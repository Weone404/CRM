-- 110: Meta Ads > Automate: quick actions, automated rules (always with approval) and A/B tests. Run after 109.
-- Re-runnable. Rollback: 110_ads_meta_actions_down.sql.
--
--  * Quick actions on a campaign, ad set or ad: pause, switch on, change the daily budget, duplicate (paused). Every action
--    is a request an approver approves; ads-sync job meta_actions then reads the live object, applies the change and reads
--    it back. Guards: the Meta emergency stop, a daily-budget floor and ceiling, raises above 100% only by Admin, a warning
--    for changes of 20% or more (a big edit restarts Meta's learning phase), requests expire after 3 days, and an object
--    that changed since the request is marked "stale" instead of being overwritten.
--  * Rules (CRM-side, so they can use CRM quality, which Meta's own rules cannot): metric over a window (spend, leads, cost
--    per lead, cost per qualified lead, qualified, CTR, frequency, CPM), a minimum spend / leads before judging, an action
--    (pause, budget up / down by %, or a warning only) and a cool-down. Rules only create requests; nothing changes until
--    an approver approves. Checked every morning (09:10 IST) and on "Run now".
--  * A/B tests: 2-5 cells of ad sets, ads or campaigns, one variable, a metric and a period; results with the share of
--    spend vs the share of results and a significance test (two-proportion z-test, or a binomial test of leads against spend
--    share for cost metrics), plus "too early" until each cell has enough results. Optionally created in Meta as a real
--    split test (ad study: non-overlapping audiences) when the ad account belongs to a Business.

CREATE TABLE IF NOT EXISTS public.ads_meta_action (
  id bigserial PRIMARY KEY,
  level text NOT NULL CHECK (level IN ('campaign', 'adset', 'ad')),
  object_id text NOT NULL CHECK (object_id ~ '^[0-9]{3,25}$'),
  object_name text,
  kind text NOT NULL CHECK (kind IN ('pause', 'activate', 'budget', 'duplicate')),
  params jsonb NOT NULL DEFAULT '{}',
  reason text,
  source text NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'rule', 'test')),
  rule_id bigint, test_id bigint,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'executing', 'done', 'failed', 'rejected', 'cancelled', 'stale', 'expired')),
  guard jsonb NOT NULL DEFAULT '[]',
  before jsonb, after jsonb, error text,
  requested_by uuid, approved_by uuid, decided_at timestamptz, note text,
  executed_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '3 days',
  created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS ux_ads_meta_action_open ON public.ads_meta_action (object_id, kind) WHERE status IN ('pending', 'approved', 'executing');
CREATE INDEX IF NOT EXISTS idx_ads_meta_action_status ON public.ads_meta_action (status, created_at DESC);
ALTER TABLE public.ads_meta_action ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_action FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_rule (
  id bigserial PRIMARY KEY,
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 100),
  enabled boolean NOT NULL DEFAULT false,
  level text NOT NULL CHECK (level IN ('campaign', 'adset', 'ad')),
  name_contains text,
  metric text NOT NULL CHECK (metric IN ('spend', 'leads', 'cpl', 'cpql', 'qualified', 'ctr', 'frequency', 'cpm')),
  window_days int NOT NULL DEFAULT 7 CHECK (window_days BETWEEN 1 AND 30),
  op text NOT NULL CHECK (op IN ('gt', 'lt')),
  value numeric NOT NULL,
  min_spend numeric NOT NULL DEFAULT 0, min_leads int NOT NULL DEFAULT 0,
  action text NOT NULL CHECK (action IN ('pause', 'budget_up', 'budget_down', 'notify')),
  pct numeric CHECK (pct IS NULL OR pct BETWEEN 1 AND 100),
  cooldown_days int NOT NULL DEFAULT 3 CHECK (cooldown_days BETWEEN 0 AND 30),
  last_run_at timestamptz, last_hits int,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_rule ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_rule FROM anon, authenticated;

INSERT INTO public.ads_meta_rule (name, level, metric, window_days, op, value, min_spend, min_leads, action, pct, cooldown_days)
SELECT * FROM (VALUES
  ('Pause ads that spent ₹1,500 in 7 days without a lead', 'ad', 'leads', 7, 'lt', 1, 1500, 0, 'pause', NULL::numeric, 7),
  ('Pause ad sets whose cost per qualified lead is above ₹4,000 (14 days)', 'adset', 'cpql', 14, 'gt', 4000, 3000, 10, 'pause', NULL, 7),
  ('Raise budget 15% when cost per qualified lead is under ₹1,500 (7 days, 3+ qualified)', 'adset', 'cpql', 7, 'lt', 1500, 1000, 5, 'budget_up', 15, 4),
  ('Warn when frequency passes 3.5 (7 days)', 'ad', 'frequency', 7, 'gt', 3.5, 500, 0, 'notify', NULL, 7)) v(name, level, metric, window_days, op, value, min_spend, min_leads, action, pct, cooldown_days)
WHERE NOT EXISTS (SELECT 1 FROM public.ads_meta_rule);

