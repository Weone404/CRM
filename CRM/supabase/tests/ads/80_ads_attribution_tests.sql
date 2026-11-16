-- 098: CRM leads from ads are counted by the campaign id the ad click carries. Runs after 10_-70_.
-- Enquiries go in through the real entry point (svc_ads_ingest_enquiry), shaped like a real Google ad click.
RESET ROLE;
-- The ADS test stub has no CRM core; the ingest needs this one helper (same text as the live function, see ../intake/00_live_core.sql).
CREATE OR REPLACE FUNCTION crm_private.norm_phone(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE WHEN d ~ '^91\d{10}$' THEN '+' || d WHEN length(d) = 10 THEN '+91' || d ELSE '+' || d END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x $$;
DELETE FROM public.lead WHERE name LIKE 'Alloc%';
DELETE FROM public.ads_change_queue; DELETE FROM public.ads_metrics_daily;
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
UPDATE public.ads_config SET value = '1500' WHERE key = 'google_cap_daily';
UPDATE public.ads_campaigns SET external_id = '24283129095', utm_campaign = NULL, status = 'ENABLED', daily_budget = 1000,
  raw = raw || '{"primary_status_reasons": []}' WHERE external_id = 'g1';
UPDATE public.ads_campaigns SET external_id = '555000111' WHERE external_id = 'm1';
CREATE TEMP TABLE t8 AS
  SELECT c.id camp, a.id acc, a.client_id client, crm_private.ads_google_today() today
    FROM public.ads_campaigns c JOIN public.ads_accounts a ON a.id = c.account_id WHERE c.external_id = '24283129095';
GRANT SELECT ON t8 TO authenticated, service_role;
UPDATE public.ads_clients SET crm_segment = NULL, target_cpl = NULL WHERE id = (SELECT client FROM t8);
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend, clicks) SELECT camp, today, 400, 20 FROM t8;

