-- 142 ADS delivery watch. DW01-DW24. Each check prints PASS <name>; the first failure stops the run.
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
-- the watch as the owner sees it (short name for the checks)
CREATE OR REPLACE FUNCTION pg_temp.w() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_google_delivery() $$;
-- one day of account numbers, n days ago, on a campaign
CREATE OR REPLACE FUNCTION pg_temp.day(p_ago int, p_spend numeric, p_impr int, p_camp text DEFAULT 'g1') RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, impressions, clicks)
  VALUES ((SELECT id FROM public.ads_campaigns WHERE external_id = p_camp), crm_private.ads_google_today() - p_ago, p_spend, p_impr, 0)
  ON CONFLICT (campaign_id, day) DO UPDATE SET spend = EXCLUDED.spend, impressions = EXCLUDED.impressions $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES ('00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW01 no Google Ads account: nothing to report');
INSERT INTO public.ads_clients (id, name) VALUES ('c1420000-0000-4000-8000-000000000001', 'We One Aviation');
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status, last_ok_at) VALUES
  ('a1420000-0000-4000-8000-000000000001', 'c1420000-0000-4000-8000-000000000001', 'google', '6318538100', 'We One', 'INR', 'Asia/Kolkata', 'connected', now()),
  ('a1420000-0000-4000-8000-000000000002', 'c1420000-0000-4000-8000-000000000001', 'meta', 'act_1', 'We One Meta', 'INR', 'Asia/Kolkata', 'connected', now());
INSERT INTO public.ads_campaigns (account_id, external_id, name, status, daily_budget) VALUES
  ('a1420000-0000-4000-8000-000000000001', 'g1', 'We-Aviation-Search', 'ENABLED', 200),
  ('a1420000-0000-4000-8000-000000000001', 'g0', 'Old campaign', 'PAUSED', 700),
  ('a1420000-0000-4000-8000-000000000002', 'm1', 'Meta leads', 'ENABLED', 150);
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW02 a campaign that has never spent is not "stopped"');
-- the Meta campaign spends every day: it must never hide or fake a Google stop
SELECT pg_temp.day(g, 120, 900, 'm1') FROM generate_series(0, 20) g;
-- an old run, two months ago
SELECT pg_temp.day(g, 500, 800, 'g0') FROM generate_series(60, 69) g;
-- the real case: 13-15 Nov spend, then a trickle of impressions with no clicks (today = 24 Nov in that story)
SELECT pg_temp.day(11, 399.88, 322), pg_temp.day(10, 399.94, 975), pg_temp.day(9, 47.55, 107);
SELECT pg_temp.day(8, 0, 5), pg_temp.day(7, 0, 8), pg_temp.day(6, 0, 9), pg_temp.day(5, 0, 3), pg_temp.day(3, 0, 1), pg_temp.day(0, 0, 1);
CREATE TEMP TABLE r AS SELECT pg_temp.w() j, crm_private.ads_google_today() t;
GRANT ALL ON r TO authenticated;
SELECT pg_temp.ok((SELECT j @> '{"stopped": true, "cause": "funds", "quiet_days": 8, "daily_budget": 200, "currency": "INR", "tax_pct": 18, "has_ledger": false, "crm_changes": 0}'
  AND (j->>'since')::date = t - 8 AND (j->>'last_spend_day')::date = t - 9 FROM r), 'DW03 the real case: stopped since the day after the last spend, most likely the balance');
SELECT pg_temp.ok((SELECT j->'run' @> '{"spend": 847.37, "with_tax": 999.90, "payment": 1000, "matches_payment": true}' AND (j->'run'->>'from')::date = t - 11 FROM r),
  'DW04 the run starts after the last long pause (the old campaign two months ago is not counted): 847.37 + 18% = 999.90, a payment of 1,000');
SELECT pg_temp.ok((SELECT (j->>'usual_impressions')::int = 468 AND (j->>'recent_impressions')::int = 3 AND (j->>'topup_30d')::int = 7100 FROM r), 'DW05 usual vs recent impressions, and what 30 days at this budget cost with tax');
SELECT pg_temp.ok((SELECT jsonb_array_length(j->'evidence') = 4 AND j->'evidence'->>0 = 'It was shown about 468 times a day before; since then about 3.'
  AND j->'evidence'->>1 = 'A campaign is switched on with INR 200 a day, and Google gives no reason for the stop.'
  AND j->'evidence'->>2 = format('Spend from %s to %s is INR 847.37. With 18%% tax that is 999.90, almost exactly one payment of INR 1,000.', to_char(t - 11, 'FMDD Mon'), to_char(t - 9, 'FMDD Mon'))
  AND j->'evidence'->>3 LIKE 'The CRM changed nothing in the account on %' FROM r), 'DW06 the evidence is given in plain sentences');
