-- 108: Website signals (WS01-06), website audiences (WA01), Strategy agents' funnel context (AX01). Runs after A6_.
RESET ROLE;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT NOT (v->'configured'->>'gsc')::boolean AND jsonb_array_length(v->'topics') = 0 AND NOT (v->'settings'->>'token_set')::boolean
    FROM public.api_ads_site_signals() v), 'WS01 before connecting: nothing configured, no topics, no token');
SELECT pg_temp.fails($q$SELECT public.api_ads_site_settings_save('sc-domain:weoneaviation.in', '123456789')$q$, '%Admin%', 'WS02 only Admin connects the website');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_site_settings_save('weoneaviation.in', '')$q$, '%sc-domain:example.com%', 'WS02b the Search Console site is checked');
SELECT pg_temp.fails($q$SELECT public.api_ads_site_settings_save('', 'G-ABC123')$q$, '%digits only%', 'WS02c the GA4 property ID is checked');
SELECT public.api_ads_site_settings_save('https://WeOneAviation.in', 'properties/123456789');
SELECT public.api_ads_settings_save('GOOGLE_SITE_REFRESH_TOKEN', '1//site-token-for-tests');
RESET ROLE;
SELECT pg_temp.ok(crm_private.ads_cfg('site_gsc_url') = 'https://weoneaviation.in/' AND crm_private.ads_cfg('site_ga4_property') = '123456789'
  AND 'GOOGLE_SITE_REFRESH_TOKEN' = ANY (crm_private.ads_secret_names()),
  'WS03 settings are normalised (trailing slash, digits only) and the website token is a Vault secret');
SET ROLE service_role;
SELECT pg_temp.ok((SELECT v->>'gsc_url' = 'https://weoneaviation.in/' AND v->>'ga4_property' = '123456789' FROM public.svc_ads_site_work() v)
  AND (public.svc_ads_secrets()->>'GOOGLE_SITE_REFRESH_TOKEN') = '1//site-token-for-tests', 'WS04 the job gets the site, property and sign-in');
SELECT public.svc_ads_site_save('gsc', '[
  {"kind": "query", "k1": "pilot training fees delhi", "win": "cur", "m": {"clicks": 30, "impressions": 900, "position": 6.1}},
  {"kind": "query", "k1": "pilot training fees delhi", "win": "prev", "m": {"clicks": 20, "impressions": 400, "position": 8}},
  {"kind": "query", "k1": "how to become pilot after 12th", "win": "cur", "m": {"clicks": 5, "impressions": 700, "position": 12}},
  {"kind": "query", "k1": "dgca ground classes", "win": "cur", "m": {"clicks": 12, "impressions": 150, "position": 4}},
  {"kind": "page", "k1": "https://weoneaviation.in/fees", "win": "cur", "m": {"clicks": 25, "impressions": 800}},
  {"kind": "bogus", "k1": "x", "win": "cur", "m": {}}]');
SELECT public.svc_ads_site_save('ga', '[
  {"kind": "landing", "k1": "/fees", "win": "cur", "m": {"sessions": 200, "engagedSessions": 120, "keyEvents": 9}},
  {"kind": "channel", "k1": "Organic Search", "win": "cur", "m": {"sessions": 500, "engagedSessions": 300, "keyEvents": 14}},
  {"kind": "channel", "k1": "Paid Social", "win": "cur", "m": {"sessions": 300, "engagedSessions": 90, "keyEvents": 6}},
  {"kind": "city", "k1": "Delhi", "k2": "Delhi", "win": "cur", "m": {"activeUsers": 260, "keyEvents": 8}},
  {"kind": "event", "k1": "form_start", "win": "cur", "m": {"eventCount": 70}},
  {"kind": "event", "k1": "generate_lead", "win": "cur", "m": {"eventCount": 18}}]');
SELECT public.svc_ads_site_done('{"gsc_rows": 5, "ga_rows": 6, "notes": []}', '{"id": "555666777", "name": "We One Pixel", "firing": true}');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 5 FROM public.ads_site_row WHERE src = 'gsc') AND (SELECT count(*) = 6 FROM public.ads_site_row WHERE src = 'ga'),
  'WS05 the job replaces a source''s rows; unknown kinds are dropped');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE ws AS SELECT public.api_ads_site_signals() v;
SELECT pg_temp.ok((SELECT (x->>'clicks')::int = 30 AND (x->>'change')::int = 50 AND x->'top' @> '["pilot training fees delhi"]' FROM ws, jsonb_array_elements(v->'topics') x WHERE x->>'key' = 'fees')
  AND (SELECT bool_or(x->>'key' = 'after12') AND bool_or(x->>'key' = 'dgca') AND bool_or(x->>'key' = 'local') FROM ws, jsonb_array_elements(v->'topics') x)
  AND (SELECT bool_or(x->>'query' = 'how to become pilot after 12th') AND NOT bool_or(x->>'query' = 'dgca ground classes' AND false) FROM ws, jsonb_array_elements(v->'rising') x)
  AND (SELECT (x->>'google_clicks')::int = 25 AND (x->>'sessions')::int = 200 AND (x->>'key_events')::int = 9 FROM ws, jsonb_array_elements(v->'pages') x WHERE x->>'page' = '/fees')
  AND (SELECT (v->'web_funnel'->>'sessions')::int = 800 AND (v->'web_funnel'->>'form_start')::int = 70 AND (v->'web_funnel'->>'form_submit')::int = 18 FROM ws)
  AND (SELECT (v->'pixel'->>'firing')::boolean AND (v->'totals'->>'clicks')::int = 47 FROM ws),
  'WS06 search intent topics with change and top searches, rising searches, landing pages joined across Search Console and GA4, the website funnel and the Pixel');
RESET ROLE; SET ROLE service_role;
SELECT pg_temp.ok((SELECT x->>'kind' = 'website' AND x->>'people' IS NULL FROM jsonb_array_elements(public.svc_ads_meta_audience_work()->'audiences') x WHERE x->>'key' = 'web_fees_30')
  AND public.svc_ads_meta_audience_work()->>'pixel_id' = '555666777',
  'WA01 website audiences go to the audience job with the Pixel id (rules only, no people)');
CREATE TEMP TABLE ax AS SELECT public.svc_ads_meta_strategy_extra() v;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'funnel_90d'->'stages') = 6 AND jsonb_array_length(v->'audiences') >= 15
    AND (SELECT bool_or(a->>'key' = 'crm_customers' AND (a->>'ready_in_meta')::boolean AND (a->>'excluded_by_default')::boolean) FROM jsonb_array_elements(v->'audiences') a)
    AND v->'locations' ? 'regions' AND jsonb_array_length(v->'website'->'topics') >= 3 AND length(v::text) < 30000 FROM ax),
  'AX01 the Strategy agents get the funnel, the audience library, location verdicts and website signals (kept small)');
RESET ROLE;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'stages') = 6 FROM (SELECT public.api_ads_meta_funnel(current_date - 30, current_date) v) z),
  'AX02 the funnel and location screens still work through their new inner functions');
RESET ROLE;
\echo ALL ADS META 108 TESTS PASSED