-- A Google ad click as it really arrives: no utm_campaign text, the ids only inside the landing page URL.
CREATE OR REPLACE FUNCTION pg_temp.click(p_name text, p_phone text, p_camp text DEFAULT '24283129095', p_extra jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT public.svc_ads_ingest_enquiry(jsonb_build_object('name', p_name, 'phone', p_phone, 'gclid', 'Cj0-' || p_phone, 'gbraid', '0AAA',
    'utm_source', 'google', 'utm_medium', 'cpc', 'utm_term', 'commercial pilot course', 'utm_content', '831464041389',
    'submission_id', 'sub-' || p_phone || '-' || coalesce(p_camp, 'none'),
    'landing_page', 'https://weoneaviation.in/pilot-training-in-delhi?utm_source=google&utm_medium=cpc&utm_campaign=' ||
       coalesce('&utm_campaignid=' || p_camp, '') || '&utm_adgroup=&utm_adgroupid=200162758466&utm_term=commercial%20pilot%20course&utm_matchtype=p' ||
       '&utm_content=831464041389&device=m&gclid=Cj0-' || p_phone || '&gad_source=1' || coalesce('&gad_campaignid=' || p_camp, '') || '&gbraid=0AAA')
    || p_extra, 'pilot_training') $$;
CREATE OR REPLACE FUNCTION pg_temp.ov() RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.api_ads_overview((SELECT client FROM t8), (SELECT today FROM t8) - 6, (SELECT today FROM t8))->'clients'->0 $$;
CREATE OR REPLACE FUNCTION pg_temp.cid(p_ext text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT c.id::text FROM public.ads_campaigns c WHERE c.external_id = p_ext $$;
CREATE OR REPLACE FUNCTION pg_temp.camp(p_ext text DEFAULT '24283129095') RETURNS jsonb LANGUAGE sql AS $$
  SELECT e FROM jsonb_array_elements(public.api_ads_campaigns((SELECT client FROM t8), (SELECT today FROM t8) - 6, (SELECT today FROM t8))) e
   WHERE e->>'id' = pg_temp.cid(p_ext) $$;
CREATE OR REPLACE FUNCTION pg_temp.ctx() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT crm_private.ads_agent_context(r) FROM public.ads_agent_runs r ORDER BY r.id LIMIT 1 $$;
CREATE OR REPLACE FUNCTION pg_temp.rep(p_day date DEFAULT NULL) RETURNS int LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (crm_private.ads_report_data(coalesce(p_day, crm_private.ads_google_today()))->>'crm_leads')::int $$;
CREATE OR REPLACE FUNCTION pg_temp.num(t jsonb, VARIADIC n text[]) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_touch_num(t, VARIADIC n) $$;
CREATE OR REPLACE FUNCTION pg_temp.plat(t jsonb) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_touch_platform(t) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- reading the click
SELECT pg_temp.ok(pg_temp.num('{"utm_campaignid": "24283129095"}', 'gad_campaignid', 'utm_campaignid') = '24283129095', 'L01 campaign id given as its own field is read');
SELECT pg_temp.ok(pg_temp.num('{"landing_page": "https://x.in/p?utm_campaign=&utm_campaignid=111222333&gclid=abc&gad_source=1&gad_campaignid=24283129095&gbraid=0A"}',
  'gad_campaignid', 'utm_campaignid') = '24283129095', 'L02 campaign id is read from inside the landing page URL (Google''s own gad_campaignid first)');
SELECT pg_temp.ok(pg_temp.num('{"landing_page": "https://x.in/p?gad_campaignid=24283129095"}', 'gad_campaignid') = '24283129095'
  AND pg_temp.num('{"page_url": "https://x.in/p?a=1&gad_campaignid=24283129095#form"}', 'gad_campaignid') = '24283129095',
  'L03 works at the end of the URL, before a #anchor, and from the page URL when there is no landing page');
SELECT pg_temp.ok(pg_temp.num('{"utm_campaignid": "24283129095; DROP TABLE lead", "landing_page": "https://x.in/?gad_campaignid=12ab&xgad_campaignid=999999&gad_campaignid=%7Bcampaignid%7D"}',
  'gad_campaignid', 'utm_campaignid') IS NULL, 'L04 junk, injected text, look-alike names and unfilled {placeholders} are never taken as an id');
SELECT pg_temp.ok(pg_temp.num(NULL, 'gad_campaignid') IS NULL AND pg_temp.num('[]', 'gad_campaignid') IS NULL AND pg_temp.num('"text"', 'gad_campaignid') IS NULL
  AND pg_temp.num('{}', 'gad_campaignid') IS NULL AND pg_temp.num('{"landing_page": 5}', 'gad_campaignid') IS NULL, 'L05 empty, missing or malformed touches give nothing and no error');
SELECT pg_temp.ok(pg_temp.plat('{"gclid": "x"}') = 'google' AND pg_temp.plat('{"wbraid": "x"}') = 'google' AND pg_temp.plat('{"fbclid": "x"}') = 'meta'
  AND pg_temp.plat('{"utm_source": "Google", "utm_medium": "CPC"}') = 'google' AND pg_temp.plat('{"utm_source": "instagram", "utm_medium": "paid_social"}') = 'meta',
  'L06 the platform comes from the click id, else from a paid UTM');
SELECT pg_temp.ok(pg_temp.plat('{"utm_source": "google", "utm_medium": "organic"}') IS NULL AND pg_temp.plat('{"utm_source": "newsletter", "utm_medium": "cpc"}') IS NULL
  AND pg_temp.plat('{}') IS NULL AND pg_temp.plat(NULL) IS NULL, 'L07 organic Google visits and unknown paid sources are not credited to an ad platform');

-- ---------------------------------------------------------------- one real ad enquiry, everywhere
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.ok(NOT (pg_temp.ov()->>'crm_linked')::boolean AND pg_temp.camp()->'crm' = 'null'::jsonb,
  'L08 before any ad enquiry: CRM numbers show as not available, never as a false 0');
RESET ROLE;
SELECT pg_temp.click('Asha Verma', '9811200001');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(NOT quarantined) FROM public.ads_lead), 'L09 the enquiry is stored as one ad lead');
SELECT pg_temp.ok(pg_temp.rep() = 1, 'L10 the daily report counts it (it said 0 before)');
SELECT pg_temp.ok((SELECT (c->>'crm_leads_30d')::int = 1 AND (c->>'crm_qualified_30d')::int = 0 FROM jsonb_array_elements(pg_temp.ctx()->'campaigns') c WHERE c->>'id' = '24283129095'),
  'L11 the agents see 1 CRM lead on that campaign');
