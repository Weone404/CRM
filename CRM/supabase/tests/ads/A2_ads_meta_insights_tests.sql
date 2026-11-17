-- 103: Meta Ads > Insights. History rows (MI01-04), CRM outcomes per campaign / ad set / ad / form (MI05-09),
-- breakdowns (MI10), access (MI11-13), the history job's plan and progress (MI14-17), monthly summaries (MI18-20).
-- Runs after A1_ (uses A0_'s pg_temp helpers).
RESET ROLE;
INSERT INTO public.ads_clients (id, name) VALUES ('c1030000-0000-0000-0000-000000000103', 'Meta Insights Client') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status)
VALUES ('a1030000-0000-0000-0000-000000000103', 'c1030000-0000-0000-0000-000000000103', 'meta', '564511644492586', 'We One Meta', 'INR', 'Asia/Kolkata', 'connected')
ON CONFLICT (platform, external_id) DO UPDATE SET status = 'connected';
CREATE OR REPLACE FUNCTION pg_temp.acct() RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.ads_accounts WHERE platform = 'meta' AND external_id = '564511644492586' $$;
CREATE OR REPLACE FUNCTION pg_temp.d(n int) RETURNS text LANGUAGE sql AS $$ SELECT (current_date - n)::text $$;

-- campaigns 7001 (Winner) and 7002 (Loser); ad sets 8001 / 8002; ads 9001 (video, form 555) / 9002 (image)
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_meta_objects_save(pg_temp.acct(), jsonb_build_array(
  jsonb_build_object('level', 'campaign', 'external_id', '7001', 'name', 'Winner', 'status', 'ACTIVE', 'info', jsonb_build_object('objective', 'OUTCOME_LEADS')),
  jsonb_build_object('level', 'campaign', 'external_id', '7002', 'name', 'Loser', 'status', 'PAUSED'),
  jsonb_build_object('level', 'adset', 'external_id', '8001', 'campaign_ext', '7001', 'name', 'Delhi 18-24', 'info', jsonb_build_object('age_min', 18, 'age_max', 24)),
  jsonb_build_object('level', 'adset', 'external_id', '8002', 'campaign_ext', '7002', 'name', 'India 25-45'),
  jsonb_build_object('level', 'ad', 'external_id', '9001', 'campaign_ext', '7001', 'adset_ext', '8001', 'name', 'Reel',
    'info', jsonb_build_object('format', 'video', 'form_id', '555000111', 'body', 'Pilot banna hai?')),
  jsonb_build_object('level', 'ad', 'external_id', '9002', 'campaign_ext', '7002', 'adset_ext', '8002', 'name', 'Static',
    'info', jsonb_build_object('format', 'image')),
  jsonb_build_object('level', 'ad', 'external_id', 'not-an-id', 'name', 'x'))) = 6, 'MI01 campaigns, ad sets and ads are saved; a bad id is ignored');
-- a name from the numbers never wipes the creative saved before
SELECT public.svc_ads_meta_objects_save(pg_temp.acct(), '[{"level": "ad", "external_id": "9001", "name": "Reel (renamed)"}]');
RESET ROLE;
SELECT pg_temp.ok((SELECT name = 'Reel (renamed)' AND info->>'format' = 'video' AND adset_ext = '8001' FROM public.ads_meta_object WHERE level = 'ad' AND external_id = '9001'),
  'MI02 a name arriving with the numbers keeps the saved creative and parents');

SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_meta_ad_days_save(pg_temp.acct(), jsonb_build_array(
  jsonb_build_object('ad_ext', '9001', 'adset_ext', '8001', 'campaign_ext', '7001', 'day', pg_temp.d(10), 'spend', 1000, 'impressions', 10000, 'clicks', 200, 'leads', 10),
  jsonb_build_object('ad_ext', '9001', 'adset_ext', '8001', 'campaign_ext', '7001', 'day', pg_temp.d(9), 'spend', 1000, 'impressions', 10000, 'clicks', 150, 'leads', 10),
  jsonb_build_object('ad_ext', '9002', 'adset_ext', '8002', 'campaign_ext', '7002', 'day', pg_temp.d(10), 'spend', 3000, 'impressions', 20000, 'clicks', 100, 'leads', 5),
  jsonb_build_object('ad_ext', '9002', 'adset_ext', '8002', 'campaign_ext', '7002', 'day', pg_temp.d(45), 'spend', 500, 'impressions', 4000, 'clicks', 30, 'leads', 2),
  jsonb_build_object('ad_ext', 'bad', 'day', pg_temp.d(1), 'spend', 1))) = 4, 'MI03 ad-day rows are saved; a row without an ad id is ignored');
