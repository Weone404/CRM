-- 112 CRM > Website: WB01-WB16. Each check prints PASS <name>; the first failure stops the run.
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
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Approver', 'IT', '10000000-0000-0000-0000-00000000000d');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES
  ('00000000-0000-0000-0000-00000000000c', false), ('00000000-0000-0000-0000-00000000000d', true);
UPDATE public.ads_config SET value = 'sc-domain:weoneaviation.in' WHERE key = 'site_gsc_url';
UPDATE public.ads_config SET value = '430628737' WHERE key = 'site_ga4_property';
SELECT vault.create_secret('cid.apps.googleusercontent.com', 'ads_google_ads_client_id', 'x');
SELECT vault.create_secret('csecret', 'ads_google_ads_client_secret', 'x');
SELECT vault.create_secret('1//site', 'ads_google_site_refresh_token', 'x');

-- Data as the Edge Function would save it
SET ROLE service_role;
SELECT public.svc_web_save('gsc', ARRAY['date', 'query', 'page', 'device', 'query_page'], '[
  {"kind": "date", "k1": "2026-11-01", "win": "cur", "m": {"clicks": 30, "impressions": 1000, "position": 8}},
  {"kind": "date", "k1": "2026-11-02", "win": "cur", "m": {"clicks": 50, "impressions": 3000, "position": 6}},
  {"kind": "date", "k1": "2026-10-01", "win": "prev", "m": {"clicks": 40, "impressions": 2000, "position": 9}},
  {"kind": "query", "k1": "dgca pariksha", "win": "cur", "m": {"clicks": 40, "impressions": 2000, "ctr": 0.02, "position": 3.8}},
  {"kind": "query", "k1": "dgca pariksha", "win": "prev", "m": {"clicks": 20, "impressions": 1500, "ctr": 0.013, "position": 5.1}},
  {"kind": "query", "k1": "egca login", "win": "cur", "m": {"clicks": 4, "impressions": 900, "ctr": 0.004, "position": 8.7}},
  {"kind": "query", "k1": "egca login", "win": "prev", "m": {"clicks": 3, "impressions": 800, "ctr": 0.004, "position": 9.2}},
  {"kind": "query", "k1": "pariksha dgca", "win": "cur", "m": {"clicks": 2, "impressions": 800, "ctr": 0.0025, "position": 4.7}},
  {"kind": "query", "k1": "cpl fees", "win": "cur", "m": {"clicks": 1, "impressions": 60, "ctr": 0.016, "position": 14}},
  {"kind": "query", "k1": "cpl fees", "win": "prev", "m": {"clicks": 2, "impressions": 70, "ctr": 0.03, "position": 9}},
  {"kind": "query", "k1": "how to become pilot after 12th", "win": "cur", "m": {"clicks": 0, "impressions": 25, "ctr": 0, "position": 30}},
  {"kind": "query", "k1": "we one aviation", "win": "cur", "m": {"clicks": 16, "impressions": 60, "ctr": 0.26, "position": 1}},
  {"kind": "query_page", "k1": "cpl fees", "k2": "https://weoneaviation.in/cpl", "win": "cur", "m": {"clicks": 1, "impressions": 40, "position": 12}},
  {"kind": "query_page", "k1": "cpl fees", "k2": "https://weoneaviation.in/blogs/cpl-cost", "win": "cur", "m": {"clicks": 0, "impressions": 30, "position": 18}},
  {"kind": "page", "k1": "https://weoneaviation.in/dgca-pariksha", "win": "cur", "m": {"clicks": 60, "impressions": 3000, "position": 4.6}},
  {"kind": "page", "k1": "https://weoneaviation.in/cpl", "win": "cur", "m": {"clicks": 8, "impressions": 500, "position": 7}},
  {"kind": "device", "k1": "MOBILE", "win": "cur", "m": {"clicks": 60, "impressions": 3000, "position": 7}},
  {"kind": "bogus", "k1": "x", "win": "cur", "m": {}}]');
