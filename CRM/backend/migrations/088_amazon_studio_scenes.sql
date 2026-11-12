-- 088: Studio part 3. Run after 087. Re-runnable.
--  * Lifestyle scenes: the REAL cut-out placed on a real free Pexels photo or an AI background made on the Mac
--    (Z-Image-Turbo, Apache-2.0, run free with mflux). The product's own pixels are never redrawn; only the background is new.
--    The Mac adds a soft shadow and (optionally) a "Props not included" note; Claude then looks at the scene.
--  * Competitor photo study: Amazon's own catalog (SP-API search) -> what top listings show in their photos (Claude looks).
--  * Brand kit (colours, font, name) used by the designer; designs can copy their layers to other products/colours.
--  * Shoot list per product: the photos a strong listing has, what this product has, and what competitors show.
-- Nothing here reaches Amazon: a finished scene still goes to Decisions and waits for approval.

-- ---------------------------------------------------------------- kinds
ALTER TABLE public.amazon_studio_assets DROP CONSTRAINT IF EXISTS amazon_studio_assets_kind_check;
ALTER TABLE public.amazon_studio_assets ADD CONSTRAINT amazon_studio_assets_kind_check
  CHECK (kind IN ('upload', 'cutout', 'main', 'swatch', 'design', 'scene', 'background'));
ALTER TABLE public.amazon_studio_jobs DROP CONSTRAINT IF EXISTS amazon_studio_jobs_kind_check;
ALTER TABLE public.amazon_studio_jobs ADD CONSTRAINT amazon_studio_jobs_kind_check
  CHECK (kind IN ('check', 'cutout', 'main', 'swatch', 'scene', 'aibg', 'study'));

-- Free Pexels key (pexels.com/api) is stored in Vault like the other keys.
CREATE OR REPLACE FUNCTION crm_private.amz_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['AMZ_LWA_CLIENT_ID','AMZ_LWA_CLIENT_SECRET','AMZ_REFRESH_TOKEN','AMZ_SELLER_ID',
               'ADS_CLIENT_ID','ADS_CLIENT_SECRET','ADS_REFRESH_TOKEN','ADS_PROFILE_ID','PEXELS_API_KEY']
$$;

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS public.amazon_studio_brand (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  name text NOT NULL DEFAULT 'Nitaniya',
  colors jsonb NOT NULL DEFAULT '["#1d1d1f", "#7A4A24", "#A67C1A", "#F6EFE4"]',   -- text, accent, highlight, soft background
  font text NOT NULL DEFAULT 'system' CHECK (font IN ('system', 'serif', 'rounded')),
  name_spot text NOT NULL DEFAULT 'none' CHECK (name_spot IN ('none', 'top-left', 'top-right', 'bottom-left', 'bottom-right')),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.amazon_studio_brand (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.amazon_photo_study (
  id bigserial PRIMARY KEY,
  sku text NOT NULL,
  keyword text NOT NULL,
  items jsonb NOT NULL DEFAULT '[]',        -- [{asin, title, brand, bsr, images:[{variant, url}]}] from Amazon's catalog
  own jsonb NOT NULL DEFAULT '[]',          -- this product's photos [{slot, url}]
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'done', 'failed')),
  result jsonb, error text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS amazon_photo_study_sku ON public.amazon_photo_study (sku, created_at DESC);

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_studio_brand', 'amazon_photo_study'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- photo types (shared by the study, the shoot list and the UI)
-- Order = the order a strong listing usually shows them. 'needs' = a product fact that must be true for the shot to make sense.
CREATE OR REPLACE FUNCTION crm_private.amz_shot_types() RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT '[
    {"code":"white_main","label":"Main photo on pure white","tip":"Studio makes it from any clear photo: Upload, Make cut-out, Make main photo."},
    {"code":"personalisation","label":"Name on the cover, close-up","needs":"personal","tip":"Print a sample name; shoot straight on in daylight, cover fills the frame."},
    {"code":"inside_pages","label":"Inside pages","tip":"Open flat on a table, phone straight above, show 2 pages clearly."},
    {"code":"size_scale","label":"Size: in hand or next to a phone/pen","tip":"Hold it in one hand or put a phone beside it so buyers see the real size."},
    {"code":"features","label":"Key features with pointers","tip":"Use a cut-out photo, then Add text & pointers with the Features template."},
    {"code":"material","label":"Cover, closure and stitching close-up","tip":"Shoot the corner and closure 15 cm away, side light shows the texture."},
    {"code":"lifestyle","label":"Lifestyle scene (desk, gift, office)","tip":"Make lifestyle scene from a cut-out; or shoot it on a real desk."},
    {"code":"whats_included","label":"What''s in the box","tip":"Lay out exactly what the buyer gets, nothing extra; use the Box template."},
    {"code":"gift","label":"Gift moment / packaging","tip":"Only if it really comes gift-ready; otherwise show it next to a gift card or ribbon with \"Props not included\"."}
  ]'::jsonb
