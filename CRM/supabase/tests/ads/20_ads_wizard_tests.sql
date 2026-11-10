-- ADS client wizard + import tests (migration 078). Runs in the same session right after 10_ads_tests.sql.
SET ROLE authenticated; SELECT pg_temp.as_('a');

-- options
SELECT pg_temp.ok((SELECT jsonb_array_length(public.api_ads_options()->'google.objective')) = 5
  AND (SELECT jsonb_array_length(public.api_ads_options()->'meta.objective')) = 6
  AND (SELECT jsonb_array_length(public.api_ads_options()->'meta.special_ad_category')) = 5, 'W01 option lists: 5 Google objectives, 6 Meta objectives, 5 special-ad answers');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($$SELECT public.api_ads_options()$$, '%do not have access%', 'W02 options need ADS access');
SELECT pg_temp.as_('a');

-- required per platform (not a draft)
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A"}')$$, '%Google, Meta or both%', 'W03 a client needs Google, Meta or both');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["google"]}')$$, '%campaign objective%', 'W04 Google needs an objective');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["google"],"google_settings":{"objective":"LEADS"}}')$$, '%campaign type%', 'W05 Google needs a campaign type');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["google"],"google_settings":{"objective":"LEADS","campaign_types":["APP"]}}')$$,
  '%do not support%', 'W06 App campaigns cannot use the Leads objective (Google''s own pairing)');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["google"],"google_settings":{"objective":"LEADS","campaign_types":["SEARCH"],"bidding":"WHATEVER"}}')$$,
  '%bidding%', 'W07 unknown bidding focus rejected');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["meta"],"meta_settings":{"objective":"OUTCOME_LEADS"}}')$$,
  '%special ad category%', 'W08 Meta needs the special ad category answer');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["meta"],"meta_settings":{"objective":"OUTCOME_LEADS","special_ad_categories":["NONE","HOUSING"]}}')$$,
  '%cannot be combined%', 'W09 None cannot be combined with a category');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["meta"],"meta_settings":{"objective":"OUTCOME_LEADS","special_ad_categories":["ISSUES_ELECTIONS_POLITICS"]}}')$$,
  '%country%', 'W10 political ads need a country');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","platforms":["meta"],"meta_settings":{"objective":"LEADS","special_ad_categories":["NONE"]}}')$$,
  '%unknown objective%', 'W11 only Meta''s own objective values are accepted');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Wiz A","website":"weone","platforms":["meta"],"meta_settings":{"objective":"OUTCOME_LEADS","special_ad_categories":["NONE"]}}')$$,
  '%full address%', 'W12 website must be a full address');

INSERT INTO ids SELECT 'w1', public.api_ads_client_save('{"name":"Wiz Both","website":"https://example.org","preset":"education","country":"in","platforms":["meta","google"],
  "google_settings":{"objective":"LEADS","campaign_types":["SEARCH","PERFORMANCE_MAX"],"bidding":"MAXIMIZE_CONVERSIONS"},
  "meta_settings":{"objective":"OUTCOME_LEADS","special_ad_categories":["NONE"],"special_ad_category_country":"IN","bid_strategy":"LOWEST_COST_WITHOUT_CAP"}}');
SELECT pg_temp.ok((SELECT c->>'country' = 'IN' AND c->'platforms' = '["google","meta"]' AND c->>'industry' = 'Education / training institute'
    AND c->'meta_settings'->'special_ad_category_country' IS NULL AND NOT (c->>'is_draft')::boolean
  FROM jsonb_array_elements(public.api_ads_clients()) c WHERE c->>'name' = 'Wiz Both'),
  'W13 client for Google + Meta saved; preset fills industry; country code upper-cased; no category -> no category country kept');

-- drafts: only the name is required, but values must still be valid
INSERT INTO ids SELECT 'w2', public.api_ads_client_save('{"name":"Half done","is_draft":true,"platforms":["google"]}');
SELECT pg_temp.ok((SELECT (c->>'is_draft')::boolean FROM jsonb_array_elements(public.api_ads_clients()) c WHERE c->>'name' = 'Half done'), 'W14 draft saved with only a name');
SELECT pg_temp.fails($$SELECT public.api_ads_client_save('{"name":"Bad draft","is_draft":true,"platforms":["google"],"google_settings":{"objective":"NOPE"}}')$$,
  '%unknown objective%', 'W15 a draft still refuses invalid values');

-- import
SELECT pg_temp.fails($$SELECT public.api_ads_import('{"client":{"name":"Imp"},"accounts":[]}')$$, '%at least one%', 'I01 import needs an account');
SELECT pg_temp.fails($$SELECT public.api_ads_import('{"accounts":[{"platform":"google","external_id":"5556667777"}]}')$$, '%Name the new client%', 'I02 new client needs a name');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.api_ads_import('{"client":{"name":"Imported Co","crm_segment":"charter"},"accounts":[
      {"platform":"google","external_id":"555-666-7777","name":"Imp G","currency":"USD","timezone":"America/New_York","login_customer_id":"9998887777"},
      {"platform":"meta","external_id":"act_123456","name":"Imp M","currency":"USD","timezone":"America/New_York"},
      {"platform":"google","external_id":"111-222-3333","name":"Already there"},
      {"platform":"google","external_id":"12","name":"Bad"}]}');
  PERFORM pg_temp.ok((r->>'added')::int = 2 AND jsonb_array_length(r->'skipped') = 2, 'I03 import adds new accounts, skips duplicates and invalid IDs');
  PERFORM pg_temp.ok((SELECT c->>'currency' = 'USD' AND c->>'timezone' = 'America/New_York' AND c->'platforms' = '["google","meta"]'
      AND (c->>'is_draft')::boolean AND c->>'crm_segment' = 'charter'
    FROM jsonb_array_elements(public.api_ads_clients()) c WHERE c->>'name' = 'Imported Co'),
    'I04 imported client takes currency and time zone from the account, platforms from what was imported, and stays a draft until set up');
  PERFORM pg_temp.ok((SELECT a->>'login_customer_id' = '9998887777' AND a->>'utm_source' = 'google' AND a->>'status' = 'not_synced'
    FROM jsonb_array_elements(public.api_ads_accounts(NULL)) a WHERE a->>'external_id' = '5556667777'),
    'I05 Google account keeps the manager it is reached through; status starts as not synced (never shown as connected)');
END $$;
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($$SELECT public.api_ads_import('{"client":{"name":"X"},"accounts":[{"platform":"meta","external_id":"999999"}]}')$$, '%Only Admin%', 'I06 only Admin imports');
RESET ROLE; SET ROLE service_role;
SELECT pg_temp.ok((SELECT a->>'login_customer_id' FROM jsonb_array_elements(public.svc_ads_accounts()) a WHERE a->>'external_id' = '5556667777') = '9998887777',
  'I07 sync gets the manager ID for imported Google accounts');
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_known_accounts()) >= 5, 'I08 known accounts listed for the import screen');
RESET ROLE;

\echo ALL ADS WIZARD TESTS PASSED
