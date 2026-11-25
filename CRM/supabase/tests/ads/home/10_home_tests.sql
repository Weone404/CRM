-- 146 ADS Google Ads home. HM01-HM46. Each check prints PASS <name>; the first failure stops the run.
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
CREATE OR REPLACE FUNCTION pg_temp.fails(p_sql text, p_like text, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN RAISE NOTICE 'PASS %', name; RETURN; END IF;
    RAISE EXCEPTION 'FAIL % (wrong error: %)', name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL % (no error)', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
CREATE OR REPLACE FUNCTION pg_temp.acc() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a1460000-0000-4000-8000-000000000001'::uuid $$;
-- Google's answer with a spending limit and an amount served (rupees), as ads-google-ops passes it on
CREATE OR REPLACE FUNCTION pg_temp.bill(p_limit numeric, p_served numeric, p_more jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('billing_setup', '[]'::jsonb, 'account_budget', jsonb_build_array(jsonb_build_object(
    'accountBudget.id', '7540703255', 'accountBudget.status', 'APPROVED',
    'accountBudget.adjustedSpendingLimitMicros', (round(p_limit * 100) * 10000)::bigint::text,
    'accountBudget.amountServedMicros', (round(p_served * 100) * 10000)::bigint::text) || p_more)) $$;
CREATE OR REPLACE FUNCTION pg_temp.save(p_data jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT public.svc_ads_google_billing_save(pg_temp.acc(), p_data) $$;
CREATE OR REPLACE FUNCTION pg_temp.bal() RETURNS public.ads_google_balance LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.ads_google_balance WHERE account_id = pg_temp.acc() $$;
CREATE OR REPLACE FUNCTION pg_temp.gate(p_kind text, p_payload jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT crm_private.ads_google_gate(pg_temp.acc(), p_kind, p_payload) $$;
CREATE OR REPLACE FUNCTION pg_temp.blocks(p_kind text, p_payload jsonb, p_like text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pg_temp.gate(p_kind, p_payload)->'blockers') m WHERE m ILIKE p_like) $$;
CREATE OR REPLACE FUNCTION pg_temp.clean(p_kind text, p_payload jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_array_length(pg_temp.gate(p_kind, p_payload)->'blockers') = 0 $$;
-- a budget_set payload: total, Delhi NCR part, Other cities part
CREATE OR REPLACE FUNCTION pg_temp.bs(p_total numeric, p_a numeric, p_b numeric) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('daily_total', p_total, 'parts', jsonb_build_array(
    jsonb_build_object('campaign_id', '24283129095', 'daily_budget', p_a), jsonb_build_object('campaign_id', '24542430627', 'daily_budget', p_b))) $$;
CREATE OR REPLACE FUNCTION pg_temp.cfg(p_key text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT value FROM public.ads_config WHERE key = p_key $$;
CREATE OR REPLACE FUNCTION pg_temp.budget(p_camp text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT daily_budget FROM public.ads_campaigns WHERE account_id = pg_temp.acc() AND external_id = p_camp $$;
CREATE OR REPLACE FUNCTION pg_temp.lastop() RETURNS public.ads_google_ops LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.ads_google_ops WHERE kind = 'budget_set' ORDER BY created_at DESC, id LIMIT 1 $$;
CREATE OR REPLACE FUNCTION pg_temp.home(p_days int DEFAULT 7) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.api_ads_google_home(p_days) $$;
-- one day of account numbers, n days ago
CREATE OR REPLACE FUNCTION pg_temp.day(p_ago int, p_spend numeric, p_clicks int, p_camp text DEFAULT '24283129095') RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, impressions, clicks)
  VALUES ((SELECT id FROM public.ads_campaigns WHERE external_id = p_camp), crm_private.ads_google_today() - p_ago, p_spend, p_clicks * 20, p_clicks)
  ON CONFLICT (campaign_id, day) DO UPDATE SET spend = EXCLUDED.spend, impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks $$;
-- what the database would have sent to ads-google-ops (pg_net is not in the test database)
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE IF NOT EXISTS net.sent (id bigserial PRIMARY KEY, url text, headers jsonb, body jsonb);
CREATE OR REPLACE FUNCTION net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds int) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO net.sent (url, headers, body) VALUES (url, headers, body) RETURNING id $$;
INSERT INTO vault.secrets (name, secret) VALUES ('crm_cron_token', 'test-cron-token') ON CONFLICT (name) DO NOTHING;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

-- ---------------------------------------------------------------- balance, read from Google
SELECT pg_temp.ok((SELECT b.kind = 'prepaid' AND b.spending_limit = 170552.31 AND b.served = 170552.22 AND b.available = 0.09
     AND b.checked_at = '2026-11-25 10:55:15+00' AND b.error IS NULL FROM pg_temp.bal() b)
  AND NOT EXISTS (SELECT 1 FROM public.ads_google_topups),
  'HM01 the read of 25 Nov becomes the first balance: limit 170,552.31 - served 170,552.22 = 0.09 left, with its own time, and no top-up invented');
-- (each save is its own statement: a check in the same statement would see the database as it was before the save)
CREATE TEMP TABLE sv (n serial, r jsonb);
CREATE OR REPLACE FUNCTION pg_temp.r(p_n int) RETURNS jsonb LANGUAGE sql AS $$ SELECT r FROM sv WHERE n = p_n $$;
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170552.22));                                  -- 1
SELECT pg_temp.ok((pg_temp.r(1)->>'rise')::numeric = 5084.75
  AND (SELECT b.available = 5084.84 AND b.checked_at > now() - interval '1 minute' FROM pg_temp.bal() b)
  AND (SELECT count(*) = 1 AND min(credit) = 5084.75 AND min(limit_after) = 175637.06 FROM public.ads_google_topups)
  AND EXISTS (SELECT 1 FROM public.ads_activity_log WHERE action = 'google_topup_seen' AND (details->>'credit')::numeric = 5084.75),
  'HM02 money added in Google Ads shows by itself: a payment of 6,000 (5,084.75 after 18% tax) raises the limit, the balance is 5,084.84, a top-up is recorded');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170552.22));                                  -- 2
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22));                                  -- 3
SELECT pg_temp.ok((pg_temp.r(2)->>'rise')::numeric = 0 AND (pg_temp.r(3)->>'available')::numeric = 4884.84
  AND (SELECT count(*) = 1 FROM public.ads_google_topups),
  'HM03 reading again records nothing twice; spending lowers the balance (200 served: 4,884.84 left)');
