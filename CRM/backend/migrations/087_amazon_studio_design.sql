-- 087: Studio part 2: text & pointers on photos 2-9 (never on the main photo), templates, truth check, photo score.
-- Run after 086. Re-runnable.
--  * Wording suggestions come only from the product's own key points and details.
--  * Truth check (on the server, so it cannot be skipped): no sales words / prices / % / competitor brands, and claims like
--    "waterproof", "genuine leather", "acid-free" or a number with a unit (24 cm, 192 pages, 80 GSM) must exist in this
--    product's own details.
--  * Photo score: truth problems -30 each, readability warnings from the editor -10 each, small image -20, too many layers -10.

-- Short callouts from the key points: "SECURE MAGNETIC CLASP: Equipped with…" -> "Secure magnetic clasp".
CREATE OR REPLACE FUNCTION crm_private.amz_callouts(p_bullets jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(c ORDER BY o), '{}') FROM (
    SELECT DISTINCT ON (lower(c)) c, o FROM (
      SELECT initcap(lower(btrim(regexp_replace(split_part(regexp_replace(b, '^[^[:alnum:]]+', ''), ':', 1), '\s+', ' ', 'g')))) c, o
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_bullets) = 'array' THEN p_bullets ELSE '[]' END) WITH ORDINALITY t(b, o)
       WHERE position(':' IN b) BETWEEN 4 AND 45) x
     WHERE length(c) BETWEEN 3 AND 40 ORDER BY lower(c), o) y
$$;

