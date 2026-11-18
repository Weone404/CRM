-- 110: Automate: quick actions (AC01-07), rules (RU01-05), A/B tests (AB01-05). Runs after A8_.
RESET ROLE;
-- two ad sets with ads, 7 days of numbers, and archived leads (B gets the qualified ones)
INSERT INTO public.ads_meta_object (account_id, level, external_id, campaign_ext, adset_ext, name, status) VALUES
  ((crm_private.ads_meta_acct()).id, 'campaign', '9911000', NULL, NULL, 'Auto test campaign', 'ACTIVE'),
  ((crm_private.ads_meta_acct()).id, 'adset', '9911001', '9911000', NULL, 'Auto A Delhi', 'ACTIVE'),
  ((crm_private.ads_meta_acct()).id, 'adset', '9911002', '9911000', NULL, 'Auto B Delhi', 'ACTIVE'),
  ((crm_private.ads_meta_acct()).id, 'ad', '9912001', '9911000', '9911001', 'Auto ad A', 'ACTIVE'),
  ((crm_private.ads_meta_acct()).id, 'ad', '9912002', '9911000', '9911002', 'Auto ad B', 'ACTIVE')
ON CONFLICT DO NOTHING;
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, link_clicks, leads, frequency)
SELECT (crm_private.ads_meta_acct()).id, ad, st, '9911000', crm_private.ads_meta_today() - g, sp, 20000, 300, 200, ld, fq
  FROM (VALUES ('9912001', '9911001', 1000, 2, 4.2), ('9912002', '9911002', 1000, 6, 1.6)) v(ad, st, sp, ld, fq), generate_series(1, 7) g
ON CONFLICT DO NOTHING;
UPDATE public.ads_meta_lead_archive SET ad_id = '9912002', adset_id = '9911002', campaign_id = '9911000', created_time = now() - interval '3 days'
 WHERE external_id IN (SELECT external_id FROM public.ads_meta_lead_archive WHERE answers->>'class12' = 'Yes' AND source = 'csv' ORDER BY external_id LIMIT 12);
UPDATE public.ads_meta_lead_archive SET ad_id = '9912001', adset_id = '9911001', campaign_id = '9911000', created_time = now() - interval '3 days'
 WHERE external_id IN (SELECT external_id FROM public.ads_meta_lead_archive WHERE answers->>'class12' = 'No' AND source = 'csv' ORDER BY external_id LIMIT 12);

SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '9911001', 'pause', '{}', 'x')$q$, '%Only approvers%', 'AC01 viewers cannot ask for changes');
SELECT pg_temp.ok((SELECT (x->>'spend')::numeric = 7000 AND (x->>'leads')::int = 14 AND (x->>'cpl')::numeric = 500 FROM jsonb_array_elements(public.api_ads_meta_objects('adset', 7)) x WHERE x->>'id' = '9911001')
  AND (SELECT (x->>'qualified')::int >= 10 AND (x->>'cpql')::numeric > 0 FROM jsonb_array_elements(public.api_ads_meta_objects('adset', 7)) x WHERE x->>'id' = '9911002'),
  'AC02 the quick-action table shows spend, leads, cost per lead, qualified and cost per qualified per ad set');
SELECT pg_temp.as_('d');
CREATE TEMP TABLE ac AS SELECT public.api_ads_meta_action_request('adset', '9911001', 'budget', '{"pct": 30}', 'test') v;
GRANT SELECT ON ac TO authenticated;
SELECT pg_temp.ok((SELECT (v->>'id')::bigint > 0 AND v->'guard' ->> 0 LIKE 'A 30% change is a big edit%' AND (v->>'self_approve')::boolean FROM ac),
  'AC03 an approver asks; a 20%+ budget change carries the learning-phase warning');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '9911001', 'budget', '{"pct": 10}', 'again')$q$, '%already waiting%', 'AC04 one open request per object and change');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('ad', '9912001', 'budget', '{"daily": 500}', 'x')$q$, '%no budget of their own%', 'AC04b ads have no budget');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '9911002', 'budget', '{"pct": 150}', 'x')$q$, '%needs Admin%', 'AC04c more than +100% needs Admin');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '9911002', 'budget', '{"daily": 50}', 'x')$q$, '%between ₹100 and ₹50000%', 'AC04d the daily budget floor and ceiling hold');