$$;

-- ---------------------------------------------------------------- browser API
CREATE OR REPLACE FUNCTION public.api_amz_studio(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; seen timestamptz;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku AND NOT is_parent;
  SELECT nullif(value, '')::timestamptz INTO seen FROM public.amazon_config WHERE key = 'bridge_seen_at';
  RETURN jsonb_build_object(
    'can_send', crm_private.amz_can_approve(),
    'mac_online', seen IS NOT NULL AND seen > now() - interval '90 seconds',
    'pexels_ready', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'amz_pexels_api_key'),
    'ai_status', (SELECT value FROM public.amazon_config WHERE key = 'studio_ai_status'),
    'brand', (SELECT to_jsonb(b) - 'updated_by' FROM public.amazon_studio_brand b WHERE id = 1),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', x.sku, 'title', x.title, 'image', x.images->0->>'url',
        'color', x.attributes->'color'->0->>'value') ORDER BY x.parent_asin NULLS LAST, x.title)
      FROM public.amazon_listings x WHERE NOT x.is_parent), '[]'),
    'product', CASE WHEN l.sku IS NULL THEN NULL ELSE jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title,
      'images', coalesce(l.images, '[]'),
      'swatch', l.attributes->'swatch_product_image_locator'->0->>'media_location',
      'swatch_flagged', EXISTS (SELECT 1 FROM public.amazon_audit_findings f WHERE f.sku = l.sku AND f.status = 'open' AND f.message ~* 'SWCH|swatch')) END,
    'assets', coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC) FROM public.amazon_studio_assets a
      WHERE (a.sku = p_sku OR a.kind = 'background') AND a.status <> 'deleted'), '[]'),
    'jobs', coalesce((SELECT jsonb_agg(to_jsonb(j) ORDER BY j.created_at DESC) FROM (
       SELECT * FROM public.amazon_studio_jobs WHERE sku = p_sku AND (status IN ('waiting', 'working') OR created_at > now() - interval '1 day')
        ORDER BY created_at DESC LIMIT 20) j), '[]'),
    'waiting_all', (SELECT count(*) FROM public.amazon_studio_jobs WHERE status IN ('waiting', 'working')));
END $$;

