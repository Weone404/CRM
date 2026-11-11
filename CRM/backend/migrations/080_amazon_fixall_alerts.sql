-- 080: Fix All (Claude fixes every open problem, with ranked alternatives), problem pop-ups, seller-feedback alerts,
-- order / pickup / stock alerts (CRM + Gmail through the scheduled Claude task), colour-swatch photo removal.
-- Every fix is still a Decision: nothing goes live without approval. Approving one alternative closes its siblings.
-- Re-runnable. Builds on 072-079.

-- ---------------------------------------------------------------- ranked alternatives
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS alt_group text;      -- same group = alternatives for one problem
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS alt_rank int;        -- 1 = best
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS rank_reason text;    -- why it got this rank
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS finding_id bigint;   -- the problem it fixes
CREATE INDEX IF NOT EXISTS idx_amz_queue_alt ON public.amazon_change_queue (alt_group) WHERE alt_group IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_amz_queue_finding ON public.amazon_change_queue (finding_id) WHERE finding_id IS NOT NULL;

ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_kind_chk;
ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_kind_chk
  CHECK (kind IN ('question', 'suggest', 'chat', 'report', 'fix'));

-- When one alternative is approved, the other waiting alternatives of the same problem are closed.
CREATE OR REPLACE FUNCTION crm_private.amz_close_siblings() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.alt_group IS NOT NULL AND NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', reject_reason = 'Another choice was approved'
     WHERE alt_group = NEW.alt_group AND id <> NEW.id AND status = 'pending';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_close_siblings ON public.amazon_change_queue;
CREATE TRIGGER amz_close_siblings AFTER UPDATE OF status ON public.amazon_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_close_siblings();

-- ---------------------------------------------------------------- colour swatch photo removal
-- A flagged swatch photo (text/logo on it) is fixed by removing it; Amazon then uses the cover photo for the swatch.
DROP FUNCTION IF EXISTS crm_private.amz_draft_internal(text, text, jsonb, text, text, text, bigint);
CREATE OR REPLACE FUNCTION crm_private.amz_draft_internal(p_kind text, p_sku text, p_after jsonb, p_summary text,
  p_reason text, p_by text, p_request bigint, p_alt_group text DEFAULT NULL, p_alt_rank int DEFAULT NULL,
  p_rank_reason text DEFAULT NULL, p_finding bigint DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; clean jsonb; bef jsonb; q public.amazon_change_queue;
BEGIN
  IF p_kind NOT IN ('listing', 'price', 'dispatch') OR jsonb_typeof(p_after) IS DISTINCT FROM 'object' THEN RETURN NULL; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_object_agg(k, v), '{}') INTO clean FROM jsonb_each(p_after) e(k, v)
   WHERE k IN ('title','bullets','description','backend_terms','price','mrp','handling_days','quantity','attributes','remove_swatch');
  IF clean ? 'remove_swatch' AND clean->'remove_swatch' <> 'true'::jsonb THEN clean := clean - 'remove_swatch'; END IF;
  IF clean = '{}' THEN RETURN NULL; END IF;
  -- the same fix is not drafted twice while one is waiting
  IF EXISTS (SELECT 1 FROM public.amazon_change_queue WHERE sku = p_sku AND status = 'pending' AND after = clean) THEN RETURN NULL; END IF;
  bef := coalesce(crm_private.amz_snapshot(p_sku), '{}');
  IF clean ? 'attributes' AND jsonb_typeof(clean->'attributes') = 'object' THEN
    bef := bef || jsonb_build_object('attributes', (SELECT coalesce(jsonb_object_agg(k, coalesce(l.attributes->k, 'null'::jsonb)), '{}')
                                                     FROM jsonb_object_keys(clean->'attributes') k));
  END IF;
  IF clean ? 'remove_swatch' THEN bef := bef || jsonb_build_object('remove_swatch', false); END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, created_by_type, reason, request_id,
                                          alt_group, alt_rank, rank_reason, finding_id)
  VALUES (p_kind, p_sku, l.asin, left(coalesce(nullif(trim(p_summary), ''), 'Suggested change'), 300), bef, clean, l.version,
          CASE WHEN p_by IN ('claude', 'system') THEN p_by ELSE 'claude' END, left(p_reason, 600), p_request,
          left(p_alt_group, 80), CASE WHEN p_alt_rank BETWEEN 1 AND 9 THEN p_alt_rank END, left(p_rank_reason, 1200),
          (SELECT id FROM public.amazon_audit_findings WHERE id = p_finding))
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind, 'by', p_by));
  RETURN q.id;
