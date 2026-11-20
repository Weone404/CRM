-- 121 down: remove the money and live-campaigns view and the 15-minute refresh.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-live';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.api_ads_meta_live();
DROP FUNCTION IF EXISTS crm_private.ads_meta_live_tick();
DROP FUNCTION IF EXISTS crm_private.ads_meta_is_live();
UPDATE public.ads_config SET value = '120', updated_at = now() WHERE key = 'ads_schema';
