-- 129: Meta Ads > Overview > Budget split (BS01-BS10). Runs after B5_ (live campaign 7101, account from A2_).
RESET ROLE;
UPDATE public.ads_meta_object SET status = 'PAUSED' WHERE level = 'adset' AND campaign_ext = '7101';
UPDATE public.ads_meta_object SET status = 'ACTIVE' WHERE level = 'campaign' AND external_id = '7101';
INSERT INTO public.ads_meta_object (account_id, level, external_id, campaign_ext, adset_ext, name, status, info) VALUES
  (pg_temp.acct(), 'adset', '8201', '7101', NULL, 'India | Advantage+ | f2', 'ACTIVE', '{"daily_budget": 70}'),
  (pg_temp.acct(), 'adset', '8301', '7101', NULL, 'India | route B', 'PAUSED', '{}'),
  (pg_temp.acct(), 'ad', '9301', '7101', '8301', 'v5', 'ACTIVE', '{}')
ON CONFLICT (level, external_id) DO NOTHING;
-- 8301 is ad set a3 of an approved plan whose name says NIOS (its Meta name does not); its budget comes from the plan until Meta's is read
INSERT INTO public.ads_meta_strategy (title, status, goal, version, approved_version, build) VALUES ('Split test', 'approved', '{}', 1, 1,
  '{"version": 1, "steps": {"adset:a3": {"id": "8301", "status": "done"}}}');
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) SELECT id, 1,
  '{"campaigns": [{"key": "c1", "adsets": [{"key": "a3", "name": "India | NIOS route | f3", "daily_budget": 30}]}]}' FROM public.ads_meta_strategy WHERE title = 'Split test';
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, link_clicks, leads) VALUES
  (pg_temp.acct(), '9201', '8201', '7101', crm_private.ads_meta_today(), 50, 900, 10, 8, 1),
  (pg_temp.acct(), '9201', '8201', '7101', crm_private.ads_meta_today() - 3, 20, 400, 4, 3, 0),
  (pg_temp.acct(), '9201', '8201', '7101', crm_private.ads_meta_today() - 9, 99, 400, 4, 3, 0),
  (pg_temp.acct(), '9301', '8301', '7101', crm_private.ads_meta_today(), 12, 300, 3, 2, 1)
ON CONFLICT (ad_ext, day) DO NOTHING;
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, stage, created_at, first_touch) VALUES
  ('5b000000-0000-0000-0000-000000000201', 'pilot_training', 'Split A', '+919811400201', 'lead_created', now() - interval '1 day', '{"adset_id": "8201"}'),
  ('5b000000-0000-0000-0000-000000000202', 'pilot_training', 'Split B', '+919811400202', 'lead_created', now() - interval '2 days', '{"adset_id": "8201"}'),
  ('5b000000-0000-0000-0000-000000000203', 'pilot_training', 'Split C', '+919811400203', 'lead_created', now() - interval '3 hours', '{"ad_id": "9301"}'),
  ('5b000000-0000-0000-0000-000000000204', 'pilot_training', 'Split D', '+919811400204', 'lead_created', now() - interval '20 days', '{"adset_id": "8201"}')
ON CONFLICT (id) DO NOTHING;

SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bs1 AS SELECT public.api_ads_meta_budget_split() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT NOT (v->>'ready')::boolean AND v->>'why' = 'Appears when the NIOS ad set is live' AND jsonb_array_length(v->'items') = 1 FROM bs1),
  'BS01 with only the CPL ad set running the card waits ("Appears when the NIOS ad set is live")');
UPDATE public.ads_meta_object SET status = 'ACTIVE' WHERE level = 'adset' AND external_id = '8301';
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bs2 AS SELECT public.api_ads_meta_budget_split() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT (v->>'ready')::boolean AND (v->>'total')::numeric = 100 AND (v->>'step')::int = 10 AND (v->>'min')::numeric = 30
      AND NOT (v->>'can_approve')::boolean
      AND v->'items'->0->>'label' = 'CPL ads' AND v->'items'->0->>'id' = '8201' AND (v->'items'->0->>'daily')::numeric = 70 AND v->'items'->0->>'budget_from' = 'meta'
      AND (v->'items'->0->>'today_spend')::numeric = 50 AND (v->'items'->0->>'leads_7d')::int = 2 AND (v->'items'->0->>'cpl_7d')::numeric = 35
      AND v->'items'->1->>'label' = 'NIOS ads' AND (v->'items'->1->>'daily')::numeric = 30 AND v->'items'->1->>'budget_from' = 'plan'
      AND (v->'items'->1->>'leads_7d')::int = 1 AND (v->'items'->1->>'cpl_7d')::numeric = 12 FROM bs2),
  'BS02 CPL and NIOS sides: daily budget (Meta''s, else the plan''s), today''s spend, 7-day leads and cost per lead; total ₹100, step ₹10, minimum ₹30');

SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_budget_split_save('[{"adset": "8201", "daily": 60}, {"adset": "8301", "daily": 40}]')$q$, '%Only approvers%', 'BS03 a viewer cannot change the split');
SELECT pg_temp.as_('d');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_budget_split_save('[{"adset": "8201", "daily": 60}, {"adset": "8301", "daily": 50}]')$q$, '%total must stay ₹100%', 'BS04 the total cannot change');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_budget_split_save('[{"adset": "8201", "daily": 80}, {"adset": "8301", "daily": 20}]')$q$, '%at least ₹30%', 'BS05 no side below the split minimum');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_budget_split_save('[{"adset": "8201", "daily": 60}, {"adset": "8101", "daily": 40}]')$q$, '%both ad sets%', 'BS05b only the two running ad sets');
CREATE TEMP TABLE bs3 AS SELECT public.api_ads_meta_budget_split_save('[{"adset": "8301", "daily": 40}, {"adset": "8201", "daily": 60}]') r;
RESET ROLE;
GRANT SELECT ON bs3 TO PUBLIC;
SELECT pg_temp.ok((SELECT jsonb_array_length(r->'ids') = 2 AND (r->>'self_approve')::boolean AND r->'guard' @> '["A 33% change is a big edit: Meta may restart the learning phase for this ad set."]' FROM bs3)
    AND (SELECT a.object_id = '8201' AND a.kind = 'budget' AND a.status = 'pending' AND a.params @> '{"daily": 60, "split": true}' AND a.reason LIKE '%CPL ads ₹60 / NIOS ads ₹40%'
         FROM public.ads_meta_action a WHERE a.id = (SELECT (r->'ids'->>0)::bigint FROM bs3))
    AND (SELECT a.object_id = '8301' AND a.params @> '{"daily": 40, "split": true}' FROM public.ads_meta_action a WHERE a.id = (SELECT (r->'ids'->>1)::bigint FROM bs3)),
  'BS06 Save makes one budget request per ad set (the lower one first) through approval, with the learning-phase warning');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_budget_split_save('[{"adset": "8201", "daily": 50}, {"adset": "8301", "daily": 50}]')$q$, '%already waiting%', 'BS07 no second split while one is waiting');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '8101', 'budget', '{"daily": 40, "split": true}', 'x')$q$, '%Budget split on Overview%', 'BS08 other budget requests cannot borrow the split minimum ...');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_action_request('adset', '8101', 'budget', '{"daily": 60}', 'x')$q$, '%between ₹100%', 'BS08b ... and still need ₹100 a day');
SELECT public.api_ads_meta_action_decide((r->'ids'->>0)::bigint, true, 'ok') FROM bs3;
RESET ROLE; SET ROLE service_role;
CREATE TEMP TABLE bs4 AS SELECT public.svc_ads_meta_action_work() w;
GRANT SELECT ON bs4 TO PUBLIC;
SELECT public.svc_ads_meta_action_done((r->'ids'->>0)::bigint, 'done', '{"daily_budget": 70}', '{"daily_budget": 60, "status": "ACTIVE"}', NULL) FROM bs3;
SELECT public.svc_ads_meta_budgets_save('[{"id": "8301", "daily_budget": 30}, {"id": "999999", "daily_budget": 5}]');
RESET ROLE;
SELECT pg_temp.ok((SELECT (w->>'split_min_daily')::numeric = 30 AND (w->>'min_daily')::numeric = 100 AND w->'items' @> '[{"kind": "budget", "object_id": "8201"}]' FROM bs4),
  'BS09 the action job gets the split minimum for split requests (the normal minimum stays ₹100)');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bs5 AS SELECT public.api_ads_meta_budget_split() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT (v->'items'->0->>'daily')::numeric = 60 AND NOT (v->'items'->0->>'waiting')::boolean AND v->'items'->1->>'budget_from' = 'meta'
      AND (v->'items'->1->>'waiting')::boolean AND (v->>'total')::numeric = 90 FROM bs5),
  'BS10 the budget Meta reads back (and meta_health''s) shows at once; the side still waiting is marked');
\echo ALL ADS META 129 TESTS PASSED