END $$;
REVOKE ALL ON FUNCTION crm_private.amz_draft_internal(text, text, jsonb, text, text, text, bigint, text, int, text, bigint) FROM PUBLIC, anon, authenticated;

-- Drafts from people: allow remove_swatch too (same body as 076 otherwise).
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
               'quantity','images','attributes','remove_swatch');
  IF clean ? 'remove_swatch' AND clean->'remove_swatch' <> 'true'::jsonb THEN clean := clean - 'remove_swatch'; END IF;
  IF clean = '{}' THEN RAISE EXCEPTION 'Nothing to change' USING ERRCODE = 'PT422'; END IF;
  bef := coalesce(crm_private.amz_snapshot(p_sku), '{}');
  IF clean ? 'attributes' AND jsonb_typeof(clean->'attributes') = 'object' THEN
    bef := bef || jsonb_build_object('attributes', (SELECT coalesce(jsonb_object_agg(k, coalesce(l.attributes->k, 'null'::jsonb)), '{}')
                                                     FROM jsonb_object_keys(clean->'attributes') k));
  END IF;
  IF clean ? 'remove_swatch' THEN bef := bef || jsonb_build_object('remove_swatch', false); END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, batch_id, created_by_type, created_by)
  VALUES (p_kind, p_sku, coalesce(l.asin, clean->>'asin'), left(coalesce(p_summary, ''), 300),
          bef, clean, l.version, p_batch, 'user', crm_private.current_employee_id())
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind));
  RETURN to_jsonb(q);
END $$;

