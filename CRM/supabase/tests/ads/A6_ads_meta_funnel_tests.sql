-- 107: Meta Ads > Funnel: funnel map (FN01-02), audience library (LB01-06), build exclusions (BW01), location focus (GEO01). Runs after A5_.
RESET ROLE;
INSERT INTO public.ads_consent_event (subject_phone, purpose, status, source)
SELECT '+91990000' || lpad(g::text, 4, '0'), 'ad_data_sharing', 'granted', 'web_form' FROM generate_series(100, 104) g
UNION ALL SELECT '+919900000200', 'ad_data_sharing', 'granted', 'web_form'
UNION ALL SELECT '+919900000201', 'ad_data_sharing', 'withdrawn', 'web_form';
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE fn AS SELECT public.api_ads_meta_funnel(current_date - 30, current_date) v;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'stages') = 6 AND (v->'stages'->2->>'n')::int >= 31 AND (v->'stages'->4->>'n')::int >= 15
    AND (v->'stages'->5->>'n')::int >= 3 AND (v->'stages'->4->>'from_prev') IS NOT NULL FROM fn)
  AND (SELECT bool_or(n #>> '{}' LIKE '%never called%') FROM fn, jsonb_array_elements(v->'notes') n),
  'FN01 the funnel map counts Meta leads, called, qualified and admissions, with the share moving on and plain notes');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_funnel(current_date, current_date - 1)$q$, '%Pick a period%', 'FN02 periods are checked');
CREATE TEMP TABLE au AS SELECT public.api_ads_meta_audiences() v;
SELECT pg_temp.ok((SELECT NOT (v->>'on')::boolean AND jsonb_array_length(v->'audiences') = 12 FROM au)
  AND (SELECT (x->>'eligible')::int = 6 FROM au, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_leads_30')
  AND (SELECT (x->>'eligible')::int = 5 FROM au, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_qualified_365')
  AND (SELECT (x->>'eligible')::int = 1 FROM au, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_customers')
  AND (SELECT (x->>'exclude_default')::boolean FROM au, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_customers'),
  'LB01 the library lists 12 audiences; CRM lists count only people whose consent allows sharing (withdrawn and missing consent left out)');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_audience_save('crm_lost_365', false, null)$q$, '%Admin%', 'LB02 only Admin changes audiences');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_audiences_on(true)$q$, '%Admin%', 'LB02b only Admin turns audiences on');
SELECT pg_temp.as_('a');
SELECT public.api_ads_meta_audience_save('crm_lost_365', false, null), public.api_ads_meta_audience_save('crm_hot_90', null, true), public.api_ads_meta_audiences_on(true);
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_audience_save('nope', true, null)$q$, '%Unknown audience%', 'LB02c unknown audiences are refused');
RESET ROLE;
SELECT pg_temp.ok((SELECT NOT enabled AND status = 'off' FROM public.ads_meta_audience WHERE key = 'crm_lost_365')
  AND (SELECT exclude_default FROM public.ads_meta_audience WHERE key = 'crm_hot_90') AND crm_private.ads_cfg('meta_audiences_on') = 'true',
  'LB03 Admin switches audiences on / off and picks the default exclusions');
SET ROLE service_role;
CREATE TEMP TABLE aw AS SELECT public.svc_ads_meta_audience_work() v;
SELECT pg_temp.ok((SELECT (v->>'on')::boolean AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_lost_365') FROM aw)
  AND (SELECT jsonb_array_length(x->'people') = 6 AND x->'people'->0->>0 ~ '^[0-9a-f]{64}$' AND x::text NOT LIKE '%+9199%'
         FROM aw, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'crm_leads_30')
  AND (SELECT x->'people' IS NULL OR x->'people' = 'null' FROM aw, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'ig_engaged_90'),
  'LB04 the job gets enabled audiences only, CRM people SHA-256 hashed (no raw numbers), none for engagement audiences');
SELECT public.svc_ads_meta_audience_saved('crm_customers', '{"meta_id": "23850000000001", "status": "ready", "size_low": 1000, "size_high": 1200, "members": 1}');
SELECT public.svc_ads_meta_audience_saved('form_dropoff_30', '{"meta_id": "23850000000002", "status": "ready", "size_low": 1500, "size_high": 1800}');
SELECT public.svc_ads_meta_audience_saved('ig_visit_30', '{"status": "error", "detail": "No Instagram professional account is linked to the Page"}');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'ready' AND meta_id = '23850000000001' AND size_high = 1200 AND members = 1 FROM public.ads_meta_audience WHERE key = 'crm_customers')
  AND (SELECT status = 'error' AND meta_id IS NULL AND detail LIKE 'No Instagram%' FROM public.ads_meta_audience WHERE key = 'ig_visit_30'),
  'LB05 the job saves the Meta id, size and problems');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT bool_or(x->>'key' = 'form_dropoff_30' AND (x->>'size_high')::int = 1800 AND x->>'status' = 'ready')
    FROM jsonb_array_elements(public.api_ads_meta_funnel(current_date - 30, current_date)->'warm') x),
  'LB06 the funnel map shows the warm and hot audiences waiting in Meta');
RESET ROLE;
INSERT INTO public.ads_meta_strategy (id, title, status, goal, version, approved_version, build)
VALUES (990107, 'Funnel test', 'approved', '{"objective": "leads"}', 1, 1, '{"status": "queued"}');
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) VALUES (990107, 1, '{"campaigns": []}');
SET ROLE service_role;
CREATE TEMP TABLE bw AS SELECT public.svc_ads_meta_build_work(990107) v;
SELECT pg_temp.ok((SELECT v->'audiences'->>'crm_customers' = '23850000000001' AND v->'audiences'->>'form_dropoff_30' = '23850000000002'
    AND NOT (v->'audiences' ? 'ig_visit_30') AND v->'default_excludes' = '["23850000000001"]' FROM bw),
  'BW01 Create in Meta gets ready audiences by key and the default exclusions (ready ones only)');
RESET ROLE;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE geo AS SELECT public.api_ads_meta_geo(current_date - 30, current_date) v;
SELECT pg_temp.ok((SELECT bool_or(r->>'region' = 'Delhi' AND (r->>'crm_leads')::int > 0) AND bool_or(r->>'region' = 'Rajasthan')
    AND bool_and(r->>'verdict' IN ('focus', 'keep', 'reduce', 'cut', 'too few leads')) FROM geo, jsonb_array_elements(v->'regions') r)
  AND (SELECT bool_or(c->>'city' = 'Jaipur' AND c->>'state' = 'Rajasthan') FROM geo, jsonb_array_elements(v->'cities') c),
  'GEO01 location focus maps form cities to states and gives each state a verdict');
RESET ROLE;
\echo ALL ADS META 107 TESTS PASSED
