-- 078: Decisions inbox, Live Claude chat (Mac Mini helper), orders to ship, morning summary, low stock, weekly report.
--
-- Live Claude: a helper on the owner's Mac Mini runs Claude Code on the Max subscription. It talks ONLY to the
-- amazon-bridge Edge Function with a bridge token (stored here as a SHA-256 hash, shown once in Settings).
-- Claude can answer and can draft changes (created_by_type 'claude', status pending). It can never approve or publish.
-- When the Mac is offline, messages wait; the hourly scheduled Claude task answers them as a fallback.
-- Re-runnable.

-- ---------------------------------------------------------------- requests become a chat
ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_status_check;
ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_status_check
  CHECK (status IN ('waiting', 'working', 'answered', 'cancelled'));
ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_kind_chk;
ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_kind_chk
  CHECK (kind IN ('question', 'suggest', 'chat', 'report'));
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS attempts int NOT NULL DEFAULT 0;
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS answered_by text;      -- 'mac' | 'scheduled'
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS note text;             -- e.g. "Claude limit reached, retrying"
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS draft_ids jsonb NOT NULL DEFAULT '[]';
CREATE INDEX IF NOT EXISTS idx_amz_req_wait ON public.amazon_claude_requests (status, created_at) WHERE status IN ('waiting', 'working');

-- Why a change is suggested (shown on the Decisions card) and which chat message it came from.
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS reason text;
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS request_id bigint;

-- ---------------------------------------------------------------- orders (no buyer personal data)
CREATE TABLE IF NOT EXISTS public.amazon_orders (
  order_id text PRIMARY KEY,
  purchase_date timestamptz,
  status text,                       -- Pending, Unshipped, PartiallyShipped, Shipped, Canceled ...
  latest_ship_date timestamptz,
  ship_service text,
  easy_ship_status text,
  units int NOT NULL DEFAULT 0,
  total numeric,
  items jsonb NOT NULL DEFAULT '[]', -- [{sku, asin, title, qty}]
  updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.amazon_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_orders FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS idx_amz_orders_ship ON public.amazon_orders (status, latest_ship_date);

INSERT INTO public.amazon_rules (code, label, severity, value) VALUES
  ('low_stock', 'Warn when stock falls below this number', 'warning', '{"min": 10}'),
  ('pickup_cutoff', 'Easy Ship same-day pickup must be booked before this time (IST)', 'warning', '{"time": "12:00"}')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------- internal draft (Claude / system)
CREATE OR REPLACE FUNCTION crm_private.amz_draft_internal(p_kind text, p_sku text, p_after jsonb, p_summary text,
  p_reason text, p_by text, p_request bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; clean jsonb; bef jsonb; q public.amazon_change_queue;
BEGIN
  IF p_kind NOT IN ('listing', 'price', 'dispatch') OR jsonb_typeof(p_after) IS DISTINCT FROM 'object' THEN RETURN NULL; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_object_agg(k, v), '{}') INTO clean FROM jsonb_each(coalesce(p_after, '{}')) e(k, v)
   WHERE k IN ('title','bullets','description','backend_terms','price','mrp','handling_days','quantity','attributes');
  IF clean = '{}' THEN RETURN NULL; END IF;
  bef := coalesce(crm_private.amz_snapshot(p_sku), '{}');
  IF clean ? 'attributes' AND jsonb_typeof(clean->'attributes') = 'object' THEN
    bef := bef || jsonb_build_object('attributes', (SELECT coalesce(jsonb_object_agg(k, coalesce(l.attributes->k, 'null'::jsonb)), '{}')
                                                     FROM jsonb_object_keys(clean->'attributes') k));
  END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, created_by_type, reason, request_id)
  VALUES (p_kind, p_sku, l.asin, left(coalesce(nullif(trim(p_summary), ''), 'Suggested change'), 300), bef, clean, l.version,
          CASE WHEN p_by IN ('claude', 'system') THEN p_by ELSE 'claude' END, left(p_reason, 600), p_request)
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind, 'by', p_by));
  RETURN q.id;
