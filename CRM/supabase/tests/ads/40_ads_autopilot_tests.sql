-- Autopilot (migration 093): spend limits, emergency stop, funds, instructions, suggestions, agents token.
-- Runs after 10_, 20_ and 30_ in the same session.
RESET ROLE;
UPDATE public.ads_rules SET active = false WHERE code IN ('changes_per_day', 'budget_change_max', 'budget_client_max');
UPDATE public.ads_rules SET value = '{"max": 40}' WHERE code = 'g_ops_per_day';
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 1000, budget_ref = 'customers/1112223333/campaignBudgets/9' WHERE external_id = 'g1';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id IN ('g2', 'x1');
UPDATE public.ads_campaigns SET status = 'PAUSED', daily_budget = 300 WHERE external_id = 'm1';
CREATE OR REPLACE FUNCTION pg_temp.ev(p_ext text, p_kind text, p_after jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT crm_private.ads_evaluate((SELECT id FROM public.ads_campaigns WHERE external_id = p_ext), p_kind, p_after) $$;
CREATE OR REPLACE FUNCTION pg_temp.has(p_res jsonb, p_code text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_res->'blockers') b WHERE b->>'code' = p_code) $$;
CREATE OR REPLACE FUNCTION pg_temp.sid(p_title text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.ads_autopilot_suggestions WHERE title = p_title $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- access and limits
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT public.api_ads_autopilot()', '%access to the ADS section%', 'P01 a user without ADS access cannot open Autopilot');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_ads_autopilot()->'caps') ? 'daily' AND public.api_ads_autopilot()->>'mode' IN ('auto', 'off'), 'P02 an ADS viewer sees mode and limits');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 500, 10000)$$, '%approve%', 'P03 a viewer cannot change limits');
SELECT pg_temp.as_('d');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 500, 400)$$, '%below the daily limit%', 'P04 monthly limit below daily is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('auto', 500, 20000)$$, '%31 days%', 'P05 monthly limit above 31 days of daily is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_autopilot_save('fast', 500, 2000)$$, '%auto or off%', 'P06 unknown mode refused');
SELECT public.api_ads_autopilot_save('auto', 1500, 40000);
SELECT pg_temp.ok((public.api_ads_autopilot()->'caps'->>'daily')::numeric = 1500 AND public.api_ads_autopilot()->>'mode' = 'auto', 'P07 an approver saves mode and limits');
RESET ROLE;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.ads_activity_log WHERE action = 'autopilot_saved'), 'P08 saving limits is logged');

-- ---------------------------------------------------------------- the evaluator enforces the limits
SELECT pg_temp.ok(pg_temp.has(pg_temp.ev('g1', 'budget', '{"daily_budget": 2000}'), 'cap_daily'), 'P09 raising a budget above the daily limit is blocked');
SELECT pg_temp.ok(NOT pg_temp.has(pg_temp.ev('g1', 'budget', '{"daily_budget": 1400}'), 'cap_daily')
  AND NOT pg_temp.has(pg_temp.ev('g1', 'budget', '{"daily_budget": 1400}'), 'cap_monthly'), 'P10 a raise within both limits passes');
UPDATE public.ads_campaigns SET daily_budget = 800 WHERE external_id = 'x1';
SELECT pg_temp.ok(pg_temp.has(pg_temp.ev('x1', 'status', '{"status": "ENABLED"}'), 'cap_daily'), 'P11 turning on a campaign that pushes the total over the daily limit is blocked');
SELECT pg_temp.ok(NOT pg_temp.has(pg_temp.ev('m1', 'status', '{"status": "ENABLED"}'), 'cap_daily'), 'P12 Meta campaigns are not counted (Google only)');
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend) VALUES ((SELECT id FROM public.ads_campaigns WHERE external_id = 'g1'), crm_private.ads_google_today(), 39000)
  ON CONFLICT (campaign_id, day) DO UPDATE SET spend = 39000;
SELECT pg_temp.ok(crm_private.ads_google_month_spend() >= 39000, 'P13 month-to-date Google spend is read from synced metrics');
SELECT pg_temp.ok(pg_temp.has(pg_temp.ev('g1', 'budget', '{"daily_budget": 1100}'), 'cap_monthly'), 'P14 a raise that would pass the monthly limit is blocked');
SELECT pg_temp.ok(jsonb_array_length(pg_temp.ev('g1', 'budget', '{"daily_budget": 900}')->'blockers') = 0, 'P15 lowering a budget is always allowed');
SELECT pg_temp.ok(jsonb_array_length(pg_temp.ev('g1', 'status', '{"status": "PAUSED"}')->'blockers') = 0, 'P16 pausing is always allowed');
UPDATE public.ads_metrics_daily SET spend = 41000 WHERE day = crm_private.ads_google_today();
SELECT pg_temp.ok(pg_temp.has(pg_temp.ev('x1', 'status', '{"status": "ENABLED"}'), 'cap_monthly')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.ev('x1', 'status', '{"status": "ENABLED"}')->'blockers') b WHERE b->>'message' ILIKE '%has reached%'),
  'P17 once the month''s spend reaches the limit, nothing can raise spend');
