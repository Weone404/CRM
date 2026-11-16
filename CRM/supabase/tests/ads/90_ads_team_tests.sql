-- 099: the specialist team. Team Lead (TL), 24-hour rule (AU), bids and budget (BB), reporting enquiries to Google (CV), tracking (TR).
-- Runs after 10_-80_ (uses t8 and pg_temp.click from 80_).
RESET ROLE;
DELETE FROM public.ads_autopilot_suggestions; DELETE FROM public.ads_google_ops; DELETE FROM public.ads_change_queue;
DELETE FROM public.ads_agent_runs; DELETE FROM public.ads_agent_instructions; DELETE FROM public.ads_metrics_daily;
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'on' WHERE key = 'agents_daily_review';
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '40000' WHERE key = 'google_cap_monthly';
UPDATE public.ads_config SET value = (now() - interval '30 days')::text WHERE key = 'suggest_auto_since';
UPDATE public.ads_accounts SET status = 'connected' WHERE id = (SELECT acc FROM t8);
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 1000, budget_ref = 'customers/1112223333/campaignBudgets/9' WHERE id = (SELECT camp FROM t8);
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE id <> (SELECT camp FROM t8);
INSERT INTO public.ads_google_snapshot (account_id, kind, data) VALUES ((SELECT acc FROM t8), 'campaigns',
  '[{"campaign.id": "24283129095", "campaign.biddingStrategyType": "TARGET_SPEND", "campaign.targetSpend.cpcBidCeilingMicros": "20000000"}]')
ON CONFLICT (account_id, kind) DO UPDATE SET data = EXCLUDED.data;

CREATE OR REPLACE FUNCTION pg_temp.g(p_kind text, p_payload jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT crm_private.ads_google_gate((SELECT acc FROM t8), p_kind, p_payload)->'blockers' $$;
CREATE OR REPLACE FUNCTION pg_temp.ok0(p_kind text, p_payload jsonb) RETURNS boolean LANGUAGE sql AS $$ SELECT jsonb_array_length(pg_temp.g(p_kind, p_payload)) = 0 $$;
CREATE OR REPLACE FUNCTION pg_temp.cpc(v jsonb) RETURNS boolean LANGUAGE sql AS $$ SELECT pg_temp.ok0('cpc_cap', jsonb_build_object('campaign_id', '24283129095', 'max_cpc', v)) $$;
CREATE OR REPLACE FUNCTION pg_temp.bud(v jsonb) RETURNS boolean LANGUAGE sql AS $$ SELECT pg_temp.ok0('budget', jsonb_build_object('campaign_id', '24283129095', 'daily_budget', v)) $$;
-- a suggestion as the agents leave it: written by a Builder step, approved (or not) by a Reviewer step
CREATE OR REPLACE FUNCTION pg_temp.sug(p_title text, p_proposal jsonb, p_review text DEFAULT 'done', p_age interval DEFAULT '25 hours') RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE b bigint; s bigint;
BEGIN
  INSERT INTO public.ads_agent_runs (account_id, role, job, status, created_at) VALUES ((SELECT acc FROM t8), 'builder', 'desk_test', 'done', now() - interval '3 days') RETURNING id INTO b;
  IF p_review IS NOT NULL THEN
    INSERT INTO public.ads_agent_runs (account_id, role, job, status, parent_id, created_at) VALUES ((SELECT acc FROM t8), 'reviewer', 'desk_test', p_review, b, now() - interval '3 days');
  END IF;
  INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal, agent_run_id, created_at)
  VALUES ((SELECT acc FROM t8), 'negatives', p_title, 'because', p_proposal, CASE WHEN p_review IS NULL THEN NULL ELSE b END, now() - p_age) RETURNING id INTO s;
  RETURN s;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.neg(p_text text, p_option text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('kind', 'negative_add', 'summary', 'Block ' || p_text, 'option', p_option,
    'payload', jsonb_build_object('level', 'campaign', 'campaign_id', '24283129095', 'keywords', jsonb_build_array(jsonb_build_object('text', p_text, 'match', 'PHRASE'))))) $$;
CREATE OR REPLACE FUNCTION pg_temp.auto() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT public.svc_ads_suggestions_auto() $$;
CREATE OR REPLACE FUNCTION pg_temp.auto_at(p_id bigint) RETURNS timestamptz LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_suggestion_auto_at(p_id) $$;
CREATE OR REPLACE FUNCTION pg_temp.sg(p_id bigint) RETURNS public.ads_autopilot_suggestions LANGUAGE sql SECURITY DEFINER AS $$ SELECT s FROM public.ads_autopilot_suggestions s WHERE id = p_id $$;
CREATE OR REPLACE FUNCTION pg_temp.tick() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT public.svc_ads_agents_tick() $$;
CREATE OR REPLACE FUNCTION pg_temp.q() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_conversions_queue() $$;
CREATE OR REPLACE FUNCTION pg_temp.cw() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT public.svc_ads_conversions_work() $$;
CREATE OR REPLACE FUNCTION pg_temp.ups() RETURNS SETOF public.ads_conversion_uploads LANGUAGE sql SECURITY DEFINER AS $$ SELECT * FROM public.ads_conversion_uploads ORDER BY id $$;
CREATE TEMP TABLE st9 (k text PRIMARY KEY, v bigint);
GRANT ALL ON st9 TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- ================================================================ BB: bids and budget (the gate every agent change passes)
SELECT pg_temp.ok(pg_temp.cpc('24'), 'BB01 max CPC 20 -> 24 on a Maximize Clicks campaign is allowed');
SELECT pg_temp.ok(NOT pg_temp.cpc('40') AND NOT pg_temp.cpc('10') AND pg_temp.g('cpc_cap', '{"campaign_id": "24283129095", "max_cpc": 40}')->>0 LIKE '%100% change%',
  'BB02 doubling or halving the max CPC in one step is refused, with the reason');