END $$;

-- ---------------------------------------------------------------- Decisions
-- Edit a waiting suggestion and approve the edited version in one step. The original is closed as "edited".
CREATE OR REPLACE FUNCTION public.api_amz_revise(p_id uuid, p_after jsonb, p_second_confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.amazon_change_queue; c jsonb; a jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You cannot approve changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO o FROM public.amazon_change_queue WHERE id = p_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Change not found' USING ERRCODE = 'PT404'; END IF;
  IF o.status <> 'pending' THEN RAISE EXCEPTION 'This change is no longer waiting' USING ERRCODE = 'PT409'; END IF;
  c := public.api_amz_draft_create(o.kind, o.sku, p_after, o.summary, NULL);
  UPDATE public.amazon_change_queue SET reason = o.reason, request_id = o.request_id WHERE id = (c->>'id')::uuid;
  IF NOT coalesce((c->'guard_result'->>'ok')::boolean, false) THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', error = 'Edited version did not pass the checks.' WHERE id = (c->>'id')::uuid;
    RETURN jsonb_build_object('status', 'blocked', 'guard_result', c->'guard_result');
  END IF;
  IF coalesce((c->>'needs_second_confirm')::boolean, false) AND NOT coalesce(p_second_confirm, false) THEN
    UPDATE public.amazon_change_queue SET status = 'cancelled', error = 'Needs a second look.' WHERE id = (c->>'id')::uuid;
    RETURN jsonb_build_object('status', 'confirm', 'guard_result', c->'guard_result');
  END IF;
  UPDATE public.amazon_change_queue SET status = 'rejected', reject_reason = 'Edited before approval' WHERE id = p_id;
  a := public.api_amz_approve((c->>'id')::uuid, coalesce(p_second_confirm, false));
  RETURN jsonb_build_object('status', a->>'status', 'id', a->>'id', 'guard_result', a->'guard_result');
END $$;

-- Decisions list with what the card needs (photo, product name, why).
CREATE OR REPLACE FUNCTION public.api_amz_decisions(p_status text DEFAULT 'open') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort') FROM (
    SELECT to_jsonb(q) || jsonb_build_object(
             'photo', l.images->0->>'url', 'product', l.title, 'sort',
             CASE q.status WHEN 'pending' THEN '0' WHEN 'needs_manual' THEN '1' WHEN 'failed' THEN '2' WHEN 'stale' THEN '3' ELSE '9' END
               || to_char(9999999999 - extract(epoch FROM q.created_at), 'FM0000000000')) x
      FROM public.amazon_change_queue q LEFT JOIN public.amazon_listings l ON l.sku = q.sku
     WHERE CASE coalesce(p_status, 'open')
             WHEN 'open' THEN q.status IN ('pending', 'approved', 'executing', 'needs_manual', 'failed', 'stale')
             WHEN 'done' THEN q.status IN ('live')
             WHEN 'rejected' THEN q.status IN ('rejected', 'cancelled')
             ELSE true END
       AND q.created_at > now() - interval '60 days'
     ORDER BY q.created_at DESC LIMIT 200) s), '[]');
END $$;