INSERT INTO sv (r) SELECT pg_temp.save('{"account_budget": {"error": "RESOURCE_EXHAUSTED: try later"}}');      -- 4
SELECT pg_temp.ok((pg_temp.r(4)->>'saved') = 'false'
  AND (SELECT b.available = 4884.84 AND b.kind = 'prepaid' AND b.error = 'RESOURCE_EXHAUSTED: try later' AND b.error_at IS NOT NULL FROM pg_temp.bal() b),
  'HM04 a failed read keeps the last good figure and says why');
INSERT INTO sv (r) SELECT pg_temp.save('{}');                                                                 -- 5
SELECT pg_temp.ok((pg_temp.r(5)->>'saved') = 'false' AND (SELECT b.error = 'Google did not return the account budget.' AND b.available = 4884.84 FROM pg_temp.bal() b),
  'HM04b an empty answer is a failed read too');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22));                                  -- 6
SELECT pg_temp.ok((pg_temp.r(6)->>'saved') = 'true' AND (SELECT b.error IS NULL AND b.error_at IS NULL FROM pg_temp.bal() b),
  'HM04c the next good read clears the error');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175537.06, 175600));                                     -- 7
SELECT pg_temp.ok((pg_temp.r(7)->>'available')::numeric = 0 AND (SELECT count(*) = 1 FROM public.ads_google_topups),
  'HM05 a lowered limit or an overspend is never a top-up and never a negative balance');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.adjustedSpendingLimitType": "INFINITE"}'));  -- 8
SELECT pg_temp.ok((pg_temp.r(8)->>'kind') = 'no_limit' AND (SELECT b.available IS NULL AND b.spending_limit IS NULL FROM pg_temp.bal() b),
  'HM06 an account with no spending limit shows no balance (never a made-up one)');
INSERT INTO sv (r) SELECT pg_temp.save('{"account_budget": []}');                                            -- 9
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.status": "PENDING"}'));                       -- 10
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.approvedEndDateTime": "2026-01-01 00:00:00"}'));  -- 11
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.adjustedSpendingLimitMicros": "abc"}'));       -- 12
SELECT pg_temp.ok((pg_temp.r(9)->>'kind') = 'none' AND (pg_temp.r(10)->>'kind') = 'none' AND (pg_temp.r(11)->>'kind') = 'none' AND (pg_temp.r(12)->>'kind') = 'no_limit'
  AND (SELECT count(*) = 1 FROM public.ads_google_topups),
  'HM06b no budget, a waiting or an ended budget, or an unreadable limit shows no balance, and none of it is a top-up');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.approvedEndDateTime": "2037-12-30 23:59:59"}'));  -- 13
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(175637.06, 170752.22, '{"accountBudget.approvedEndDateTime": "2031-02-31 10:00:00"}'));  -- 14
SELECT pg_temp.ok((pg_temp.r(13)->>'available')::numeric = 4884.84 AND (pg_temp.r(14)->>'available')::numeric = 4884.84
  AND (SELECT count(*) = 1 FROM public.ads_google_topups),
  'HM07 a budget that ends in the future counts; a date that does not exist does not break the read; coming back from "no balance" is not a top-up');
SELECT pg_temp.ok((SELECT data->'account_budget'->0->>'accountBudget.amountServedMicros' = '170752220000' FROM public.ads_google_snapshot WHERE account_id = pg_temp.acc() AND kind = 'billing'),
  'HM08 Google''s raw answer is kept in the billing snapshot for the AI team');
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_ads_google_billing_save(uuid, jsonb, timestamptz)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_ads_google_home(int)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_ads_google_budget_set(numeric)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_ads_google_balance_refresh()', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'public.ads_google_balance', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.ads_google_topups', 'SELECT')
  AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE relname IN ('ads_google_balance', 'ads_google_topups')),
  'HM09 a browser cannot write the balance or read the tables; signed-out visitors can call nothing');
SELECT pg_temp.fails($$SELECT public.svc_ads_google_billing_save('00000000-0000-0000-0000-000000000999', '{}')$$, '%not a Google Ads account%',
  'HM10 a balance is saved only for a Google Ads account');

-- "I added money" / "Check now"
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT public.api_ads_google_balance_refresh()', '%do not have access%', 'HM11 no ADS access: no balance check, no home, no budget');
SELECT pg_temp.fails('SELECT public.api_ads_google_home()', '%do not have access%', 'HM11b no ADS access: the home read is refused');
SELECT pg_temp.as_('c');
CREATE TEMP TABLE r1 AS SELECT public.api_ads_google_balance_refresh() r;
CREATE TEMP TABLE r2 AS SELECT public.api_ads_google_balance_refresh() r;
RESET ROLE;
SELECT pg_temp.ok((SELECT (r->>'asked')::boolean AND NOT (r->>'wait')::boolean FROM r1) AND (SELECT NOT (r->>'asked')::boolean AND (r->>'wait')::boolean FROM r2)
  AND (SELECT count(*) = 1 AND min(body::text) = '{"read": "billing"}' AND min(url) LIKE '%/functions/v1/ads-google-ops'
          AND min(headers->>'x-cron-token') = 'test-cron-token' FROM net.sent)
  AND (SELECT b.asked_at > now() - interval '1 minute' AND b.watch_until BETWEEN now() + interval '119 minutes' AND now() + interval '121 minutes' FROM pg_temp.bal() b),
  'HM12 "I added money" asks Google once (a second tap within 10 seconds sends nothing) and keeps checking for two hours');