-- who may see it
SET ROLE anon;
SELECT pg_temp.fails($q$SELECT public.api_ads_delivery()$q$, '%permission denied%', 'DW07 signed-out visitors cannot call it');
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_ads_delivery()$q$, '%access%', 'DW07b staff without ADS access cannot see it');
SELECT pg_temp.fails($q$SELECT crm_private.ads_google_delivery()$q$, '%permission denied%', 'DW07c the internal function is closed');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok(public.api_ads_delivery() @> '{"stopped": true, "cause": "funds"}', 'DW08 anyone with ADS access sees it');
RESET ROLE;
-- not alarms
SELECT pg_temp.day(1, 12, 300);
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW09 spend yesterday: running');
SELECT pg_temp.day(1, 0, 0), pg_temp.day(0, 30, 200);
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW10 spending again today: the stop is over');
SELECT pg_temp.day(0, 0, 1), pg_temp.day(2, 5, 100);
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW11 one quiet day is not a stop');
SELECT pg_temp.day(2, 0, 0);
UPDATE public.ads_metrics_daily SET impressions = 60 WHERE spend = 0 AND campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1');
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW12 still shown a fair amount with no clicks: not a stop (nobody clicked)');
UPDATE public.ads_metrics_daily SET impressions = 2 WHERE spend = 0 AND campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1');
UPDATE public.ads_campaigns SET status = 'PAUSED' WHERE external_id = 'g1';
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW13 every campaign paused on purpose: not a stop');
UPDATE public.ads_campaigns SET status = 'ENABLED', daily_budget = 0 WHERE external_id = 'g1';
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW13b switched on with no budget: not this warning');
UPDATE public.ads_campaigns SET daily_budget = 200 WHERE external_id = 'g1';
UPDATE public.ads_accounts SET last_ok_at = now() - interval '3 days' WHERE platform = 'google';
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false, "stale": true}', 'DW14 the account has not synced for days: old numbers prove nothing');
UPDATE public.ads_accounts SET last_ok_at = now(), status = 'auth_required' WHERE platform = 'google';
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW14b sign-in lost: that is a different warning');
UPDATE public.ads_accounts SET status = 'connected' WHERE platform = 'google';
UPDATE public.ads_metrics_daily SET impressions = 20 WHERE spend > 0 AND day > crm_private.ads_google_today() - 20 AND campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1');
SELECT pg_temp.ok(pg_temp.w() = '{"stopped": false}', 'DW15 a tiny account (under 50 impressions a day) is too small to judge');
UPDATE public.ads_metrics_daily SET impressions = 400 WHERE spend > 0 AND day > crm_private.ads_google_today() - 20 AND campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1');
SELECT pg_temp.ok(pg_temp.w() @> '{"stopped": true, "cause": "funds", "quiet_days": 8}', 'DW16 back to the real case');
-- the money ledger
INSERT INTO public.ads_funds (account_id, amount, added_on) VALUES ('a1420000-0000-4000-8000-000000000001', 5000, crm_private.ads_google_today() - 11);
SELECT pg_temp.day(10, 300, 400);
SELECT pg_temp.ok((SELECT j @> '{"stopped": true, "cause": "unknown", "has_ledger": true}' AND (j->>'estimate')::numeric = 4252.57 AND j->'run' @> '{"matches_payment": false}'
  AND j->'evidence'->>2 = 'The money recorded in the CRM still shows about INR 4,253, so the balance may not be the reason.' FROM (SELECT pg_temp.w() j) z),
  'DW17 money still recorded and no round-payment pattern: stopped, reason unknown, and it says so');
