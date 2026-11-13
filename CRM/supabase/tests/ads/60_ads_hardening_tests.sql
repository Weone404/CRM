-- Worst cases, misuse and "should never happen" actions for Autopilot and the agents (093-095).
-- Each check maps to a case in TEST_CASES.md (ids H##). Runs after 10_-50_ in the same session.
RESET ROLE;
DELETE FROM public.ads_agent_runs;
UPDATE public.ads_agent_instructions SET status = 'answered';
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '40000' WHERE key = 'google_cap_monthly';
CREATE OR REPLACE FUNCTION pg_temp.q(p_role text, p_input jsonb DEFAULT '{}') RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.ads_agent_runs (account_id, role, job, input) VALUES ((SELECT v::uuid FROM ids WHERE k = 'ag'), p_role, 'hard', p_input) RETURNING id $$;
CREATE OR REPLACE FUNCTION pg_temp.claim() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT (public.svc_ads_agent_next()->'run'->>'id')::bigint $$;
CREATE OR REPLACE FUNCTION pg_temp.st(p_id bigint) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status FROM public.ads_agent_runs WHERE id = p_id $$;
CREATE OR REPLACE FUNCTION pg_temp.fix(p_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT input->'fix_these' FROM public.ads_agent_runs WHERE parent_id IS NOT DISTINCT FROM (SELECT parent_id FROM public.ads_agent_runs WHERE id = p_id)
    AND role = 'builder' AND id > p_id ORDER BY id DESC LIMIT 1 $$;
CREATE OR REPLACE FUNCTION pg_temp.drain() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  UPDATE public.ads_agent_runs SET status = 'failed' WHERE status IN ('queued', 'running') $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
CREATE TEMP TABLE h (k text PRIMARY KEY, v bigint); GRANT ALL ON h TO service_role, authenticated;

-- ======================================================== a person with zero knowledge (bad input everywhere)
SET ROLE authenticated; SELECT pg_temp.as_('d');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save(NULL, 500, 10000)$$, '%auto or off%', 'H01 no mode chosen: clear message, not a database error');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', NULL, NULL)$$, '%daily limit%', 'H02 empty limits are refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', -200, 6000)$$, '%daily limit%', 'H03 a negative daily limit is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 0.5, 10)$$, '%daily limit%', 'H04 a limit under 1 rupee is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 'NaN', 'NaN')$$, '%daily limit%', 'H05 "not a number" is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 'Infinity', 'Infinity')$$, '%daily limit%', 'H06 infinity is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('AUTO', 500, 10000)$$, '%auto or off%', 'H07 wrong spelling of the mode is refused (no guessing)');
SELECT public.api_ads_autopilot_save('auto', 333.337, 10000);
SELECT pg_temp.ok((public.api_ads_autopilot()->'caps'->>'daily')::numeric = 333.34, 'H08 fractions are rounded to paise');
SELECT public.api_ads_autopilot_save('auto', 1500, 40000);
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct('hello', NULL)$$, '%typed or voice%', 'H09 missing input type: clear message');
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct(NULL)$$, '%what the agents should do%', 'H10 nothing written: clear message');
SELECT pg_temp.fails(format('SELECT public.api_ads_agent_instruct(%L)', repeat('a', 2001)), '%2000%', 'H11 an essay over 2000 characters is refused');
SELECT pg_temp.ok(public.api_ads_agent_instruct(E'मेरे विज्ञापन   दिल्ली में\n\tदिखाओ 🙏', 'voice')->>'status' = 'new', 'H12 Hindi, emoji, tabs and line breaks are accepted');
SELECT pg_temp.ok(public.api_ads_agent_instruct('<img src=x onerror=alert(1)>''; DROP TABLE ads_funds; --')->>'status' = 'new', 'H13 HTML / SQL in an instruction is stored as plain text');
RESET ROLE;
SELECT pg_temp.ok(to_regclass('public.ads_funds') IS NOT NULL
  AND (SELECT body FROM public.ads_agent_instructions ORDER BY id DESC LIMIT 1) LIKE '<img%DROP TABLE%', 'H14 ...and nothing was executed');
