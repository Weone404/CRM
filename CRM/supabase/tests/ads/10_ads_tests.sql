-- ADS module SQL tests. Run by run.sh on a throwaway database after the stubs and 076.
-- Each check prints "PASS <name>"; the first failure stops the run with "FAIL <name>".
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF;
  RAISE NOTICE 'PASS %', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.fails(p_sql text, p_like text, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN RAISE NOTICE 'PASS %', name; RETURN; END IF;
    RAISE EXCEPTION 'FAIL % (wrong error: %)', name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL % (no error)', name;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Approver', 'IT', '10000000-0000-0000-0000-00000000000d');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES
  ('00000000-0000-0000-0000-00000000000c', false), ('00000000-0000-0000-0000-00000000000d', true);

CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;

-- ---------------------------------------------------------------- access
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.ok(NOT (public.api_ads_access()->>'can_view')::boolean, 'A01 sales user has no ADS access');
SELECT pg_temp.fails($$SELECT public.api_ads_overview(NULL, '2026-10-01', '2026-10-31')$$, '%do not have access%', 'A02 sales user cannot read overview');
SELECT pg_temp.ok(public.api_ads_clients() IS NULL, 'A03 sales user gets no client list');
SELECT pg_temp.fails($$SELECT * FROM public.ads_clients$$, '%permission denied%', 'A04 tables are not readable directly');
SELECT pg_temp.fails($$SELECT public.svc_ads_secrets()$$, '%permission denied%', 'A05 browser cannot call service functions');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_ads_access()->>'can_view')::boolean AND NOT (public.api_ads_access()->>'can_approve')::boolean, 'A06 viewer can view, not approve');
SELECT pg_temp.fails($$SELECT public.api_ads_settings()$$, '%Only Admin%', 'A07 settings are Admin only');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"X Co"}')$$, '%Only Admin%', 'A08 only Admin creates clients');

-- ---------------------------------------------------------------- settings / secrets
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($$SELECT public.api_ads_settings_save('GOOGLE_ADS_CLIENT_ID', 'abc')$$, '%apps.googleusercontent.com%', 'S01 Google client id format checked');
SELECT pg_temp.fails($$SELECT public.api_ads_settings_save('GOOGLE_ADS_REFRESH_TOKEN', 'abc def')$$, '%spaces%', 'S02 whitespace rejected');
SELECT pg_temp.fails($$SELECT public.api_ads_settings_save('SOMETHING_ELSE', 'x')$$, '%Unknown setting%', 'S03 unknown names rejected');
SELECT pg_temp.ok((public.api_ads_settings_save('META_ACCESS_TOKEN', 'EAAtestsecretvalue9876')->>'last4') = '9876', 'S04 secret saved, last4 returned');
SELECT pg_temp.ok(public.api_ads_settings()::text NOT LIKE '%EAAtestsecret%' AND (public.api_ads_settings()->'secrets'->'META_ACCESS_TOKEN'->>'set')::boolean,
  'S05 settings never return the secret value');
SELECT pg_temp.ok((SELECT count(*) FROM public.api_ads_activity(50) e WHERE e::text LIKE '%EAAtestsecret%') = 0, 'S06 activity log has no secret value');
SELECT pg_temp.ok((public.api_ads_settings_save('GOOGLE_ADS_LOGIN_CUSTOMER_ID', '123-456-7890')->>'last4') = '7890', 'S07 MCC id dashes stripped');
SELECT pg_temp.fails($$SELECT public.api_ads_settings_save('google_api_version', 'latest')$$, '%v26%', 'S08 API version format checked');

-- ---------------------------------------------------------------- clients / accounts
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
GRANT ALL ON ids TO authenticated, service_role;
INSERT INTO ids SELECT 'c1', public.api_ads_client_save('{"name":"We One Aviation","crm_segment":"aviation","target_cpl":"500","gross_margin_pct":"40","max_daily_budget":"3000"}');
INSERT INTO ids SELECT 'c2', public.api_ads_client_save('{"name":"Other Client","currency":"USD"}');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Dup","crm_segment":"aviation"}')$$, '%already linked%', 'C01 one client per CRM segment');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Bad","target_cpl":"-5"}')$$, '%positive number%', 'C02 negative economics rejected');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Bad2","timezone":"Mars/Base"}')$$, '%time zone%', 'C03 unknown time zone rejected');
SELECT pg_temp.fails(format($$SELECT public.api_ads_account_save('{"client_id":"%s","platform":"google","external_id":"12345"}')$$, (SELECT v FROM ids WHERE k='c1')),
  '%10 digits%', 'C04 Google customer id validated');
