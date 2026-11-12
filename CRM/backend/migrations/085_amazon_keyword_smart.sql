-- 085: smarter keywords. Run after 084. Re-runnable.
--  1. Fit check: a keyword is only added to products it truly describes (size, name printing, photo, pack, year, dated,
--     monthly pages, cover, closure, pen holder, aeroplane design). Mismatches are skipped as "Doesn't fit" with the reason.
--  2. Smart apply: missing words go into hidden search words now, and for main keywords Claude also drafts a product name
--     and Item Highlights that contain the keyword (Amazon gives the name more weight). Everything waits in Decisions.
--  3. Niche per product group: Claude groups the products and gives each group its own keywords, so our products stop
--     competing with each other for the same searches.
--  4. Re-check after a change: when a name / key points / description change on Amazon, keywords that lost a word get it
--     back in hidden search words (as a Decision), and hidden words that became duplicates are freed.
--  5. Take one keyword out of a merged hidden-words Decision.  6. Swap a weak keyword out when there is no room.
--  7. Applied keywords are watched every morning automatically (max 15; finished ones rotate out).
--  8. Seasonal keywords are suggested 3 weeks before the festival and removed after it.
--  9. Item Highlights (Amazon attribute title_differentiation) count as visible words everywhere.

-- ---------------------------------------------------------------- columns / tables
ALTER TABLE public.amazon_keywords
  ADD COLUMN IF NOT EXISTS placement text NOT NULL DEFAULT 'auto',
  ADD COLUMN IF NOT EXISTS group_name text,
  ADD COLUMN IF NOT EXISTS target_skus text[],
  ADD COLUMN IF NOT EXISTS season_day date,
  ADD COLUMN IF NOT EXISTS season_applied_at timestamptz,
  ADD COLUMN IF NOT EXISTS season_removed_at timestamptz,
  ADD COLUMN IF NOT EXISTS watch_auto boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS watched_at timestamptz;
-- 072 already had a free-text "placement" (title / bullets / backend / ads, mostly empty): map it to the new places.
UPDATE public.amazon_keywords SET placement = CASE placement WHEN 'title' THEN 'name' WHEN 'bullets' THEN 'highlights' WHEN 'backend' THEN 'hidden'
  WHEN 'name' THEN 'name' WHEN 'highlights' THEN 'highlights' WHEN 'hidden' THEN 'hidden' ELSE 'auto' END
 WHERE placement IS NULL OR placement NOT IN ('auto', 'name', 'highlights', 'hidden');
ALTER TABLE public.amazon_keywords ALTER COLUMN placement SET DEFAULT 'auto', ALTER COLUMN placement SET NOT NULL;
ALTER TABLE public.amazon_keywords DROP CONSTRAINT IF EXISTS amazon_keywords_placement_check;
ALTER TABLE public.amazon_keywords ADD CONSTRAINT amazon_keywords_placement_check CHECK (placement IN ('auto', 'name', 'highlights', 'hidden'));

ALTER TABLE public.amazon_keyword_products DROP CONSTRAINT IF EXISTS amazon_keyword_products_status_check;
ALTER TABLE public.amazon_keyword_products ADD CONSTRAINT amazon_keyword_products_status_check
  CHECK (status IN ('pending', 'live', 'covered', 'no_room', 'removing', 'removed', 'rejected', 'not_fit', 'lost'));

CREATE TABLE IF NOT EXISTS public.amazon_product_groups (
  name text PRIMARY KEY,
  skus text[] NOT NULL DEFAULT '{}',
  why text,
  updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.amazon_product_groups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_product_groups FROM anon, authenticated;

ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS target_skus text[];
ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_kind_chk;
ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_kind_chk
  CHECK (kind IN ('question', 'suggest', 'chat', 'report', 'fix', 'keywords', 'market', 'kwname', 'niche'));

CREATE OR REPLACE FUNCTION crm_private.amz_kw_place_norm() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.placement := CASE NEW.placement WHEN 'title' THEN 'name' WHEN 'bullets' THEN 'highlights' WHEN 'backend' THEN 'hidden'
    WHEN 'name' THEN 'name' WHEN 'highlights' THEN 'highlights' WHEN 'hidden' THEN 'hidden' ELSE 'auto' END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_kw_place_norm ON public.amazon_keywords;
CREATE TRIGGER amz_kw_place_norm BEFORE INSERT OR UPDATE OF placement ON public.amazon_keywords
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_kw_place_norm();

-- ---------------------------------------------------------------- what a product shows and is
-- Item Highlights live in the Amazon attribute title_differentiation.
CREATE OR REPLACE FUNCTION crm_private.amz_highlights(l public.amazon_listings) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT nullif(concat_ws(' ', l.item_highlights,
    (SELECT string_agg(e->>'value', ' ') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(l.attributes->'title_differentiation') = 'array'
       THEN l.attributes->'title_differentiation' ELSE '[]' END) e)), '')
$$;

-- Words a shopper sees: name, Item Highlights, key points, description.
CREATE OR REPLACE FUNCTION crm_private.amz_visible_words(l public.amazon_listings) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT crm_private.amz_words(concat_ws(' ', l.title, crm_private.amz_highlights(l),
    (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b),
    l.description))
$$;

-- All words a listing can be found by (visible words + hidden search words).
CREATE OR REPLACE FUNCTION crm_private.amz_listing_words(l public.amazon_listings) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT crm_private.amz_visible_words(l) || crm_private.amz_words(l.backend_terms)
$$;