-- ---------------------------------------------------------------- Live Claude chat
CREATE OR REPLACE FUNCTION crm_private.amz_require_chat() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.amz_can_approve() THEN
    RAISE EXCEPTION 'Only Admin and people allowed to approve can chat with Claude' USING ERRCODE = 'PT403';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_chat_send(p_text text, p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; n int;
BEGIN
  PERFORM crm_private.amz_require_view();
  PERFORM crm_private.amz_require_chat();
  IF length(trim(coalesce(p_text, ''))) < 2 THEN RAISE EXCEPTION 'Type a message first' USING ERRCODE = 'PT422'; END IF;
  SELECT count(*) INTO n FROM public.amazon_claude_requests WHERE status IN ('waiting', 'working') AND asked_by IS NOT DISTINCT FROM crm_private.current_employee_id();
  IF n >= 10 THEN RAISE EXCEPTION 'Claude already has 10 messages from you waiting. Please wait for answers.' USING ERRCODE = 'PT429'; END IF;
  INSERT INTO public.amazon_claude_requests (question, asked_by, kind, sku)
  VALUES (left(trim(p_text), 4000), crm_private.current_employee_id(), 'chat', nullif(p_sku, ''))
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_chat(p_limit int DEFAULT 40) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz;
BEGIN
  PERFORM crm_private.amz_require_view();
  PERFORM crm_private.amz_require_chat();
  SELECT nullif(value, '')::timestamptz INTO seen FROM public.amazon_config WHERE key = 'bridge_seen_at';
  RETURN jsonb_build_object(
    'online', seen IS NOT NULL AND seen > now() - interval '90 seconds',
    'seen_at', seen,
    'connected', EXISTS (SELECT 1 FROM public.amazon_config WHERE key = 'bridge_token_hash' AND coalesce(value, '') <> ''),
    'messages', coalesce((SELECT jsonb_agg(m ORDER BY m.created_at) FROM (
       SELECT id, kind, question, answer, status, note, created_at, answered_at, answered_by, draft_ids
         FROM public.amazon_claude_requests WHERE kind IN ('chat', 'question') AND status <> 'cancelled'
        ORDER BY created_at DESC LIMIT greatest(1, least(coalesce(p_limit, 40), 200))) m), '[]'));
END $$;

-- Bridge token (Admin): created once, shown once, stored as a hash. Revoking disconnects the Mac at once.
CREATE OR REPLACE FUNCTION public.api_amz_bridge_token_new() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := 'nitb_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
BEGIN
  PERFORM crm_private.amz_require_admin();
  INSERT INTO public.amazon_config (key, value) VALUES ('bridge_token_hash', encode(sha256(convert_to(t, 'UTF8')), 'hex'))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.amz_log('bridge_token_created', 'settings', NULL, '{}');
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_bridge_token_revoke() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_admin();
  DELETE FROM public.amazon_config WHERE key IN ('bridge_token_hash', 'bridge_seen_at');
  PERFORM crm_private.amz_log('bridge_token_revoked', 'settings', NULL, '{}');
END $$;

-- Service side (amazon-bridge Edge Function only).
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_ok(p_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE h text;
BEGIN
  SELECT value INTO h FROM public.amazon_config WHERE key = 'bridge_token_hash';
  IF h IS NULL OR p_token IS NULL OR length(p_token) < 40 OR encode(sha256(convert_to(p_token, 'UTF8')), 'hex') <> h THEN RETURN false; END IF;
  INSERT INTO public.amazon_config (key, value) VALUES ('bridge_seen_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN true;
END $$;

-- Compact, read-only picture of the store for Claude (no keys, no buyer data).
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_context(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'today_ist', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'rules', jsonb_build_object('price_floor', 299, 'title_max_chars', 75, 'bullet_max', 10, 'backend_terms_bytes', 249,
              'note', 'Generic brand (no Brand Registry). Personalised diaries; buyer name on cover via Amazon Custom. Easy Ship FBM.'),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent', l.is_parent, 'title', l.title,
        'price', l.price, 'mrp', l.mrp, 'stock', l.quantity, 'dispatch_days', l.handling_days, 'status', l.status,
        'wins_add_to_cart', l.has_buybox, 'add_to_cart_price', l.buybox_price, 'photos', jsonb_array_length(coalesce(l.images, '[]')),
        'bullets', CASE WHEN p_sku IS NULL OR l.sku = p_sku THEN l.bullets END,
        'description', CASE WHEN l.sku = p_sku THEN left(l.description, 2000) END,
        'backend_terms', CASE WHEN l.sku = p_sku THEN l.backend_terms END,
        'details', (SELECT jsonb_object_agg(k, l.attributes->k->0->'value') FROM jsonb_object_keys(coalesce(l.attributes, '{}')) k
                     WHERE k IN ('color', 'size', 'paper_size', 'pages', 'page_count', 'ruling_type', 'style', 'pattern', 'binding', 'theme'))
      ) ORDER BY l.asin) FROM public.amazon_listings l), '[]'),
    'problems', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', f.sku, 'code', f.rule_code, 'message', left(f.message, 200)))
       FROM public.amazon_audit_findings f WHERE f.status = 'open'), '[]'),
    'sales_14d', coalesce((SELECT jsonb_agg(jsonb_build_object('day', s.day, 'units', s.units, 'revenue', s.revenue)) FROM (
       SELECT day, sum(units) units, sum(revenue) revenue FROM public.amazon_sales_daily WHERE day > current_date - 14 GROUP BY day ORDER BY day) s), '[]'),
    'health', (SELECT to_jsonb(h) - 'raw' FROM public.amazon_health_daily h ORDER BY day DESC LIMIT 1),
    'waiting_decisions', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'),
    'orders_to_ship', (SELECT count(*) FROM public.amazon_orders WHERE status IN ('Unshipped', 'PartiallyShipped')),
    'recent_chat', coalesce((SELECT jsonb_agg(jsonb_build_object('q', left(question, 500), 'a', left(answer, 800)) ORDER BY created_at) FROM (
       SELECT question, answer, created_at FROM public.amazon_claude_requests WHERE kind IN ('chat', 'question') AND status = 'answered'
        ORDER BY created_at DESC LIMIT 6) c), '[]'))
