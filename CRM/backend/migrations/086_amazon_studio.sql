-- 086: Studio (Amazon > Studio), part 1: photos. Run after 085. Re-runnable.
-- Upload real diary photos -> the Mac checks them (size, sharpness, light, glare) -> cut-out (2 options) -> main photo
-- (pure white 2000x2000, product ~85%) or a clean colour swatch -> "Send to Decisions". Nothing reaches Amazon without approval.
-- Files live in the PRIVATE bucket 'amazon-studio'; only a photo you send to Decisions is copied to the public bucket
-- (Amazon needs a public link). The Mac works through the amazon-bridge Edge Function with its own token.

DO $$ BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES ('amazon-studio', 'amazon-studio', false, 15728640, ARRAY['image/jpeg', 'image/png'])
    ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 15728640, allowed_mime_types = ARRAY['image/jpeg', 'image/png'];
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.amazon_studio_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('upload', 'cutout', 'main', 'swatch', 'design')),
  path text NOT NULL,                       -- in the private bucket
  width int, height int, bytes int,
  checks jsonb NOT NULL DEFAULT '[]',
  score int,
  meta jsonb NOT NULL DEFAULT '{}',
  layers jsonb,                             -- text / pointer layers (part 2)
  parent uuid,
  status text NOT NULL DEFAULT 'ready' CHECK (status IN ('ready', 'sent', 'deleted')),
  sent_change uuid,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS amazon_studio_assets_sku ON public.amazon_studio_assets (sku, created_at DESC);

CREATE TABLE IF NOT EXISTS public.amazon_studio_jobs (
  id bigserial PRIMARY KEY,
  sku text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('check', 'cutout', 'main', 'swatch')),
  asset_ids uuid[] NOT NULL DEFAULT '{}',
  params jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'working', 'done', 'failed')),
  result jsonb, error text,
  attempts int NOT NULL DEFAULT 0,
  claimed_at timestamptz, done_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS amazon_studio_jobs_wait ON public.amazon_studio_jobs (status, created_at);

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_studio_assets', 'amazon_studio_jobs'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- browser API
-- Access now also says who is signed in (Studio files and Decisions record the maker).
CREATE OR REPLACE FUNCTION public.api_amz_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.amz_can_view(), 'can_approve', crm_private.amz_can_approve(),
                            'is_admin', crm_private.is_admin(), 'employee_id', crm_private.current_employee_id())
$$;

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
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', x.sku, 'title', x.title, 'image', x.images->0->>'url',
        'color', x.attributes->'color'->0->>'value') ORDER BY x.parent_asin NULLS LAST, x.title)
      FROM public.amazon_listings x WHERE NOT x.is_parent), '[]'),
    'product', CASE WHEN l.sku IS NULL THEN NULL ELSE jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title,
      'images', coalesce(l.images, '[]'),
      'swatch', l.attributes->'swatch_product_image_locator'->0->>'media_location',
      'swatch_flagged', EXISTS (SELECT 1 FROM public.amazon_audit_findings f WHERE f.sku = l.sku AND f.status = 'open' AND f.message ~* 'SWCH|swatch')) END,
    'assets', coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC) FROM public.amazon_studio_assets a
      WHERE a.sku = p_sku AND a.status <> 'deleted'), '[]'),
    'jobs', coalesce((SELECT jsonb_agg(to_jsonb(j) ORDER BY j.created_at DESC) FROM (
       SELECT * FROM public.amazon_studio_jobs WHERE sku = p_sku AND (status IN ('waiting', 'working') OR created_at > now() - interval '1 day')
        ORDER BY created_at DESC LIMIT 20) j), '[]'),
    'waiting_all', (SELECT count(*) FROM public.amazon_studio_jobs WHERE status IN ('waiting', 'working')));
END $$;