SELECT public.svc_web_save('ga', ARRAY['date', 'channel', 'source', 'ai_landing', 'device', 'newret', 'hour', 'event'], '[
  {"kind": "date", "k1": "20261101", "win": "cur", "m": {"activeUsers": 100, "newUsers": 80, "sessions": 150, "engagedSessions": 90, "userEngagementDuration": 6000, "keyEvents": 6, "screenPageViews": 400}},
  {"kind": "date", "k1": "20261001", "win": "prev", "m": {"activeUsers": 80, "sessions": 100, "engagedSessions": 50, "keyEvents": 4}},
  {"kind": "channel", "k1": "Organic Search", "win": "cur", "m": {"sessions": 120, "keyEvents": 5}},
  {"kind": "channel", "k1": "Organic Search", "win": "prev", "m": {"sessions": 90}},
  {"kind": "source", "k1": "chatgpt.com", "k2": "referral", "win": "cur", "m": {"sessions": 9, "keyEvents": 1}},
  {"kind": "source", "k1": "chatgpt.com", "k2": "referral", "win": "prev", "m": {"sessions": 3}},
  {"kind": "source", "k1": "perplexity.ai", "k2": "referral", "win": "cur", "m": {"sessions": 2}},
  {"kind": "source", "k1": "google", "k2": "organic", "win": "cur", "m": {"sessions": 110}},
  {"kind": "ai_landing", "k1": "chatgpt.com", "k2": "/cpl", "win": "cur", "m": {"sessions": 6}},
  {"kind": "ai_landing", "k1": "perplexity.ai", "k2": "/cpl", "win": "cur", "m": {"sessions": 2}},
  {"kind": "device", "k1": "mobile", "win": "cur", "m": {"activeUsers": 70, "sessions": 100}},
  {"kind": "newret", "k1": "new", "win": "cur", "m": {"activeUsers": 80}},
  {"kind": "newret", "k1": "returning", "win": "cur", "m": {"activeUsers": 20}},
  {"kind": "hour", "k1": "1", "k2": "11", "win": "cur", "m": {"sessions": 30}},
  {"kind": "event", "k1": "page_view", "win": "cur", "m": {"eventCount": 400}},
  {"kind": "event", "k1": "form_submit", "win": "cur", "m": {"eventCount": 7, "keyEvents": 6}}]');
SELECT public.svc_web_pages_save('[
  {"url": "https://weoneaviation.in/", "status": 200, "ms": 400, "title": "Home", "schema": ["Organization"], "issues": ["short_title"], "broken": [{"url": "https://weoneaviation.in/old", "status": 404}]},
  {"url": "https://weoneaviation.in/cpl", "status": 200, "ms": 2500, "noindex": true, "schema": [], "issues": ["noindex", "no_description", "no_schema"], "broken": [{"url": "https://weoneaviation.in/old", "status": 404}]},
  {"url": "https://weoneaviation.in/gone", "status": 404, "ms": 100, "issues": []}]');
SELECT public.svc_web_check_save('psi:https://weoneaviation.in/|mobile', '{"overall": "slow", "scores": {"performance": 41}, "field": {"lcp": {"p75": 4100, "rating": "slow"}}}');
SELECT public.svc_web_check_save('psi:https://weoneaviation.in/|desktop', '{"overall": "fast", "scores": {"performance": 92}}');
SELECT public.svc_web_check_save('inspect:https://weoneaviation.in/cpl', '{"verdict": "NEUTRAL", "coverage": "Excluded by noindex tag"}');
SELECT public.svc_web_check_save('robots', '{"bots": {"GPTBot": "blocked", "OAI-SearchBot": "allowed", "PerplexityBot": "blocked"}}');
SELECT public.svc_web_check_save('llms', '{"status": "missing"}');
SELECT public.svc_web_run_end(public.svc_web_run_begin('visitors'), 'ok', 'GA4 2 reports');
RESET ROLE;
INSERT INTO public.lead (name, utm_source, created_at, closure_outcome) VALUES
  ('a', 'website', now() - interval '2 days', NULL), ('b', 'website', now() - interval '3 days', 'admission_completed'),
  ('c', 'Book My Charter website', now() - interval '5 days', NULL), ('d', 'website', now() - interval '40 days', NULL);

SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_web_overview()$q$, '%not have access to the Website%', 'WB01 people without ADS access cannot open Website');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_web_access()->>'can_view')::boolean AND NOT (public.api_web_access()->>'can_run')::boolean, 'WB01b ADS viewers can look, not refresh');
SELECT pg_temp.fails($q$SELECT public.api_web_settings_save('https://weoneaviation.in/', '', NULL)$q$, '%Only Admin%', 'WB01c only Admin changes settings');
SELECT pg_temp.fails($q$SELECT public.api_web_copilot_upload('query', '[]')$q$, '%Only Admin or approvers%', 'WB01d viewers cannot upload');
CREATE TEMP TABLE o AS SELECT public.api_web_overview() v;
GRANT ALL ON o TO authenticated;
SELECT pg_temp.ok((SELECT (v->'search'->'cur'->>'clicks')::numeric = 80 AND (v->'search'->'cur'->>'impressions')::numeric = 4000
    AND (v->'search'->'cur'->>'ctr')::numeric = 0.02 AND (v->'search'->'cur'->>'position')::numeric = 6.5 AND (v->'search'->'prev'->>'clicks')::numeric = 40 FROM o),
  'WB03 search totals come from the per-day report (clicks 80, CTR 2%, position weighted by views 6.5)');
