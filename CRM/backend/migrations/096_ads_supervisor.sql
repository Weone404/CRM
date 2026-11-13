-- 096: ADS only, Google only. Stage 4 of Autopilot: Supervisor, Budget allocator, Learner, daily report.
--
--   svc_ads_supervise()      every 15 min, plain SQL (no AI). Enforces the spend limits even against changes made directly in
--                            Google Ads: total running budgets above the daily limit -> the biggest budget is lowered; the month's
--                            spend at the monthly limit -> running campaigns are paused. Changes go through the normal queue
--                            (checked, sent, read back). Runs in every Autopilot mode: the limits are the owner's.
--   svc_ads_allocate()       daily, plain SQL, Automatic mode only. Moves budget towards what brings CRM leads at or below the
--                            client's target cost per lead, within the limits: +15% when Google says the budget limits a
--                            campaign that hits the target; -20% when a campaign spends 3x the target cost per lead with poor results.
--   svc_ads_daily_report()   daily 09:05 IST: yesterday's numbers, what changed, what needs the owner.
--   svc_ads_agents_learn()   weekly: queues the Learner (AI) with the past month's decisions and outcomes; its lessons become
--                            the playbook every agent reads (ads_playbook).
-- Also fixes the execute schedule: approved agent / Google operations (ads_google_ops) now wake the executor too.
-- Re-runnable. Rollback: 096_ads_supervisor_down.sql.