SELECT pg_temp.ok((SELECT l->>'keyword' = 'commercial pilot course' AND l->>'ad_id' = '831464041389' AND l->>'ad_group_id' = '200162758466'
    AND l->>'campaign_id' = '24283129095' AND l->>'stage' = 'lead_created' FROM jsonb_array_elements(pg_temp.ctx()->'ad_leads_30d') l),
  'L12 the agents see which keyword, ad and ad group brought it');
SELECT pg_temp.ok((pg_temp.ctx()->'ad_leads_30d')::text NOT LIKE '%Asha%' AND (pg_temp.ctx()->'ad_leads_30d')::text NOT LIKE '%9811200001%'
  AND (pg_temp.ctx()->'ad_leads_30d')::text NOT LIKE '%Cj0-%' AND (pg_temp.ctx()->'ad_leads_30d')::text NOT LIKE '%landing_page%',
  'L13 no name, phone number or click id of the person is sent to the agents');
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok((pg_temp.ov()->>'crm_linked')::boolean AND (pg_temp.ov()->'crm'->>'leads')::int = 1 AND (pg_temp.ov()->'crm'->>'valid')::int = 1
  AND (pg_temp.ov()->'crm'->>'cpl')::numeric = 400, 'L14 Today / overview: 1 enquiry, and cost per lead = spend / leads (400)');
SELECT pg_temp.ok((SELECT (public.api_ads_overview((SELECT client FROM t8), (SELECT today FROM t8) - 6, (SELECT today FROM t8))->'leads_trend'->0->>'leads')::int = 1),
  'L15 the leads chart has the day');
SELECT pg_temp.ok((pg_temp.camp()->>'crm_linked')::boolean AND (pg_temp.camp()->'crm'->>'leads')::int = 1 AND (pg_temp.camp()->>'cpl')::numeric = 400,
  'L16 Campaigns: the lead is on its campaign with no UTM set up');
SELECT pg_temp.ok((SELECT bool_and((e->>'crm_linked')::boolean AND (e->'crm'->>'leads')::int = 0) FROM jsonb_array_elements(
    public.api_ads_campaigns((SELECT client FROM t8), (SELECT today FROM t8) - 6, (SELECT today FROM t8))) e WHERE e->>'id' <> (SELECT camp::text FROM t8)),
  'L17 the client''s other campaigns show a true 0');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails('SELECT pg_temp.ov()', '%do not have access%', 'L18 people without ADS access still see nothing');
SELECT pg_temp.fails('SELECT * FROM crm_private.ads_ad_leads()', '%permission denied%', 'L19 the lead list behind the counts cannot be read from the browser');
RESET ROLE;

-- ---------------------------------------------------------------- what must not be counted
SELECT pg_temp.click('Asha Verma', '9811200001');                                      -- double tap on Submit: same submission id
SELECT pg_temp.click('Asha V', '9811200001', '24283129095', '{"submission_id": "again-next-day"}');   -- same person enquires again
SELECT pg_temp.ok(pg_temp.rep() = 1 AND (SELECT count(*) FROM public.ads_enquiry) = 2, 'L20 a double tap and a repeat enquiry by the same person are still one lead');
SELECT pg_temp.click('Spam Bot', '9811200002');
UPDATE public.ads_lead SET quarantined = true, quarantine_reasons = '{test}' WHERE phone_e164 LIKE '%9811200002';
SELECT pg_temp.ok(pg_temp.rep() = 1, 'L21 a quarantined (spam / test) lead is not counted');
UPDATE public.ads_lead SET quarantined = false, quarantine_reasons = '{}', deleted_at = now() WHERE phone_e164 LIKE '%9811200002';
SELECT pg_temp.ok(pg_temp.rep() = 1, 'L22 a deleted lead is not counted');

