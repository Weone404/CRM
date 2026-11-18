-- 111 Connections & keys: VT01-VT12. Each check prints PASS <name>; the first failure stops the run.
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
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b');
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text) TO authenticated;

-- Other stores, as the real modules would leave them
SELECT vault.create_secret('tok-charter-abcd', 'crm_charter_ingest_token', 'x');
INSERT INTO crm_private.ai_integration (provider, vault_id, last4) VALUES ('groq', gen_random_uuid(), 'Gq12');
INSERT INTO flightbridge.integration_secret (name, ciphertext, last4, last_test_ok, last_test_message) VALUES ('tavily_api_key', 'enc', 'tv99', true, 'OK');
INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ('00000000-0000-0000-0000-00000000000a', 'connection_token_viewed', 'connection', '{"id": "charter"}');

SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_vault_overview()$q$, '%Only Admin%', 'VT01 only Admin opens Connections & keys');
SELECT pg_temp.fails($q$SELECT public.api_vault_amz_remove('AMZ_REFRESH_TOKEN')$q$, '%Only Admin%', 'VT01b only Admin removes keys');
SELECT pg_temp.as_('a');
SELECT public.api_ads_settings_save('GOOGLE_ADS_CLIENT_ID', '1234-abc.apps.googleusercontent.com');
SELECT public.api_ads_settings_save('META_ACCESS_TOKEN', 'EAAsecretvalue9876');
SELECT public.api_amz_settings_save('AMZ_REFRESH_TOKEN', 'Atzr|secret-refresh-zz11');
SELECT public.api_amz_settings_save('AMZ_SELLER_ID', 'A1SELLER42');
SELECT public.api_ads_site_settings_save('sc-domain:weoneaviation.in', '430628737');

CREATE TEMP TABLE v AS SELECT public.api_vault_overview() AS o;
SELECT pg_temp.ok((SELECT o->'ads'->'GOOGLE_ADS_CLIENT_ID'->>'value' = '1234-abc.apps.googleusercontent.com' FROM v),
  'VT02 non-secret IDs come back in full, ready to copy');
SELECT pg_temp.ok((SELECT o->'ads'->'META_ACCESS_TOKEN'->>'last4' = '9876' AND NOT (o->'ads'->'META_ACCESS_TOKEN' ? 'value') FROM v),
  'VT03 secrets come back as last 4 only, never the value');
SELECT pg_temp.ok((SELECT position('EAAsecretvalue' IN o::text) = 0 AND position('secret-refresh' IN o::text) = 0 AND position('tok-charter' IN o::text) = 0 FROM v),
  'VT03b no secret value appears anywhere in the answer');
SELECT pg_temp.ok((SELECT NOT (o->'ads'->'GOOGLE_ADS_DEVELOPER_TOKEN'->>'set')::boolean FROM v), 'VT04 missing keys show as not saved');
SELECT pg_temp.ok((SELECT o->'amz'->'AMZ_SELLER_ID'->>'value' = 'A1SELLER42' AND o->'amz'->'AMZ_REFRESH_TOKEN'->>'last4' = 'zz11'
    AND NOT (o->'amz'->'AMZ_REFRESH_TOKEN' ? 'value') FROM v), 'VT05 Amazon: seller ID shown, refresh token masked');
SELECT pg_temp.ok((SELECT o->'ads_status'->'site'->>'gsc_url' = 'sc-domain:weoneaviation.in' AND o->'ads_status'->'site'->>'ga4_property' = '430628737' FROM v),
  'VT06 website settings are listed with Google');
SELECT pg_temp.ok((SELECT o->'ai'->0->>'provider' = 'groq' AND o->'ai'->0->>'last4' = 'Gq12' AND o->'fb'->0->>'name' = 'tavily_api_key'
    AND (o->'fb'->0->>'last_test_ok')::boolean FROM v), 'VT07 AI keys and FlightBridge keys are included with their status');
SELECT pg_temp.ok((SELECT (o->'inbound'->'charter'->>'set')::boolean AND o->'inbound'->'charter'->>'last4' = 'abcd' AND NOT (o->'inbound'->'charter' ? 'value')
    AND NOT (o->'inbound'->'partner'->>'set')::boolean FROM v), 'VT08 inbound tokens: status and last 4 only');
SELECT pg_temp.ok((SELECT jsonb_array_length(o->'activity') >= 5
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(o->'activity') a WHERE a->>'action' = 'connection_token_viewed' AND a->>'who' = 'Admin')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(o->'activity') a WHERE a->>'action' = 'secret_saved' AND a->>'what' = 'META_ACCESS_TOKEN') FROM v),
  'VT09 activity log merges ADS, Amazon and CRM changes with who did it');
SELECT pg_temp.ok((SELECT bool_and(x.at >= coalesce(y.at, '-infinity')) FROM v,
    LATERAL (SELECT (a->>'at')::timestamptz at, i FROM jsonb_array_elements(o->'activity') WITH ORDINALITY t(a, i)) x
    LEFT JOIN LATERAL (SELECT (a->>'at')::timestamptz at FROM jsonb_array_elements(o->'activity') WITH ORDINALITY t2(a, j) WHERE j = x.i + 1) y ON true),
  'VT09b activity is newest first');
SELECT pg_temp.fails($q$SELECT public.api_vault_amz_remove('NOT_A_KEY')$q$, '%Unknown Amazon key%', 'VT10 unknown Amazon key is refused');
SELECT pg_temp.ok((public.api_vault_amz_remove('AMZ_REFRESH_TOKEN')->>'removed')::boolean, 'VT11 Amazon key removal accepted');
SELECT pg_temp.ok(NOT (public.api_vault_overview()->'amz'->'AMZ_REFRESH_TOKEN'->>'set')::boolean, 'VT11a the key is gone from the vault');
SELECT pg_temp.ok((SELECT a->>'action' = 'secret_deleted' AND a->>'what' = 'AMZ_REFRESH_TOKEN' FROM jsonb_array_elements(public.api_vault_overview()->'activity') a LIMIT 1),
  'VT11b removal is logged first, by name only');
RESET ROLE;
SELECT pg_temp.ok(NOT has_function_privilege('anon', 'public.api_vault_overview()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'crm_private.vault_meta(text,boolean)', 'EXECUTE'), 'VT12 not callable without signing in; helpers are private');
SELECT 'ALL VAULT SQL CHECKS PASSED';
