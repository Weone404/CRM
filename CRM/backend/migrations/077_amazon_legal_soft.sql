-- 077: Missing Legal Metrology details no longer block edits of EXISTING listings (they show as a warning),
-- so photos, text and details can be fixed while MRP / maker / quantity are being added. New listings still require them.
-- Same evaluator as 076 otherwise. Re-runnable.

CREATE OR REPLACE FUNCTION crm_private.amz_evaluate(p_kind text, p_sku text, p_after jsonb, p_batch uuid DEFAULT NULL,
  p_self uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  g jsonb := crm_private.amz_evaluate_core(p_kind, p_sku, p_after, p_batch, p_self);
  a jsonb := coalesce(p_after, '{}'); L public.amazon_listings; r jsonb; d text; n int; items jsonb := '[]';
  cover jsonb; k text; v jsonb; mx int;
BEGIN
  -- Existing listings: a missing Legal Metrology field (MRP, maker, country, quantity) is a warning, not a stop,
  -- so photos, text and details can still be fixed. New listings ('create') keep it as a blocker.
  IF p_kind <> 'create' THEN
    g := jsonb_build_object(
      'blockers', coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(g->'blockers') i WHERE i->>'code' <> 'legal_fields'), '[]'),
      'warnings', (g->'warnings') || coalesce((SELECT jsonb_agg(i || jsonb_build_object('severity', 'warning',
                    'message', (i->>'message') || ' Amazon India needs it; add it soon.'))
                    FROM jsonb_array_elements(g->'blockers') i WHERE i->>'code' = 'legal_fields'), '[]'),
      'confirms', g->'confirms');
    g := g || jsonb_build_object('ok', jsonb_array_length(g->'blockers') = 0);
  END IF;
  SELECT * INTO L FROM public.amazon_listings WHERE sku = p_sku;
  IF (p_kind = 'dispatch' OR a ?| ARRAY['handling_days', 'quantity', 'images', 'attributes']) AND L.sku IS NULL THEN
    items := items || jsonb_build_object('code', 'unknown_sku', 'severity', 'blocker', 'message', 'This SKU is not in the CRM.');
  END IF;

  -- Dispatch time (075)
  IF p_kind = 'dispatch' OR a ? 'handling_days' THEN
    r := crm_private.amz_rule('dispatch_days');
    d := a->>'handling_days';
    IF d IS NULL OR d !~ '^\d{1,2}$' THEN
      items := items || jsonb_build_object('code', 'dispatch_days', 'severity', 'blocker',
        'message', 'Pick a dispatch time (same day, next day, ...). The old value is unknown, so set it in Seller Central.');
    ELSE
      n := d::int;
      IF r IS NOT NULL AND (n < coalesce((r->>'min')::int, 0) OR n > coalesce((r->>'max')::int, 30)) THEN
        items := items || jsonb_build_object('code', 'dispatch_days', 'severity', 'blocker',
          'message', format('Dispatch time must be %s to %s days.', r->>'min', r->>'max'));
      ELSIF r IS NOT NULL AND n = 0 THEN
        items := items || jsonb_build_object('code', 'dispatch_days', 'severity', 'warning',
          'message', format('Same day: every order must be packed and handed to Easy Ship the day it arrives (book the pickup before %s). Late shipments hurt account health.',
            coalesce(r->>'pickup_cutoff', '12:00')));
      END IF;
    END IF;
    IF p_kind = 'dispatch' AND EXISTS (SELECT 1 FROM jsonb_object_keys(a) x WHERE x <> 'handling_days') THEN
      items := items || jsonb_build_object('code', 'dispatch_only', 'severity', 'blocker',
        'message', 'A dispatch change can only change the dispatch time.');
    END IF;
  END IF;
  IF (a ? 'handling_days' OR a ? 'quantity') AND L.is_parent THEN
    items := items || jsonb_build_object('code', 'dispatch_parent', 'severity', 'blocker',
      'message', 'This is a parent listing (no stock of its own). Set stock and dispatch time on each variation.');
  END IF;

  -- Stock
  IF a ? 'quantity' THEN
    mx := coalesce((crm_private.amz_rule('quantity_max')->>'max')::int, 99999);
    IF (a->>'quantity') IS NULL OR (a->>'quantity') !~ '^\d{1,6}$' OR (a->>'quantity')::int > mx THEN
      items := items || jsonb_build_object('code', 'quantity_max', 'severity', 'blocker',
        'message', format('Stock must be a whole number from 0 to %s.', mx));
    ELSIF (a->>'quantity')::int = 0 THEN
      items := items || jsonb_build_object('code', 'quantity_max', 'severity', 'warning',
        'message', 'Stock 0: the product stops selling until you add stock.');
    END IF;
  END IF;

  -- Photos: array of {url, width?, height?, white_bg?, has_text?} or plain URLs; the first one is the cover.
  IF a ? 'images' THEN
    mx := coalesce((crm_private.amz_rule('images_max')->>'max')::int, 9);
    IF jsonb_typeof(a->'images') <> 'array' OR jsonb_array_length(a->'images') = 0 THEN
      items := items || jsonb_build_object('code', 'images_max', 'severity', 'blocker', 'message', 'Keep at least one photo (the cover).');
    ELSE
      IF jsonb_array_length(a->'images') > mx THEN
        items := items || jsonb_build_object('code', 'images_max', 'severity', 'blocker',
          'message', format('Amazon allows %s photos. Remove %s.', mx, jsonb_array_length(a->'images') - mx));
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(a->'images') e
                  WHERE coalesce(e->>'url', CASE WHEN jsonb_typeof(e) = 'string' THEN e #>> '{}' END, '') !~ '^https://[^\s]+$') THEN
        items := items || jsonb_build_object('code', 'images_max', 'severity', 'blocker', 'message', 'Every photo needs a public https link.');
      END IF;
      cover := a->'images'->0;
      IF jsonb_typeof(cover) = 'string' THEN cover := jsonb_build_object('url', cover #>> '{}'); END IF;
      IF cover->>'url' IS DISTINCT FROM (L.images->0->>'url') AND crm_private.amz_rule('main_image') IS NOT NULL THEN
        r := crm_private.amz_rule('main_image');
        IF cover ? 'width' THEN
          IF greatest(coalesce((cover->>'width')::int, 0), coalesce((cover->>'height')::int, 0)) < (r->>'min_px')::int THEN
            items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
              'message', format('Cover photo is %sx%s px; the longest side must be at least %s px.', cover->>'width', cover->>'height', r->>'min_px'));
          END IF;
          IF coalesce((cover->>'white_bg')::boolean, false) IS NOT TRUE THEN
            items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
              'message', 'Cover photo background is not pure white. Amazon needs a pure white background for the cover.');
          END IF;
        END IF;
        IF coalesce((cover->>'has_text')::boolean, false) THEN
          items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
            'message', 'Cover photo has text, a logo or a watermark. Amazon does not allow that on the cover.');
        ELSIF (cover->>'has_text') IS NULL THEN
          items := items || jsonb_build_object('code', 'main_image', 'severity', 'confirm',
            'message', 'New cover photo: check it has a pure white background and no text, logo or watermark.');
        END IF;
      END IF;
    END IF;
  END IF;

  -- Product details: {attribute_name: [Amazon value objects] | null}
  IF a ? 'attributes' THEN
    r := crm_private.amz_rule('attribute_locked');
    IF jsonb_typeof(a->'attributes') <> 'object' OR a->'attributes' = '{}' THEN
      items := items || jsonb_build_object('code', 'attribute_locked', 'severity', 'blocker', 'message', 'No product details to change.');
    ELSE
      FOR k, v IN SELECT * FROM jsonb_each(a->'attributes') LOOP
        IF k !~ '^[a-z][a-z0-9_]{1,63}$' THEN
          items := items || jsonb_build_object('code', 'attribute_locked', 'severity', 'blocker', 'message', format('"%s" is not a valid detail name.', left(k, 40)));
        ELSIF r IS NOT NULL AND ((r->'keys') ? k OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(r->'prefixes') p WHERE k LIKE p || '%')) THEN
          items := items || jsonb_build_object('code', 'attribute_locked', 'severity', 'blocker',
            'message', format('"%s" cannot be changed here.', replace(k, '_', ' ')));
        ELSIF jsonb_typeof(v) NOT IN ('array', 'null') OR length(v::text) > 4000 THEN
          items := items || jsonb_build_object('code', 'attribute_locked', 'severity', 'blocker', 'message', format('"%s" has an invalid value.', replace(k, '_', ' ')));
        ELSIF jsonb_typeof(v) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE coalesce(e->>'value', '') ~* '\m(best ?seller|#1|no\.? ?1|free|sale|offer|discount)\M') THEN
          items := items || jsonb_build_object('code', 'title_promo_words', 'severity', 'blocker',
            'message', format('"%s" has sales words (best seller, free, sale ...). Amazon removes listings for that.', replace(k, '_', ' ')));
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF jsonb_array_length(items) > 0 THEN
    g := jsonb_build_object(
      'blockers', (g->'blockers') || coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'blocker'), '[]'),
      'warnings', (g->'warnings') || coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'warning'), '[]'),
      'confirms', (g->'confirms') || coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'confirm'), '[]'));
    g := g || jsonb_build_object('ok', jsonb_array_length(g->'blockers') = 0);
  END IF;
  RETURN g;
END $$;

REVOKE ALL ON FUNCTION crm_private.amz_evaluate(text, text, jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated;