CREATE TABLE IF NOT EXISTS public.ads_playbook (
  id bigserial PRIMARY KEY,
  lesson text NOT NULL CHECK (length(lesson) BETWEEN 3 AND 500),
  evidence text,
  active boolean NOT NULL DEFAULT true,
  agent_run_id bigint REFERENCES public.ads_agent_runs(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_playbook ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_playbook FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('agents_allocator', 'on') ON CONFLICT (key) DO NOTHING;

-- System change to one campaign through the normal queue. Returns NULL when queued, else the reason it was not.
CREATE OR REPLACE FUNCTION crm_private.ads_system_change(p_campaign uuid, p_kind text, p_after jsonb, p_summary text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ads_change_queue WHERE campaign_id = p_campaign AND created_by_type = 'system'
               AND status IN ('pending', 'approved', 'executing', 'outcome_unknown') ) THEN
    RETURN 'a system change for this campaign is already on its way';
  END IF;
  INSERT INTO public.ads_change_queue (campaign_id, kind, after, summary, status, second_confirmed, created_by_type, approved_at)
  VALUES (p_campaign, p_kind, p_after, left(p_summary, 300), 'approved', true, 'system', now());
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_agent_note(p_role text, p_job text, p_summary text, p_output jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_agent_runs (account_id, role, job, status, summary, output, finished_at)
  VALUES ((crm_private.ads_google_account()).id, p_role, p_job, 'done', left(p_summary, 500), p_output, now());
  INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('agent', p_role || '_' || p_job, 'agent_run', NULL, jsonb_build_object('summary', left(p_summary, 300)));
$$;

-- -------------------------------------------------------------------------------------------
-- Supervisor
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.svc_ads_supervise() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE capd numeric := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
        capm numeric := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
        tot numeric; mtd numeric; c record; why text; acts jsonb := '[]'; excess numeric; nb numeric;
BEGIN
  IF (crm_private.ads_google_account()).id IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  mtd := crm_private.ads_google_month_spend();
  -- 1. month's spend reached the monthly limit: pause everything that is running
  IF capm IS NOT NULL AND mtd >= capm THEN
    FOR c IN SELECT x.* FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
              WHERE a.platform = 'google' AND x.status = 'ENABLED' LOOP
      why := crm_private.ads_system_change(c.id, 'status', '{"status": "PAUSED"}',
        format('Supervisor: month''s spend %s reached the monthly limit %s; pausing "%s"', mtd, capm, c.name));
      acts := acts || jsonb_build_object('campaign', c.name, 'action', 'pause', 'problem', why);
    END LOOP;
  -- 2. running budgets above the daily limit (e.g. raised directly in Google Ads): lower the biggest one
  ELSIF capd IS NOT NULL THEN
    SELECT coalesce(sum(x.daily_budget), 0) INTO tot FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
     WHERE a.platform = 'google' AND x.status = 'ENABLED';
    IF tot > capd THEN
      excess := tot - capd;
      SELECT x.* INTO c FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
       WHERE a.platform = 'google' AND x.status = 'ENABLED' AND x.budget_ref IS NOT NULL AND x.daily_budget > 0
       ORDER BY x.daily_budget DESC LIMIT 1;
      IF c.id IS NOT NULL THEN
        nb := greatest(round(c.daily_budget - excess, 2), 1);
        why := crm_private.ads_system_change(c.id, 'budget', jsonb_build_object('daily_budget', nb),
          format('Supervisor: running budgets total %s, above the daily limit %s; lowering "%s" from %s to %s', tot, capd, c.name, c.daily_budget, nb));
        acts := acts || jsonb_build_object('campaign', c.name, 'action', 'lower_budget', 'from', c.daily_budget, 'to', nb, 'problem', why);
      ELSE
        acts := acts || jsonb_build_object('action', 'none', 'problem', 'Budgets are above the daily limit but none can be changed from here (shared budgets)');
      END IF;
    END IF;
  END IF;
  IF jsonb_array_length(acts) > 0 THEN
    PERFORM crm_private.ads_agent_note('supervisor', 'limits', format('Supervisor kept spend within your limits: %s',
      (SELECT string_agg(coalesce(a->>'campaign', '') || ' ' || (a->>'action') || coalesce(' (not done: ' || (a->>'problem') || ')', ''), '; ')
         FROM jsonb_array_elements(acts) a)), jsonb_build_object('actions', acts, 'month_spend', mtd));
  END IF;
  RETURN jsonb_build_object('actions', acts);
END $$;

-- -------------------------------------------------------------------------------------------
-- Budget allocator
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.svc_ads_allocate() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE capd numeric := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric; c record; d date := crm_private.ads_google_today();
        spend numeric; leads int; cpl numeric; tgt numeric; tot numeric; nb numeric; why text; acts jsonb := '[]';
BEGIN
  IF crm_private.ads_cfg('autopilot_google') <> 'auto' OR crm_private.ads_cfg('agents_allocator') <> 'on' THEN
    RETURN jsonb_build_object('skipped', 'Autopilot is not Automatic');
  END IF;
  FOR c IN SELECT x.*, cl.target_cpl FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
             JOIN public.ads_clients cl ON cl.id = a.client_id
            WHERE a.platform = 'google' AND x.status = 'ENABLED' AND x.budget_ref IS NOT NULL AND x.daily_budget > 0 LOOP
    tgt := c.target_cpl;
    IF tgt IS NULL OR tgt <= 0 OR c.utm_campaign IS NULL THEN CONTINUE; END IF;   -- no target or no way to count leads: do nothing
    SELECT coalesce(sum(m.spend), 0) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d - 14 AND d - 1;
    SELECT count(*) INTO leads FROM public.lead l WHERE lower(l.utm_campaign) = lower(c.utm_campaign)
       AND l.created_at >= (d - 14)::timestamptz AND l.created_at < d::timestamptz;
    cpl := CASE WHEN leads > 0 THEN round(spend / leads, 2) END;
    SELECT coalesce(sum(x.daily_budget), 0) INTO tot FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
     WHERE a.platform = 'google' AND x.status = 'ENABLED';
    IF leads >= 3 AND cpl <= tgt AND coalesce(c.raw->'primary_status_reasons', '[]') ? 'BUDGET_CONSTRAINED' THEN
      nb := round(c.daily_budget * 1.15, 2);
      IF capd IS NOT NULL THEN nb := least(nb, c.daily_budget + greatest(capd - tot, 0)); END IF;
      IF nb > c.daily_budget THEN
        why := crm_private.ads_system_change(c.id, 'budget', jsonb_build_object('daily_budget', nb),
          format('Allocator: "%s" brought %s CRM leads at %s each (target %s) and Google says the budget limits it; %s -> %s', c.name, leads, cpl, tgt, c.daily_budget, nb));
        acts := acts || jsonb_build_object('campaign', c.name, 'action', 'raise', 'from', c.daily_budget, 'to', nb, 'leads', leads, 'cpl', cpl, 'problem', why);
      END IF;
    ELSIF spend >= 3 * tgt AND (leads = 0 OR cpl > 1.5 * tgt) THEN
      nb := greatest(round(c.daily_budget * 0.8, 2), 1);
      why := crm_private.ads_system_change(c.id, 'budget', jsonb_build_object('daily_budget', nb),
        format('Allocator: "%s" spent %s in 14 days for %s CRM leads (target %s each); %s -> %s', c.name, spend, leads, tgt, c.daily_budget, nb));
      acts := acts || jsonb_build_object('campaign', c.name, 'action', 'lower', 'from', c.daily_budget, 'to', nb, 'leads', leads, 'spend', spend, 'problem', why);
    END IF;
  END LOOP;
  IF jsonb_array_length(acts) > 0 THEN
    PERFORM crm_private.ads_agent_note('allocator', 'daily', format('Budget allocator: %s',
      (SELECT string_agg((a->>'campaign') || ' ' || (a->>'from') || ' -> ' || (a->>'to') || coalesce(' (not done: ' || (a->>'problem') || ')', ''), '; ')
         FROM jsonb_array_elements(acts) a)), jsonb_build_object('actions', acts));
  END IF;
  RETURN jsonb_build_object('actions', acts);
END $$;

-- -------------------------------------------------------------------------------------------
-- Daily report
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.ads_report_data(p_day date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH g AS (SELECT x.* FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id WHERE a.platform = 'google'),
       m AS (SELECT sum(md.spend) spend, sum(md.clicks) clicks, sum(md.impressions) impressions, sum(md.conversions) conv
               FROM public.ads_metrics_daily md JOIN g ON g.id = md.campaign_id WHERE md.day = p_day)
  SELECT jsonb_build_object(
    'day', p_day,
    'spend', (SELECT spend FROM m), 'clicks', (SELECT clicks FROM m), 'impressions', (SELECT impressions FROM m),
    'platform_conversions', (SELECT conv FROM m),
    'crm_leads', (SELECT count(*) FROM public.lead l WHERE l.utm_campaign IS NOT NULL
        AND lower(l.utm_campaign) IN (SELECT lower(utm_campaign) FROM g WHERE utm_campaign IS NOT NULL)
        AND l.created_at >= p_day::timestamptz AND l.created_at < (p_day + 1)::timestamptz),
    'month_spend', crm_private.ads_google_month_spend(),
    'limits', jsonb_build_object('daily', nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric,
                                 'monthly', nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric),
    'changes_live', (SELECT count(*) FROM public.ads_google_ops WHERE status = 'verified' AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz)
                  + (SELECT count(*) FROM public.ads_change_queue WHERE status = 'verified' AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz),
    'changes_failed', (SELECT count(*) FROM public.ads_google_ops WHERE status IN ('failed', 'outcome_unknown') AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz),
    'reviewer_stopped', (SELECT count(*) FROM public.ads_agent_runs WHERE role = 'reviewer' AND status IN ('rejected', 'escalated')
                           AND created_at >= p_day::timestamptz AND created_at < (p_day + 1)::timestamptz),
    'open_suggestions', (SELECT count(*) FROM public.ads_autopilot_suggestions WHERE status = 'open'),
    'waiting_approval', (SELECT count(*) FROM public.ads_google_ops WHERE status = 'pending'),
    'not_serving', (SELECT coalesce(jsonb_agg(jsonb_build_object('campaign', name, 'status', raw->>'primary_status', 'reasons', raw->'primary_status_reasons')), '[]')
                      FROM g WHERE status = 'ENABLED' AND raw->>'primary_status' IN ('NOT_ELIGIBLE', 'LIMITED', 'MISCONFIGURED', 'PENDING')),
    'account_status', (crm_private.ads_google_account()).status,
    'agents_last_seen', crm_private.ads_cfg('agents_last_seen'))
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_daily_report() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; d date := crm_private.ads_google_today() - 1; lines text[] := '{}'; ns jsonb;
BEGIN
  IF (crm_private.ads_google_account()).id IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  IF EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'supervisor' AND job = 'daily_report' AND output->>'day' = d::text) THEN
    RETURN jsonb_build_object('skipped', 'already done');
  END IF;
  r := crm_private.ads_report_data(d);
  lines := lines || format('%s: spent %s, %s clicks, %s CRM leads%s.', to_char(d, 'DD Mon'), coalesce(r->>'spend', '0'), coalesce(r->>'clicks', '0'),
    r->>'crm_leads', CASE WHEN (r->>'crm_leads')::int > 0 AND coalesce((r->>'spend')::numeric, 0) > 0
      THEN format(' (%s per lead)', round((r->>'spend')::numeric / (r->>'crm_leads')::int)) ELSE '' END);
  lines := lines || format('This month %s of %s.', r->>'month_spend', coalesce(r->'limits'->>'monthly', 'no limit'));
  IF (r->>'changes_live')::int + (r->>'changes_failed')::int > 0 THEN
    lines := lines || format('%s change(s) went live, %s failed.', r->>'changes_live', r->>'changes_failed');
  END IF;
  IF (r->>'open_suggestions')::int > 0 THEN lines := lines || format('%s suggestion(s) wait for you.', r->>'open_suggestions'); END IF;
  IF (r->>'waiting_approval')::int > 0 THEN lines := lines || format('%s change(s) wait in Approvals.', r->>'waiting_approval'); END IF;
  FOR ns IN SELECT v FROM jsonb_array_elements(r->'not_serving') v LOOP
    lines := lines || format('"%s" is %s (%s).', ns->>'campaign', lower(ns->>'status'),
      lower(replace(array_to_string(ARRAY(SELECT jsonb_array_elements_text(ns->'reasons')), ', '), '_', ' ')));
  END LOOP;
  IF r->>'account_status' <> 'connected' THEN lines := lines || format('Google Ads connection: %s. Fix it in Settings.', replace(r->>'account_status', '_', ' ')); END IF;
  IF r->>'agents_last_seen' IS NULL OR (r->>'agents_last_seen')::timestamptz < now() - interval '2 hours' THEN
    lines := lines || 'The agents helper on the Mac has not checked in for over 2 hours.'::text;
  END IF;
  PERFORM crm_private.ads_agent_note('supervisor', 'daily_report', array_to_string(lines, ' '), r);
  RETURN r;
END $$;

-- -------------------------------------------------------------------------------------------
-- Learner (AI, weekly) and the playbook
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.svc_ads_agents_learn() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc uuid := (crm_private.ads_google_account()).id; nid bigint;
BEGIN
  IF acc IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  IF EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'learner' AND created_at > now() - interval '6 days') THEN
    RETURN jsonb_build_object('skipped', 'learned this week');
  END IF;
  INSERT INTO public.ads_agent_runs (account_id, role, job, input) VALUES (acc, 'learner', 'weekly_learning', jsonb_build_object(
    'title', 'Weekly learning',
    'current_playbook', (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', lesson, 'evidence', evidence)), '[]') FROM public.ads_playbook WHERE active),
    'reviewer_rejections', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', created_at, 'problems', output->'problems')), '[]') FROM (
       SELECT * FROM public.ads_agent_runs WHERE role = 'reviewer' AND status IN ('rejected', 'escalated') AND created_at > now() - interval '30 days'
        ORDER BY created_at DESC LIMIT 20) x),
    'code_check_rejections', (SELECT coalesce(jsonb_agg(summary), '[]') FROM (
       SELECT summary FROM public.ads_agent_runs WHERE role = 'builder' AND status IN ('rejected', 'escalated') AND created_at > now() - interval '30 days'
        ORDER BY created_at DESC LIMIT 20) x),
    'owner_decisions', (SELECT coalesce(jsonb_agg(jsonb_build_object('title', title, 'decision', status, 'note', user_note)), '[]') FROM (
       SELECT * FROM public.ads_autopilot_suggestions WHERE status <> 'open' AND decided_at > now() - interval '30 days' ORDER BY decided_at DESC LIMIT 30) x),
    'owner_instructions', (SELECT coalesce(jsonb_agg(jsonb_build_object('text', body, 'status', status)), '[]') FROM (
       SELECT * FROM public.ads_agent_instructions WHERE created_at > now() - interval '30 days' ORDER BY created_at DESC LIMIT 30) x),
    'changes', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'summary', summary, 'status', status, 'error', left(error, 200), 'at', created_at)), '[]') FROM (
       SELECT * FROM public.ads_google_ops WHERE created_at > now() - interval '30 days' ORDER BY created_at DESC LIMIT 60) x),
    'daily_reports', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', output->>'day', 'report', summary) ORDER BY created_at), '[]') FROM (
       SELECT * FROM public.ads_agent_runs WHERE role = 'supervisor' AND job = 'daily_report' AND created_at > now() - interval '30 days') x)))
  RETURNING id INTO nid;
  RETURN jsonb_build_object('queued', nid);
