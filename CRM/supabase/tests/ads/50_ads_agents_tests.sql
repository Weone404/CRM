-- ADS agents queue (migration 094). Runs after 10_-40_ in the same session.
RESET ROLE;
DELETE FROM public.ads_agent_runs;
UPDATE public.ads_agent_instructions SET status = 'answered';
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_rules SET value = '{"max": 400}' WHERE code = 'g_ops_per_day';
CREATE OR REPLACE FUNCTION pg_temp.runs(p_role text, p_status text) RETURNS int LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.ads_agent_runs WHERE role = p_role AND status = p_status $$;
CREATE OR REPLACE FUNCTION pg_temp.step() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT public.svc_ads_agent_next() $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- an instruction starts a chain on the next tick
SET ROLE authenticated; SELECT pg_temp.as_('d');
SELECT public.api_ads_agent_instruct('Add a callout about weekend batches');
SET ROLE authenticated;
SELECT pg_temp.fails('SELECT public.svc_ads_agents_tick()', '%permission denied%', 'Q01 the tick is service-only');
SELECT pg_temp.fails('SELECT public.svc_ads_agent_next()', '%permission denied%', 'Q02 claiming work is service-only');
RESET ROLE; SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_agents_tick()->>'started')::int = 1, 'Q03 tick starts the new instruction');
SELECT pg_temp.ok((public.svc_ads_agents_tick()->>'started')::int = 0, 'Q04 a second tick starts nothing new (no daily review while work is waiting)');
CREATE TEMP TABLE st (k text PRIMARY KEY, v jsonb); GRANT ALL ON st TO service_role;
INSERT INTO st SELECT 'r1', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'researcher' AND v->'run'->>'job' = 'instruction' FROM st WHERE k = 'r1'), 'Q05 the oldest step (the instruction) is claimed first');
SELECT pg_temp.ok((SELECT v->'context'->'instruction'->>'text' = 'Add a callout about weekend batches' AND v->'context'->'rules'->'banned_claims' IS NOT NULL
  AND v->'context'->'autopilot'->>'mode' = 'auto' AND jsonb_typeof(v->'context'->'campaigns') = 'array' FROM st WHERE k = 'r1'),
  'Q06 context carries the instruction, rules, limits and campaigns');
RESET ROLE;
SELECT pg_temp.ok((SELECT status FROM public.ads_agent_instructions WHERE body = 'Add a callout about weekend batches') = 'working', 'Q07 the instruction shows as working');
SET ROLE service_role;

-- researcher -> builder
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'r1'), true, '{"summary":"Weekend batches are on the site."}');
SELECT pg_temp.ok(pg_temp.runs('builder', 'queued') = 1, 'Q08 research done queues the builder');
INSERT INTO st SELECT 'b1', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'builder' AND v->'run'->'input'->'research'->>'summary' LIKE 'Weekend%' FROM st WHERE k = 'b1'), 'Q09 the builder gets the research');

-- builder with a banned claim -> code checks send it back without bothering the reviewer
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b1'), true,
  '{"answer":"Added a callout","ops":[{"kind":"callout_add","payload":{"text":"Guaranteed Weekend Batch"},"summary":"Callout"}]}');
SELECT pg_temp.ok(pg_temp.runs('builder', 'rejected') = 1 AND pg_temp.runs('reviewer', 'queued') = 0 AND pg_temp.runs('builder', 'queued') = 1,
  'Q10 a proposal failing the code checks goes back to the builder, not to the reviewer');
INSERT INTO st SELECT 'b2', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT (v->'run'->>'attempt')::int = 2 AND v->'run'->'input'->'fix_these'->>0 LIKE '%guarantee%' FROM st WHERE k = 'b2'),
  'Q11 the second try carries the exact problems');

-- clean builder with a location change -> reviewer; location change becomes a suggestion
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b2'), true,
  '{"answer":"Added a weekend callout","ops":[{"kind":"callout_add","payload":{"text":"Weekend Batches"},"summary":"Callout Weekend Batches"},
    {"kind":"campaign_geo","payload":{"campaign_id":"24283129095","add":["1007765"]},"summary":"Add Gurugram"}]}');
INSERT INTO st SELECT 'v1', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'reviewer' AND jsonb_array_length(v->'run'->'input'->'proposal'->'ops') = 1
  AND v->'run'->'input'->'proposal'->'suggestions'->0->>'kind' = 'geo' FROM st WHERE k = 'v1'),
  'Q12 a clean proposal reaches the reviewer; the location change is turned into a suggestion');