INSERT INTO ids SELECT 'ag', public.api_ads_account_save(jsonb_build_object('client_id', (SELECT v FROM ids WHERE k='c1'), 'platform', 'google', 'external_id', '111-222-3333', 'utm_source', 'google'));
INSERT INTO ids SELECT 'am', public.api_ads_account_save(jsonb_build_object('client_id', (SELECT v FROM ids WHERE k='c1'), 'platform', 'meta', 'external_id', 'act_998877', 'utm_source', 'facebook'));
INSERT INTO ids SELECT 'ax', public.api_ads_account_save(jsonb_build_object('client_id', (SELECT v FROM ids WHERE k='c2'), 'platform', 'google', 'external_id', '4445556666'));
SELECT pg_temp.ok((SELECT external_id FROM public.api_ads_accounts(NULL) a, jsonb_array_elements(a) e(x), LATERAL (SELECT x->>'external_id' external_id) z
   WHERE x->>'platform' = 'meta') = '998877', 'C05 act_ prefix stripped');
SELECT pg_temp.fails(format($$SELECT public.api_ads_account_save('{"client_id":"%s","platform":"google","external_id":"1112223333"}')$$, (SELECT v FROM ids WHERE k='c1')),
  '%already added%', 'C06 duplicate account rejected');

-- ---------------------------------------------------------------- sync (service role)
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_account_status((SELECT v FROM ids WHERE k='ag'), 'connected', NULL, 'WOA Google', 'INR', 'Asia/Kolkata');
SELECT public.svc_ads_account_status((SELECT v FROM ids WHERE k='am'), 'connected', NULL, 'WOA Meta', 'INR', 'Asia/Kolkata');
SELECT public.svc_ads_account_status((SELECT v FROM ids WHERE k='ax'), 'connected', NULL, 'Other', 'USD', 'America/New_York');
SELECT pg_temp.ok(public.svc_ads_upsert_campaigns((SELECT v FROM ids WHERE k='ag'), '[
  {"external_id":"g1","name":"Search CPL","status":"ENABLED","platform_status":"ENABLED","daily_budget":1000,"budget_ref":"customers/1112223333/campaignBudgets/9"},
  {"external_id":"g2","name":"Shared budget","status":"ENABLED","platform_status":"ENABLED","daily_budget":null,"budget_ref":null}]') = 2,
  'Y01 campaigns upserted');
SELECT public.svc_ads_upsert_campaigns((SELECT v FROM ids WHERE k='am'), '[{"external_id":"m1","name":"Lead form","status":"PAUSED","daily_budget":500,"budget_ref":"campaign"}]');
SELECT public.svc_ads_upsert_campaigns((SELECT v FROM ids WHERE k='ax'), '[{"external_id":"x1","name":"US","status":"ENABLED","daily_budget":50,"budget_ref":"customers/4445556666/campaignBudgets/1"}]');
SELECT pg_temp.ok(public.svc_ads_upsert_metrics((SELECT v FROM ids WHERE k='ag'), '[
  {"campaign_external_id":"g1","day":"2026-10-05","impressions":1000,"clicks":50,"spend":2500,"conversions":4,"conversion_value":0},
  {"campaign_external_id":"g1","day":"2026-10-06","impressions":1000,"clicks":50,"spend":2500,"conversions":4,"conversion_value":10000},
  {"campaign_external_id":"g2","day":"2026-10-06","impressions":0,"clicks":0,"spend":0},
  {"campaign_external_id":"unknown","day":"2026-10-06","impressions":5,"clicks":1,"spend":3}]') = 3, 'Y02 metrics for unknown campaigns are skipped');
SELECT public.svc_ads_upsert_metrics((SELECT v FROM ids WHERE k='ag'), '[{"campaign_external_id":"g1","day":"2026-10-06","impressions":1000,"clicks":50,"spend":2500,"conversions":4,"conversion_value":10000}]');
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_metrics_daily) = 3, 'Y03 re-sync of a day replaces it (no duplicates)');
SELECT public.svc_ads_upsert_metrics((SELECT v FROM ids WHERE k='ax'), '[{"campaign_external_id":"x1","day":"2026-10-06","impressions":100,"clicks":10,"spend":40}]');
RESET ROLE;
SELECT pg_temp.ok(crm_private.ads_div(5, 0) IS NULL AND crm_private.ads_div(NULL, 5) IS NULL AND crm_private.ads_div(1, 4, 100) = 25, 'M01 zero/missing denominators give NULL');