-- Pexels photo links the Mac may download (checked again on the Mac).
CREATE OR REPLACE FUNCTION crm_private.amz_bg_url_ok(u text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(u ~ '^https://images\.pexels\.com/photos/[0-9]+/[A-Za-z0-9._-]+\.(jpe?g|png)(\?[A-Za-z0-9=&._%-]*)?$', false)
$$;

-- Ask the Mac to do something with photos of one product.
--   scene: assets [cut-out] or [cut-out, AI background]; params {bg:{source:'pexels', url, credit} | {source:'ai'}, x, y, scale, note}
--   aibg:  no assets; params {theme, words}  -> 2 AI backgrounds (empty scene, no text/people/logos)
CREATE OR REPLACE FUNCTION public.api_amz_studio_job(p_sku text, p_kind text, p_assets uuid[], p_params jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs; need text; prm jsonb := coalesce(p_params, '{}'); bg jsonb; theme text; words text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_kind NOT IN ('check', 'cutout', 'main', 'swatch', 'scene', 'aibg') THEN RAISE EXCEPTION 'Unknown job' USING ERRCODE = 'PT422'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.amazon_listings WHERE sku = p_sku AND NOT is_parent) THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  IF p_kind = 'aibg' THEN
    IF coalesce(cardinality(p_assets), 0) <> 0 THEN RAISE EXCEPTION 'AI backgrounds do not use a photo' USING ERRCODE = 'PT422'; END IF;
    theme := coalesce(prm->>'theme', '');
    IF theme NOT IN ('desk', 'gift', 'cafe', 'office', 'festive', 'nature') THEN RAISE EXCEPTION 'Choose a theme' USING ERRCODE = 'PT422'; END IF;
    words := btrim(regexp_replace(coalesce(prm->>'words', ''), '[^A-Za-z0-9 ,.-]', '', 'g'));
    IF length(words) > 120 THEN RAISE EXCEPTION 'Keep the extra words under 120 characters' USING ERRCODE = 'PT422'; END IF;
    IF words ~* '\m(person|people|man|woman|girl|boy|child|kid|face|hand|hands|logo|brand|text|letters|words|nude|naked)\M' THEN
      RAISE EXCEPTION 'AI backgrounds are made without people, hands, logos or text' USING ERRCODE = 'PT422';
    END IF;
    prm := jsonb_build_object('theme', theme, 'words', words, 'seed', coalesce((prm->>'seed')::int, (random() * 1e6)::int));
  ELSE
    IF coalesce(cardinality(p_assets), 0) NOT BETWEEN 1 AND (CASE WHEN p_kind = 'scene' THEN 2 ELSE 1 END) THEN
      RAISE EXCEPTION 'Choose one photo' USING ERRCODE = 'PT422';
    END IF;
    need := CASE p_kind WHEN 'main' THEN 'cutout' WHEN 'cutout' THEN 'upload' WHEN 'scene' THEN 'cutout' ELSE NULL END;
    IF NOT EXISTS (SELECT 1 FROM public.amazon_studio_assets WHERE id = p_assets[1] AND sku = p_sku AND status <> 'deleted'
                    AND (need IS NULL OR kind = need)) THEN
      RAISE EXCEPTION 'That photo cannot be used for this step' USING ERRCODE = 'PT422';
    END IF;
    IF p_kind = 'swatch' AND NOT (jsonb_typeof(prm->'box') = 'object') THEN RAISE EXCEPTION 'Choose the area for the swatch' USING ERRCODE = 'PT422'; END IF;
    IF p_kind = 'scene' THEN
      bg := prm->'bg';
      IF bg->>'source' = 'pexels' THEN
        IF cardinality(p_assets) <> 1 OR NOT crm_private.amz_bg_url_ok(bg->>'url') THEN
          RAISE EXCEPTION 'Choose a Pexels background' USING ERRCODE = 'PT422';
        END IF;
        bg := jsonb_build_object('source', 'pexels', 'url', bg->>'url',
          'credit', jsonb_build_object('name', left(coalesce(bg->'credit'->>'name', ''), 80),
            'url', CASE WHEN bg->'credit'->>'url' ~ '^https://www\.pexels\.com/' THEN bg->'credit'->>'url' END,
            'photo', CASE WHEN bg->'credit'->>'photo' ~ '^https://www\.pexels\.com/' THEN bg->'credit'->>'photo' END));
      ELSIF bg->>'source' = 'ai' THEN
        IF cardinality(p_assets) <> 2 OR NOT EXISTS (SELECT 1 FROM public.amazon_studio_assets WHERE id = p_assets[2] AND kind = 'background' AND status <> 'deleted') THEN
          RAISE EXCEPTION 'Choose an AI background' USING ERRCODE = 'PT422';
        END IF;
        bg := jsonb_build_object('source', 'ai');
      ELSE
        RAISE EXCEPTION 'Choose a background' USING ERRCODE = 'PT422';
      END IF;
      prm := jsonb_build_object('bg', bg,
        'x', least(0.9, greatest(0.1, coalesce((prm->>'x')::numeric, 0.5))),
        'y', least(0.9, greatest(0.1, coalesce((prm->>'y')::numeric, 0.55))),
        'scale', least(0.8, greatest(0.25, coalesce((prm->>'scale')::numeric, 0.5))),
        'note', coalesce((prm->>'note')::boolean, true),
        -- for Claude's look at the finished scene: what the product really is
        'product', left(coalesce((SELECT title FROM public.amazon_listings WHERE sku = p_sku), '') || ' | ' || crm_private.amz_product_text(p_sku), 1500));
    END IF;
  END IF;
  IF (SELECT count(*) FROM public.amazon_studio_jobs WHERE status IN ('waiting', 'working')) >= 40 THEN
    RAISE EXCEPTION 'The Mac already has 40 photo jobs waiting. Try again when some are done.' USING ERRCODE = 'PT429';
  END IF;
  INSERT INTO public.amazon_studio_jobs (sku, kind, asset_ids, params, created_by)
  VALUES (p_sku, p_kind, coalesce(p_assets, '{}'), prm, crm_private.current_employee_id()) RETURNING * INTO j;
  RETURN to_jsonb(j);
END $$;

-- Brand kit
CREATE OR REPLACE FUNCTION public.api_amz_studio_brand_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.amazon_studio_brand; c jsonb := p->'colors';
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Only Admin can change the brand kit' USING ERRCODE = 'PT403'; END IF;
  IF c IS NOT NULL AND (jsonb_typeof(c) <> 'array' OR jsonb_array_length(c) NOT BETWEEN 1 AND 6
      OR EXISTS (SELECT 1 FROM jsonb_array_elements(c) e WHERE jsonb_typeof(e) <> 'string' OR e #>> '{}' !~ '^#[0-9A-Fa-f]{6}$')) THEN
    RAISE EXCEPTION 'Colours must be 1-6 hex codes like #7A4A24' USING ERRCODE = 'PT422';
  END IF;
  IF p ? 'name' AND (length(btrim(p->>'name')) NOT BETWEEN 1 AND 30) THEN RAISE EXCEPTION 'Brand name: 1-30 characters' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.amazon_studio_brand SET
    name = coalesce(btrim(p->>'name'), name), colors = coalesce(c, colors),
    font = coalesce(p->>'font', font), name_spot = coalesce(p->>'name_spot', name_spot),
    updated_by = crm_private.current_employee_id(), updated_at = now()
   WHERE id = 1 RETURNING * INTO b;
  RETURN to_jsonb(b) - 'updated_by';
EXCEPTION WHEN check_violation THEN RAISE EXCEPTION 'Unknown font or name position' USING ERRCODE = 'PT422';
END $$;

-- Designs from any product (to copy their text & pointers to another colour / product; the truth check runs again there).
CREATE OR REPLACE FUNCTION public.api_amz_studio_designs(p_except text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.amz_can_view() THEN coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
    SELECT jsonb_build_object('id', a.id, 'sku', a.sku, 'title', l.title, 'color', l.attributes->'color'->0->>'value', 'score', a.score,
             'layers', a.layers, 'created_at', a.created_at) x
      FROM public.amazon_studio_assets a JOIN public.amazon_listings l ON l.sku = a.sku
     WHERE a.kind = 'design' AND a.status <> 'deleted' AND jsonb_typeof(a.layers) = 'array' AND jsonb_array_length(a.layers) > 0
       AND a.sku IS DISTINCT FROM p_except
     ORDER BY a.created_at DESC LIMIT 30) s), '[]') END
$$;

-- Guide: competitor study + shoot list for one product.
CREATE OR REPLACE FUNCTION public.api_amz_studio_guide(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; s public.amazon_photo_study; f jsonb; kw text; own jsonb := '{}'; comp jsonb := '{}';
  n int := 0; shots jsonb := '[]'; t jsonb; have boolean; made int; pct int;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku AND NOT is_parent;
  IF l.sku IS NULL THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  f := crm_private.amz_facts(p_sku);
  SELECT k.keyword INTO kw FROM public.amazon_keywords k
   WHERE crm_private.amz_kw_main(k) AND k.status NOT IN ('rejected', 'hidden') AND crm_private.amz_kw_fit(p_sku, k.keyword) IS NULL
   ORDER BY coalesce(k.competitor_count, 0) DESC, k.id LIMIT 1;
  SELECT * INTO s FROM public.amazon_photo_study WHERE sku = p_sku ORDER BY created_at DESC LIMIT 1;
  IF s.status = 'done' THEN
    own := coalesce(s.result->'own', '{}');
    comp := coalesce(s.result->'share', '{}');
    n := coalesce((s.result->>'competitors')::int, 0);
  END IF;
  FOR t IN SELECT * FROM jsonb_array_elements(crm_private.amz_shot_types()) LOOP
    CONTINUE WHEN t ? 'needs' AND NOT coalesce((f->>(t->>'needs'))::boolean, false);
    have := CASE WHEN t->>'code' = 'white_main' THEN jsonb_array_length(coalesce(l.images, '[]')) > 0 AND (s.id IS NULL OR coalesce((own->>'white_main')::int, 0) > 0)
                 WHEN s.status = 'done' THEN coalesce((own->>(t->>'code'))::int, 0) > 0 END;
    made := (SELECT count(*) FROM public.amazon_studio_assets a WHERE a.sku = p_sku AND a.status = 'ready'
              AND a.kind = CASE t->>'code' WHEN 'white_main' THEN 'main' WHEN 'lifestyle' THEN 'scene'
                                         WHEN 'features' THEN 'design' WHEN 'whats_included' THEN 'design' ELSE '-' END);
    pct := CASE WHEN n > 0 THEN round(coalesce((comp->>(t->>'code'))::numeric, 0) * 100 / n) END;
    shots := shots || jsonb_build_object('code', t->>'code', 'label', t->>'label', 'tip', t->>'tip',
      'have', have, 'ready_in_studio', made, 'competitors_pct', pct);
  END LOOP;
  RETURN jsonb_build_object(
    'sku', l.sku, 'title', l.title, 'photos', jsonb_array_length(coalesce(l.images, '[]')),
    'keyword', coalesce(s.keyword, kw, lower(array_to_string((regexp_split_to_array(btrim(coalesce(l.title, '')), '\s+'))[1:3], ' '))),
    'study', CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('id', s.id, 'keyword', s.keyword, 'status', s.status, 'error', s.error,
      'created_at', s.created_at, 'competitors', n, 'avg_photos', s.result->'avg_photos', 'notes', s.result->'notes',
      'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('asin', i->>'asin', 'title', i->>'title', 'brand', i->>'brand',
                 'photos', jsonb_array_length(coalesce(i->'images', '[]')), 'image', i->'images'->0->>'url')), '[]')
                FROM jsonb_array_elements(s.items) i)) END,
    'study_running', EXISTS (SELECT 1 FROM public.amazon_studio_jobs WHERE sku = p_sku AND kind = 'study' AND status IN ('waiting', 'working')),
    'shots', shots,
    'brand', (SELECT to_jsonb(b) - 'updated_by' FROM public.amazon_studio_brand b WHERE id = 1));