CREATE TABLE IF NOT EXISTS public.ads_meta_test (
  id bigserial PRIMARY KEY,
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 100),
  hypothesis text,
  variable text NOT NULL DEFAULT 'creative' CHECK (variable IN ('creative', 'audience', 'placement', 'form', 'offer', 'other')),
  level text NOT NULL CHECK (level IN ('campaign', 'adset', 'ad')),
  cells jsonb NOT NULL,                     -- [{name, ids: [...]}], 2-5 cells; the first is the control
  metric text NOT NULL CHECK (metric IN ('cost_per_lead', 'cost_per_qualified', 'qualified_rate', 'ctr')),
  start_date date NOT NULL, end_date date NOT NULL,
  min_results int NOT NULL DEFAULT 30 CHECK (min_results BETWEEN 5 AND 10000),
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'finished', 'stopped')),
  meta_split boolean NOT NULL DEFAULT false, meta_study_id text, meta_detail text,
  decision text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date));
ALTER TABLE public.ads_meta_test ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_test FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('meta_action_min_daily', '100'), ('meta_action_max_daily', '50000'), ('meta_actions_two_person', 'false')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------------------------------- numbers per object
-- Meta numbers (ads_meta_ad_day) and CRM results (the lead archive with its ids) per campaign / ad set / ad in a period.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_obj_stats(p_level text, p_from date, p_to date)
RETURNS TABLE (object_id text, name text, status text, campaign_id text, adset_id text, spend numeric, impressions bigint, clicks bigint,
  leads bigint, frequency numeric, crm_leads bigint, known bigint, qualified bigint, customers bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH d AS (
    SELECT CASE p_level WHEN 'campaign' THEN d.campaign_ext WHEN 'adset' THEN d.adset_ext ELSE d.ad_ext END oid,
           max(d.campaign_ext) cid, max(d.adset_ext) sid, sum(d.spend) spend, sum(d.impressions) imp, sum(coalesce(d.link_clicks, d.clicks)) clk,
           sum(d.leads) leads, round(avg(d.frequency) FILTER (WHERE d.frequency IS NOT NULL), 2) freq
      FROM public.ads_meta_ad_day d
     WHERE d.account_id = (crm_private.ads_meta_acct()).id AND d.day BETWEEN p_from AND p_to
     GROUP BY 1),
  c AS (
    SELECT CASE p_level WHEN 'campaign' THEN a.campaign_id WHEN 'adset' THEN a.adset_id ELSE a.ad_id END oid,
           count(*) n, count(*) FILTER (WHERE x.known) kn, count(*) FILTER (WHERE x.qualified) q, count(*) FILTER (WHERE x.customer) cu
      FROM public.ads_meta_lead_archive a JOIN crm_private.ads_meta_lead_facts(p_from, p_to) x ON x.archive_id = a.id
     GROUP BY 1)
  SELECT d.oid, o.name, o.status, d.cid, d.sid, d.spend, d.imp, d.clk, d.leads, d.freq,
         coalesce(c.n, 0), coalesce(c.kn, 0), coalesce(c.q, 0), coalesce(c.cu, 0)
    FROM d LEFT JOIN c ON c.oid = d.oid LEFT JOIN public.ads_meta_object o ON o.level = p_level AND o.external_id = d.oid
   WHERE d.oid IS NOT NULL $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_metric(p_metric text, spend numeric, impressions bigint, clicks bigint, leads bigint, qualified bigint, frequency numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_metric WHEN 'spend' THEN spend WHEN 'leads' THEN leads WHEN 'qualified' THEN qualified WHEN 'frequency' THEN frequency
    WHEN 'cpl' THEN CASE WHEN leads > 0 THEN round(spend / leads, 2) END
    WHEN 'cpql' THEN CASE WHEN qualified > 0 THEN round(spend / qualified, 2) END
    WHEN 'ctr' THEN CASE WHEN impressions > 0 THEN round(100.0 * clicks / impressions, 3) END
    WHEN 'cpm' THEN CASE WHEN impressions > 0 THEN round(1000 * spend / impressions, 2) END END $$;

-- ------------------------------------------------------------------------------------------- actions
CREATE OR REPLACE FUNCTION crm_private.ads_meta_action_guard(p_level text, p_kind text, p_params jsonb, p_current numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE g jsonb := '[]'; nd numeric; lo numeric := coalesce(nullif(crm_private.ads_cfg('meta_action_min_daily'), '')::numeric, 100);
        hi numeric := coalesce(nullif(crm_private.ads_cfg('meta_action_max_daily'), '')::numeric, 50000); pct numeric;
BEGIN
  IF p_kind = 'budget' THEN
    IF p_level = 'ad' THEN RAISE EXCEPTION 'Ads have no budget of their own: change the ad set or campaign' USING ERRCODE = 'PT422'; END IF;
    nd := nullif(p_params->>'daily', '')::numeric;
    pct := nullif(p_params->>'pct', '')::numeric;
    IF nd IS NULL AND pct IS NULL THEN RAISE EXCEPTION 'Give a new daily budget' USING ERRCODE = 'PT422'; END IF;
    IF nd IS NOT NULL AND (nd < lo OR nd > hi) THEN RAISE EXCEPTION 'Daily budget must be between ₹% and ₹%', lo, hi USING ERRCODE = 'PT422'; END IF;
    IF pct IS NOT NULL AND (pct < -90 OR pct > 200 OR pct = 0) THEN RAISE EXCEPTION 'Change between -90%% and +200%%' USING ERRCODE = 'PT422'; END IF;
    pct := coalesce(pct, CASE WHEN p_current > 0 THEN round(100 * (nd - p_current) / p_current, 1) END);
    IF pct IS NOT NULL AND pct > 100 AND NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Raising a budget by more than 100%% needs Admin' USING ERRCODE = 'PT403'; END IF;
    IF pct IS NOT NULL AND abs(pct) >= 20 THEN
      g := g || to_jsonb(format('A %s%% change is a big edit: Meta may restart the learning phase for this %s.', round(pct), CASE p_level WHEN 'adset' THEN 'ad set' ELSE p_level END));
    END IF;
  END IF;
  IF p_kind = 'duplicate' THEN g := g || to_jsonb('The copy is created paused; switch it on when ready.'::text); END IF;
  IF crm_private.ads_platform_paused('meta') THEN g := g || to_jsonb('Meta emergency stop is on: it will run only after the stop is lifted.'::text); END IF;
  RETURN g;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_action_add(p_level text, p_object_id text, p_kind text, p_params jsonb, p_reason text,
  p_source text, p_rule bigint, p_test bigint, p_by uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.ads_meta_object; nid bigint;
BEGIN
  IF p_level NOT IN ('campaign', 'adset', 'ad') OR p_object_id !~ '^[0-9]{3,25}$' THEN RAISE EXCEPTION 'Unknown object' USING ERRCODE = 'PT422'; END IF;
  IF p_kind NOT IN ('pause', 'activate', 'budget', 'duplicate') THEN RAISE EXCEPTION 'Unknown action' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO o FROM public.ads_meta_object WHERE level = p_level AND external_id = p_object_id;
  IF EXISTS (SELECT 1 FROM public.ads_meta_action WHERE object_id = p_object_id AND kind = p_kind AND status IN ('pending', 'approved', 'executing')) THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.ads_meta_action (level, object_id, object_name, kind, params, reason, source, rule_id, test_id, guard, requested_by)
  VALUES (p_level, p_object_id, o.name, p_kind, coalesce(p_params, '{}'), left(p_reason, 500), p_source, p_rule, p_test,
          crm_private.ads_meta_action_guard(p_level, p_kind, coalesce(p_params, '{}'), NULL), p_by)
  RETURNING id INTO nid;
  PERFORM crm_private.ads_log('meta_action_requested', 'meta_action', nid::text, jsonb_build_object('kind', p_kind, 'object', p_object_id, 'source', p_source),
    CASE WHEN p_source = 'user' THEN 'user' ELSE 'system' END);
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_action_request(p_level text, p_object_id text, p_kind text, p_params jsonb, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only approvers can ask for changes' USING ERRCODE = 'PT403'; END IF;
  nid := crm_private.ads_meta_action_add(p_level, p_object_id, p_kind, p_params, p_reason, 'user', NULL, NULL, auth.uid());
  IF nid IS NULL THEN RAISE EXCEPTION 'The same change is already waiting for this object' USING ERRCODE = 'PT409'; END IF;
  RETURN jsonb_build_object('id', nid, 'guard', (SELECT guard FROM public.ads_meta_action WHERE id = nid),
    'self_approve', crm_private.ads_cfg('meta_actions_two_person') <> 'true');
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_action_decide(p_id bigint, p_approve boolean, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_meta_action;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only approvers can approve changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO a FROM public.ads_meta_action WHERE id = p_id FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Unknown request' USING ERRCODE = 'PT404'; END IF;
  IF a.status <> 'pending' THEN RAISE EXCEPTION 'This request is already %', a.status USING ERRCODE = 'PT409'; END IF;
  IF a.expires_at < now() THEN
    UPDATE public.ads_meta_action SET status = 'expired' WHERE id = p_id;
    RAISE EXCEPTION 'This request expired; ask again' USING ERRCODE = 'PT409';
  END IF;
  IF p_approve AND crm_private.ads_cfg('meta_actions_two_person') = 'true' AND a.requested_by IS NOT DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Another approver must approve your own request' USING ERRCODE = 'PT403';
  END IF;
  IF p_approve AND a.kind = 'budget' AND coalesce((a.params->>'pct')::numeric, 0) > 100 AND NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Raising a budget by more than 100%% needs Admin' USING ERRCODE = 'PT403';
  END IF;
  UPDATE public.ads_meta_action SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END, approved_by = auth.uid(), decided_at = now(),
    note = left(p_note, 500) WHERE id = p_id;
  PERFORM crm_private.ads_log(CASE WHEN p_approve THEN 'meta_action_approved' ELSE 'meta_action_rejected' END, 'meta_action', p_id::text, '{}');
  RETURN jsonb_build_object('ok', true, 'status', CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_actions(p_days int DEFAULT 14) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object('can_approve', crm_private.ads_can_approve(), 'two_person', crm_private.ads_cfg('meta_actions_two_person') = 'true',
    'paused', crm_private.ads_platform_paused('meta'),
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'level', a.level, 'object_id', a.object_id, 'object_name', a.object_name, 'kind', a.kind,
        'params', a.params, 'reason', a.reason, 'source', a.source, 'rule', r.name, 'status', CASE WHEN a.status = 'pending' AND a.expires_at < now() THEN 'expired' ELSE a.status END,
        'guard', a.guard, 'before', a.before, 'after', a.after, 'error', a.error, 'mine', a.requested_by IS NOT DISTINCT FROM auth.uid(),
        'created_at', a.created_at, 'decided_at', a.decided_at, 'executed_at', a.executed_at)
        ORDER BY (a.status IN ('pending', 'approved', 'executing')) DESC, a.created_at DESC), '[]')
      FROM public.ads_meta_action a LEFT JOIN public.ads_meta_rule r ON r.id = a.rule_id
     WHERE a.status IN ('pending', 'approved', 'executing') OR a.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 14), 90)))));