END $$;

-- When the Learner finishes, its lessons replace the playbook (max 15, each with evidence).
CREATE OR REPLACE FUNCTION crm_private.ads_learner_done() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x jsonb; n int := 0;
BEGIN
  IF NEW.role = 'learner' AND NEW.status = 'done' AND OLD.status IS DISTINCT FROM 'done'
     AND jsonb_typeof(NEW.output->'playbook') = 'array' AND jsonb_array_length(NEW.output->'playbook') > 0 THEN
    UPDATE public.ads_playbook SET active = false WHERE active;
    FOR x IN SELECT v FROM jsonb_array_elements(NEW.output->'playbook') v LOOP
      CONTINUE WHEN jsonb_typeof(x) <> 'object' OR length(btrim(coalesce(x->>'lesson', ''))) < 3;
      n := n + 1; EXIT WHEN n > 15;
      INSERT INTO public.ads_playbook (lesson, evidence, agent_run_id) VALUES (left(btrim(x->>'lesson'), 500), left(x->>'evidence', 1000), NEW.id);
    END LOOP;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_learner_done ON public.ads_agent_runs;
CREATE TRIGGER trg_ads_learner_done AFTER UPDATE ON public.ads_agent_runs FOR EACH ROW EXECUTE FUNCTION crm_private.ads_learner_done();