INSERT INTO sv (r) SELECT pg_temp.save(pg_temp.bill(180000, 170752.22));                                   -- 15
SELECT pg_temp.ok((pg_temp.r(15)->>'rise')::numeric = 4362.94 AND (SELECT b.watch_until IS NULL FROM pg_temp.bal() b)
  AND (SELECT count(*) = 2 FROM public.ads_google_topups),
  'HM13 once the money shows, the two-hour watch ends');
UPDATE public.ads_accounts SET status = 'auth_required' WHERE id = pg_temp.acc();
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.fails('SELECT public.api_ads_google_balance_refresh()', '%Connect the Google Ads account first%', 'HM14 a disconnected account is not asked');
SELECT pg_temp.ok(public.api_ads_google_home()->'status'->>'state' = 'not_connected', 'HM15 a disconnected account: the home says so');
RESET ROLE;
UPDATE public.ads_accounts SET status = 'connected' WHERE id = pg_temp.acc();
DROP SCHEMA net CASCADE;
UPDATE public.ads_google_balance SET asked_at = NULL;
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_google_balance_refresh()->>'asked') = 'false', 'HM16 without pg_net nothing breaks: the answer says it was not sent (the schedule will)');
RESET ROLE;

-- ---------------------------------------------------------------- budget_set: the checks
SELECT pg_temp.ok(pg_temp.clean('budget_set', pg_temp.bs(200, 150, 50)) AND pg_temp.clean('budget_set', pg_temp.bs(100, 70, 30))
  AND pg_temp.clean('campaign_geo', '{"campaign_id":"24283129095","add":["1007801"]}')
  AND pg_temp.clean('ad_schedule', '{"campaign_id":"1","slots":[{"start_hour":0,"end_hour":24}]}')
  AND pg_temp.clean('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50"]}')
  AND pg_temp.blocks('made_up', '{}', 'Unknown operation type.') AND NOT pg_temp.blocks('budget_set', '{}', 'Unknown operation type.'),
  'HM17 a new split inside the owner''s limit passes; every older kind still gets its own checks through all three layers');
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(99, 69, 30), 'daily_total must be a whole number from 100 to 5000.')
  AND pg_temp.blocks('budget_set', pg_temp.bs(5001, 3501, 1500), 'daily_total must be%')
  AND pg_temp.blocks('budget_set', pg_temp.bs(200.5, 140.5, 60), 'daily_total must be%')
  AND pg_temp.blocks('budget_set', '{"daily_total":"lots","parts":[]}', 'daily_total must be%')
  AND pg_temp.blocks('budget_set', '{"daily_total":"NaN"}', 'daily_total must be%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200}', 'parts: one row for every switched-on campaign%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":"all"}', 'parts: one row%'),
  'HM18 the total must be a whole amount within the allowed range, and the parts must be given');
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(200, 150, 60), 'The parts add up to 210, not to the daily total of 200.')
  AND pg_temp.blocks('budget_set', pg_temp.bs(200, 140, 60), 'The campaign budgets are already set this way.')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":200}]}', 'parts must list every switched-on campaign once (2 are on, 1 listed).')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":100},{"campaign_id":"24283129095","daily_budget":100}]}', 'Campaign 24283129095 is listed twice.')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":100},{"campaign_id":"111","daily_budget":100}]}', 'Campaign 111 is not a switched-on campaign%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":100},{"campaign_id":"999","daily_budget":100}]}', 'Campaign 999 is not a switched-on campaign%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":200},{"campaign_id":"24542430627","daily_budget":0}]}', 'Every part needs a campaign_id and a daily_budget of at least 1%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095","daily_budget":"x"},{"campaign_id":"24542430627","daily_budget":60}]}', 'Every part needs%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":[{"campaign_id":"24283129095; DROP","daily_budget":140},{"campaign_id":"24542430627","daily_budget":60}]}', 'Every part needs%')
  AND pg_temp.blocks('budget_set', '{"daily_total":200,"parts":["24283129095"]}', 'Every part needs%'),
  'HM19 the parts must add up, change something, and name every switched-on campaign exactly once with a real amount');
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(300, 210, 90), 'The owner''s daily limit is 200; a total of 300 is above it.'),
  'HM20 nothing gets past the owner''s daily limit');
UPDATE public.ads_clients SET max_daily_budget = 150 WHERE id = 'c1460000-0000-4000-8000-000000000001';
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(200, 150, 50), 'The client''s maximum daily budget is 150%'), 'HM21 the client''s own maximum also holds');
UPDATE public.ads_clients SET max_daily_budget = NULL WHERE id = 'c1460000-0000-4000-8000-000000000001';
UPDATE public.ads_campaigns SET budget_ref = NULL WHERE external_id = '24542430627';
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(200, 150, 50), 'The budget of "WOA | Search | Other cities | Online | Nov26" is shared with another campaign or not synced%'),
  'HM22 a campaign whose budget is not synced is never guessed at');
UPDATE public.ads_campaigns SET budget_ref = 'customers/6318538100/campaignBudgets/15901873674' WHERE external_id = '24542430627';
SELECT pg_temp.ok(pg_temp.blocks('budget_set', pg_temp.bs(200, 150, 50), 'The budget of %shared with another campaign%'), 'HM23 a budget shared by two campaigns is not changed from here');
UPDATE public.ads_campaigns SET budget_ref = 'customers/6318538100/campaignBudgets/16106833427' WHERE external_id = '24542430627';
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES (pg_temp.acc(), 'budget_set', pg_temp.bs(200, 150, 50), 'agent');
SELECT pg_temp.ok((SELECT o.status = 'pending' AND o.approved_at IS NULL FROM pg_temp.lastop() o),
  'HM24 an agent''s budget change waits for the owner even on Automatic');