SELECT public.api_ads_meta_action_decide((SELECT (v->>'id')::bigint FROM ac), true, NULL);
SELECT public.api_ads_meta_action_request('ad', '9912001', 'pause', '{}', 'test');
RESET ROLE; UPDATE public.ads_config SET value = 'true' WHERE key = 'meta_actions_two_person';
CREATE TEMP TABLE pid AS SELECT id FROM public.ads_meta_action WHERE object_id = '9912001' AND kind = 'pause';
GRANT SELECT ON pid TO authenticated;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_decide((SELECT id FROM pid), true, NULL)$q$,
  '%Another approver%', 'AC05 with two-person approval, nobody approves their own request');
RESET ROLE; UPDATE public.ads_config SET value = 'false' WHERE key = 'meta_actions_two_person';
UPDATE public.ads_config SET value = 'true' WHERE key = 'meta_paused';
SET ROLE service_role;
SELECT pg_temp.ok((SELECT (v->>'paused')::boolean AND jsonb_array_length(v->'items') = 0 FROM public.svc_ads_meta_action_work() v), 'AC06 nothing runs while the Meta emergency stop is on');
RESET ROLE; UPDATE public.ads_config SET value = 'false' WHERE key = 'meta_paused'; SET ROLE service_role;
CREATE TEMP TABLE aw2 AS SELECT public.svc_ads_meta_action_work() v;
SELECT public.svc_ads_meta_action_done((SELECT (x->>'id')::bigint FROM aw2, jsonb_array_elements(v->'items') x LIMIT 1), 'done', '{"daily_budget": 1000}', '{"daily_budget": 1300}', NULL);
RESET ROLE;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'items') = 1 AND v->'items'->0->>'kind' = 'budget' AND v->'items'->0->'params'->>'pct' = '30' FROM aw2)
  AND (SELECT status = 'done' AND after->>'daily_budget' = '1300' AND executed_at IS NOT NULL FROM public.ads_meta_action WHERE object_id = '9911001' AND kind = 'budget')
  AND (SELECT status = 'pending' FROM public.ads_meta_action WHERE object_id = '9912001' AND kind = 'pause'),
  'AC07 only approved requests run; the result (before and after) is kept');
UPDATE public.ads_meta_action SET status = 'cancelled' WHERE object_id = '9912001' AND kind = 'pause';

-- rules
UPDATE public.ads_meta_rule SET enabled = true WHERE name LIKE 'Warn when frequency%';
INSERT INTO public.ads_meta_rule (name, enabled, level, name_contains, metric, window_days, op, value, min_spend, min_leads, action, pct, cooldown_days)
VALUES ('Auto: cut ad sets with cost per lead above ₹800', true, 'adset', 'Auto', 'cpl', 7, 'gt', 800, 1000, 0, 'budget_down', 20, 3),
       ('Auto: pause ad sets with cost per qualified above ₹2,000', true, 'adset', 'Auto', 'cpql', 7, 'gt', 2000, 1000, 0, 'pause', NULL, 3);
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_rules_run(NULL)$q$, '%Only approvers%', 'RU01 viewers cannot run rules');
SELECT pg_temp.as_('d');
CREATE TEMP TABLE ru AS SELECT public.api_ads_meta_rules_run(NULL) v;
RESET ROLE;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.ads_meta_action a WHERE a.source = 'rule' AND a.kind = 'budget' AND a.object_id IN ('9911001', '9911002')),
  'RU02 a cost-per-lead rule does not fire below its limit (both ad sets cost ₹500 or less per lead)');
SELECT pg_temp.ok((SELECT a.status = 'pending' AND a.reason LIKE 'Auto A Delhi: cpql is n/a%' FROM public.ads_meta_action a WHERE a.object_id = '9911001' AND a.kind = 'pause' AND a.source = 'rule')
  AND NOT EXISTS (SELECT 1 FROM public.ads_meta_action a WHERE a.object_id = '9911002' AND a.kind = 'pause' AND a.status = 'pending'),
  'RU03 an ad set that spent past the cost-per-qualified limit with no qualified lead is asked to pause; the one with qualified leads is not');