END $$;

-- Objects with their last-7-day numbers, for the quick-action table.
CREATE OR REPLACE FUNCTION public.api_ads_meta_objects(p_level text, p_days int DEFAULT 7) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := crm_private.ads_meta_today();
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_level NOT IN ('campaign', 'adset', 'ad') THEN RAISE EXCEPTION 'Unknown level' USING ERRCODE = 'PT422'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.external_id, 'name', o.name, 'status', o.status, 'campaign_id', o.campaign_ext, 'adset_id', o.adset_ext,
      'spend', s.spend, 'leads', s.leads, 'cpl', crm_private.ads_meta_metric('cpl', s.spend, s.impressions, s.clicks, s.leads, s.qualified, s.frequency),
      'qualified', s.qualified, 'cpql', crm_private.ads_meta_metric('cpql', s.spend, s.impressions, s.clicks, s.leads, s.qualified, s.frequency),
      'ctr', crm_private.ads_meta_metric('ctr', s.spend, s.impressions, s.clicks, s.leads, s.qualified, s.frequency), 'frequency', s.frequency,
      'open', (SELECT jsonb_agg(a.kind) FROM public.ads_meta_action a WHERE a.object_id = o.external_id AND a.status IN ('pending', 'approved', 'executing')))
      ORDER BY coalesce(s.spend, 0) DESC, o.name), '[]')
    FROM public.ads_meta_object o
    LEFT JOIN crm_private.ads_meta_obj_stats(p_level, today - greatest(1, least(coalesce(p_days, 7), 90)), today - 1) s ON s.object_id = o.external_id
   WHERE o.level = p_level AND o.account_id = (crm_private.ads_meta_acct()).id
     AND (coalesce(o.status, '') NOT IN ('DELETED', 'ARCHIVED') OR s.spend > 0));