SELECT pg_temp.ok(NOT pg_temp.cpc('2') AND NOT pg_temp.cpc('151') AND NOT pg_temp.cpc('0') AND NOT pg_temp.cpc('-20') AND NOT pg_temp.cpc('"abc"')
  AND NOT pg_temp.cpc('"NaN"') AND NOT pg_temp.cpc('"Infinity"') AND NOT pg_temp.cpc('null') AND NOT pg_temp.cpc('20.123') AND NOT pg_temp.cpc('[20]'),
  'BB03 max CPC below 3, above 150, zero, negative, text, NaN, infinity, empty, 3 decimals or a list: all refused');
UPDATE public.ads_google_snapshot SET data = '[{"campaign.id": "24283129095", "campaign.biddingStrategyType": "MANUAL_CPC"}]' WHERE kind = 'campaigns' AND account_id = (SELECT acc FROM t8);
SELECT pg_temp.ok(NOT pg_temp.cpc('24'), 'BB04 a campaign that is not on Maximize Clicks cannot get a max CPC cap');
UPDATE public.ads_google_snapshot SET data = '{"error": "Google did not answer"}' WHERE kind = 'campaigns' AND account_id = (SELECT acc FROM t8);
SELECT pg_temp.ok(NOT pg_temp.cpc('24'), 'BB05 the account picture failed to load: refused, no crash');
UPDATE public.ads_google_snapshot SET data = '[{"campaign.id": "24283129095", "campaign.biddingStrategyType": "TARGET_SPEND"}]' WHERE kind = 'campaigns' AND account_id = (SELECT acc FROM t8);
SELECT pg_temp.ok(pg_temp.cpc('24') AND pg_temp.cpc('140'), 'BB06 no cap set yet: any value inside 3-150 can be the first cap');
UPDATE public.ads_google_snapshot SET data = '[{"campaign.id": "24283129095", "campaign.biddingStrategyType": "TARGET_SPEND", "campaign.targetSpend.cpcBidCeilingMicros": "20000000"}]'
 WHERE kind = 'campaigns' AND account_id = (SELECT acc FROM t8);
SELECT pg_temp.ok(NOT pg_temp.ok0('cpc_cap', '{"campaign_id": "99999", "max_cpc": 24}') AND NOT pg_temp.ok0('cpc_cap', '{"campaign_id": "555000111", "max_cpc": 24}')
  AND NOT pg_temp.ok0('cpc_cap', '{"max_cpc": 24}') AND NOT pg_temp.ok0('cpc_cap', '{"campaign_id": "1 OR 1=1", "max_cpc": 24}') AND NOT pg_temp.ok0('cpc_cap', '"x"'),
  'BB07 unknown campaign, a Meta campaign, no campaign, injected text or no payload: refused');
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES ((SELECT acc FROM t8), 'cpc_cap', '{"campaign_id": "24283129095", "max_cpc": 24}', 'agent');
SELECT pg_temp.ok((SELECT status = 'approved' FROM public.ads_google_ops WHERE kind = 'cpc_cap'), 'BB08 in Automatic mode an agent''s valid bid change is approved by itself');
SELECT pg_temp.ok(NOT pg_temp.cpc('22'), 'BB09 a second max CPC change within 24 hours is refused');
DELETE FROM public.ads_google_ops;

SELECT pg_temp.ok(pg_temp.bud('1200'), 'BB10 budget 1,000 -> 1,200 with a daily limit of 1,500: allowed');
UPDATE public.ads_config SET value = '1100' WHERE key = 'google_cap_daily';
SELECT pg_temp.ok(NOT pg_temp.bud('1200') AND pg_temp.g('budget', '{"campaign_id": "24283129095", "daily_budget": 1200}')->>0 LIKE '%above the daily limit of 1100%',
  'BB11 a raise above the owner''s daily limit is refused');
SELECT pg_temp.ok(pg_temp.bud('1100'), 'BB12 a raise exactly to the daily limit is allowed');
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 300 WHERE external_id = 'g2';
SELECT pg_temp.ok(NOT pg_temp.bud('1100'), 'BB13 the limit counts ALL running Google campaigns together, not one campaign');
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id = 'g2';
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '500' WHERE key = 'google_cap_monthly';
SELECT pg_temp.ok(NOT pg_temp.bud('1200') AND pg_temp.g('budget', '{"campaign_id": "24283129095", "daily_budget": 1200}')->>0 LIKE '%monthly limit of 500%',
  'BB14 a raise that could break the monthly limit is refused');
SELECT pg_temp.ok(pg_temp.bud('800'), 'BB15 lowering the budget is always allowed, even over the limits');
UPDATE public.ads_config SET value = '40000' WHERE key = 'google_cap_monthly';
SELECT pg_temp.ok(NOT pg_temp.bud('1400') AND NOT pg_temp.bud('500'), 'BB16 more than 30% up or down in one step is refused');
SELECT pg_temp.ok(NOT pg_temp.bud('0') AND NOT pg_temp.bud('-100') AND NOT pg_temp.bud('"abc"') AND NOT pg_temp.bud('"NaN"') AND NOT pg_temp.bud('null')
  AND NOT pg_temp.bud('1000') AND NOT pg_temp.bud('999999999999') AND NOT pg_temp.bud('1100.555'),
  'BB17 zero, negative, text, NaN, empty, the same amount, an absurd amount or 3 decimals: refused');