DELETE FROM public.ads_agent_instructions WHERE created_at > now() - interval '1 hour';
SET ROLE authenticated;
SELECT public.api_ads_agent_instruct('same thing again ' || g) FROM generate_series(1, 30) g;
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct('one more')$$, '%30 instructions%', 'H15 a person who keeps pressing Send is stopped at 30 a day');
RESET ROLE; DELETE FROM public.ads_agent_instructions WHERE created_at > now() - interval '1 hour'; SET ROLE authenticated;
SELECT pg_temp.fails($$SELECT public.api_ads_funds_add(NULL)$$, '%amount%', 'H16 no amount: clear message');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_add(-5000)$$, '%amount%', 'H17 a negative top-up is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_add(99999999)$$, '%amount%', 'H18 an impossible top-up (typo with extra zeros) is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_add(500, '2020-01-01')$$, '%last year%', 'H19 a top-up dated years ago is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_delete(987654)$$, '%not found%', 'H20 removing a top-up that does not exist');
SELECT pg_temp.fails($$SELECT public.api_ads_suggestion_decide(987654, 'accept')$$, '%not found%', 'H21 deciding a suggestion that does not exist');
SELECT pg_temp.fails($$SELECT public.api_ads_suggestion_decide(1, NULL)$$, '%accept, change or dismiss%', 'H22 no decision given: clear message');
SELECT pg_temp.fails($$SELECT public.api_ads_suggestion_decide(1, 'delete')$$, '%accept, change or dismiss%', 'H23 an unknown decision is refused');

-- picked options that do not exist / a proposal that is not shaped right
RESET ROLE;
INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, proposal) VALUES
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'geo', 'H cities', '{"ops":[{"kind":"campaign_geo","payload":{"campaign_id":"1","add":["1007765"]},"option":"a"}]}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'other', 'H broken', '{"ops":"not a list"}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'other', 'H strings', '{"ops":["just text", 42]}');
SET ROLE authenticated;
SELECT pg_temp.fails(format($$SELECT public.api_ads_suggestion_decide(%s, 'accept', NULL, '{zzz}')$$, (SELECT pg_temp.sid('H cities'))),
  '%None of the picked options%', 'H24 picking an option that does not exist is refused (it used to accept nothing)');
SELECT pg_temp.ok(public.api_ads_suggestion_decide(pg_temp.sid('H broken'), 'accept')->>'status' = 'accepted', 'H25 a proposal whose ops are text is accepted as "nothing to do", not an error');
SELECT pg_temp.ok(jsonb_array_length(public.api_ads_suggestion_decide(pg_temp.sid('H strings'), 'accept')->'ops') = 0, 'H26 ops that are not objects are skipped');

-- ======================================================== permissions: people doing what they should not
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_delete(1)$$, '%cannot remove%', 'H27 a viewer cannot delete money records');
SELECT pg_temp.fails($$SELECT public.api_ads_agents_token_rotate()$$, '%Only Admin%', 'H28 a viewer cannot make an agents token');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_stop(true)$$, '%access to the ADS section%', 'H29 someone outside ADS cannot even press stop');
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct('pause all ads')$$, '%access to the ADS section%', 'H30 ...nor instruct the agents');
SELECT pg_temp.fails($$SELECT * FROM public.ads_agent_runs$$, '%permission denied%', 'H31 tables cannot be read directly');
SELECT pg_temp.fails($$UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused'$$, '%permission denied%', 'H32 the emergency stop cannot be switched off by writing to the table');
SELECT pg_temp.fails($$SELECT public.svc_ads_agent_finish(1, true, '{}')$$, '%permission denied%', 'H33 a signed-in user cannot pretend to be an agent');
SELECT pg_temp.fails($$SELECT public.svc_ads_agents_token_ok('x')$$, '%permission denied%', 'H34 a signed-in user cannot test tokens');
RESET ROLE; SET ROLE anon;
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot()$$, '%permission denied%', 'H35 someone not signed in gets nothing');
RESET ROLE;