SELECT pg_temp.click('No Campaign', '9811200003', NULL);                                -- a click id but no campaign id at all
SELECT pg_temp.click('Other Campaign', '9811200004', '99999999999');                    -- a campaign id that is not ours
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'leads')::int = 3 AND (pg_temp.camp()->'crm'->>'leads')::int = 1,
  'L23 an ad click without a known campaign id counts for the account, and is not pinned on any campaign');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.rep() = 3, 'L24 ... and the Google daily report includes it');
SELECT public.svc_ads_ingest_enquiry('{"name": "Meta Person", "phone": "9811200005", "fbclid": "IwAR-1", "submission_id": "m-1",
  "landing_page": "https://weoneaviation.in/?utm_campaignid=24283129095&fbclid=IwAR-1"}', 'pilot_training');
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.ok((pg_temp.camp()->'crm'->>'leads')::int = 1, 'L25 a Meta click carrying a Google campaign id is not credited to the Google campaign');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.rep() = 3, 'L26 ... and never appears in the Google report (Google and Meta stay separate)');
UPDATE public.ads_lead SET deleted_at = now() WHERE phone_e164 NOT LIKE '%9811200001' AND deleted_at IS NULL;   -- enquiries are append-only; leads are removed the way the CRM does it

-- ---------------------------------------------------------------- how far the lead got
UPDATE public.ads_lead SET contact_status = 'wrong_number';
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'leads')::int = 1 AND (pg_temp.ov()->'crm'->>'valid')::int = 0 AND pg_temp.ov()->'crm'->'cpl' = 'null'::jsonb,
  'L27 a wrong number is an enquiry but not a valid lead, and cost per lead is blank instead of dividing by zero');
RESET ROLE; UPDATE public.ads_lead SET contact_status = 'valid', stage = 'interested'; SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'qualified')::int = 0, 'L28 "Interested" is not yet a qualified lead');
RESET ROLE; UPDATE public.ads_lead SET stage = 'qualified'; SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'qualified')::int = 1 AND (pg_temp.ov()->'crm'->>'customers')::int = 0 AND (pg_temp.camp()->>'qualified_cpl')::numeric = 400,
  'L29 the Qualified Lead stage counts as qualified');
RESET ROLE; UPDATE public.ads_lead SET stage = 'admission_completed'; SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'customers')::int = 1 AND (pg_temp.ov()->'crm'->>'qualified')::int = 1 AND (pg_temp.ov()->'crm'->>'cac')::numeric = 400,
  'L30 an admission counts as a customer, with the cost per customer');
RESET ROLE; UPDATE public.ads_lead SET stage = 'lost'; SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'leads')::int = 1 AND (pg_temp.ov()->'crm'->>'qualified')::int = 0 AND (pg_temp.ov()->'crm'->>'customers')::int = 0,
  'L31 a lost lead stays an enquiry but is neither qualified nor a customer');
RESET ROLE; UPDATE public.ads_lead SET stage = 'lead_created';