-- the same day again overwrites (Meta adjusts recent numbers)
SELECT public.svc_ads_meta_ad_days_save(pg_temp.acct(), jsonb_build_array(
  jsonb_build_object('ad_ext', '9001', 'adset_ext', '8001', 'campaign_ext', '7001', 'day', pg_temp.d(9), 'spend', 1200, 'impressions', 11000, 'clicks', 160, 'leads', 11)));
RESET ROLE;
SELECT pg_temp.ok((SELECT spend = 1200 AND leads = 11 FROM public.ads_meta_ad_day WHERE ad_ext = '9001' AND day = current_date - 9)
  AND (SELECT count(*) FROM public.ads_meta_ad_day WHERE ad_ext = '9001') = 2, 'MI04 a day saved again is replaced, not doubled');

-- CRM: Meta form leads from ad 9001 (one qualified, one admitted), one from 9002 (lost early), one website lead without ids
CREATE OR REPLACE FUNCTION pg_temp.mlead(p_phone text, p_stage text, p_touch jsonb, p_days int) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.ads_lead (pipeline, name, phone_e164, stage, first_touch, last_touch, created_at)
  VALUES ('pilot_training', 'MI ' || p_phone, '+91' || p_phone, p_stage, p_touch, p_touch, now() - make_interval(days => p_days)) RETURNING id $$;
SELECT pg_temp.mlead('9811500001', 'qualified', '{"fbclid": "fb.1", "meta_source": "instant_form", "ad_id": "9001", "adset_id": "8001", "utm_campaignid": "7001", "form_id": "555000111"}', 10);
SELECT pg_temp.mlead('9811500002', 'admission_completed', '{"fbclid": "fb.2", "meta_source": "instant_form", "ad_id": "9001", "adset_id": "8001", "utm_campaignid": "7001", "form_id": "555000111"}', 9);
SELECT pg_temp.mlead('9811500003', 'lead_created', '{"fbclid": "fb.3", "meta_source": "instant_form", "ad_id": "9002", "adset_id": "8002", "utm_campaignid": "7002"}', 10);
SELECT pg_temp.mlead('9811500004', 'contacted', '{"fbclid": "fb.4", "utm_source": "facebook", "utm_medium": "paid_social"}', 8);

