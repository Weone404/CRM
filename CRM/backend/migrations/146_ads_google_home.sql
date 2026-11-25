-- 146 ADS > Google Ads: the simple home screen (owner approved, 25 Nov 2026).
-- What it adds:
--   balance      the prepaid balance, read from Google itself. For a prepaid account Google's "account budget" is the running
--                total of every payment (after tax) and of everything served; what is left = spending limit - amount served.
--                Checked on 25 Nov 2026 against this account: limit 170,552.31, served 170,552.22, ads stopped => 0.09 left.
--                Nobody types an amount any more. A rise of the limit is recorded as a top-up, by itself.
--   budget_set   new owner-only operation: one daily amount for the whole account, shared between the switched-on campaigns
--                in their present proportions, sent to Google as one request (all campaigns change or none).
--   home         one read for the screen: status in plain words, money, budget, who sees the ads, results, what needs the owner.
-- Layered like 144/145: the 145 gate is renamed to ads_google_gate_v145 and the new gate calls it for everything it knew.
-- IMPORTANT for later migrations: add a layer the same way; never replace crm_private.ads_google_gate with a full body.
-- budget_set runs in ads-google-ops. Run it twice safely. Rollback: 146_ads_google_home_down.sql. Needs 145.

ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget',
    'campaign_create', 'income_filter', 'ad_schedule', 'budget_set'));

INSERT INTO public.ads_rules (code, label, severity, value) VALUES
  ('g_daily_total', 'Daily budget set on the Google Ads home screen', 'blocker', '{"min": 100, "max": 5000}')
ON CONFLICT (code) DO NOTHING;
-- Plain names for the screen (campaign id -> name), and the areas the owner has not switched on yet. Both are only shown.
INSERT INTO public.ads_config (key, value) VALUES
  ('google_campaign_labels', '{"24283129095": "Delhi NCR", "24542430627": "Punjab & Chandigarh (online)"}'),
  ('google_areas_waiting', '[{"name": "Tier 2", "places": "Jaipur, Lucknow, Udaipur, Sonipat, Panipat"}, {"name": "Tier 3", "places": "Mumbai, Bengaluru, Hyderabad, Pune, Chennai, Kolkata, Ahmedabad"}]')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- balance