$$;

-- Take the next message (oldest first). Messages stuck in "working" for 10 minutes go back to the queue.
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_claim(p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests;
BEGIN
  UPDATE public.amazon_claude_requests SET status = 'waiting', note = 'Retrying after a pause.'
   WHERE status = 'working' AND claimed_at < now() - interval '10 minutes';
  SELECT * INTO r FROM public.amazon_claude_requests
   WHERE status = 'waiting' AND kind IN ('chat', 'question', 'suggest')
     AND (note IS NULL OR note NOT LIKE 'Claude limit%' OR claimed_at IS NULL OR claimed_at < now() - interval '10 minutes')
   ORDER BY (kind = 'chat') DESC, created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_claude_requests SET status = 'working', claimed_at = now(), attempts = attempts + 1, answered_by = p_by
   WHERE id = r.id RETURNING * INTO r;
  RETURN jsonb_build_object('job', to_jsonb(r), 'context', public.svc_amz_bridge_context(r.sku));
END $$;

-- Save Claude's answer; drafts become pending Decisions (never approved here).
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_answer(p_id bigint, p_answer text, p_options jsonb DEFAULT NULL,
  p_drafts jsonb DEFAULT NULL, p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; d jsonb; did uuid; ids jsonb := '[]'; n int := 0;
BEGIN
  SELECT * INTO r FROM public.amazon_claude_requests WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('waiting', 'working') THEN RETURN jsonb_build_object('saved', false); END IF;
  IF jsonb_typeof(p_drafts) = 'array' THEN
    FOR d IN SELECT * FROM jsonb_array_elements(p_drafts) LIMIT 30 LOOP
      did := crm_private.amz_draft_internal(d->>'kind', d->>'sku', d->'after', d->>'summary', d->>'reason', 'claude', p_id);
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

-- Could not answer now (Claude limit, Mac error). After 3 tries the user gets a clear message instead of waiting forever.
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_release(p_id bigint, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.amazon_claude_requests SET
    status = CASE WHEN attempts >= 3 THEN 'answered' ELSE 'waiting' END,
    answer = CASE WHEN attempts >= 3 THEN 'Sorry, I could not answer this (' || left(coalesce(p_note, 'unknown error'), 200) || '). Please ask again.' ELSE answer END,
    answered_at = CASE WHEN attempts >= 3 THEN now() ELSE answered_at END,
    note = left(p_note, 300), claimed_at = now()
   WHERE id = p_id AND status = 'working';
END $$;

-- Weekly report written by the scheduled Claude task.
CREATE OR REPLACE FUNCTION public.svc_amz_report_save(p_text text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i bigint;
BEGIN
  INSERT INTO public.amazon_claude_requests (question, kind, status, answer, answered_at, answered_by)
  VALUES ('Weekly report ' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY'), 'report', 'answered', left(p_text, 8000), now(), 'scheduled')
  RETURNING id INTO i;
  RETURN i;
END $$;

-- ---------------------------------------------------------------- orders
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
  RETURN n;
END $$;

-- Orders that still need items fetched (only open ones, newest first).
CREATE OR REPLACE FUNCTION public.svc_amz_orders_without_items() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(order_id), '[]') FROM (
    SELECT order_id FROM public.amazon_orders WHERE items = '[]' AND status IN ('Pending', 'Unshipped', 'PartiallyShipped')
     ORDER BY purchase_date DESC LIMIT 20) o
$$;

-- ---------------------------------------------------------------- Home: one morning summary
CREATE OR REPLACE FUNCTION public.api_amz_home() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; lowmin int;
BEGIN
  PERFORM crm_private.amz_require_view();
  lowmin := coalesce((crm_private.amz_rule('low_stock')->>'min')::int, 10);
  RETURN jsonb_build_object(
    'today', today,
    'yesterday', (SELECT jsonb_build_object('units', coalesce(sum(units), 0), 'revenue', coalesce(sum(revenue), 0))
                    FROM public.amazon_sales_daily WHERE day = today - 1),
    'week', (SELECT jsonb_build_object('units', coalesce(sum(units), 0), 'revenue', coalesce(sum(revenue), 0))
               FROM public.amazon_sales_daily WHERE day > today - 7),
    'to_ship', coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', o.order_id, 'purchase_date', o.purchase_date, 'status', o.status,
                 'latest_ship_date', o.latest_ship_date, 'easy_ship_status', o.easy_ship_status, 'units', o.units, 'items', o.items,
                 'photo', (SELECT l.images->0->>'url' FROM public.amazon_listings l WHERE l.sku = o.items->0->>'sku'))
                 ORDER BY o.latest_ship_date NULLS LAST)
               FROM public.amazon_orders o WHERE o.status IN ('Pending', 'Unshipped', 'PartiallyShipped')), '[]'),
    'orders_synced_at', (SELECT max(updated_at) FROM public.amazon_orders),
    'low_stock', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', sku, 'title', title, 'stock', quantity, 'photo', images->0->>'url') ORDER BY quantity)
                 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) AND quantity IS NOT NULL AND quantity < lowmin), '[]'),
    'low_stock_min', lowmin,
    'decisions', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'),
    'report', (SELECT jsonb_build_object('id', id, 'text', answer, 'at', answered_at) FROM public.amazon_claude_requests
                WHERE kind = 'report' AND status = 'answered' ORDER BY answered_at DESC LIMIT 1));
END $$;

-- ---------------------------------------------------------------- grants
REVOKE ALL ON FUNCTION crm_private.amz_draft_internal(text, text, jsonb, text, text, text, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_private.amz_require_chat() FROM PUBLIC, anon, authenticated;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_revise(uuid, jsonb, boolean)', 'public.api_amz_decisions(text)',
    'public.api_amz_chat_send(text, text)', 'public.api_amz_chat(int)', 'public.api_amz_bridge_token_new()',
    'public.api_amz_bridge_token_revoke()', 'public.api_amz_home()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_bridge_ok(text)', 'public.svc_amz_bridge_context(text)', 'public.svc_amz_bridge_claim(text)',
    'public.svc_amz_bridge_answer(bigint, text, jsonb, jsonb, text)', 'public.svc_amz_bridge_release(bigint, text)',
    'public.svc_amz_report_save(text)', 'public.svc_amz_upsert_orders(jsonb)', 'public.svc_amz_orders_without_items()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
