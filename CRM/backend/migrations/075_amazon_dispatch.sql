-- 075: Dispatch speed ("handling time") per product, for Easy Ship (FBM).
-- handling_days = days between the order and handing the parcel to Easy Ship: 0 = same day, 1 = next day.
-- Sent to Amazon as fulfillment_availability.lead_time_to_ship_max_days through the normal Change Queue
-- (draft -> approval -> preview -> live). Amazon still decides the delivery date the customer sees.
-- Re-runnable.

ALTER TABLE public.amazon_listings ADD COLUMN IF NOT EXISTS handling_days int;
DO $$ BEGIN
  ALTER TABLE public.amazon_listings ADD CONSTRAINT amazon_listings_handling_days_chk CHECK (handling_days BETWEEN 0 AND 30);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- New change kind 'dispatch' (no Legal Metrology checks: it only changes the shipping promise).
ALTER TABLE public.amazon_change_queue DROP CONSTRAINT IF EXISTS amazon_change_queue_kind_check;
ALTER TABLE public.amazon_change_queue ADD CONSTRAINT amazon_change_queue_kind_check
  CHECK (kind IN ('listing', 'price', 'ads_budget', 'rollback', 'create', 'dispatch'));

INSERT INTO public.amazon_rules (code, label, severity, value) VALUES
  ('dispatch_days', 'Dispatch time must be 0-30 days; same day needs the pickup booked before 12 noon', 'warning',
   '{"min": 0, "max": 30, "pickup_cutoff": "12:00"}')
ON CONFLICT (code) DO NOTHING;

-- Keep the existing evaluator as the core and add the dispatch checks on top.
DO $$ BEGIN
  IF to_regprocedure('crm_private.amz_evaluate_core(text,text,jsonb,uuid,uuid)') IS NULL THEN
    ALTER FUNCTION crm_private.amz_evaluate(text, text, jsonb, uuid, uuid) RENAME TO amz_evaluate_core;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_evaluate(p_kind text, p_sku text, p_after jsonb, p_batch uuid DEFAULT NULL,
  p_self uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  g jsonb := crm_private.amz_evaluate_core(p_kind, p_sku, p_after, p_batch, p_self);
  a jsonb := coalesce(p_after, '{}'); L public.amazon_listings; r jsonb; d text; n int; items jsonb := '[]';
BEGIN
  IF p_kind = 'dispatch' OR a ? 'handling_days' THEN
    SELECT * INTO L FROM public.amazon_listings WHERE sku = p_sku;
    r := crm_private.amz_rule('dispatch_days');
    d := a->>'handling_days';
    IF L.sku IS NULL THEN
      items := items || jsonb_build_object('code', 'unknown_sku', 'severity', 'blocker', 'message', 'This SKU is not in the CRM.');
    END IF;
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
    IF L.is_parent THEN
      items := items || jsonb_build_object('code', 'dispatch_parent', 'severity', 'blocker',
        'message', 'This is a parent listing (no stock of its own). Set the dispatch time on each variation.');
    END IF;
    IF p_kind = 'dispatch' AND EXISTS (SELECT 1 FROM jsonb_object_keys(a) k WHERE k <> 'handling_days') THEN
      items := items || jsonb_build_object('code', 'dispatch_only', 'severity', 'blocker',
        'message', 'A dispatch change can only change the dispatch time.');
    END IF;
    IF jsonb_array_length(items) > 0 THEN
      g := jsonb_build_object(
        'blockers', (g->'blockers') || coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'blocker'), '[]'),
        'warnings', (g->'warnings') || coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'warning'), '[]'),
        'confirms', g->'confirms');
      g := g || jsonb_build_object('ok', jsonb_array_length(g->'blockers') = 0);
    END IF;
  END IF;
  RETURN g;
END $$;

-- Snapshot now includes the dispatch time (before/after, versions, rollback).
CREATE OR REPLACE FUNCTION crm_private.amz_snapshot(p_sku text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title, 'item_highlights', l.item_highlights,
    'bullets', l.bullets, 'description', l.description, 'backend_terms', l.backend_terms, 'price', l.price,
    'mrp', l.mrp, 'country_of_origin', l.country_of_origin, 'manufacturer', l.manufacturer,
    'net_quantity', l.net_quantity, 'images', l.images, 'product_type', l.product_type, 'version', l.version,
    'handling_days', l.handling_days)
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
      version = version + 1, updated_at = now()
     WHERE sku = q.sku;
    INSERT INTO public.amazon_listing_versions (sku, version, source, snapshot, change_id)
    SELECT sku, version, CASE WHEN q.kind = 'rollback' THEN 'rollback' ELSE 'change' END, crm_private.amz_snapshot(sku), q.id
      FROM public.amazon_listings l WHERE l.sku = q.sku;
  END IF;