UPDATE public.ads_campaigns SET budget_ref = NULL WHERE id = (SELECT camp FROM t8);
SELECT pg_temp.ok(NOT pg_temp.bud('1100'), 'BB18 a campaign whose budget the CRM does not know (shared budget) is not touched');
UPDATE public.ads_campaigns SET budget_ref = 'customers/1112223333/campaignBudgets/9' WHERE id = (SELECT camp FROM t8);
INSERT INTO public.ads_change_queue (campaign_id, kind, after, status, created_by_type) VALUES ((SELECT camp FROM t8), 'budget', '{"daily_budget": 900}', 'verified', 'system');
SELECT pg_temp.ok(NOT pg_temp.bud('1100'), 'BB19 the Spend Guard or the owner changed this budget today: the agent waits a day');
DELETE FROM public.ads_change_queue;
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES ((SELECT acc FROM t8), 'budget', '{"campaign_id": "24283129095", "daily_budget": 1100}', 'agent');
SELECT pg_temp.ok(NOT pg_temp.bud('1200'), 'BB20 one budget change per campaign per day');
SET ROLE service_role;
SELECT pg_temp.ok((SELECT w->'payload'->>'budget_resource' = 'customers/1112223333/campaignBudgets/9' AND w->'payload'->>'daily_budget' = '1100'
  FROM jsonb_array_elements(public.svc_ads_google_op_work()) w), 'BB21 the executor is given the budget''s own Google resource by the CRM');
RESET ROLE;
UPDATE public.ads_google_ops SET status = 'executing' WHERE kind = 'budget';
UPDATE public.ads_google_ops SET status = 'verified' WHERE kind = 'budget';
SELECT pg_temp.ok((SELECT daily_budget = 1100 FROM public.ads_campaigns WHERE id = (SELECT camp FROM t8)),
  'BB22 once Google confirms, the CRM knows the new budget at once (limits are checked against it, not a stale copy)');
UPDATE public.ads_google_ops SET status = 'failed' WHERE kind = 'budget';
UPDATE public.ads_campaigns SET daily_budget = 1000 WHERE id = (SELECT camp FROM t8);
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type, status) VALUES ((SELECT acc FROM t8), 'budget', '{"campaign_id": "24283129095", "daily_budget": 1250}', 'agent', 'executing');
UPDATE public.ads_google_ops SET status = 'failed' WHERE status = 'executing';
SELECT pg_temp.ok((SELECT daily_budget = 1000 FROM public.ads_campaigns WHERE id = (SELECT camp FROM t8)), 'BB23 a budget change Google refused does not alter the CRM''s number');
DELETE FROM public.ads_google_ops;
UPDATE public.ads_config SET value = 'off' WHERE key = 'autopilot_google';
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES ((SELECT acc FROM t8), 'budget', '{"campaign_id": "24283129095", "daily_budget": 1100}', 'agent');
SELECT pg_temp.ok((SELECT status = 'pending' FROM public.ads_google_ops), 'BB24 in "Ask me" mode a budget change waits for approval');
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES ((SELECT acc FROM t8), 'budget', '{"campaign_id": "24283129095", "daily_budget": 5000}', 'agent');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_google_ops WHERE status = 'blocked' AND payload->>'daily_budget' = '5000'), 'BB25 an agent asking for 5x the budget is stored as blocked, never sent');
DELETE FROM public.ads_google_ops;
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
SELECT pg_temp.ok((SELECT jsonb_array_length(c->'problems') = 0 AND jsonb_array_length(c->'ops') = 2 FROM (SELECT crm_private.ads_agent_check(
  '{"ops": [{"kind": "cpc_cap", "payload": {"campaign_id": "24283129095", "max_cpc": 24}}, {"kind": "budget", "payload": {"campaign_id": "24283129095", "daily_budget": 1100}}]}') c) z),
  'BB26 a Builder proposal with a bid and a budget change inside the limits passes the code checks');
SELECT pg_temp.ok((SELECT (c->'problems'->>0) LIKE '%above the daily limit%' FROM (SELECT crm_private.ads_agent_check(
  '{"ops": [{"kind": "budget", "payload": {"campaign_id": "24283129095", "daily_budget": 1290}}]}') c) z) IS NOT TRUE
  AND (SELECT jsonb_array_length(c->'problems') > 0 FROM (SELECT crm_private.ads_agent_check(
  '{"ops": [{"kind": "budget", "payload": {"campaign_id": "24283129095", "daily_budget": 9000}}]}') c) z),
  'BB27 a Builder proposal above the limits is sent back to the Builder with the reason');
UPDATE public.ads_config SET value = '{"enquiry": "7700001"}' WHERE key = 'google_conv_actions';
SELECT pg_temp.ok(NOT pg_temp.ok0('conversion_goal', '{"conversion_action_id": "7700001", "primary": false}') AND pg_temp.ok0('conversion_goal', '{"conversion_action_id": "123", "primary": false}'),
  'BB28 agents cannot switch off the conversion action the CRM itself reports to');
UPDATE public.ads_config SET value = '{}' WHERE key = 'google_conv_actions';