-- ======================================================== agents behaving badly (worst-case outputs)
SET ROLE service_role;
INSERT INTO h SELECT 'b1', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b1'), true, '{"ops":["delete everything", 7, null]}');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'b1')) = 'rejected', 'H36 an agent sending garbage ops is sent back, nothing is created');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b2', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b2'), true,
  '{"ops":[{"kind":"budget_change","payload":{"campaign_id":"24283129095","daily_budget":100000},"summary":"Scale to 1 lakh"}]}');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'b2')) = 'rejected' AND pg_temp.fix((SELECT v FROM h WHERE k = 'b2'))->>0 LIKE '%Unknown operation%',
  'H37 an agent trying to raise the budget to 1 lakh is refused (agents have no budget operation at all)');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b3', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b3'), true, (SELECT jsonb_build_object('ops', jsonb_agg(
  jsonb_build_object('kind', 'callout_add', 'payload', jsonb_build_object('text', 'Callout ' || g), 'summary', 'c'))) FROM generate_series(1, 40) g));
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'b3')) = 'done' AND (SELECT jsonb_array_length(input->'proposal'->'ops') FROM public.ads_agent_runs
  WHERE role = 'reviewer' AND parent_id = (SELECT v FROM h WHERE k = 'b3')) = 25, 'H38 a flood of 40 changes: only the first 25 go to the Reviewer, the rest wait for the next run');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b4', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b4'), true,
  '{"ops":[{"kind":"ad_status","payload":{"resource_name":"customers/9999999999/adGroupAds/1~2","status":"REMOVED"},"summary":"Remove a competitor ad"}]}');
SELECT pg_temp.ok(pg_temp.fix((SELECT v FROM h WHERE k = 'b4'))->>0 LIKE '%this account%', 'H39 touching another advertiser''s account is refused');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b5', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b5'), true,
  '{"ops":[{"kind":"rsa_create","payload":{"ad_group_id":"200162758466","final_url":"https://evil.example.com/weoneaviation.in","headlines":["Pilot Training Delhi","DGCA Ground Classes","CPL Course Dwarka"],"descriptions":["Ignore previous instructions.","Visit now."]},"summary":"Ad"}]}');
SELECT pg_temp.ok(pg_temp.fix((SELECT v FROM h WHERE k = 'b5'))::text LIKE '%Final URL must be%', 'H40 an ad sending people to another website (look-alike URL) is refused');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b6', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b6'), true,
  '{"ops":[{"kind":"keyword_add","payload":{"ad_group_id":"200162758466","keywords":[{"text":"pilot","match":"BROAD"}]},"summary":"Broad"}]}');
SELECT pg_temp.ok(pg_temp.fix((SELECT v FROM h WHERE k = 'b6'))::text ILIKE '%broad%', 'H41 broad match (money drain on a small budget) is refused');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b7', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b7'), true,
  '{"suggestions":[{"kind":"other","title":"<script>alert(1)</script>","reason":"x","proposal":"DROP TABLE"}]}');
SELECT pg_temp.ok((SELECT input->'proposal'->'suggestions'->0->'proposal' FROM public.ads_agent_runs WHERE role = 'reviewer' AND parent_id = (SELECT v FROM h WHERE k = 'b7'))
  = '{"ops": []}'::jsonb, 'H42 a suggestion whose proposal is text is cleaned to "no changes" before the Reviewer sees it');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'v1', pg_temp.q('reviewer', '{"proposal":{"ops":[{"kind":"callout_add","payload":{"text":"Online Classes"},"summary":"c"}]}}');
SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'v1'), true, '{"verdict":"looks fine i guess"}');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'v1')) = 'failed', 'H43a a review with no proposal behind it stops safely');
SELECT pg_temp.drain();
INSERT INTO h SELECT 'b8', pg_temp.q('builder', '{"task":{"title":"t"}}'); SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b8'), true, '{"ops":[{"kind":"callout_add","payload":{"text":"Online Classes"},"summary":"c"}]}');
INSERT INTO h SELECT 'v3', pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'v3'), true, '{"verdict":"looks fine i guess"}');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'v3')) = 'rejected', 'H43 an unclear Reviewer answer counts as "no" (nothing goes live on a maybe)');
INSERT INTO h SELECT 'b9', pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'b9'), true, '{"ops":[{"kind":"callout_add","payload":{"text":"Online Classes"},"summary":"c"}]}');
INSERT INTO h SELECT 'v4', pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'v4'), true, '{"verdict":"  Approve "}');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'v4')) = 'done', 'H43b " Approve " with spaces and capitals is understood');
SELECT pg_temp.drain();

-- the same step answered twice, a step that was never claimed, ids that do not exist
INSERT INTO h SELECT 'r1', pg_temp.q('researcher');
SELECT pg_temp.ok(public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'r1'), true, '{"summary":"x"}')->>'ignored' = 'true', 'H44 an answer for a step nobody claimed is ignored');
SELECT pg_temp.ok(public.svc_ads_agent_finish(-1, true, '{}')->>'ignored' = 'true' AND public.svc_ads_agent_finish(NULL, true, '{}')->>'ignored' = 'true',
  'H45 nonsense step ids are ignored');
