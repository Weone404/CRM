-- 093: ADS only, Google Ads only. Autopilot: spend limits, agent suggestions, instructions to the agents,
-- agent run log, funds added, and the ADS agents' own bridge token. Separate from Amazon (its bridge and token are
-- never used here) and from Meta (untouched).
--
--   ads_config  google_cap_daily / google_cap_monthly   spend limits; budget raises and turning campaigns on are
--                                                       blocked by the evaluator when they would go above them
--               agents_token_sha256                     hash of the ADS agents' token (the token itself is never stored)
--   ads_agent_runs           one row per agent step (researcher, builder, reviewer, allocator, learner, supervisor)
--   ads_autopilot_suggestions  agent proposals the user can accept, change or dismiss; accepting turns them into
--                              ads_google_ops (which still pass the 092 quality gate and Google's own pre-check)
--   ads_agent_instructions   typed or spoken instructions for the agents, with their answer
--   ads_funds                money the user added to the Google Ads account (for the balance estimate)
--
-- Re-runnable. Rollback: 093_ads_autopilot_down.sql.

CREATE TABLE IF NOT EXISTS public.ads_agent_runs (
  id bigserial PRIMARY KEY,
  account_id uuid REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor')),
  job text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed', 'rejected', 'escalated')),
  attempt int NOT NULL DEFAULT 1,
  parent_id bigint REFERENCES public.ads_agent_runs(id) ON DELETE SET NULL,
  instruction_id bigint,
  input jsonb NOT NULL DEFAULT '{}',
  output jsonb,
  summary text,
  error text,
  claimed_at timestamptz, finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_agent_runs_status ON public.ads_agent_runs (status, created_at);
CREATE INDEX IF NOT EXISTS idx_ads_agent_runs_at ON public.ads_agent_runs (created_at DESC);

CREATE TABLE IF NOT EXISTS public.ads_autopilot_suggestions (
  id bigserial PRIMARY KEY,
  account_id uuid REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'other' CHECK (kind IN ('geo', 'keywords', 'negatives', 'ads', 'assets', 'budget', 'tracking', 'other')),
  title text NOT NULL,
  reason text NOT NULL DEFAULT '',
  proposal jsonb NOT NULL DEFAULT '{"ops": []}',   -- {ops: [{kind, payload, summary, option?}], options?: [{id, label, reason}]}
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'changed', 'dismissed', 'superseded')),
  user_note text,
  agent_run_id bigint REFERENCES public.ads_agent_runs(id) ON DELETE SET NULL,
  decided_by uuid, decided_at timestamptz, result jsonb,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_ap_sugg_status ON public.ads_autopilot_suggestions (status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ads_agent_instructions (
  id bigserial PRIMARY KEY,
  account_id uuid REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(body) BETWEEN 2 AND 2000),
  via text NOT NULL DEFAULT 'typed' CHECK (via IN ('typed', 'voice', 'suggestion')),
  suggestion_id bigint REFERENCES public.ads_autopilot_suggestions(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'working', 'answered', 'failed')),
  answer text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), answered_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_ads_agent_instr_status ON public.ads_agent_instructions (status, created_at);

CREATE TABLE IF NOT EXISTS public.ads_funds (
  id bigserial PRIMARY KEY,
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  added_on date NOT NULL,
  note text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_funds_account ON public.ads_funds (account_id, added_on);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ads_agent_runs', 'ads_autopilot_suggestions', 'ads_agent_instructions', 'ads_funds'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

INSERT INTO public.ads_config (key, value) VALUES
  ('google_cap_daily', '200'),      -- today's campaign budget until the user sets a limit
  ('google_cap_monthly', '6080')    -- 200 x 30.4
ON CONFLICT (key) DO NOTHING;
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google' AND value = 'off'
  AND NOT EXISTS (SELECT 1 FROM public.ads_activity_log WHERE action = 'autopilot_saved');   -- fully automatic from day one

-- -------------------------------------------------------------------------------------------
-- Helpers (account day = the Google account's own time zone)
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.ads_google_account() RETURNS public.ads_accounts
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT a.* FROM public.ads_accounts a WHERE a.platform = 'google' AND a.status <> 'disabled'
   ORDER BY (a.status = 'connected') DESC, a.created_at LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_today() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT a.timezone FROM public.ads_accounts a WHERE a.platform = 'google'
    AND a.timezone IS NOT NULL ORDER BY a.created_at LIMIT 1), 'Asia/Kolkata'))::date
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_spend(p_from date, p_to date) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(m.spend), 0) FROM public.ads_metrics_daily m
    JOIN public.ads_campaigns c ON c.id = m.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
   WHERE a.platform = 'google' AND m.day BETWEEN p_from AND p_to
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_month_spend() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_google_spend(date_trunc('month', crm_private.ads_google_today())::date, crm_private.ads_google_today())
$$;