-- ================================================================ AU: the 24-hour rule
INSERT INTO st9 SELECT 'fresh', pg_temp.sug('Fresh', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('cabin crew'))), 'done', '2 hours');
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'fresh')) BETWEEN now() + interval '21 hours' AND now() + interval '23 hours'
  AND jsonb_array_length(pg_temp.auto()->'applied') = 0 AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'fresh'))).status = 'open',
  'AU01 a 2-hour-old suggestion waits: it will be applied 24 hours after it was written, not now');
INSERT INTO st9 SELECT 'pick', pg_temp.sug('Two options', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('air hostess', 'block'), pg_temp.neg('bba aviation', 'other')),
  'options', '[{"id": "block", "label": "Block", "selected": true}, {"id": "other", "label": "Other", "selected": false}]'::jsonb));
SELECT pg_temp.auto();
SELECT pg_temp.ok((pg_temp.sg((SELECT v FROM st9 WHERE k = 'pick'))).status = 'accepted' AND (SELECT count(*) = 1 AND bool_and(status = 'approved' AND summary = 'Block air hostess')
  FROM public.ads_google_ops), 'AU02 after 24 hours with no answer only the agents'' recommended option is applied');
SELECT pg_temp.ok((pg_temp.sg((SELECT v FROM st9 WHERE k = 'pick'))).user_note LIKE 'No answer in time%' AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'pick'))).decided_by IS NULL
  AND EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'team_lead' AND job = 'auto_apply' AND summary LIKE '%Two options%applied the recommended option (1 change(s))%'),
  'AU03 it is recorded as applied by the Team Lead (not by a person) and shows in Activity');
SELECT pg_temp.auto(); SELECT pg_temp.auto();
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_google_ops) = 1, 'AU04 running again and again never applies it twice');
DELETE FROM public.ads_google_ops;
INSERT INTO st9 SELECT 'wait', pg_temp.sug('Recommended: wait', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('ground staff', 'block')),
  'options', '[{"id": "block", "label": "Block now"}, {"id": "wait", "label": "Wait", "selected": true}]'::jsonb));
SELECT pg_temp.auto();
SELECT pg_temp.ok((pg_temp.sg((SELECT v FROM st9 WHERE k = 'wait'))).status = 'accepted' AND (SELECT count(*) FROM public.ads_google_ops) = 0
  AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'wait'))).user_note LIKE '%change nothing%', 'AU05 the recommendation was "wait": it is closed and NOTHING is changed');
INSERT INTO st9 SELECT 'all', pg_temp.sug('No options', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('salary'), pg_temp.neg('jobs'), 'junk', 5)));
SELECT pg_temp.auto();
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_google_ops) = 2, 'AU06 a suggestion without options applies all its changes (junk entries are skipped)');
DELETE FROM public.ads_google_ops;
INSERT INTO st9 SELECT 'none', pg_temp.sug('No recommendation', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('free course', 'a')),
  'options', '[{"id": "a", "label": "A"}, {"id": "b", "label": "B", "selected": "true"}]'::jsonb));
INSERT INTO st9 SELECT 'rejected', pg_temp.sug('Needs your decision: x', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('scholarship'))), 'escalated');
INSERT INTO st9 SELECT 'norev', pg_temp.sug('Never reviewed', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('cadet'))), NULL);
INSERT INTO st9 SELECT 'running', pg_temp.sug('Review not finished', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('indigo'))), 'running');
INSERT INTO st9 SELECT 'info', pg_temp.sug('Check the website form', '{"ops": [], "options": [{"id": "t", "label": "Test it", "selected": true}]}');
INSERT INTO st9 SELECT 'malformed', pg_temp.sug('Malformed', '{"ops": "all of them", "options": 7}');
SELECT pg_temp.auto();
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_google_ops) = 0 AND (SELECT bool_and(pg_temp.auto_at(v) IS NULL AND (pg_temp.sg(v)).status = 'open')
  FROM st9 WHERE k IN ('none', 'rejected', 'norev', 'running', 'info', 'malformed')),
  'AU07 never by itself: no recommended option, a proposal the Reviewer rejected, one never or not yet reviewed, nothing to apply, malformed content');
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
INSERT INTO st9 SELECT 'stop', pg_temp.sug('During emergency stop', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('mba'))));
SELECT pg_temp.ok(pg_temp.auto()->>'skipped' LIKE '%Emergency stop%' AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'stop'))).status = 'open',
  'AU08 emergency stop: nothing is applied, however old the suggestion');
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'off' WHERE key = 'autopilot_google';
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'stop')) IS NULL AND jsonb_array_length(pg_temp.auto()->'applied') = 0, 'AU09 "Ask me" mode: suggestions wait for the owner for ever');
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_config SET value = '' WHERE key = 'suggest_auto_hours';
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'stop')) IS NULL, 'AU10 the rule switched off (empty hours): nothing by itself');
UPDATE public.ads_config SET value = '0' WHERE key = 'suggest_auto_hours';
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'stop')) IS NULL, 'AU11 0 hours does not mean "at once": it means off');
UPDATE public.ads_config SET value = 'soon; DROP TABLE' WHERE key = 'suggest_auto_hours';
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'stop')) IS NULL AND jsonb_array_length(pg_temp.auto()->'applied') = 0, 'AU12 a nonsense setting is treated as off, no error');
UPDATE public.ads_config SET value = '24' WHERE key = 'suggest_auto_hours';
UPDATE public.ads_config SET value = now()::text WHERE key = 'suggest_auto_since';
SELECT pg_temp.ok(pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'stop')) > now() + interval '23 hours' AND jsonb_array_length(pg_temp.auto()->'applied') = 0,
  'AU13 suggestions written before the rule existed get a full 24 hours from the day the rule started');