END $$;

-- ---------------------------------------------------------------- server side
-- Competitor study: the Edge Function has already read Amazon's catalog; queue the Mac to look at the photos.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_study(p_sku text, p_keyword text, p_items jsonb, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; sid bigint; own jsonb; items jsonb;
BEGIN
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku AND NOT is_parent;
  IF l.sku IS NULL THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  IF EXISTS (SELECT 1 FROM public.amazon_studio_jobs WHERE sku = p_sku AND kind = 'study' AND status IN ('waiting', 'working')) THEN
    RAISE EXCEPTION 'A study for this product is already running' USING ERRCODE = 'PT429';
  END IF;
  -- keep only Amazon image links; at most 10 listings x 9 photos
  items := coalesce((SELECT jsonb_agg(jsonb_build_object('asin', i->>'asin', 'title', left(i->>'title', 200), 'brand', left(i->>'brand', 80),
             'bsr', i->'bsr', 'images', (SELECT coalesce(jsonb_agg(m ORDER BY o), '[]') FROM (
                 SELECT jsonb_build_object('variant', m->>'variant', 'url', m->>'url') m, o FROM jsonb_array_elements(coalesce(i->'images', '[]')) WITH ORDINALITY x(m, o)
                  WHERE m->>'url' ~ '^https://m\.media-amazon\.com/images/I/[A-Za-z0-9._+%-]+\.(jpg|jpeg|png)$' LIMIT 9) z)) ORDER BY o)
     FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]' END) WITH ORDINALITY q(i, o)
    WHERE o <= 10 AND i->>'asin' ~ '^[A-Z0-9]{10}$'), '[]');
  IF jsonb_array_length(items) = 0 THEN RAISE EXCEPTION 'Amazon returned no other listings for this keyword' USING ERRCODE = 'PT422'; END IF;
  own := (SELECT coalesce(jsonb_agg(jsonb_build_object('slot', o, 'url', coalesce(e->>'url', e #>> '{}')) ORDER BY o), '[]')
            FROM jsonb_array_elements(coalesce(l.images, '[]')) WITH ORDINALITY x(e, o) WHERE o <= 9);
  INSERT INTO public.amazon_photo_study (sku, keyword, items, own, created_by) VALUES (p_sku, left(p_keyword, 120), items, own, p_by) RETURNING id INTO sid;
  INSERT INTO public.amazon_studio_jobs (sku, kind, params, created_by) VALUES (p_sku, 'study', jsonb_build_object('study', sid), p_by);
  RETURN jsonb_build_object('study', sid, 'competitors', jsonb_array_length(items));
END $$;

-- The Mac takes the next photo job. Study jobs carry the photo links; AI jobs only run when nothing else waits.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs; s public.amazon_photo_study; extra jsonb := '{}';
BEGIN
  UPDATE public.amazon_studio_jobs SET status = CASE WHEN attempts >= 3 THEN 'failed' ELSE 'waiting' END,
    error = CASE WHEN attempts >= 3 THEN 'The Mac did not finish this job after 3 tries.' ELSE error END
   WHERE status = 'working' AND claimed_at < now() - interval '15 minutes';
  UPDATE public.amazon_photo_study p SET status = 'failed', error = sj.error
    FROM public.amazon_studio_jobs sj WHERE sj.kind = 'study' AND sj.status = 'failed' AND (sj.params->>'study')::bigint = p.id AND p.status = 'waiting';
  SELECT * INTO j FROM public.amazon_studio_jobs WHERE status = 'waiting'
   ORDER BY (kind = 'check') DESC, (kind = 'aibg'), created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF j.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_studio_jobs SET status = 'working', claimed_at = now(), attempts = attempts + 1 WHERE id = j.id RETURNING * INTO j;
  IF j.kind = 'study' THEN
    SELECT * INTO s FROM public.amazon_photo_study WHERE id = (j.params->>'study')::bigint;
    extra := jsonb_build_object('study', jsonb_build_object('keyword', s.keyword, 'items', s.items, 'own', s.own));
  END IF;
  RETURN jsonb_build_object('job', to_jsonb(j), 'inputs', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'path', a.path) ORDER BY o)
      FROM unnest(j.asset_ids) WITH ORDINALITY u(aid, o) JOIN public.amazon_studio_assets a ON a.id = u.aid), '[]')) || extra;