-- Ask the Mac to do something with photos of one product.
CREATE OR REPLACE FUNCTION public.api_amz_studio_job(p_sku text, p_kind text, p_assets uuid[], p_params jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs; need text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_kind NOT IN ('check', 'cutout', 'main', 'swatch') THEN RAISE EXCEPTION 'Unknown job' USING ERRCODE = 'PT422'; END IF;
  IF cardinality(p_assets) <> 1 THEN RAISE EXCEPTION 'Choose one photo' USING ERRCODE = 'PT422'; END IF;
  need := CASE p_kind WHEN 'main' THEN 'cutout' WHEN 'cutout' THEN 'upload' ELSE NULL END;
  IF NOT EXISTS (SELECT 1 FROM public.amazon_studio_assets WHERE id = p_assets[1] AND sku = p_sku AND status <> 'deleted'
                  AND (need IS NULL OR kind = need)) THEN
    RAISE EXCEPTION 'That photo cannot be used for this step' USING ERRCODE = 'PT422';
  END IF;
  IF p_kind = 'swatch' AND NOT (jsonb_typeof(p_params->'box') = 'object') THEN RAISE EXCEPTION 'Choose the area for the swatch' USING ERRCODE = 'PT422'; END IF;
  IF (SELECT count(*) FROM public.amazon_studio_jobs WHERE status IN ('waiting', 'working')) >= 40 THEN
    RAISE EXCEPTION 'The Mac already has 40 photo jobs waiting. Try again when some are done.' USING ERRCODE = 'PT429';
  END IF;
  INSERT INTO public.amazon_studio_jobs (sku, kind, asset_ids, params, created_by)
  VALUES (p_sku, p_kind, p_assets, coalesce(p_params, '{}'), crm_private.current_employee_id()) RETURNING * INTO j;
  RETURN to_jsonb(j);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_studio_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  UPDATE public.amazon_studio_assets SET status = 'deleted' WHERE id = p_id AND status = 'ready';
END $$;

-- ---------------------------------------------------------------- server side (Edge Functions with the service role)
CREATE OR REPLACE FUNCTION public.svc_amz_studio_asset(p_sku text, p_kind text, p_path text, p_width int, p_height int, p_bytes int,
  p_checks jsonb, p_score int, p_meta jsonb, p_parent uuid, p_by uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid uuid;
BEGIN
  INSERT INTO public.amazon_studio_assets (sku, kind, path, width, height, bytes, checks, score, meta, parent, created_by)
  VALUES (p_sku, p_kind, p_path, p_width, p_height, p_bytes, coalesce(p_checks, '[]'), p_score, coalesce(p_meta, '{}'), p_parent, p_by)
  RETURNING id INTO nid;
  RETURN nid;
END $$;

-- An upload: save the asset and queue its photo check.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_upload(p_sku text, p_path text, p_bytes int, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE aid uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.amazon_listings WHERE sku = p_sku) THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  aid := public.svc_amz_studio_asset(p_sku, 'upload', p_path, NULL, NULL, p_bytes, '[]', NULL, '{}', NULL, p_by);
  INSERT INTO public.amazon_studio_jobs (sku, kind, asset_ids, created_by) VALUES (p_sku, 'check', ARRAY[aid], p_by);
  RETURN jsonb_build_object('id', aid);
END $$;

-- The Mac takes the next photo job (one at a time; a job stuck for 15 minutes is retried, at most 3 times).
CREATE OR REPLACE FUNCTION public.svc_amz_studio_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs;
BEGIN
  UPDATE public.amazon_studio_jobs SET status = CASE WHEN attempts >= 3 THEN 'failed' ELSE 'waiting' END,
    error = CASE WHEN attempts >= 3 THEN 'The Mac did not finish this job after 3 tries.' ELSE error END
   WHERE status = 'working' AND claimed_at < now() - interval '15 minutes';
  SELECT * INTO j FROM public.amazon_studio_jobs WHERE status = 'waiting' ORDER BY (kind = 'check') DESC, created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF j.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_studio_jobs SET status = 'working', claimed_at = now(), attempts = attempts + 1 WHERE id = j.id RETURNING * INTO j;
  RETURN jsonb_build_object('job', to_jsonb(j), 'inputs', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'path', a.path) ORDER BY o)
      FROM unnest(j.asset_ids) WITH ORDINALITY u(aid, o) JOIN public.amazon_studio_assets a ON a.id = u.aid), '[]'));