UPDATE public.ads_config SET value = (now() - interval '30 days')::text WHERE key = 'suggest_auto_since';
SET ROLE authenticated; SELECT pg_temp.as_('d');
SELECT public.api_ads_suggestion_decide((SELECT v FROM st9 WHERE k = 'stop'), 'dismiss', 'no');
RESET ROLE;
SELECT pg_temp.ok(jsonb_array_length(pg_temp.auto()->'applied') = 0 AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'stop'))).status = 'dismissed' AND (SELECT count(*) FROM public.ads_google_ops) = 0,
  'AU14 the owner said no in time: it is never applied afterwards');
INSERT INTO st9 SELECT 'blocked', pg_temp.sug('Would block a core search', jsonb_build_object('ops', jsonb_build_array(pg_temp.neg('pilot training'), pg_temp.neg('ielts'))));
SELECT pg_temp.auto();
SELECT pg_temp.ok((SELECT count(*) FILTER (WHERE status = 'blocked') = 1 AND count(*) FILTER (WHERE status = 'approved') = 1 FROM public.ads_google_ops)
  AND EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE job = 'auto_apply' AND summary LIKE '%1 stopped by the safety checks%'),
  'AU15 the safety checks still apply at that moment: a change that would block "pilot training" is stopped, the rest goes through');
DELETE FROM public.ads_google_ops;
INSERT INTO st9 SELECT 'badkind', pg_temp.sug('Operation type that does not exist', '{"ops": [{"kind": "delete_account", "payload": {}}]}');
SELECT pg_temp.auto(); SELECT pg_temp.auto();
SELECT pg_temp.ok((pg_temp.sg((SELECT v FROM st9 WHERE k = 'badkind'))).status = 'open' AND (pg_temp.sg((SELECT v FROM st9 WHERE k = 'badkind'))).result ? 'auto_error'
  AND pg_temp.auto_at((SELECT v FROM st9 WHERE k = 'badkind')) IS NULL AND (SELECT count(*) FROM public.ads_google_ops) = 0,
  'AU16 a suggestion that cannot be applied is left for the owner and not tried again every 5 minutes');
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok((SELECT (s->>'auto_at')::timestamptz > now() FROM jsonb_array_elements(public.api_ads_autopilot()->'suggestions') s WHERE (s->>'id')::bigint = (SELECT v FROM st9 WHERE k = 'fresh'))
  AND (SELECT s->'auto_at' = 'null'::jsonb FROM jsonb_array_elements(public.api_ads_autopilot()->'suggestions') s WHERE (s->>'id')::bigint = (SELECT v FROM st9 WHERE k = 'info')),
  'AU17 the screen is told when each suggestion will be applied by itself, or that it never will');
SELECT pg_temp.fails('SELECT public.svc_ads_suggestions_auto()', '%permission denied%', 'AU18 nobody can trigger the rule from the browser');
RESET ROLE;
SELECT pg_temp.ok((SELECT bool_and((o->>'selected')::boolean) AND count(*) = 2 FROM jsonb_array_elements((SELECT crm_private.ads_agent_check(
  '{"ops": [{"kind": "campaign_geo", "summary": "Add Gurugram", "payload": {"campaign_id": "24283129095", "add": ["1007753"]}},
            {"kind": "campaign_geo", "summary": "Presence only", "payload": {"campaign_id": "24283129095", "target_type": "PRESENCE"}}]}')->'suggestions'->0->'proposal'->'options')) o),
  'AU19 location changes the agents propose are marked as recommended, so they too go ahead after 24 hours');
DELETE FROM public.ads_autopilot_suggestions; DELETE FROM public.ads_agent_runs; DELETE FROM public.ads_google_ops;

-- ================================================================ TL: the Team Lead
SELECT pg_temp.tick();
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(job = 'desk_extensions') FROM public.ads_agent_runs WHERE status = 'queued'),
  'TL01 no ad spend to look at: only a desk that needs no new data starts (Extensions); the others wait');
DELETE FROM public.ads_agent_runs;
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, clicks) SELECT camp, today - g, 200, 20 FROM t8, generate_series(1, 5) g;
SELECT pg_temp.tick();
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(job = 'desk_search_terms' AND role = 'researcher' AND input->>'desk' = 'search_terms'
  AND input->>'goal' LIKE 'You are the Search Terms desk%' AND input->>'title' = 'Search Terms') FROM public.ads_agent_runs),
  'TL02 with spend to look at, the first specialist starts with its own brief (Search Terms)');
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0 AND (SELECT count(*) FROM public.ads_agent_runs) = 1, 'TL03 one desk at a time: nothing else starts while it works');
UPDATE public.ads_agent_runs SET status = 'done', finished_at = now();
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL04 a desk just finished: the next one waits (2 hours apart), so the Claude plan is not used up in a burst');
UPDATE public.ads_agent_runs SET created_at = now() - interval '3 hours';
SELECT pg_temp.tick();
SELECT pg_temp.ok((SELECT job FROM public.ads_agent_runs ORDER BY id DESC LIMIT 1) = 'desk_keywords', 'TL05 3 hours later the next specialist starts (Keywords)');
UPDATE public.ads_agent_runs SET status = 'done', created_at = now() - interval '3 hours' WHERE status = 'queued';
SELECT pg_temp.tick();
UPDATE public.ads_agent_runs SET status = 'done', created_at = now() - interval '3 hours' WHERE status = 'queued';
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_agent_runs) = 3 AND (pg_temp.tick()->>'started')::int = 0,
  'TL06 at most 3 desk runs in 24 hours, even if more are due');
