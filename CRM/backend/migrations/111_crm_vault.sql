-- 111: Connections & keys (Setup > Connections & keys). One admin-only overview of every key, token and account ID
-- the CRM holds, grouped by provider, with status, last test and who changed what.
-- Nothing moves: each key stays where its readers already look (Supabase Vault names ads_*, amz_*, crm_*,
-- crm_ai_*, flightbridge.integration_secret). Saving, replacing and removing still go through the existing
-- functions (api_ads_settings_save, api_amz_settings_save, ai_integration_set, api_connection_rotate, ...), so their
-- checks and logs stay exactly as they are. Secrets are never returned: only "saved", the last 4 characters and the
-- date. Account IDs that are not secret (OAuth client IDs, customer/profile/seller IDs) are returned in full so they
-- can be copied. Re-runnable.

-- Status of one Vault entry. p_reveal = true only for non-secret IDs.
CREATE OR REPLACE FUNCTION crm_private.vault_meta(p_name text, p_reveal boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT jsonb_build_object('set', true, 'last4', right(d.decrypted_secret, 4), 'updated_at', d.updated_at)
                          || CASE WHEN p_reveal THEN jsonb_build_object('value', d.decrypted_secret) ELSE '{}'::jsonb END
                     FROM vault.decrypted_secrets d WHERE d.name = p_name LIMIT 1), jsonb_build_object('set', false))
$$;

-- Account IDs that are safe to show in full (never passwords, secrets or tokens).
CREATE OR REPLACE FUNCTION crm_private.vault_public_ids() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_CLIENT_ID', 'GOOGLE_ADS_LOGIN_CUSTOMER_ID', 'META_APP_ID',
               'AMZ_LWA_CLIENT_ID', 'AMZ_SELLER_ID', 'ADS_CLIENT_ID', 'ADS_PROFILE_ID']
$$;