DELETE FROM public.ads_google_ops WHERE kind = 'budget_set';

-- ---------------------------------------------------------------- the owner's one number
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(300)', '%Only people who can approve%', 'HM25 no ADS access: the budget cannot be changed');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(300)', '%Only people who can approve%', 'HM26 view-only access: the budget cannot be changed');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(99)', 'Enter a whole amount from 100 to 5000 a day', 'HM27 below the minimum is refused');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(5001)', 'Enter a whole amount from 100 to 5000 a day', 'HM28 above the maximum is refused');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(250.5)', 'Enter a whole amount%', 'HM29 paise are refused');
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(NULL)', 'Enter a whole amount%', 'HM30 an empty amount is refused');
SELECT pg_temp.fails($$SELECT public.api_ads_google_budget_set('NaN')$$, 'Enter a whole amount%', 'HM31 "not a number" is refused');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.cfg('google_cap_daily') = '200' AND pg_temp.cfg('google_cap_monthly') = '6080' AND NOT EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind = 'budget_set'),
  'HM32 a refused amount changes nothing');
SET ROLE authenticated;
CREATE TEMP TABLE s1 AS SELECT public.api_ads_google_budget_set(300) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT (r->>'changed')::boolean AND (r->>'daily')::numeric = 300 AND (r->>'monthly')::numeric = 9120 AND r->>'op' IS NOT NULL FROM s1)
  AND pg_temp.cfg('google_cap_daily') = '300' AND pg_temp.cfg('google_cap_monthly') = '9120'
  AND (SELECT o.status = 'approved' AND o.created_by_type = 'user' AND o.approved_by = '00000000-0000-0000-0000-00000000000a'
          AND o.payload->'parts' = '[{"campaign_id":"24283129095","daily_budget":210},{"campaign_id":"24542430627","daily_budget":90}]'::jsonb
          AND o.payload->'previous' = '{"daily":"200","monthly":"6080","total":200}'::jsonb
          AND o.summary = 'Daily budget 200 -> 300 (Delhi NCR 210, Punjab & Chandigarh (online) 90)' FROM pg_temp.lastop() o)
  AND pg_temp.budget('24283129095') = 140,
  'HM33 300 a day: limits 300 and 9,120 (30.4 days), one approved change sharing it 210 / 90 as before (70% / 30%); the CRM waits for Google before believing it');
SET ROLE authenticated;
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(400)', 'The last budget change is still being saved to Google%', 'HM34 a second change waits until the first is saved');
SELECT pg_temp.ok((public.api_ads_google_home()->'budget'->'change'->>'status') = 'approved' AND (public.api_ads_google_home()->'budget'->>'daily')::numeric = 300
  AND (public.api_ads_google_home()->'budget'->>'actual')::numeric = 200, 'HM35 the home shows the change as being saved: limit 300, Google still at 200');
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(v->>'kind' = 'budget_set'
      AND v->'payload'->'parts'->0->>'budget_resource' = 'customers/6318538100/campaignBudgets/15901873674'
      AND v->'payload'->'parts'->1->>'budget_resource' = 'customers/6318538100/campaignBudgets/16106833427') FROM jsonb_array_elements(public.svc_ads_google_build_work()) v)
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_ads_google_op_work()) v WHERE v->>'kind' = 'budget_set')
  AND (SELECT public.svc_ads_google_build_peek(o.id)->>'kind' = 'budget_set' FROM pg_temp.lastop() o),
  'HM36 the change is run by ads-google-ops only, with each campaign''s own budget resource filled in');
CREATE TEMP TABLE c1 AS SELECT public.svc_ads_google_op_claim((SELECT o.id FROM pg_temp.lastop() o)) c;
SELECT public.svc_ads_google_op_finish((SELECT o.id FROM pg_temp.lastop() o), 'verified', NULL, '{"resource_names": ["customers/6318538100/campaignBudgets/15901873674", "customers/6318538100/campaignBudgets/16106833427"]}', '[]');
RESET ROLE;
SELECT pg_temp.ok((SELECT c FROM c1) AND pg_temp.budget('24283129095') = 210 AND pg_temp.budget('24542430627') = 90 AND pg_temp.budget('111') = 700
  AND pg_temp.cfg('google_cap_daily') = '300',
  'HM37 once Google confirms, the CRM''s budgets are 210 and 90 at once; a paused campaign is untouched');
SET ROLE authenticated;
CREATE TEMP TABLE s2 AS SELECT public.api_ads_google_budget_set(300.0) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT NOT (r->>'changed')::boolean FROM s2) AND (SELECT count(*) = 1 FROM public.ads_google_ops WHERE kind = 'budget_set'),
  'HM38 saving the same amount again does nothing (no second request to Google)');
-- lowering, and Google refusing it before anything changed
SET ROLE authenticated;
CREATE TEMP TABLE s3 AS SELECT public.api_ads_google_budget_set(200) r;
RESET ROLE;
SELECT pg_temp.ok(pg_temp.cfg('google_cap_daily') = '200' AND (SELECT o.payload->'parts' = '[{"campaign_id":"24283129095","daily_budget":140},{"campaign_id":"24542430627","daily_budget":60}]'::jsonb FROM pg_temp.lastop() o),
  'HM39 back to 200: the limit drops at once and the split is 140 / 60 again');