-- Facts used by the fit check, read from the product's own text and Amazon details.
CREATE OR REPLACE FUNCTION crm_private.amz_facts(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; t text; detail text; sz text; cover text; packs int;
BEGIN
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RETURN NULL; END IF;
  detail := (SELECT string_agg(v #>> '{}', ' ') FROM jsonb_each(coalesce(l.attributes, '{}')) e(k, val),
               jsonb_path_query(val, 'lax $.**.value') v
              WHERE k IN ('size', 'paper_size', 'special_feature', 'cover', 'material', 'binding', 'ruling_type', 'number_of_items', 'number_of_packs'));
  t := ' ' || crm_private.amz_norm(concat_ws(' ', l.title, crm_private.amz_highlights(l),
         (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b),
         l.description, detail)) || ' ';
  -- size: Amazon detail first, then the name, then any text
  sz := coalesce(
    (SELECT lower(m[1]) FROM jsonb_path_query(coalesce(l.attributes, '{}'), 'lax $.size[*].value') v,
       regexp_match(lower(v #>> '{}'), '\m(a4|a5|a6|b5)') m LIMIT 1),
    (SELECT lower(m[1]) FROM jsonb_path_query(coalesce(l.attributes, '{}'), 'lax $.paper_size[*].value') v,
       regexp_match(lower(v #>> '{}'), '\m(a4|a5|a6|b5)') m LIMIT 1),
    (regexp_match(lower(coalesce(l.title, '')), '\m(a4|a5|a6|b5)\M'))[1],
    (regexp_match(t, '\m(a4|a5|a6|b5)\M'))[1]);
  cover := lower(coalesce((SELECT v #>> '{}' FROM jsonb_path_query(coalesce(l.attributes, '{}'), 'lax $.cover[*].material[*].value') v LIMIT 1), ''));
  packs := greatest(1,
    coalesce((SELECT (v #>> '{}')::int FROM jsonb_path_query(coalesce(l.attributes, '{}'), 'lax $.number_of_items[*].value') v
               WHERE (v #>> '{}') ~ '^\d{1,2}$' LIMIT 1), 1),
    coalesce(((regexp_match(t, '(pack|set) of (\d{1,2})'))[2])::int, 1));
  RETURN jsonb_build_object(
    'size', sz,
    'personal', t ~ '(personali[sz]ed|personali[sz]ation|personalise|customi[sz]ed|customi[sz]able|customise|customize|custom name|with name|name printed|your name|name embossing|name engraving|name or text|printed with your)',
    'photo', t ~ '\mphoto',
    'pack', packs,
    'undated', t ~ '\mundated\M',
    'years', coalesce((SELECT jsonb_agg(DISTINCT m[1]) FROM regexp_matches(t, '\m(20[2-3]\d)\M', 'g') m), '[]'),
    'monthly', t ~ '\mmonthly\M|\mmonth\M',
    'leather', CASE WHEN cover ~ '(paper|pvc|polyvinyl)' AND cover !~ 'leather' THEN false ELSE t ~ '(leather|leatherette|\mpu\M)' END,
    'magnetic', t ~ 'magnet',
    'elastic', t ~ 'elastic',
    'pen', t ~ '\mpen (holder|loop)',
    'aero', t ~ '(aeroplane|airplane|aviation|aircraft|pilot)',
    'spiral', t ~ 'spiral',
    'photo_or_name', t ~ '\mphoto' OR t ~ '(personali|customi)');
END $$;

-- NULL = the keyword fits this product; otherwise a short reason (shown to the owner).
CREATE OR REPLACE FUNCTION crm_private.amz_kw_fit(p_sku text, p_keyword text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE f jsonb := crm_private.amz_facts(p_sku); k text := ' ' || crm_private.amz_norm(p_keyword) || ' '; m text[]; y text; n int;
BEGIN
  IF f IS NULL THEN RETURN 'Product not found'; END IF;
  m := regexp_match(k, '\m(a4|a5|a6|b5)\M');
  IF m IS NOT NULL THEN
    IF f->>'size' IS NULL THEN RETURN 'Size is not stated on this product, so a size keyword could mislead'; END IF;
    IF f->>'size' <> m[1] THEN RETURN format('This is a %s diary; the keyword says %s', upper(f->>'size'), upper(m[1])); END IF;
  END IF;
  IF k ~ '(personali|customi|\mcustom\M|\mname\M|monogram|initials|engrav)' AND NOT (f->>'personal')::boolean THEN
    RETURN 'This product does not say it can carry a name';
  END IF;
  IF k ~ '\mphoto' AND NOT (f->>'photo')::boolean THEN RETURN 'No photo printing on this product'; END IF;
  m := regexp_match(k, '(set|pack) of (\d{1,2})');
  n := CASE WHEN m IS NOT NULL THEN m[2]::int WHEN k ~ '(\mcombo\M|\mpair\M|\m2 pack\M|\mtwin\M)' THEN 2 END;
  IF n IS NOT NULL AND (f->>'pack')::int < n THEN RETURN 'This is a single diary, not a set'; END IF;
  FOR y IN SELECT x[1] FROM regexp_matches(k, '\m(20[2-3]\d)\M', 'g') x LOOP
    IF (f->>'undated')::boolean THEN RETURN 'Undated diary: a year in the keyword would mislead'; END IF;
    IF NOT (f->'years') ? y THEN RETURN format('This product is not for %s', y); END IF;
  END LOOP;
  IF k ~ '\mundated\M' AND NOT (f->>'undated')::boolean THEN RETURN 'This diary is dated'; END IF;
  IF k ~ '\mdated\M' AND (f->>'undated')::boolean THEN RETURN 'This diary is undated'; END IF;
  IF k ~ '\mmonthly\M' AND NOT (f->>'monthly')::boolean THEN RETURN 'No monthly planner pages stated'; END IF;
  IF k ~ 'leather' AND NOT (f->>'leather')::boolean THEN RETURN 'Cover is not leather or faux leather'; END IF;
  IF k ~ 'magnet' AND NOT (f->>'magnetic')::boolean THEN RETURN 'No magnetic closure'; END IF;
  IF k ~ 'elastic' AND NOT (f->>'elastic')::boolean THEN RETURN 'No elastic band'; END IF;
  IF k ~ '\mpen\M' AND NOT (f->>'pen')::boolean THEN RETURN 'No pen holder'; END IF;
  IF k ~ '(aeroplane|airplane|aviation|aircraft|pilot|aviator)' AND NOT (f->>'aero')::boolean THEN RETURN 'No aeroplane / aviation design'; END IF;
  IF k ~ 'spiral' AND NOT (f->>'spiral')::boolean THEN RETURN 'Not spiral-bound'; END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------- auto-watch
-- Applied keywords are watched every morning, so their 14-day result is measured. Max 15; an auto-watched keyword
-- that has been watched for 15+ days (result known) makes room.
CREATE OR REPLACE FUNCTION crm_private.amz_kw_autowatch(p_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE out_id bigint;
BEGIN
  IF (SELECT track FROM public.amazon_keywords WHERE id = p_id) THEN RETURN true; END IF;
  IF (SELECT count(*) FROM public.amazon_keywords WHERE track) >= 15 THEN
    SELECT id INTO out_id FROM public.amazon_keywords WHERE track AND watch_auto AND watched_at < now() - interval '15 days'
     ORDER BY watched_at LIMIT 1;
    IF out_id IS NULL THEN RETURN false; END IF;
    UPDATE public.amazon_keywords SET track = false, watch_auto = false, updated_at = now() WHERE id = out_id;
  END IF;
  UPDATE public.amazon_keywords SET track = true, watch_auto = true, watched_at = now(), updated_at = now() WHERE id = p_id;
  RETURN true;
END $$;

-- ---------------------------------------------------------------- hidden words (now fit-checked)
CREATE OR REPLACE FUNCTION crm_private.amz_kw_apply(p_id bigint, p_skus text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; l public.amazon_listings; cur text; nxt text; vis text[]; cid uuid; why text;
  drafted int := 0; covered int := 0; noroom int := 0; notfit int := 0; base int;
BEGIN
  SELECT * INTO k FROM public.amazon_keywords WHERE id = p_id;
  IF k.id IS NULL THEN RAISE EXCEPTION 'Keyword not found' USING ERRCODE = 'PT404'; END IF;
  FOR l IN SELECT * FROM public.amazon_listings WHERE sku = ANY (p_skus) AND NOT is_parent LOOP
    why := crm_private.amz_kw_fit(l.sku, k.keyword);
    IF why IS NOT NULL THEN
      INSERT INTO public.amazon_keyword_products AS kp (keyword_id, sku, status, detail, updated_at)
      VALUES (p_id, l.sku, 'not_fit', 'Doesn''t fit: ' || why, now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'not_fit', detail = EXCLUDED.detail, change_id = NULL, updated_at = now()
       WHERE kp.status NOT IN ('live', 'pending', 'removing');
      notfit := notfit + 1;
      CONTINUE;
    END IF;
    cur := crm_private.amz_pending_backend(l.sku);
    vis := crm_private.amz_visible_words(l);
    nxt := crm_private.amz_backend_add(cur, k.keyword, vis);
    base := (SELECT (r.my_ranks->>l.asin)::int FROM public.amazon_rank_daily r WHERE r.keyword_id = p_id ORDER BY r.day DESC LIMIT 1);
    IF nxt IS NULL THEN
      INSERT INTO public.amazon_keyword_products AS kp (keyword_id, sku, status, detail, updated_at)
      VALUES (p_id, l.sku, 'no_room', format('No room: hidden search words would pass %s bytes. Swap out a weaker keyword.', crm_private.amz_backend_max()), now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'no_room', detail = EXCLUDED.detail, change_id = NULL, updated_at = now()
       WHERE kp.status NOT IN ('live', 'pending', 'removing');
      noroom := noroom + 1;
    ELSIF crm_private.amz_norm(nxt) = crm_private.amz_norm(cur) THEN
      INSERT INTO public.amazon_keyword_products AS kp (keyword_id, sku, status, detail, baseline_rank, applied_at, updated_at)
      VALUES (p_id, l.sku, 'covered', 'Already findable: every word is in the name, highlights, key points or hidden search words.', base, now(), now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'covered', detail = EXCLUDED.detail, updated_at = now()
       WHERE kp.status NOT IN ('live', 'pending', 'removing');
      covered := covered + 1;
    ELSE
      cid := crm_private.amz_kw_draft(l.sku, nxt, '+ ' || k.keyword);
      IF cid IS NULL THEN CONTINUE; END IF;
      INSERT INTO public.amazon_keyword_products (keyword_id, sku, status, change_id, detail, baseline_rank, updated_at)
      VALUES (p_id, l.sku, 'pending', cid, 'Waiting in Decisions', base, now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'pending', change_id = cid, detail = 'Waiting in Decisions',
        baseline_rank = coalesce(public.amazon_keyword_products.baseline_rank, base), updated_at = now();
      drafted := drafted + 1;
    END IF;
  END LOOP;
  IF drafted + covered > 0 THEN PERFORM crm_private.amz_kw_autowatch(p_id); END IF;
  RETURN jsonb_build_object('drafted', drafted, 'covered', covered, 'no_room', noroom, 'not_fit', notfit);
END $$;

-- ---------------------------------------------------------------- Claude: names that carry a keyword
CREATE OR REPLACE FUNCTION crm_private.amz_kw_name_request(p_id bigint, p_skus text[], p_by uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint; kw text := (SELECT keyword FROM public.amazon_keywords WHERE id = p_id); skus text[];
BEGIN
  skus := ARRAY(SELECT sku FROM public.amazon_listings WHERE sku = ANY (p_skus) AND NOT is_parent
                   AND crm_private.amz_kw_fit(sku, kw) IS NULL ORDER BY sku LIMIT 27);
  IF cardinality(skus) = 0 THEN RETURN NULL; END IF;
  SELECT id INTO rid FROM public.amazon_claude_requests WHERE kind = 'kwname' AND field = p_id::text AND status IN ('waiting', 'working') LIMIT 1;
  IF rid IS NOT NULL THEN
    UPDATE public.amazon_claude_requests SET target_skus = ARRAY(SELECT DISTINCT unnest(coalesce(target_skus, '{}') || skus))
     WHERE id = rid AND status = 'waiting';
    RETURN rid;
  END IF;
  INSERT INTO public.amazon_claude_requests (question, kind, field, target_skus, asked_by)
  VALUES (format('Put the keyword "%s" into the product name and Item Highlights of %s product%s.', kw, cardinality(skus),
          CASE WHEN cardinality(skus) = 1 THEN '' ELSE 's' END), 'kwname', p_id::text, skus, p_by)
  RETURNING id INTO rid;
  RETURN rid;
END $$;

-- Is this keyword worth a place in the product name?
CREATE OR REPLACE FUNCTION crm_private.amz_kw_main(k public.amazon_keywords) RETURNS boolean
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT k.placement IN ('name', 'highlights')
      OR (k.placement = 'auto' AND (k.group_name IS NOT NULL OR k.track
          OR (coalesce(k.competitors_total, 0) > 0 AND k.competitor_count::numeric / k.competitors_total >= 0.2)))
$$;

-- ---------------------------------------------------------------- browser API
-- Smart apply: fit check -> hidden words now (Decisions) -> for main keywords, Claude drafts names + Item Highlights.
CREATE OR REPLACE FUNCTION public.api_amz_keyword_smart(p_id bigint, p_skus text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; skus text[]; r jsonb := '{}'; rid bigint; naming text[];
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO k FROM public.amazon_keywords WHERE id = p_id;
  IF k.id IS NULL THEN RAISE EXCEPTION 'Keyword not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.amz_kw_check(k.keyword);
  skus := coalesce(p_skus, k.target_skus, ARRAY(SELECT crm_private.amz_kw_skus()));
  IF cardinality(skus) = 0 THEN RAISE EXCEPTION 'Choose at least one product' USING ERRCODE = 'PT422'; END IF;
  IF k.placement <> 'name' THEN r := crm_private.amz_kw_apply(p_id, skus); END IF;
  IF crm_private.amz_kw_main(k) THEN
    -- products that fit but do not show every word of the keyword in the name yet
    naming := ARRAY(SELECT l.sku FROM public.amazon_listings l WHERE l.sku = ANY (skus) AND NOT l.is_parent
                      AND crm_private.amz_kw_fit(l.sku, k.keyword) IS NULL
                      AND NOT (ARRAY(SELECT w FROM unnest(crm_private.amz_words(k.keyword)) w WHERE NOT crm_private.amz_stopword(w))
                               <@ crm_private.amz_words(concat_ws(' ', l.title, crm_private.amz_highlights(l)))));
    IF cardinality(naming) > 0 THEN rid := crm_private.amz_kw_name_request(p_id, naming, crm_private.current_employee_id()); END IF;
  END IF;
  UPDATE public.amazon_keywords SET status = 'pinned', apply_future = CASE WHEN p_skus IS NULL AND k.target_skus IS NULL THEN true ELSE apply_future END,
    updated_at = now() WHERE id = p_id;
  PERFORM crm_private.amz_kw_autowatch(p_id);
  PERFORM crm_private.amz_log('keyword_smart_applied', 'keyword', p_id::text, r || jsonb_build_object('products', cardinality(skus), 'naming', coalesce(cardinality(naming), 0)));
  RETURN r || jsonb_build_object('naming', CASE WHEN rid IS NULL THEN 0 ELSE cardinality(naming) END, 'request', rid,
    'mac_online', coalesce((SELECT nullif(value, '')::timestamptz FROM public.amazon_config WHERE key = 'bridge_seen_at') > now() - interval '90 seconds', false));
END $$;

-- "Hidden words only" (the old behaviour, now fit-checked and auto-watched).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_apply(p_id bigint, p_skus text[] DEFAULT NULL, p_future boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; skus text[];
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  PERFORM crm_private.amz_kw_check((SELECT keyword FROM public.amazon_keywords WHERE id = p_id));
  skus := coalesce(p_skus, ARRAY(SELECT crm_private.amz_kw_skus()));
  IF cardinality(skus) = 0 THEN RAISE EXCEPTION 'Choose at least one product' USING ERRCODE = 'PT422'; END IF;
  r := crm_private.amz_kw_apply(p_id, skus);
  UPDATE public.amazon_keywords SET status = 'pinned', apply_future = CASE WHEN p_skus IS NULL THEN coalesce(p_future, false) ELSE apply_future END,
    updated_at = now() WHERE id = p_id;
  PERFORM crm_private.amz_log('keyword_applied', 'keyword', p_id::text, r || jsonb_build_object('products', cardinality(skus)));
  RETURN r;
END $$;

-- "Suggest better name": Claude drafts names (+ Item Highlights) that contain the keyword, for products it fits.
CREATE OR REPLACE FUNCTION public.api_amz_keyword_name(p_id bigint, p_skus text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; skus text[]; rid bigint; fit int; total int;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO k FROM public.amazon_keywords WHERE id = p_id;
  IF k.id IS NULL THEN RAISE EXCEPTION 'Keyword not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.amz_kw_check(k.keyword);
  skus := coalesce(p_skus, k.target_skus, ARRAY(SELECT crm_private.amz_kw_skus()));
  total := cardinality(skus);
  fit := (SELECT count(*) FROM unnest(skus) s WHERE crm_private.amz_kw_fit(s, k.keyword) IS NULL);
  IF fit = 0 THEN RAISE EXCEPTION 'This keyword does not fit any of the chosen products' USING ERRCODE = 'PT422'; END IF;
  rid := crm_private.amz_kw_name_request(p_id, skus, crm_private.current_employee_id());
  RETURN jsonb_build_object('request', rid, 'naming', fit, 'not_fit', total - fit);
END $$;

-- Which chosen products the keyword fits (for the product picker).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_fit(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE kw text := (SELECT keyword FROM public.amazon_keywords WHERE id = p_id);
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_object_agg(sku, crm_private.amz_kw_fit(sku, kw)) FROM public.amazon_listings WHERE NOT is_parent), '{}');
END $$;

-- Where a keyword should go.
CREATE OR REPLACE FUNCTION public.api_amz_keyword_placement(p_id bigint, p_placement text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_placement NOT IN ('auto', 'name', 'highlights', 'hidden') THEN RAISE EXCEPTION 'Unknown place' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.amazon_keywords SET placement = p_placement, updated_at = now() WHERE id = p_id;
END $$;

-- Take one keyword out of a waiting hidden-words Decision (the other keywords in it stay).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_drop(p_change uuid, p_keyword_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; kp public.amazon_keyword_products; nxt text; live text; kw text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO q FROM public.amazon_change_queue WHERE id = p_change FOR UPDATE;
  IF q.id IS NULL OR q.status <> 'pending' OR NOT (q.after ? 'backend_terms') THEN
    RAISE EXCEPTION 'This Decision is no longer waiting' USING ERRCODE = 'PT409';
  END IF;
  SELECT * INTO kp FROM public.amazon_keyword_products WHERE keyword_id = p_keyword_id AND change_id = p_change AND status IN ('pending', 'removing') FOR UPDATE;
  IF kp.keyword_id IS NULL THEN RAISE EXCEPTION 'That keyword is not in this Decision' USING ERRCODE = 'PT404'; END IF;
  kw := (SELECT keyword FROM public.amazon_keywords WHERE id = p_keyword_id);
  live := (SELECT backend_terms FROM public.amazon_listings WHERE sku = q.sku);
  IF kp.status = 'pending' THEN
    -- words other pending/live keywords of this product need are kept (this keyword's own row is excluded)
    nxt := crm_private.amz_backend_remove(q.after->>'backend_terms', p_keyword_id, q.sku);
    -- words that were already live stay live
    nxt := btrim(nxt || ' ' || coalesce((SELECT string_agg(w, ' ') FROM unnest(crm_private.amz_words(kw)) w
             WHERE w = ANY (crm_private.amz_words(live)) AND NOT w = ANY (crm_private.amz_words(nxt))), ''));
    UPDATE public.amazon_keyword_products SET status = 'rejected', change_id = NULL, detail = 'Taken out of the Decision by you', updated_at = now()
     WHERE keyword_id = p_keyword_id AND sku = q.sku;
  ELSE
    -- a removal taken out: put its words back
    nxt := crm_private.amz_backend_add(q.after->>'backend_terms', kw, '{}');
    IF nxt IS NULL THEN RAISE EXCEPTION 'No room to keep it' USING ERRCODE = 'PT422'; END IF;
    UPDATE public.amazon_keyword_products SET status = 'live', change_id = NULL, detail = 'Kept (removal taken out)', updated_at = now()
     WHERE keyword_id = p_keyword_id AND sku = q.sku;
  END IF;
  IF crm_private.amz_norm(nxt) = crm_private.amz_norm(live) THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', reject_reason = 'Nothing left to change', updated_at = now() WHERE id = q.id;
    RETURN jsonb_build_object('cancelled', true);
  END IF;
  UPDATE public.amazon_change_queue SET after = jsonb_build_object('backend_terms', nxt),
    reason = left(q.reason || '; taken out: ' || kw, 600), updated_at = now() WHERE id = q.id;
  RETURN jsonb_build_object('cancelled', false, 'backend_terms', nxt);
END $$;

-- Swap: take a weaker keyword out of a product's hidden words to make room for this one (one Decision).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_swap(p_id bigint, p_sku text, p_out bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; kw text; outkw text; cur text; mid text; nxt text; cid uuid; outst text; why text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  kw := (SELECT keyword FROM public.amazon_keywords WHERE id = p_id);
  outkw := (SELECT keyword FROM public.amazon_keywords WHERE id = p_out);
  IF l.sku IS NULL OR kw IS NULL OR outkw IS NULL OR p_id = p_out THEN RAISE EXCEPTION 'Not found' USING ERRCODE = 'PT404'; END IF;
  why := crm_private.amz_kw_fit(p_sku, kw);
  IF why IS NOT NULL THEN RAISE EXCEPTION 'Doesn''t fit: %', why USING ERRCODE = 'PT422'; END IF;
  outst := (SELECT status FROM public.amazon_keyword_products WHERE keyword_id = p_out AND sku = p_sku);
  IF outst NOT IN ('live', 'pending') THEN RAISE EXCEPTION '"%" is not in this product''s hidden words', outkw USING ERRCODE = 'PT422'; END IF;
  cur := crm_private.amz_pending_backend(p_sku);
  -- mark the outgoing keyword first so its words are not protected by its own row
  UPDATE public.amazon_keyword_products SET status = 'removed' WHERE keyword_id = p_out AND sku = p_sku;
  mid := crm_private.amz_backend_remove(cur, p_out, p_sku);
  nxt := crm_private.amz_backend_add(mid, kw, crm_private.amz_visible_words(l));
  IF nxt IS NULL THEN RAISE EXCEPTION 'Still no room after taking "%" out', outkw USING ERRCODE = 'PT422'; END IF;
  cid := crm_private.amz_kw_draft(p_sku, nxt, '- ' || outkw || ' + ' || kw || ' (swap)');
  UPDATE public.amazon_keyword_products SET status = CASE WHEN outst = 'live' THEN 'removing' ELSE 'removed' END,
    change_id = CASE WHEN outst = 'live' THEN cid END,
    detail = CASE WHEN outst = 'live' THEN 'Swapped out (waiting in Decisions)' ELSE 'Swapped out before it went live' END, updated_at = now()
   WHERE keyword_id = p_out AND sku = p_sku;
  INSERT INTO public.amazon_keyword_products (keyword_id, sku, status, change_id, detail, updated_at)
  VALUES (p_id, p_sku, 'pending', cid, 'Swapped in (waiting in Decisions)', now())
  ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'pending', change_id = cid, detail = EXCLUDED.detail, updated_at = now();
  PERFORM crm_private.amz_kw_autowatch(p_id);
  RETURN jsonb_build_object('change', cid);
END $$;

-- Ask Claude to group the products and give each group its own keywords.
CREATE OR REPLACE FUNCTION public.api_amz_keyword_niche() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT id INTO rid FROM public.amazon_claude_requests WHERE kind = 'niche' AND status IN ('waiting', 'working') LIMIT 1;
  IF rid IS NULL THEN
    INSERT INTO public.amazon_claude_requests (question, kind, asked_by)
    VALUES ('Group my products and give each group its own search keywords.', 'niche', crm_private.current_employee_id()) RETURNING id INTO rid;
  END IF;
  RETURN jsonb_build_object('id', rid);
END $$;

-- ---------------------------------------------------------------- removing a keyword (shared by the browser and the season job)
CREATE OR REPLACE FUNCTION crm_private.amz_kw_remove(p_id bigint, p_skus text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE kp public.amazon_keyword_products; cur text; nxt text; cid uuid; n int := 0; in_name int := 0; l public.amazon_listings;
  kw text := (SELECT keyword FROM public.amazon_keywords WHERE id = p_id);
BEGIN
  FOR kp IN SELECT * FROM public.amazon_keyword_products WHERE keyword_id = p_id AND (p_skus IS NULL OR sku = ANY (p_skus))
              AND status IN ('pending', 'live', 'covered', 'no_room', 'rejected', 'not_fit', 'lost') FOR UPDATE LOOP
    IF kp.status IN ('covered', 'no_room', 'rejected', 'not_fit', 'lost') THEN
      UPDATE public.amazon_keyword_products SET status = 'removed', detail = 'Removed from the list', updated_at = now()
       WHERE keyword_id = p_id AND sku = kp.sku;
      CONTINUE;
    END IF;
    cur := crm_private.amz_pending_backend(kp.sku);
    nxt := crm_private.amz_backend_remove(cur, p_id, kp.sku);
    SELECT * INTO l FROM public.amazon_listings WHERE sku = kp.sku;
    IF crm_private.amz_words(kw) <@ crm_private.amz_visible_words(l) THEN in_name := in_name + 1; END IF;
    IF crm_private.amz_norm(nxt) = crm_private.amz_norm(cur) THEN
      UPDATE public.amazon_keyword_products SET status = 'removed', detail = 'Nothing to remove from hidden search words', updated_at = now()
       WHERE keyword_id = p_id AND sku = kp.sku;
      CONTINUE;
    END IF;
    cid := crm_private.amz_kw_draft(kp.sku, nxt, '- ' || kw);
    UPDATE public.amazon_keyword_products SET status = CASE WHEN kp.status = 'pending' AND kp.change_id = cid THEN 'removed' ELSE 'removing' END,
      change_id = cid, detail = CASE WHEN kp.status = 'pending' AND kp.change_id = cid THEN 'Taken out of the waiting Decision' ELSE 'Removal waiting in Decisions' END,
      updated_at = now() WHERE keyword_id = p_id AND sku = kp.sku;
    n := n + 1;
  END LOOP;
  UPDATE public.amazon_change_queue q SET status = 'cancelled', updated_at = now()
   FROM public.amazon_listings li
   WHERE q.sku = li.sku AND q.status = 'pending' AND q.created_by_type = 'system' AND q.reason LIKE 'Keywords:%'
     AND crm_private.amz_norm(q.after->>'backend_terms') = crm_private.amz_norm(li.backend_terms);
  PERFORM crm_private.amz_log('keyword_removed', 'keyword', p_id::text, jsonb_build_object('products', n));
  RETURN jsonb_build_object('changed', n, 'still_in_name', in_name);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keyword_remove(p_id bigint, p_skus text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  RETURN crm_private.amz_kw_remove(p_id, p_skus);
END $$;

-- ---------------------------------------------------------------- re-check after a product changes on Amazon
CREATE OR REPLACE FUNCTION crm_private.amz_kw_recheck(p_sku text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; vis text[]; cur text; nxt text; kp record; need text[]; cid uuid; back int := 0; lost int := 0; dup text[];
BEGIN
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL OR l.is_parent THEN RETURN NULL; END IF;
  vis := crm_private.amz_visible_words(l);
  FOR kp IN SELECT p.*, k.keyword FROM public.amazon_keyword_products p JOIN public.amazon_keywords k ON k.id = p.keyword_id
             WHERE p.sku = p_sku AND p.status IN ('covered', 'live') LOOP
    cur := crm_private.amz_pending_backend(p_sku);
    need := ARRAY(SELECT w FROM unnest(crm_private.amz_words(kp.keyword)) w WHERE NOT crm_private.amz_stopword(w));
    CONTINUE WHEN need <@ (vis || crm_private.amz_words(cur));
    nxt := crm_private.amz_backend_add(cur, kp.keyword, vis);
    IF nxt IS NULL THEN
      UPDATE public.amazon_keyword_products SET status = 'lost', change_id = NULL,
        detail = 'Lost after a name/text change and no room in hidden words. Swap out a weaker keyword.', updated_at = now()
       WHERE keyword_id = kp.keyword_id AND sku = p_sku;
      lost := lost + 1;
    ELSE
      cid := crm_private.amz_kw_draft(p_sku, nxt, '+ ' || kp.keyword || ' (lost after a name change)');
      UPDATE public.amazon_keyword_products SET status = 'pending', change_id = cid,
        detail = 'Lost after a name/text change: adding it back (waiting in Decisions)', updated_at = now()
       WHERE keyword_id = kp.keyword_id AND sku = p_sku;
      back := back + 1;
    END IF;
  END LOOP;
  -- hidden words that now appear in the name / highlights / key points / description only waste bytes
  cur := crm_private.amz_pending_backend(p_sku);
  dup := ARRAY(SELECT w FROM unnest(crm_private.amz_words(cur)) w WHERE w = ANY (vis));
  IF cardinality(dup) >= 3 THEN
    nxt := (SELECT coalesce(string_agg(w, ' ' ORDER BY o), '') FROM regexp_split_to_table(crm_private.amz_norm(cur), ' ') WITH ORDINALITY t(w, o)
             WHERE w <> '' AND NOT w = ANY (dup));
    PERFORM crm_private.amz_kw_draft(p_sku, nxt, 'free space: ' || cardinality(dup) || ' words are now visible on the page');
  END IF;
  RETURN jsonb_build_object('added_back', back, 'lost', lost, 'freed', CASE WHEN cardinality(dup) >= 3 THEN cardinality(dup) ELSE 0 END);
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_kw_recheck_trg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  BEGIN
    PERFORM crm_private.amz_kw_recheck(NEW.sku);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'keyword re-check skipped for %: %', NEW.sku, SQLERRM;   -- never break the listing sync
  END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_kw_recheck ON public.amazon_listings;
CREATE TRIGGER amz_kw_recheck AFTER UPDATE ON public.amazon_listings FOR EACH ROW
  WHEN (OLD.title IS DISTINCT FROM NEW.title OR OLD.bullets IS DISTINCT FROM NEW.bullets OR OLD.description IS DISTINCT FROM NEW.description
        OR OLD.item_highlights IS DISTINCT FROM NEW.item_highlights
        OR OLD.attributes->'title_differentiation' IS DISTINCT FROM NEW.attributes->'title_differentiation')
  EXECUTE FUNCTION crm_private.amz_kw_recheck_trg();

-- ---------------------------------------------------------------- seasons: suggest 21..4 days before, remove 3 days after
CREATE OR REPLACE FUNCTION public.svc_amz_keyword_seasons() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; r jsonb; added int := 0; removed int := 0;
BEGIN
  FOR k IN SELECT * FROM public.amazon_keywords WHERE season_day IS NOT NULL AND status <> 'rejected' FOR UPDATE LOOP
    IF today BETWEEN k.season_day - 21 AND k.season_day - 4
       AND (k.season_applied_at IS NULL OR k.season_applied_at < (k.season_day - 60)::timestamptz) THEN
      r := crm_private.amz_kw_apply(k.id, coalesce(k.target_skus, ARRAY(SELECT crm_private.amz_kw_skus())));
      UPDATE public.amazon_keywords SET season_applied_at = now(), status = 'pinned', updated_at = now() WHERE id = k.id;
      PERFORM crm_private.amz_log('keyword_season_added', 'keyword', k.id::text, r);
      added := added + 1;
    ELSIF today > k.season_day + 3 THEN
      IF k.season_applied_at IS NOT NULL AND (k.season_removed_at IS NULL OR k.season_removed_at < k.season_applied_at) THEN
        r := crm_private.amz_kw_remove(k.id, NULL);
        PERFORM crm_private.amz_log('keyword_season_removed', 'keyword', k.id::text, r);
        removed := removed + 1;
      END IF;
      -- same festival next year
      UPDATE public.amazon_keywords SET season_removed_at = CASE WHEN season_applied_at IS NOT NULL THEN now() ELSE season_removed_at END,
        season_day = (season_day + interval '1 year')::date, updated_at = now() WHERE id = k.id;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('added', added, 'removed', removed);
END $$;

-- Festival keywords and their day (fixed-date festivals; lunar ones are set in amazon_festivals each year).
UPDATE public.amazon_keywords SET season_day = '2026-12-25' WHERE lower(keyword) IN ('christmas gift diary', 'secret santa gift') AND season_day IS NULL;
UPDATE public.amazon_keywords SET season_day = '2027-01-01' WHERE lower(keyword) IN ('new year gift diary') AND season_day IS NULL;
UPDATE public.amazon_keywords SET season_day = '2026-11-14' WHERE lower(keyword) IN ('childrens day gift diary') AND season_day IS NULL;

-- ---------------------------------------------------------------- Keywords section data
CREATE OR REPLACE FUNCTION public.api_amz_keywords() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'byte_limit', crm_private.amz_backend_max(),
    'can_apply', crm_private.amz_can_approve(),
    'watched', (SELECT count(*) FROM public.amazon_keywords WHERE track),
    'groups', coalesce((SELECT jsonb_agg(jsonb_build_object('name', g.name, 'skus', g.skus, 'why', g.why) ORDER BY g.name) FROM public.amazon_product_groups g), '[]'),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent_asin', l.parent_asin, 'title', l.title,
        'image', (SELECT i->>'url' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(l.images) = 'array' THEN l.images ELSE '[]' END) i ORDER BY (i->>'slot' = 'main') DESC LIMIT 1),
        'color', l.attributes->'color'->0->>'value',
        'group', (SELECT g.name FROM public.amazon_product_groups g WHERE l.sku = ANY (g.skus) LIMIT 1),
        'bytes', octet_length(coalesce(crm_private.amz_pending_backend(l.sku), ''))) ORDER BY l.parent_asin NULLS LAST, l.title)
      FROM public.amazon_listings l WHERE NOT l.is_parent), '[]'),
    'keywords', coalesce((WITH lw AS (SELECT crm_private.amz_listing_words(l) words FROM public.amazon_listings l WHERE NOT l.is_parent)
      SELECT jsonb_agg(x ORDER BY x->>'sort') FROM (
      SELECT jsonb_build_object('id', k.id, 'keyword', k.keyword, 'source', k.source, 'kind', k.kind, 'why', k.why, 'status', k.status,
        'track', k.track, 'watch_auto', k.watch_auto, 'apply_future', k.apply_future, 'competitor_count', k.competitor_count, 'competitors_total', k.competitors_total,
        'placement', k.placement, 'group_name', k.group_name, 'target_skus', k.target_skus, 'season_day', k.season_day,
        'main', crm_private.amz_kw_main(k),
        'naming', EXISTS (SELECT 1 FROM public.amazon_claude_requests c WHERE c.kind = 'kwname' AND c.field = k.id::text AND c.status IN ('waiting', 'working')),
        'bytes', octet_length(k.keyword),
        'findable', (SELECT count(*) FROM lw WHERE ARRAY(SELECT w FROM unnest(crm_private.amz_words(k.keyword)) w WHERE NOT crm_private.amz_stopword(w)) <@ lw.words),
        'rank_today', r.my_best_rank, 'rank_week_ago', r7.my_best_rank, 'had_week', r7.day IS NOT NULL, 'checked', r.day,
        'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', kp.sku, 'status', kp.status, 'detail', kp.detail, 'change_id', kp.change_id,
            'baseline_rank', kp.baseline_rank, 'applied_at', kp.applied_at,
            'rank_now', (SELECT (rr.my_ranks->>l2.asin)::int FROM public.amazon_rank_daily rr WHERE rr.keyword_id = k.id ORDER BY rr.day DESC LIMIT 1),
            'effect', CASE WHEN kp.status <> 'live' OR kp.applied_at IS NULL THEN NULL
                           WHEN kp.applied_at > now() - interval '14 days' THEN 'too_early'
                           WHEN coalesce((SELECT (rr.my_ranks->>l2.asin)::int FROM public.amazon_rank_daily rr WHERE rr.keyword_id = k.id ORDER BY rr.day DESC LIMIT 1), 99)
                                < coalesce(kp.baseline_rank, 99) THEN 'working' ELSE 'no_effect' END,
            -- the weakest keyword in this product's hidden words, offered as a swap when there is no room
            'swap', CASE WHEN kp.status IN ('no_room', 'lost') THEN (
              SELECT jsonb_build_object('id', k2.id, 'keyword', k2.keyword)
                FROM public.amazon_keyword_products o JOIN public.amazon_keywords k2 ON k2.id = o.keyword_id
               WHERE o.sku = kp.sku AND o.status IN ('live', 'pending') AND o.keyword_id <> k.id
                 AND crm_private.amz_words(k2.keyword) && crm_private.amz_words(crm_private.amz_pending_backend(kp.sku))
               ORDER BY (o.status = 'live' AND o.applied_at < now() - interval '14 days'
                         AND coalesce((SELECT (rr.my_ranks->>l2.asin)::int FROM public.amazon_rank_daily rr WHERE rr.keyword_id = k2.id ORDER BY rr.day DESC LIMIT 1), 99)
                             >= coalesce(o.baseline_rank, 99)) DESC,
                        coalesce(k2.competitor_count, 0), k2.track, o.updated_at
               LIMIT 1) END))
          FROM public.amazon_keyword_products kp JOIN public.amazon_listings l2 ON l2.sku = kp.sku WHERE kp.keyword_id = k.id), '[]'),
        'sort', CASE k.status WHEN 'pinned' THEN '1' WHEN 'candidate' THEN '2' ELSE '3' END || lpad((999 - coalesce(k.competitor_count, 0))::text, 3, '0') || k.keyword)
      FROM public.amazon_keywords k
      LEFT JOIN public.amazon_rank_daily r ON r.keyword_id = k.id AND r.day = (SELECT max(day) FROM public.amazon_rank_daily WHERE keyword_id = k.id)
      LEFT JOIN public.amazon_rank_daily r7 ON r7.keyword_id = k.id AND r7.day = r.day - 7) s(x)), '[]'),
    'claude_running', EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind IN ('keywords', 'niche', 'kwname') AND status IN ('waiting', 'working')),
    'niche_running', EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind = 'niche' AND status IN ('waiting', 'working')),
    'ideas_running', EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind = 'keywords' AND status IN ('waiting', 'working')),
    'today', today);
END $$;

-- ---------------------------------------------------------------- Decisions list: which keywords are inside each change
CREATE OR REPLACE FUNCTION public.api_amz_decisions(p_status text DEFAULT 'open') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort') FROM (
    SELECT to_jsonb(q) || jsonb_build_object(
             'photo', l.images->0->>'url', 'product', l.title,
             'keywords', (SELECT jsonb_agg(jsonb_build_object('id', k.id, 'keyword', k.keyword, 'status', kp.status) ORDER BY k.keyword)
                            FROM public.amazon_keyword_products kp JOIN public.amazon_keywords k ON k.id = kp.keyword_id
                           WHERE kp.change_id = q.id AND kp.status IN ('pending', 'removing')),
             'sort', CASE q.status WHEN 'pending' THEN '0' WHEN 'needs_manual' THEN '1' WHEN 'failed' THEN '2' WHEN 'stale' THEN '3' ELSE '9' END
               || to_char(9999999999 - extract(epoch FROM q.created_at), 'FM0000000000')) x
      FROM public.amazon_change_queue q LEFT JOIN public.amazon_listings l ON l.sku = q.sku
     WHERE CASE coalesce(p_status, 'open')
             WHEN 'open' THEN q.status IN ('pending', 'approved', 'executing', 'needs_manual', 'failed', 'stale')
             WHEN 'done' THEN q.status IN ('live')
             WHEN 'rejected' THEN q.status IN ('rejected', 'cancelled')
             ELSE true END
       AND q.created_at > now() - interval '60 days'
     ORDER BY q.created_at DESC LIMIT 300) s), '[]');
END $$;

-- ---------------------------------------------------------------- Claude bridge: new jobs (names with a keyword, niche plan)
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_claim(p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; ctx jsonb;
BEGIN
  UPDATE public.amazon_claude_requests SET status = 'waiting', note = 'Retrying after a pause.'
   WHERE status = 'working' AND claimed_at < now() - interval '10 minutes';
  SELECT * INTO r FROM public.amazon_claude_requests
   WHERE status = 'waiting' AND kind IN ('chat', 'question', 'suggest', 'fix', 'market', 'keywords', 'kwname', 'niche')
     AND (note IS NULL OR note NOT LIKE 'Claude limit%' OR claimed_at IS NULL OR claimed_at < now() - interval '10 minutes')
   ORDER BY (kind = 'chat') DESC, (kind = 'suggest') DESC, (kind IN ('market', 'keywords', 'niche')) ASC, created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_claude_requests SET status = 'working', claimed_at = now(), attempts = attempts + 1, answered_by = p_by
   WHERE id = r.id RETURNING * INTO r;
  ctx := public.svc_amz_bridge_context(r.sku);
  IF r.kind IN ('kwname', 'niche') THEN
    ctx := ctx || jsonb_build_object(
      'keyword', CASE WHEN r.kind = 'kwname' THEN (SELECT keyword FROM public.amazon_keywords WHERE id::text = r.field) END,
      'target_skus', r.target_skus,
      'product_text', (SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'title', l.title, 'item_highlights', crm_private.amz_highlights(l),
          'bullets', l.bullets, 'description', left(l.description, 1500), 'facts', crm_private.amz_facts(l.sku),
          'pending_title', (SELECT q.after->>'title' FROM public.amazon_change_queue q WHERE q.sku = l.sku AND q.status = 'pending'
                             AND q.after ? 'title' ORDER BY coalesce(q.alt_rank, 1), q.created_at DESC LIMIT 1)))
        FROM public.amazon_listings l WHERE NOT l.is_parent AND (r.kind = 'niche' OR l.sku = ANY (r.target_skus))),
      'groups', coalesce((SELECT jsonb_agg(jsonb_build_object('name', name, 'skus', skus)) FROM public.amazon_product_groups), '[]'));
  END IF;
  RETURN jsonb_build_object('job', to_jsonb(r), 'context', ctx);
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_bridge_answer(p_id bigint, p_answer text, p_options jsonb DEFAULT NULL,
  p_drafts jsonb DEFAULT NULL, p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; d jsonb; did uuid; ids jsonb := '[]'; n int := 0; grp text; o jsonb; kw text; added int := 0;
  need text[]; kwid bigint; rk int; gname text; gskus text[]; kwo jsonb; groups int := 0; t text;
BEGIN
  SELECT * INTO r FROM public.amazon_claude_requests WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('waiting', 'working') THEN RETURN jsonb_build_object('saved', false); END IF;
  IF r.kind = 'kwname' THEN
    kw := (SELECT keyword FROM public.amazon_keywords WHERE id::text = r.field);
    need := ARRAY(SELECT w FROM unnest(crm_private.amz_words(kw)) w WHERE NOT crm_private.amz_stopword(w));
  END IF;
  IF jsonb_typeof(p_drafts) = 'array' AND r.kind NOT IN ('keywords', 'niche') THEN
    FOR d IN SELECT * FROM jsonb_array_elements(p_drafts) LIMIT CASE WHEN r.kind = 'kwname' THEN 60 ELSE 30 END LOOP
      IF r.kind = 'kwname' THEN
        -- only the asked products; the name (or Item Highlights) must really contain every word of the keyword; names under 75
        CONTINUE WHEN NOT (d->>'sku' = ANY (coalesce(r.target_skus, '{}')));
        t := concat_ws(' ', d->'after'->>'title', d->'after'->'attributes'->'title_differentiation'->0->>'value');
        CONTINUE WHEN NOT (need <@ crm_private.amz_words(t));
        CONTINUE WHEN length(coalesce(d->'after'->>'title', '')) > 74;
        CONTINUE WHEN length(coalesce(d->'after'->'attributes'->'title_differentiation'->0->>'value', '')) > 125;
        CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_object_keys(d->'after') key WHERE key NOT IN ('title', 'attributes'));
        CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_object_keys(coalesce(d->'after'->'attributes', '{}')) key WHERE key <> 'title_differentiation');
        -- join the product's waiting name choices (approving one closes the others), ranked after them
        SELECT alt_group, max(coalesce(alt_rank, 1)) INTO grp, rk FROM public.amazon_change_queue
         WHERE sku = d->>'sku' AND status = 'pending' AND after ? 'title' AND alt_group IS NOT NULL GROUP BY alt_group LIMIT 1;
        IF grp IS NULL THEN grp := 'kw' || r.field || ':' || (d->>'sku'); rk := 0; END IF;
        d := d || jsonb_build_object('rank', least(9, rk + CASE WHEN (d->>'rank') ~ '^\d$' THEN (d->>'rank')::int ELSE 1 END)::text);
      ELSE
        grp := CASE WHEN coalesce(d->>'group', '') <> '' THEN p_id || ':' || left(d->>'group', 60) END;
      END IF;
      did := crm_private.amz_draft_internal(coalesce(d->>'kind', 'listing'), d->>'sku', d->'after', d->>'summary', d->>'reason', 'claude', p_id,
               grp, CASE WHEN (d->>'rank') ~ '^\d$' THEN (d->>'rank')::int END, d->>'rank_reason',
               CASE WHEN (d->>'finding_id') ~ '^\d{1,12}$' THEN (d->>'finding_id')::bigint END);
      IF did IS NOT NULL THEN ids := ids || to_jsonb(did::text); n := n + 1; END IF;
    END LOOP;
  END IF;
  IF r.kind = 'keywords' AND jsonb_typeof(p_options) = 'array' THEN
    FOR o IN SELECT * FROM jsonb_array_elements(p_options) LIMIT 40 LOOP
      BEGIN
        kw := crm_private.amz_kw_check(CASE WHEN jsonb_typeof(o) = 'string' THEN o #>> '{}' ELSE o->>'keyword' END);
        INSERT INTO public.amazon_keywords (keyword, source, status, kind, why)
        VALUES (kw, 'claude', 'candidate',
                CASE WHEN o->>'type' IN ('search', 'spelling', 'related', 'gift', 'festival') THEN o->>'type' ELSE 'related' END,
                left(coalesce(o->>'why', 'Suggested by Claude'), 300))
        ON CONFLICT (lower(keyword)) DO NOTHING;
        IF FOUND THEN added := added + 1; END IF;
      EXCEPTION WHEN others THEN NULL;   -- sales words, brands, too long: skipped
      END;
    END LOOP;
  END IF;
  -- niche plan: [{group, why, skus:[...], keywords:[{keyword, why}]}]
  IF r.kind = 'niche' AND jsonb_typeof(p_options) = 'array' THEN
    FOR o IN SELECT * FROM jsonb_array_elements(p_options) LIMIT 12 LOOP
      gname := left(btrim(coalesce(o->>'group', '')), 40);
      CONTINUE WHEN gname = '' OR jsonb_typeof(o->'skus') <> 'array';
      gskus := ARRAY(SELECT DISTINCT s FROM jsonb_array_elements_text(o->'skus') s
                      WHERE s IN (SELECT sku FROM public.amazon_listings WHERE NOT is_parent));
      CONTINUE WHEN cardinality(gskus) = 0;
      INSERT INTO public.amazon_product_groups (name, skus, why, updated_at) VALUES (gname, gskus, left(o->>'why', 300), now())
      ON CONFLICT (name) DO UPDATE SET skus = EXCLUDED.skus, why = EXCLUDED.why, updated_at = now();
      groups := groups + 1;
      FOR kwo IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(o->'keywords') = 'array' THEN o->'keywords' ELSE '[]' END) LIMIT 8 LOOP
        BEGIN
          kw := crm_private.amz_kw_check(CASE WHEN jsonb_typeof(kwo) = 'string' THEN kwo #>> '{}' ELSE kwo->>'keyword' END);
          INSERT INTO public.amazon_keywords AS k (keyword, source, status, kind, why, group_name, target_skus)
          VALUES (kw, 'claude', 'candidate', 'niche', left(coalesce(kwo->>'why', 'Own search for ' || gname), 300), gname, gskus)
          ON CONFLICT (lower(keyword)) DO UPDATE SET group_name = EXCLUDED.group_name, target_skus = EXCLUDED.target_skus, updated_at = now()
           WHERE k.status <> 'rejected' AND NOT EXISTS (SELECT 1 FROM public.amazon_keyword_products kp WHERE kp.keyword_id = k.id AND kp.status IN ('live', 'pending'));
          IF FOUND THEN added := added + 1; END IF;
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;
    END LOOP;
  END IF;
  UPDATE public.amazon_claude_requests SET
    answer = left(coalesce(nullif(trim(p_answer), ''), CASE WHEN r.kind = 'suggest' THEN 'Suggestions ready'
                                                            WHEN r.kind = 'keywords' THEN added || ' new keyword ideas'
                                                            WHEN r.kind = 'niche' THEN groups || ' product groups, ' || added || ' keywords'
                                                            WHEN r.kind = 'kwname' THEN n || ' name suggestions in Decisions' ELSE 'Done.' END), 8000),
    options = CASE WHEN r.kind = 'suggest' AND jsonb_typeof(p_options) = 'array' AND jsonb_array_length(p_options) BETWEEN 1 AND 5 THEN p_options ELSE options END,
    status = 'answered', answered_at = now(), answered_by = p_by, note = NULL, draft_ids = ids
   WHERE id = p_id;
  RETURN jsonb_build_object('saved', true, 'drafts', n, 'keywords', added, 'groups', groups);
END $$;

-- ---------------------------------------------------------------- permissions
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_keyword_smart(bigint, text[])', 'public.api_amz_keyword_name(bigint, text[])',
    'public.api_amz_keyword_fit(bigint)', 'public.api_amz_keyword_placement(bigint, text)', 'public.api_amz_keyword_drop(uuid, bigint)',
    'public.api_amz_keyword_swap(bigint, text, bigint)', 'public.api_amz_keyword_niche()', 'public.api_amz_keywords()',
    'public.api_amz_keyword_apply(bigint, text[], boolean)', 'public.api_amz_keyword_remove(bigint, text[])', 'public.api_amz_decisions(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_keyword_seasons()', 'public.svc_amz_bridge_claim(text)',
    'public.svc_amz_bridge_answer(bigint, text, jsonb, jsonb, text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['crm_private.amz_highlights(public.amazon_listings)', 'crm_private.amz_visible_words(public.amazon_listings)',
    'crm_private.amz_facts(text)', 'crm_private.amz_kw_fit(text, text)', 'crm_private.amz_kw_autowatch(bigint)',
    'crm_private.amz_kw_apply(bigint, text[])', 'crm_private.amz_kw_name_request(bigint, text[], uuid)',
    'crm_private.amz_kw_main(public.amazon_keywords)', 'crm_private.amz_kw_remove(bigint, text[])', 'crm_private.amz_kw_recheck(text)',
    'crm_private.amz_kw_recheck_trg()', 'crm_private.amz_kw_place_norm()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- cron: seasons every morning 06:55 IST (01:25 UTC)
DO $outer$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN RETURN; END IF;
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-amazon-kw-seasons';
  PERFORM cron.schedule('crm-amazon-kw-seasons', '25 1 * * *', $job$ SELECT public.svc_amz_keyword_seasons() $job$);
END $outer$;