SELECT pg_temp.ok((SELECT (v->'search'->'counts'->>'almost')::int = 2 AND (v->'search'->'counts'->>'low_ctr')::int = 2 AND (v->'search'->'counts'->>'dropping')::int = 1
    AND (v->'search'->'counts'->>'new')::int = 3 AND (v->'search'->'counts'->>'cannibal')::int = 1 AND (v->'search'->'counts'->>'brand_clicks')::numeric = 16 FROM o),
  'WB04 opportunity counts: almost page 1, seen-not-clicked, dropping, new, split pages, brand clicks');
SELECT pg_temp.ok((SELECT v->'search'->'examples'->'almost'->0->>'query' = 'egca login' AND v->'search'->'examples'->'cannibal'->0->>'query' = 'cpl fees'
    AND jsonb_array_length(v->'search'->'examples'->'cannibal'->0->'pages') = 2 FROM o), 'WB04b examples name the searches and the competing pages');
SELECT pg_temp.ok((SELECT v->'search'->'top_queries'->0->>'query' = 'dgca pariksha' AND (v->'search'->'top_queries'->0->>'prev_pos')::numeric = 5.1 FROM o),
  'WB04c top searches carry last period''s position');
SELECT pg_temp.ok((public.api_web_queries('dropping')->>'total')::int = 1 AND (public.api_web_queries('questions')->'rows') @> '[{"query": "how to become pilot after 12th"}]' AND (public.api_web_queries('questions')->'rows') @> '[{"query": "cpl fees"}]'
    AND (public.api_web_queries('all', 'pariksha')->>'total')::int = 2 AND (public.api_web_queries('nonbrand')->>'total')::int = 5
    AND jsonb_array_length(public.api_web_queries('cannibal')->'rows'->0->'page_list') = 2, 'WB05 Searches list filters (questions include cost/fees searches), search box and competing pages');
SELECT pg_temp.fails($q$SELECT public.api_web_queries('bogus')$q$, '%Unknown filter%', 'WB05b unknown filters are refused');
SELECT pg_temp.ok((SELECT (v->'visitors'->'cur'->>'users')::numeric = 100 AND (v->'visitors'->'cur'->>'engaged_rate')::numeric = 60 AND (v->'visitors'->'cur'->>'avg_engagement_s')::numeric = 60
    AND (v->'visitors'->'channels'->0->>'prev_sessions')::numeric = 90 AND (v->'visitors'->'newret'->>'returning')::numeric = 20
    AND (v->'visitors'->'busiest'->0->>'hour')::int = 11 AND v->'visitors'->'events'->0->>'event' = 'form_submit' FROM o),
  'WB06 visitors: users, engaged rate, time on site, channels vs last period, new/returning, busiest hour, real actions only');
SELECT pg_temp.ok((SELECT v->'ai'->'tools'->0->>'tool' = 'ChatGPT' AND (v->'ai'->'tools'->0->>'sessions')::numeric = 9 AND (v->'ai'->'tools'->0->>'prev_sessions')::numeric = 3
    AND v->'ai'->'pages'->0->>'page' = '/cpl' AND v->'ai'->'pages'->0->>'tools' = 'ChatGPT, Perplexity' FROM o), 'WB07 AI visits by assistant, with the pages they land on');
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'speed') = 2 AND v->'speed'->0->>'strategy' = 'mobile' AND (v->'speed'->0->'scores'->>'performance')::int = 41 FROM o),
  'WB09 speed results per key page, mobile first');
SELECT pg_temp.ok((SELECT (v->'health'->'scan'->>'pages')::int = 3 AND (v->'health'->'scan'->>'errors')::int = 1 AND (v->'health'->'scan'->>'slow')::int = 1
    AND (v->'health'->'scan'->'issues'->>'noindex')::int = 1 AND v->'health'->'scan'->'broken'->0->>'url' = 'https://weoneaviation.in/old'
    AND (v->'health'->'scan'->'broken'->0->>'on_pages')::int = 2 FROM o), 'WB10 site scan: errors, slow pages, issue counts, broken links counted once per target');
SELECT pg_temp.ok((SELECT (v->'actions'->0->>'title') = 'GA4 sends no visitor data' IS FALSE FROM o), 'WB12a GA4 with data is not flagged');
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'actions') BETWEEN 5 AND 10
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' LIKE '1 page(s) tell Google not to index%')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' LIKE '1 key page(s) are not indexed%')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' = 'Fix 1 broken link(s) on the site')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' = 'Speed up 1 page(s) on mobile')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' = 'Push "egca login" onto page 1')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'actions') a WHERE a->>'title' LIKE 'robots.txt blocks 1 %') FROM o),
  'WB11 ranked fix list covers indexing, broken links, speed, near-page-1 searches and AI crawlers');