UPDATE public.ads_config SET value = '' WHERE key IN ('google_cap_daily', 'google_cap_monthly');
SELECT pg_temp.ok(NOT pg_temp.has(pg_temp.ev('g1', 'budget', '{"daily_budget": 2000}'), 'cap_daily'), 'P18 with no limits set, nothing is blocked by them');
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '40000' WHERE key = 'google_cap_monthly';
SELECT pg_temp.fails(format($$INSERT INTO public.ads_change_queue (campaign_id, kind, after, status) VALUES ('%s', 'budget', '{"daily_budget": 2000}', 'approved')$$,
  (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1')), '%must be fixed first%', 'P19 an over-limit budget change cannot be approved');

-- ---------------------------------------------------------------- emergency stop
SET ROLE authenticated;
SELECT pg_temp.as_('c');
SELECT public.api_ads_autopilot_stop(true);
SELECT pg_temp.ok((public.api_ads_autopilot()->>'stopped')::boolean, 'P20 any ADS user can press the emergency stop');
SELECT pg_temp.fails('SELECT public.api_ads_autopilot_stop(false)', '%approve%', 'P21 a viewer cannot turn it off again');
SELECT pg_temp.as_('d');
SELECT public.api_ads_autopilot_stop(false);
SELECT pg_temp.ok(NOT (public.api_ads_autopilot()->>'stopped')::boolean, 'P22 an approver turns it off');

-- ---------------------------------------------------------------- funds
SELECT pg_temp.as_('c');
SELECT pg_temp.fails('SELECT public.api_ads_funds_add(0)', '%amount%', 'P23 zero funds refused');
SELECT pg_temp.fails($$SELECT public.api_ads_funds_add(500, (now() + interval '3 days')::date)$$, '%future%', 'P24 a future date is refused');
SELECT public.api_ads_funds_add(50000, NULL, 'UPI top-up');
SELECT pg_temp.ok((public.api_ads_autopilot()->'funds'->>'added')::numeric = 50000
  AND (public.api_ads_autopilot()->'funds'->>'estimate')::numeric = 50000 - 41000, 'P25 balance estimate = added minus Google spend since then');
SELECT pg_temp.ok(NOT (public.api_ads_autopilot()->'funds'->>'low')::boolean, 'P26a 9 days of balance left: no notice');
RESET ROLE; UPDATE public.ads_metrics_daily SET spend = 48500 WHERE day = crm_private.ads_google_today(); SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_autopilot()->'funds'->>'low')::boolean, 'P26 a balance under 3 days of spend shows the add-funds notice');
SELECT pg_temp.fails(format('SELECT public.api_ads_funds_delete(%s)', public.api_ads_autopilot()->'funds'->'entries'->0->>'id'), '%cannot remove%', 'P27 a viewer cannot remove a funds entry');

-- ---------------------------------------------------------------- instructions
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct('  ')$$, '%what the agents should do%', 'P28 empty instruction refused');
SELECT pg_temp.fails($$SELECT public.api_ads_agent_instruct('hello', 'email')$$, '%typed or voice%', 'P29 unknown input type refused');
SELECT pg_temp.ok(public.api_ads_agent_instruct('Add Chandigarh   and stop showing in Punjab villages', 'voice')->>'status' = 'new', 'P30 a spoken instruction is queued');
RESET ROLE;
SELECT pg_temp.ok((SELECT body FROM public.ads_agent_instructions ORDER BY id DESC LIMIT 1) = 'Add Chandigarh and stop showing in Punjab villages', 'P31 spaces are tidied');

-- ---------------------------------------------------------------- suggestions
RESET ROLE;
INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal) VALUES
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'assets', 'Add callouts', 'Facts from the website only.',
   '{"ops": [{"kind": "callout_add", "payload": {"text": "Weekend Batches"}, "option": "a"},
             {"kind": "callout_add", "payload": {"text": "Hostel Help Desk"}, "option": "b"},
             {"kind": "callout_add", "payload": {"text": "Online Classes"}}]}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'assets', 'Viewer accepts', '', '{"ops": [{"kind": "callout_add", "payload": {"text": "Dwarka Campus"}}]}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'ads', 'Risky ad', '', '{"ops": [{"kind": "callout_add", "payload": {"text": "Guaranteed Job"}}]}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'geo', 'Change me', '', '{"ops": []}'),
  ((SELECT v::uuid FROM ids WHERE k = 'ag'), 'other', 'Dismiss me', '', '{"ops": []}');
