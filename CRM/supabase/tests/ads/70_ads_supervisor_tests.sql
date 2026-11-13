-- Stage 4 (096): Supervisor, Budget allocator, daily report, Learner + playbook. Runs after 10_-60_.
RESET ROLE;
DELETE FROM public.ads_agent_runs; DELETE FROM public.ads_change_queue;
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '40000' WHERE key = 'google_cap_monthly';
DELETE FROM public.ads_metrics_daily WHERE day >= date_trunc('month', crm_private.ads_google_today())::date;
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 1000, budget_ref = 'customers/1112223333/campaignBudgets/9', utm_campaign = 'woa_search',
  raw = raw || '{"primary_status_reasons": []}' WHERE external_id = 'g1';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id IN ('g2', 'x1');
UPDATE public.ads_campaigns SET status = 'ENABLED' WHERE external_id = 'm1';
CREATE OR REPLACE FUNCTION pg_temp.cq(p_ext text) RETURNS SETOF public.ads_change_queue LANGUAGE sql SECURITY DEFINER AS $$
  SELECT q.* FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id WHERE c.external_id = p_ext ORDER BY q.created_at $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- Supervisor
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_supervise()->'actions') = 0, 'S01 within the limits: the Supervisor does nothing');
RESET ROLE;
UPDATE public.ads_campaigns SET daily_budget = 2500 WHERE external_id = 'g1';     -- someone raised it directly in Google Ads
SET ROLE service_role;
SELECT public.svc_ads_supervise();
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.cq('g1')) = 1 AND (SELECT (after->>'daily_budget')::numeric = 1500 AND status = 'approved' AND created_by_type = 'system'
  FROM pg_temp.cq('g1')), 'S02 a budget raised directly in Google Ads above the limit is pulled back to the limit');
SET ROLE service_role; SELECT public.svc_ads_supervise(); RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.cq('g1')) = 1, 'S03 running again does not queue the same fix twice');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'supervisor' AND job = 'limits' AND summary LIKE '%lower_budget%'),
  'S04 what the Supervisor did shows in Activity');
DELETE FROM public.ads_change_queue;
UPDATE public.ads_campaigns SET daily_budget = 1000 WHERE external_id = 'g1';
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend) VALUES ((SELECT id FROM public.ads_campaigns WHERE external_id = 'g1'), crm_private.ads_google_today(), 40000);
SET ROLE service_role; SELECT public.svc_ads_supervise(); RESET ROLE;
SELECT pg_temp.ok((SELECT after->>'status' FROM pg_temp.cq('g1')) = 'PAUSED' AND NOT EXISTS (SELECT 1 FROM pg_temp.cq('m1')),
  'S05 monthly limit reached: Google campaigns are paused (Meta is not touched)');
DELETE FROM public.ads_change_queue; DELETE FROM public.ads_metrics_daily WHERE day = crm_private.ads_google_today();
UPDATE public.ads_config SET value = 'off' WHERE key = 'autopilot_google';
UPDATE public.ads_campaigns SET daily_budget = 2500 WHERE external_id = 'g1';
SET ROLE service_role; SELECT public.svc_ads_supervise(); RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.cq('g1')) = 1, 'S06 the limits are enforced even when Autopilot is "Ask me"');
DELETE FROM public.ads_change_queue; UPDATE public.ads_campaigns SET daily_budget = 1000 WHERE external_id = 'g1';

-- ---------------------------------------------------------------- Budget allocator
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_allocate()->>'skipped' LIKE '%not Automatic%', 'S07 the allocator only moves money in Automatic mode');
RESET ROLE;
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend)
SELECT (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1'), crm_private.ads_google_today() - g, 100 FROM generate_series(1, 10) g
ON CONFLICT (campaign_id, day) DO UPDATE SET spend = 100;
DELETE FROM public.ads_metrics_daily WHERE day < crm_private.ads_google_today() - 10;
DELETE FROM public.lead WHERE name LIKE 'Alloc%';
INSERT INTO public.lead (name, utm_source, utm_campaign, segment, created_at)
SELECT 'Alloc ' || g, 'google', 'woa_search', 'aviation', (crm_private.ads_google_today() - g)::timestamptz + interval '10 hours' FROM generate_series(1, 4) g;
SET ROLE service_role; SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_allocate()->'actions') = 0,
  'S08 good results but Google does not say the budget limits it: no raise (more money would not be spent)'); RESET ROLE;
UPDATE public.ads_campaigns SET raw = raw || '{"primary_status_reasons": ["BUDGET_CONSTRAINED"]}' WHERE external_id = 'g1';
SET ROLE service_role; SELECT public.svc_ads_allocate(); RESET ROLE;
SELECT pg_temp.ok((SELECT (after->>'daily_budget')::numeric FROM pg_temp.cq('g1')) = 1150,
  'S09 4 CRM leads at 250 each (target 500) and limited by budget: +15%');