SET ROLE service_role;
CREATE TEMP TABLE c3 AS SELECT public.svc_ads_google_op_claim((SELECT o.id FROM pg_temp.lastop() o)) c;
SELECT public.svc_ads_google_op_finish((SELECT o.id FROM pg_temp.lastop() o), 'failed', 'Google rejected it in the pre-check (nothing changed): BUDGET_ERROR', NULL, NULL);
RESET ROLE;
SELECT pg_temp.ok(pg_temp.cfg('google_cap_daily') = '300' AND pg_temp.cfg('google_cap_monthly') = '9120' AND pg_temp.budget('24283129095') = 210
  AND pg_temp.budget('24542430627') = 90,
  'HM40 Google refused before anything changed: the limits go back to 300 / 9,120, matching what Google still has');
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_google_home()->'budget'->'change'->>'status') = 'failed' AND (public.api_ads_google_home()->'budget'->'change'->>'error') LIKE 'Google rejected it%',
  'HM41 the home says the change failed, with Google''s reason');
CREATE TEMP TABLE s4 AS SELECT public.api_ads_google_budget_set(200) r;
RESET ROLE;
SET ROLE service_role;
CREATE TEMP TABLE c4 AS SELECT public.svc_ads_google_op_claim((SELECT o.id FROM pg_temp.lastop() o)) c;
SELECT public.svc_ads_google_op_finish((SELECT o.id FROM pg_temp.lastop() o), 'failed', 'Google accepted it, but 1 item(s) do not read back as expected.', '{"resource_names": ["x"]}', '[]');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.cfg('google_cap_daily') = '200' AND pg_temp.budget('24283129095') = 210,
  'HM42 sent but not confirmed: the lower limit stays (the safe side) and the CRM does not pretend the budgets changed');
-- the daily limit lowered by hand before the change is picked up
UPDATE public.ads_config SET value = '300' WHERE key = 'google_cap_daily';
SET ROLE authenticated;
CREATE TEMP TABLE s5 AS SELECT public.api_ads_google_budget_set(500) r;
RESET ROLE;
UPDATE public.ads_config SET value = '250' WHERE key = 'google_cap_daily';
SET ROLE service_role;
CREATE TEMP TABLE c5 AS SELECT public.svc_ads_google_op_claim((SELECT o.id FROM pg_temp.lastop() o)) c;
RESET ROLE;
SELECT pg_temp.ok(NOT (SELECT c FROM c5) AND (SELECT o.status = 'stale' FROM pg_temp.lastop() o) AND pg_temp.budget('24283129095') = 210 AND pg_temp.cfg('google_cap_daily') = '250',
  'HM43 a limit lowered after saving stops the change before anything is sent, and the newer limit is kept');
-- odd amounts and other shapes
UPDATE public.ads_config SET value = '300' WHERE key = 'google_cap_daily';
SET ROLE authenticated;
CREATE TEMP TABLE s6 AS SELECT public.api_ads_google_budget_set(255) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT (r->'parts'->0->>'daily_budget')::numeric + (r->'parts'->1->>'daily_budget')::numeric = 255 AND (r->'parts'->1->>'daily_budget')::numeric = 77 FROM s6)
  AND (SELECT o.status = 'approved' FROM pg_temp.lastop() o),
  'HM44 an amount that is not a multiple of 10 is shared to the rupee and still adds up (178 + 77 = 255)');
DELETE FROM public.ads_google_ops WHERE kind = 'budget_set' AND status = 'approved';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id = '24542430627';
SET ROLE authenticated;
CREATE TEMP TABLE s7 AS SELECT public.api_ads_google_budget_set(400) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT r->'parts' = '[{"campaign_id":"24283129095","daily_budget":400}]'::jsonb FROM s7), 'HM45 with one campaign on, it gets the whole amount');
DELETE FROM public.ads_google_ops WHERE kind = 'budget_set' AND status = 'approved';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id = '24283129095';
SET ROLE authenticated;
SELECT pg_temp.fails('SELECT public.api_ads_google_budget_set(400)', 'No Google Ads campaign is switched on', 'HM46 with nothing switched on there is nothing to share it between');
RESET ROLE;
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = CASE external_id WHEN '24283129095' THEN 140 ELSE 60 END WHERE external_id IN ('24283129095', '24542430627');
UPDATE public.ads_config SET value = '250' WHERE key = 'google_cap_daily';
SET ROLE authenticated;
CREATE TEMP TABLE s8 AS SELECT public.api_ads_google_budget_set(200) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT (r->>'changed')::boolean AND r->>'op' IS NULL FROM s8) AND pg_temp.cfg('google_cap_daily') = '200' AND pg_temp.cfg('google_cap_monthly') = '6080'
  AND NOT EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind = 'budget_set' AND status = 'approved'),
  'HM47 when the campaigns already add up to the amount, only the limits are set (nothing is sent to Google)');

-- ---------------------------------------------------------------- the home read
DELETE FROM public.ads_google_topups; DELETE FROM public.ads_google_balance; DELETE FROM public.ads_google_ops;
SELECT pg_temp.save(pg_temp.bill(170552.31, 170552.22)) \gset s_
SET ROLE authenticated;
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((h->'status'->>'state') = 'no_money' AND NOT (h->'status'->>'likely')::boolean AND NOT (h->>'can_edit')::boolean
  AND (h->'money'->>'kind') = 'prepaid' AND (h->'money'->>'available')::numeric = 0.09 AND (h->'money'->>'days_left')::numeric = 0
  AND (h->'money'->>'daily')::numeric = 200 AND (h->'money'->>'tax_pct')::numeric = 18 AND (h->'money'->>'add_30d')::numeric = 7100
  AND (h->'budget'->>'daily')::numeric = 200 AND (h->'budget'->>'monthly')::numeric = 6080 AND (h->'budget'->>'min')::numeric = 100 AND (h->'budget'->>'max')::numeric = 5000
  AND (h->'status'->>'campaigns_on')::int = 2,
  'HM48 today''s account: "no money" (0.09 left, read from Google), 7,100 to add for 30 days at 200 a day with 18% tax; a viewer sees it but cannot edit')
  FROM (SELECT public.api_ads_google_home() h) x;
