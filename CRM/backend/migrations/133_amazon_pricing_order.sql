-- 133: Buy Box refresh checks OUR products first.
-- The half-hourly price check reads the first 60 ASINs of this list. It was alphabetical across our 26 products and
-- 80+ competitors, so about half of our own products were only refreshed once a day. Ours now come first.
CREATE OR REPLACE FUNCTION public.svc_amz_competitor_asins() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(a ORDER BY mine DESC, a), '{}') FROM (
    SELECT a, bool_or(mine) mine FROM (
      SELECT asin a, true mine FROM public.amazon_listings WHERE asin IS NOT NULL AND NOT is_parent
      UNION ALL SELECT asin, false FROM public.amazon_competitors WHERE active AND asin IS NOT NULL) x
    GROUP BY a) y
$$;
REVOKE ALL ON FUNCTION public.svc_amz_competitor_asins() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_amz_competitor_asins() TO service_role;
