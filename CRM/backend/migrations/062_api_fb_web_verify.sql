-- 062: FlightBridge AI finds and re-checks schools on the web for free (engine 1.4.0).
--  * Official lists: an admin uploads the FAA Part 141 pilot-school list (downloaded from the FAA facility dashboard);
--    the engine imports it on its next cycle (table flightbridge.register_upload, migration 061).
--  * Tavily web search key (1,000 free searches a month) can be saved like the other keys.
--  * School Detector shows the Tavily allowance next to Google's.

CREATE OR REPLACE FUNCTION crm_private.fb_integration_label(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE p_name WHEN 'google_places_api_key' THEN 'Google Places API key' WHEN 'groq_api_key' THEN 'Groq API key'
    WHEN 'gemini_api_key' THEN 'Gemini API key' WHEN 'hostinger_mail_api_token' THEN 'Hostinger Mail API token'
    WHEN 'hostinger_mailbox_resource_id' THEN 'Hostinger mailbox ID' WHEN 'tavily_api_key' THEN 'Tavily API key' END
$$;

CREATE OR REPLACE FUNCTION public.api_fb_integrations()
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
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
                     (5, 'hostinger_mail_api_token'), (6, 'hostinger_mailbox_resource_id')) n(o, name)
   LEFT JOIN flightbridge.integration_secret s ON s.name = n.name),
    'settings', json_build_object(
        'engine_in_crm', coalesce(cfg->'engine_in_crm', 'true'), 'llm_provider', coalesce(cfg->'llm_provider', '"none"'),
        'llm_model', coalesce(cfg->'llm_model', '""'), 'inbound_source', coalesce(cfg->'inbound_source', '"none"'),
        'store_google_contacts', coalesce(cfg->'store_google_contacts', 'true')),
    'engine_env_off', coalesce((env->>'engine_off')::boolean, false),
    'dry_run', coalesce((env->>'dry_run')::boolean, true),
    'outbound_enabled', coalesce((env->>'outbound_enabled')::boolean, false),
    'engine_status', env);
END $$;

-- Upload an official list (admin only). p_data: {kind: 'faa_part141', filename, content_b64}
CREATE OR REPLACE FUNCTION public.api_fb_register_upload(p_data jsonb)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  v_kind text := p_data->>'kind'; v_name text := btrim(coalesce(p_data->>'filename', ''));
  v_b64 text := regexp_replace(coalesce(p_data->>'content_b64', ''), '\s', '', 'g'); v_bytes bytea; v_id bigint; v_sha text;
BEGIN
  IF v_kind IS DISTINCT FROM 'faa_part141' THEN RAISE EXCEPTION 'Unknown list type' USING ERRCODE = 'PT422'; END IF;
  IF v_name = '' OR length(v_name) > 200 OR v_name !~* '\.(csv|xlsx|txt|tsv)$' THEN
    RAISE EXCEPTION 'Choose the CSV or Excel (.xlsx) file you downloaded from the FAA dashboard' USING ERRCODE = 'PT422';
  END IF;
  IF v_b64 = '' THEN RAISE EXCEPTION 'The file is empty' USING ERRCODE = 'PT422'; END IF;
  IF length(v_b64) > 14000000 THEN RAISE EXCEPTION 'The file is too large (10 MB at most)' USING ERRCODE = 'PT422'; END IF;
  BEGIN
    v_bytes := decode(v_b64, 'base64');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'The file could not be read' USING ERRCODE = 'PT422';
  END;
  v_sha := encode(extensions.digest(v_bytes, 'sha256'), 'hex');
  IF EXISTS (SELECT 1 FROM flightbridge.register_upload WHERE sha256 = v_sha AND status IN ('pending', 'imported')
             AND uploaded_at > now() - interval '1 day') THEN
    RAISE EXCEPTION 'This same file was already uploaded today' USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO flightbridge.register_upload (kind, filename, content_b64, sha256, uploaded_by)
  VALUES (v_kind, v_name, v_b64, v_sha, eid) RETURNING id INTO v_id;
  PERFORM crm_private.fb_audit(eid, 'register_uploaded', 'register', 'upload/' || v_id,
                               jsonb_build_object('kind', v_kind, 'filename', v_name, 'bytes', length(v_bytes), 'sha256', v_sha));
  RETURN json_build_object('id', v_id, 'status', 'pending');
END $$;

-- The last uploads and what the engine made of them (file content is never returned)
CREATE OR REPLACE FUNCTION public.api_fb_register_uploads()
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x ORDER BY x.uploaded_at DESC) FROM (
    SELECT u.id, u.kind, u.filename, u.uploaded_at, e.name AS uploaded_by, u.status, u.result, u.processed_at
      FROM flightbridge.register_upload u LEFT JOIN public.employee e ON e.id = u.uploaded_by
     ORDER BY u.uploaded_at DESC LIMIT 10) x), '[]');
END $$;