SELECT pg_temp.as_('a');
SELECT pg_temp.ok((public.api_ads_google_home()->>'can_edit')::boolean, 'HM49 the owner can edit');
RESET ROLE;
SELECT pg_temp.save(pg_temp.bill(175637.06, 170552.22)) \gset s_
SET ROLE authenticated;
SELECT pg_temp.ok((h->'status'->>'state') = 'starting' AND (h->'money'->>'available')::numeric = 5084.84 AND (h->'money'->>'days_left')::numeric = 25.4
  AND (h->'money'->'last_topup'->>'credit')::numeric = 5084.75 AND (h->'money'->>'add_30d')::numeric = 1100,
  'HM50 right after a top-up with no spend yet: "starting", 25.4 days of money, 1,100 more would make it 30 days')
  FROM (SELECT public.api_ads_google_home() h) x;
RESET ROLE;
SELECT pg_temp.day(0, 55, 4);
SET ROLE authenticated;
SELECT pg_temp.ok((h->'status'->>'state') = 'running' AND (h->'status'->>'today_spend')::numeric = 55 AND (h->'status'->>'today_clicks')::numeric = 4,
  'HM51 spending today: "running", with today''s spend and clicks')
  FROM (SELECT public.api_ads_google_home() h) x;
RESET ROLE;
SELECT pg_temp.save(pg_temp.bill(175637.06, 175137.06)) \gset s_
SET ROLE authenticated;
SELECT pg_temp.ok((h->'status'->>'state') = 'low_money' AND (h->'money'->>'days_left')::numeric = 2.5, 'HM52 under 3 days of money left: "low money" (500 at 200 a day = 2.5 days)')
  FROM (SELECT public.api_ads_google_home() h) x;
RESET ROLE;
UPDATE public.ads_config SET value = 'true' WHERE key = 'google_paused';
INSERT INTO public.ads_config (key, value) VALUES ('google_paused', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_google_home()->'status'->>'state') = 'paused', 'HM53 Stop is on: "paused" comes before anything about money');
RESET ROLE;
UPDATE public.ads_config SET value = 'false' WHERE key = 'google_paused';
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id IN ('24283129095', '24542430627');
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_google_home()->'status'->>'state') = 'off' AND jsonb_array_length(public.api_ads_google_home()->'campaigns') = 0, 'HM54 no campaign switched on: "off"');
RESET ROLE;
UPDATE public.ads_campaigns SET status = 'ENABLED' WHERE external_id IN ('24283129095', '24542430627');
-- no balance from Google (never read), and the delivery watch says the money ran out
DELETE FROM public.ads_google_topups; DELETE FROM public.ads_google_balance; DELETE FROM public.ads_metrics_daily;
SELECT pg_temp.day(n, 282.46, 23) FROM generate_series(10, 12) n;
SET ROLE authenticated;
SELECT pg_temp.ok((h->'status'->>'state') = 'no_money' AND (h->'status'->>'likely')::boolean AND h->'money'->>'kind' IS NULL AND h->'money'->>'available' IS NULL
  AND (h->'status'->>'cause') = 'funds',
  'HM55 before the first read from Google the delivery watch still says "probably no money" (847.38 + 18% tax = one payment of 1,000), marked as likely, with no invented balance')
  FROM (SELECT public.api_ads_google_home() h) x;
RESET ROLE;
-- money is there but the ads still do not show
SELECT pg_temp.save(pg_temp.bill(175637.06, 170552.22)) \gset s_
SELECT pg_temp.save(pg_temp.bill(175637.06, 170552.22)) \gset s_
SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_google_home()->'status'->>'state') = 'not_showing' AND (public.api_ads_google_home()->'money'->>'available')::numeric = 5084.84,
  'HM56 money in the account (no fresh top-up) and still no impressions: "not showing", never "no money"');
RESET ROLE;
DELETE FROM public.ads_metrics_daily;

-- who / where / when / words
INSERT INTO public.ads_google_snapshot (account_id, kind, data) VALUES
  (pg_temp.acc(), 'campaigns', '[{"campaign.id":"24283129095","campaign.primaryStatus":"ELIGIBLE","campaign.targetSpend.cpcBidCeilingMicros":"20000000"},
     {"campaign.id":"24542430627","campaign.primaryStatus":"PENDING","campaign.primaryStatusReasons":["BIDDING_STRATEGY_LEARNING","MOST_ADS_UNDER_REVIEW"],"campaign.targetSpend.cpcBidCeilingMicros":"20000000"}]'),
  (pg_temp.acc(), 'locations', '[{"campaign.id":"24283129095","place":"110017,Delhi,India","campaignCriterion.negative":false},
     {"campaign.id":"24283129095","place":"Gurugram,Gurugram,Haryana,India","campaignCriterion.negative":false},
     {"campaign.id":"24283129095","place":"Pakistan","campaignCriterion.negative":true},
     {"campaign.id":"24283129095","campaignCriterion.criterionId":"9061645","campaignCriterion.negative":false},
     {"campaign.id":"24542430627","place":"Punjab,India","campaignCriterion.negative":false},
     {"campaign.id":"111","place":"India","campaignCriterion.negative":false}]'),
  (pg_temp.acc(), 'keywords', '[{"campaign.id":"24283129095","adGroupCriterion.keyword.text":"pilot training","adGroupCriterion.status":"ENABLED","adGroupCriterion.negative":false},
     {"campaign.id":"24283129095","adGroupCriterion.keyword.text":"cpl training","adGroupCriterion.status":"ENABLED","adGroupCriterion.negative":false},
     {"campaign.id":"24283129095","adGroupCriterion.keyword.text":"aviation academy","adGroupCriterion.status":"PAUSED","adGroupCriterion.negative":false},
     {"campaign.id":"24283129095","adGroupCriterion.keyword.text":"free","adGroupCriterion.status":"ENABLED","adGroupCriterion.negative":true}]')