SELECT pg_temp.ok((SELECT bool_and((x.a->>'p')::int >= coalesce((y.a->>'p')::int, -1)) FROM o,
    LATERAL jsonb_array_elements(v->'actions') WITH ORDINALITY x(a, i) LEFT JOIN LATERAL jsonb_array_elements(v->'actions') WITH ORDINALITY y(a, j) ON y.j = x.i + 1),
  'WB11b most valuable first');
SELECT pg_temp.ok((SELECT (v->'leads'->>'cur')::int = 3 AND (v->'leads'->>'prev')::int = 1 AND (v->'leads'->>'admissions')::int = 1
    AND v->'leads'->'by_source'->0->>'source' = 'website' FROM o), 'WB13 leads from the website: this period, last period, admissions, by source');
SELECT pg_temp.ok((SELECT v->'runs'->'visitors'->>'status' = 'ok' FROM o), 'WB16 last run per job is shown');
SELECT pg_temp.as_('d');
SELECT pg_temp.ok((public.api_web_copilot_upload('query', '[{"k": "pilot training delhi", "citations": 12}, {"k": "cpl cost", "citations": 3}, {"k": "", "citations": 9}]')->>'saved')::int = 2,
  'WB08 approvers upload the Copilot CSV (empty rows skipped)');
SELECT public.api_web_copilot_upload('query', '[{"k": "cpl cost", "citations": 5}]');
SELECT pg_temp.ok((SELECT (v->'ai'->'copilot'->>'total')::numeric = 5 AND jsonb_array_length(v->'ai'->'copilot'->'queries') = 1 FROM (SELECT public.api_web_overview() v) z),
  'WB08b a new upload replaces the old one');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_web_settings_save('weoneaviation.in', '', NULL)$q$, '%https://weoneaviation.in/%', 'WB14 site address is checked');
SELECT pg_temp.fails($q$SELECT public.api_web_settings_save('https://weoneaviation.in', '/a', 'short')$q$, '%AIza%', 'WB14b API key format is checked');
SELECT public.api_web_settings_save('https://WeOneAviation.in', E'/cpl-course\n/ppl-course', 'AIzaSyD-test_key_0123456789abcdefghijkl');
SELECT pg_temp.ok((SELECT public.api_web_settings()->>'site_url' = 'https://weoneaviation.in/' AND public.api_web_settings()->'psi_key'->>'last4' = 'ijkl'
    AND position('AIzaSyD' IN public.api_web_settings()::text) = 0), 'WB14c settings saved; the API key is write-only (last 4 only)');
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT v->>'psi_key' = 'AIzaSyD-test_key_0123456789abcdefghijkl' AND v->>'refresh_token' = '1//site' AND v->>'gsc_url' = 'sc-domain:weoneaviation.in'
    AND v->'key_pages' ? 'https://weoneaviation.in/' AND v->'key_pages' ? 'https://weoneaviation.in/cpl-course' AND NOT (v->'key_pages' ? 'https://weoneaviation.in/dgca-pariksha')
    FROM (SELECT public.svc_web_work() v) z), 'WB02 the job gets the sign-in, the key and the chosen key pages (home first)');
RESET ROLE;
UPDATE public.web_config SET value = '' WHERE key = 'key_pages';
SET ROLE service_role;
SELECT pg_temp.ok((SELECT v->'key_pages' ? 'https://weoneaviation.in/dgca-pariksha' FROM (SELECT public.svc_web_work() v) z), 'WB02b with no key pages set, the top Google pages are used');
SELECT public.svc_web_save('ga', ARRAY['date'], '[]');
RESET ROLE;
SET ROLE authenticated;
SELECT pg_temp.as_('a');
SELECT pg_temp.ok((SELECT v->'actions'->0->>'title' = 'GA4 sends no visitor data' AND v->'actions'->0->>'go' = 'connections' FROM (SELECT public.api_web_overview() v) z),
  'WB12 GA4 connected but empty is the first thing to fix');
SELECT public.api_web_settings_save('https://weoneaviation.in/', '', '');
SELECT pg_temp.ok(public.api_web_settings()->'psi_key' IS NULL OR jsonb_typeof(public.api_web_settings()->'psi_key') = 'null', 'WB14d an empty key removes it');
RESET ROLE;
SELECT pg_temp.ok(NOT has_function_privilege('anon', 'public.api_web_overview()', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.svc_web_work()', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'public.web_row', 'SELECT'), 'WB15 not callable without signing in; data and job functions are private');
SELECT 'ALL WEBSITE SQL CHECKS PASSED';