SET ROLE authenticated;
SELECT pg_temp.as_('d');
SELECT pg_temp.fails(format($$SELECT public.api_ads_suggestion_decide(%s, 'accept', NULL, '{}')$$, pg_temp.sid('Add callouts')),
  '%at least one%', 'P32 accepting with nothing picked is refused');
SELECT pg_temp.ok(jsonb_array_length(public.api_ads_suggestion_decide(pg_temp.sid('Add callouts'), 'accept', NULL, '{a}')->'ops') = 2,
  'P33 only the picked option (plus the shared part) becomes operations');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_google_ops WHERE payload->>'text' IN ('Weekend Batches', 'Online Classes') AND status = 'approved'
  AND created_by_type = 'agent') = 2 AND NOT EXISTS (SELECT 1 FROM public.ads_google_ops WHERE payload->>'text' = 'Hostel Help Desk'),
  'P34 an approver''s accept approves them; the unpicked option is not created');
SET ROLE authenticated;
SELECT pg_temp.fails(format($$SELECT public.api_ads_suggestion_decide(%s, 'accept')$$, pg_temp.sid('Add callouts')),
  '%already accepted%', 'P35 a suggestion is decided once');
SELECT pg_temp.ok(public.api_ads_suggestion_decide(pg_temp.sid('Risky ad'), 'accept')->'ops'->0->>'status' = 'blocked',
  'P36 accepting does not bypass the quality gate (unprovable claim stays blocked)');
SELECT pg_temp.as_('c');
RESET ROLE; UPDATE public.ads_config SET value = 'off' WHERE key = 'autopilot_google'; SET ROLE authenticated;
SELECT pg_temp.ok(public.api_ads_suggestion_decide(pg_temp.sid('Viewer accepts'), 'accept')->'ops'->0->>'status' = 'pending',
  'P37 a viewer''s accept waits for an approver when Autopilot is off');
SELECT pg_temp.fails(format($$SELECT public.api_ads_suggestion_decide(%s, 'change', ' ')$$, pg_temp.sid('Change me')),
  '%what to change%', 'P38 "change" needs a note');
SELECT public.api_ads_suggestion_decide(pg_temp.sid('Change me'), 'change', 'Only Delhi NCR please');
SELECT public.api_ads_suggestion_decide(pg_temp.sid('Dismiss me'), 'dismiss');
RESET ROLE;
SELECT pg_temp.ok((SELECT via = 'suggestion' AND body ILIKE '%Only Delhi NCR please%' FROM public.ads_agent_instructions ORDER BY id DESC LIMIT 1),
  'P39 "change" sends the note to the agents');
SELECT pg_temp.ok((SELECT string_agg(status, ',' ORDER BY id) FROM public.ads_autopilot_suggestions) = 'accepted,accepted,accepted,changed,dismissed', 'P40 statuses recorded');
SET ROLE authenticated;

-- ---------------------------------------------------------------- agents token
SELECT pg_temp.fails('SELECT public.api_ads_agents_token_rotate()', '%Only Admin%', 'P41 only Admin can make an agents token');
SELECT pg_temp.as_('a');
CREATE TEMP TABLE tok AS SELECT public.api_ads_agents_token_rotate()->>'token' AS t;
GRANT SELECT ON tok TO service_role;
RESET ROLE;
SELECT pg_temp.ok((SELECT value FROM public.ads_config WHERE key = 'agents_token_sha256') ~ '^[0-9a-f]{64}$'
  AND NOT EXISTS (SELECT 1 FROM public.ads_config, tok WHERE value = tok.t), 'P42 only the token''s hash is stored');
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agents_token_ok((SELECT t FROM tok)) AND NOT public.svc_ads_agents_token_ok('adsag_wrong_token_000000000000000000')
  AND NOT public.svc_ads_agents_token_ok(NULL), 'P43 the token checks out; a wrong or missing one does not');
RESET ROLE; SET ROLE authenticated;
SELECT pg_temp.fails($$SELECT public.svc_ads_agents_token_ok('x')$$, '%permission denied%', 'P44 the token check is service-only');
SELECT pg_temp.ok(jsonb_typeof(public.api_ads_autopilot()->'runs') = 'array' AND jsonb_array_length(public.api_ads_autopilot()->'ops') > 0
  AND jsonb_array_length(public.api_ads_autopilot()->'instructions') = 2, 'P45 Activity lists agent runs, operations and instructions');
RESET ROLE;

\echo ALL ADS AUTOPILOT TESTS PASSED
