-- 059: School Detector API, second version.
--  * "schools found" counts each school once. A busy square is split into 4 and searched again, so the engine's
--    running total in sweep_country counts some schools twice; here we count distinct schools from flightbridge.detection.
--  * 'cells': the last 16 squares searched (for the globe's camera tour).
--  * 'recent': one row per school (latest sighting), with the square it was seen in.

CREATE OR REPLACE FUNCTION public.api_fb_detector() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg jsonb; caps jsonb := '{"text_search_pro": 4500, "text_search_enterprise": 900,
                                   "place_details_pro": 4500, "place_details_enterprise": 900}';
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