UPDATE public.ads_funds SET amount = 760;
SELECT pg_temp.ok((SELECT j @> '{"cause": "funds"}' AND j->'evidence'->>2 LIKE 'Money recorded in the CRM: INR 760 added since %, all of it spent.' FROM (SELECT pg_temp.w() j) z), 'DW18 the ledger says the money is used up: funds');
DELETE FROM public.ads_funds;
SELECT pg_temp.ok(pg_temp.w() @> '{"cause": "unknown", "has_ledger": false}' AND jsonb_array_length(pg_temp.w()->'evidence') = 3, 'DW19 no ledger and no pattern: unknown, with what was checked');
SELECT pg_temp.day(10, 399.94, 975);
-- tax
UPDATE public.ads_accounts SET currency = 'USD' WHERE platform = 'google';
SELECT pg_temp.ok(pg_temp.w() @> '{"cause": "unknown", "tax_pct": 0, "currency": "USD"}', 'DW20 an account in another currency assumes no tax, so 847.37 is not a round payment');
INSERT INTO public.ads_config (key, value) VALUES ('google_tax_pct', '18') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT pg_temp.ok(pg_temp.w() @> '{"cause": "funds", "tax_pct": 18}', 'DW20b the tax rate can be set');
DELETE FROM public.ads_config WHERE key = 'google_tax_pct';
UPDATE public.ads_accounts SET currency = 'INR' WHERE platform = 'google';
-- changes the CRM made that day
INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, status, created_by_type, executed_at) VALUES
  ('a1420000-0000-4000-8000-000000000001', 'negative_add', '{}', 'Block searches', 'verified', 'agent', (crm_private.ads_google_today() - 9)::timestamp AT TIME ZONE 'Asia/Kolkata' + interval '10 hours'),
  ('a1420000-0000-4000-8000-000000000001', 'negative_add', '{}', 'Earlier', 'verified', 'agent', (crm_private.ads_google_today() - 12)::timestamp AT TIME ZONE 'Asia/Kolkata' + interval '10 hours'),
  ('a1420000-0000-4000-8000-000000000001', 'negative_add', '{}', 'Never sent', 'rejected', 'agent', NULL);
SELECT pg_temp.ok(pg_temp.w() @> '{"crm_changes": 1, "crm_changes_next_day": 0}' AND pg_temp.w()->'evidence'->>3 LIKE 'The CRM made 1 change(s) in the account on %, the last day with spend (ADS > Activity).', 'DW21 changes the CRM made on the last day with spend are pointed out, not hidden');
UPDATE public.ads_google_ops SET executed_at = executed_at + interval '1 day' WHERE summary = 'Block searches';
SELECT pg_temp.ok(pg_temp.w() @> '{"crm_changes": 0, "crm_changes_next_day": 1}' AND pg_temp.w()->'evidence'->>3 LIKE 'The CRM changed nothing on %, the last day with spend; it made 1 change(s) the next day.', 'DW21b changes made the day after are said to be the day after');
UPDATE public.ads_config SET value = '12.5' WHERE key = 'google_tax_pct';
INSERT INTO public.ads_config (key, value) VALUES ('google_tax_pct', '12.5') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT pg_temp.ok(pg_temp.w() @> '{"tax_pct": 12.5, "cause": "unknown"}', 'DW21c a tax rate with a decimal is used as given');
DELETE FROM public.ads_config WHERE key = 'google_tax_pct';
-- absurd data
UPDATE public.ads_metrics_daily SET impressions = NULL WHERE spend = 0;
SELECT pg_temp.ok(pg_temp.w() @> '{"stopped": true, "recent_impressions": 0}', 'DW22 days without an impression count are zero, not an error');
DELETE FROM public.ads_metrics_daily WHERE campaign_id = (SELECT id FROM public.ads_campaigns WHERE external_id = 'g1') AND spend = 0;
SELECT pg_temp.ok(pg_temp.w() @> '{"stopped": true, "quiet_days": 8, "recent_impressions": 0}', 'DW23 no rows at all for the quiet days (Google sent nothing): still seen as stopped');
SELECT pg_temp.ok((SELECT p.provolatile = 's' AND p.prosecdef AND p.proconfig::text LIKE '%search_path=%' FROM pg_proc p WHERE p.proname = 'ads_google_delivery')
  AND NOT has_function_privilege('anon', 'public.api_ads_delivery()', 'EXECUTE') AND has_function_privilege('authenticated', 'public.api_ads_delivery()', 'EXECUTE'), 'DW24 read-only, search path pinned, privileges as designed');
DO $$ BEGIN RAISE NOTICE 'ALL DELIVERY TESTS PASSED'; END $$;