END $$;

-- What the action job runs now (service role): approved, not expired; nothing while the Meta stop is on.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_action_work() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); items jsonb;
BEGIN
  UPDATE public.ads_meta_action SET status = 'expired' WHERE status IN ('pending', 'approved') AND expires_at < now();
  IF crm_private.ads_platform_paused('meta') THEN RETURN jsonb_build_object('paused', true, 'items', '[]'::jsonb); END IF;
  WITH x AS (UPDATE public.ads_meta_action SET status = 'executing' WHERE id IN (
               SELECT id FROM public.ads_meta_action WHERE status = 'approved' ORDER BY decided_at LIMIT 20 FOR UPDATE SKIP LOCKED)
             RETURNING id, level, object_id, kind, params)
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id), '[]') INTO items FROM x;
  RETURN jsonb_build_object('paused', false, 'currency', acc.currency, 'account_id', acc.external_id,
    'min_daily', coalesce(nullif(crm_private.ads_cfg('meta_action_min_daily'), '')::numeric, 100),
    'max_daily', coalesce(nullif(crm_private.ads_cfg('meta_action_max_daily'), '')::numeric, 50000), 'items', items);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_action_done(p_id bigint, p_status text, p_before jsonb, p_after jsonb, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.ads_meta_action SET status = CASE WHEN p_status IN ('done', 'failed', 'stale') THEN p_status ELSE 'failed' END,
    before = p_before, after = p_after, error = left(p_error, 600), executed_at = now() WHERE id = p_id AND status = 'executing';
  PERFORM crm_private.ads_log('meta_action_' || CASE WHEN p_status IN ('done', 'failed', 'stale') THEN p_status ELSE 'failed' END, 'meta_action', p_id::text,
    jsonb_build_object('error', left(p_error, 200)), 'system');
END $$;

-- ------------------------------------------------------------------------------------------- rules
CREATE OR REPLACE FUNCTION crm_private.ads_meta_rules_run(p_rule bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_meta_rule; s record; today date := crm_private.ads_meta_today(); v numeric; hit boolean; hits int; made int := 0;
        warned int := 0; checked int := 0; v_kind text; nid bigint; label text;
BEGIN
  FOR r IN SELECT * FROM public.ads_meta_rule WHERE (p_rule IS NULL AND enabled) OR id = p_rule ORDER BY id LOOP
    hits := 0;
    FOR s IN SELECT * FROM crm_private.ads_meta_obj_stats(r.level, today - r.window_days, today - 1) x
              WHERE coalesce(x.status, 'ACTIVE') = 'ACTIVE'
                AND (coalesce(r.name_contains, '') = '' OR position(lower(r.name_contains) IN lower(coalesce(x.name, ''))) > 0) LOOP
      checked := checked + 1;
      CONTINUE WHEN s.spend < r.min_spend OR s.leads < r.min_leads;
      v := crm_private.ads_meta_metric(r.metric, s.spend, s.impressions, s.clicks, s.leads, s.qualified, s.frequency);
      -- a cost with nothing bought yet counts as "above" once the spend alone passes the limit
      hit := CASE WHEN v IS NULL AND r.metric IN ('cpl', 'cpql') THEN r.op = 'gt' AND s.spend > r.value
                  WHEN v IS NULL THEN false
                  WHEN r.op = 'gt' THEN v > r.value ELSE v < r.value END;
      CONTINUE WHEN NOT hit;
      label := format('%s: %s is %s (rule: %s %s %s, last %s days; spend ₹%s, %s leads, %s qualified)', coalesce(s.name, s.object_id), r.metric,
        coalesce(v::text, 'n/a'), r.metric, CASE r.op WHEN 'gt' THEN '>' ELSE '<' END, r.value, r.window_days, round(s.spend), s.leads, s.qualified);
      IF r.action = 'notify' THEN
        INSERT INTO public.ads_meta_warning (kind, entity, severity, title, detail, data)
        VALUES ('rule_' || r.id, s.object_id, 'medium', left(r.name, 200), label, jsonb_build_object('rule', r.id, 'value', v))
        ON CONFLICT (kind, entity) WHERE resolved_at IS NULL DO UPDATE SET last_seen = now(), detail = EXCLUDED.detail;
        warned := warned + 1; hits := hits + 1;
        CONTINUE;
      END IF;
      v_kind := CASE r.action WHEN 'pause' THEN 'pause' ELSE 'budget' END;
      CONTINUE WHEN r.level = 'ad' AND v_kind = 'budget';
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.ads_meta_action a WHERE a.object_id = s.object_id AND a.rule_id = r.id
                             AND a.created_at > now() - make_interval(days => r.cooldown_days));
      nid := crm_private.ads_meta_action_add(r.level, s.object_id, v_kind,
        CASE WHEN v_kind = 'budget' THEN jsonb_build_object('pct', CASE r.action WHEN 'budget_up' THEN r.pct ELSE -r.pct END) ELSE '{}'::jsonb END,
        label, 'rule', r.id, NULL, NULL);
      IF nid IS NOT NULL THEN made := made + 1; hits := hits + 1; END IF;
    END LOOP;
    UPDATE public.ads_meta_rule SET last_run_at = now(), last_hits = hits WHERE id = r.id;
  END LOOP;
  RETURN jsonb_build_object('checked', checked, 'requests', made, 'warnings', warned);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_rules_run() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.ads_meta_rules_run(NULL) $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_rules_run(p_rule bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only approvers can run rules' USING ERRCODE = 'PT403'; END IF;
  RETURN crm_private.ads_meta_rules_run(p_rule);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_rules() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) - 'created_by' ORDER BY r.enabled DESC, r.id), '[]') FROM public.ads_meta_rule r);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_rule_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint := nullif(p->>'id', '')::bigint; act text := p->>'action';
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF coalesce(p->>'delete', '') = 'true' THEN DELETE FROM public.ads_meta_rule WHERE id = rid; RETURN jsonb_build_object('ok', true, 'deleted', rid); END IF;
  IF length(btrim(coalesce(p->>'name', ''))) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'Name: 2-100 characters' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'level', '') NOT IN ('campaign', 'adset', 'ad') THEN RAISE EXCEPTION 'Level: campaign, ad set or ad' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'metric', '') NOT IN ('spend', 'leads', 'cpl', 'cpql', 'qualified', 'ctr', 'frequency', 'cpm') THEN RAISE EXCEPTION 'Unknown metric' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'op', '') NOT IN ('gt', 'lt') THEN RAISE EXCEPTION 'Above or below' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'value', '') !~ '^\d{1,9}(\.\d{1,3})?$' THEN RAISE EXCEPTION 'The limit is a number' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(act, '') NOT IN ('pause', 'budget_up', 'budget_down', 'notify') THEN RAISE EXCEPTION 'Unknown action' USING ERRCODE = 'PT422'; END IF;
  IF act IN ('budget_up', 'budget_down') AND (coalesce(p->>'pct', '') !~ '^\d{1,3}(\.\d+)?$' OR (p->>'pct')::numeric NOT BETWEEN 1 AND 100) THEN
    RAISE EXCEPTION 'Budget rules need a change of 1-100%%' USING ERRCODE = 'PT422'; END IF;
  IF act IN ('budget_up', 'budget_down') AND p->>'level' = 'ad' THEN RAISE EXCEPTION 'Ads have no budget: use ad sets or campaigns' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'window_days', '7') !~ '^\d{1,2}$' OR (coalesce(p->>'window_days', '7'))::int NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'Window: 1-30 days' USING ERRCODE = 'PT422'; END IF;
  IF rid IS NULL THEN
    INSERT INTO public.ads_meta_rule (name, enabled, level, name_contains, metric, window_days, op, value, min_spend, min_leads, action, pct, cooldown_days, created_by)
    VALUES (btrim(p->>'name'), coalesce((p->>'enabled')::boolean, false), p->>'level', nullif(btrim(p->>'name_contains'), ''), p->>'metric',
            coalesce((p->>'window_days')::int, 7), p->>'op', (p->>'value')::numeric, coalesce(nullif(p->>'min_spend', '')::numeric, 0),
            coalesce(nullif(p->>'min_leads', '')::int, 0), act, CASE WHEN act IN ('budget_up', 'budget_down') THEN (p->>'pct')::numeric END,
            coalesce(nullif(p->>'cooldown_days', '')::int, 3), auth.uid())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.ads_meta_rule SET name = btrim(p->>'name'), enabled = coalesce((p->>'enabled')::boolean, enabled), level = p->>'level',
      name_contains = nullif(btrim(p->>'name_contains'), ''), metric = p->>'metric', window_days = coalesce((p->>'window_days')::int, window_days),
      op = p->>'op', value = (p->>'value')::numeric, min_spend = coalesce(nullif(p->>'min_spend', '')::numeric, min_spend),
      min_leads = coalesce(nullif(p->>'min_leads', '')::int, min_leads), action = act,
      pct = CASE WHEN act IN ('budget_up', 'budget_down') THEN (p->>'pct')::numeric END,
      cooldown_days = coalesce(nullif(p->>'cooldown_days', '')::int, cooldown_days), updated_at = now() WHERE id = rid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown rule' USING ERRCODE = 'PT404'; END IF;
  END IF;
  PERFORM crm_private.ads_log('meta_rule_saved', 'meta_rule', rid::text, jsonb_build_object('enabled', p->>'enabled'));
  RETURN jsonb_build_object('ok', true, 'id', rid);