ON CONFLICT (account_id, kind) DO UPDATE SET data = EXCLUDED.data;
INSERT INTO public.ads_google_ops (account_id, kind, payload, status, created_by_type, created_at) VALUES
  (pg_temp.acc(), 'income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_0_50"]}', 'pending', 'user', now() - interval '3 hours'),
  (pg_temp.acc(), 'income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_0_50","INCOME_RANGE_50_60","INCOME_RANGE_60_70","INCOME_RANGE_70_80","INCOME_RANGE_UNDETERMINED"]}', 'pending', 'user', now() - interval '2 hours'),
  (pg_temp.acc(), 'ad_schedule', '{"campaign_id":"24283129095","slots":[{"start_hour":0,"end_hour":6,"bid_pct":-30},{"start_hour":6,"end_hour":24,"bid_pct":0}]}', 'pending', 'user', now() - interval '2 hours'),
  (pg_temp.acc(), 'campaign_create', '{"name":"WOA Other","daily_budget":10,"max_cpc":20,"locations":["1007801"],"income_exclude":["INCOME_RANGE_0_50","INCOME_RANGE_UNDETERMINED"]}', 'pending', 'user', now() - interval '2 hours');
ALTER TABLE public.ads_google_ops DISABLE TRIGGER USER;
UPDATE public.ads_google_ops SET status = 'verified' WHERE kind IN ('income_filter', 'ad_schedule') AND created_at < now() - interval '90 minutes' AND payload->'exclude' IS DISTINCT FROM '["INCOME_RANGE_0_50"]'::jsonb;
UPDATE public.ads_google_ops SET status = 'failed' WHERE payload->'exclude' = '["INCOME_RANGE_0_50"]'::jsonb;
UPDATE public.ads_google_ops SET status = 'verified', result = '{"resource_names":["customers/6318538100/campaignBudgets/16106833427","customers/6318538100/campaigns/24542430627"]}' WHERE kind = 'campaign_create';
ALTER TABLE public.ads_google_ops ENABLE TRIGGER USER;
SET ROLE authenticated;
SELECT pg_temp.ok(jsonb_array_length(h->'campaigns') = 2
  AND (c0->>'id') = '24283129095' AND (c0->>'label') = 'Delhi NCR' AND (c0->>'daily_budget')::numeric = 140 AND (c0->>'max_cpc')::numeric = 20
  AND jsonb_array_length(c0->'income_excluded') = 5 AND (c0->'slots'->0->>'bid_pct')::int = -30
  AND c0->'places' = '["110017,Delhi,India", "Gurugram,Gurugram,Haryana,India", "9061645"]'::jsonb
  AND (c0->>'keywords_on')::int = 2 AND (c0->>'keywords_paused')::int = 1 AND c0->'examples' @> '["pilot training", "cpl training"]'::jsonb AND NOT c0->'examples' @> '["free"]'::jsonb
  AND (c1->>'label') = 'Punjab & Chandigarh (online)' AND c1->'income_excluded' = '["INCOME_RANGE_0_50", "INCOME_RANGE_UNDETERMINED"]'::jsonb
  AND c1->'slots' = 'null'::jsonb AND c1->'places' = '["Punjab,India"]'::jsonb AND (c1->>'keywords_on')::int = 0
  AND h->'status'->'reviewing' = '["Punjab & Chandigarh (online)"]'::jsonb
  AND jsonb_array_length(h->'areas_waiting') = 2 AND (h->'areas_waiting'->0->>'places') LIKE 'Jaipur%',
  'HM57 who / where / when / words per campaign come from what Google confirmed: income groups shut out (latest verified change, also from the campaign''s creation), time slots, places (excluded places left out), phrase counts; the campaign under review is named; areas not opened yet are listed')
  FROM (SELECT h, h->'campaigns'->0 c0, h->'campaigns'->1 c1 FROM (SELECT public.api_ads_google_home() h) y) x;
RESET ROLE;
UPDATE public.ads_google_snapshot SET data = '{"error": "quota"}' WHERE account_id = pg_temp.acc() AND kind IN ('campaigns', 'locations', 'keywords');
UPDATE public.ads_config SET value = 'not json' WHERE key IN ('google_campaign_labels', 'google_areas_waiting');
SET ROLE authenticated;
SELECT pg_temp.ok(jsonb_array_length(h->'campaigns') = 2 AND (h->'campaigns'->0->>'label') = 'We-Aviation-Search-sep-2026' AND h->'campaigns'->0->'places' = '[]'::jsonb
  AND h->'areas_waiting' = '[]'::jsonb AND h->'status'->'reviewing' = '[]'::jsonb,
  'HM58 a failed snapshot or a broken label setting never breaks the screen: names fall back to Google''s, lists are empty')
  FROM (SELECT public.api_ads_google_home() h) x;
RESET ROLE;