-- Claude's answers may carry ranked alternatives: {kind, sku, after, summary, reason, group, rank, rank_reason, finding_id}
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_answer(p_id bigint, p_answer text, p_options jsonb DEFAULT NULL,
  p_drafts jsonb DEFAULT NULL, p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; d jsonb; did uuid; ids jsonb := '[]'; n int := 0; grp text;
BEGIN
  SELECT * INTO r FROM public.amazon_claude_requests WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('waiting', 'working') THEN RETURN jsonb_build_object('saved', false); END IF;
  IF jsonb_typeof(p_drafts) = 'array' THEN
    FOR d IN SELECT * FROM jsonb_array_elements(p_drafts) LIMIT 30 LOOP
      grp := CASE WHEN coalesce(d->>'group', '') <> '' THEN p_id || ':' || left(d->>'group', 60) END;
      did := crm_private.amz_draft_internal(d->>'kind', d->>'sku', d->'after', d->>'summary', d->>'reason', 'claude', p_id,
               grp, CASE WHEN (d->>'rank') ~ '^\d$' THEN (d->>'rank')::int END, d->>'rank_reason',
               CASE WHEN (d->>'finding_id') ~ '^\d{1,12}$' THEN (d->>'finding_id')::bigint END);
      IF did IS NOT NULL THEN ids := ids || to_jsonb(did::text); n := n + 1; END IF;
    END LOOP;
  END IF;
  UPDATE public.amazon_claude_requests SET
    answer = left(coalesce(nullif(trim(p_answer), ''), CASE WHEN r.kind = 'suggest' THEN 'Suggestions ready' ELSE 'Done.' END), 8000),
    options = CASE WHEN r.kind = 'suggest' AND jsonb_typeof(p_options) = 'array' AND jsonb_array_length(p_options) BETWEEN 1 AND 5 THEN p_options ELSE options END,
    status = 'answered', answered_at = now(), answered_by = p_by, note = NULL, draft_ids = ids
   WHERE id = p_id;
  RETURN jsonb_build_object('saved', true, 'drafts', n);
END $$;

-- Context: problems carry their id so Claude can link each fix to it; a 'fix' job gets the full product.
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_context(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'today_ist', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'rules', jsonb_build_object('price_floor', 299, 'title_max_chars', 75, 'bullet_max', 10, 'backend_terms_bytes', 249,
              'note', 'Generic brand (no Brand Registry). Personalised diaries; buyer name on cover via Amazon Custom. Easy Ship FBM.'),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent', l.is_parent, 'title', l.title,
        'price', l.price, 'mrp', l.mrp, 'stock', l.quantity, 'dispatch_days', l.handling_days, 'status', l.status,
        'wins_add_to_cart', l.has_buybox, 'add_to_cart_price', l.buybox_price, 'add_to_cart_seller', l.buybox_seller,
        'photos', jsonb_array_length(coalesce(l.images, '[]')),
        'has_swatch_photo', l.attributes ? 'swatch_product_image_locator',
        'bullets', CASE WHEN p_sku IS NULL OR l.sku = p_sku THEN l.bullets END,
        'description', CASE WHEN l.sku = p_sku THEN left(l.description, 2000) END,
        'backend_terms', CASE WHEN l.sku = p_sku THEN l.backend_terms END,
        'amazon_issues', CASE WHEN l.sku = p_sku THEN l.issues END,
        'details', (SELECT jsonb_object_agg(k, l.attributes->k->0->'value') FROM jsonb_object_keys(coalesce(l.attributes, '{}')) k
                     WHERE k IN ('color', 'size', 'paper_size', 'pages', 'page_count', 'ruling_type', 'style', 'pattern', 'binding', 'theme'))
      ) ORDER BY l.asin) FROM public.amazon_listings l), '[]'),
    'competitors', coalesce((SELECT jsonb_agg(to_jsonb(c) - 'id') FROM (SELECT * FROM public.amazon_competitors LIMIT 20) c), '[]'),
    'keywords', coalesce((SELECT jsonb_agg(keyword) FROM (SELECT keyword FROM public.amazon_keywords WHERE status <> 'rejected' ORDER BY updated_at DESC LIMIT 40) k), '[]'),
    'problems', coalesce((SELECT jsonb_agg(jsonb_build_object('id', f.id, 'sku', f.sku, 'code', f.rule_code, 'message', left(f.message, 300)))
       FROM public.amazon_audit_findings f WHERE f.status = 'open' AND (p_sku IS NULL OR f.sku = p_sku)), '[]'),
    'sales_14d', coalesce((SELECT jsonb_agg(jsonb_build_object('day', s.day, 'units', s.units, 'revenue', s.revenue)) FROM (
       SELECT day, sum(units) units, sum(revenue) revenue FROM public.amazon_sales_daily WHERE day > current_date - 14 GROUP BY day ORDER BY day) s), '[]'),
    'health', (SELECT to_jsonb(h) - 'raw' FROM public.amazon_health_daily h ORDER BY day DESC LIMIT 1),
    'waiting_decisions', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'),
    'orders_to_ship', (SELECT count(*) FROM public.amazon_orders WHERE status IN ('Unshipped', 'PartiallyShipped')),
    'recent_chat', coalesce((SELECT jsonb_agg(jsonb_build_object('q', left(question, 500), 'a', left(answer, 800)) ORDER BY created_at) FROM (
       SELECT question, answer, created_at FROM public.amazon_claude_requests WHERE kind IN ('chat', 'question') AND status = 'answered'
        ORDER BY created_at DESC LIMIT 6) c), '[]'),
    'rejected_before', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', q.sku, 'summary', q.summary, 'reason', q.reject_reason)) FROM (
       SELECT sku, summary, reject_reason FROM public.amazon_change_queue WHERE status = 'rejected' AND reject_reason IS NOT NULL
          AND reject_reason <> 'Edited before approval' AND (p_sku IS NULL OR sku = p_sku) ORDER BY updated_at DESC LIMIT 15) q), '[]'))
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_bridge_claim(p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests;
BEGIN
  UPDATE public.amazon_claude_requests SET status = 'waiting', note = 'Retrying after a pause.'
   WHERE status = 'working' AND claimed_at < now() - interval '10 minutes';
  SELECT * INTO r FROM public.amazon_claude_requests
   WHERE status = 'waiting' AND kind IN ('chat', 'question', 'suggest', 'fix')
     AND (note IS NULL OR note NOT LIKE 'Claude limit%' OR claimed_at IS NULL OR claimed_at < now() - interval '10 minutes')
   ORDER BY (kind = 'chat') DESC, (kind = 'suggest') DESC, created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_claude_requests SET status = 'working', claimed_at = now(), attempts = attempts + 1, answered_by = p_by
   WHERE id = r.id RETURNING * INTO r;
  RETURN jsonb_build_object('job', to_jsonb(r), 'context', public.svc_amz_bridge_context(r.sku));
END $$;

-- ---------------------------------------------------------------- Fix All / fix one product
-- One 'fix' request per product that has open problems and no fix already waiting or being worked on.
CREATE OR REPLACE FUNCTION public.api_amz_fix(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s record; n int := 0; skipped int := 0;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Only Admin and people allowed to approve can ask Claude to fix' USING ERRCODE = 'PT403'; END IF;
  FOR s IN SELECT f.sku, string_agg(f.rule_code, ', ' ORDER BY f.id) codes, count(*) c
             FROM public.amazon_audit_findings f WHERE f.status = 'open' AND f.sku IS NOT NULL AND (p_sku IS NULL OR f.sku = p_sku)
            GROUP BY f.sku LOOP
    IF EXISTS (SELECT 1 FROM public.amazon_claude_requests r WHERE r.kind = 'fix' AND r.sku = s.sku AND r.status IN ('waiting', 'working')) THEN
      skipped := skipped + 1; CONTINUE;
    END IF;
    INSERT INTO public.amazon_claude_requests (question, asked_by, kind, sku)
    VALUES (format('Fix the %s open problem(s) on product %s (%s). For each problem give 1 to 3 ranked alternatives.', s.c, s.sku, s.codes),
            crm_private.current_employee_id(), 'fix', s.sku);
    n := n + 1;
  END LOOP;
  PERFORM crm_private.amz_log('fix_requested', 'listing', p_sku, jsonb_build_object('products', n, 'skipped', skipped));
  RETURN jsonb_build_object('queued', n, 'already_waiting', skipped);
END $$;

-- Progress of Fix All (for the Decisions screen).
CREATE OR REPLACE FUNCTION public.api_amz_fix_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT nullif(value, '')::timestamptz INTO seen FROM public.amazon_config WHERE key = 'bridge_seen_at';
  RETURN jsonb_build_object(
    'waiting', (SELECT count(*) FROM public.amazon_claude_requests WHERE kind = 'fix' AND status = 'waiting'),
    'working', (SELECT count(*) FROM public.amazon_claude_requests WHERE kind = 'fix' AND status = 'working'),
    'done_today', (SELECT count(*) FROM public.amazon_claude_requests WHERE kind = 'fix' AND status = 'answered' AND answered_at > now() - interval '1 day'),
    'mac_online', seen IS NOT NULL AND seen > now() - interval '90 seconds');
END $$;

-- Pop-up data for one problem: what is wrong, the current value, and every waiting solution ranked.
CREATE OR REPLACE FUNCTION public.api_amz_problem(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE f public.amazon_audit_findings; l public.amazon_listings;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO f FROM public.amazon_audit_findings WHERE id = p_id;
  IF f.id IS NULL THEN RAISE EXCEPTION 'Problem not found' USING ERRCODE = 'PT404'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = f.sku;
  RETURN jsonb_build_object(
    'problem', to_jsonb(f),
    'product', CASE WHEN l.sku IS NOT NULL THEN jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title, 'price', l.price, 'mrp', l.mrp,
                 'stock', l.quantity, 'buybox_price', l.buybox_price, 'has_buybox', l.has_buybox, 'photo', l.images->0->>'url',
                 'bullets', l.bullets, 'backend_terms', l.backend_terms, 'issues', l.issues) END,
    'fix_waiting', EXISTS (SELECT 1 FROM public.amazon_claude_requests r WHERE r.kind = 'fix' AND r.sku = f.sku AND r.status IN ('waiting', 'working')),
    'solutions', coalesce((SELECT jsonb_agg(to_jsonb(q) ORDER BY coalesce(q.alt_rank, 9), q.created_at)
       FROM public.amazon_change_queue q
      WHERE q.status = 'pending' AND (q.finding_id = f.id OR (q.finding_id IS NULL AND q.sku = f.sku AND q.created_by_type = 'claude'))), '[]'));
END $$;

-- ---------------------------------------------------------------- seller feedback (1-3 stars report)
CREATE TABLE IF NOT EXISTS public.amazon_feedback (
  order_id text NOT NULL,
  day date,
  rating int CHECK (rating BETWEEN 1 AND 5),
  comment text,
  responded boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id));
ALTER TABLE public.amazon_feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_feedback FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.svc_amz_upsert_feedback(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  INSERT INTO public.amazon_feedback AS f (order_id, day, rating, comment, responded)
  -- day = the day we first saw it (the report's date format differs by marketplace), so an alert fires once, promptly
  SELECT it->>'order_id', (now() AT TIME ZONE 'Asia/Kolkata')::date, (it->>'rating')::int, left(it->>'comment', 1000), coalesce((it->>'responded')::boolean, false)
    FROM jsonb_array_elements(coalesce(p_items, '[]')) it
   WHERE coalesce(it->>'order_id', '') <> '' AND (it->>'rating') ~ '^[1-5]$'
  ON CONFLICT (order_id) DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, responded = EXCLUDED.responded;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.svc_amz_alerts_scan();
  RETURN n;
END $$;

-- ---------------------------------------------------------------- alerts (CRM + email)
CREATE TABLE IF NOT EXISTS public.amazon_alerts (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('new_order', 'pickup', 'feedback', 'out_of_stock', 'suppressed')),
  ref text NOT NULL,                     -- order id / sku, makes each alert unique per day
  day date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Kolkata')::date,
  title text NOT NULL,
  body text,
  link text,
  emailed_at timestamptz,
  seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, ref, day));
ALTER TABLE public.amazon_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_alerts FROM anon, authenticated;

INSERT INTO public.amazon_rules (code, label, severity, value) VALUES
  ('alerts', 'Phone/email alerts: pickup reminder hour (IST) and which alerts to send', 'warning',
   '{"pickup_reminder_hour": 11, "email": true}')
ON CONFLICT (code) DO NOTHING;

-- Creates alerts from current data. Safe to run often: one alert per (kind, ref, IST day).
CREATE OR REPLACE FUNCTION public.svc_amz_alerts_scan() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := 0; k int; hr int := extract(hour FROM now() AT TIME ZONE 'Asia/Kolkata');
  remind int := coalesce((crm_private.amz_rule('alerts')->>'pickup_reminder_hour')::int, 11);
BEGIN
  INSERT INTO public.amazon_alerts (kind, ref, title, body, link)
  SELECT 'new_order', o.order_id, 'New order: ' || coalesce((SELECT string_agg(coalesce(i->>'qty', '1') || ' × ' || left(coalesce(i->>'title', i->>'sku'), 60), ', ')
                                                              FROM jsonb_array_elements(o.items) i), o.units || ' item(s)'),
         'Ship by ' || to_char(o.latest_ship_date AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'),
         'https://sellercentral.amazon.in/orders-v3/order/' || o.order_id
    FROM public.amazon_orders o
   WHERE o.status IN ('Pending', 'Unshipped', 'PartiallyShipped') AND o.purchase_date > now() - interval '2 days'
     AND NOT EXISTS (SELECT 1 FROM public.amazon_alerts a WHERE a.kind = 'new_order' AND a.ref = o.order_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  IF hr >= remind AND hr < 12 THEN
    INSERT INTO public.amazon_alerts (kind, ref, title, body, link)
    SELECT 'pickup', o.order_id, 'Book the Easy Ship pickup before 12 noon', 'Order ' || o.order_id || ' is not scheduled yet.',
           'https://sellercentral.amazon.in/orders-v3/order/' || o.order_id
      FROM public.amazon_orders o
     WHERE o.status = 'Unshipped' AND coalesce(o.easy_ship_status, 'PendingSchedule') = 'PendingSchedule'
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END IF;
  INSERT INTO public.amazon_alerts (kind, ref, title, body, link)
  SELECT 'feedback', f.order_id, f.rating || '-star seller feedback', left(coalesce(f.comment, ''), 300),
         'https://sellercentral.amazon.in/feedback-manager/index.html'
    FROM public.amazon_feedback f WHERE f.rating <= 2 AND f.day > (now() AT TIME ZONE 'Asia/Kolkata')::date - 14
     AND NOT EXISTS (SELECT 1 FROM public.amazon_alerts a WHERE a.kind = 'feedback' AND a.ref = f.order_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  INSERT INTO public.amazon_alerts (kind, ref, title, body)
  SELECT 'out_of_stock', l.sku, 'Out of stock: ' || left(l.title, 70), 'It stops selling until you add stock.'
    FROM public.amazon_listings l WHERE NOT coalesce(l.is_parent, false) AND l.quantity = 0
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  DELETE FROM public.amazon_alerts WHERE created_at < now() - interval '60 days';
  RETURN n;
END $$;

-- For the scheduled email: alerts not yet emailed (marks them emailed in the same step).
CREATE OR REPLACE FUNCTION public.svc_amz_alerts_for_email() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  PERFORM public.svc_amz_alerts_scan();
  WITH x AS (UPDATE public.amazon_alerts SET emailed_at = now() WHERE emailed_at IS NULL AND created_at > now() - interval '1 day'
             RETURNING kind, title, body, link, created_at)
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY created_at), '[]') INTO out FROM x;
  RETURN out;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_alerts(p_mark_seen boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC), '[]') INTO out FROM (
    SELECT id, kind, title, body, link, created_at, seen_at FROM public.amazon_alerts
     WHERE created_at > now() - interval '3 days' ORDER BY created_at DESC LIMIT 30) a;
  IF p_mark_seen THEN UPDATE public.amazon_alerts SET seen_at = now() WHERE seen_at IS NULL; END IF;
  RETURN out;
END $$;

-- Orders upsert now also scans for alerts.
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_orders(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  INSERT INTO public.amazon_orders AS o (order_id, purchase_date, status, latest_ship_date, ship_service, easy_ship_status, units, total, items, updated_at)
  SELECT it->>'order_id', (it->>'purchase_date')::timestamptz, it->>'status', (it->>'latest_ship_date')::timestamptz,
         it->>'ship_service', it->>'easy_ship_status', coalesce((it->>'units')::int, 0), (it->>'total')::numeric,
         coalesce(it->'items', '[]'), now()
    FROM jsonb_array_elements(coalesce(p_items, '[]')) it WHERE coalesce(it->>'order_id', '') <> ''
  ON CONFLICT (order_id) DO UPDATE SET status = EXCLUDED.status, latest_ship_date = EXCLUDED.latest_ship_date,
    ship_service = EXCLUDED.ship_service, easy_ship_status = EXCLUDED.easy_ship_status, units = EXCLUDED.units, total = EXCLUDED.total,
    items = CASE WHEN jsonb_array_length(EXCLUDED.items) > 0 THEN EXCLUDED.items ELSE o.items END, updated_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM public.amazon_orders WHERE purchase_date < now() - interval '90 days';
  PERFORM public.svc_amz_alerts_scan();
  RETURN n;
END $$;

-- Chat limit counts chat messages only (Fix All requests must not block chatting).
CREATE OR REPLACE FUNCTION public.api_amz_chat_send(p_text text, p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; n int;
BEGIN
  PERFORM crm_private.amz_require_view();
  PERFORM crm_private.amz_require_chat();
  IF length(trim(coalesce(p_text, ''))) < 2 THEN RAISE EXCEPTION 'Type a message first' USING ERRCODE = 'PT422'; END IF;
  SELECT count(*) INTO n FROM public.amazon_claude_requests WHERE kind = 'chat' AND status IN ('waiting', 'working') AND asked_by IS NOT DISTINCT FROM crm_private.current_employee_id();
  IF n >= 10 THEN RAISE EXCEPTION 'Claude already has 10 messages from you waiting. Please wait for answers.' USING ERRCODE = 'PT429'; END IF;
  INSERT INTO public.amazon_claude_requests (question, asked_by, kind, sku)
  VALUES (left(trim(p_text), 4000), crm_private.current_employee_id(), 'chat', nullif(p_sku, ''))
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

-- Alert email recipients (Admin edits them in Settings). Stored as a JSON array in amazon_config.
CREATE OR REPLACE FUNCTION public.api_amz_alert_emails(p_emails jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_emails IS NOT NULL THEN
    PERFORM crm_private.amz_require_admin();
    IF jsonb_typeof(p_emails) <> 'array' THEN RAISE EXCEPTION 'Send a list of emails' USING ERRCODE = 'PT422'; END IF;
    SELECT coalesce(jsonb_agg(DISTINCT lower(trim(e))), '[]') INTO clean FROM jsonb_array_elements_text(p_emails) e WHERE trim(e) <> '';
    IF jsonb_array_length(clean) > 10 THEN RAISE EXCEPTION 'At most 10 emails' USING ERRCODE = 'PT422'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(clean) e WHERE e !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN
      RAISE EXCEPTION 'One of the emails is not valid' USING ERRCODE = 'PT422';
    END IF;
    INSERT INTO public.amazon_config (key, value) VALUES ('alert_emails', clean::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.amz_log('alert_emails_set', 'settings', NULL, jsonb_build_object('count', jsonb_array_length(clean)));
  END IF;
  RETURN coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'alert_emails'), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_alert_recipients() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'alert_emails'), '[]')
$$;

-- ---------------------------------------------------------------- grants
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_fix(text)', 'public.api_amz_fix_status()', 'public.api_amz_alert_emails(jsonb)', 'public.api_amz_problem(bigint)', 'public.api_amz_alerts(boolean)',
    'public.api_amz_draft_create(text, text, jsonb, text, uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_bridge_answer(bigint, text, jsonb, jsonb, text)', 'public.svc_amz_bridge_context(text)',
    'public.svc_amz_bridge_claim(text)', 'public.svc_amz_upsert_feedback(jsonb)', 'public.svc_amz_alerts_scan()',
    'public.svc_amz_alerts_for_email()', 'public.svc_amz_upsert_orders(jsonb)', 'public.svc_amz_alert_recipients()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION crm_private.amz_close_siblings() FROM PUBLIC, anon, authenticated;