-- Everything this product says about itself (for the truth check).
CREATE OR REPLACE FUNCTION crm_private.amz_product_text(p_sku text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ' ' || crm_private.amz_norm(concat_ws(' ', l.title, crm_private.amz_highlights(l),
    (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b),
    l.description,
    (SELECT string_agg(v #>> '{}', ' ') FROM jsonb_each(coalesce(l.attributes, '{}')) e(k, val), jsonb_path_query(val, 'lax $.**.value') v
      WHERE k IN ('size', 'paper_size', 'special_feature', 'cover', 'material', 'binding', 'ruling_type', 'number_of_items', 'pages', 'page_count',
                  'item_dimensions', 'item_length_width', 'color', 'specific_uses_for_product')))) || ' '
    FROM public.amazon_listings l WHERE l.sku = p_sku
$$;

-- Per text: ok + problems in plain words.
CREATE OR REPLACE FUNCTION crm_private.amz_truth(p_sku text, p_texts text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pt text := coalesce(crm_private.amz_product_text(p_sku), ' '); t text; n text; probs text[]; out jsonb := '[]'; w text; m text[];
BEGIN
  FOREACH t IN ARRAY coalesce(p_texts, '{}') LOOP
    probs := '{}';
    n := ' ' || crm_private.amz_norm(t) || ' ';
    IF t ~ '[₹%]' OR t ~* '\mrs\.?\s*\d' OR t ~* '\minr\s*\d' THEN probs := array_append(probs, 'No prices or % on photos'::text); END IF;
    SELECT x INTO w FROM unnest(ARRAY['best seller', 'bestseller', 'best', 'no 1', 'number 1', 'top rated', 'free', 'sale', 'offer', 'discount',
      'cheapest', 'lowest price', 'guarantee', 'guaranteed', 'amazon choice', 'amazons choice', 'limited time', 'hurry']) x
     WHERE n LIKE '% ' || x || ' %' LIMIT 1;
    IF w IS NOT NULL OR t ~ '#\s*1' THEN probs := array_append(probs, format('Sales word not allowed: "%s"', coalesce(w, '#1'))); END IF;
    SELECT b INTO w FROM (SELECT DISTINCT crm_private.amz_norm(brand) b FROM public.amazon_competitors WHERE brand IS NOT NULL) c
     WHERE length(b) >= 3 AND b NOT IN ('generic', 'nitaniya') AND n LIKE '% ' || b || ' %' LIMIT 1;
    IF w IS NOT NULL THEN probs := array_append(probs, format('Competitor brand: "%s"', w)); END IF;
    -- claims that must be in the product's own details
    FOR w IN SELECT x FROM unnest(ARRAY['waterproof', 'water resistant', 'genuine leather', 'real leather', 'pure leather', 'handmade', 'hand made',
        'eco friendly', 'recycled', 'acid free', 'lifetime', 'warranty', 'refillable', 'tear resistant', 'leak proof', 'organic', 'vegan',
        'gift box', 'pen included', 'with pen', 'lay flat', 'lies flat', 'perforated', 'pocket', 'elastic', 'magnetic', 'pen holder', 'ribbon',
        'bookmark', 'undated', 'dated', 'monthly planner', 'weekly planner', 'name embossed', 'photo']) x LOOP
      CONTINUE WHEN n NOT LIKE '% ' || w || ' %';
      IF pt NOT LIKE '% ' || w || ' %' AND NOT (w = 'lies flat' AND pt LIKE '% lie flat %') AND NOT (w = 'lay flat' AND pt LIKE '% lie flat %') THEN
        probs := array_append(probs, format('"%s" is not in this product''s details', w));
      END IF;
    END LOOP;
    -- numbers with units must match the product's details (24 cm, 192 pages, 80 GSM, A5 is checked by size words)
    FOR m IN SELECT regexp_matches(n, '\m(\d+(?: \d+)?) ?(cm|mm|inch|inches|pages|page|gsm|days)\M', 'g') LOOP
      IF pt NOT LIKE '% ' || split_part(m[1], ' ', 1) || ' %' THEN probs := array_append(probs, format('"%s %s" is not in this product''s details', m[1], m[2])); END IF;
    END LOOP;
    FOR m IN SELECT regexp_matches(n, '\m(a4|a5|a6|b5)\M', 'g') LOOP
      IF pt NOT LIKE '% ' || m[1] || ' %' THEN probs := array_append(probs, format('Size "%s" is not this product''s size', upper(m[1]))); END IF;
    END LOOP;
    out := out || jsonb_build_object('text', t, 'ok', cardinality(probs) = 0, 'problems', to_jsonb(probs));
  END LOOP;
  RETURN out;
END $$;

-- Editor data: suggested callouts and facts for one product.
CREATE OR REPLACE FUNCTION public.api_amz_studio_facts(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  RETURN jsonb_build_object(
    'callouts', to_jsonb(crm_private.amz_callouts(l.bullets)),
    'facts', crm_private.amz_facts(l.sku),
    'title', l.title,
    'special_features', coalesce((SELECT jsonb_agg(e->>'value') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(l.attributes->'special_feature') = 'array'
        THEN l.attributes->'special_feature' ELSE '[]' END) e), '[]'),
    'pages', coalesce(l.attributes->'pages'->0->>'value', l.attributes->'page_count'->0->>'value'),
    'dimensions', (SELECT m[1] || ' x ' || m[2] || ' cm' FROM regexp_matches(crm_private.amz_product_text(l.sku), '\m(\d{2}(?: \d)?) ?(?:cm )?x (\d{2}(?: \d)?) ?cm') m LIMIT 1));
END $$;

-- Live truth check while editing.
CREATE OR REPLACE FUNCTION public.api_amz_studio_truth(p_sku text, p_texts text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN crm_private.amz_truth(p_sku, p_texts[1:20]);
END $$;

-- A finished design (stored by the Edge Function). The truth check and score are made HERE from the layers.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_design(p_sku text, p_path text, p_width int, p_height int, p_bytes int, p_layers jsonb,
  p_parent uuid, p_client_checks jsonb, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE texts text[]; truth jsonb; checks jsonb := '[]'; score int := 100; bad int; warns int; aid uuid; nl int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.amazon_listings WHERE sku = p_sku) THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  texts := ARRAY(SELECT left(e->>'text', 200) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_layers) = 'array' THEN p_layers ELSE '[]' END) e
                  WHERE coalesce(e->>'text', '') <> '' LIMIT 20);
  nl := jsonb_array_length(CASE WHEN jsonb_typeof(p_layers) = 'array' THEN p_layers ELSE '[]' END);
  truth := crm_private.amz_truth(p_sku, texts);
  bad := (SELECT count(*) FROM jsonb_array_elements(truth) x, jsonb_array_elements_text(x->'problems') p);
  checks := checks || jsonb_build_object('code', 'truth', 'ok', bad = 0, 'level', CASE WHEN bad = 0 THEN 'ok' ELSE 'bad' END,
    'message', CASE WHEN bad = 0 THEN 'Every claim is in this product''s details' ELSE (SELECT string_agg(p, '; ') FROM jsonb_array_elements(truth) x,
      jsonb_array_elements_text(x->'problems') p) END);
  score := score - 30 * bad;
  -- readability / safe-area warnings measured in the editor (only messages are kept; they can only lower the score)
  warns := 0;
  IF jsonb_typeof(p_client_checks) = 'array' THEN
    checks := checks || coalesce((SELECT jsonb_agg(jsonb_build_object('code', left(c->>'code', 30), 'ok', false, 'level', 'warn', 'message', left(c->>'message', 160)))
      FROM (SELECT c FROM jsonb_array_elements(p_client_checks) c WHERE c->>'ok' = 'false' LIMIT 6) s), '[]');
    warns := (SELECT count(*) FROM jsonb_array_elements(p_client_checks) c WHERE c->>'ok' = 'false');
  END IF;
  score := score - 10 * least(warns, 4);
  IF greatest(coalesce(p_width, 0), coalesce(p_height, 0)) < 1600 THEN
    checks := checks || jsonb_build_object('code', 'size', 'ok', false, 'level', 'warn', 'message', 'Smaller than 1600 px: zoom will be blurry');
    score := score - 20;
  END IF;
  IF nl > 7 THEN
    checks := checks || jsonb_build_object('code', 'busy', 'ok', false, 'level', 'warn', 'message', format('%s labels: 3 to 5 read best on a phone', nl));
    score := score - 10;
  END IF;
  IF nl BETWEEN 1 AND 7 AND bad = 0 AND warns = 0 THEN
    checks := checks || jsonb_build_object('code', 'readable', 'ok', true, 'level', 'ok', 'message', 'Readable on a phone thumbnail');
  END IF;
  IF bad > 0 THEN score := least(score, 40); END IF;            -- a false claim can never be sent, whatever else is right
  aid := public.svc_amz_studio_asset(p_sku, 'design', p_path, p_width, p_height, p_bytes, checks, greatest(0, score),
           jsonb_build_object('truth', truth, 'layers_count', nl), p_parent, p_by);
  UPDATE public.amazon_studio_assets SET layers = p_layers WHERE id = aid;
  RETURN jsonb_build_object('id', aid, 'score', greatest(0, score), 'checks', checks);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_studio_facts(text)', 'public.api_amz_studio_truth(text, text[])'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  EXECUTE 'REVOKE ALL ON FUNCTION public.svc_amz_studio_design(text, text, int, int, int, jsonb, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.svc_amz_studio_design(text, text, int, int, int, jsonb, uuid, jsonb, uuid) TO service_role';
  FOREACH f IN ARRAY ARRAY['crm_private.amz_callouts(jsonb)', 'crm_private.amz_product_text(text)', 'crm_private.amz_truth(text, text[])'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- Sending (redefined from 086): a design that failed the checks (score under 70) is refused; the asset remembers its slot.
CREATE OR REPLACE FUNCTION public.svc_amz_studio_send(p_asset uuid, p_slot text, p_url text, p_by uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.amazon_studio_assets; l public.amazon_listings; imgs jsonb; n int; after jsonb; bef jsonb; q public.amazon_change_queue;
  white boolean; summary text;
BEGIN
  SELECT * INTO a FROM public.amazon_studio_assets WHERE id = p_asset FOR UPDATE;
  IF a.id IS NULL OR a.status = 'deleted' THEN RAISE EXCEPTION 'Photo not found' USING ERRCODE = 'PT404'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = a.sku;
  IF a.kind = 'design' AND coalesce(a.score, 0) < 70 THEN
    RAISE EXCEPTION 'This design scored %/100: fix the problems shown before sending', coalesce(a.score, 0) USING ERRCODE = 'PT422';
  END IF;
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
  UPDATE public.amazon_studio_assets SET status = 'sent', sent_change = q.id,
         meta = coalesce(meta, '{}') || jsonb_build_object('sent_slot', coalesce(n::text, p_slot)) WHERE id = a.id;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', a.sku, 'kind', 'studio', 'slot', p_slot));
  RETURN jsonb_build_object('change', q.id, 'slot', coalesce(n::text, p_slot));
END $$;
