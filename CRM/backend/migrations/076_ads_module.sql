-- 076: ADS module (CRM > ADS). Additive only: new ads_* tables and api_ads_* / svc_ads_* functions.
--
-- What it is
--   One place to run paid advertising for one or more clients: clients with their business economics,
--   ad accounts (Google Ads, Meta), campaigns and daily platform metrics (pulled by the ads-sync Edge
--   Function), CRM outcomes (leads, qualified leads, customers, confirmed revenue), rule-based
--   recommendations, an approval queue for budget/status changes, research notes and experiments.
--
-- Rules this file enforces
--   * Platform-reported numbers (spend, clicks, platform conversions/value) and CRM-confirmed numbers
--     (leads, customers, revenue) are kept and returned separately. They are never added together.
--   * Ratios are computed here, deterministically. A ratio with a zero or missing denominator is NULL
--     ("not available"), never 0.
--   * A client's CRM numbers are only shown when the client is linked to a CRM lead segment; otherwise
--     they are NULL with crm.linked = false.
--   * Nothing is ever sent to an ad platform without an approved row in ads_change_queue. Guards are
--     evaluated on insert/update by a trigger; a change with blockers can never be approved.
--   * Execution can be stopped for everything with the emergency stop (ads_config.execution_paused).
--
-- Access
--   * View: Admin, plus employees Admin adds in ADS > Settings > Team (ads_access).
--   * Approve: Admin, plus ads_access.can_approve.
--   * Settings / API keys: Admin only. Keys live in Supabase Vault (names ads_*), never in a table, and
--     only the last 4 characters are ever returned to the browser.
--   * Every table has RLS on and no grants to anon/authenticated: the browser reaches data only through
--     the SECURITY DEFINER api_ads_* functions, which check the caller first. svc_ads_* are service-role only.
--
-- Re-runnable: CREATE ... IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO NOTHING throughout.

-- ===========================================================================================
-- 1. Tables
-- ===========================================================================================
CREATE TABLE IF NOT EXISTS public.ads_config (
  key text PRIMARY KEY, value text, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.ads_access (
  employee_id uuid PRIMARY KEY REFERENCES public.employee(id) ON DELETE CASCADE,
  can_approve boolean NOT NULL DEFAULT false,
  granted_by uuid, granted_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.ads_clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  website text, industry text, business_model text,
  products text, geography text, audience text, competitors text, objectives text,
  brand_notes text, restrictions text,
  currency text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  crm_segment text CHECK (crm_segment IN ('aviation', 'charter')),   -- links CRM leads; NULL = no CRM data for this client
  -- business economics (all optional; NULL = not set, never assumed)
  avg_order_value numeric(14,2), gross_margin_pct numeric(6,2), target_cpl numeric(14,2),
  target_qualified_cpl numeric(14,2), target_cac numeric(14,2), max_cac numeric(14,2),
  target_roas numeric(8,2), ltv numeric(14,2), sales_cycle_days int,
  monthly_budget numeric(14,2), max_daily_budget numeric(14,2),     -- max_daily_budget caps any single campaign change
  active boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS uq_ads_client_name ON public.ads_clients (lower(name));

CREATE TABLE IF NOT EXISTS public.ads_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.ads_clients(id) ON DELETE CASCADE,
  platform text NOT NULL CHECK (platform IN ('google', 'meta')),
  external_id text NOT NULL,          -- Google: 10-digit customer id (no dashes); Meta: ad account id without "act_"
  name text,
  currency text, timezone text,       -- as reported by the platform
  utm_source text,                    -- CRM leads with this utm_source and no campaign match count for this account
  status text NOT NULL DEFAULT 'not_synced' CHECK (status IN ('not_synced', 'connected', 'auth_required',
    'permission_missing', 'rate_limited', 'sync_failed', 'unavailable', 'disabled')),
  last_error text, last_sync_at timestamptz, last_ok_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, external_id));
CREATE INDEX IF NOT EXISTS idx_ads_accounts_client ON public.ads_accounts (client_id);

CREATE TABLE IF NOT EXISTS public.ads_campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  external_id text NOT NULL,
  name text, status text,             -- normalised: ENABLED / PAUSED / REMOVED / OTHER
  platform_status text,               -- the platform's own value
  objective text, channel text,
  daily_budget numeric(14,2),         -- account currency; NULL = not a daily budget / shared / unknown
  budget_ref text,                    -- Google: campaignBudgets resource name; Meta: 'campaign' or 'adset'
  utm_campaign text,                  -- CRM leads with this utm_campaign belong to this campaign
  raw jsonb NOT NULL DEFAULT '{}',
  synced_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, external_id));
CREATE INDEX IF NOT EXISTS idx_ads_campaigns_utm ON public.ads_campaigns (lower(utm_campaign)) WHERE utm_campaign IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.ads_metrics_daily (
  campaign_id uuid NOT NULL REFERENCES public.ads_campaigns(id) ON DELETE CASCADE,
  day date NOT NULL,                  -- the account's own reporting day
  impressions bigint, clicks bigint, spend numeric(14,2),
  conversions numeric(14,2), conversion_value numeric(14,2),   -- platform-reported
  reach bigint, video_views bigint,
  raw jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (campaign_id, day));
CREATE INDEX IF NOT EXISTS idx_ads_metrics_day ON public.ads_metrics_daily (day);

-- CRM-confirmed money. Entered by staff (or later by an integration). Refunds are separate rows.
CREATE TABLE IF NOT EXISTS public.ads_revenue (
  id bigserial PRIMARY KEY,
  client_id uuid NOT NULL REFERENCES public.ads_clients(id) ON DELETE CASCADE,
  lead_id uuid REFERENCES public.lead(id) ON DELETE SET NULL,
  kind text NOT NULL DEFAULT 'sale' CHECK (kind IN ('sale', 'refund')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  occurred_on date NOT NULL,
  note text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_revenue_client ON public.ads_revenue (client_id, occurred_on);

CREATE TABLE IF NOT EXISTS public.ads_rules (
  code text PRIMARY KEY,
  label text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('blocker', 'warning', 'confirm')),
  value jsonb NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.ads_recommendations (
  id bigserial PRIMARY KEY,
  client_id uuid NOT NULL REFERENCES public.ads_clients(id) ON DELETE CASCADE,
  campaign_id uuid REFERENCES public.ads_campaigns(id) ON DELETE CASCADE,
  rule_code text NOT NULL,
  observation text NOT NULL,
  source_data jsonb NOT NULL DEFAULT '{}',
  reasoning text NOT NULL,
  alternatives text,
  proposed_action text NOT NULL,
  proposed_change jsonb,              -- {kind, after} when it can become a queued change
  expected_impact text,
  confidence text NOT NULL CHECK (confidence IN ('low', 'medium', 'high')),
  financial_risk text NOT NULL CHECK (financial_risk IN ('none', 'low', 'medium', 'high')),
  source text NOT NULL DEFAULT 'rules' CHECK (source IN ('rules', 'claude', 'user')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'queued', 'dismissed', 'done')),
  change_id uuid, dismiss_reason text,
  created_at timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ads_rec_open
  ON public.ads_recommendations (client_id, coalesce(campaign_id, '00000000-0000-0000-0000-000000000000'::uuid), rule_code)
  WHERE status = 'open';

CREATE TABLE IF NOT EXISTS public.ads_change_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.ads_campaigns(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('budget', 'status')),
  summary text NOT NULL DEFAULT '',
  before jsonb NOT NULL DEFAULT '{}',
  after jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'executing', 'verified',
    'failed', 'outcome_unknown', 'rejected', 'cancelled', 'stale')),
  guard_result jsonb NOT NULL DEFAULT '{}',
  needs_second_confirm boolean NOT NULL DEFAULT false,
  second_confirmed boolean NOT NULL DEFAULT false,
  idempotency_key uuid NOT NULL DEFAULT gen_random_uuid(),
  recommendation_id bigint REFERENCES public.ads_recommendations(id) ON DELETE SET NULL,
  created_by_type text NOT NULL DEFAULT 'user' CHECK (created_by_type IN ('user', 'claude', 'system')),
  created_by uuid, approved_by uuid, approved_at timestamptz,
  executed_at timestamptz, verify_result jsonb,
  reject_reason text, error text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_queue_status ON public.ads_change_queue (status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ads_research (
  id bigserial PRIMARY KEY,
  client_id uuid NOT NULL REFERENCES public.ads_clients(id) ON DELETE CASCADE,
  topic text NOT NULL, competitor text, segment text, geography text,
  observation text NOT NULL,
  classification text NOT NULL CHECK (classification IN ('fact', 'inference', 'hypothesis', 'unknown')),
  source_url text CHECK (source_url IS NULL OR source_url ~ '^https?://'),
  publisher text, published_on date,
  retrieved_at timestamptz NOT NULL DEFAULT now(),
  confidence text NOT NULL DEFAULT 'medium' CHECK (confidence IN ('low', 'medium', 'high')),
  interpretation text, opportunity text, action text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ads_research_fact_has_source CHECK (classification <> 'fact' OR source_url IS NOT NULL));
CREATE INDEX IF NOT EXISTS idx_ads_research_client ON public.ads_research (client_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ads_experiments (
  id bigserial PRIMARY KEY,
  client_id uuid NOT NULL REFERENCES public.ads_clients(id) ON DELETE CASCADE,
  name text NOT NULL, kind text NOT NULL DEFAULT 'creative' CHECK (kind IN
    ('creative', 'headline', 'cta', 'offer', 'audience', 'landing_page', 'budget', 'bidding')),
  hypothesis text NOT NULL, control text, treatment text,
  primary_metric text NOT NULL, secondary_metrics text, sample_plan text,
  starts_on date, ends_on date,
  status text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'running', 'analysing', 'done', 'stopped')),
  result text, confidence text CHECK (confidence IN ('not_enough_data', 'low', 'medium', 'high')),
  decision text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ads_exp_dates CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on));

