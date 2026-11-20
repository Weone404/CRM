-- 121: Meta Ads > Overview money and live campaigns (ML01-ML07). Runs after B1_ (uses A0_'s helpers and A2_'s account).
RESET ROLE;
DELETE FROM public.ads_meta_health;
INSERT INTO public.ads_meta_health (taken_at, data) VALUES (now() - interval '10 minutes',
  '{"account": {"status_text": "Active", "spend_cap": 46911.3, "amount_spent": 46431.51, "prepaid": 423.73, "cap_left": 479.79, "available": 423.73,
    "funding_text": "Available balance (₹423.73 INR)"}, "pacing": {"daily_budget": 0}, "delivery": {"campaigns": 0}}');
INSERT INTO public.ads_meta_strategy (title, status, goal, version, approved_version, build) VALUES ('Live test', 'approved', '{}', 1, 1,
  '{"version": 1, "posts": {"v1": {"permalink": "https://www.instagram.com/reel/A1/"}},
    "steps": {"form:f1": {"id": "777100", "status": "done"}, "campaign:c1": {"id": "7101", "status": "done"},
              "adset:a1": {"id": "8101", "status": "done"}, "ad:a1:v1": {"id": "9101", "status": "done"}, "ad:a1:v2": {"id": "9102", "status": "done"},
              "creative:v2:f1": {"status": "error"}}}');
CREATE TEMP TABLE ml121 AS SELECT id FROM public.ads_meta_strategy WHERE title = 'Live test';
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) SELECT id, 1,
  '{"campaigns": [{"key": "c1", "name": "CPL leads Delhi NCR"}], "budget": {"daily_total": 100, "monthly_total": 3000},
    "creatives": [{"key": "v1", "headline": "Pilot after 12th"}, {"key": "v2", "headline": "Parents: 3 questions"}]}' FROM ml121;
INSERT INTO public.ads_meta_object (account_id, level, external_id, campaign_ext, adset_ext, name, status) VALUES
  (pg_temp.acct(), 'campaign', '7101', NULL, NULL, 'CPL leads', 'ACTIVE'),
  (pg_temp.acct(), 'ad', '9101', '7101', '8101', 'v1', 'ACTIVE');
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, link_clicks, leads) VALUES
  (pg_temp.acct(), '9101', '8101', '7101', (now() AT TIME ZONE 'Asia/Kolkata')::date - 2, 100, 2000, 30, 20, 2),
  (pg_temp.acct(), '9101', '8101', '7101', (now() AT TIME ZONE 'Asia/Kolkata')::date, 80, 2120, 25, 15, 2),
  (pg_temp.acct(), '9102', '8101', '7101', (now() AT TIME ZONE 'Asia/Kolkata')::date, 132, 2960, 20, 12, 2);
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, stage, created_at, first_response_at) VALUES
  ('5b000000-0000-0000-0000-000000000121', 'pilot_training', 'Meena K', '+919811400121', 'qualified', now() - interval '3 hours', now() - interval '3 hours' + interval '4 minutes'),
  ('5b000000-0000-0000-0000-000000000122', 'pilot_training', 'Rohit S', '+919811400122', 'lead_created', now() - interval '12 minutes', NULL);
INSERT INTO public.ads_meta_lead_raw (source, external_id, form_id, ad_id, created_time, payload, status, lead_id) VALUES
  ('instant_form', 'lg121', '777100', '9101', now() - interval '3 hours', '{"answers": {"full_name": "Meena K", "phone_number": "+919811400121", "who_is_filling_this_form?": "parent_/_guardian"}}', 'ingested', '5b000000-0000-0000-0000-000000000121'),
  ('instant_form', 'lg122', '777100', '9102', now() - interval '12 minutes', '{"answers": {"when_do_you_want_to_start?": "in_1-3_months"}}', 'ingested', '5b000000-0000-0000-0000-000000000122'),
  ('instant_form', 'lg123', '777100', NULL, now() - interval '1 hour', '{}', 'organic', NULL);

SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE lv121 AS SELECT public.api_ads_meta_live() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT (v->'wallet'->>'available')::numeric = 423.73 AND (v->'wallet'->>'prepaid')::numeric = 423.73 AND (v->'wallet'->>'cap_left')::numeric = 479.79
    AND v->'wallet'->>'account' IS NOT NULL FROM lv121),
  'ML01 money left is the prepaid balance when it is lower than the spending limit left');