SELECT pg_temp.as_('a'); SET ROLE authenticated;
CREATE OR REPLACE FUNCTION pg_temp.ins(p_campaign text DEFAULT NULL, p_form text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.api_ads_meta_insights(current_date - 30, current_date, p_campaign, p_form, NULL) $$;
GRANT EXECUTE ON FUNCTION pg_temp.ins(text, text) TO authenticated;
SELECT pg_temp.ok((SELECT (x->'current'->>'spend')::numeric = 5200 AND (x->'current'->>'meta_leads')::int = 26 AND (x->'current'->>'clicks')::int = 460
    AND (x->'current'->>'crm_leads')::int = 4 AND (x->'current'->>'qualified')::int = 2 AND (x->'current'->>'customers')::int = 1
    AND (x->'previous'->>'spend')::numeric = 500 FROM pg_temp.ins() x),
  'MI05 totals: Meta spend / clicks / leads and CRM leads / qualified / admitted, and the previous period');
SELECT pg_temp.ok((SELECT c->>'name' = 'Winner' AND (c->>'spend')::numeric = 2200 AND (c->>'crm_leads')::int = 2 AND (c->>'qualified')::int = 2
    AND (c->>'customers')::int = 1 AND c->>'objective' = 'OUTCOME_LEADS'
    FROM pg_temp.ins() x, jsonb_array_elements(x->'board'->'campaign') c WHERE c->>'ext' = '7001'),
  'MI06 each campaign gets its CRM outcomes from the ad ids its leads carry');
SELECT pg_temp.ok((SELECT a->'info'->>'format' = 'video' AND (a->>'customers')::int = 1 AND (a->>'days')::int = 2
    FROM pg_temp.ins() x, jsonb_array_elements(x->'board'->'ad') a WHERE a->>'ext' = '9001')
  AND (SELECT (s->>'qualified')::int = 0 FROM pg_temp.ins() x, jsonb_array_elements(x->'board'->'adset') s WHERE s->>'ext' = '8002')
  AND (SELECT (x->>'crm_unplaced')::int = 1 FROM pg_temp.ins() x),
  'MI07 ads carry creative and outcomes; a website lead without ad ids counts in totals only');
SELECT pg_temp.ok((SELECT (x->'current'->>'spend')::numeric = 2200 AND (x->'current'->>'crm_leads')::int = 2 FROM pg_temp.ins('7001') x)
  AND (SELECT (x->'current'->>'spend')::numeric = 2200 AND (x->'current'->>'customers')::int = 1 FROM pg_temp.ins(NULL, '555000111') x),
  'MI08 filters: by campaign and by lead form');
SELECT pg_temp.ok((SELECT jsonb_array_length(x->'trend') >= 1 AND jsonb_array_length(x->'weekday') >= 1
    AND x->'options'->'campaigns' @> '[{"ext": "7001", "name": "Winner"}]' AND (x->'coverage'->>'ads')::int = 2 FROM pg_temp.ins() x),
  'MI09 weekly trend, weekdays, filter options and coverage are included');

-- breakdowns: replaced for the months they cover
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_meta_breakdowns_save(pg_temp.acct(), 'age_gender', (date_trunc('month', current_date) - interval '1 month')::date, jsonb_build_array(
  jsonb_build_object('month', current_date::text, 'k1', '18-24', 'k2', 'male', 'spend', 100, 'leads', 4),
  jsonb_build_object('month', current_date::text, 'k1', '35-44', 'k2', 'female', 'spend', 60, 'leads', 0)));
SELECT public.svc_ads_meta_breakdowns_save(pg_temp.acct(), 'age_gender', (date_trunc('month', current_date) - interval '1 month')::date, jsonb_build_array(
  jsonb_build_object('month', current_date::text, 'k1', '18-24', 'k2', 'male', 'spend', 120, 'leads', 5)));
RESET ROLE;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_array_length(x->'breakdowns'->'age_gender') = 1 AND (x->'breakdowns'->'age_gender'->0->>'spend')::numeric = 120 FROM pg_temp.ins() x),
  'MI10 a breakdown saved again replaces its months (an old bucket does not linger)');

-- access
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_insights(current_date - 30, current_date)$q$, '%access%', 'MI11 someone without ADS access cannot see Insights');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_insights(current_date, current_date - 1)$q$, '%period%', 'MI11b an upside-down period is refused');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_insights(current_date - 2000, current_date)$q$, '%period%', 'MI11c more than about 3 years is refused');
SELECT public.api_ads_meta_note_save(current_date - 9, 'Exam results out');
SELECT pg_temp.ok((SELECT x->'notes'->0->>'text' = 'Exam results out' FROM pg_temp.ins() x), 'MI12 a note shows on the timeline');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_note_save(current_date, '')$q$, '%1 to 200%', 'MI12b an empty note is refused');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_note_save(current_date, 'x')$q$, '%Only Admin%', 'MI12c only Admin adds notes');
RESET ROLE;
SELECT pg_temp.fails($q$SET ROLE authenticated; SELECT count(*) FROM public.ads_meta_ad_day$q$, '%permission denied%', 'MI13 the browser cannot read the raw tables');
RESET ROLE; SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.svc_ads_meta_history_plan()$q$, '%permission denied%', 'MI13b ... nor call the history job''s functions');
RESET ROLE;