-- Days left in the month, today included.
CREATE OR REPLACE FUNCTION crm_private.ads_google_days_left() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ((date_trunc('month', crm_private.ads_google_today()) + interval '1 month')::date - crm_private.ads_google_today())
$$;

-- -------------------------------------------------------------------------------------------
-- Evaluator from 076, plus the Autopilot spend limits (marked "093").
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.ads_evaluate(p_campaign uuid, p_kind text, p_after jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.ads_campaigns; a public.ads_accounts; cl public.ads_clients; r jsonb;
        blockers jsonb := '[]'; confirms jsonb := '[]'; warnings jsonb := '[]';
        nb numeric; ob numeric; ch numeric; n int; st text; capd numeric; capm numeric; tot numeric; mtd numeric;
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
  -- Autopilot spend limits (093, Google only): total enabled daily budgets stay within the daily limit,
  -- and the month's projected spend within the monthly limit.
  -- Only changes that raise spend are checked; lowering a budget or pausing is always allowed.
  IF a.platform = 'google' AND blockers = '[]'::jsonb
     AND ((p_kind = 'budget' AND c.status = 'ENABLED' AND nb > coalesce(ob, 0)) OR (p_kind = 'status' AND st = 'ENABLED')) THEN
    capd := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
    capm := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
    SELECT coalesce(sum(x.daily_budget), 0) INTO tot FROM public.ads_campaigns x JOIN public.ads_accounts xa ON xa.id = x.account_id
     WHERE xa.platform = 'google' AND x.status = 'ENABLED' AND x.id <> c.id;
    tot := tot + coalesce(CASE WHEN p_kind = 'budget' THEN nb ELSE c.daily_budget END, 0);
    IF capd IS NOT NULL AND tot > capd THEN
      blockers := blockers || jsonb_build_object('code', 'cap_daily', 'severity', 'blocker',
        'message', format('All running Google campaigns would spend up to %s a day, above your daily limit of %s (Autopilot tab).', tot, capd));
    END IF;
    IF capm IS NOT NULL THEN
      mtd := crm_private.ads_google_month_spend();
      IF mtd >= capm THEN
        blockers := blockers || jsonb_build_object('code', 'cap_monthly', 'severity', 'blocker',
          'message', format('This month''s Google spend (%s) has reached your monthly limit of %s.', mtd, capm));
      ELSIF mtd + tot * crm_private.ads_google_days_left() > capm THEN
        blockers := blockers || jsonb_build_object('code', 'cap_monthly', 'severity', 'blocker',
          'message', format('At up to %s a day, this month''s Google spend could reach %s, above your monthly limit of %s.',
            tot, round(mtd + tot * crm_private.ads_google_days_left()), capm));
      END IF;
    END IF;
  END IF;
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN
    warnings := warnings || jsonb_build_object('code', 'paused', 'severity', 'warning',
      'message', 'Emergency stop is on: approved changes wait until it is turned off.');
  END IF;
  RETURN jsonb_build_object('blockers', blockers, 'confirms', confirms, 'warnings', warnings);
END $$;



-- -------------------------------------------------------------------------------------------
-- Browser API
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_ads_autopilot() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; d date; capd numeric; capm numeric; f0 date; added numeric; spent numeric; avg7 numeric;
        est numeric; days numeric; mtd numeric; enabled_total numeric;
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  d := crm_private.ads_google_today();
  capd := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
  capm := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
  mtd := crm_private.ads_google_month_spend();
  avg7 := round(crm_private.ads_google_spend(d - 7, d - 1) / 7, 2);
  SELECT coalesce(sum(c.daily_budget), 0) INTO enabled_total FROM public.ads_campaigns c JOIN public.ads_accounts x ON x.id = c.account_id
   WHERE x.platform = 'google' AND c.status = 'ENABLED';
  SELECT min(added_on), sum(amount) INTO f0, added FROM public.ads_funds WHERE account_id = a.id;
  IF f0 IS NOT NULL THEN
    spent := crm_private.ads_google_spend(f0, d);
    est := added - spent;
    days := CASE WHEN greatest(avg7, coalesce(enabled_total, 0)) > 0 THEN round(est / greatest(avg7, enabled_total), 1) END;
  END IF;
  RETURN jsonb_build_object(
    'mode', coalesce(crm_private.ads_cfg('autopilot_google'), 'off'),
    'stopped', crm_private.ads_cfg('execution_paused') = 'true',
    'can_approve', crm_private.ads_can_approve(), 'is_admin', crm_private.is_admin(),
    'caps', jsonb_build_object('daily', capd, 'monthly', capm),
    'account', CASE WHEN a.id IS NOT NULL THEN jsonb_build_object('id', a.id, 'name', a.name, 'external_id', a.external_id,
      'currency', a.currency, 'status', a.status, 'last_ok_at', a.last_ok_at) END,
    'today', d, 'days_left', crm_private.ads_google_days_left(),
    'spend', jsonb_build_object('today', crm_private.ads_google_spend(d, d), 'yesterday', crm_private.ads_google_spend(d - 1, d - 1),
      'month', mtd, 'avg7', avg7),
    'budgets', jsonb_build_object('enabled_total', enabled_total, 'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'name', c.name, 'daily_budget', c.daily_budget) ORDER BY c.daily_budget DESC NULLS LAST), '[]')
        FROM public.ads_campaigns c JOIN public.ads_accounts x ON x.id = c.account_id WHERE x.platform = 'google' AND c.status = 'ENABLED')),
    'funds', jsonb_build_object('since', f0, 'added', added, 'spent_since', spent, 'estimate', est, 'days_left', days,
      'low', est IS NOT NULL AND (est <= 0 OR (days IS NOT NULL AND days < 3)),
      'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'added_on', added_on, 'note', note)
        ORDER BY added_on DESC, id DESC), '[]') FROM (SELECT * FROM public.ads_funds WHERE account_id = a.id
        ORDER BY added_on DESC, id DESC LIMIT 10) f)),
    'suggestions', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY (s.status = 'open') DESC, s.created_at DESC), '[]') FROM (
      SELECT * FROM public.ads_autopilot_suggestions ORDER BY (status = 'open') DESC, created_at DESC LIMIT 40) s),
    'instructions', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at DESC), '[]') FROM (
      SELECT id, body, via, status, answer, created_at, answered_at FROM public.ads_agent_instructions ORDER BY created_at DESC LIMIT 20) i),
    'runs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'status', r.status,
      'attempt', r.attempt, 'summary', r.summary, 'error', r.error, 'created_at', r.created_at, 'finished_at', r.finished_at)
      ORDER BY r.created_at DESC), '[]') FROM (SELECT * FROM public.ads_agent_runs ORDER BY created_at DESC LIMIT 40) r),
    'ops', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'summary', o.summary, 'status', o.status,
      'by', o.created_by_type, 'error', o.error, 'blockers', o.gate_result->'blockers', 'created_at', o.created_at)
      ORDER BY o.created_at DESC), '[]') FROM (SELECT * FROM public.ads_google_ops ORDER BY created_at DESC LIMIT 40) o));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_autopilot_save(p_mode text, p_daily numeric, p_monthly numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only people who can approve ADS changes can change Autopilot' USING ERRCODE = 'PT403'; END IF;
  IF p_mode NOT IN ('auto', 'off') THEN RAISE EXCEPTION 'Mode is auto or off' USING ERRCODE = 'PT422'; END IF;
  IF p_daily IS NULL OR p_daily < 1 OR p_daily > 1000000 THEN RAISE EXCEPTION 'Enter a daily limit of at least 1' USING ERRCODE = 'PT422'; END IF;
  IF p_monthly IS NULL OR p_monthly < p_daily THEN RAISE EXCEPTION 'The monthly limit cannot be below the daily limit' USING ERRCODE = 'PT422'; END IF;
  IF p_monthly > p_daily * 31 THEN RAISE EXCEPTION 'The monthly limit is more than 31 days at the daily limit; lower it' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('autopilot_google', p_mode), ('google_cap_daily', round(p_daily, 2)::text),
    ('google_cap_monthly', round(p_monthly, 2)::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('autopilot_saved', 'config', 'autopilot_google',
    jsonb_build_object('mode', p_mode, 'daily', p_daily, 'monthly', p_monthly));
  RETURN jsonb_build_object('saved', true);
END $$;

-- Anyone with ADS access can stop everything; only approvers can start it again.
CREATE OR REPLACE FUNCTION public.api_ads_autopilot_stop(p_stop boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT coalesce(p_stop, true) AND NOT crm_private.ads_can_approve() THEN
    RAISE EXCEPTION 'Only people who can approve ADS changes can turn the emergency stop off' USING ERRCODE = 'PT403';
  END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('execution_paused', CASE WHEN coalesce(p_stop, true) THEN 'true' ELSE 'false' END)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('emergency_stop_' || CASE WHEN coalesce(p_stop, true) THEN 'true' ELSE 'false' END, 'config', 'execution_paused', '{}');
  RETURN jsonb_build_object('stopped', coalesce(p_stop, true));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_funds_add(p_amount numeric, p_on date DEFAULT NULL, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; d date := coalesce(p_on, crm_private.ads_google_today()); nid bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  IF a.id IS NULL THEN RAISE EXCEPTION 'Connect the Google Ads account first' USING ERRCODE = 'PT409'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 10000000 THEN RAISE EXCEPTION 'Enter the amount you added' USING ERRCODE = 'PT422'; END IF;
  IF d > crm_private.ads_google_today() OR d < crm_private.ads_google_today() - 366 THEN
    RAISE EXCEPTION 'The date must be within the last year and not in the future' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_funds (account_id, amount, added_on, note, created_by)
  VALUES (a.id, round(p_amount, 2), d, left(p_note, 200), crm_private.current_employee_id()) RETURNING id INTO nid;
  PERFORM crm_private.ads_log('funds_added', 'funds', nid::text, jsonb_build_object('amount', p_amount, 'on', d));
  RETURN jsonb_build_object('id', nid);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_funds_delete(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'You cannot remove funds entries' USING ERRCODE = 'PT403'; END IF;
  DELETE FROM public.ads_funds WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Entry not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('funds_removed', 'funds', p_id::text, '{}');
  RETURN jsonb_build_object('deleted', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_agent_instruct(p_text text, p_via text DEFAULT 'typed') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')); n int; nid bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF length(t) < 2 THEN RAISE EXCEPTION 'Write or say what the agents should do' USING ERRCODE = 'PT422'; END IF;
  IF length(t) > 2000 THEN RAISE EXCEPTION 'Keep it under 2000 characters' USING ERRCODE = 'PT422'; END IF;
  IF p_via NOT IN ('typed', 'voice') THEN RAISE EXCEPTION 'typed or voice' USING ERRCODE = 'PT422'; END IF;
  SELECT count(*) INTO n FROM public.ads_agent_instructions
   WHERE created_by IS NOT DISTINCT FROM crm_private.current_employee_id() AND created_at > now() - interval '24 hours';
  IF n >= 30 THEN RAISE EXCEPTION 'That is 30 instructions in 24 hours; wait for the agents to catch up' USING ERRCODE = 'PT429'; END IF;
  INSERT INTO public.ads_agent_instructions (account_id, body, via, created_by)
  VALUES ((crm_private.ads_google_account()).id, t, p_via, crm_private.current_employee_id()) RETURNING id INTO nid;
  PERFORM crm_private.ads_log('agent_instructed', 'instruction', nid::text, jsonb_build_object('via', p_via));
  RETURN jsonb_build_object('id', nid, 'status', 'new');
END $$;

-- accept: the proposal's operations (only the picked options, when it has options) become Google operations.
--         They still pass the quality gate; approvers' accepts are approved at once, others wait for an approver.
-- change: the note goes to the agents as an instruction; the suggestion is closed as "changed".
-- dismiss: closed.
CREATE OR REPLACE FUNCTION public.api_ads_suggestion_decide(p_id bigint, p_action text, p_note text DEFAULT NULL,
  p_pick text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_autopilot_suggestions; op jsonb; o public.ads_google_ops; res jsonb := '[]'; me uuid := crm_private.current_employee_id();
        appr boolean := crm_private.ads_can_approve(); nid bigint; acc uuid;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_action NOT IN ('accept', 'change', 'dismiss') THEN RAISE EXCEPTION 'accept, change or dismiss' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO s FROM public.ads_autopilot_suggestions WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Suggestion not found' USING ERRCODE = 'PT404'; END IF;
  IF s.status <> 'open' THEN RAISE EXCEPTION 'This suggestion is already %', s.status USING ERRCODE = 'PT409'; END IF;

  IF p_action = 'change' THEN
    IF length(btrim(coalesce(p_note, ''))) < 2 THEN RAISE EXCEPTION 'Say what to change' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.ads_agent_instructions (account_id, body, via, suggestion_id, created_by)
    VALUES (s.account_id, left(format('Change suggestion "%s": %s', s.title, btrim(p_note)), 2000), 'suggestion', s.id, me) RETURNING id INTO nid;
    res := jsonb_build_object('instruction_id', nid);
  ELSIF p_action = 'accept' THEN
    acc := coalesce(s.account_id, (crm_private.ads_google_account()).id);
    IF acc IS NULL THEN RAISE EXCEPTION 'Connect the Google Ads account first' USING ERRCODE = 'PT409'; END IF;
    IF p_pick IS NOT NULL AND cardinality(p_pick) = 0 AND jsonb_array_length(coalesce(s.proposal->'ops', '[]')) > 0 THEN
      RAISE EXCEPTION 'Pick at least one option' USING ERRCODE = 'PT422';
    END IF;
    FOR op IN SELECT x FROM jsonb_array_elements(coalesce(s.proposal->'ops', '[]')) x LOOP
      IF op ? 'option' AND p_pick IS NOT NULL AND NOT (op->>'option' = ANY (p_pick)) THEN CONTINUE; END IF;
      INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, created_by_type, created_by, agent_run_id)
      VALUES (acc, op->>'kind', coalesce(op->'payload', '{}'), left(coalesce(op->>'summary', s.title), 300), left(s.reason, 1000),
              'agent', me, s.agent_run_id) RETURNING * INTO o;
      IF appr AND o.status = 'pending' THEN
        UPDATE public.ads_google_ops SET status = 'approved', approved_by = me, approved_at = now() WHERE id = o.id RETURNING * INTO o;
      END IF;
      res := res || jsonb_build_object('id', o.id, 'kind', o.kind, 'status', o.status, 'blockers', o.gate_result->'blockers');
    END LOOP;
    res := jsonb_build_object('ops', res);
  END IF;
  UPDATE public.ads_autopilot_suggestions SET status = CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'change' THEN 'changed' ELSE 'dismissed' END,
    user_note = left(p_note, 1000), decided_by = me, decided_at = now(), result = res WHERE id = p_id;
  PERFORM crm_private.ads_log('suggestion_' || p_action, 'suggestion', p_id::text, res);
  RETURN res || jsonb_build_object('status', CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'change' THEN 'changed' ELSE 'dismissed' END);
END $$;

-- New token for the ADS agents' Mac helper. Returned once; only its SHA-256 is kept.
CREATE OR REPLACE FUNCTION public.api_ads_agents_token_rotate() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE tok text := 'adsag_' || encode(extensions.gen_random_bytes(24), 'hex');
BEGIN
  PERFORM crm_private.ads_require_admin();
  INSERT INTO public.ads_config (key, value) VALUES ('agents_token_sha256', encode(extensions.digest(tok, 'sha256'), 'hex'))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('agents_token_rotated', 'config', 'agents_token_sha256', '{}');
  RETURN jsonb_build_object('token', tok);
END $$;

-- -------------------------------------------------------------------------------------------
-- Service side (the ads-agents Edge Function checks the token with this, then uses service_role)
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.svc_ads_agents_token_ok(p_token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(length(p_token) >= 30 AND crm_private.ads_cfg('agents_token_sha256') = encode(extensions.digest(p_token, 'sha256'), 'hex'), false)
$$;

REVOKE ALL ON FUNCTION public.svc_ads_agents_token_ok(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_agents_token_ok(text) TO service_role;
REVOKE ALL ON FUNCTION public.api_ads_autopilot(), public.api_ads_autopilot_save(text, numeric, numeric), public.api_ads_autopilot_stop(boolean),
  public.api_ads_funds_add(numeric, date, text), public.api_ads_funds_delete(bigint), public.api_ads_agent_instruct(text, text),
  public.api_ads_suggestion_decide(bigint, text, text, text[]), public.api_ads_agents_token_rotate() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_autopilot(), public.api_ads_autopilot_save(text, numeric, numeric), public.api_ads_autopilot_stop(boolean),
  public.api_ads_funds_add(numeric, date, text), public.api_ads_funds_delete(bigint), public.api_ads_agent_instruct(text, text),
  public.api_ads_suggestion_decide(bigint, text, text, text[]), public.api_ads_agents_token_rotate() TO authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_google_account(), crm_private.ads_google_today(), crm_private.ads_google_spend(date, date),
  crm_private.ads_google_month_spend(), crm_private.ads_google_days_left() FROM PUBLIC, anon, authenticated;