SELECT pg_temp.ok((SELECT (v->'wallet'->>'daily_budget')::numeric = 100 AND (v->'wallet'->>'days_left')::int = 3 AND NOT (v->'wallet'->>'low')::boolean FROM lv121),
  'ML02 days left counts GST (₹423.73 / ₹118 a day = 3 days); not low until under 3 days');
SELECT pg_temp.ok((SELECT c->>'name' = 'CPL leads Delhi NCR' AND c->>'status' = 'ACTIVE' AND (c->>'budget_total')::numeric = 3000 AND (c->>'used')::numeric = 312
    AND (c->>'today')::numeric = 212 AND (c->>'day')::int = 3 AND (c->>'meta_leads')::int = 2 AND (c->>'qualified')::int = 1 AND (c->>'cpl')::numeric = 156
    FROM lv121, jsonb_array_elements(v->'campaigns') c WHERE c->>'id' = '7101'),
  'ML03 a campaign shows budget used against the strategy total, today, day of the run, Meta leads (no test/organic) and CRM-qualified');
SELECT pg_temp.ok((SELECT jsonb_array_length(c->'ads') = 2 AND c->'ads'->0->>'name' = 'Pilot after 12th' AND (c->'ads'->0->>'spend')::numeric = 180
    AND (c->'ads'->0->>'leads')::int = 1 AND c->'ads'->0->>'post' = 'https://www.instagram.com/reel/A1/' AND c->'ads'->0->>'status' = 'ACTIVE'
    AND c->'ads'->1->>'status' = 'PAUSED' AND (c->'ads'->1->>'impressions')::int = 2960
    FROM lv121, jsonb_array_elements(v->'campaigns') c WHERE c->>'id' = '7101'),
  'ML04 one row per ad: its headline, spend, views, leads, status and the Instagram post');
SELECT pg_temp.ok((SELECT jsonb_array_length(c->'latest') = 2 AND c->'latest'->0->>'name' = 'Rohit S' AND c->'latest'->0->>'called_at' IS NULL
    AND (c->'latest'->0->>'wait_min')::int BETWEEN 11 AND 13 AND c->'latest'->1->>'stage' = 'Qualified Lead' AND (c->'latest'->1->>'wait_min')::int = 4
    AND NOT (c->'latest'->1->'answers')::text ~ '(9811400121|full_name)' AND c->'latest'->1->'answers'->0->>'q' = 'who_is_filling_this_form?'
    FROM lv121, jsonb_array_elements(v->'campaigns') c WHERE c->>'id' = '7101'),
  'ML05 latest responses: newest first, minutes waiting for a call (or minutes to the first call), answers without name or phone');
SELECT pg_temp.ok(crm_private.ads_meta_is_live() AND (SELECT (v->>'live')::boolean FROM lv121), 'ML06 an active campaign counts as live');
UPDATE public.ads_config SET value = (now() - interval '1 hour')::text WHERE key = 'meta_history_recent_at';
INSERT INTO public.ads_config (key, value) SELECT 'meta_history_recent_at', (now() - interval '1 hour')::text WHERE NOT EXISTS (SELECT 1 FROM public.ads_config WHERE key = 'meta_history_recent_at');
CREATE TEMP TABLE tk121 AS SELECT crm_private.ads_meta_live_tick() t;
SELECT pg_temp.ok((SELECT t FROM tk121) AND (SELECT value = '' FROM public.ads_config WHERE key = 'meta_history_recent_at'),
  'ML07a while live, the 15-minute tick makes the next history run refresh recent numbers');
UPDATE public.ads_meta_object SET status = 'PAUSED' WHERE level = 'campaign';
SELECT pg_temp.ok(NOT crm_private.ads_meta_live_tick(), 'ML07b nothing live: the tick does nothing');
SELECT pg_temp.ok(NOT has_function_privilege('anon', 'public.api_ads_meta_live()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'crm_private.ads_meta_live_tick()', 'EXECUTE'), 'ML08 reading needs sign-in; the tick is internal');
UPDATE public.ads_config SET value = (now() - interval '3 minutes')::text WHERE key = 'meta_history_recent_at';
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE lv122 AS SELECT public.api_ads_meta_live() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT (v->>'numbers_at')::timestamptz > now() - interval '4 minutes' AND v ? 'wallet' FROM lv122),
  'ML09 (122) "updated" is when the CRM last read Meta, even with no new spend rows');
\echo ALL ADS META 121 TESTS PASSED