CREATE TABLE IF NOT EXISTS public.ads_sync_runs (
  id bigserial PRIMARY KEY,
  job text NOT NULL,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'error', 'skipped')),
  items int, detail text,
  started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_ads_runs_job ON public.ads_sync_runs (job, started_at DESC);

-- Who did what. Never stores secret values.
CREATE TABLE IF NOT EXISTS public.ads_activity_log (
  id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  actor uuid, actor_type text NOT NULL DEFAULT 'user',
  action text NOT NULL, entity text, entity_id text, details jsonb);
CREATE INDEX IF NOT EXISTS idx_ads_activity_at ON public.ads_activity_log (at DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ads_config','ads_access','ads_clients','ads_accounts','ads_campaigns','ads_metrics_daily',
    'ads_revenue','ads_rules','ads_recommendations','ads_change_queue','ads_research','ads_experiments',
    'ads_sync_runs','ads_activity_log']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- ===========================================================================================
-- 2. Config defaults and rules (limits are data, editable by Admin)
-- ===========================================================================================
INSERT INTO public.ads_config (key, value) VALUES
  ('execution_paused', 'false'),          -- emergency stop: nothing is sent to any platform while 'true'
  ('google_api_version', 'v26'),          -- Google Ads API v26 (released 2026-10-14)
  ('meta_api_version', 'v26.0'),          -- Graph / Marketing API v26.0 (released 2026-07-29)
  ('sync_days', '30')                     -- days of daily metrics re-pulled on each sync
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_rules (code, label, severity, value) VALUES
  ('budget_min', 'Daily budget must be at least this amount', 'blocker', '{"min": 1}'),
  ('budget_client_max', 'Daily budget may not exceed the client''s "max daily budget"', 'blocker', '{}'),
  ('budget_change_confirm', 'Budget change above this % needs a second confirm', 'confirm', '{"pct": 20}'),
  ('budget_change_max', 'Budget change above this % in one step is blocked', 'blocker', '{"pct": 100}'),
  ('enable_confirm', 'Turning a paused campaign on needs a second confirm', 'confirm', '{}'),
  ('changes_per_day', 'Changes per campaign per day', 'blocker', '{"max": 3}'),
  ('rec_no_leads_spend', 'Recommend review: spend with no CRM leads (min spend, days)', 'warning', '{"min_spend": 2000, "days": 14}'),
  ('rec_cpl_over_target', 'Recommend review: CPL above target by this %', 'warning', '{"pct": 50, "days": 14, "min_leads": 3}'),
  ('rec_budget_capped_good', 'Recommend scale-up: CPL below target by this % (min leads)', 'warning', '{"pct": 30, "days": 14, "min_leads": 5, "raise_pct": 15}'),
  ('stale_sync_hours', 'Warn when an account has not synced for this many hours', 'warning', '{"hours": 26}')
ON CONFLICT (code) DO NOTHING;

-- ===========================================================================================
-- 3. Access helpers
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_can_view() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (
    SELECT 1 FROM public.ads_access a WHERE a.employee_id = crm_private.current_employee_id())
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_can_approve() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (
    SELECT 1 FROM public.ads_access a WHERE a.employee_id = crm_private.current_employee_id() AND a.can_approve)
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_require_view() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_view() THEN
    RAISE EXCEPTION 'You do not have access to the ADS section' USING ERRCODE = 'PT403';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_require_admin() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can do this' USING ERRCODE = 'PT403';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_log(p_action text, p_entity text, p_entity_id text, p_details jsonb,
  p_actor_type text DEFAULT 'user') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_activity_log (actor, actor_type, action, entity, entity_id, details)
  VALUES (crm_private.current_employee_id(), p_actor_type, p_action, p_entity, p_entity_id, p_details)
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_rule(p_code text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT r.value FROM public.ads_rules r WHERE r.code = p_code AND r.active
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_cfg(p_key text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT c.value FROM public.ads_config c WHERE c.key = p_key
$$;

-- ===========================================================================================
-- 4. Deterministic metrics. NULL means "not available"; a zero denominator is never shown as 0.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_div(n numeric, d numeric, scale numeric DEFAULT 1) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN n IS NULL OR d IS NULL OR d = 0 THEN NULL ELSE round(n * scale / d, 4) END
$$;

-- Platform totals for one client (or all clients when p_client is NULL), grouped by currency.
CREATE OR REPLACE FUNCTION crm_private.ads_platform_totals(p_client uuid, p_from date, p_to date, p_platform text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH m AS (
    SELECT coalesce(a.currency, cl.currency) AS currency, d.*
      FROM public.ads_metrics_daily d
      JOIN public.ads_campaigns c ON c.id = d.campaign_id
      JOIN public.ads_accounts a ON a.id = c.account_id
      JOIN public.ads_clients cl ON cl.id = a.client_id
     WHERE d.day BETWEEN p_from AND p_to
       AND (p_client IS NULL OR a.client_id = p_client)
       AND (p_platform IS NULL OR a.platform = p_platform)),
  g AS (
    SELECT currency, sum(spend) spend, sum(impressions) impressions, sum(clicks) clicks,
           sum(conversions) conversions, sum(conversion_value) conversion_value, count(*) rows_
      FROM m GROUP BY currency)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'currency', currency, 'spend', spend, 'impressions', impressions, 'clicks', clicks,
    'conversions', conversions, 'conversion_value', conversion_value,
    'ctr', crm_private.ads_div(clicks, impressions, 100), 'cpc', crm_private.ads_div(spend, clicks),
    'cpm', crm_private.ads_div(spend, impressions, 1000),
    'platform_roas', crm_private.ads_div(conversion_value, spend)) ORDER BY spend DESC NULLS LAST), '[]')
  FROM g
$$;