END $$;

-- The Mac finished (files already stored by the Edge Function and listed in p_files with their storage path).
CREATE OR REPLACE FUNCTION public.svc_amz_studio_finish(p_job bigint, p_ok boolean, p_result jsonb, p_error text, p_files jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs; f jsonb; ids jsonb := '[]'; r jsonb; aid uuid; i int; parent uuid; fmeta jsonb; sc int;
  types text[] := ARRAY(SELECT e->>'code' FROM jsonb_array_elements(crm_private.amz_shot_types()) e);
  share jsonb := '{}'; own_c jsonb := '{}'; comp jsonb; t text; nc int := 0; photos int := 0;
BEGIN
  SELECT * INTO j FROM public.amazon_studio_jobs WHERE id = p_job FOR UPDATE;
  IF j.id IS NULL OR j.status <> 'working' THEN RETURN jsonb_build_object('saved', false); END IF;
  IF NOT p_ok THEN
    UPDATE public.amazon_studio_jobs SET status = 'failed', error = left(coalesce(p_error, 'Failed'), 300), done_at = now() WHERE id = p_job;
    IF j.kind = 'study' THEN
      UPDATE public.amazon_photo_study SET status = 'failed', error = left(coalesce(p_error, 'Failed'), 300) WHERE id = (j.params->>'study')::bigint;
    END IF;
    RETURN jsonb_build_object('saved', true);
  END IF;
  IF j.kind = 'check' THEN
    FOR i IN 1 .. cardinality(j.asset_ids) LOOP
      r := p_result->(i - 1)::text;
      CONTINUE WHEN r IS NULL;
      UPDATE public.amazon_studio_assets SET checks = coalesce(r->'checks', '[]'), score = (r->>'score')::int,
        width = (r->>'width')::int, height = (r->>'height')::int, meta = meta || jsonb_build_object('metrics', r->'metrics')
       WHERE id = j.asset_ids[i];
    END LOOP;
  END IF;
  IF j.kind = 'study' THEN
    -- p_result: {competitors:[{asin, types:[codes per photo]}], own:[codes per photo], notes:[text]}; counts are made here
    FOR comp IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_result->'competitors') = 'array' THEN p_result->'competitors' ELSE '[]' END) LOOP
      nc := nc + 1;
      photos := photos + coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(comp->'types') = 'array' THEN comp->'types' END), 0);
      FOREACH t IN ARRAY types LOOP
        IF coalesce(comp->'types', '[]') ? t THEN share := jsonb_set(share, ARRAY[t], to_jsonb(coalesce((share->>t)::int, 0) + 1)); END IF;
      END LOOP;
    END LOOP;
    FOREACH t IN ARRAY types LOOP
      own_c := own_c || jsonb_build_object(t, (SELECT count(*) FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_result->'own') = 'array' THEN p_result->'own' ELSE '[]' END) x WHERE x = t));
    END LOOP;
    UPDATE public.amazon_photo_study SET status = 'done', result = jsonb_build_object('competitors', nc, 'share', share, 'own', own_c,
        'avg_photos', CASE WHEN nc > 0 THEN round(photos::numeric / nc, 1) END,
        'notes', (SELECT coalesce(jsonb_agg(left(x, 200)), '[]') FROM (SELECT x FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_result->'notes') = 'array' THEN p_result->'notes' ELSE '[]' END) x LIMIT 5) n),
        'detail', p_result->'competitors')
     WHERE id = (j.params->>'study')::bigint;
  END IF;
  FOR f IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_files) = 'array' THEN p_files ELSE '[]' END) LOOP
    CONTINUE WHEN f->>'kind' NOT IN ('cutout', 'main', 'swatch', 'scene', 'background');
    CONTINUE WHEN (f->>'kind' = 'background') <> (j.kind = 'aibg');
    CONTINUE WHEN (f->>'kind' = 'scene') <> (j.kind = 'scene');
    parent := CASE WHEN j.kind = 'aibg' THEN NULL ELSE j.asset_ids[1] END;
    fmeta := coalesce(f->'meta', '{}') || jsonb_build_object('job', p_job);
    sc := (f->>'score')::int;
    IF j.kind = 'scene' THEN
      fmeta := fmeta || jsonb_build_object('bg', j.params->'bg', 'bg_asset', j.asset_ids[2], 'note', j.params->'note');
      -- Claude flagged something that could mislead a buyer (props that look included, people, logos): cap like a false claim
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(f->'checks', '[]')) c WHERE c->>'code' = 'claude' AND c->>'level' = 'bad') THEN
        sc := least(coalesce(sc, 0), 40);
      END IF;
    END IF;
    aid := public.svc_amz_studio_asset(j.sku, f->>'kind', f->>'path', (f->>'width')::int, (f->>'height')::int, (f->>'bytes')::int,
             f->'checks', sc, fmeta, parent, j.created_by);
    ids := ids || to_jsonb(aid::text);
  END LOOP;
  UPDATE public.amazon_studio_jobs SET status = 'done', result = coalesce(p_result, '{}') || jsonb_build_object('assets', ids), done_at = now()
   WHERE id = p_job;
  RETURN jsonb_build_object('saved', true, 'assets', ids);