-- the history job's plan and progress
SET ROLE service_role;
SELECT pg_temp.ok((SELECT NOT (p->>'done')::boolean AND (p->>'recent_due')::boolean AND (p->>'breakdowns_due')::boolean AND (p->>'months')::int = 37
    AND p->>'cursor' = p->>'start' AND p->>'start' = (date_trunc('month', current_date) - interval '36 months')::date::text
    AND jsonb_array_length(p->'accounts') >= 1 FROM public.svc_ads_meta_history_plan() p),
  'MI14 the first plan: back-fill 37 months from the start, refresh and breakdowns due');
RESET ROLE;
SELECT pg_temp.ok(crm_private.ads_meta_history_wake(), 'MI14b the hourly cron wakes ads-sync while there is history work');
SET ROLE service_role;
SELECT public.svc_ads_meta_history_mark('{"cursor": "2025-01-01"}');
SELECT pg_temp.ok((SELECT p->>'cursor' = '2025-01-01' FROM public.svc_ads_meta_history_plan() p), 'MI15 the back-fill resumes where it stopped');
SELECT public.svc_ads_meta_history_mark('{"done": true, "recent": true, "breakdowns": true}');
RESET ROLE;
UPDATE public.ads_meta_report SET month = month WHERE false;
INSERT INTO public.ads_meta_report (month, data) VALUES ((date_trunc('month', current_date) - interval '1 month')::date, '{}') ON CONFLICT DO NOTHING;
SELECT pg_temp.ok(NOT crm_private.ads_meta_history_wake(), 'MI16 when everything is done and fresh, the cron does not wake ads-sync');
DELETE FROM public.ads_meta_report;
UPDATE public.ads_config SET value = (now() - interval '2 days')::text WHERE key = 'meta_history_recent_at';
SET ROLE service_role;
SELECT pg_temp.ok((SELECT (p->>'done')::boolean AND (p->>'recent_due')::boolean AND NOT (p->>'breakdowns_due')::boolean FROM public.svc_ads_meta_history_plan() p),
  'MI17 after a day the recent refresh is due again; breakdowns weekly');
RESET ROLE;

-- monthly summary
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, leads)
VALUES (pg_temp.acct(), '9001', '8001', '7001', (date_trunc('month', current_date) - interval '1 month')::date + 3, 700, 5000, 50, 3)
ON CONFLICT (ad_ext, day) DO NOTHING;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT p->>'report_month' = (date_trunc('month', current_date) - interval '1 month')::date::text FROM public.svc_ads_meta_history_plan() p),
  'MI18 last month''s summary is due once the history is complete');
SELECT pg_temp.ok((SELECT (d->'current'->>'spend')::numeric >= 700 AND d->'period'->>'from' = (date_trunc('month', current_date) - interval '1 month')::date::text
    FROM public.svc_ads_meta_report_data((date_trunc('month', current_date) - interval '1 month')::date) d), 'MI18b its numbers cover exactly that month');
SELECT public.svc_ads_meta_report_save((date_trunc('month', current_date) - interval '1 month')::date,
  public.svc_ads_meta_report_data((date_trunc('month', current_date) - interval '1 month')::date), '[{"title": "Video ads win"}]', false, 'CRM email is not set up');
SELECT pg_temp.ok((SELECT p->>'report_month' IS NULL FROM public.svc_ads_meta_history_plan() p), 'MI18c ... and is built once');
SELECT pg_temp.ok(NOT (public.svc_ads_meta_mail_config()->>'ready')::boolean, 'MI19 without CRM email set up nothing is sent');
RESET ROLE;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT r->'reports'->0->'patterns'->0->>'title' = 'Video ads win' AND r->'reports'->0->>'email_error' = 'CRM email is not set up'
    AND NOT (r->>'email_ready')::boolean FROM public.api_ads_meta_reports() r), 'MI20 saved summaries are listed with why they were not emailed');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_emails_save('["ops@weoneaviation.in"]')$q$, '%Only Admin%', 'MI20b only Admin sets the recipients');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_emails_save('["not an email"]')$q$, '%valid email%', 'MI20c bad addresses are refused');
SELECT public.api_ads_meta_report_emails_save('["ops@weoneaviation.in"]');
SELECT pg_temp.ok(public.api_ads_meta_reports()->'emails' = '["ops@weoneaviation.in"]', 'MI20d recipients are saved');
RESET ROLE;
\echo ALL ADS META 103 TESTS PASSED