END $$;

-- ------------------------------------------------------------------------------------------- A/B tests
-- Standard normal CDF (Abramowitz and Stegun 7.1.26, error < 1.5e-7).
CREATE OR REPLACE FUNCTION crm_private.ads_norm_cdf(z numeric) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE x float8 := abs(z) / sqrt(2.0); t float8; y float8;
BEGIN
  t := 1.0 / (1.0 + 0.3275911 * x);
  y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
  RETURN CASE WHEN z >= 0 THEN 0.5 * (1 + y) ELSE 0.5 * (1 - y) END;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_test_result(t public.ads_meta_test) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cells jsonb := '[]'; c jsonb; i int := 0; st record; ctl record; z numeric; p numeric; succ_c numeric; succ_t numeric; base_c numeric; base_t numeric;
        to_day date := least(t.end_date, crm_private.ads_meta_today() - 1); enough boolean := true; best int; bestv numeric; lower_better boolean;
BEGIN
  lower_better := t.metric IN ('cost_per_lead', 'cost_per_qualified');
  FOR c IN SELECT * FROM jsonb_array_elements(t.cells) LOOP
    SELECT coalesce(sum(s.spend), 0) spend, coalesce(sum(s.impressions), 0) imp, coalesce(sum(s.clicks), 0) clk, coalesce(sum(s.leads), 0) leads,
           coalesce(sum(s.known), 0) known, coalesce(sum(s.qualified), 0) q
      INTO st FROM crm_private.ads_meta_obj_stats(t.level, t.start_date, to_day) s
     WHERE s.object_id IN (SELECT jsonb_array_elements_text(c->'ids'));
    cells := cells || jsonb_build_object('name', c->>'name', 'ids', c->'ids', 'spend', st.spend, 'impressions', st.imp, 'clicks', st.clk, 'leads', st.leads,
      'known', st.known, 'qualified', st.q,
      'value', CASE t.metric WHEN 'cost_per_lead' THEN CASE WHEN st.leads > 0 THEN round(st.spend / st.leads, 2) END
                             WHEN 'cost_per_qualified' THEN CASE WHEN st.q > 0 THEN round(st.spend / st.q, 2) END
                             WHEN 'qualified_rate' THEN CASE WHEN st.known > 0 THEN round(100.0 * st.q / st.known, 2) END
                             ELSE CASE WHEN st.imp > 0 THEN round(100.0 * st.clk / st.imp, 3) END END,
      'results', CASE t.metric WHEN 'cost_per_lead' THEN st.leads WHEN 'cost_per_qualified' THEN st.q WHEN 'qualified_rate' THEN st.known ELSE st.clk END);
    IF (cells->i->>'results')::numeric < t.min_results THEN enough := false; END IF;
    i := i + 1;
  END LOOP;
  -- each cell against the control (cell 1)
  FOR i IN 1 .. jsonb_array_length(cells) - 1 LOOP
    IF t.metric IN ('cost_per_lead', 'cost_per_qualified') THEN
      -- leads (or qualified) split between the two cells vs their spend split (binomial, normal approximation)
      succ_c := (cells->0->>'results')::numeric; succ_t := (cells->i->>'results')::numeric;
      base_c := (cells->0->>'spend')::numeric; base_t := (cells->i->>'spend')::numeric;
      IF succ_c + succ_t > 0 AND base_c > 0 AND base_t > 0 THEN
        p := base_t / (base_c + base_t);
        z := (succ_t - (succ_c + succ_t) * p) / sqrt((succ_c + succ_t) * p * (1 - p));
      ELSE z := NULL; END IF;
    ELSE
      succ_c := CASE t.metric WHEN 'qualified_rate' THEN (cells->0->>'qualified')::numeric ELSE (cells->0->>'clicks')::numeric END;
      succ_t := CASE t.metric WHEN 'qualified_rate' THEN (cells->i->>'qualified')::numeric ELSE (cells->i->>'clicks')::numeric END;
      base_c := CASE t.metric WHEN 'qualified_rate' THEN (cells->0->>'known')::numeric ELSE (cells->0->>'impressions')::numeric END;
      base_t := CASE t.metric WHEN 'qualified_rate' THEN (cells->i->>'known')::numeric ELSE (cells->i->>'impressions')::numeric END;
      IF base_c > 0 AND base_t > 0 AND succ_c + succ_t > 0 AND succ_c + succ_t < base_c + base_t THEN
        p := (succ_c + succ_t) / (base_c + base_t);
        z := (succ_t / base_t - succ_c / base_c) / sqrt(p * (1 - p) * (1 / base_c + 1 / base_t));
      ELSE z := NULL; END IF;
    END IF;
    cells := jsonb_set(cells, ARRAY[i::text], (cells->i) || jsonb_build_object('z', round(z, 3),
      'confidence', CASE WHEN z IS NOT NULL THEN round(100 * (1 - 2 * (1 - crm_private.ads_norm_cdf(abs(z)))), 1) END,
      'better', CASE WHEN z IS NULL THEN NULL ELSE z > 0 END));   -- more results per rupee / higher rate = better
  END LOOP;
  SELECT n - 1, v INTO best, bestv FROM (SELECT n, (x->>'value')::numeric v FROM jsonb_array_elements(cells) WITH ORDINALITY y(x, n) WHERE x->>'value' IS NOT NULL
     ORDER BY CASE WHEN lower_better THEN (x->>'value')::numeric ELSE -(x->>'value')::numeric END LIMIT 1) z;
  RETURN jsonb_build_object('cells', cells, 'enough', enough, 'to', to_day, 'leader', best,
    'verdict', CASE WHEN NOT enough THEN format('Too early: every cell needs %s+ %s.', t.min_results,
                                         CASE t.metric WHEN 'cost_per_lead' THEN 'leads' WHEN 'cost_per_qualified' THEN 'qualified leads' WHEN 'qualified_rate' THEN 'followed leads' ELSE 'clicks' END)
                    WHEN best IS NULL THEN 'No results yet.'
                    WHEN best = 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(cells) x WHERE (x->>'confidence')::numeric >= 95) THEN 'No clear difference yet (below 95% confidence).'
                    WHEN best = 0 THEN format('%s (control) is ahead with 95%%+ confidence over at least one cell.', cells->0->>'name')
                    WHEN (cells->best->>'confidence')::numeric >= 95 THEN format('%s wins with %s%% confidence.', cells->best->>'name', cells->best->>'confidence')
                    ELSE format('%s is ahead, but only %s%% confident: keep it running.', cells->best->>'name', coalesce(cells->best->>'confidence', '?')) END);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_tests() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(t) - 'created_by' || jsonb_build_object('result', crm_private.ads_meta_test_result(t)) ORDER BY (t.status = 'running') DESC, t.id DESC), '[]')
    FROM public.ads_meta_test t);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_test_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE tid bigint := nullif(p->>'id', '')::bigint; n int; c jsonb; ids text[] := '{}';
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF tid IS NOT NULL THEN
    UPDATE public.ads_meta_test SET status = coalesce(nullif(p->>'status', ''), status), decision = coalesce(p->>'decision', decision), updated_at = now()
     WHERE id = tid AND coalesce(p->>'status', status) IN ('running', 'finished', 'stopped');
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown test' USING ERRCODE = 'PT404'; END IF;
    RETURN jsonb_build_object('ok', true, 'id', tid);
  END IF;
  IF length(btrim(coalesce(p->>'name', ''))) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'Name: 2-100 characters' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'level', '') NOT IN ('campaign', 'adset', 'ad') THEN RAISE EXCEPTION 'Level: campaign, ad set or ad' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p->>'metric', '') NOT IN ('cost_per_lead', 'cost_per_qualified', 'qualified_rate', 'ctr') THEN RAISE EXCEPTION 'Unknown metric' USING ERRCODE = 'PT422'; END IF;
  n := CASE WHEN jsonb_typeof(p->'cells') = 'array' THEN jsonb_array_length(p->'cells') ELSE 0 END;
  IF n NOT BETWEEN 2 AND 5 THEN RAISE EXCEPTION 'A test has 2 to 5 cells' USING ERRCODE = 'PT422'; END IF;
  FOR c IN SELECT * FROM jsonb_array_elements(p->'cells') LOOP
    IF length(btrim(coalesce(c->>'name', ''))) = 0 OR jsonb_typeof(c->'ids') <> 'array' OR jsonb_array_length(c->'ids') = 0 THEN
      RAISE EXCEPTION 'Every cell needs a name and at least one %', replace(p->>'level', 'adset', 'ad set') USING ERRCODE = 'PT422'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(c->'ids') x WHERE x !~ '^[0-9]{3,25}$' OR x = ANY (ids)) THEN
      RAISE EXCEPTION 'An object is in two cells, or is not a Meta id' USING ERRCODE = 'PT422'; END IF;
    ids := ids || ARRAY(SELECT jsonb_array_elements_text(c->'ids'));
  END LOOP;
  IF coalesce(p->>'start_date', '') !~ '^\d{4}-\d{2}-\d{2}$' OR coalesce(p->>'end_date', '') !~ '^\d{4}-\d{2}-\d{2}$'
     OR (p->>'end_date')::date < (p->>'start_date')::date OR (p->>'end_date')::date - (p->>'start_date')::date > 90 THEN
    RAISE EXCEPTION 'Pick start and end dates (up to 90 days)' USING ERRCODE = 'PT422'; END IF;
  IF coalesce((p->>'meta_split')::boolean, false) AND (p->>'level' = 'ad' OR (p->>'start_date')::date < crm_private.ads_meta_today()) THEN
    RAISE EXCEPTION 'A Meta split test compares ad sets or campaigns and starts today or later' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_meta_test (name, hypothesis, variable, level, cells, metric, start_date, end_date, min_results, meta_split, created_by)
  VALUES (btrim(p->>'name'), left(p->>'hypothesis', 500), coalesce(nullif(p->>'variable', ''), 'creative'), p->>'level',
          (SELECT jsonb_agg(jsonb_build_object('name', left(btrim(e->>'name'), 60), 'ids', e->'ids')) FROM jsonb_array_elements(p->'cells') e),
          p->>'metric', (p->>'start_date')::date, (p->>'end_date')::date, coalesce(nullif(p->>'min_results', '')::int, 30),
          coalesce((p->>'meta_split')::boolean, false), auth.uid())
  RETURNING id INTO tid;
  PERFORM crm_private.ads_log('meta_test_created', 'meta_test', tid::text, jsonb_build_object('meta_split', p->>'meta_split'));
  RETURN jsonb_build_object('ok', true, 'id', tid);