DELETE FROM public.ads_change_queue;
UPDATE public.ads_campaigns SET daily_budget = 1400 WHERE external_id = 'g1';
SET ROLE service_role; SELECT public.svc_ads_allocate(); RESET ROLE;
SELECT pg_temp.ok((SELECT (after->>'daily_budget')::numeric FROM pg_temp.cq('g1')) = 1500, 'S10 a raise never goes past the daily limit');
DELETE FROM public.ads_change_queue;
UPDATE public.ads_campaigns SET daily_budget = 1500 WHERE external_id = 'g1';
SET ROLE service_role; SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_allocate()->'actions') = 0, 'S11 already at the limit: no raise'); RESET ROLE;
DELETE FROM public.lead WHERE name LIKE 'Alloc%';
UPDATE public.ads_metrics_daily SET spend = 300 WHERE campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1') AND day < crm_private.ads_google_today();
SET ROLE service_role; SELECT public.svc_ads_allocate(); RESET ROLE;
SELECT pg_temp.ok((SELECT (after->>'daily_budget')::numeric FROM pg_temp.cq('g1')) = 1200, 'S12 3,000 spent in 14 days with no CRM leads: -20%');
DELETE FROM public.ads_change_queue;
UPDATE public.ads_clients SET target_cpl = NULL WHERE id = (SELECT client_id FROM public.ads_accounts WHERE id = (SELECT v::uuid FROM ids WHERE k = 'ag'));
SET ROLE service_role; SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_allocate()->'actions') = 0, 'S13 no target cost per lead set: the allocator does not guess'); RESET ROLE;
UPDATE public.ads_clients SET target_cpl = 500 WHERE id = (SELECT client_id FROM public.ads_accounts WHERE id = (SELECT v::uuid FROM ids WHERE k = 'ag'));
UPDATE public.ads_campaigns SET daily_budget = 1000 WHERE external_id = 'g1';

-- ---------------------------------------------------------------- Daily report
SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_daily_report()->>'spend')::numeric = 300, 'S14 the daily report has yesterday''s spend');
SELECT pg_temp.ok(public.svc_ads_daily_report()->>'skipped' = 'already done', 'S15 one report per day');
RESET ROLE;
SELECT pg_temp.ok((SELECT summary FROM public.ads_agent_runs WHERE job = 'daily_report') LIKE '%has not checked in%',
  'S16 the report says when the agents helper on the Mac is offline');

-- ---------------------------------------------------------------- Learner and playbook
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agents_learn() ? 'queued', 'S17 the weekly learning step is queued');
SELECT pg_temp.ok(public.svc_ads_agents_learn()->>'skipped' = 'learned this week', 'S18 only once a week');
CREATE TEMP TABLE ln AS SELECT public.svc_ads_agent_next() AS j;
SELECT pg_temp.ok((SELECT j->'run'->>'role' = 'learner' AND j->'run'->'input' ? 'reviewer_rejections' AND j->'context' ? 'playbook' FROM ln),
  'S19 the Learner gets the month''s rejections and decisions; every step gets the playbook');
SELECT public.svc_ads_agent_finish((SELECT (j->'run'->>'id')::bigint FROM ln), true, jsonb_build_object('answer', 'Learned', 'playbook',
  jsonb_build_array(jsonb_build_object('lesson', 'Put the website source next to every fact in research', 'evidence', 'Reviewer rejected "since 2009" on 13 Nov'),
    'not an object', jsonb_build_object('lesson', ''), jsonb_build_object('lesson', 'Keep proposals under 25 changes', 'evidence', 'Builder failed 3 times'))));
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_playbook WHERE active) = 2, 'S20 good lessons are kept; empty or malformed ones are dropped');
INSERT INTO public.ads_agent_runs (account_id, role, job, status, output) VALUES ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'learner', 'x', 'running',
  (SELECT jsonb_build_object('playbook', jsonb_agg(jsonb_build_object('lesson', 'Lesson number ' || g))) FROM generate_series(1, 30) g));
UPDATE public.ads_agent_runs SET status = 'done' WHERE job = 'x';
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_playbook WHERE active) = 15 AND (SELECT count(*) FROM public.ads_playbook WHERE NOT active) = 2,
  'S21 a new week''s lessons replace the old ones, at most 15');
UPDATE public.ads_agent_runs SET status = 'done', output = '{"playbook": []}' WHERE job = 'weekly_learning';
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_playbook WHERE active) = 15, 'S22 a Learner run with no lessons does not wipe the playbook');

-- ---------------------------------------------------------------- Autopilot tab status, permissions
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok(NOT (public.api_ads_autopilot_status()->'agents'->>'online')::boolean AND jsonb_array_length(public.api_ads_autopilot_status()->'playbook') = 15
  AND public.api_ads_autopilot_status()->'report'->>'text' LIKE '%spent%', 'S23 the tab shows agents offline, the playbook and the latest report');
RESET ROLE; UPDATE public.ads_config SET value = now()::text WHERE key = 'agents_last_seen';
INSERT INTO public.ads_config (key, value) SELECT 'agents_last_seen', now()::text WHERE NOT EXISTS (SELECT 1 FROM public.ads_config WHERE key = 'agents_last_seen');
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_autopilot_status()->'agents'->>'online')::boolean, 'S24 agents online when they checked in in the last 3 minutes');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT public.api_ads_autopilot_status()', '%access to the ADS section%', 'S25 outsiders see nothing');
SELECT pg_temp.fails('SELECT public.svc_ads_supervise()', '%permission denied%', 'S26 nobody can run the Supervisor or allocator from the browser');
RESET ROLE;

\echo ALL ADS SUPERVISOR TESTS PASSED
