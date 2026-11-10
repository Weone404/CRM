-- 076: Product editor. Admin can publish edits directly; anyone else's edits wait for approval.
-- New editable fields: quantity (stock), images (photos, first = cover), attributes (product details).
-- AI ideas: instant ones are made in the browser; "Ask Claude" ones go through amazon_claude_requests (kind 'suggest').
-- Photos are uploaded by the amazon-upload Edge Function into the public 'amazon-images' bucket (Amazon needs a public URL).
-- Re-runnable. Builds on 072 + 075.

-- Photo bucket (skipped where the storage schema does not exist, e.g. the local test database).
DO $$ BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES ('amazon-images', 'amazon-images', true, 10485760, ARRAY['image/jpeg', 'image/png'])
    ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 10485760, allowed_mime_types = ARRAY['image/jpeg', 'image/png'];
  END IF;
END $$;

-- Claude suggestions ride on the existing request queue.
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'question';
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS sku text;
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS field text;
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS options jsonb;
DO $$ BEGIN
  ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_kind_chk CHECK (kind IN ('question', 'suggest'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

INSERT INTO public.amazon_rules (code, label, severity, value) VALUES
  ('images_max', 'At most 9 photos (1 cover + 8 more); every photo needs a public https link', 'blocker', '{"max": 9}'),
  ('quantity_max', 'Stock must be a whole number from 0 to this maximum', 'blocker', '{"max": 99999}'),
  ('attribute_locked', 'Product details that cannot be edited here (they have their own editor or must not change)', 'blocker',
   '{"keys": ["item_name", "bullet_point", "product_description", "generic_keyword", "purchasable_offer", "list_price",
     "fulfillment_availability", "main_product_image_locator", "merchant_suggested_asin", "condition_type", "skip_offer",
     "brand", "externally_assigned_product_identifier", "supplier_declared_has_product_identifier_exemption",
     "manufacturer", "country_of_origin", "item_package_quantity", "maximum_retail_price"],
     "prefixes": ["other_product_image_locator_", "swatch_product_image_locator"]}')
ON CONFLICT (code) DO NOTHING;

-- Evaluator: core (072) + dispatch (075) + editor checks (076).
CREATE OR REPLACE FUNCTION crm_private.amz_evaluate(p_kind text, p_sku text, p_after jsonb, p_batch uuid DEFAULT NULL,
  p_self uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  g jsonb := crm_private.amz_evaluate_core(p_kind, p_sku, p_after, p_batch, p_self);
  a jsonb := coalesce(p_after, '{}'); L public.amazon_listings; r jsonb; d text; n int; items jsonb := '[]';
  cover jsonb; k text; v jsonb; mx int;
BEGIN
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

CREATE OR REPLACE FUNCTION crm_private.amz_snapshot(p_sku text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title, 'item_highlights', l.item_highlights,
    'bullets', l.bullets, 'description', l.description, 'backend_terms', l.backend_terms, 'price', l.price,
    'mrp', l.mrp, 'country_of_origin', l.country_of_origin, 'manufacturer', l.manufacturer,
    'net_quantity', l.net_quantity, 'images', l.images, 'product_type', l.product_type, 'version', l.version,
    'handling_days', l.handling_days, 'quantity', l.quantity)
  FROM public.amazon_listings l WHERE l.sku = p_sku
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_apply_live(q public.amazon_change_queue) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a jsonb;
BEGIN
  IF q.sku IS NOT NULL THEN
    a := q.after;
    UPDATE public.amazon_listings SET
      title = CASE WHEN a ? 'title' THEN a->>'title' ELSE title END,
      last_approved_title = CASE WHEN a ? 'title' THEN a->>'title' ELSE last_approved_title END,
      item_highlights = CASE WHEN a ? 'item_highlights' THEN a->>'item_highlights' ELSE item_highlights END,
      bullets = CASE WHEN a ? 'bullets' THEN a->'bullets' ELSE bullets END,
      description = CASE WHEN a ? 'description' THEN a->>'description' ELSE description END,
      backend_terms = CASE WHEN a ? 'backend_terms' THEN a->>'backend_terms' ELSE backend_terms END,
      price = CASE WHEN a ? 'price' THEN (a->>'price')::numeric ELSE price END,
      mrp = CASE WHEN a ? 'mrp' THEN (a->>'mrp')::numeric ELSE mrp END,
      country_of_origin = CASE WHEN a ? 'country_of_origin' THEN a->>'country_of_origin' ELSE country_of_origin END,
      manufacturer = CASE WHEN a ? 'manufacturer' THEN a->>'manufacturer' ELSE manufacturer END,
      net_quantity = CASE WHEN a ? 'net_quantity' THEN a->>'net_quantity' ELSE net_quantity END,
      handling_days = CASE WHEN a ? 'handling_days' THEN (a->>'handling_days')::int ELSE handling_days END,
      quantity = CASE WHEN a ? 'quantity' THEN (a->>'quantity')::int ELSE quantity END,
      images = CASE WHEN a ? 'images' THEN (
        SELECT coalesce(jsonb_agg(jsonb_build_object('slot', CASE WHEN o = 1 THEN 'MAIN' ELSE 'PT0' || (o - 1) END,
                 'url', coalesce(e->>'url', e #>> '{}')) ORDER BY o), '[]')
          FROM jsonb_array_elements(a->'images') WITH ORDINALITY t(e, o)) ELSE images END,
      attributes = CASE WHEN a ? 'attributes' THEN (
        SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM jsonb_each(coalesce(attributes, '{}') || (a->'attributes')) x(k, v)
         WHERE jsonb_typeof(v) <> 'null') ELSE attributes END,
      version = version + 1, updated_at = now()
     WHERE sku = q.sku;
    INSERT INTO public.amazon_listing_versions (sku, version, source, snapshot, change_id)
    SELECT sku, version, CASE WHEN q.kind = 'rollback' THEN 'rollback' ELSE 'change' END, crm_private.amz_snapshot(sku), q.id
      FROM public.amazon_listings l WHERE l.sku = q.sku;
  END IF;
END $$;

-- Drafts: new fields. For product details the "before" keeps only the touched details, so Undo restores exactly those.
CREATE OR REPLACE FUNCTION public.api_amz_draft_create(p_kind text, p_sku text, p_after jsonb, p_summary text DEFAULT '',
  p_batch uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; l public.amazon_listings; clean jsonb; bef jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_kind NOT IN ('listing', 'price', 'ads_budget', 'create', 'dispatch') THEN RAISE EXCEPTION 'Unknown change type' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF p_kind <> 'ads_budget' AND p_kind <> 'create' AND l.sku IS NULL THEN RAISE EXCEPTION 'Listing not found' USING ERRCODE = 'PT404'; END IF;
  SELECT coalesce(jsonb_object_agg(k, v), '{}') INTO clean FROM jsonb_each(coalesce(p_after, '{}')) e(k, v)
   WHERE k IN ('title','item_highlights','bullets','description','backend_terms','price','mrp','country_of_origin',
               'manufacturer','net_quantity','main_image','claims','daily_budget_total','asin','product_type','handling_days',
               'quantity','images','attributes');
  IF clean = '{}' THEN RAISE EXCEPTION 'Nothing to change' USING ERRCODE = 'PT422'; END IF;
  bef := coalesce(crm_private.amz_snapshot(p_sku), '{}');
  IF clean ? 'attributes' AND jsonb_typeof(clean->'attributes') = 'object' THEN
    bef := bef || jsonb_build_object('attributes', (SELECT coalesce(jsonb_object_agg(k, coalesce(l.attributes->k, 'null'::jsonb)), '{}')
                                                     FROM jsonb_object_keys(clean->'attributes') k));
  END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, batch_id, created_by_type, created_by)
  VALUES (p_kind, p_sku, coalesce(l.asin, clean->>'asin'), left(coalesce(p_summary, ''), 300),
          bef, clean, l.version, p_batch, 'user', crm_private.current_employee_id())
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind));
  RETURN to_jsonb(q);
END $$;

-- Editor save. Admin: the save is the approval (same guards; a change needing a second look needs p_second_confirm).
-- Everyone else: the change waits in Approve Changes. The browser then calls amazon-execute for approved changes.
CREATE OR REPLACE FUNCTION public.api_amz_publish(p_kind text, p_sku text, p_after jsonb, p_summary text DEFAULT '',
  p_second_confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c jsonb;
BEGIN
  c := public.api_amz_draft_create(p_kind, p_sku, p_after, p_summary, NULL);
  IF NOT coalesce((c->'guard_result'->>'ok')::boolean, false) THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', error = 'Not saved: fix the problems first.' WHERE id = (c->>'id')::uuid;
    RETURN jsonb_build_object('status', 'blocked', 'guard_result', c->'guard_result');
  END IF;
  IF NOT crm_private.is_admin() THEN
    RETURN jsonb_build_object('status', 'pending', 'id', c->>'id', 'guard_result', c->'guard_result');
  END IF;
  IF coalesce((c->>'needs_second_confirm')::boolean, false) AND NOT coalesce(p_second_confirm, false) THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', error = 'Not saved: needs a second look.' WHERE id = (c->>'id')::uuid;
    RETURN jsonb_build_object('status', 'confirm', 'guard_result', c->'guard_result');
  END IF;
  c := public.api_amz_approve((c->>'id')::uuid, coalesce(p_second_confirm, false));
  RETURN jsonb_build_object('status', c->>'status', 'id', c->>'id', 'guard_result', c->'guard_result');
END $$;

-- AI ideas from Claude (asynchronous). Claude answers with svc_amz_suggest_answer.
CREATE OR REPLACE FUNCTION public.api_amz_suggest(p_sku text, p_field text, p_note text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; r public.amazon_claude_requests;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_field NOT IN ('title', 'bullets', 'description', 'backend_terms') THEN RAISE EXCEPTION 'Unknown field' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RAISE EXCEPTION 'Listing not found' USING ERRCODE = 'PT404'; END IF;
  SELECT * INTO r FROM public.amazon_claude_requests WHERE kind = 'suggest' AND sku = p_sku AND field = p_field AND status = 'waiting';
  IF r.id IS NOT NULL THEN RETURN to_jsonb(r); END IF;
  INSERT INTO public.amazon_claude_requests (question, asked_by, kind, sku, field)
  VALUES (left(format('Suggest 5 options for the %s of %s (%s).%s', p_field, l.asin, l.title,
            CASE WHEN coalesce(trim(p_note), '') <> '' THEN ' Note: ' || trim(p_note) ELSE '' END), 4000),
          crm_private.current_employee_id(), 'suggest', p_sku, p_field)
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_suggestions(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC) FROM (
    SELECT id, field, status, options, created_at, answered_at FROM public.amazon_claude_requests
     WHERE kind = 'suggest' AND sku = p_sku AND status <> 'cancelled' ORDER BY created_at DESC LIMIT 20) r), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_suggest_answer(p_id bigint, p_options jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF jsonb_typeof(p_options) <> 'array' OR jsonb_array_length(p_options) NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'options must be an array of 1 to 5 suggestions';
  END IF;
  UPDATE public.amazon_claude_requests SET options = p_options, status = 'answered', answer = 'Suggestions ready', answered_at = now()
   WHERE id = p_id AND kind = 'suggest' AND status = 'waiting';
END $$;

REVOKE ALL ON FUNCTION crm_private.amz_evaluate(text, text, jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_amz_draft_create(text, text, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_draft_create(text, text, jsonb, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.api_amz_publish(text, text, jsonb, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_publish(text, text, jsonb, text, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.api_amz_suggest(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_suggest(text, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.api_amz_suggestions(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_suggestions(text) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_amz_suggest_answer(bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_amz_suggest_answer(bigint, jsonb) TO service_role;