-- CRM leads (aviation segment): 4 from campaign g1, 1 via utm_source facebook, 1 organic, 1 charter
INSERT INTO public.lead (id, name, utm_source, utm_campaign, segment, is_eligible, closure_outcome, created_at) VALUES
  ('20000000-0000-0000-0000-000000000001', 'L1', 'google', 'woa_search', 'aviation', true, 'admission_completed', '2026-10-05 10:00+05:30'),
  ('20000000-0000-0000-0000-000000000002', 'L2', 'google', 'woa_search', 'aviation', NULL, NULL, '2026-10-05 11:00+05:30'),
  ('20000000-0000-0000-0000-000000000003', 'L3', 'google', 'WOA_SEARCH', 'aviation', NULL, NULL, '2026-10-06 09:00+05:30'),
  ('20000000-0000-0000-0000-000000000004', 'L4', 'google', 'woa_search', 'aviation', NULL, NULL, '2026-10-06 23:30+05:30'),
  ('20000000-0000-0000-0000-000000000005', 'L5', 'facebook', 'other', 'aviation', NULL, NULL, '2026-10-06 12:00+05:30'),
  ('20000000-0000-0000-0000-000000000006', 'L6', NULL, NULL, 'aviation', NULL, NULL, '2026-10-06 12:00+05:30'),
  ('20000000-0000-0000-0000-000000000007', 'L7', 'google', 'woa_search', 'charter', NULL, NULL, '2026-10-06 12:00+05:30');
INSERT INTO public.contact_attempt (lead_id, disposition) VALUES
  ('20000000-0000-0000-0000-000000000002', 'Interested'),
  ('20000000-0000-0000-0000-000000000003', 'Wrong number'),
  ('20000000-0000-0000-0000-000000000003', 'Interested');
UPDATE public.ads_campaigns SET utm_campaign = 'woa_search' WHERE external_id = 'g1';
INSERT INTO ids SELECT external_id, id FROM public.ads_campaigns;

SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT public.api_ads_revenue_add((SELECT v FROM ids WHERE k='c1'), 'sale', 150000, '2026-10-06', '20000000-0000-0000-0000-000000000001', 'Batch fee');
SELECT public.api_ads_revenue_add((SELECT v FROM ids WHERE k='c1'), 'refund', 10000, '2026-10-06');
SELECT pg_temp.fails(format($$SELECT public.api_ads_revenue_add('%s', 'sale', 0, '2026-10-06')$$, (SELECT v FROM ids WHERE k='c1')), '%above 0%', 'R01 zero revenue rejected');

