-- 127 down
DO $$ BEGIN
  IF to_regprocedure('public.api_content_from_strategy_v126(bigint)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_content_from_strategy(bigint);
    ALTER FUNCTION public.api_content_from_strategy_v126(bigint) RENAME TO api_content_from_strategy;
    GRANT EXECUTE ON FUNCTION public.api_content_from_strategy(bigint) TO authenticated;
  END IF;
END $$;
UPDATE public.ads_config SET value = '126', updated_at = now() WHERE key = 'ads_schema';