-- ---------------------------------------------------------------- days, double counting
UPDATE public.ads_lead SET created_at = ((SELECT today FROM t8)::timestamp + interval '20 minutes') AT TIME ZONE crm_private.ads_google_tz();   -- 00:20 India time
SELECT pg_temp.ok(pg_temp.rep() = 1 AND pg_temp.rep((SELECT today - 1 FROM t8)) = 0, 'L32 a lead just after midnight India time belongs to the new day (same day as Google''s spend)');
UPDATE public.ads_lead SET created_at = now();
UPDATE public.ads_clients SET crm_segment = 'aviation' WHERE id = (SELECT client FROM t8);
UPDATE public.ads_campaigns SET utm_campaign = 'woa_search' WHERE id = (SELECT camp FROM t8);
INSERT INTO public.lead (name, utm_source, utm_campaign, segment, created_at) VALUES ('Asha Verma', 'google', 'woa_search', 'aviation', now());
UPDATE public.ads_lead SET organic_lead_id = (SELECT id FROM public.lead WHERE name = 'Asha Verma' ORDER BY created_at DESC LIMIT 1);
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.ok((pg_temp.ov()->'crm'->>'leads')::int = 1 AND (pg_temp.camp()->'crm'->>'leads')::int = 1, 'L33 a person who is in both lead lists is counted once');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.rep() = 1, 'L34 ... also in the daily report');
INSERT INTO public.lead (name, utm_source, utm_campaign, segment, created_at) VALUES ('Old Style', 'google', 'woa_search', 'aviation', now());
SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.camp()->'crm'->>'leads')::int = 2, 'L35 leads matched the old way (UTM text) still count next to the new ones');
RESET ROLE;
DELETE FROM public.lead WHERE name IN ('Asha Verma', 'Old Style');
UPDATE public.ads_lead SET organic_lead_id = NULL;
UPDATE public.ads_clients SET crm_segment = NULL WHERE id = (SELECT client FROM t8);
UPDATE public.ads_campaigns SET utm_campaign = NULL WHERE id = (SELECT camp FROM t8);

-- ---------------------------------------------------------------- budget allocator
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL; DELETE FROM public.ads_metrics_daily; DELETE FROM public.ads_change_queue;
UPDATE public.ads_clients SET target_cpl = 500 WHERE id = (SELECT client FROM t8);
INSERT INTO public.ads_metrics_daily (campaign_id, day, spend) SELECT camp, today - g, 200 FROM t8, generate_series(1, 10) g;   -- 2,000 spent, 4x the target
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_allocate()->'actions') = 0,
  'L36 no ad enquiry was ever received for this client: lead counting is unproven, so the allocator does NOT cut the budget for "0 leads"');
RESET ROLE;
SELECT pg_temp.click('Lead ' || g, '98112010' || lpad(g::text, 2, '0')) FROM generate_series(1, 4) g;
UPDATE public.ads_lead SET created_at = now() - interval '2 days';
UPDATE public.ads_lead SET contact_status = 'wrong_number' WHERE name = 'Lead 4';
UPDATE public.ads_metrics_daily SET spend = 100;                                         -- 1,000 spent / 3 valid leads = 333 each
UPDATE public.ads_campaigns SET raw = raw || '{"primary_status_reasons": ["BUDGET_CONSTRAINED"]}' WHERE id = (SELECT camp FROM t8);
SET ROLE service_role; SELECT public.svc_ads_allocate(); RESET ROLE;
SELECT pg_temp.ok((SELECT (after->>'daily_budget')::numeric = 1150 AND summary LIKE '%3 CRM leads%' FROM pg_temp.cq('24283129095')),
  'L37 3 valid ad leads under the target cost and Google says budget-limited: +15%, counted by campaign id (the wrong number is left out)');
DELETE FROM public.ads_change_queue;
UPDATE public.ads_lead SET created_at = now() - interval '40 days';                    -- the leads are old; the last 14 days brought none
UPDATE public.ads_metrics_daily SET spend = 200;
UPDATE public.ads_campaigns SET raw = raw || '{"primary_status_reasons": []}' WHERE id = (SELECT camp FROM t8);
SET ROLE service_role; SELECT public.svc_ads_allocate(); RESET ROLE;
SELECT pg_temp.ok((SELECT (after->>'daily_budget')::numeric = 800 FROM pg_temp.cq('24283129095')),
  'L38 counting is proven and 14 days of spend brought no lead: -20%');
DELETE FROM public.ads_change_queue; UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
UPDATE public.ads_clients SET target_cpl = NULL WHERE id = (SELECT client FROM t8);

\echo ALL ADS ATTRIBUTION TESTS PASSED