-- results: Google's spend, the CRM's own enquiries, and how fast they were called
SELECT pg_temp.day(1, 300, 20); SELECT pg_temp.day(2, 150, 10, '24542430627'); SELECT pg_temp.day(8, 999, 50); SELECT pg_temp.day(0, 50, 5);
INSERT INTO public.ads_lead (pipeline, name, phone_e164, stage, first_touch, last_touch, created_at, first_response_at) VALUES
  ('pilot_training', 'Fast', '+919811460001', 'lead_created', '{"gclid":"g1","gad_campaignid":"24283129095"}', '{}', now() - interval '26 hours', now() - interval '26 hours' + interval '9 minutes'),
  ('pilot_training', 'Slow', '+919811460002', 'lead_created', '{"gclid":"g2","gad_campaignid":"24283129095"}', '{}', now() - interval '27 hours', now() - interval '20 hours'),
  ('pilot_training', 'Waiting', '+919811460003', 'lead_created', '{"gclid":"g3"}', '{}', now() - interval '28 hours', NULL),
  ('pilot_training', 'Old', '+919811460004', 'lead_created', '{"gclid":"g4"}', '{}', now() - interval '12 days', now() - interval '12 days' + interval '1 minute'),
  ('pilot_training', 'Meta', '+919811460005', 'lead_created', '{"fbclid":"f1"}', '{}', now() - interval '26 hours', NULL),
  ('pilot_training', 'Organic', '+919811460006', 'lead_created', '{}', '{}', now() - interval '26 hours', NULL);
INSERT INTO public.ads_lead (pipeline, name, phone_e164, stage, contact_status, first_touch, last_touch, created_at) VALUES
  ('pilot_training', 'Wrong', '+919811460007', 'lead_created', 'wrong_number', '{"gclid":"g7"}', '{}', now() - interval '26 hours');
SET ROLE authenticated;
SELECT pg_temp.ok((r->>'days')::int = 7 AND (r->>'spend')::numeric = 500 AND (r->>'clicks')::numeric = 35 AND (r->>'cpc')::numeric = 14.29
  AND (r->>'enquiries')::int = 3 AND (r->>'cost_per_enquiry')::numeric = 167 AND (r->>'called')::int = 2 AND (r->>'called_15m')::int = 1 AND (r->>'waiting')::int = 1
  AND jsonb_array_length(r->'series') = 7 AND (r->'series'->6->>'spend')::numeric = 50 AND (SELECT sum((s->>'enquiries')::int) = 3 FROM jsonb_array_elements(r->'series') s),
  'HM59 last 7 days: 500 spent, 35 clicks, 3 Google enquiries in the CRM (Meta, organic and wrong numbers not counted), 167 each, 1 of 3 called within 15 minutes, 1 still waiting')
  FROM (SELECT public.api_ads_google_home()->'results' r) x;
SELECT pg_temp.ok((public.api_ads_google_home(30)->'results'->>'enquiries')::int = 4 AND (public.api_ads_google_home(30)->'results'->>'spend')::numeric = 1499
  AND jsonb_array_length(public.api_ads_google_home(30)->'results'->'series') = 30
  AND (public.api_ads_google_home(13)->'results'->>'days')::int = 7 AND (public.api_ads_google_home(NULL)->'results'->>'days')::int = 7
  AND (public.api_ads_google_home(90)->'results'->>'days')::int = 90,
  'HM60 30 and 90 days work the same way; any other period falls back to 7');
RESET ROLE;
DELETE FROM public.ads_metrics_daily; UPDATE public.ads_lead SET deleted_at = now();
SET ROLE authenticated;
SELECT pg_temp.ok((r->>'spend')::numeric = 0 AND r->>'cpc' IS NULL AND r->>'cost_per_enquiry' IS NULL AND (r->>'enquiries')::int = 0,
  'HM61 nothing spent, nothing received: zeros and blanks, never a division by zero')
  FROM (SELECT public.api_ads_google_home()->'results' r) x;
RESET ROLE;

-- what needs the owner
DELETE FROM public.ads_google_ops;
INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, created_by_type, created_by) VALUES
  (pg_temp.acc(), 'ad_schedule', '{"campaign_id":"24283129095","slots":[{"start_hour":0,"end_hour":24,"bid_pct":-10}]}', 'AI: bid 10% lower all day', 'agent', NULL),
  (pg_temp.acc(), 'ad_schedule', '{"campaign_id":"24283129095","slots":[{"start_hour":0,"end_hour":24,"bid_pct":10}]}', 'Mine: bid 10% higher', 'user', '00000000-0000-0000-0000-00000000000a'),
  (pg_temp.acc(), 'ad_schedule', '{"campaign_id":"24283129095","slots":[{"start_hour":0,"end_hour":24,"bid_pct":20}]}', 'Colleague: bid 20% higher', 'user', '00000000-0000-0000-0000-00000000000c'),
  (pg_temp.acc(), 'ad_schedule', '{"campaign_id":"24283129095","slots":[{"start_hour":0,"end_hour":20}]}', 'Blocked one', 'user', '00000000-0000-0000-0000-00000000000a');
SET ROLE authenticated;
SELECT pg_temp.ok(jsonb_array_length(n->'ops') = 3
  AND (SELECT string_agg(o->>'by', ',' ORDER BY o->>'summary') = 'ai,team,you' FROM jsonb_array_elements(n->'ops') o)
  AND (n->>'suggestions')::int = 0 AND (n->>'queue')::int = 0,
  'HM62 waiting changes are labelled by who made them (AI suggestion, yours, a colleague''s); blocked ones are not offered for approval')
  FROM (SELECT public.api_ads_google_home()->'needs' n) x;
RESET ROLE;
SELECT pg_temp.ok((SELECT (length(value) - length(replace(value, 'Money and budget (25 Nov 2026)', ''))) / length('Money and budget (25 Nov 2026)') = 1
     AND value LIKE 'We One Aviation, pilot training institute%' AND value LIKE '%budget_set, owner only%' FROM public.ads_config WHERE key = 'google_brand_facts'),
  'HM63 the AI team is told once (146 ran twice) where the balance is and that the daily total is the owner''s');
INSERT INTO public.ads_google_ops (account_id, kind, payload, status, created_by_type) VALUES (pg_temp.acc(), 'budget_set', pg_temp.bs(200, 150, 50), 'pending', 'user');
\echo ALL HOME TESTS PASSED