UPDATE public.ads_config SET value = 'lots' WHERE key = 'agents_chains_per_day';
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL07 a nonsense daily cap falls back to 3');
UPDATE public.ads_config SET value = '3' WHERE key = 'agents_chains_per_day';
INSERT INTO public.ads_agent_instructions (account_id, body, via) VALUES ((SELECT acc FROM t8), 'Pause the ad about hostels', 'typed');
SELECT pg_temp.tick();
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(job = 'instruction') FROM public.ads_agent_runs WHERE status = 'queued'),
  'TL08 the owner''s own instruction always starts, whatever the daily cap');
DELETE FROM public.ads_agent_runs; DELETE FROM public.ads_agent_instructions;
INSERT INTO public.ads_agent_runs (account_id, role, job, status, created_at) SELECT (SELECT acc FROM t8), 'researcher', 'desk_' || d.key, 'done', now() - interval '26 hours'
  FROM public.ads_agent_desks d WHERE d.kind = 'agent';
UPDATE public.ads_metrics_daily SET day = day - 10;
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL09 Search Terms is due by the clock, but nothing new was spent since it last ran: it does not run for nothing');
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, clicks) SELECT camp, today, 150, 12 FROM t8;
SELECT pg_temp.tick();
SELECT pg_temp.ok((SELECT job FROM public.ads_agent_runs WHERE status = 'queued') = 'desk_search_terms', 'TL10 150 of new spend: Search Terms runs again; weekly desks are not due yet');
DELETE FROM public.ads_agent_runs WHERE status = 'queued';
UPDATE public.ads_agent_desks SET enabled = false WHERE key = 'search_terms';
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL11 a desk that is switched off never runs');
UPDATE public.ads_agent_desks SET enabled = true WHERE key = 'search_terms';
UPDATE public.ads_config SET value = 'off' WHERE key = 'agents_daily_review';
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL12 the team switched off: no desk starts');
UPDATE public.ads_config SET value = 'on' WHERE key = 'agents_daily_review';
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
SELECT pg_temp.ok((pg_temp.tick()->>'started')::int = 0, 'TL13 emergency stop: no desk starts');
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok((SELECT count(*) = 14 AND count(*) FILTER (WHERE m->>'kind' = 'agent') = 7 AND bool_and(length(m->>'does') > 20) FROM jsonb_array_elements(public.api_ads_autopilot_status()->'team') m),
  'TL14 the CRM lists the whole team: 7 specialists and 7 always-on members, each with what it does');
SELECT pg_temp.ok((SELECT m->'last'->>'status' = 'done' AND (m->>'next_at')::timestamptz < now() AND m->'waiting_for_spend' = 'null'::jsonb
    FROM jsonb_array_elements(public.api_ads_autopilot_status()->'team') m WHERE m->>'key' = 'search_terms')
  AND (SELECT (m->>'waiting_for_spend')::numeric = 150 AND (m->>'next_at')::timestamptz < now() + interval '2 days'
    FROM jsonb_array_elements(public.api_ads_autopilot_status()->'team') m WHERE m->>'key' = 'keywords'),
  'TL15 ... with when each last worked, when it works next, and how much more spend it is waiting for');
RESET ROLE; UPDATE public.ads_config SET value = (now() - interval '40 minutes')::text WHERE key = 'agents_last_seen'; SET ROLE authenticated;
SELECT pg_temp.ok((SELECT NOT (a->>'online')::boolean AND (a->>'healthy')::boolean FROM (SELECT public.api_ads_autopilot_status()->'agents' a) z),
  'TL18 the hourly cloud runner checked in 40 minutes ago: not "online" this second, but on schedule (no false alarm)');
RESET ROLE; UPDATE public.ads_config SET value = (now() - interval '3 hours')::text WHERE key = 'agents_last_seen'; SET ROLE authenticated;
SELECT pg_temp.ok((SELECT NOT (a->>'online')::boolean AND NOT (a->>'healthy')::boolean FROM (SELECT public.api_ads_autopilot_status()->'agents' a) z),
  'TL19 no check-in for 3 hours: the agents are reported as not working');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT public.api_ads_autopilot_status()', '%do not have access%', 'TL16 people without ADS access cannot see the team');
SELECT pg_temp.fails('SELECT * FROM public.ads_agent_desks', '%permission denied%', 'TL17 the briefs cannot be read or changed from the browser');
RESET ROLE;
DELETE FROM public.ads_agent_runs;

-- ================================================================ CV: telling Google which clicks became enquiries
SELECT pg_temp.click('Granted Person', '9811300001', '24283129095', '{"consent": {"ad_data_sharing": true, "notice_version": "v1"}}');
SELECT pg_temp.click('Denied Person', '9811300002', '24283129095', '{"consent": {"ad_data_sharing": false, "notice_version": "v1"}}');
SELECT pg_temp.click('Silent Person', '9811300003', '24283129095');
SELECT pg_temp.ok(pg_temp.q() = 0, 'CV01 an enquiry less than 30 minutes old is not reported yet (spam checks come first)');
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE deleted_at IS NULL;
SELECT pg_temp.ok(pg_temp.q() = 1 AND (SELECT count(*) = 1 AND bool_and(event = 'enquiry' AND status = 'pending') FROM pg_temp.ups()),
  'CV02 only the person who allowed ad data sharing is queued; "no" and "did not answer" are never reported');