DO $$
DECLARE o jsonb; c jsonb; crm jsonb;
BEGIN
  o := public.api_ads_overview((SELECT v FROM ids WHERE k='c1'), '2026-10-05', '2026-10-06');
  c := o->'clients'->0; crm := c->'crm';
  PERFORM pg_temp.ok((c->>'spend')::numeric = 5000, 'M02 platform spend = 5000');
  PERFORM pg_temp.ok((c->'platform'->0->>'ctr')::numeric = 5 AND (c->'platform'->0->>'cpc')::numeric = 50
    AND (c->'platform'->0->>'cpm')::numeric = 2500, 'M03 CTR 5%, CPC 50, CPM 2500');
  PERFORM pg_temp.ok((c->'platform'->0->>'platform_roas')::numeric = 2, 'M04 platform ROAS = 10000/5000 (platform value only)');
  PERFORM pg_temp.ok((crm->>'leads')::int = 5, 'M05 5 ad leads: 4 by campaign utm (case-insensitive) + 1 by account utm_source; organic and charter excluded');
  PERFORM pg_temp.ok((crm->>'valid')::int = 4, 'M06 wrong-number lead is not valid');
  PERFORM pg_temp.ok((crm->>'qualified')::int = 2, 'M07 qualified = interested or eligible, and valid');
  PERFORM pg_temp.ok((crm->>'customers')::int = 1, 'M08 one customer');
  PERFORM pg_temp.ok((crm->>'revenue')::numeric = 140000, 'M09 CRM revenue = sales - refunds = 140000');
  PERFORM pg_temp.ok((crm->>'cpl')::numeric = 1250 AND (crm->>'qualified_cpl')::numeric = 2500 AND (crm->>'cac')::numeric = 5000,
    'M10 CPL 1250, qualified CPL 2500, CAC 5000');
  PERFORM pg_temp.ok((crm->>'crm_roas')::numeric = 28, 'M11 CRM ROAS = 140000/5000, separate from platform ROAS');
  PERFORM pg_temp.ok((crm->>'contribution')::numeric = 51000, 'M12 contribution = 140000*40% - 5000');
  PERFORM pg_temp.ok((crm->>'lead_to_customer_pct')::numeric = 25, 'M13 lead-to-customer 1/4 = 25%');
  o := public.api_ads_overview((SELECT v FROM ids WHERE k='c2'), '2026-10-05', '2026-10-06');
  PERFORM pg_temp.ok(NOT (o->'clients'->0->>'crm_linked')::boolean AND jsonb_typeof(o->'clients'->0->'crm') = 'null',
    'M14 client without CRM link shows CRM as unavailable, not zero');
  PERFORM pg_temp.ok((o->'clients'->0->>'spend')::numeric = 40 AND o->'clients'->0->'platform'->0->>'currency' = 'USD', 'M15 USD client spend kept in USD');
  o := public.api_ads_overview(NULL, '2026-10-05', '2026-10-06');
  PERFORM pg_temp.ok(jsonb_array_length(o->'clients') = 2 AND jsonb_array_length(o->'by_platform'->'google') = 2,
    'M16 agency view keeps INR and USD totals apart');
  o := public.api_ads_overview((SELECT v FROM ids WHERE k='c1'), '2026-09-01', '2026-09-30');
  PERFORM pg_temp.ok(o->'clients'->0->'spend' = 'null'::jsonb AND (o->'clients'->0->'crm'->>'cpl') IS NULL, 'M17 no data gives NULL spend and NULL CPL, not 0');
  c := (SELECT e FROM jsonb_array_elements(public.api_ads_campaigns((SELECT v FROM ids WHERE k='c1'), '2026-10-05', '2026-10-06')) e WHERE e->>'name' = 'Search CPL');
  PERFORM pg_temp.ok((c->'crm'->>'leads')::int = 4 AND (c->>'cpl')::numeric = round(5000/3.0, 4), 'M18 campaign row: 4 leads, CPL over 3 valid');
  c := (SELECT e FROM jsonb_array_elements(public.api_ads_campaigns((SELECT v FROM ids WHERE k='c1'), '2026-10-05', '2026-10-06')) e WHERE e->>'name' = 'Shared budget');
  PERFORM pg_temp.ok(NOT (c->>'crm_linked')::boolean AND jsonb_typeof(c->'crm') = 'null', 'M19 unmapped campaign has no CRM numbers');
  PERFORM pg_temp.ok(jsonb_array_length(public.api_ads_leads((SELECT v FROM ids WHERE k='c1'), '2026-10-05', '2026-10-06')) = 5, 'M20 ad leads list');
END $$;

-- ---------------------------------------------------------------- guards and approvals
DO $$
DECLARE g1 uuid := (SELECT v FROM ids WHERE k='g1');
        g2 uuid := (SELECT v FROM ids WHERE k='g2');
        m1 uuid := (SELECT v FROM ids WHERE k='m1');
        r jsonb; q uuid;
