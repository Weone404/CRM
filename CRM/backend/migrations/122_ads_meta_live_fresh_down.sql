-- 122 down: back to 121's api_ads_meta_live.
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_live_v121()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_meta_live();
    ALTER FUNCTION public.api_ads_meta_live_v121() RENAME TO api_ads_meta_live;
    GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
  END IF;
END $$;
UPDATE public.ads_config SET value = '121', updated_at = now() WHERE key = 'ads_schema';