-- Every agent step now also reads the playbook.
CREATE OR REPLACE FUNCTION public.svc_ads_agent_next() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs;
BEGIN
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.ads_agent_runs WHERE status = 'queued' ORDER BY created_at, id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_agent_runs SET status = 'running', claimed_at = now(), claims = claims + 1 WHERE id = r.id RETURNING * INTO r;
  IF r.instruction_id IS NOT NULL THEN
    UPDATE public.ads_agent_instructions SET status = 'working' WHERE id = r.instruction_id AND status = 'new';
  END IF;
  RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'attempt', r.attempt, 'input', r.input),
    'context', crm_private.ads_agent_context(r) || jsonb_build_object('playbook',
      (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', p.lesson, 'evidence', p.evidence) ORDER BY p.id), '[]') FROM public.ads_playbook p WHERE p.active)));
END $$;

-- -------------------------------------------------------------------------------------------
-- For the Autopilot tab: agents online, today's report, the playbook
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_ads_autopilot_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz := nullif(crm_private.ads_cfg('agents_last_seen'), '')::timestamptz; busy public.ads_agent_runs;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO busy FROM public.ads_agent_runs WHERE status = 'running' AND claimed_at > now() - interval '30 minutes' ORDER BY claimed_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'agents', jsonb_build_object('last_seen', seen,
      'online', busy.id IS NOT NULL OR (seen IS NOT NULL AND seen > now() - interval '3 minutes'),
      'working_on', CASE WHEN busy.id IS NOT NULL THEN jsonb_build_object('role', busy.role, 'job', busy.job, 'since', busy.claimed_at) END,
      'queued', (SELECT count(*) FROM public.ads_agent_runs WHERE status = 'queued')),
    'report', (SELECT jsonb_build_object('text', summary, 'data', output, 'at', created_at) FROM public.ads_agent_runs
                WHERE role = 'supervisor' AND job = 'daily_report' ORDER BY created_at DESC LIMIT 1),
    'playbook', (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', lesson, 'evidence', evidence) ORDER BY id), '[]') FROM public.ads_playbook WHERE active));
END $$;

REVOKE ALL ON FUNCTION public.svc_ads_supervise(), public.svc_ads_allocate(), public.svc_ads_daily_report(), public.svc_ads_agents_learn(),
  public.svc_ads_agent_next() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_supervise(), public.svc_ads_allocate(), public.svc_ads_daily_report(), public.svc_ads_agents_learn(),
  public.svc_ads_agent_next() TO service_role;
REVOKE ALL ON FUNCTION public.api_ads_autopilot_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_autopilot_status() TO authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_system_change(uuid, text, jsonb, text), crm_private.ads_agent_note(text, text, text, jsonb),
  crm_private.ads_report_data(date), crm_private.ads_learner_done() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-supervise', 'crm-ads-allocate', 'crm-ads-report', 'crm-ads-learn');
    PERFORM cron.schedule('crm-ads-supervise', '7,22,37,52 * * * *', 'SELECT public.svc_ads_supervise()');
    PERFORM cron.schedule('crm-ads-allocate', '10 1 * * *', 'SELECT public.svc_ads_allocate()');          -- 06:40 IST, after the night sync
    PERFORM cron.schedule('crm-ads-report', '35 3 * * *', 'SELECT public.svc_ads_daily_report()');       -- 09:05 IST
    PERFORM cron.schedule('crm-ads-learn', '20 4 * * 1', 'SELECT public.svc_ads_agents_learn()');        -- Monday 09:50 IST
    -- the executor now also wakes for approved Google operations (agent changes), not only budget/status changes
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-execute';
    PERFORM cron.schedule('crm-ads-execute', '*/5 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["execute"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE EXISTS (SELECT 1 FROM public.ads_change_queue WHERE status IN ('approved', 'outcome_unknown')
                     OR (status = 'executing' AND executed_at < now() - interval '10 minutes'))
         OR EXISTS (SELECT 1 FROM public.ads_google_ops WHERE status = 'approved'
                     OR (status = 'executing' AND executed_at < now() - interval '10 minutes'))
    $job$);
  END IF;
END $$;