BEGIN
  r := public.api_ads_check(g1, 'budget', '{"daily_budget": 1100}');
  PERFORM pg_temp.ok(jsonb_array_length(r->'blockers') = 0 AND jsonb_array_length(r->'confirms') = 0, 'G01 +10% budget passes');
  r := public.api_ads_check(g1, 'budget', '{"daily_budget": 1500}');
  PERFORM pg_temp.ok(r->'confirms'->0->>'code' = 'budget_change_confirm', 'G02 +50% needs a second confirm');
  r := public.api_ads_check(g1, 'budget', '{"daily_budget": 2500}');
  PERFORM pg_temp.ok(r->'blockers' @> '[{"code":"budget_change_max"}]', 'G03 +150% blocked');
  r := public.api_ads_check(g1, 'budget', '{"daily_budget": 3500}');
  PERFORM pg_temp.ok(r->'blockers' @> '[{"code":"budget_client_max"}]', 'G04 above client max daily budget blocked');
  r := public.api_ads_check(g2, 'budget', '{"daily_budget": 100}');
  PERFORM pg_temp.ok(r->'blockers' @> '[{"code":"budget_unknown"}]', 'G05 shared/unknown budget blocked');
  r := public.api_ads_check(m1, 'status', '{"status": "ENABLED"}');
  PERFORM pg_temp.ok(r->'confirms' @> '[{"code":"enable_confirm"}]', 'G06 turning a campaign on needs a second confirm');
  r := public.api_ads_check(m1, 'status', '{"status": "PAUSED"}');
  PERFORM pg_temp.ok(r->'blockers' @> '[{"code":"status_same"}]', 'G07 no-op status change blocked');

  r := public.api_ads_change_create(g1, 'budget', '{"daily_budget": 2500}', 'too big');
  PERFORM pg_temp.fails(format($f$SELECT public.api_ads_approve('%s')$f$, r->>'id'), '%must be fixed%', 'G08 blocked change cannot be approved');
  PERFORM public.api_ads_reject((r->>'id')::uuid, 'test');

  r := public.api_ads_change_create(g1, 'budget', '{"daily_budget": 1500}', 'raise');
  q := (r->>'id')::uuid;
  PERFORM pg_temp.ok((SELECT e->'before'->>'daily_budget' FROM jsonb_array_elements(public.api_ads_queue('pending')) e WHERE e->>'id' = q::text) = '1000.00', 'G09 before-snapshot recorded');
  PERFORM pg_temp.fails(format($f$SELECT public.api_ads_approve('%s')$f$, q), '%second confirm%', 'G10 approve without second confirm refused');
  PERFORM pg_temp.as_('c');
  PERFORM pg_temp.fails(format($f$SELECT public.api_ads_approve('%s', true)$f$, q), '%cannot approve%', 'G11 viewer cannot approve');
  PERFORM pg_temp.as_('d');
  PERFORM pg_temp.ok(public.api_ads_approve(q, true)->>'status' = 'approved', 'G12 approver approves with second confirm');
  PERFORM pg_temp.as_('a');
END $$;

-- execution (service role): emergency stop, claim, finish
RESET ROLE;
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_work()) = 0, 'E01 emergency stop: nothing to execute');
SELECT pg_temp.ok(NOT public.svc_ads_claim((SELECT id FROM public.ads_change_queue WHERE status = 'approved')), 'E02 emergency stop: claim refused');
RESET ROLE;
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_work()) = 1, 'E03 approved change is ready');
SELECT pg_temp.ok(public.svc_ads_claim((SELECT id FROM public.ads_change_queue WHERE status = 'approved')), 'E04 claim moves it to executing');
SELECT pg_temp.ok(NOT public.svc_ads_claim((SELECT id FROM public.ads_change_queue WHERE status = 'executing')), 'E05 a change cannot be claimed twice');
SELECT public.svc_ads_finish((SELECT id FROM public.ads_change_queue WHERE status = 'executing'), 'outcome_unknown', 'timeout', NULL);
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_unknown()) = 1, 'E06 unknown outcome is listed for re-check (not retried)');
SELECT public.svc_ads_finish((SELECT id FROM public.ads_change_queue WHERE status = 'outcome_unknown'), 'verified', NULL, '{"daily_budget": 1500}');
SELECT pg_temp.ok((SELECT daily_budget FROM public.ads_campaigns WHERE external_id = 'g1') = 1500, 'E07 verified change updates the campaign');
RESET ROLE;

