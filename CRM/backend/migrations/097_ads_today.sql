-- 097: ADS only, Google only. Data for the "Today" page: the searches that brought results and the ones that wasted money,
-- read from the latest account snapshot (last 30 days; the past year when the last 30 days have no searches).
-- Re-runnable. Rollback: DROP FUNCTION public.api_ads_search_insights(int);
CREATE OR REPLACE FUNCTION public.api_ads_search_insights(p_limit int DEFAULT 8) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; src text := 'search_terms_30d'; rows jsonb; lim int := greatest(1, least(coalesce(p_limit, 8), 25));
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  IF a.id IS NULL THEN RETURN jsonb_build_object('source', NULL, 'best', '[]'::jsonb, 'wasted', '[]'::jsonb); END IF;
  SELECT data INTO rows FROM public.ads_google_snapshot WHERE account_id = a.id AND kind = src;
  IF rows IS NULL OR jsonb_typeof(rows) <> 'array' OR jsonb_array_length(rows) = 0 THEN
    src := 'search_terms_365d';
    SELECT data INTO rows FROM public.ads_google_snapshot WHERE account_id = a.id AND kind = src;
  END IF;
  IF rows IS NULL OR jsonb_typeof(rows) <> 'array' THEN rows := '[]'; END IF;
  RETURN (WITH t AS (
      SELECT lower(r->>'searchTermView.searchTerm') term,
             coalesce((r->>'metrics.costMicros')::numeric, 0) / 1e6 cost,
             coalesce((r->>'metrics.conversions')::numeric, 0) conv,
             coalesce((r->>'metrics.clicks')::numeric, 0) clicks
        FROM jsonb_array_elements(rows) r WHERE r ? 'searchTermView.searchTerm'),
    g AS (SELECT term, sum(cost) cost, sum(conv) conv, sum(clicks) clicks FROM t GROUP BY term)
    SELECT jsonb_build_object(
      'source', CASE src WHEN 'search_terms_30d' THEN 'last 30 days' ELSE 'past year' END,
      'synced_at', (SELECT synced_at FROM public.ads_google_snapshot WHERE account_id = a.id AND kind = src),
      'best', (SELECT coalesce(jsonb_agg(jsonb_build_object('term', term, 'cost', round(cost, 2), 'conversions', round(conv, 1),
                 'cost_per_conversion', round(cost / conv, 2)) ORDER BY cost / conv, conv DESC), '[]')
                 FROM (SELECT * FROM g WHERE conv > 0 ORDER BY cost / conv, conv DESC LIMIT lim) b),
      'wasted', (SELECT coalesce(jsonb_agg(jsonb_build_object('term', term, 'cost', round(cost, 2), 'clicks', clicks) ORDER BY cost DESC), '[]')
                 FROM (SELECT * FROM g WHERE conv = 0 AND cost > 0 ORDER BY cost DESC LIMIT lim) w)));
END $$;
REVOKE ALL ON FUNCTION public.api_ads_search_insights(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_search_insights(int) TO authenticated;