END $$;

-- Meta split tests still to create (service role), and where the result goes.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_test_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('account_id', (crm_private.ads_meta_acct()).external_id, 'paused', crm_private.ads_platform_paused('meta'),
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'hypothesis', t.hypothesis, 'level', t.level, 'cells', t.cells,
        'start_date', t.start_date, 'end_date', t.end_date) ORDER BY t.id), '[]')
      FROM public.ads_meta_test t WHERE t.meta_split AND t.meta_study_id IS NULL AND t.status = 'running' AND coalesce(t.meta_detail, '') NOT LIKE 'given up%')) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_test_saved(p_id bigint, p_study text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_test SET meta_study_id = coalesce(substring(p_study FROM '^[0-9]{3,25}$'), meta_study_id), meta_detail = left(p_detail, 600), updated_at = now()
   WHERE id = p_id $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_obj_stats(text, date, date), crm_private.ads_meta_metric(text, numeric, bigint, bigint, bigint, bigint, numeric),
  crm_private.ads_meta_action_guard(text, text, jsonb, numeric), crm_private.ads_meta_action_add(text, text, text, jsonb, text, text, bigint, bigint, uuid),
  crm_private.ads_meta_rules_run(bigint), crm_private.ads_norm_cdf(numeric), crm_private.ads_meta_test_result(public.ads_meta_test) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text), public.api_ads_meta_action_decide(bigint, boolean, text),
  public.api_ads_meta_actions(int), public.api_ads_meta_objects(text, int), public.api_ads_meta_rules_run(bigint), public.api_ads_meta_rules(),
  public.api_ads_meta_rule_save(jsonb), public.api_ads_meta_tests(), public.api_ads_meta_test_save(jsonb),
  public.svc_ads_meta_action_work(), public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_rules_run(),
  public.svc_ads_meta_test_work(), public.svc_ads_meta_test_saved(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text), public.api_ads_meta_action_decide(bigint, boolean, text),
  public.api_ads_meta_actions(int), public.api_ads_meta_objects(text, int), public.api_ads_meta_rules_run(bigint), public.api_ads_meta_rules(),
  public.api_ads_meta_rule_save(jsonb), public.api_ads_meta_tests(), public.api_ads_meta_test_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_work(), public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_rules_run(),
  public.svc_ads_meta_test_work(), public.svc_ads_meta_test_saved(bigint, text, text) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '110')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- Rules every morning at 09:10 IST (requests only, nothing changes in Meta); approved actions and new split tests every 15 min.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-meta-rules', 'crm-ads-meta-actions');
    PERFORM cron.schedule('crm-ads-meta-rules', '40 3 * * *', $job$ SELECT public.svc_ads_meta_rules_run() WHERE (crm_private.ads_meta_acct()).id IS NOT NULL $job$);
    PERFORM cron.schedule('crm-ads-meta-actions', '*/15 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_actions"]}'::jsonb, timeout_milliseconds := 120000)
      WHERE EXISTS (SELECT 1 FROM public.ads_meta_action WHERE status = 'approved')
         OR EXISTS (SELECT 1 FROM public.ads_meta_test WHERE meta_split AND meta_study_id IS NULL AND status = 'running' AND coalesce(meta_detail, '') NOT LIKE 'given up%')
    $job$);
  END IF;
END $$;