-- CRM leads attributed to ads for a client: a lead belongs to a campaign when its utm_campaign matches the
-- campaign's utm_campaign, otherwise to an account when its utm_source matches the account's utm_source.
CREATE OR REPLACE FUNCTION crm_private.ads_client_leads(p_client uuid, p_from date, p_to date)
RETURNS TABLE (lead_id uuid, campaign_id uuid, account_id uuid, platform text, created_day date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.id,
         c.id,
         coalesce(c.account_id, a2.id),
         coalesce(a1.platform, a2.platform),
         (l.created_at AT TIME ZONE cl.timezone)::date
    FROM public.ads_clients cl
    JOIN public.lead l ON l.segment = cl.crm_segment
    LEFT JOIN LATERAL (
      SELECT c0.id, c0.account_id FROM public.ads_campaigns c0 JOIN public.ads_accounts a0 ON a0.id = c0.account_id
       WHERE a0.client_id = cl.id AND c0.utm_campaign IS NOT NULL AND lower(c0.utm_campaign) = lower(l.utm_campaign)
       ORDER BY c0.created_at LIMIT 1) c ON true
    LEFT JOIN public.ads_accounts a1 ON a1.id = c.account_id
    LEFT JOIN LATERAL (
      SELECT a0.id, a0.platform FROM public.ads_accounts a0
       WHERE c.id IS NULL AND a0.client_id = cl.id AND a0.utm_source IS NOT NULL AND lower(a0.utm_source) = lower(l.utm_source)
       ORDER BY a0.created_at LIMIT 1) a2 ON true
   WHERE cl.id = p_client AND cl.crm_segment IS NOT NULL
     AND (l.created_at AT TIME ZONE cl.timezone)::date BETWEEN p_from AND p_to
     AND (c.id IS NOT NULL OR a2.id IS NOT NULL)
$$;

-- CRM outcome counts for a set of lead ids (definitions documented in CRM/docs/ADS_MODULE.md).
--   valid      = no contact attempt marked 'Wrong number'
--   qualified  = valid AND (any attempt marked 'Interested' OR is_eligible = true)
--   customer   = closure_outcome is admission_completed / booking_confirmed
CREATE OR REPLACE FUNCTION crm_private.ads_lead_outcomes(p_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH x AS (
    SELECT l.id,
           NOT EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Wrong number') AS valid,
           (EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Interested')
             OR coalesce(l.is_eligible, false)) AS interested,
           coalesce(l.closure_outcome::text IN ('admission_completed', 'booking_confirmed'), false) AS customer
      FROM public.lead l WHERE l.id = ANY (p_ids))
  SELECT jsonb_build_object('leads', count(*), 'valid', count(*) FILTER (WHERE valid),
    'qualified', count(*) FILTER (WHERE valid AND interested), 'customers', count(*) FILTER (WHERE customer))
  FROM x
$$;

-- One client's full picture for a period: platform numbers, CRM numbers, and the ratios that join them.
CREATE OR REPLACE FUNCTION crm_private.ads_client_summary(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cl public.ads_clients; plat jsonb; crm jsonb := NULL; ids uuid[]; rev numeric; refunds numeric;
        spend numeric; one jsonb; mixed boolean;
BEGIN
  SELECT * INTO cl FROM public.ads_clients WHERE id = p_client;
  IF cl.id IS NULL THEN RETURN NULL; END IF;
  plat := crm_private.ads_platform_totals(p_client, p_from, p_to);
  mixed := jsonb_array_length(plat) > 1;
  one := CASE WHEN jsonb_array_length(plat) = 1 THEN plat->0 ELSE NULL END;
  spend := CASE WHEN one IS NOT NULL AND one->>'currency' = cl.currency THEN (one->>'spend')::numeric END;
  IF cl.crm_segment IS NOT NULL THEN
    SELECT coalesce(array_agg(lead_id), '{}') INTO ids FROM crm_private.ads_client_leads(p_client, p_from, p_to);
    crm := crm_private.ads_lead_outcomes(ids);
    SELECT sum(amount) FILTER (WHERE kind = 'sale'), sum(amount) FILTER (WHERE kind = 'refund') INTO rev, refunds
      FROM public.ads_revenue WHERE client_id = p_client AND currency = cl.currency AND occurred_on BETWEEN p_from AND p_to;
    crm := crm || jsonb_build_object(
      'revenue', coalesce(rev, 0) - coalesce(refunds, 0), 'refunds', coalesce(refunds, 0),
      'cpl', crm_private.ads_div(spend, (crm->>'valid')::numeric),
      'qualified_cpl', crm_private.ads_div(spend, (crm->>'qualified')::numeric),
      'cac', crm_private.ads_div(spend, (crm->>'customers')::numeric),
      'lead_to_customer_pct', crm_private.ads_div((crm->>'customers')::numeric, (crm->>'valid')::numeric, 100),
      'crm_roas', crm_private.ads_div(coalesce(rev, 0) - coalesce(refunds, 0), spend),
      'contribution', CASE WHEN spend IS NULL OR cl.gross_margin_pct IS NULL THEN NULL
                           ELSE round((coalesce(rev, 0) - coalesce(refunds, 0)) * cl.gross_margin_pct / 100 - spend, 2) END);
  END IF;
  RETURN jsonb_build_object(
    'client_id', cl.id, 'name', cl.name, 'currency', cl.currency,
    'platform', plat, 'mixed_currency', mixed, 'spend', spend,
    'crm_linked', cl.crm_segment IS NOT NULL, 'crm', crm,
    'targets', jsonb_build_object('cpl', cl.target_cpl, 'qualified_cpl', cl.target_qualified_cpl, 'cac', cl.target_cac,
      'roas', cl.target_roas, 'monthly_budget', cl.monthly_budget));
END $$;

-- ===========================================================================================
-- 5. Guards: one evaluator for the queue trigger and the UI preview
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_evaluate(p_campaign uuid, p_kind text, p_after jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.ads_campaigns; a public.ads_accounts; cl public.ads_clients; r jsonb;
        blockers jsonb := '[]'; confirms jsonb := '[]'; warnings jsonb := '[]';
        nb numeric; ob numeric; ch numeric; n int; st text;
BEGIN
  SELECT * INTO c FROM public.ads_campaigns WHERE id = p_campaign;
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('blockers', jsonb_build_array(jsonb_build_object('code', 'campaign', 'severity', 'blocker',
      'message', 'Campaign not found.')), 'confirms', '[]'::jsonb, 'warnings', '[]'::jsonb);
  END IF;
  SELECT * INTO a FROM public.ads_accounts WHERE id = c.account_id;
  SELECT * INTO cl FROM public.ads_clients WHERE id = a.client_id;
  IF a.status <> 'connected' THEN
    blockers := blockers || jsonb_build_object('code', 'account', 'severity', 'blocker',
      'message', format('The %s account is "%s", not connected. Fix it in Settings and sync first.', a.platform, a.status));
  END IF;
  IF c.status = 'REMOVED' THEN
    blockers := blockers || jsonb_build_object('code', 'removed', 'severity', 'blocker', 'message', 'This campaign is removed.');
  END IF;

  IF p_kind = 'budget' THEN
    BEGIN nb := (p_after->>'daily_budget')::numeric; EXCEPTION WHEN others THEN nb := NULL; END;
    ob := c.daily_budget;
    IF nb IS NULL THEN
      blockers := blockers || jsonb_build_object('code', 'budget_value', 'severity', 'blocker', 'message', 'Enter the new daily budget as a number.');
    ELSE
      r := crm_private.ads_rule('budget_min');
      IF r IS NOT NULL AND nb < (r->>'min')::numeric THEN
        blockers := blockers || jsonb_build_object('code', 'budget_min', 'severity', 'blocker',
          'message', format('Daily budget must be at least %s.', r->>'min'));
      END IF;
      IF crm_private.ads_rule('budget_client_max') IS NOT NULL THEN
        IF cl.max_daily_budget IS NULL THEN
          blockers := blockers || jsonb_build_object('code', 'budget_client_max', 'severity', 'blocker',
            'message', format('Set a "max daily budget" for %s before changing budgets.', cl.name));
        ELSIF nb > cl.max_daily_budget THEN
          blockers := blockers || jsonb_build_object('code', 'budget_client_max', 'severity', 'blocker',
            'message', format('%s is above %s''s max daily budget of %s.', nb, cl.name, cl.max_daily_budget));
        END IF;
      END IF;
      IF ob IS NULL OR c.budget_ref IS NULL THEN
        blockers := blockers || jsonb_build_object('code', 'budget_unknown', 'severity', 'blocker',
          'message', 'The current daily budget is unknown (shared, ad-set level or not synced). Change it in the platform.');
      ELSIF ob > 0 THEN
        ch := abs(nb - ob) * 100 / ob;
        r := crm_private.ads_rule('budget_change_max');
        IF r IS NOT NULL AND ch > (r->>'pct')::numeric THEN
          blockers := blockers || jsonb_build_object('code', 'budget_change_max', 'severity', 'blocker',
            'message', format('A %s%% change is more than the %s%% allowed in one step.', round(ch), r->>'pct'));
        END IF;
        r := crm_private.ads_rule('budget_change_confirm');
        IF r IS NOT NULL AND ch > (r->>'pct')::numeric THEN
          confirms := confirms || jsonb_build_object('code', 'budget_change_confirm', 'severity', 'confirm',
            'message', format('Budget changes by %s%%. A second confirm is needed.', round(ch)));
        END IF;
      END IF;
    END IF;
  ELSIF p_kind = 'status' THEN
    st := upper(coalesce(p_after->>'status', ''));
    IF st NOT IN ('ENABLED', 'PAUSED') THEN
      blockers := blockers || jsonb_build_object('code', 'status_value', 'severity', 'blocker', 'message', 'Status must be ENABLED or PAUSED.');
    ELSIF st = coalesce(c.status, '') THEN
      blockers := blockers || jsonb_build_object('code', 'status_same', 'severity', 'blocker', 'message', format('The campaign is already %s.', st));
    ELSIF st = 'ENABLED' AND crm_private.ads_rule('enable_confirm') IS NOT NULL THEN
      confirms := confirms || jsonb_build_object('code', 'enable_confirm', 'severity', 'confirm',
        'message', 'Turning a campaign on starts spending money. A second confirm is needed.');
    END IF;
  ELSE
    blockers := blockers || jsonb_build_object('code', 'kind', 'severity', 'blocker', 'message', 'Unknown change type.');
  END IF;

  r := crm_private.ads_rule('changes_per_day');
  IF r IS NOT NULL THEN
    SELECT count(*) INTO n FROM public.ads_change_queue q
     WHERE q.campaign_id = p_campaign AND q.id IS DISTINCT FROM p_exclude
       AND q.status IN ('pending', 'approved', 'executing', 'verified', 'outcome_unknown')
       AND q.created_at > now() - interval '24 hours';
    IF n >= (r->>'max')::int THEN
      blockers := blockers || jsonb_build_object('code', 'changes_per_day', 'severity', 'blocker',
        'message', format('This campaign already has %s changes in the last 24 hours (limit %s).', n, r->>'max'));
    END IF;
  END IF;
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN
    warnings := warnings || jsonb_build_object('code', 'paused', 'severity', 'warning',
      'message', 'Emergency stop is on: approved changes wait until it is turned off.');
  END IF;
  RETURN jsonb_build_object('blockers', blockers, 'confirms', confirms, 'warnings', warnings);
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_queue_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.ads_campaigns;
BEGIN
  IF TG_OP = 'INSERT' OR (NEW.status IN ('pending', 'approved') AND (NEW.after IS DISTINCT FROM OLD.after OR NEW.status IS DISTINCT FROM OLD.status)) THEN
    NEW.guard_result := crm_private.ads_evaluate(NEW.campaign_id, NEW.kind, NEW.after, NEW.id);
    NEW.needs_second_confirm := jsonb_array_length(NEW.guard_result->'confirms') > 0;
    IF TG_OP = 'INSERT' THEN
      SELECT * INTO c FROM public.ads_campaigns WHERE id = NEW.campaign_id;
      NEW.before := jsonb_build_object('daily_budget', c.daily_budget, 'status', c.status, 'name', c.name);
    END IF;
  END IF;
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
    IF jsonb_array_length(NEW.guard_result->'blockers') > 0 THEN
      RAISE EXCEPTION 'This change has problems that must be fixed first' USING ERRCODE = 'PT422';
    END IF;
    IF NEW.needs_second_confirm AND NOT NEW.second_confirmed THEN
      RAISE EXCEPTION 'This change needs a second confirm' USING ERRCODE = 'PT422';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_queue_guard ON public.ads_change_queue;
CREATE TRIGGER trg_ads_queue_guard BEFORE INSERT OR UPDATE ON public.ads_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_queue_guard();

-- ===========================================================================================
-- 6. Rule-based recommendations (deterministic; no AI). Run after each sync and on demand.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_recommend_all() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cl public.ads_clients; c record; r jsonb; n int := 0; d0 date; d1 date; spend numeric; leads int; cpl numeric; nb numeric;
BEGIN
  FOR cl IN SELECT * FROM public.ads_clients WHERE active AND crm_segment IS NOT NULL LOOP
    d1 := (now() AT TIME ZONE cl.timezone)::date - 1;
    FOR c IN SELECT cp.*, a.currency AS acur FROM public.ads_campaigns cp JOIN public.ads_accounts a ON a.id = cp.account_id
              WHERE a.client_id = cl.id AND cp.status = 'ENABLED' AND cp.utm_campaign IS NOT NULL LOOP
      IF coalesce(c.acur, cl.currency) <> cl.currency THEN CONTINUE; END IF;
      -- 1. spend with no CRM leads
      r := crm_private.ads_rule('rec_no_leads_spend');
      IF r IS NOT NULL THEN
        d0 := d1 - (r->>'days')::int + 1;
        SELECT sum(m.spend) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d0 AND d1;
        SELECT count(*) INTO leads FROM crm_private.ads_client_leads(cl.id, d0, d1) x WHERE x.campaign_id = c.id;
        IF spend >= (r->>'min_spend')::numeric AND leads = 0 THEN
          INSERT INTO public.ads_recommendations (client_id, campaign_id, rule_code, observation, source_data, reasoning,
            alternatives, proposed_action, proposed_change, expected_impact, confidence, financial_risk)
          VALUES (cl.id, c.id, 'rec_no_leads_spend',
            format('"%s" spent %s %s from %s to %s and the CRM recorded no leads with utm_campaign "%s".', c.name, spend, cl.currency, d0, d1, c.utm_campaign),
            jsonb_build_object('spend', spend, 'crm_leads', 0, 'from', d0, 'to', d1, 'utm_campaign', c.utm_campaign),
            'Money is being spent without any enquiry reaching the CRM for this campaign.',
            'The landing page may not pass utm_campaign to the CRM form, the form may be broken, or leads may arrive under another UTM. Check tracking before pausing.',
            'Check the landing page form and UTM tagging; if tracking is fine, pause the campaign.',
            jsonb_build_object('kind', 'status', 'after', jsonb_build_object('status', 'PAUSED')),
            format('Stops about %s %s a day of spend that produced no CRM leads.', round(spend / (r->>'days')::int), cl.currency),
            'medium', 'low')
          ON CONFLICT DO NOTHING;
          IF FOUND THEN n := n + 1; END IF;
        END IF;
      END IF;
      -- 2. CPL far above target
      r := crm_private.ads_rule('rec_cpl_over_target');
      IF r IS NOT NULL AND cl.target_cpl IS NOT NULL THEN
        d0 := d1 - (r->>'days')::int + 1;
        SELECT sum(m.spend) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d0 AND d1;
        SELECT count(*) INTO leads FROM crm_private.ads_client_leads(cl.id, d0, d1) x WHERE x.campaign_id = c.id;
        cpl := crm_private.ads_div(spend, leads);
        IF leads >= (r->>'min_leads')::int AND cpl > cl.target_cpl * (1 + (r->>'pct')::numeric / 100) THEN
          INSERT INTO public.ads_recommendations (client_id, campaign_id, rule_code, observation, source_data, reasoning,
            alternatives, proposed_action, expected_impact, confidence, financial_risk)
          VALUES (cl.id, c.id, 'rec_cpl_over_target',
            format('"%s" cost %s %s per CRM lead over %s days; the target is %s.', c.name, round(cpl, 2), cl.currency, r->>'days', cl.target_cpl),
            jsonb_build_object('spend', spend, 'crm_leads', leads, 'cpl', cpl, 'target_cpl', cl.target_cpl, 'from', d0, 'to', d1),
            'Cost per lead is well above the client''s target.',
            'A short period, seasonality, or a recent change may explain it. Lead quality (qualified rate) may still justify the cost.',
            'Review targeting, keywords/audiences and ads; consider lowering the budget.',
            NULL, 'medium', 'none')
          ON CONFLICT DO NOTHING;
          IF FOUND THEN n := n + 1; END IF;
        END IF;
      END IF;
      -- 3. CPL well below target: candidate to scale
      r := crm_private.ads_rule('rec_budget_capped_good');
      IF r IS NOT NULL AND cl.target_cpl IS NOT NULL AND c.daily_budget IS NOT NULL AND c.budget_ref IS NOT NULL THEN
        d0 := d1 - (r->>'days')::int + 1;
        SELECT sum(m.spend) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d0 AND d1;
        SELECT count(*) INTO leads FROM crm_private.ads_client_leads(cl.id, d0, d1) x WHERE x.campaign_id = c.id;
        cpl := crm_private.ads_div(spend, leads);
        nb := round(c.daily_budget * (1 + (r->>'raise_pct')::numeric / 100), 2);
        IF leads >= (r->>'min_leads')::int AND cpl < cl.target_cpl * (1 - (r->>'pct')::numeric / 100)
           AND (cl.max_daily_budget IS NULL OR nb <= cl.max_daily_budget) THEN
          INSERT INTO public.ads_recommendations (client_id, campaign_id, rule_code, observation, source_data, reasoning,
            alternatives, proposed_action, proposed_change, expected_impact, confidence, financial_risk)
          VALUES (cl.id, c.id, 'rec_budget_capped_good',
            format('"%s" cost %s %s per CRM lead over %s days, below the %s target.', c.name, round(cpl, 2), cl.currency, r->>'days', cl.target_cpl),
            jsonb_build_object('spend', spend, 'crm_leads', leads, 'cpl', cpl, 'target_cpl', cl.target_cpl, 'daily_budget', c.daily_budget),
            'The campaign brings leads cheaper than target, so more budget may bring more leads.',
            'Extra budget usually gets more expensive leads (diminishing returns). Check the qualified-lead rate first.',
            format('Raise the daily budget from %s to %s (+%s%%).', c.daily_budget, nb, r->>'raise_pct'),
            jsonb_build_object('kind', 'budget', 'after', jsonb_build_object('daily_budget', nb)),
            'Not estimated: depends on auction volume.', 'low', 'medium')
          ON CONFLICT DO NOTHING;
          IF FOUND THEN n := n + 1; END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- ===========================================================================================
-- 7. Settings (Admin only). Secrets in Vault as ads_<name>.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN']
$$;

CREATE OR REPLACE FUNCTION public.api_ads_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '{}'; nm text; s record;
BEGIN
  PERFORM crm_private.ads_require_admin();
  FOREACH nm IN ARRAY crm_private.ads_secret_names() LOOP
    SELECT right(d.decrypted_secret, 4) AS last4, d.updated_at INTO s
      FROM vault.decrypted_secrets d WHERE d.name = 'ads_' || lower(nm);
    out := out || jsonb_build_object(nm, CASE WHEN s.last4 IS NULL THEN jsonb_build_object('set', false)
      ELSE jsonb_build_object('set', true, 'last4', s.last4, 'updated_at', s.updated_at) END);
    s := NULL;
  END LOOP;
  RETURN jsonb_build_object('secrets', out,
    'config', (SELECT jsonb_object_agg(c.key, c.value) FROM public.ads_config c),
    'tests', (SELECT jsonb_object_agg(sub.job, jsonb_build_object('status', sub.status, 'detail', sub.detail, 'at', sub.finished_at))
               FROM (SELECT DISTINCT ON (job) job, status, detail, finished_at FROM public.ads_sync_runs
                      WHERE job IN ('test_google', 'test_meta') ORDER BY job, started_at DESC) sub));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_settings_save(p_name text, p_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text := trim(coalesce(p_value, '')); sid uuid; vname text;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_name IN ('google_api_version', 'meta_api_version', 'sync_days', 'execution_paused') THEN
    IF p_name = 'google_api_version' AND v !~ '^v[0-9]{2}$' THEN RAISE EXCEPTION 'Google Ads API version looks like v26' USING ERRCODE = 'PT422'; END IF;
    IF p_name = 'meta_api_version' AND v !~ '^v[0-9]{2}\.0$' THEN RAISE EXCEPTION 'Meta API version looks like v26.0' USING ERRCODE = 'PT422'; END IF;
    IF p_name = 'sync_days' AND (v !~ '^[0-9]+$' OR v::int NOT BETWEEN 1 AND 90) THEN RAISE EXCEPTION 'Sync days is 1 to 90' USING ERRCODE = 'PT422'; END IF;
    IF p_name = 'execution_paused' AND v NOT IN ('true', 'false') THEN RAISE EXCEPTION 'true or false' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.ads_config (key, value) VALUES (p_name, v)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.ads_log(CASE WHEN p_name = 'execution_paused' THEN 'emergency_stop_' || v ELSE 'config_saved' END, 'config', p_name,
      CASE WHEN p_name = 'execution_paused' THEN '{}'::jsonb ELSE jsonb_build_object('value', v) END);
    RETURN jsonb_build_object('saved', true);
  END IF;
  IF NOT (p_name = ANY (crm_private.ads_secret_names())) THEN RAISE EXCEPTION 'Unknown setting' USING ERRCODE = 'PT404'; END IF;
  IF v = '' THEN RAISE EXCEPTION 'Value is empty' USING ERRCODE = 'PT422'; END IF;
  IF v ~ '\s' THEN RAISE EXCEPTION 'Value contains spaces or line breaks; paste it again' USING ERRCODE = 'PT422'; END IF;
  IF length(v) > 4000 THEN RAISE EXCEPTION 'Value is too long' USING ERRCODE = 'PT422'; END IF;
  IF p_name = 'GOOGLE_ADS_CLIENT_ID' AND v !~ '\.apps\.googleusercontent\.com$' THEN
    RAISE EXCEPTION 'OAuth client ID ends with .apps.googleusercontent.com' USING ERRCODE = 'PT422'; END IF;
  IF p_name = 'GOOGLE_ADS_REFRESH_TOKEN' AND v !~ '^1//' THEN
    RAISE EXCEPTION 'Google refresh tokens start with 1//' USING ERRCODE = 'PT422'; END IF;
  IF p_name = 'GOOGLE_ADS_LOGIN_CUSTOMER_ID' THEN
    v := replace(v, '-', '');
    IF v !~ '^[0-9]{10}$' THEN RAISE EXCEPTION 'Manager (MCC) customer ID is 10 digits' USING ERRCODE = 'PT422'; END IF;
  END IF;
  IF p_name = 'META_APP_ID' AND v !~ '^[0-9]{5,20}$' THEN RAISE EXCEPTION 'Meta App ID is digits only' USING ERRCODE = 'PT422'; END IF;
  vname := 'ads_' || lower(p_name);
  SELECT id INTO sid FROM vault.secrets WHERE name = vname;
  IF sid IS NULL THEN PERFORM vault.create_secret(v, vname, 'CRM ADS: ' || p_name);
  ELSE PERFORM vault.update_secret(sid, v); END IF;
  PERFORM crm_private.ads_log('secret_saved', 'setting', p_name, '{}');   -- name only, never the value
  RETURN jsonb_build_object('saved', true, 'last4', right(v, 4));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_secret_delete(p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF NOT (p_name = ANY (crm_private.ads_secret_names())) THEN RAISE EXCEPTION 'Unknown setting' USING ERRCODE = 'PT404'; END IF;
  DELETE FROM vault.secrets WHERE name = 'ads_' || lower(p_name);
  PERFORM crm_private.ads_log('secret_deleted', 'setting', p_name, '{}');
END $$;

-- ===========================================================================================
-- 8. Browser API (authenticated; every function checks access first)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_ads_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.ads_can_view(), 'can_approve', crm_private.ads_can_approve(),
    'is_admin', crm_private.is_admin())
$$;

-- Command Centre. p_client NULL = every client. Previous period has the same length, right before.
CREATE OR REPLACE FUNCTION public.api_ads_overview(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE len int; pf date; pt date; clients jsonb; prev jsonb; trend jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 400 THEN
    RAISE EXCEPTION 'Pick a valid period (up to 400 days)' USING ERRCODE = 'PT422';
  END IF;
  len := p_to - p_from + 1; pt := p_from - 1; pf := pt - len + 1;
  SELECT coalesce(jsonb_agg(crm_private.ads_client_summary(c.id, p_from, p_to) ORDER BY c.name), '[]'),
         coalesce(jsonb_agg(crm_private.ads_client_summary(c.id, pf, pt) ORDER BY c.name), '[]')
    INTO clients, prev
    FROM public.ads_clients c WHERE c.active AND (p_client IS NULL OR c.id = p_client);
  SELECT coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'currency', d.currency, 'spend', d.spend, 'clicks', d.clicks,
           'conversions', d.conversions) ORDER BY d.day), '[]') INTO trend
    FROM (SELECT m.day, coalesce(a.currency, cl.currency) currency, sum(m.spend) spend, sum(m.clicks) clicks, sum(m.conversions) conversions
            FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
            JOIN public.ads_accounts a ON a.id = c.account_id JOIN public.ads_clients cl ON cl.id = a.client_id
           WHERE m.day BETWEEN p_from AND p_to AND cl.active AND (p_client IS NULL OR a.client_id = p_client)
           GROUP BY 1, 2) d;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'prev_from', pf, 'prev_to', pt),
    'clients', clients, 'previous', prev,
    'by_platform', jsonb_build_object(
      'google', crm_private.ads_platform_totals(p_client, p_from, p_to, 'google'),
      'meta', crm_private.ads_platform_totals(p_client, p_from, p_to, 'meta')),
    'trend', trend,
    'leads_trend', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', x.created_day, 'leads', x.n) ORDER BY x.created_day), '[]')
                      FROM (SELECT l.created_day, count(*) n FROM public.ads_clients c,
                              LATERAL crm_private.ads_client_leads(c.id, p_from, p_to) l
                             WHERE c.active AND (p_client IS NULL OR c.id = p_client) GROUP BY 1) x),
    'accounts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'client', cl.name, 'platform', a.platform,
                   'name', a.name, 'external_id', a.external_id, 'status', a.status, 'last_error', a.last_error,
                   'last_sync_at', a.last_sync_at, 'last_ok_at', a.last_ok_at,
                   'stale', a.last_ok_at IS NULL OR a.last_ok_at < now() - make_interval(hours => coalesce((crm_private.ads_rule('stale_sync_hours')->>'hours')::int, 26))
                 ) ORDER BY cl.name, a.platform), '[]')
                 FROM public.ads_accounts a JOIN public.ads_clients cl ON cl.id = a.client_id
                WHERE cl.active AND (p_client IS NULL OR cl.id = p_client)),
    'pending_approvals', (SELECT count(*) FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id
                            JOIN public.ads_accounts a ON a.id = c.account_id
                           WHERE q.status = 'pending' AND (p_client IS NULL OR a.client_id = p_client)),
    'open_recommendations', (SELECT count(*) FROM public.ads_recommendations r WHERE r.status = 'open' AND (p_client IS NULL OR r.client_id = p_client)),
    'execution_paused', crm_private.ads_cfg('execution_paused') = 'true',
    'last_sync', (SELECT jsonb_build_object('status', s.status, 'at', s.finished_at, 'detail', s.detail)
                    FROM public.ads_sync_runs s WHERE s.job = 'sync' ORDER BY s.started_at DESC LIMIT 1));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_clients() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_can_view() THEN (
    SELECT coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object(
      'accounts', (SELECT count(*) FROM public.ads_accounts a WHERE a.client_id = c.id)) ORDER BY c.active DESC, c.name), '[]')
    FROM public.ads_clients c) ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION public.api_ads_client_save(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cid uuid := nullif(p_data->>'id', '')::uuid; num text;
        nums text[] := ARRAY['avg_order_value','gross_margin_pct','target_cpl','target_qualified_cpl','target_cac','max_cac',
                             'target_roas','ltv','monthly_budget','max_daily_budget'];
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF length(trim(coalesce(p_data->>'name', ''))) < 2 THEN RAISE EXCEPTION 'Client name is required' USING ERRCODE = 'PT422'; END IF;
  FOREACH num IN ARRAY nums LOOP
    IF nullif(p_data->>num, '') IS NOT NULL AND (p_data->>num) !~ '^[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION '% must be a positive number', replace(num, '_', ' ') USING ERRCODE = 'PT422';
    END IF;
  END LOOP;
  IF nullif(p_data->>'gross_margin_pct', '') IS NOT NULL AND (p_data->>'gross_margin_pct')::numeric > 100 THEN
    RAISE EXCEPTION 'Gross margin is a percentage (0–100)' USING ERRCODE = 'PT422'; END IF;
  IF nullif(p_data->>'crm_segment', '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.ads_clients c
      WHERE c.crm_segment = p_data->>'crm_segment' AND c.id IS DISTINCT FROM cid) THEN
    RAISE EXCEPTION 'Another client is already linked to the % leads', p_data->>'crm_segment' USING ERRCODE = 'PT409';
  END IF;
  IF nullif(p_data->>'timezone', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = p_data->>'timezone') THEN
    RAISE EXCEPTION 'Unknown time zone' USING ERRCODE = 'PT422'; END IF;
  IF cid IS NULL THEN
    INSERT INTO public.ads_clients (name, created_by) VALUES (trim(p_data->>'name'), crm_private.current_employee_id()) RETURNING id INTO cid;
  ELSIF NOT EXISTS (SELECT 1 FROM public.ads_clients WHERE id = cid) THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = 'PT404';
  END IF;
  UPDATE public.ads_clients SET
    name = trim(p_data->>'name'),
    website = nullif(trim(p_data->>'website'), ''), industry = nullif(trim(p_data->>'industry'), ''),
    business_model = nullif(trim(p_data->>'business_model'), ''), products = nullif(trim(p_data->>'products'), ''),
    geography = nullif(trim(p_data->>'geography'), ''), audience = nullif(trim(p_data->>'audience'), ''),
    competitors = nullif(trim(p_data->>'competitors'), ''), objectives = nullif(trim(p_data->>'objectives'), ''),
    brand_notes = nullif(trim(p_data->>'brand_notes'), ''), restrictions = nullif(trim(p_data->>'restrictions'), ''),
    currency = coalesce(nullif(upper(trim(p_data->>'currency')), ''), 'INR'),
    timezone = coalesce(nullif(p_data->>'timezone', ''), 'Asia/Kolkata'),
    crm_segment = nullif(p_data->>'crm_segment', ''),
    avg_order_value = nullif(p_data->>'avg_order_value', '')::numeric, gross_margin_pct = nullif(p_data->>'gross_margin_pct', '')::numeric,
    target_cpl = nullif(p_data->>'target_cpl', '')::numeric, target_qualified_cpl = nullif(p_data->>'target_qualified_cpl', '')::numeric,
    target_cac = nullif(p_data->>'target_cac', '')::numeric, max_cac = nullif(p_data->>'max_cac', '')::numeric,
    target_roas = nullif(p_data->>'target_roas', '')::numeric, ltv = nullif(p_data->>'ltv', '')::numeric,
    sales_cycle_days = nullif(p_data->>'sales_cycle_days', '')::int,
    monthly_budget = nullif(p_data->>'monthly_budget', '')::numeric, max_daily_budget = nullif(p_data->>'max_daily_budget', '')::numeric,
    active = coalesce((p_data->>'active')::boolean, true),
    updated_at = now()
  WHERE id = cid;
  PERFORM crm_private.ads_log('client_saved', 'client', cid::text, jsonb_build_object('name', p_data->>'name'));
  RETURN cid;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_accounts(p_client uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('client', cl.name,
            'campaigns', (SELECT count(*) FROM public.ads_campaigns c WHERE c.account_id = a.id)) ORDER BY cl.name, a.platform), '[]')
            FROM public.ads_accounts a JOIN public.ads_clients cl ON cl.id = a.client_id
           WHERE p_client IS NULL OR a.client_id = p_client);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_account_save(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE aid uuid := nullif(p_data->>'id', '')::uuid; plat text := p_data->>'platform';
        ext text := regexp_replace(coalesce(p_data->>'external_id', ''), '^act_|-', '', 'g');
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF aid IS NULL THEN
    IF plat NOT IN ('google', 'meta') THEN RAISE EXCEPTION 'Platform must be google or meta' USING ERRCODE = 'PT422'; END IF;
    IF plat = 'google' AND ext !~ '^[0-9]{10}$' THEN RAISE EXCEPTION 'Google Ads customer ID is 10 digits (123-456-7890)' USING ERRCODE = 'PT422'; END IF;
    IF plat = 'meta' AND ext !~ '^[0-9]{5,25}$' THEN RAISE EXCEPTION 'Meta ad account ID is digits (act_ prefix optional)' USING ERRCODE = 'PT422'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.ads_clients WHERE id = (p_data->>'client_id')::uuid) THEN
      RAISE EXCEPTION 'Pick a client' USING ERRCODE = 'PT422'; END IF;
    IF EXISTS (SELECT 1 FROM public.ads_accounts WHERE platform = plat AND external_id = ext) THEN
      RAISE EXCEPTION 'This account is already added' USING ERRCODE = 'PT409'; END IF;
    INSERT INTO public.ads_accounts (client_id, platform, external_id, name, utm_source)
    VALUES ((p_data->>'client_id')::uuid, plat, ext, nullif(trim(p_data->>'name'), ''), nullif(trim(p_data->>'utm_source'), ''))
    RETURNING id INTO aid;
    PERFORM crm_private.ads_log('account_added', 'account', aid::text, jsonb_build_object('platform', plat, 'external_id', ext));
  ELSE
    UPDATE public.ads_accounts SET
      name = coalesce(nullif(trim(p_data->>'name'), ''), name),
      utm_source = nullif(trim(p_data->>'utm_source'), ''),
      status = CASE WHEN (p_data->>'disabled')::boolean IS TRUE THEN 'disabled'
                    WHEN (p_data->>'disabled')::boolean IS FALSE AND status = 'disabled' THEN 'not_synced' ELSE status END,
      updated_at = now()
    WHERE id = aid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Account not found' USING ERRCODE = 'PT404'; END IF;
    PERFORM crm_private.ads_log('account_saved', 'account', aid::text, p_data - 'id');
  END IF;
  RETURN aid;