CREATE TABLE IF NOT EXISTS public.ads_google_balance (
  account_id uuid PRIMARY KEY REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'none' CHECK (kind IN ('prepaid', 'no_limit', 'none')),   -- none = Google reports no account budget
  spending_limit numeric(16,2), served numeric(16,2), available numeric(16,2),
  checked_at timestamptz,                        -- last good read from Google
  error text, error_at timestamptz,              -- last failed read (the figures above stay as they were)
  asked_at timestamptz, watch_until timestamptz, -- "I added money": checked every 5 minutes until then
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.ads_google_topups (
  id bigserial PRIMARY KEY,
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  credit numeric(16,2) NOT NULL CHECK (credit > 0),      -- what Google added to the spending limit (after tax)
  limit_after numeric(16,2) NOT NULL,
  seen_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_google_topups_account ON public.ads_google_topups (account_id, seen_at DESC);
ALTER TABLE public.ads_google_balance ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_google_topups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_google_balance, public.ads_google_topups FROM anon, authenticated;

-- Rows of one snapshot kind (nothing when the snapshot holds an error instead of rows).
CREATE OR REPLACE FUNCTION crm_private.ads_google_snap(p_account uuid, p_kind text) RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_array_elements(CASE WHEN jsonb_typeof(s.data) = 'array' THEN s.data ELSE '[]'::jsonb END)
    FROM public.ads_google_snapshot s WHERE s.account_id = p_account AND s.kind = p_kind
$$;
REVOKE ALL ON FUNCTION crm_private.ads_google_snap(uuid, text) FROM PUBLIC, anon, authenticated;

-- 'YYYY-MM-DD HH:MM:SS' -> timestamp; a date that does not exist (31 Feb) counts as far in the future, never as an error.
CREATE OR REPLACE FUNCTION crm_private.ads_ts(p text) RETURNS timestamp
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  RETURN p::timestamp;
EXCEPTION WHEN others THEN RETURN 'infinity'::timestamp;
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_ts(text) FROM PUBLIC, anon, authenticated;

-- What ads-google-ops read from Google ({"read": "billing"}). A failed read keeps the last good figures and notes the error.
CREATE OR REPLACE FUNCTION public.svc_ads_google_billing_save(p_account uuid, p_data jsonb, p_at timestamptz DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; rws jsonb := p_data->'account_budget'; ts timestamptz := coalesce(p_at, now()); old public.ads_google_balance;
        lim numeric; srv numeric; n int; nolimit boolean; knd text; avail numeric; rise numeric; err text; tz text;
BEGIN
  SELECT * INTO a FROM public.ads_accounts WHERE id = p_account AND platform = 'google';
  IF a.id IS NULL THEN RAISE EXCEPTION 'not a Google Ads account'; END IF;
  INSERT INTO public.ads_google_balance (account_id) VALUES (p_account) ON CONFLICT (account_id) DO NOTHING;
  SELECT * INTO old FROM public.ads_google_balance WHERE account_id = p_account FOR UPDATE;
  IF jsonb_typeof(rws) IS DISTINCT FROM 'array' THEN
    err := left(coalesce(nullif(rws->>'error', ''), 'Google did not return the account budget.'), 300);
    UPDATE public.ads_google_balance SET error = err, error_at = ts, updated_at = now() WHERE account_id = p_account;
    RETURN jsonb_build_object('saved', false, 'error', err);
  END IF;
  tz := coalesce(a.timezone, 'Asia/Kolkata');
  SELECT count(*), coalesce(sum(x.limv), 0), coalesce(sum(x.srvv), 0), coalesce(bool_or(x.limv IS NULL), false) INTO n, lim, srv, nolimit FROM (
    SELECT CASE WHEN r->>'accountBudget.adjustedSpendingLimitMicros' ~ '^\d{1,18}$' AND coalesce(r->>'accountBudget.adjustedSpendingLimitType', '') <> 'INFINITE'
                THEN (r->>'accountBudget.adjustedSpendingLimitMicros')::numeric / 1000000 END AS limv,
           CASE WHEN r->>'accountBudget.amountServedMicros' ~ '^\d{1,18}$' THEN (r->>'accountBudget.amountServedMicros')::numeric / 1000000 ELSE 0 END AS srvv
      FROM jsonb_array_elements(rws) r
     WHERE r->>'accountBudget.status' = 'APPROVED'
       AND CASE WHEN coalesce(r->>'accountBudget.approvedEndDateTime', '') ~ '^(19|20)\d\d-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01]) ([01]\d|2[0-3]):[0-5]\d:[0-5]\d'
                THEN crm_private.ads_ts(left(r->>'accountBudget.approvedEndDateTime', 19)) > (now() AT TIME ZONE tz) ELSE true END) x;
  knd := CASE WHEN n = 0 THEN 'none' WHEN nolimit THEN 'no_limit' ELSE 'prepaid' END;
  avail := CASE WHEN knd = 'prepaid' THEN round(greatest(lim - srv, 0), 2) END;
  rise := CASE WHEN knd = 'prepaid' AND old.kind = 'prepaid' AND old.spending_limit IS NOT NULL AND old.checked_at IS NOT NULL
               THEN round(lim, 2) - old.spending_limit END;
  UPDATE public.ads_google_balance SET kind = knd, spending_limit = CASE WHEN knd = 'prepaid' THEN round(lim, 2) END,
         served = CASE WHEN knd = 'prepaid' THEN round(srv, 2) END, available = avail, checked_at = ts, error = NULL, error_at = NULL,
         watch_until = CASE WHEN coalesce(rise, 0) >= 1 THEN NULL ELSE watch_until END, updated_at = now()
   WHERE account_id = p_account;
  IF coalesce(rise, 0) >= 1 THEN
    INSERT INTO public.ads_google_topups (account_id, credit, limit_after, seen_at) VALUES (p_account, rise, round(lim, 2), ts);
    INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
    VALUES ('system', 'google_topup_seen', 'account', p_account::text, jsonb_build_object('credit', rise, 'available', avail));
  END IF;
  PERFORM public.svc_ads_google_snapshot_save(p_account, 'billing', p_data);       -- the raw answer, for the AI team
  RETURN jsonb_build_object('saved', true, 'kind', knd, 'available', avail, 'rise', rise);
END $$;
REVOKE ALL ON FUNCTION public.svc_ads_google_billing_save(uuid, jsonb, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_billing_save(uuid, jsonb, timestamptz) TO service_role;

-- The read that proved this (25 Nov 2026) becomes the first balance, with its own time.
DO $$
DECLARE s record;
BEGIN
  FOR s IN SELECT sn.account_id, sn.data, sn.synced_at FROM public.ads_google_snapshot sn
            WHERE sn.kind = 'billing' AND NOT EXISTS (SELECT 1 FROM public.ads_google_balance b WHERE b.account_id = sn.account_id) LOOP
    PERFORM public.svc_ads_google_billing_save(s.account_id, s.data, s.synced_at);
  END LOOP;
END $$;

-- Wakes ads-google-ops (async through pg_net). Never fails the caller; false when it could not be sent (the schedule will).
CREATE OR REPLACE FUNCTION crm_private.ads_google_ops_kick(p_body jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN RETURN false; END IF;
  BEGIN
    EXECUTE $q$SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-google-ops',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := $1, timeout_milliseconds := 140000)$q$ USING p_body;
  EXCEPTION WHEN OTHERS THEN RETURN false;
  END;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_ops_kick(jsonb) FROM PUBLIC, anon, authenticated;

-- "I added money" / "Check now": asks Google again (answer arrives a few seconds later) and keeps checking for two hours.
CREATE OR REPLACE FUNCTION public.api_ads_google_balance_refresh() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; b public.ads_google_balance; sent boolean;
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  IF a.id IS NULL OR a.status IS DISTINCT FROM 'connected' THEN RAISE EXCEPTION 'Connect the Google Ads account first' USING ERRCODE = 'PT409'; END IF;
  INSERT INTO public.ads_google_balance (account_id) VALUES (a.id) ON CONFLICT (account_id) DO NOTHING;
  SELECT * INTO b FROM public.ads_google_balance WHERE account_id = a.id FOR UPDATE;
  IF b.asked_at > now() - interval '10 seconds' THEN
    RETURN jsonb_build_object('asked', false, 'wait', true, 'checked_at', b.checked_at);
  END IF;
  UPDATE public.ads_google_balance SET asked_at = now(), watch_until = now() + interval '2 hours', updated_at = now() WHERE account_id = a.id;
  sent := crm_private.ads_google_ops_kick('{"read": "billing"}'::jsonb);
  RETURN jsonb_build_object('asked', sent, 'wait', false, 'checked_at', b.checked_at);
END $$;
REVOKE ALL ON FUNCTION public.api_ads_google_balance_refresh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_google_balance_refresh() TO authenticated;

-- ---------------------------------------------------------------- gate (one more layer: budget_set)
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_google_gate_v145(uuid,text,jsonb,uuid)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) RENAME TO ads_google_gate_v145;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_gate(p_account uuid, p_kind text, p_payload jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE res jsonb := crm_private.ads_google_gate_v145(p_account, p_kind, p_payload, p_exclude);
        a public.ads_accounts; b jsonb; r jsonb; pt jsonb; gc public.ads_campaigns; tot numeric; v numeric; sm numeric := 0;
        seen text[] := '{}'; ok boolean := true; changed boolean := false; n_on int; capd numeric; cmax numeric; mn numeric;
BEGIN
  IF p_kind IS DISTINCT FROM 'budget_set' THEN RETURN res; END IF;
  SELECT coalesce(jsonb_agg(bl), '[]') INTO b FROM jsonb_array_elements(res->'blockers') bl WHERE bl #>> '{}' <> 'Unknown operation type.';
  SELECT * INTO a FROM public.ads_accounts WHERE id = p_account;
  IF a.id IS NULL OR a.platform <> 'google' OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('blockers', b, 'warnings', coalesce(res->'warnings', '[]'));
  END IF;
  r := crm_private.ads_rule('g_daily_total');
  mn := coalesce((crm_private.ads_rule('budget_min')->>'min')::numeric, 1);
  BEGIN tot := (p_payload->>'daily_total')::numeric; EXCEPTION WHEN others THEN tot := NULL; END;
  IF tot IS NULL OR tot = 'NaN'::numeric OR tot <> round(tot)
     OR tot < coalesce((r->>'min')::numeric, 100) OR tot > coalesce((r->>'max')::numeric, 5000) THEN
    b := b || to_jsonb(format('daily_total must be a whole number from %s to %s.', coalesce(r->>'min', '100'), coalesce(r->>'max', '5000')));
    tot := NULL;
  END IF;
  IF jsonb_typeof(p_payload->'parts') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'parts') NOT BETWEEN 1 AND 20 THEN
    b := b || to_jsonb('parts: one row for every switched-on campaign (campaign_id, daily_budget).'::text);
  ELSE
    FOR pt IN SELECT e FROM jsonb_array_elements(p_payload->'parts') e LOOP
      BEGIN v := (pt->>'daily_budget')::numeric; EXCEPTION WHEN others THEN v := NULL; END;
      IF jsonb_typeof(pt) <> 'object' OR coalesce(pt->>'campaign_id', '') !~ '^\d+$' OR v IS NULL OR v = 'NaN'::numeric
         OR v <> round(v, 2) OR v < mn OR v > 100000000 THEN
        b := b || to_jsonb(format('Every part needs a campaign_id and a daily_budget of at least %s (at most 2 decimals).', mn)); ok := false; EXIT;
      END IF;
      IF (pt->>'campaign_id') = ANY (seen) THEN
        b := b || to_jsonb(format('Campaign %s is listed twice.', pt->>'campaign_id')); ok := false; EXIT;
      END IF;
      seen := seen || (pt->>'campaign_id');
      SELECT * INTO gc FROM public.ads_campaigns WHERE account_id = a.id AND external_id = pt->>'campaign_id';
      IF gc.id IS NULL OR gc.status IS DISTINCT FROM 'ENABLED' THEN
        b := b || to_jsonb(format('Campaign %s is not a switched-on campaign of this account.', pt->>'campaign_id')); ok := false; EXIT;
      END IF;
      IF gc.budget_ref IS NULL OR EXISTS (SELECT 1 FROM public.ads_campaigns c2 WHERE c2.account_id = a.id AND c2.id <> gc.id
                                           AND c2.budget_ref = gc.budget_ref AND coalesce(c2.status, '') <> 'REMOVED') THEN
        b := b || to_jsonb(format('The budget of "%s" is shared with another campaign or not synced; it cannot be changed from here.', gc.name)); ok := false; EXIT;
      END IF;
      sm := sm + v;
      IF v IS DISTINCT FROM gc.daily_budget THEN changed := true; END IF;
    END LOOP;
    IF ok THEN
      SELECT count(*) INTO n_on FROM public.ads_campaigns WHERE account_id = a.id AND status = 'ENABLED';
      IF n_on <> coalesce(array_length(seen, 1), 0) THEN
        b := b || to_jsonb(format('parts must list every switched-on campaign once (%s are on, %s listed).', n_on, coalesce(array_length(seen, 1), 0)));
      END IF;
      IF tot IS NOT NULL AND sm <> tot THEN
        b := b || to_jsonb(format('The parts add up to %s, not to the daily total of %s.', sm, tot));
      END IF;
      IF NOT changed THEN b := b || to_jsonb('The campaign budgets are already set this way.'::text); END IF;
    END IF;
  END IF;
  capd := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
  IF tot IS NOT NULL AND capd IS NOT NULL AND tot > capd THEN
    b := b || to_jsonb(format('The owner''s daily limit is %s; a total of %s is above it.', capd, tot));
  END IF;
  SELECT cl.max_daily_budget INTO cmax FROM public.ads_clients cl WHERE cl.id = a.client_id;
  IF tot IS NOT NULL AND cmax IS NOT NULL AND tot > cmax THEN
    b := b || to_jsonb(format('The client''s maximum daily budget is %s; a total of %s is above it.', cmax, tot));
  END IF;
  IF EXISTS (SELECT 1 FROM public.ads_google_ops o WHERE o.account_id = p_account AND o.kind = 'budget_set'
              AND o.id IS DISTINCT FROM p_exclude AND o.status IN ('approved', 'executing')) THEN
    b := b || to_jsonb('Another budget change is still being saved to Google.'::text);
  END IF;
  RETURN jsonb_build_object('blockers', b, 'warnings', coalesce(res->'warnings', '[]'));
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate_v145(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- owner only, and who runs it
CREATE OR REPLACE FUNCTION crm_private.ads_google_ops_owner_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.created_by_type = 'agent' AND NEW.status = 'approved' AND NEW.approved_by IS NULL
     AND (NEW.kind IN ('campaign_create', 'income_filter', 'ad_schedule', 'budget_set')
          OR (NEW.kind = 'campaign_geo' AND crm_private.ads_cfg('google_targeting_locked') = 'on')) THEN
    NEW.status := 'pending'; NEW.approved_at := NULL;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind,
      'payload', CASE WHEN o.kind = 'budget' THEN o.payload || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->>'campaign_id'))
        ELSE o.payload END,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind NOT IN ('campaign_create', 'income_filter', 'ad_schedule', 'budget_set')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
-- The executor needs each budget's own resource name; the CRM knows it from the sync.
CREATE OR REPLACE FUNCTION crm_private.ads_google_build_payload(o public.ads_google_ops) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN o.kind = 'campaign_create' AND o.payload ? 'move_budget' THEN o.payload || jsonb_build_object('move_budget_resource',
      (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->'move_budget'->>'campaign_id'))
    WHEN o.kind = 'budget_set' AND jsonb_typeof(o.payload->'parts') = 'array' THEN o.payload || jsonb_build_object('parts',
      (SELECT coalesce(jsonb_agg(t.pt || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = t.pt->>'campaign_id')) ORDER BY t.ord), '[]')
         FROM jsonb_array_elements(o.payload->'parts') WITH ORDINALITY AS t(pt, ord)))
    ELSE o.payload END
$$;
REVOKE ALL ON FUNCTION crm_private.ads_google_build_payload(public.ads_google_ops) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.svc_ads_google_build_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' OR crm_private.ads_cfg('google_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', crm_private.ads_google_build_payload(o),
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind IN ('campaign_create', 'income_filter', 'ad_schedule', 'budget_set')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
CREATE OR REPLACE FUNCTION public.svc_ads_google_build_peek(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', crm_private.ads_google_build_payload(o),
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status)
    FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
   WHERE o.id = p_id AND o.kind IN ('campaign_create', 'income_filter', 'ad_schedule', 'budget_set') AND o.status IN ('pending', 'approved')
$$;
REVOKE ALL ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work(), public.svc_ads_google_build_peek(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work(), public.svc_ads_google_build_peek(uuid) TO service_role;

-- A verified budget change is the CRM's truth at once (the spend limits read ads_campaigns). One that Google never took
-- (failed before anything was sent, or blocked when it was picked up) puts the owner's limits back to what they were.
CREATE OR REPLACE FUNCTION crm_private.ads_google_budget_applied() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.kind = 'budget_set' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'verified' THEN
      UPDATE public.ads_campaigns c SET daily_budget = (pt->>'daily_budget')::numeric
        FROM jsonb_array_elements(NEW.payload->'parts') pt
       WHERE c.account_id = NEW.account_id AND c.external_id = pt->>'campaign_id';
    ELSIF NEW.status IN ('failed', 'stale', 'rejected') AND NEW.result IS NULL AND NEW.payload->'previous'->>'daily' ~ '^\d+(\.\d+)?$'
          AND crm_private.ads_num(crm_private.ads_cfg('google_cap_daily')) = crm_private.ads_num(NEW.payload->>'daily_total') THEN
      UPDATE public.ads_config SET value = NEW.payload->'previous'->>'daily', updated_at = now() WHERE key = 'google_cap_daily';
      UPDATE public.ads_config SET value = NEW.payload->'previous'->>'monthly', updated_at = now()
       WHERE key = 'google_cap_monthly' AND NEW.payload->'previous'->>'monthly' ~ '^\d+(\.\d+)?$';
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_budget_applied() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_ads_google_budget_applied ON public.ads_google_ops;
CREATE TRIGGER trg_ads_google_budget_applied AFTER UPDATE ON public.ads_google_ops
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_google_budget_applied();

CREATE OR REPLACE FUNCTION crm_private.ads_num(p text) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT CASE WHEN p ~ '^\d{1,12}(\.\d{1,4})?$' THEN p::numeric END $$;
REVOKE ALL ON FUNCTION crm_private.ads_num(text) FROM PUBLIC, anon, authenticated;

-- The owner's one number: the daily amount for all of Google Ads. Sets the limits (monthly = 30.4 days, Google's own rule
-- for a month) and shares the amount between the switched-on campaigns as they are shared now.
CREATE OR REPLACE FUNCTION public.api_ads_google_budget_set(p_daily numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; r jsonb := crm_private.ads_rule('g_daily_total'); mnt numeric; mxt numeric; me uuid := crm_private.current_employee_id();
        c record; n int := 0; s numeric := 0; step numeric; parts jsonb := '[]'; others numeric := 0; first_id text; first_name text; v numeric;
        changed boolean := false; capd text := crm_private.ads_cfg('google_cap_daily'); capm text := crm_private.ads_cfg('google_cap_monthly');
        monthly numeric; o public.ads_google_ops; labels jsonb; lbl text; words text := '';
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only people who can approve ADS changes can change the budget' USING ERRCODE = 'PT403'; END IF;
  a := crm_private.ads_google_account();
  IF a.id IS NULL OR a.status IS DISTINCT FROM 'connected' THEN RAISE EXCEPTION 'Connect the Google Ads account first' USING ERRCODE = 'PT409'; END IF;
  mnt := coalesce((r->>'min')::numeric, 100); mxt := coalesce((r->>'max')::numeric, 5000);
  IF p_daily IS NULL OR p_daily = 'NaN'::numeric OR p_daily <> round(p_daily) OR p_daily < mnt OR p_daily > mxt THEN
    RAISE EXCEPTION 'Enter a whole amount from % to % a day', mnt, mxt USING ERRCODE = 'PT422';
  END IF;
  p_daily := round(p_daily, 0);
  IF EXISTS (SELECT 1 FROM public.ads_google_ops x WHERE x.account_id = a.id AND x.kind = 'budget_set' AND x.status IN ('approved', 'executing')) THEN
    RAISE EXCEPTION 'The last budget change is still being saved to Google. Try again in a minute.' USING ERRCODE = 'PT409';
  END IF;
  SELECT count(*), coalesce(sum(x.daily_budget), 0) INTO n, s FROM public.ads_campaigns x WHERE x.account_id = a.id AND x.status = 'ENABLED';
  IF n = 0 THEN RAISE EXCEPTION 'No Google Ads campaign is switched on' USING ERRCODE = 'PT409'; END IF;
  IF p_daily < n * 10 THEN RAISE EXCEPTION '% campaigns are on; the daily amount must be at least %', n, n * 10 USING ERRCODE = 'PT422'; END IF;
  BEGIN labels := crm_private.ads_cfg('google_campaign_labels')::jsonb; EXCEPTION WHEN others THEN labels := '{}'; END;
  step := CASE WHEN p_daily % 10 = 0 THEN 10 ELSE 1 END;
  -- every campaign but the largest gets its share, rounded; the largest takes the rest, so the parts always add up
  FOR c IN SELECT x.external_id, x.name, coalesce(x.daily_budget, 0) AS cur FROM public.ads_campaigns x
            WHERE x.account_id = a.id AND x.status = 'ENABLED' ORDER BY coalesce(x.daily_budget, 0) DESC, x.external_id LOOP
    IF first_id IS NULL THEN first_id := c.external_id; first_name := c.name; CONTINUE; END IF;
    v := greatest(10, round(p_daily * CASE WHEN s > 0 THEN c.cur / s ELSE 1.0 / n END / step) * step);
    others := others + v;
    parts := parts || jsonb_build_object('campaign_id', c.external_id, 'daily_budget', v);
    IF v IS DISTINCT FROM c.cur THEN changed := true; END IF;
    lbl := coalesce(labels->>c.external_id, c.name);
    words := words || format(', %s %s', lbl, trim_scale(v));
  END LOOP;
  IF p_daily - others < 10 THEN RAISE EXCEPTION 'That amount is too small to share between % campaigns', n USING ERRCODE = 'PT422'; END IF;
  parts := jsonb_build_array(jsonb_build_object('campaign_id', first_id, 'daily_budget', p_daily - others)) || parts;
  IF (p_daily - others) IS DISTINCT FROM (SELECT coalesce(x.daily_budget, 0) FROM public.ads_campaigns x WHERE x.account_id = a.id AND x.external_id = first_id) THEN
    changed := true;
  END IF;
  words := format('%s %s', coalesce(labels->>first_id, first_name), trim_scale(p_daily - others)) || words;
  monthly := round(p_daily * 30.4);
  IF NOT changed AND crm_private.ads_num(capd) IS NOT DISTINCT FROM p_daily AND crm_private.ads_num(capm) IS NOT DISTINCT FROM monthly THEN
    RETURN jsonb_build_object('changed', false, 'daily', p_daily, 'monthly', monthly, 'parts', parts);
  END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('google_cap_daily', p_daily::text), ('google_cap_monthly', monthly::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('google_budget_set', 'config', 'google_cap_daily',
    jsonb_build_object('daily', p_daily, 'monthly', monthly, 'before', capd, 'parts', parts));
  IF NOT changed THEN
    RETURN jsonb_build_object('changed', true, 'daily', p_daily, 'monthly', monthly, 'parts', parts, 'op', NULL);
  END IF;
  INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, status, created_by_type, created_by, approved_by, approved_at)
  VALUES (a.id, 'budget_set', jsonb_build_object('daily_total', p_daily, 'parts', parts,
            'previous', jsonb_build_object('daily', capd, 'monthly', capm, 'total', trim_scale(s))),
          left(format('Daily budget %s -> %s (%s)', trim_scale(s), p_daily, words), 300), 'Set by the owner on the Google Ads home screen.',
          'approved', 'user', me, me, now())
  RETURNING * INTO o;
  IF o.status <> 'approved' THEN
    RAISE EXCEPTION '%', coalesce(o.gate_result->'blockers'->>0, 'This budget cannot be set right now.') USING ERRCODE = 'PT422';
  END IF;
  PERFORM crm_private.ads_google_ops_kick('{}'::jsonb);
  RETURN jsonb_build_object('changed', true, 'daily', p_daily, 'monthly', monthly, 'parts', parts, 'op', o.id);
END $$;
REVOKE ALL ON FUNCTION public.api_ads_google_budget_set(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_google_budget_set(numeric) TO authenticated;

-- ---------------------------------------------------------------- the screen
CREATE OR REPLACE FUNCTION public.api_ads_google_home(p_days int DEFAULT 7) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; bal public.ads_google_balance; d date; f date; tz text; cur text; tax numeric;
        days int := CASE WHEN p_days IN (7, 30, 90) THEN p_days ELSE 7 END;
        capd numeric; capm numeric; actual numeric; n_on int; basis numeric; floor_amt numeric; dl jsonb; state text; likely boolean := false;
        today_spend numeric; yday_spend numeric; today_clicks numeric; top public.ads_google_topups; fresh_top boolean; days_left numeric;
        labels jsonb; waiting_areas jsonb; r jsonb := crm_private.ads_rule('g_daily_total'); camps jsonb; reviewing jsonb; series jsonb;
        t_spend numeric; t_clicks numeric; t_impr numeric; enq int; called int; called15 int; waiting int; me uuid := crm_private.current_employee_id();
        paused boolean; chg jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  IF a.id IS NULL THEN
    RETURN jsonb_build_object('status', jsonb_build_object('state', 'not_connected'), 'can_edit', crm_private.ads_can_approve(), 'is_admin', crm_private.is_admin());
  END IF;
  SELECT * INTO bal FROM public.ads_google_balance WHERE account_id = a.id;
  d := crm_private.ads_google_today(); f := d - (days - 1);
  tz := coalesce(a.timezone, 'Asia/Kolkata'); cur := coalesce(a.currency, 'INR');
  tax := coalesce(nullif(crm_private.ads_cfg('google_tax_pct'), '')::numeric, CASE WHEN cur = 'INR' THEN 18 ELSE 0 END);
  capd := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
  capm := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
  BEGIN labels := crm_private.ads_cfg('google_campaign_labels')::jsonb; EXCEPTION WHEN others THEN labels := '{}'; END;
  BEGIN waiting_areas := crm_private.ads_cfg('google_areas_waiting')::jsonb; EXCEPTION WHEN others THEN waiting_areas := '[]'; END;
  paused := crm_private.ads_cfg('execution_paused') = 'true' OR crm_private.ads_cfg('google_paused') = 'true';
  SELECT count(*), coalesce(sum(c.daily_budget), 0) INTO n_on, actual FROM public.ads_campaigns c WHERE c.account_id = a.id AND c.status = 'ENABLED';
  basis := CASE WHEN actual > 0 THEN actual ELSE coalesce(capd, 0) END;
  floor_amt := greatest(1, basis * 0.05);                  -- under a twentieth of a day's budget nothing can be shown
  today_spend := crm_private.ads_google_spend(d, d); yday_spend := crm_private.ads_google_spend(d - 1, d - 1);
  SELECT coalesce(sum(m.clicks), 0) INTO today_clicks FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
   WHERE c.account_id = a.id AND m.day = d;
  SELECT * INTO top FROM public.ads_google_topups WHERE account_id = a.id ORDER BY seen_at DESC LIMIT 1;
  fresh_top := top.id IS NOT NULL AND top.seen_at > now() - interval '24 hours';
  days_left := CASE WHEN bal.kind = 'prepaid' AND basis > 0 THEN round(bal.available / basis, 1) END;
  dl := crm_private.ads_google_delivery();

  -- the switched-on campaigns, each with who / where / when / words
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.external_id, 'name', c.name, 'label', coalesce(labels->>c.external_id, c.name), 'daily_budget', c.daily_budget,
      'max_cpc', CASE WHEN sc.e->>'campaign.targetSpend.cpcBidCeilingMicros' ~ '^\d{1,15}$' THEN (sc.e->>'campaign.targetSpend.cpcBidCeilingMicros')::numeric / 1000000 END,
      'primary_status', sc.e->>'campaign.primaryStatus', 'reasons', coalesce(sc.e->'campaign.primaryStatusReasons', '[]'),
      'income_excluded', (SELECT coalesce(o.payload->'exclude', o.payload->'income_exclude') FROM public.ads_google_ops o
          WHERE o.account_id = a.id AND o.status = 'verified'
            AND ((o.kind = 'income_filter' AND o.payload->>'campaign_id' = c.external_id)
              OR (o.kind = 'campaign_create' AND o.payload ? 'income_exclude' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(o.result->'resource_names', '[]')) rn
                    WHERE rn = 'customers/' || a.external_id || '/campaigns/' || c.external_id)))
          ORDER BY o.created_at DESC LIMIT 1),
      'slots', (SELECT o.payload->'slots' FROM public.ads_google_ops o
          WHERE o.account_id = a.id AND o.status = 'verified' AND o.kind = 'ad_schedule' AND o.payload->>'campaign_id' = c.external_id
          ORDER BY o.created_at DESC LIMIT 1),
      'places', (SELECT coalesce(jsonb_agg(coalesce(e->>'place', e->>'campaignCriterion.criterionId')), '[]') FROM crm_private.ads_google_snap(a.id, 'locations') e
          WHERE e->>'campaign.id' = c.external_id AND coalesce(e->>'campaignCriterion.negative', 'false') <> 'true'),
      'keywords_on', (SELECT count(*) FROM crm_private.ads_google_snap(a.id, 'keywords') e WHERE e->>'campaign.id' = c.external_id
          AND coalesce(e->>'adGroupCriterion.negative', 'false') <> 'true' AND e->>'adGroupCriterion.status' = 'ENABLED'),
      'keywords_paused', (SELECT count(*) FROM crm_private.ads_google_snap(a.id, 'keywords') e WHERE e->>'campaign.id' = c.external_id
          AND coalesce(e->>'adGroupCriterion.negative', 'false') <> 'true' AND e->>'adGroupCriterion.status' = 'PAUSED'),
      'examples', (SELECT coalesce(jsonb_agg(x.t), '[]') FROM (SELECT e->>'adGroupCriterion.keyword.text' AS t FROM crm_private.ads_google_snap(a.id, 'keywords') e
          WHERE e->>'campaign.id' = c.external_id AND coalesce(e->>'adGroupCriterion.negative', 'false') <> 'true'
            AND e->>'adGroupCriterion.status' = 'ENABLED' LIMIT 6) x)
    ) ORDER BY c.daily_budget DESC NULLS LAST, c.external_id), '[]') INTO camps
    FROM public.ads_campaigns c
    LEFT JOIN LATERAL (SELECT e FROM crm_private.ads_google_snap(a.id, 'campaigns') e WHERE e->>'campaign.id' = c.external_id LIMIT 1) sc ON true
   WHERE c.account_id = a.id AND c.status = 'ENABLED';
  SELECT coalesce(jsonb_agg(x->>'label'), '[]') INTO reviewing FROM jsonb_array_elements(camps) x
   WHERE jsonb_typeof(x->'reasons') = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(x->'reasons') rs WHERE rs LIKE '%UNDER_REVIEW%');

  state := CASE
    WHEN a.status IS DISTINCT FROM 'connected' THEN 'not_connected'
    WHEN paused THEN 'paused'
    WHEN n_on = 0 THEN 'off'
    WHEN bal.kind = 'prepaid' AND bal.available < floor_amt THEN 'no_money'
    WHEN bal.kind = 'prepaid' AND fresh_top AND today_spend = 0 AND yday_spend = 0 THEN 'starting'
    WHEN coalesce((dl->>'stopped')::boolean, false) AND dl->>'cause' = 'funds' AND bal.kind IS DISTINCT FROM 'prepaid' THEN 'no_money'
    WHEN coalesce((dl->>'stopped')::boolean, false) THEN 'not_showing'
    WHEN bal.kind = 'prepaid' AND days_left < 3 THEN 'low_money'
    ELSE 'running' END;
  likely := state = 'no_money' AND bal.kind IS DISTINCT FROM 'prepaid';

  -- results of the period: what Google charged, and what the CRM itself received and did
  SELECT coalesce(jsonb_agg(jsonb_build_object('day', g.day, 'spend', coalesce(m.spend, 0), 'clicks', coalesce(m.clicks, 0), 'enquiries', coalesce(l.n, 0)) ORDER BY g.day), '[]'),
         coalesce(sum(m.spend), 0), coalesce(sum(m.clicks), 0), coalesce(sum(m.impr), 0)
    INTO series, t_spend, t_clicks, t_impr
    FROM (SELECT generate_series(f, d, interval '1 day')::date AS day) g
    LEFT JOIN (SELECT m.day, sum(m.spend) AS spend, sum(m.clicks) AS clicks, sum(m.impressions) AS impr FROM public.ads_metrics_daily m
                 JOIN public.ads_campaigns c ON c.id = m.campaign_id WHERE c.account_id = a.id AND m.day BETWEEN f AND d GROUP BY m.day) m ON m.day = g.day
    LEFT JOIN (SELECT (x.created_at AT TIME ZONE tz)::date AS day, count(*) AS n FROM crm_private.ads_ad_leads() x
                WHERE x.account_id = a.id AND x.valid GROUP BY 1) l ON l.day = g.day;
  SELECT count(*), count(l.first_response_at), count(*) FILTER (WHERE l.first_response_at <= l.created_at + interval '15 minutes')
    INTO enq, called, called15
    FROM crm_private.ads_ad_leads() x JOIN public.ads_lead l ON l.id = x.lead_id
   WHERE x.account_id = a.id AND x.valid AND (x.created_at AT TIME ZONE tz)::date BETWEEN f AND d;
  SELECT count(*) INTO waiting FROM crm_private.ads_ad_leads() x JOIN public.ads_lead l ON l.id = x.lead_id
   WHERE x.account_id = a.id AND x.valid AND l.first_response_at IS NULL AND l.created_at > now() - interval '30 days';

  SELECT jsonb_build_object('id', o.id, 'status', o.status, 'error', o.error, 'daily_total', (o.payload->>'daily_total')::numeric,
           'previous_total', (o.payload->'previous'->>'total')::numeric, 'created_at', o.created_at) INTO chg
    FROM public.ads_google_ops o WHERE o.account_id = a.id AND o.kind = 'budget_set' AND o.created_at > now() - interval '2 days'
   ORDER BY o.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'can_edit', crm_private.ads_can_approve(), 'is_admin', crm_private.is_admin(), 'today', d,
    'account', jsonb_build_object('name', a.name, 'external_id', a.external_id, 'currency', cur, 'status', a.status, 'last_ok_at', a.last_ok_at),
    'status', jsonb_build_object('state', state, 'likely', likely, 'since', dl->>'since', 'cause', dl->>'cause', 'reviewing', reviewing,
      'today_spend', today_spend, 'today_clicks', today_clicks, 'campaigns_on', n_on),
    'money', jsonb_build_object('kind', bal.kind, 'available', bal.available, 'checked_at', bal.checked_at, 'error', bal.error, 'error_at', bal.error_at,
      'asked_at', bal.asked_at, 'watching', coalesce(bal.watch_until > now(), false), 'daily', basis, 'days_left', days_left, 'tax_pct', tax,
      'add_30d', CASE WHEN basis > 0 THEN ceil(greatest(basis * 30 - coalesce(bal.available, 0), 0) * (1 + tax / 100) / 100) * 100 END,
      'last_topup', CASE WHEN top.id IS NOT NULL THEN jsonb_build_object('credit', top.credit, 'seen_at', top.seen_at) END),
    'budget', jsonb_build_object('daily', capd, 'monthly', capm, 'actual', actual, 'min', coalesce((r->>'min')::numeric, 100),
      'max', coalesce((r->>'max')::numeric, 5000), 'tax_pct', tax, 'month_spend', crm_private.ads_google_month_spend(), 'change', chg),
    'campaigns', camps,
    'areas_waiting', CASE WHEN jsonb_typeof(waiting_areas) = 'array' THEN waiting_areas ELSE '[]'::jsonb END,
    'results', jsonb_build_object('days', days, 'from', f, 'to', d, 'spend', t_spend, 'clicks', t_clicks, 'impressions', t_impr,
      'cpc', CASE WHEN t_clicks > 0 THEN round(t_spend / t_clicks, 2) END, 'enquiries', enq,
      'cost_per_enquiry', CASE WHEN enq > 0 THEN round(t_spend / enq) END, 'called', called, 'called_15m', called15, 'waiting', waiting, 'series', series),
    'needs', jsonb_build_object(
      'ops', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'summary', o.summary, 'reason', left(o.reason, 300),
          'by', CASE WHEN o.created_by_type = 'agent' THEN 'ai' WHEN o.created_by IS NOT DISTINCT FROM me THEN 'you' ELSE 'team' END,
          'warnings', coalesce(o.gate_result->'warnings', '[]'), 'created_at', o.created_at) ORDER BY o.created_at), '[]')
          FROM public.ads_google_ops o WHERE o.account_id = a.id AND o.status = 'pending'),
      'suggestions', (SELECT count(*) FROM public.ads_autopilot_suggestions s WHERE s.status = 'open'),
      'queue', (SELECT count(*) FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id
                 WHERE c.account_id = a.id AND q.status = 'pending')));