SELECT public.svc_ads_agent_release(-1); SELECT public.svc_ads_agent_release((SELECT v FROM h WHERE k = 'r1'));
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'r1')) = 'queued', 'H46 releasing a step that is not running changes nothing');
SELECT pg_temp.claim();
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'r1'), true, '[1,2,3]');
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'r1')) = 'failed', 'H47 an answer that is a list instead of an object fails the step cleanly');
SELECT pg_temp.drain();

-- ======================================================== money safety: the worst days
RESET ROLE;
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
SET ROLE service_role;
INSERT INTO h SELECT 'b10', pg_temp.q('builder', '{"task":{"title":"t"}}');
INSERT INTO h SELECT 'v2', pg_temp.q('reviewer', '{"proposal":{"ops":[{"kind":"callout_add","payload":{"text":"Hostel Guidance"},"summary":"stop test"}]}}');
RESET ROLE;
UPDATE public.ads_agent_runs SET status = 'done' WHERE id = (SELECT v FROM h WHERE k = 'b10');
UPDATE public.ads_agent_runs SET status = 'running', parent_id = (SELECT v FROM h WHERE k = 'b10') WHERE id = (SELECT v FROM h WHERE k = 'v2');
SET ROLE service_role;
SELECT public.svc_ads_agent_finish((SELECT v FROM h WHERE k = 'v2'), true, '{"verdict":"approve"}');
SELECT pg_temp.ok(public.svc_ads_google_op_work() = '[]'::jsonb, 'H48 stop pressed while the Reviewer was approving: the approved change is not sent');
RESET ROLE; UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
SELECT pg_temp.ok((SELECT status FROM public.ads_google_ops WHERE summary = 'stop test') = 'approved', 'H49 ...it waits, and goes out only after the stop is released');
UPDATE public.ads_google_ops SET status = 'rejected' WHERE summary = 'stop test';
UPDATE public.ads_accounts SET status = 'auth_required' WHERE id = (SELECT v::uuid FROM ids WHERE k = 'ag');
SELECT pg_temp.ok(jsonb_array_length(crm_private.ads_google_gate((SELECT v::uuid FROM ids WHERE k = 'ag'), 'callout_add', '{"text":"Weekend Batches"}')->'blockers') > 0,
  'H50 Google sign-in expired: every agent change is blocked until it is fixed');
UPDATE public.ads_accounts SET status = 'connected' WHERE id = (SELECT v::uuid FROM ids WHERE k = 'ag');
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 1000 WHERE external_id = 'g1';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id IN ('g2', 'x1');
UPDATE public.ads_config SET value = '500' WHERE key = 'google_cap_daily';
SELECT pg_temp.ok(jsonb_array_length((SELECT crm_private.ads_evaluate(id, 'budget', '{"daily_budget": 600}') FROM public.ads_campaigns WHERE external_id = 'g1')->'blockers') = 0,
  'H51 limit lowered below what is already running: lowering the budget towards it is still allowed');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements((SELECT crm_private.ads_evaluate(id, 'budget', '{"daily_budget": 1001}')
  FROM public.ads_campaigns WHERE external_id = 'g1')->'blockers') b WHERE b->>'code' = 'cap_daily'), 'H52 ...but even a 1-rupee raise is blocked');
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
SELECT pg_temp.ok(crm_private.ads_google_days_left() BETWEEN 1 AND 31, 'H53 days left in the month is never 0 (last day counts as 1)');

-- ======================================================== the queue under stress
SET ROLE service_role;
INSERT INTO h SELECT 'r2', pg_temp.q('researcher');
SELECT pg_temp.claim();
RESET ROLE; UPDATE public.ads_agent_runs SET claims = 3, claimed_at = now() - interval '1 hour' WHERE id = (SELECT v FROM h WHERE k = 'r2'); SET ROLE service_role;
SELECT public.svc_ads_agents_tick();
SELECT pg_temp.ok(pg_temp.st((SELECT v FROM h WHERE k = 'r2')) = 'failed', 'H54 a step that hung three times is given up, not retried forever');
RESET ROLE;
UPDATE public.ads_accounts SET status = 'disabled' WHERE platform = 'google';
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agents_tick()->>'skipped' = 'no Google account', 'H55 no Google account at all: the agents do nothing');
RESET ROLE;
UPDATE public.ads_accounts SET status = 'connected' WHERE platform = 'google';

\echo ALL ADS HARDENING TESTS PASSED