SET ROLE service_role;
SELECT pg_temp.ok((SELECT w->'account'->>'external_id' IS NOT NULL AND jsonb_array_length(w->'missing') = 3 AND jsonb_array_length(w->'items') = 1
  AND w->'items'->0->>'gclid' = 'Cj0-9811300001' AND w->'items'->0->>'at' ~ '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\+00:00$'
  AND w->'items'->0->>'order_id' LIKE '%:enquiry' AND w::text NOT LIKE '%Granted%' AND w::text NOT LIKE '%+919811300001%' AND w::text NOT LIKE '%landing_page%' FROM (SELECT public.svc_ads_conversions_work() w) z),
  'CV03 the reporter gets the click id, the time and a dedupe id; no name and no phone number');
SELECT public.svc_ads_conversion_action_save('enquiry', '7700001'); SELECT public.svc_ads_conversion_action_save('qualified', '7700002');
SELECT public.svc_ads_conversion_action_save('customer', '7700003'); SELECT public.svc_ads_conversion_action_save('enquiry', 'abc; DROP');
SELECT public.svc_ads_conversion_action_save('refund', '7700009');
SELECT pg_temp.ok((SELECT w->'actions' = '{"enquiry": "7700001", "qualified": "7700002", "customer": "7700003"}'::jsonb AND jsonb_array_length(w->'missing') = 0
  FROM (SELECT public.svc_ads_conversions_work() w) z), 'CV04 the 3 Google conversion actions are created once and remembered; junk ids and unknown events are ignored');
SELECT public.svc_ads_conversion_finish((SELECT id FROM pg_temp.ups() LIMIT 1), 'retry', 'TOO_RECENT_CONVERSION_ACTION: wait');
SELECT pg_temp.ok((SELECT status = 'pending' AND attempts = 1 AND error LIKE 'TOO_RECENT%' FROM pg_temp.ups()) AND jsonb_array_length(public.svc_ads_conversions_work()->'items') = 0,
  'CV05 Google says "too recent": it stays queued and is tried again later, not in a loop');
RESET ROLE; UPDATE public.ads_conversion_uploads SET last_try_at = now() - interval '4 hours'; SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_conversions_work()->'items') = 1, 'CV06 3 hours later it is due again');
SELECT public.svc_ads_conversion_finish((SELECT id FROM pg_temp.ups() LIMIT 1), 'sent', NULL);
SELECT public.svc_ads_conversion_finish((SELECT id FROM pg_temp.ups() LIMIT 1), 'failed', 'late answer');
SELECT pg_temp.ok((SELECT status = 'sent' AND sent_at IS NOT NULL AND error IS NULL AND attempts = 2 FROM pg_temp.ups()) AND pg_temp.q() = 0
  AND jsonb_array_length(public.svc_ads_conversions_work()->'items') = 0, 'CV07 once Google has it, it is never sent again, and a late second answer cannot change that');
RESET ROLE;
UPDATE public.ads_lead SET stage = 'qualified' WHERE name = 'Granted Person';
INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, at) SELECT id, 'lead_created', 'qualified', now() - interval '1 hour' FROM public.ads_lead WHERE name = 'Granted Person';
SELECT pg_temp.ok(pg_temp.q() = 1 AND (SELECT happened_at BETWEEN now() - interval '61 minutes' AND now() - interval '59 minutes' FROM pg_temp.ups() WHERE event = 'qualified'),
  'CV08 when sales marks the lead Qualified, that is reported too, with the time it happened');
UPDATE public.ads_lead SET stage = 'admission_completed' WHERE name = 'Granted Person';
SELECT pg_temp.ok(pg_temp.q() = 2 AND (SELECT count(*) = 3 FROM pg_temp.ups()) AND (SELECT happened_at >= (SELECT created_at FROM public.ads_lead WHERE name = 'Granted Person')
  FROM pg_temp.ups() WHERE event = 'customer'), 'CV09 an admission is reported as well (never dated before the enquiry itself)');
SET ROLE service_role;
DO $$ BEGIN FOR i IN 1..12 LOOP
  UPDATE public.ads_conversion_uploads SET last_try_at = NULL WHERE event = 'qualified';
  PERFORM public.svc_ads_conversion_finish((SELECT id FROM public.ads_conversion_uploads WHERE event = 'qualified'), 'retry', 'EVENT_NOT_FOUND: click not found');
END LOOP; END $$;
SELECT public.svc_ads_conversion_finish((SELECT id FROM pg_temp.ups() WHERE event = 'customer'), 'failed', 'EXPIRED_EVENT: too old');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'failed' AND attempts = 12 FROM pg_temp.ups() WHERE event = 'qualified') AND (SELECT status = 'failed' AND error LIKE 'EXPIRED%' FROM pg_temp.ups() WHERE event = 'customer'),
  'CV10 after 12 tries, or on a final refusal, it stops trying and keeps Google''s reason');