-- stale: approved, then the platform changed the budget before execution
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT public.api_ads_approve((public.api_ads_change_create((SELECT v FROM ids WHERE k='g1'), 'budget', '{"daily_budget": 1600}')->>'id')::uuid);
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_upsert_campaigns((SELECT v FROM ids WHERE k='ag'), '[{"external_id":"g1","name":"Search CPL","status":"ENABLED","daily_budget":1400,"budget_ref":"customers/1112223333/campaignBudgets/9"}]');
SELECT pg_temp.ok(NOT public.svc_ads_claim((SELECT id FROM public.ads_change_queue WHERE status = 'approved')), 'E08 change approved against an old budget is not sent');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_change_queue WHERE status = 'stale') = 1, 'E09 it is marked stale');

SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT public.api_ads_change_create((SELECT v FROM ids WHERE k='g1'), 'budget', '{"daily_budget": 1450}');
SELECT public.api_ads_change_create((SELECT v FROM ids WHERE k='g1'), 'budget', '{"daily_budget": 1460}');
SELECT pg_temp.ok((public.api_ads_change_create((SELECT v FROM ids WHERE k='g1'), 'budget', '{"daily_budget": 1470}')->'guard_result'->'blockers')
  @> '[{"code":"changes_per_day"}]', 'G13 max 3 changes per campaign per day');

-- ---------------------------------------------------------------- recommendations, research, experiments
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_upsert_campaigns((SELECT v FROM ids WHERE k='am'), '[{"external_id":"m2","name":"Silent campaign","status":"ENABLED","daily_budget":800,"budget_ref":"campaign"}]');
SELECT public.svc_ads_upsert_metrics((SELECT v FROM ids WHERE k='am'), jsonb_build_array(
  jsonb_build_object('campaign_external_id', 'm2', 'day', (now() AT TIME ZONE 'Asia/Kolkata')::date - 2, 'impressions', 5000, 'clicks', 100, 'spend', 2600)));
RESET ROLE;
UPDATE public.ads_campaigns SET utm_campaign = 'silent' WHERE external_id = 'm2';
INSERT INTO ids SELECT 'm2', id FROM public.ads_campaigns WHERE external_id = 'm2';
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok(public.api_ads_recommend_run() = 1, 'X01 spend with no CRM leads creates a recommendation');
SELECT pg_temp.ok(public.api_ads_recommend_run() = 0, 'X02 running again does not duplicate it');
SELECT pg_temp.ok((SELECT r->>'alternatives' IS NOT NULL AND r->'proposed_change'->>'kind' = 'status' AND r->>'confidence' = 'medium'
  FROM jsonb_array_elements(public.api_ads_recommendations(NULL, 'open')) r LIMIT 1), 'X03 recommendation has alternatives, confidence and a proposed change');

SELECT pg_temp.fails(format($$SELECT public.api_ads_research_save('{"client_id":"%s","topic":"Pricing","observation":"Competitor fee is 45L","classification":"fact"}')$$,
  (SELECT v FROM ids WHERE k='c1')), '%source URL%', 'Z01 a fact without a source is rejected');
SELECT pg_temp.ok(public.api_ads_research_save(jsonb_build_object('client_id', (SELECT v FROM ids WHERE k='c1'), 'topic', 'Pricing',
  'observation', 'Fee page lists the CPL programme', 'classification', 'fact', 'source_url', 'https://example.org/fees')) > 0, 'Z02 sourced fact saved');
SELECT pg_temp.fails(format($$SELECT public.api_ads_experiment_save('{"client_id":"%s","name":"CTA","hypothesis":"Call now beats Enquire","primary_metric":"qualified leads","status":"done"}')$$,
  (SELECT v FROM ids WHERE k='c1')), '%confident%', 'Z03 a finished experiment must state confidence');
RESET ROLE;

\echo ALL ADS SQL TESTS PASSED