END $$;

-- Drafts: accept the new kind and field (same body as 072 otherwise).
CREATE OR REPLACE FUNCTION public.api_amz_draft_create(p_kind text, p_sku text, p_after jsonb, p_summary text DEFAULT '',
  p_batch uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; l public.amazon_listings; clean jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_kind NOT IN ('listing', 'price', 'ads_budget', 'create', 'dispatch') THEN RAISE EXCEPTION 'Unknown change type' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF p_kind <> 'ads_budget' AND p_kind <> 'create' AND l.sku IS NULL THEN RAISE EXCEPTION 'Listing not found' USING ERRCODE = 'PT404'; END IF;
  SELECT coalesce(jsonb_object_agg(k, v), '{}') INTO clean FROM jsonb_each(coalesce(p_after, '{}')) e(k, v)
   WHERE k IN ('title','item_highlights','bullets','description','backend_terms','price','mrp','country_of_origin',
               'manufacturer','net_quantity','main_image','claims','daily_budget_total','asin','product_type','handling_days');
  IF clean = '{}' THEN RAISE EXCEPTION 'Nothing to change' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, batch_id, created_by_type, created_by)
  VALUES (p_kind, p_sku, coalesce(l.asin, clean->>'asin'), left(coalesce(p_summary, ''), 300),
          coalesce(crm_private.amz_snapshot(p_sku), '{}'), clean, l.version, p_batch, 'user', crm_private.current_employee_id())
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind));
  RETURN to_jsonb(q);
END $$;

-- One click: draft the same dispatch time for every product (variations only, not parents) that differs.
-- Drafts go in batches of at most bulk_batch_max; nothing goes live until approved.
CREATE OR REPLACE FUNCTION public.api_amz_dispatch_all(p_days int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l record; batch uuid; per int; n int := 0; skipped int := 0; label text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_days IS NULL OR p_days < 0 OR p_days > 30 THEN RAISE EXCEPTION 'Dispatch time must be 0 to 30 days' USING ERRCODE = 'PT422'; END IF;
  per := greatest(1, coalesce((crm_private.amz_rule('bulk_batch_max')->>'max')::int, 20));
  label := CASE p_days WHEN 0 THEN 'Same-day dispatch' WHEN 1 THEN 'Next-day dispatch' ELSE format('Dispatch in %s days', p_days) END;
  FOR l IN SELECT * FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY asin, sku LOOP
    IF l.handling_days IS NOT DISTINCT FROM p_days
       OR EXISTS (SELECT 1 FROM public.amazon_change_queue q WHERE q.sku = l.sku AND q.kind = 'dispatch'
                  AND q.status IN ('pending', 'approved', 'executing') AND (q.after->>'handling_days')::int = p_days) THEN
      skipped := skipped + 1; CONTINUE;
    END IF;
    IF n % per = 0 THEN batch := gen_random_uuid(); END IF;
    PERFORM public.api_amz_draft_create('dispatch', l.sku, jsonb_build_object('handling_days', p_days), label, batch);
    n := n + 1;
  END LOOP;
  PERFORM crm_private.amz_log('dispatch_all_drafted', 'listing', NULL, jsonb_build_object('days', p_days, 'drafted', n, 'skipped', skipped));
  RETURN jsonb_build_object('drafted', n, 'skipped', skipped);
END $$;

-- Sync writes Amazon's current dispatch time (does not bump versions or make drafts stale).
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_dispatch(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  UPDATE public.amazon_listings l SET handling_days = (it->>'handling_days')::int
    FROM jsonb_array_elements(coalesce(p_items, '[]')) it
   WHERE l.sku = it->>'sku' AND (it->>'handling_days') ~ '^\d{1,2}$' AND (it->>'handling_days')::int <= 30;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION crm_private.amz_evaluate(text, text, jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_amz_dispatch_all(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_dispatch_all(int) TO authenticated;
REVOKE ALL ON FUNCTION public.api_amz_draft_create(text, text, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_draft_create(text, text, jsonb, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_amz_upsert_dispatch(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_amz_upsert_dispatch(jsonb) TO service_role;