SELECT pg_temp.click('Changed Mind', '9811300004', '24283129095', '{"consent": {"ad_data_sharing": true, "notice_version": "v1"}}');
SELECT pg_temp.click('Changed Mind', '9811300004', '24283129095', '{"consent": {"ad_data_sharing": false, "notice_version": "v2"}, "submission_id": "second"}');
SELECT pg_temp.click('Wrong Number', '9811300005', '24283129095', '{"consent": {"ad_data_sharing": true}}');
SELECT pg_temp.click('Spam Bot', '9811300006', '24283129095', '{"consent": {"ad_data_sharing": true}}');
SELECT pg_temp.click('Too Old', '9811300007', '24283129095', '{"consent": {"ad_data_sharing": true}}');
SELECT public.svc_ads_ingest_enquiry('{"name": "No Click Id", "phone": "9811300008", "utm_source": "google", "utm_medium": "cpc", "submission_id": "nc", "consent": {"ad_data_sharing": true}}', 'pilot_training');
SELECT public.svc_ads_ingest_enquiry('{"name": "Meta Person", "phone": "9811300009", "fbclid": "IwAR", "submission_id": "mp", "consent": {"ad_data_sharing": true}}', 'pilot_training');
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE deleted_at IS NULL AND created_at > now() - interval '30 minutes';
UPDATE public.ads_lead SET contact_status = 'wrong_number' WHERE name = 'Wrong Number';
UPDATE public.ads_lead SET quarantined = true WHERE name = 'Spam Bot';
UPDATE public.ads_lead SET created_at = now() - interval '86 days' WHERE name = 'Too Old';
SELECT pg_temp.ok(pg_temp.q() = 0 AND (SELECT count(*) = 3 FROM pg_temp.ups()),
  'CV11 not reported: a person who later withdrew permission, a wrong number, spam, a click older than Google''s window, an enquiry with no click id, a Meta click');
SELECT pg_temp.click('Deleted Later', '9811300010', '24283129095', '{"consent": {"ad_data_sharing": true}}');
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE name = 'Deleted Later';
SELECT pg_temp.q();
UPDATE public.ads_lead SET deleted_at = now() WHERE name = 'Deleted Later';
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_conversions_work()->'items') = 0, 'CV12 a lead deleted while waiting in the queue is not sent');
RESET ROLE;
UPDATE public.ads_lead SET deleted_at = NULL WHERE name = 'Deleted Later';
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
SET ROLE service_role;
SELECT pg_temp.ok((SELECT w->'account' = 'null'::jsonb AND jsonb_array_length(w->'items') = 0 FROM (SELECT public.svc_ads_conversions_work() w) z), 'CV13 emergency stop: nothing is reported');
RESET ROLE;
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_config SET value = 'off' WHERE key = 'google_conv_upload';
SELECT pg_temp.ok(pg_temp.q() = 0 AND NOT (SELECT crm_private.ads_conversions_wake()), 'CV14 reporting switched off: nothing is queued and the reporter is not woken');
UPDATE public.ads_config SET value = 'on' WHERE key = 'google_conv_upload';
SELECT pg_temp.ok((SELECT crm_private.ads_conversions_wake()), 'CV15 something is waiting: the reporter is woken');
UPDATE public.ads_conversion_uploads SET status = 'sent' WHERE status = 'pending';
SELECT pg_temp.ok(NOT (SELECT crm_private.ads_conversions_wake()), 'CV16 nothing waiting and the conversion actions exist: the reporter sleeps (no pointless calls)');
UPDATE public.ads_config SET value = 'not json' WHERE key = 'google_conv_actions';
SELECT pg_temp.ok((SELECT crm_private.ads_conversions_wake()) AND (SELECT crm_private.ads_conversion_actions()) = '{}'::jsonb, 'CV17 a damaged setting is treated as "not created yet", no error');
UPDATE public.ads_config SET value = '{"enquiry": "7700001", "qualified": "7700002", "customer": "7700003"}' WHERE key = 'google_conv_actions';
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.fails('SELECT public.svc_ads_conversions_work()', '%permission denied%', 'CV18 even an Admin''s browser cannot fetch click ids');
SELECT pg_temp.fails('SELECT * FROM public.ads_conversion_uploads', '%permission denied%', 'CV19 the report queue is not readable from the browser');
SELECT pg_temp.ok((SELECT m->'last'->>'summary' LIKE '%reported to Google%' FROM jsonb_array_elements(public.api_ads_autopilot_status()->'team') m WHERE m->>'key' = 'lead_quality'),
  'CV20 the Team list shows how many enquiries Lead Quality has reported');
RESET ROLE;

-- ================================================================ TR: tracking
DELETE FROM public.ads_metrics_daily;
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, clicks) SELECT camp, today - g, 200, 30 FROM t8, generate_series(1, 6) g;
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT (t->>'clicks_7d')::int = 180 AND (t->>'enquiries_7d')::int = 0 AND t->'problems'->>0 LIKE '180 ad clicks%not one enquiry%' FROM (SELECT public.svc_ads_tracking_check() t) z),
  'TR01 180 clicks in a week and not one enquiry: Tracking raises the alarm (the form may be broken)');
SELECT public.svc_ads_tracking_check();
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(summary LIKE 'Tracking:%2 enquiry report(s) to Google were not accepted%') FROM public.ads_agent_runs WHERE role = 'tracking'),
  'TR02 the alarm (with the failed reports to Google) is written once a day, not on every check');
DELETE FROM public.ads_agent_runs; DELETE FROM public.ads_conversion_uploads;
UPDATE public.ads_lead SET deleted_at = NULL, created_at = now() - interval '2 days' WHERE name = 'Granted Person';
SET ROLE service_role;
SELECT pg_temp.ok((SELECT jsonb_array_length(t->'problems') = 0 AND (t->>'enquiries_7d')::int = 1 FROM (SELECT public.svc_ads_tracking_check() t) z)
  AND NOT EXISTS (SELECT 1 FROM pg_temp.ups() WHERE false), 'TR03 clicks and enquiries both arriving: no alarm');
RESET ROLE;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'tracking'), 'TR04 ... and nothing is written when all is well');
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.fails('SELECT public.svc_ads_tracking_check()', '%permission denied%', 'TR05 the check runs on the server only');
RESET ROLE;
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;

\echo ALL ADS TEAM TESTS PASSED