END $$;
REVOKE ALL ON FUNCTION public.api_ads_google_home(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_google_home(int) TO authenticated;

-- ---------------------------------------------------------------- what the AI team works from
UPDATE public.ads_config SET value = value || E'\nMoney and budget (25 Nov 2026):\n'
  '- The prepaid balance is read from Google (account budget: spending limit minus amount served) every 30 minutes and is in the "billing" snapshot. When it is near zero the ads cannot show: say so first; do not propose ad changes to fix a delivery stop that is an empty balance.\n'
  '- The owner sets one daily amount for all of Google Ads on the home screen (operation budget_set, owner only). Work inside it; a single campaign''s share may be moved with a budget operation, the total may not be raised.'
 WHERE key = 'google_brand_facts' AND value NOT LIKE '%Money and budget (25 Nov 2026)%';

-- ---------------------------------------------------------------- schedules
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-google-build', 'crm-ads-google-billing');
    PERFORM cron.schedule('crm-ads-google-build', '*/5 * * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-google-ops',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{}'::jsonb, timeout_milliseconds := 140000)
      WHERE EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind IN ('campaign_create', 'income_filter', 'ad_schedule', 'budget_set') AND status IN ('approved', 'executing')) $job$);
    -- the balance: every 30 minutes, and every 5 minutes for two hours after "I added money"
    PERFORM cron.schedule('crm-ads-google-billing', '*/5 * * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-google-ops',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"read": "billing"}'::jsonb, timeout_milliseconds := 60000)
      FROM public.ads_accounts a LEFT JOIN public.ads_google_balance b ON b.account_id = a.id
      WHERE a.id = (SELECT x.id FROM public.ads_accounts x WHERE x.platform = 'google' AND x.status = 'connected' ORDER BY x.created_at LIMIT 1)
        AND (greatest(b.checked_at, b.error_at) IS NULL
          OR greatest(b.checked_at, b.error_at) < now() - CASE WHEN b.watch_until > now() THEN interval '4 minutes' ELSE interval '29 minutes' END) $job$);
  END IF;
END $$;
