-- 113: Website charts. One read-only call with the day-by-day trend for both 28-day windows (Search Console and GA4)
-- and how searches spread over Google positions, so the Website screen can draw this period against the one before.
CREATE OR REPLACE FUNCTION public.api_web_trend() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  RETURN jsonb_build_object(
    'gsc', (SELECT jsonb_object_agg(w, rows) FROM (
      SELECT w, coalesce((SELECT jsonb_agg(jsonb_build_object('d', r.k1, 'clicks', (r.m->>'clicks')::numeric, 'impressions', (r.m->>'impressions')::numeric,
                 'ctr', (r.m->>'ctr')::numeric, 'position', (r.m->>'position')::numeric) ORDER BY r.k1)
               FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'date' AND r.win = w), '[]') AS rows
        FROM unnest(ARRAY['cur', 'prev']) w) t),
    'ga', (SELECT jsonb_object_agg(w, rows) FROM (
      SELECT w, coalesce((SELECT jsonb_agg(jsonb_build_object('d', r.k1, 'users', (r.m->>'activeUsers')::numeric, 'sessions', (r.m->>'sessions')::numeric) ORDER BY r.k1)
               FROM public.web_row r WHERE r.src = 'ga' AND r.kind = 'date' AND r.win = w), '[]') AS rows
        FROM unnest(ARRAY['cur', 'prev']) w) t),
    'ranks', (SELECT jsonb_object_agg(w, b) FROM (
      SELECT w, jsonb_build_object(
               'top3', count(*) FILTER (WHERE p <= 3), 'p1', count(*) FILTER (WHERE p > 3 AND p <= 10), 'p2', count(*) FILTER (WHERE p > 10 AND p <= 20),
               'p3_5', count(*) FILTER (WHERE p > 20 AND p <= 50), 'beyond', count(*) FILTER (WHERE p > 50)) AS b
        FROM (SELECT r.win AS w, (r.m->>'position')::numeric AS p FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'query') q
       GROUP BY w) t));
END $$;
REVOKE ALL ON FUNCTION public.api_web_trend() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_web_trend() TO authenticated;
