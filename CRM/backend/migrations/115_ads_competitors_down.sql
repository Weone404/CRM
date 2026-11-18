-- 115 rollback: Competitor watch out; the agents' context goes back to 114.
DROP TRIGGER IF EXISTS trg_ads_competitor_findings ON public.ads_agent_runs;
DROP FUNCTION IF EXISTS crm_private.ads_competitor_findings_keep();
DROP FUNCTION IF EXISTS public.api_ads_competitors();
DROP FUNCTION IF EXISTS public.api_ads_competitor_save(jsonb);
DROP FUNCTION IF EXISTS public.api_ads_competitor_ad_save(jsonb);
DROP FUNCTION IF EXISTS public.api_ads_competitor_ad_seen(bigint);
DROP FUNCTION IF EXISTS public.api_ads_competitor_delete(text, bigint);
DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_meta_strategy_extra_v114()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_strategy_extra();
    ALTER FUNCTION public.svc_ads_meta_strategy_extra_v114() RENAME TO svc_ads_meta_strategy_extra;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_competitors_data(int);
DROP TABLE IF EXISTS public.ads_competitor_finding, public.ads_competitor_ad, public.ads_competitor;
UPDATE public.ads_config SET value = '114', updated_at = now() WHERE key = 'ads_schema';