END $$;

-- Campaign table with period metrics and CRM leads.
CREATE OR REPLACE FUNCTION public.api_ads_campaigns(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  WITH m AS (
    SELECT d.campaign_id, sum(d.spend) spend, sum(d.impressions) impressions, sum(d.clicks) clicks,
           sum(d.conversions) conversions, sum(d.conversion_value) conversion_value
      FROM public.ads_metrics_daily d WHERE d.day BETWEEN p_from AND p_to GROUP BY 1),
  l AS (
    SELECT x.campaign_id, array_agg(x.lead_id) ids
      FROM public.ads_clients c, LATERAL crm_private.ads_client_leads(c.id, p_from, p_to) x
     WHERE (p_client IS NULL OR c.id = p_client) AND x.campaign_id IS NOT NULL GROUP BY 1)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'status', c.status, 'platform', a.platform, 'account', coalesce(a.name, a.external_id),
      'account_status', a.status, 'client', cl.name, 'client_id', cl.id, 'currency', coalesce(a.currency, cl.currency),
      'objective', c.objective, 'channel', c.channel, 'daily_budget', c.daily_budget, 'budget_editable', c.budget_ref IS NOT NULL,
      'utm_campaign', c.utm_campaign, 'synced_at', c.synced_at,
      'spend', m.spend, 'impressions', m.impressions, 'clicks', m.clicks, 'conversions', m.conversions,
      'conversion_value', m.conversion_value,
      'ctr', crm_private.ads_div(m.clicks, m.impressions, 100), 'cpc', crm_private.ads_div(m.spend, m.clicks),
      'cpm', crm_private.ads_div(m.spend, m.impressions, 1000), 'platform_roas', crm_private.ads_div(m.conversion_value, m.spend),
      'crm_linked', cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL,
      'crm', CASE WHEN cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL
                  THEN crm_private.ads_lead_outcomes(coalesce(l.ids, '{}')) END)
    ORDER BY m.spend DESC NULLS LAST, c.name), '[]')
  INTO out
  FROM public.ads_campaigns c JOIN public.ads_accounts a ON a.id = c.account_id JOIN public.ads_clients cl ON cl.id = a.client_id
  LEFT JOIN m ON m.campaign_id = c.id LEFT JOIN l ON l.campaign_id = c.id
  WHERE (p_client IS NULL OR cl.id = p_client) AND coalesce(c.status, '') <> 'REMOVED';
  -- per-campaign CPL / qualified CPL / CAC (only where currency matches and CRM is linked)
  RETURN (SELECT coalesce(jsonb_agg(e || CASE WHEN e->'crm' IS NULL OR jsonb_typeof(e->'crm') = 'null' THEN '{}'::jsonb ELSE jsonb_build_object(
            'cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'valid')::numeric),
            'qualified_cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'qualified')::numeric),
            'cac', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'customers')::numeric)) END), '[]')
          FROM jsonb_array_elements(out) e);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_campaign_daily(p_campaign uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'spend', d.spend, 'impressions', d.impressions,
            'clicks', d.clicks, 'conversions', d.conversions, 'conversion_value', d.conversion_value) ORDER BY d.day), '[]')
            FROM public.ads_metrics_daily d WHERE d.campaign_id = p_campaign AND d.day BETWEEN p_from AND p_to);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_campaign_map(p_campaign uuid, p_utm_campaign text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  UPDATE public.ads_campaigns SET utm_campaign = nullif(trim(p_utm_campaign), '') WHERE id = p_campaign;
  IF NOT FOUND THEN RAISE EXCEPTION 'Campaign not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('campaign_utm_mapped', 'campaign', p_campaign::text, jsonb_build_object('utm_campaign', p_utm_campaign));
END $$;

-- CRM leads that came from ads for a client and period (newest first), with outcome flags.
CREATE OR REPLACE FUNCTION public.api_ads_leads(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_client IS NULL THEN RAISE EXCEPTION 'Pick a client' USING ERRCODE = 'PT422'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'created_at', l.created_at,
            'utm_source', l.utm_source, 'utm_campaign', l.utm_campaign, 'status', l.status,
            'campaign', c.name, 'platform', x.platform,
            'customer', coalesce(l.closure_outcome::text IN ('admission_completed', 'booking_confirmed'), false),
            'outcome', crm_private.ads_lead_outcomes(ARRAY[l.id])) ORDER BY l.created_at DESC), '[]')
          FROM crm_private.ads_client_leads(p_client, p_from, p_to) x
          JOIN public.lead l ON l.id = x.lead_id LEFT JOIN public.ads_campaigns c ON c.id = x.campaign_id);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_revenue(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('lead_name', l.name) ORDER BY r.occurred_on DESC, r.id DESC), '[]')
            FROM public.ads_revenue r LEFT JOIN public.lead l ON l.id = r.lead_id
           WHERE r.client_id = p_client AND r.occurred_on BETWEEN p_from AND p_to);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_revenue_add(p_client uuid, p_kind text, p_amount numeric, p_on date,
  p_lead uuid DEFAULT NULL, p_note text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint; cur text;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only approvers can record revenue' USING ERRCODE = 'PT403'; END IF;
  SELECT currency INTO cur FROM public.ads_clients WHERE id = p_client;
  IF cur IS NULL THEN RAISE EXCEPTION 'Client not found' USING ERRCODE = 'PT404'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be above 0' USING ERRCODE = 'PT422'; END IF;
  IF p_on IS NULL OR p_on > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN RAISE EXCEPTION 'Pick the date it happened (not in the future)' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_revenue (client_id, lead_id, kind, amount, currency, occurred_on, note, created_by)
  VALUES (p_client, p_lead, coalesce(p_kind, 'sale'), round(p_amount, 2), cur, p_on, nullif(trim(p_note), ''), crm_private.current_employee_id())
  RETURNING id INTO rid;
  PERFORM crm_private.ads_log('revenue_added', 'revenue', rid::text, jsonb_build_object('kind', p_kind, 'amount', p_amount, 'on', p_on));
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_revenue_delete(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_revenue;
BEGIN
  PERFORM crm_private.ads_require_admin();
  DELETE FROM public.ads_revenue WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('revenue_deleted', 'revenue', p_id::text, jsonb_build_object('amount', r.amount, 'kind', r.kind, 'on', r.occurred_on));
END $$;

-- Recommendations
CREATE OR REPLACE FUNCTION public.api_ads_recommendations(p_client uuid DEFAULT NULL, p_status text DEFAULT 'open') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('client', cl.name, 'campaign', c.name,
            'change_status', q.status) ORDER BY r.created_at DESC), '[]')
            FROM public.ads_recommendations r JOIN public.ads_clients cl ON cl.id = r.client_id
            LEFT JOIN public.ads_campaigns c ON c.id = r.campaign_id LEFT JOIN public.ads_change_queue q ON q.id = r.change_id
           WHERE (p_client IS NULL OR r.client_id = p_client) AND (p_status IS NULL OR r.status = p_status));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_recommend_run() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  PERFORM crm_private.ads_require_view();
  n := crm_private.ads_recommend_all();
  PERFORM crm_private.ads_log('recommendations_run', 'recommendation', NULL, jsonb_build_object('new', n));
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_recommendation_dismiss(p_id bigint, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF length(trim(coalesce(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'Say why (a few words)' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.ads_recommendations SET status = 'dismissed', dismiss_reason = trim(p_reason), resolved_at = now()
   WHERE id = p_id AND status = 'open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Recommendation is not open' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.ads_log('recommendation_dismissed', 'recommendation', p_id::text, jsonb_build_object('reason', p_reason));
END $$;

-- Change queue
CREATE OR REPLACE FUNCTION public.api_ads_check(p_campaign uuid, p_kind text, p_after jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_evaluate(p_campaign, p_kind, p_after);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_change_create(p_campaign uuid, p_kind text, p_after jsonb, p_summary text DEFAULT '',
  p_recommendation bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.ads_change_queue;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_kind NOT IN ('budget', 'status') THEN RAISE EXCEPTION 'Unknown change type' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_change_queue (campaign_id, kind, after, summary, recommendation_id, created_by)
  VALUES (p_campaign, p_kind, coalesce(p_after, '{}'), left(coalesce(p_summary, ''), 300), p_recommendation, crm_private.current_employee_id())
  RETURNING * INTO q;
  IF p_recommendation IS NOT NULL THEN
    UPDATE public.ads_recommendations SET status = 'queued', change_id = q.id WHERE id = p_recommendation AND status = 'open';
  END IF;
  PERFORM crm_private.ads_log('change_drafted', 'change', q.id::text, jsonb_build_object('kind', p_kind, 'after', p_after));
  RETURN jsonb_build_object('id', q.id, 'guard_result', q.guard_result, 'needs_second_confirm', q.needs_second_confirm);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_queue(p_status text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(q) || jsonb_build_object('campaign', c.name, 'platform', a.platform,
            'client', cl.name, 'currency', coalesce(a.currency, cl.currency),
            'created_by_name', e.name, 'approved_by_name', e2.name) ORDER BY q.created_at DESC), '[]')
            FROM (SELECT * FROM public.ads_change_queue WHERE p_status IS NULL OR status = p_status ORDER BY created_at DESC LIMIT 300) q
            JOIN public.ads_campaigns c ON c.id = q.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
            JOIN public.ads_clients cl ON cl.id = a.client_id
            LEFT JOIN public.employee e ON e.id = q.created_by LEFT JOIN public.employee e2 ON e2.id = q.approved_by);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_approve(p_id uuid, p_second_confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.ads_change_queue;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'You cannot approve changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO q FROM public.ads_change_queue WHERE id = p_id FOR UPDATE;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Change not found' USING ERRCODE = 'PT404'; END IF;
  IF q.status <> 'pending' THEN RAISE EXCEPTION 'This change is already %', q.status USING ERRCODE = 'PT409'; END IF;
  UPDATE public.ads_change_queue SET status = 'approved', second_confirmed = coalesce(p_second_confirm, false),
         approved_by = crm_private.current_employee_id(), approved_at = now()
   WHERE id = p_id RETURNING * INTO q;
  PERFORM crm_private.ads_log('change_approved', 'change', p_id::text, jsonb_build_object('second_confirm', p_second_confirm));
  RETURN jsonb_build_object('id', q.id, 'status', q.status);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_reject(p_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rec bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  UPDATE public.ads_change_queue SET status = CASE WHEN crm_private.ads_can_approve() THEN 'rejected' ELSE 'cancelled' END,
         reject_reason = nullif(trim(p_reason), '')
   WHERE id = p_id AND status IN ('pending', 'approved') RETURNING recommendation_id INTO rec;
  IF NOT FOUND THEN RAISE EXCEPTION 'Only waiting changes can be rejected' USING ERRCODE = 'PT409'; END IF;
  IF rec IS NOT NULL THEN UPDATE public.ads_recommendations SET status = 'open', change_id = NULL WHERE id = rec AND status = 'queued'; END IF;
  PERFORM crm_private.ads_log('change_rejected', 'change', p_id::text, jsonb_build_object('reason', p_reason));
END $$;

-- Research and experiments
CREATE OR REPLACE FUNCTION public.api_ads_research(p_client uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]') FROM public.ads_research r
           WHERE p_client IS NULL OR r.client_id = p_client);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_research_save(p_data jsonb) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint := nullif(p_data->>'id', '')::bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_data->>'classification' = 'fact' AND nullif(trim(p_data->>'source_url'), '') IS NULL THEN
    RAISE EXCEPTION 'A verified fact needs a source URL' USING ERRCODE = 'PT422'; END IF;
  IF rid IS NULL THEN
    INSERT INTO public.ads_research (client_id, topic, competitor, segment, geography, observation, classification, source_url,
      publisher, published_on, confidence, interpretation, opportunity, action, created_by)
    VALUES ((p_data->>'client_id')::uuid, trim(p_data->>'topic'), nullif(trim(p_data->>'competitor'), ''), nullif(trim(p_data->>'segment'), ''),
      nullif(trim(p_data->>'geography'), ''), trim(p_data->>'observation'), p_data->>'classification', nullif(trim(p_data->>'source_url'), ''),
      nullif(trim(p_data->>'publisher'), ''), nullif(p_data->>'published_on', '')::date, coalesce(nullif(p_data->>'confidence', ''), 'medium'),
      nullif(trim(p_data->>'interpretation'), ''), nullif(trim(p_data->>'opportunity'), ''), nullif(trim(p_data->>'action'), ''),
      crm_private.current_employee_id())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.ads_research SET topic = trim(p_data->>'topic'), competitor = nullif(trim(p_data->>'competitor'), ''),
      observation = trim(p_data->>'observation'), classification = p_data->>'classification',
      source_url = nullif(trim(p_data->>'source_url'), ''), publisher = nullif(trim(p_data->>'publisher'), ''),
      published_on = nullif(p_data->>'published_on', '')::date, confidence = coalesce(nullif(p_data->>'confidence', ''), 'medium'),
      interpretation = nullif(trim(p_data->>'interpretation'), ''), opportunity = nullif(trim(p_data->>'opportunity'), ''),
      action = nullif(trim(p_data->>'action'), '')
    WHERE id = rid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Not found' USING ERRCODE = 'PT404'; END IF;
  END IF;
  PERFORM crm_private.ads_log('research_saved', 'research', rid::text, jsonb_build_object('topic', p_data->>'topic'));
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_experiments(p_client uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]') FROM public.ads_experiments x
           WHERE p_client IS NULL OR x.client_id = p_client);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_experiment_save(p_data jsonb) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE xid bigint := nullif(p_data->>'id', '')::bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF length(trim(coalesce(p_data->>'hypothesis', ''))) < 5 THEN RAISE EXCEPTION 'Write the hypothesis' USING ERRCODE = 'PT422'; END IF;
  IF p_data->>'status' = 'done' AND nullif(p_data->>'confidence', '') IS NULL THEN
    RAISE EXCEPTION 'Say how confident the result is (choose "not enough data" if unsure)' USING ERRCODE = 'PT422'; END IF;
  IF xid IS NULL THEN
    INSERT INTO public.ads_experiments (client_id, name, kind, hypothesis, control, treatment, primary_metric, secondary_metrics,
      sample_plan, starts_on, ends_on, created_by)
    VALUES ((p_data->>'client_id')::uuid, trim(p_data->>'name'), coalesce(nullif(p_data->>'kind', ''), 'creative'), trim(p_data->>'hypothesis'),
      nullif(trim(p_data->>'control'), ''), nullif(trim(p_data->>'treatment'), ''), trim(p_data->>'primary_metric'),
      nullif(trim(p_data->>'secondary_metrics'), ''), nullif(trim(p_data->>'sample_plan'), ''),
      nullif(p_data->>'starts_on', '')::date, nullif(p_data->>'ends_on', '')::date, crm_private.current_employee_id())
    RETURNING id INTO xid;
  ELSE
    UPDATE public.ads_experiments SET name = trim(p_data->>'name'), hypothesis = trim(p_data->>'hypothesis'),
      control = nullif(trim(p_data->>'control'), ''), treatment = nullif(trim(p_data->>'treatment'), ''),
      primary_metric = trim(p_data->>'primary_metric'), sample_plan = nullif(trim(p_data->>'sample_plan'), ''),
      starts_on = nullif(p_data->>'starts_on', '')::date, ends_on = nullif(p_data->>'ends_on', '')::date,
      status = coalesce(nullif(p_data->>'status', ''), status), result = nullif(trim(p_data->>'result'), ''),
      confidence = nullif(p_data->>'confidence', ''), decision = nullif(trim(p_data->>'decision'), ''), updated_at = now()
    WHERE id = xid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Not found' USING ERRCODE = 'PT404'; END IF;
  END IF;
  PERFORM crm_private.ads_log('experiment_saved', 'experiment', xid::text, jsonb_build_object('name', p_data->>'name', 'status', p_data->>'status'));
  RETURN xid;
END $$;

-- Activity, rules, team access
CREATE OR REPLACE FUNCTION public.api_ads_activity(p_limit int DEFAULT 200) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('at', x.at, 'who', coalesce(e.name, x.actor_type), 'action', x.action,
            'entity', x.entity, 'entity_id', x.entity_id, 'details', x.details) ORDER BY x.at DESC), '[]')
            FROM (SELECT * FROM public.ads_activity_log ORDER BY at DESC LIMIT least(coalesce(p_limit, 200), 1000)) x
            LEFT JOIN public.employee e ON e.id = x.actor);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_sync_runs() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.started_at DESC), '[]')
            FROM (SELECT * FROM public.ads_sync_runs ORDER BY started_at DESC LIMIT 50) r);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_rules() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.severity, r.code), '[]') FROM public.ads_rules r);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_rule_set(p_code text, p_value jsonb, p_active boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE old jsonb; k text;
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT value INTO old FROM public.ads_rules WHERE code = p_code;
  IF old IS NULL THEN RAISE EXCEPTION 'Unknown rule' USING ERRCODE = 'PT404'; END IF;
  FOR k IN SELECT jsonb_object_keys(old) LOOP          -- same keys, numeric values only
    IF NOT (p_value ? k) OR jsonb_typeof(p_value->k) <> 'number' OR (p_value->>k)::numeric < 0 THEN
      RAISE EXCEPTION 'Rule value % must be a number of 0 or more', k USING ERRCODE = 'PT422';
    END IF;
  END LOOP;
  UPDATE public.ads_rules SET value = old || (p_value - ARRAY(SELECT jsonb_object_keys(p_value) EXCEPT SELECT jsonb_object_keys(old))),
         active = coalesce(p_active, active), updated_at = now() WHERE code = p_code;
  PERFORM crm_private.ads_log('rule_changed', 'rule', p_code, jsonb_build_object('from', old, 'to', p_value, 'active', p_active));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_team() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'department', e.department,
            'access', a.employee_id IS NOT NULL OR e.department = 'Admin', 'can_approve', coalesce(a.can_approve, false) OR e.department = 'Admin',
            'is_admin', e.department = 'Admin') ORDER BY e.name), '[]')
            FROM public.employee e LEFT JOIN public.ads_access a ON a.employee_id = e.id WHERE e.active);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_team_set(p_employee uuid, p_access boolean, p_can_approve boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF NOT coalesce(p_access, false) THEN
    DELETE FROM public.ads_access WHERE employee_id = p_employee;
  ELSE
    INSERT INTO public.ads_access (employee_id, can_approve, granted_by) VALUES (p_employee, coalesce(p_can_approve, false), crm_private.current_employee_id())
      ON CONFLICT (employee_id) DO UPDATE SET can_approve = EXCLUDED.can_approve, granted_by = EXCLUDED.granted_by, granted_at = now();
  END IF;
  PERFORM crm_private.ads_log('access_changed', 'employee', p_employee::text, jsonb_build_object('access', p_access, 'can_approve', p_can_approve));
END $$;

-- ===========================================================================================
-- 9. Service API for the ads-sync Edge Function (service role only)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.svc_ads_secrets() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '{}'; nm text; v text;
BEGIN
  FOREACH nm IN ARRAY crm_private.ads_secret_names() LOOP
    SELECT d.decrypted_secret INTO v FROM vault.decrypted_secrets d WHERE d.name = 'ads_' || lower(nm);
    IF v IS NOT NULL THEN out := out || jsonb_build_object(nm, v); END IF;
    v := NULL;
  END LOOP;
  RETURN out || jsonb_build_object('GOOGLE_API_VERSION', crm_private.ads_cfg('google_api_version'),
    'META_API_VERSION', crm_private.ads_cfg('meta_api_version'), 'SYNC_DAYS', crm_private.ads_cfg('sync_days'),
    'EXECUTION_PAUSED', crm_private.ads_cfg('execution_paused'));
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_run_begin(p_job text, p_seconds int DEFAULT 600) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint;
BEGIN
  IF NOT crm_private.take_lease('ads_' || p_job, p_seconds) THEN
    INSERT INTO public.ads_sync_runs (job, status, detail, finished_at) VALUES (p_job, 'skipped', 'another run holds the lock', now());
    RETURN NULL;
  END IF;
  INSERT INTO public.ads_sync_runs (job) VALUES (p_job) RETURNING id INTO rid;
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_run_end(p_run bigint, p_job text, p_status text, p_items int, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.ads_sync_runs SET status = p_status, items = p_items, detail = left(p_detail, 1000), finished_at = now() WHERE id = p_run;
  UPDATE public.job_lease SET lease_until = now() WHERE name = 'ads_' || p_job AND holder = 'supabase';
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_accounts() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'platform', a.platform, 'external_id', a.external_id)), '[]')
    FROM public.ads_accounts a JOIN public.ads_clients c ON c.id = a.client_id
   WHERE a.status <> 'disabled' AND c.active
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_account_status(p_account uuid, p_status text, p_error text,
  p_name text DEFAULT NULL, p_currency text DEFAULT NULL, p_timezone text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_accounts SET status = p_status, last_error = left(p_error, 500), last_sync_at = now(),
         last_ok_at = CASE WHEN p_status = 'connected' THEN now() ELSE last_ok_at END,
         name = coalesce(p_name, name), currency = coalesce(p_currency, currency), timezone = coalesce(p_timezone, timezone),
         updated_at = now()
   WHERE id = p_account AND status <> 'disabled'
$$;

-- p_items: [{external_id, name, status, platform_status, objective, channel, daily_budget, budget_ref, raw}]
CREATE OR REPLACE FUNCTION public.svc_ads_upsert_campaigns(p_account uuid, p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  INSERT INTO public.ads_campaigns (account_id, external_id, name, status, platform_status, objective, channel,
    daily_budget, budget_ref, raw, synced_at)
  SELECT p_account, i->>'external_id', i->>'name', i->>'status', i->>'platform_status', i->>'objective', i->>'channel',
         nullif(i->>'daily_budget', '')::numeric, nullif(i->>'budget_ref', ''), coalesce(i->'raw', '{}'), now()
    FROM jsonb_array_elements(coalesce(p_items, '[]')) i
  ON CONFLICT (account_id, external_id) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status,
    platform_status = EXCLUDED.platform_status, objective = EXCLUDED.objective, channel = EXCLUDED.channel,
    daily_budget = EXCLUDED.daily_budget, budget_ref = EXCLUDED.budget_ref, raw = EXCLUDED.raw, synced_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- p_items: [{campaign_external_id, day, impressions, clicks, spend, conversions, conversion_value, reach, video_views, raw}]
-- The platform's numbers for a day replace what we had (late conversions and corrections arrive for days afterwards).
CREATE OR REPLACE FUNCTION public.svc_ads_upsert_metrics(p_account uuid, p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  INSERT INTO public.ads_metrics_daily (campaign_id, day, impressions, clicks, spend, conversions, conversion_value, reach, video_views, raw)
  SELECT c.id, (i->>'day')::date, nullif(i->>'impressions', '')::bigint, nullif(i->>'clicks', '')::bigint,
         nullif(i->>'spend', '')::numeric, nullif(i->>'conversions', '')::numeric, nullif(i->>'conversion_value', '')::numeric,
         nullif(i->>'reach', '')::bigint, nullif(i->>'video_views', '')::bigint, coalesce(i->'raw', '{}')
    FROM jsonb_array_elements(coalesce(p_items, '[]')) i
    JOIN public.ads_campaigns c ON c.account_id = p_account AND c.external_id = i->>'campaign_external_id'
  ON CONFLICT (campaign_id, day) DO UPDATE SET impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
    spend = EXCLUDED.spend, conversions = EXCLUDED.conversions, conversion_value = EXCLUDED.conversion_value,
    reach = EXCLUDED.reach, video_views = EXCLUDED.video_views, raw = EXCLUDED.raw, updated_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Approved changes ready to send, plus the account/campaign details the executor needs.
CREATE OR REPLACE FUNCTION public.svc_ads_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'after', q.after, 'before', q.before,
      'idempotency_key', q.idempotency_key, 'platform', a.platform, 'account_external_id', a.external_id, 'account_id', a.id,
      'campaign_external_id', c.external_id, 'budget_ref', c.budget_ref) ORDER BY q.approved_at), '[]')
      FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
     WHERE q.status = 'approved') END