REVOKE ALL ON FUNCTION public.api_fb_register_upload(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_fb_register_uploads() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_fb_integrations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_register_upload(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_register_uploads() TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_integrations() TO authenticated;

-- School Detector: add the Tavily allowance to the free-limit meters
CREATE OR REPLACE FUNCTION public.api_fb_detector() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg jsonb; caps jsonb := '{"text_search_pro": 4500, "text_search_enterprise": 900,
                                   "place_details_pro": 4500, "place_details_enterprise": 900, "tavily_search": 900}';
  k text; m date := date_trunc('month', now() AT TIME ZONE 'UTC')::date;
BEGIN
  PERFORM crm_private.fb_member();
  -- same rule as flightbridge.research.quota.caps(): an override may lower a cap, never raise it past Google's free tier
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'google_budget';
  IF jsonb_typeof(cfg) = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(caps) LOOP
      IF jsonb_typeof(cfg->k) = 'number' AND (cfg->>k)::numeric = trunc((cfg->>k)::numeric)
         AND (cfg->>k)::numeric BETWEEN 0 AND (caps->>k)::numeric / 0.9 THEN
        caps := caps || jsonb_build_object(k, (cfg->>k)::int);
      END IF;
    END LOOP;
  END IF;
  RETURN (
    WITH found AS (                     -- distinct schools per country in the country's current pass
      SELECT c.country, count(DISTINCT d.org_id) AS schools,
             count(DISTINCT d.org_id) FILTER (WHERE d.is_new) AS new_schools
        FROM flightbridge.detection d
        JOIN flightbridge.sweep_cell c ON c.id = d.cell_id
        JOIN flightbridge.sweep_country k ON k.country = c.country AND k.pass = c.pass
       GROUP BY c.country)
    SELECT json_build_object(
    'quota', json_build_object('month', m, 'skus', (
       SELECT json_object_agg(c.key, json_build_object('cap', c.value::int,
                'used', coalesce((SELECT calls FROM flightbridge.google_usage u WHERE u.month = m AND u.sku = c.key), 0)))
         FROM jsonb_each_text(caps) c)),
    'totals', (SELECT json_build_object(
        'countries', count(*), 'countries_done', count(*) FILTER (WHERE finished_at IS NOT NULL),
        'squares_total', coalesce(sum(cells_total), 0), 'squares_done', coalesce(sum(cells_done), 0),
        'schools_found', (SELECT coalesce(sum(schools), 0) FROM found),
        'schools_new', (SELECT coalesce(sum(new_schools), 0) FROM found),
        'all_schools', (SELECT count(*) FROM flightbridge.organisation WHERE deleted_at IS NULL),
        'detections_24h', (SELECT count(DISTINCT org_id) FROM flightbridge.detection WHERE at > now() - interval '24 hours'),
        'new_24h', (SELECT count(DISTINCT org_id) FROM flightbridge.detection WHERE is_new AND at > now() - interval '24 hours'))
        FROM flightbridge.sweep_country),
    'countries', coalesce((SELECT json_agg(json_build_object('country', k.country, 'priority', k.priority, 'pass', k.pass,
        'squares_total', k.cells_total, 'squares_done', k.cells_done,
        'schools_found', coalesce(f.schools, 0), 'schools_new', coalesce(f.new_schools, 0),
        'started_at', k.started_at, 'finished_at', k.finished_at, 'enabled', k.enabled,
        'state', CASE WHEN k.finished_at IS NOT NULL THEN 'done' WHEN k.started_at IS NOT NULL THEN 'scanning' ELSE 'queued' END)
        ORDER BY k.priority) FROM flightbridge.sweep_country k LEFT JOIN found f ON f.country = k.country), '[]'),
    'scanning', (SELECT json_build_object('id', id, 'country', country, 'lat0', lat0, 'lng0', lng0, 'lat1', lat1, 'lng1', lng1,
                   'depth', depth, 'at', searched_at, 'status', status)
                   FROM flightbridge.sweep_cell WHERE searched_at IS NOT NULL ORDER BY searched_at DESC LIMIT 1),
    'cells', coalesce((SELECT json_agg(x ORDER BY x.at) FROM (
        SELECT id, country, lat0, lng0, lat1, lng1, depth, status, results, schools, new_schools, calls, searched_at AS at
          FROM flightbridge.sweep_cell WHERE searched_at IS NOT NULL ORDER BY searched_at DESC LIMIT 16) x), '[]'),
    'recent', coalesce((SELECT json_agg(x ORDER BY x.at DESC) FROM (
        SELECT * FROM (
          SELECT DISTINCT ON (d.org_id) d.org_id, d.cell_id, d.name, d.country,
                 round(d.lat::numeric, 3) AS lat, round(d.lng::numeric, 3) AS lng, d.is_new, d.at, o.eligibility
            FROM (SELECT * FROM flightbridge.detection ORDER BY at DESC LIMIT 400) d
            JOIN flightbridge.organisation o ON o.id = d.org_id
           ORDER BY d.org_id, d.is_new DESC, d.at DESC) u
         ORDER BY u.at DESC LIMIT 60) x), '[]'),
    -- one dot per school for the globe: [lat, lng, e] with e = 2 eligible, 1 check needed, 0 other
    'points', coalesce((SELECT json_agg(json_build_array(round(p.lat::numeric, 2), round(p.lng::numeric, 2), p.e)) FROM (
        SELECT DISTINCT ON (d.org_id) d.lat, d.lng,
               CASE o.eligibility WHEN 'eligible_verified' THEN 2 WHEN 'eligible_claimed' THEN 1 ELSE 0 END AS e
          FROM flightbridge.detection d JOIN flightbridge.organisation o ON o.id = d.org_id AND o.deleted_at IS NULL
         ORDER BY d.org_id, d.at DESC LIMIT 20000) p), '[]'),
    'engine', (SELECT json_build_object('at', updated_at, 'runner', value->>'runner', 'engine_off', value->'engine_off')
                 FROM flightbridge.system_setting WHERE key = 'engine_status'),
    'autopilot', (SELECT value FROM flightbridge.system_setting WHERE key = 'autopilot')));
END $$;

REVOKE ALL ON FUNCTION public.api_fb_detector() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_detector() TO authenticated;