END $$;

-- The Mac reports its AI-background setup ("installing", "ready", or a plain-words problem).
CREATE OR REPLACE FUNCTION public.svc_amz_studio_ai_status(p_status text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_config (key, value) VALUES ('studio_ai_status', left(p_status, 200))
  ON CONFLICT (key) DO UPDATE SET value = excluded.value
$$;

-- "Send to Decisions" (redefined from 087): designs and scenes under 70 are refused; backgrounds and cut-outs are not photos.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_send(p_asset uuid, p_slot text, p_url text, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.amazon_studio_assets; l public.amazon_listings; imgs jsonb; n int; after jsonb; bef jsonb; q public.amazon_change_queue;
  white boolean; summary text; why text;
BEGIN
  SELECT * INTO a FROM public.amazon_studio_assets WHERE id = p_asset FOR UPDATE;
  IF a.id IS NULL OR a.status = 'deleted' THEN RAISE EXCEPTION 'Photo not found' USING ERRCODE = 'PT404'; END IF;
  IF a.kind IN ('design', 'scene') AND coalesce(a.score, 0) < 70 THEN
    RAISE EXCEPTION 'This % scored %/100: fix the problems shown before sending', a.kind, coalesce(a.score, 0) USING ERRCODE = 'PT422';
  END IF;
  IF a.kind = 'background' THEN RAISE EXCEPTION 'A background on its own is not a product photo: make a scene with it' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = a.sku;
  IF p_url !~ '^https://[^\s]+$' THEN RAISE EXCEPTION 'Photo link is not public' USING ERRCODE = 'PT422'; END IF;
  IF p_slot = 'swatch' THEN
    IF a.kind <> 'swatch' THEN RAISE EXCEPTION 'Only a swatch can go into the colour swatch' USING ERRCODE = 'PT422'; END IF;
    after := jsonb_build_object('swatch_image', jsonb_build_object('url', p_url));
    bef := jsonb_build_object('swatch_image', CASE WHEN l.attributes->'swatch_product_image_locator'->0->>'media_location' IS NULL THEN 'null'::jsonb
             ELSE jsonb_build_object('url', l.attributes->'swatch_product_image_locator'->0->>'media_location') END);
    summary := 'New clean colour swatch (Studio)';
  ELSE
    IF p_slot !~ '^[1-9]$' THEN RAISE EXCEPTION 'Unknown photo slot' USING ERRCODE = 'PT422'; END IF;
    n := p_slot::int;
    IF n = 1 AND a.kind <> 'main' THEN RAISE EXCEPTION 'The main photo must be a Studio main photo (pure white, no text)' USING ERRCODE = 'PT422'; END IF;
    IF a.kind = 'cutout' THEN RAISE EXCEPTION 'Make a main photo from the cut-out first' USING ERRCODE = 'PT422'; END IF;
    imgs := (SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(e) = 'string' THEN jsonb_build_object('url', e #>> '{}') ELSE e END ORDER BY o), '[]')
               FROM jsonb_array_elements(coalesce(l.images, '[]')) WITH ORDINALITY t(e, o));
    white := coalesce((a.meta->>'white_bg')::boolean, false);
    IF n > jsonb_array_length(imgs) THEN
      n := jsonb_array_length(imgs) + 1;                 -- next free slot
      IF n = 1 AND a.kind <> 'main' THEN RAISE EXCEPTION 'The main photo must be a Studio main photo (pure white, no text)' USING ERRCODE = 'PT422'; END IF;
      imgs := imgs || jsonb_build_array(jsonb_build_object('url', p_url, 'width', a.width, 'height', a.height)
                || CASE WHEN n = 1 THEN jsonb_build_object('white_bg', white, 'has_text', false) ELSE '{}'::jsonb END);
    ELSE
      imgs := jsonb_set(imgs, ARRAY[(n - 1)::text], jsonb_build_object('url', p_url, 'width', a.width, 'height', a.height)
                || CASE WHEN n = 1 THEN jsonb_build_object('white_bg', white, 'has_text', false) ELSE '{}'::jsonb END);
    END IF;
    after := jsonb_build_object('images', imgs);
    bef := jsonb_build_object('images', coalesce(l.images, '[]'));
    summary := CASE WHEN n = 1 THEN 'New main photo (Studio)' WHEN a.kind = 'scene' THEN format('New lifestyle photo %s (Studio)', n)
                    ELSE format('New photo %s (Studio)', n) END;
  END IF;
  why := 'Made in Studio from your own photo. Checks: ' || coalesce((SELECT string_agg(c->>'message', '; ') FROM jsonb_array_elements(a.checks) c), 'none');
  IF a.kind = 'scene' THEN
    why := CASE WHEN a.meta->'bg'->>'source' = 'pexels'
                THEN format('Real product on a free Pexels photo by %s (Pexels licence: free to use, edited). ', coalesce(nullif(a.meta->'bg'->'credit'->>'name', ''), 'a Pexels photographer'))
                ELSE 'Real product on an AI-made background (Z-Image-Turbo on your Mac; the product itself is your photo). ' END || why;
  END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, created_by_type, created_by, reason)
  VALUES ('listing', a.sku, l.asin, summary, bef, after, l.version, 'user', p_by, left(why, 600))
  RETURNING * INTO q;
  UPDATE public.amazon_studio_assets SET status = 'sent', sent_change = q.id,
         meta = coalesce(meta, '{}') || jsonb_build_object('sent_slot', coalesce(n::text, p_slot)) WHERE id = a.id;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', a.sku, 'kind', 'studio', 'slot', p_slot));
  RETURN jsonb_build_object('change', q.id, 'slot', coalesce(n::text, p_slot));
END $$;

-- ---------------------------------------------------------------- permissions
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_studio_brand_save(jsonb)', 'public.api_amz_studio_designs(text)', 'public.api_amz_studio_guide(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_studio_study(text, text, jsonb, uuid)', 'public.svc_amz_studio_ai_status(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['crm_private.amz_shot_types()', 'crm_private.amz_bg_url_ok(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;