CREATE OR REPLACE FUNCTION public.api_vault_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '{}'; part jsonb; act jsonb := '[]';
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can open Connections & keys' USING ERRCODE = 'PT403';
  END IF;

  -- Google Ads, Meta and the website sign-in (ADS module)
  IF to_regprocedure('crm_private.ads_secret_names()') IS NOT NULL THEN
    EXECUTE $q$
      SELECT jsonb_object_agg(n, crm_private.vault_meta('ads_' || lower(n), n = ANY (crm_private.vault_public_ids())))
        FROM unnest(crm_private.ads_secret_names()) n $q$ INTO part;
    out := out || jsonb_build_object('ads', coalesce(part, '{}'));
    EXECUTE $q$
      SELECT jsonb_build_object(
        'tests', (SELECT jsonb_object_agg(s.job, jsonb_build_object('status', s.status, 'detail', s.detail, 'at', s.finished_at))
                    FROM (SELECT DISTINCT ON (r.job) r.job, r.status, r.detail, r.finished_at FROM public.ads_sync_runs r
                           WHERE r.job IN ('test_google', 'test_meta', 'site_signals') ORDER BY r.job, r.started_at DESC) s),
        'site', jsonb_build_object(
          'gsc_url', (SELECT nullif(c.value, '') FROM public.ads_config c WHERE c.key = 'site_gsc_url'),
          'ga4_property', (SELECT nullif(c.value, '') FROM public.ads_config c WHERE c.key = 'site_ga4_property'),
          'last', (SELECT nullif(c.value, '')::jsonb FROM public.ads_config c WHERE c.key = 'site_signals_last'),
          'pixel', (SELECT nullif(c.value, '')::jsonb FROM public.ads_config c WHERE c.key = 'meta_pixel'))) $q$ INTO part;
    out := out || jsonb_build_object('ads_status', part);
  END IF;

  -- Amazon (Selling Partner API, Amazon Ads, Pexels)
  IF to_regprocedure('crm_private.amz_secret_names()') IS NOT NULL THEN
    EXECUTE $q$
      SELECT jsonb_object_agg(n, crm_private.vault_meta('amz_' || lower(n), n = ANY (crm_private.vault_public_ids())))
        FROM unnest(crm_private.amz_secret_names()) n $q$ INTO part;
    out := out || jsonb_build_object('amz', coalesce(part, '{}'));
    EXECUTE $q$
      SELECT jsonb_build_object(
        'last_test', (SELECT jsonb_build_object('status', max(c.value) FILTER (WHERE c.key = 'last_test_status'),
                        'detail', max(c.value) FILTER (WHERE c.key = 'last_test_detail'),
                        'at', max(c.value) FILTER (WHERE c.key = 'last_test_at'))
                      FROM public.amazon_config c WHERE c.key LIKE 'last_test_%'),
        'rotated_on', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'secret_rotated_on'),
        'smtp', (SELECT nullif(c.value, '')::jsonb - 'password' FROM public.amazon_config c WHERE c.key = 'smtp'),
        'smtp_password', crm_private.vault_meta('crm_smtp_password')) $q$ INTO part;
    out := out || jsonb_build_object('amz_status', part);
  END IF;

  -- AI model keys used by the CRM
  IF to_regclass('crm_private.ai_integration') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(jsonb_build_object('provider', a.provider, 'last4', a.last4, 'enabled', a.enabled,
               'updated_at', a.updated_at) ORDER BY a.provider), '[]')
        FROM crm_private.ai_integration a $q$ INTO part;
    out := out || jsonb_build_object('ai', part);
  END IF;

  -- Keys FlightBridge AI uses (saved there through its own encrypted store)
  IF to_regclass('flightbridge.integration_secret') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'last4', s.last4, 'updated_at', s.updated_at,
               'last_test_at', s.last_test_at, 'last_test_ok', s.last_test_ok, 'last_test_message', s.last_test_message) ORDER BY s.name), '[]')
        FROM flightbridge.integration_secret s $q$ INTO part;
    out := out || jsonb_build_object('fb', part);
  END IF;

  -- Tokens other systems use to send data in (website forms, BookMyCharter, attendance machine, partner apps)
  out := out || jsonb_build_object('inbound', jsonb_build_object(
    'charter', crm_private.vault_meta('crm_charter_ingest_token'),
    'hikvision', crm_private.vault_meta('crm_attendance_ingest_token'),
    'partner', crm_private.vault_meta('crm_partner_api_token')));

  -- Who changed what (names of keys only, never values)
  IF to_regclass('public.ads_activity_log') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(x), '[]') FROM (
        SELECT l.at, e.name AS who, l.action, coalesce(l.entity_id, l.entity) AS what, 'ads' AS area
          FROM public.ads_activity_log l LEFT JOIN public.employee e ON e.id = l.actor
         WHERE l.action IN ('secret_saved', 'secret_deleted', 'site_settings_saved', 'agents_token_rotated')
         ORDER BY l.at DESC LIMIT 40) x $q$ INTO part;
    act := act || part;
  END IF;
  IF to_regclass('public.amazon_activity_log') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(x), '[]') FROM (
        SELECT l.at, e.name AS who, l.action, coalesce(l.entity_id, l.entity) AS what, 'amazon' AS area
          FROM public.amazon_activity_log l LEFT JOIN public.employee e ON e.id = l.actor
         WHERE l.action IN ('settings_saved', 'secret_deleted', 'smtp_saved', 'bridge_token_created')
         ORDER BY l.at DESC LIMIT 40) x $q$ INTO part;
    act := act || part;
  END IF;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(x), '[]') FROM (
        SELECT l.ts AS at, e.name AS who, l.action, coalesce(l.payload->>'id', l.payload->>'provider', l.entity) AS what, 'crm' AS area
          FROM public.audit_log l LEFT JOIN public.employee e ON e.id = l.actor
         WHERE l.action IN ('connection_token_viewed', 'connection_token_rotated')
            OR l.action LIKE 'ai_integration%'
         ORDER BY l.ts DESC LIMIT 40) x $q$ INTO part;
    act := act || part;
  END IF;
  SELECT coalesce(jsonb_agg(a ORDER BY (a->>'at')::timestamptz DESC), '[]') INTO act
    FROM (SELECT a FROM jsonb_array_elements(act) a ORDER BY (a->>'at')::timestamptz DESC LIMIT 40) z;
  RETURN out || jsonb_build_object('activity', act, 'checked_at', now());
END $$;

-- Amazon keys had no "remove" before; Google/Meta (api_ads_secret_delete) and AI keys (ai_integration_delete) do.
CREATE OR REPLACE FUNCTION public.api_vault_amz_remove(p_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can remove keys' USING ERRCODE = 'PT403'; END IF;
  IF to_regprocedure('crm_private.amz_secret_names()') IS NULL THEN RAISE EXCEPTION 'Amazon is not set up' USING ERRCODE = 'PT404'; END IF;
  IF NOT (p_name = ANY (crm_private.amz_secret_names())) THEN RAISE EXCEPTION 'Unknown Amazon key' USING ERRCODE = 'PT404'; END IF;
  DELETE FROM vault.secrets WHERE name = 'amz_' || lower(p_name);
  INSERT INTO public.amazon_activity_log (actor, actor_type, action, entity, entity_id, details)
  VALUES (crm_private.current_employee_id(), 'user', 'secret_deleted', 'setting', p_name, '{}');   -- name only
  RETURN jsonb_build_object('removed', true);
END $$;

REVOKE ALL ON FUNCTION crm_private.vault_meta(text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_private.vault_public_ids() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_vault_overview() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_vault_amz_remove(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_vault_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_vault_amz_remove(text) TO authenticated;