SELECT pg_temp.ok((SELECT count(*) >= 1 FROM public.ads_meta_warning WHERE kind LIKE 'rule\_%' AND entity = '9912001' AND resolved_at IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.ads_meta_warning WHERE kind LIKE 'rule\_%' AND entity = '9912002'),
  'RU04 a warn-only rule raises a warning (frequency 4.2) and nothing else');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT public.api_ads_meta_rules_run(NULL);
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_meta_action WHERE object_id = '9911001' AND kind = 'pause' AND source = 'rule'),
  'RU05 running again never asks twice (open request and cool-down)');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_rule_save('{"name": "x budget", "level": "ad", "metric": "cpl", "op": "gt", "value": "500", "action": "budget_up", "pct": "10"}')$q$, '%Ads have no budget%', 'RU06 budget rules cannot target ads');
SELECT pg_temp.ok((public.api_ads_meta_rule_save('{"name": "New rule", "level": "campaign", "metric": "spend", "op": "gt", "value": "5000", "action": "notify", "window_days": "3"}')->>'id')::bigint > 0,
  'RU07 Admin adds a rule (off until switched on)');

-- A/B tests
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_test_save('{"name": "Tt", "level": "adset", "metric": "cost_per_lead", "start_date": "2026-01-01", "end_date": "2026-01-10", "cells": [{"name": "A", "ids": ["9911001"]}]}')$q$,
  '%2 to 5 cells%', 'AB01 a test has 2 to 5 cells');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_test_save('{"name": "Tt", "level": "adset", "metric": "cost_per_lead", "start_date": "2026-01-01", "end_date": "2026-01-10", "cells": [{"name": "A", "ids": ["9911001"]}, {"name": "B", "ids": ["9911001"]}]}')$q$,
  '%two cells%', 'AB02 an object cannot be in two cells');
SELECT public.api_ads_meta_test_save(jsonb_build_object('name', 'Delhi A vs B', 'level', 'adset', 'metric', 'cost_per_lead', 'variable', 'creative', 'min_results', '10',
  'start_date', (current_date - 7)::text, 'end_date', (current_date + 7)::text,
  'cells', '[{"name": "A", "ids": ["9911001"]}, {"name": "B", "ids": ["9911002"]}]'::jsonb));
SELECT public.api_ads_meta_test_save(jsonb_build_object('name', 'Quality A vs B', 'level', 'adset', 'metric', 'qualified_rate', 'min_results', '10',
  'start_date', (current_date - 7)::text, 'end_date', (current_date + 7)::text,
  'cells', '[{"name": "A", "ids": ["9911001"]}, {"name": "B", "ids": ["9911002"]}]'::jsonb));
CREATE TEMP TABLE ab AS SELECT public.api_ads_meta_tests() v;
SELECT pg_temp.ok((SELECT (x->'result'->'cells'->1->>'leads')::int = 42 AND (x->'result'->'cells'->0->>'value')::numeric = 500
    AND (x->'result'->'cells'->1->>'confidence')::numeric >= 99 AND x->'result'->>'verdict' LIKE 'B wins with%' FROM ab, jsonb_array_elements(v) x WHERE x->>'name' = 'Delhi A vs B'),
  'AB03 cost per lead: B gets 3x the leads on equal spend, so it wins with 99%+ confidence');
SELECT pg_temp.ok((SELECT x->'result'->>'verdict' LIKE 'B wins with%' AND (x->'result'->'cells'->1->>'value')::numeric > (x->'result'->'cells'->0->>'value')::numeric
    FROM ab, jsonb_array_elements(v) x WHERE x->>'name' = 'Quality A vs B'),
  'AB04 qualified rate: a two-proportion test between the cells');
RESET ROLE;
SELECT pg_temp.ok((SELECT abs(crm_private.ads_norm_cdf(1.96) - 0.975) < 0.0005 AND abs(crm_private.ads_norm_cdf(0) - 0.5) < 0.0001 AND abs(crm_private.ads_norm_cdf(-1.645) - 0.05) < 0.0005),
  'AB05 the normal distribution used for confidence is accurate');
RESET ROLE;
\echo ALL ADS META 110 TESTS PASSED
