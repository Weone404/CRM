-- 069: FlightBridge mailboxes (engine 1.7.0). The HIOX India mailbox (partnership@weoneaviation.in, SMTP/IMAP) next to
-- the Hostinger mailbox, and the choice of which one sends and is read for replies:
--   integrations.send_from      hostinger | hiox
--   integrations.inbound_source none | hostinger | hiox
--   integrations.hiox_mail_user / hiox_mail_host   (defaults partnership@weoneaviation.in / host2.dnsinweb.com, the MX)
-- Settings are now merged into what is stored, so a value this screen doesn't show is never lost.

CREATE OR REPLACE FUNCTION crm_private.fb_integration_label(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE p_name WHEN 'google_places_api_key' THEN 'Google Places API key' WHEN 'groq_api_key' THEN 'Groq API key'
    WHEN 'gemini_api_key' THEN 'Gemini API key' WHEN 'hostinger_mail_api_token' THEN 'Hostinger Mail API token'
    WHEN 'hostinger_mailbox_resource_id' THEN 'Hostinger mailbox ID' WHEN 'tavily_api_key' THEN 'Tavily API key'
    WHEN 'hiox_mail_password' THEN 'Mailbox password' END
$$;

CREATE OR REPLACE FUNCTION public.api_fb_integrations() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE env jsonb; cfg jsonb;
BEGIN
  PERFORM crm_private.fb_admin();
  SELECT value INTO env FROM flightbridge.system_setting WHERE key = 'engine_status';
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'integrations';
  IF jsonb_typeof(cfg) IS DISTINCT FROM 'object' THEN cfg := '{}'; END IF;
  RETURN json_build_object(
    'keys', (SELECT json_agg(json_build_object('name', n.name, 'label', crm_private.fb_integration_label(n.name),
        'saved', s.name IS NOT NULL, 'last4', s.last4, 'updated_at', s.updated_at,
        'from_server_env', coalesce(env->'env_keys' ? upper(n.name), false),
        'last_test_at', s.last_test_at, 'last_test_ok', s.last_test_ok, 'last_test_message', s.last_test_message) ORDER BY n.o)
        FROM (VALUES (1, 'google_places_api_key'), (2, 'tavily_api_key'), (3, 'groq_api_key'), (4, 'gemini_api_key'),
                     (5, 'hostinger_mail_api_token'), (6, 'hostinger_mailbox_resource_id'), (7, 'hiox_mail_password')) n(o, name)
   LEFT JOIN flightbridge.integration_secret s ON s.name = n.name),
    'settings', json_build_object(
        'engine_in_crm', coalesce(cfg->'engine_in_crm', 'true'), 'llm_provider', coalesce(cfg->'llm_provider', '"none"'),
        'llm_model', coalesce(cfg->'llm_model', '""'), 'inbound_source', coalesce(cfg->'inbound_source', '"none"'),
        'store_google_contacts', coalesce(cfg->'store_google_contacts', 'true'),
        'send_from', coalesce(cfg->'send_from', '"hostinger"'),
        'hiox_mail_user', coalesce(cfg->'hiox_mail_user', '"partnership@weoneaviation.in"'),
        'hiox_mail_host', coalesce(cfg->'hiox_mail_host', '"host2.dnsinweb.com"')),
    'engine_env_off', coalesce((env->>'engine_off')::boolean, false),
    'dry_run', coalesce((env->>'dry_run')::boolean, true),
    'outbound_enabled', coalesce((env->>'outbound_enabled')::boolean, false),
    'engine_status', env);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_integration_settings(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); cur jsonb; v jsonb;
  prov text := coalesce(crm_private.fb_text(p_data, 'llm_provider', NULL), 'none');
  inb text := coalesce(crm_private.fb_text(p_data, 'inbound_source', NULL), 'none');
  sf text := coalesce(crm_private.fb_text(p_data, 'send_from', NULL), 'hostinger');
  hu text := lower(btrim(coalesce(nullif(crm_private.fb_text(p_data, 'hiox_mail_user', 160), ''), 'partnership@weoneaviation.in')));
  hh text := lower(btrim(coalesce(nullif(crm_private.fb_text(p_data, 'hiox_mail_host', 160), ''), 'host2.dnsinweb.com')));
BEGIN
  IF prov NOT IN ('none', 'groq', 'gemini') THEN
    RAISE EXCEPTION 'llm_provider must be none, groq or gemini' USING ERRCODE = 'PT400';
  END IF;
  IF inb NOT IN ('none', 'hostinger', 'hiox') THEN RAISE EXCEPTION 'inbound_source must be none, hostinger or hiox' USING ERRCODE = 'PT400'; END IF;
  IF sf NOT IN ('hostinger', 'hiox') THEN RAISE EXCEPTION 'send_from must be hostinger or hiox' USING ERRCODE = 'PT400'; END IF;
  IF hu !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$' THEN RAISE EXCEPTION 'Enter the full email address' USING ERRCODE = 'PT400'; END IF;
  IF hh !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' THEN
    RAISE EXCEPTION 'Enter the mail server name, e.g. host2.dnsinweb.com' USING ERRCODE = 'PT400';
  END IF;
  IF (sf = 'hiox' OR inb = 'hiox') AND NOT EXISTS (SELECT 1 FROM flightbridge.integration_secret
                                                    WHERE name = 'hiox_mail_password' AND last_test_ok) THEN
    RAISE EXCEPTION 'Connect the HIOX India mailbox first (save its password and pass the test)' USING ERRCODE = 'PT400';
  END IF;
  SELECT value INTO cur FROM flightbridge.system_setting WHERE key = 'integrations';
  IF jsonb_typeof(cur) IS DISTINCT FROM 'object' THEN cur := '{}'; END IF;
  v := cur || jsonb_build_object('engine_in_crm', crm_private.fb_bool(p_data, 'engine_in_crm', true), 'llm_provider', prov,
         'llm_model', coalesce(crm_private.fb_text(p_data, 'llm_model', 100), ''), 'inbound_source', inb,
         'send_from', sf, 'hiox_mail_user', hu, 'hiox_mail_host', hh);
  PERFORM crm_private.fb_set_setting('integrations', v, eid);
  PERFORM crm_private.fb_audit(eid, 'integration_settings_set', 'system_setting', 'integrations', v);
  RETURN v::json;
END $$;

-- The Edge Function's mailbox test reads the address and server with the service role only.
CREATE OR REPLACE FUNCTION public.svc_fb_mail_settings() RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT json_build_object(
    'hiox_mail_user', coalesce((SELECT value->>'hiox_mail_user' FROM flightbridge.system_setting WHERE key = 'integrations'), 'partnership@weoneaviation.in'),
    'hiox_mail_host', coalesce((SELECT value->>'hiox_mail_host' FROM flightbridge.system_setting WHERE key = 'integrations'), 'host2.dnsinweb.com'))
$$;
REVOKE ALL ON FUNCTION public.svc_fb_mail_settings() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_fb_mail_settings() TO service_role;