-- reviewer rejects -> builder try 3; reviewer rejects again -> escalated to the user
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'v1'), true, '{"verdict":"reject","problems":["Callout duplicates an existing one"]}');
INSERT INTO st SELECT 'b3', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'builder' AND (v->'run'->>'attempt')::int = 3 AND v->'run'->'input'->>'from' = 'reviewer' FROM st WHERE k = 'b3'),
  'Q13 a reviewer rejection sends the builder back with the reviewer''s problems');
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b3'), true,
  '{"answer":"Weekend callout","ops":[{"kind":"callout_add","payload":{"text":"Saturday Sunday Batches"},"summary":"Callout"}]}');
INSERT INTO st SELECT 'v2', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'v2'), true, '{"verdict":"reject","problems":["Still unsure"]}');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.runs('reviewer', 'escalated') = 1 AND EXISTS (SELECT 1 FROM public.ads_autopilot_suggestions WHERE title LIKE 'Needs your decision%')
  AND (SELECT status FROM public.ads_agent_instructions WHERE body = 'Add a callout about weekend batches') = 'failed',
  'Q14 after 3 tries the proposal goes to the user as a suggestion and the instruction says so');
SET ROLE service_role;

-- daily review: approve path makes operations (auto-approved in Automatic mode) and suggestions
SELECT pg_temp.ok((public.svc_ads_agents_tick()->>'started')::int = 1, 'Q14b with the queue empty, the daily review starts');
INSERT INTO st SELECT 'r2', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'r2'), true, '{"summary":"Cabin crew searches waste money."}');
INSERT INTO st SELECT 'b4', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b4'), true,
  '{"answer":"Blocked cabin crew searches","ops":[{"kind":"negative_add","payload":{"level":"shared_set","shared_set_id":"11955185109","keywords":[{"text":"cabin crew","match":"PHRASE"}]},"summary":"Negative cabin crew"}],
    "suggestions":[{"kind":"keywords","title":"Add ground class keywords","reason":"Best past search","proposal":{"ops":[]}}]}');
INSERT INTO st SELECT 'v3', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'v3'), true, '{"verdict":"approve","problems":[]}');
RESET ROLE;
SELECT pg_temp.ok((SELECT status FROM public.ads_google_ops WHERE summary = 'Negative cabin crew') = 'approved'
  AND (SELECT created_by_type FROM public.ads_google_ops WHERE summary = 'Negative cabin crew') = 'agent', 'Q15 approved changes go live automatically in Automatic mode');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.ads_autopilot_suggestions WHERE title = 'Add ground class keywords' AND status = 'open'), 'Q16 suggestions reach the Autopilot tab');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.ads_activity_log WHERE action = 'agents_done'), 'Q17 a finished chain is logged');

-- negatives may never block the core searches
SET ROLE service_role;
SELECT public.svc_ads_agents_tick();
UPDATE public.ads_agent_runs SET created_at = now() - interval '1 day' WHERE job = 'daily_review';
RESET ROLE;
INSERT INTO public.ads_agent_runs (account_id, role, job, input) VALUES ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'builder', 'test', '{"task":{"title":"t"}}');
SET ROLE service_role;
INSERT INTO st SELECT 'b5', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b5'), true,
  '{"ops":[{"kind":"negative_add","payload":{"level":"shared_set","shared_set_id":"11955185109","keywords":[{"text":"pilot","match":"BROAD"}]},"summary":"bad"}]}');
INSERT INTO st SELECT 'b6', public.svc_ads_agent_next();
SELECT pg_temp.ok((SELECT v->'run'->'input'->'fix_these'->>0 LIKE '%core search%' FROM st WHERE k = 'b6'), 'Q18 a negative that would block "pilot training" is sent back');

-- failure, release, emergency stop, stuck steps
SELECT public.svc_ads_agent_release((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b6'), 'Claude limit');
SELECT pg_temp.ok(pg_temp.runs('builder', 'queued') = 1, 'Q19 a released step goes back to the queue');
RESET ROLE; UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused'; SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agent_next() IS NULL, 'Q20 emergency stop: agents get no work');
RESET ROLE; UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused'; SET ROLE service_role;
INSERT INTO st SELECT 'b7', public.svc_ads_agent_next();
RESET ROLE; UPDATE public.ads_agent_runs SET claimed_at = now() - interval '40 minutes' WHERE id = (SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b7'); SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_agents_tick()->>'freed')::int = 1, 'Q21 a step stuck for 30 minutes is freed');
INSERT INTO st SELECT 'b8', public.svc_ads_agent_next();
SELECT public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b8'), false, NULL, NULL, 'Claude stopped');
SELECT pg_temp.ok(pg_temp.runs('builder', 'failed') = 1, 'Q22 a failed step is recorded as failed');
SELECT pg_temp.ok((public.svc_ads_agent_finish((SELECT (v->'run'->>'id')::bigint FROM st WHERE k = 'b8'), true, '{}'))->>'ignored' = 'true',
  'Q23 a late second answer for the same step is ignored');
RESET ROLE;

\echo ALL ADS AGENTS TESTS PASSED