$$;

-- approved -> executing (claim). Returns false if someone else claimed it, or the guards now block it.
CREATE OR REPLACE FUNCTION public.svc_ads_claim(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.ads_change_queue; g jsonb;
BEGIN
  SELECT * INTO q FROM public.ads_change_queue WHERE id = p_id AND status = 'approved' FOR UPDATE SKIP LOCKED;
  IF q.id IS NULL OR crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN false; END IF;
  g := crm_private.ads_evaluate(q.campaign_id, q.kind, q.after, q.id);
  -- the campaign changed since approval (different budget/status): do not send a stale change
  IF jsonb_array_length(g->'blockers') > 0 OR
     (SELECT (c.daily_budget IS DISTINCT FROM (q.before->>'daily_budget')::numeric) OR (c.status IS DISTINCT FROM q.before->>'status')
        FROM public.ads_campaigns c WHERE c.id = q.campaign_id) THEN
    UPDATE public.ads_change_queue SET status = 'stale', error = 'The campaign changed or a guard now blocks this change. Draft it again.',
           guard_result = g WHERE id = p_id;
    RETURN false;
  END IF;
  UPDATE public.ads_change_queue SET status = 'executing', executed_at = now() WHERE id = p_id;
  RETURN true;
END $$;

-- executing -> verified | failed | outcome_unknown. On verified, the campaign row is updated to the new state.
CREATE OR REPLACE FUNCTION public.svc_ads_finish(p_id uuid, p_status text, p_error text, p_verify jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.ads_change_queue;
BEGIN
  IF p_status NOT IN ('verified', 'failed', 'outcome_unknown') THEN RAISE EXCEPTION 'bad status'; END IF;
  UPDATE public.ads_change_queue SET status = p_status, error = left(p_error, 900), verify_result = p_verify
   WHERE id = p_id AND status IN ('executing', 'outcome_unknown') RETURNING * INTO q;
  IF q.id IS NULL THEN RETURN; END IF;
  IF p_status = 'verified' THEN
    UPDATE public.ads_campaigns SET
      daily_budget = CASE WHEN q.kind = 'budget' THEN (q.after->>'daily_budget')::numeric ELSE daily_budget END,
      status = CASE WHEN q.kind = 'status' THEN upper(q.after->>'status') ELSE status END
     WHERE id = q.campaign_id;
    UPDATE public.ads_recommendations SET status = 'done', resolved_at = now() WHERE change_id = q.id;
  END IF;
  INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('system', 'change_' || p_status, 'change', p_id::text, jsonb_build_object('error', left(p_error, 300), 'verify', p_verify));
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_unknown() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'after', q.after, 'platform', a.platform,
      'account_external_id', a.external_id, 'campaign_external_id', c.external_id, 'budget_ref', c.budget_ref)), '[]')
    FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
   WHERE q.status = 'outcome_unknown' OR (q.status = 'executing' AND q.executed_at < now() - interval '10 minutes')
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_recommend() RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.ads_recommend_all() $$;

-- ===========================================================================================
-- 10. Grants
-- ===========================================================================================
DO $$
DECLARE f text;
BEGIN
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND (p.proname LIKE 'api\_ads\_%' OR p.proname LIKE 'svc\_ads\_%') LOOP
    IF f LIKE 'api\_ads\_%' THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    ELSE
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'crm_private' AND p.proname LIKE 'ads\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);   -- reached only through api_/svc_ functions
  END LOOP;
END $$;