END $$;

-- The Mac finished (files already stored by the Edge Function and listed in p_files with their storage path).
CREATE OR REPLACE FUNCTION public.svc_amz_studio_finish(p_job bigint, p_ok boolean, p_result jsonb, p_error text, p_files jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE j public.amazon_studio_jobs; f jsonb; ids jsonb := '[]'; r jsonb; aid uuid; i int;
BEGIN
  SELECT * INTO j FROM public.amazon_studio_jobs WHERE id = p_job FOR UPDATE;
  IF j.id IS NULL OR j.status <> 'working' THEN RETURN jsonb_build_object('saved', false); END IF;
  IF NOT p_ok THEN
    UPDATE public.amazon_studio_jobs SET status = 'failed', error = left(coalesce(p_error, 'Failed'), 300), done_at = now() WHERE id = p_job;
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
  FOR f IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_files) = 'array' THEN p_files ELSE '[]' END) LOOP
    CONTINUE WHEN f->>'kind' NOT IN ('cutout', 'main', 'swatch');
    aid := public.svc_amz_studio_asset(j.sku, f->>'kind', f->>'path', (f->>'width')::int, (f->>'height')::int, (f->>'bytes')::int,
             f->'checks', (f->>'score')::int, coalesce(f->'meta', '{}') || jsonb_build_object('job', p_job), j.asset_ids[1], j.created_by);
    ids := ids || to_jsonb(aid::text);
  END LOOP;
  UPDATE public.amazon_studio_jobs SET status = 'done', result = coalesce(p_result, '{}') || jsonb_build_object('assets', ids), done_at = now()
   WHERE id = p_job;
  RETURN jsonb_build_object('saved', true, 'assets', ids);
END $$;

-- "Send to Decisions": the photo (already copied to the public bucket by the Edge Function) becomes a waiting change.
-- slot 1 = main photo (cover), 2..9 = other photos, 'swatch' = colour swatch.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_send(p_asset uuid, p_slot text, p_url text, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.amazon_studio_assets; l public.amazon_listings; imgs jsonb; n int; after jsonb; bef jsonb; q public.amazon_change_queue;
  white boolean; summary text;
BEGIN
  SELECT * INTO a FROM public.amazon_studio_assets WHERE id = p_asset FOR UPDATE;
  IF a.id IS NULL OR a.status = 'deleted' THEN RAISE EXCEPTION 'Photo not found' USING ERRCODE = 'PT404'; END IF;
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
    summary := CASE WHEN n = 1 THEN 'New main photo (Studio)' ELSE format('New photo %s (Studio)', n) END;
  END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, created_by_type, created_by, reason)
  VALUES ('listing', a.sku, l.asin, summary, bef, after, l.version, 'user', p_by,
          left('Made in Studio from your own photo. Checks: ' || coalesce((SELECT string_agg(c->>'message', '; ') FROM jsonb_array_elements(a.checks) c), 'none'), 600))
  RETURNING * INTO q;
  UPDATE public.amazon_studio_assets SET status = 'sent', sent_change = q.id WHERE id = a.id;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', a.sku, 'kind', 'studio', 'slot', p_slot));
  RETURN jsonb_build_object('change', q.id, 'slot', coalesce(n::text, p_slot));
END $$;

-- ---------------------------------------------------------------- permissions
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_studio(text)', 'public.api_amz_studio_job(text, text, uuid[], jsonb)', 'public.api_amz_studio_delete(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_studio_asset(text, text, text, int, int, int, jsonb, int, jsonb, uuid, uuid)',
    'public.svc_amz_studio_upload(text, text, int, uuid)', 'public.svc_amz_studio_claim()',
    'public.svc_amz_studio_finish(bigint, boolean, jsonb, text, jsonb)', 'public.svc_amz_studio_send(uuid, text, text, uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
