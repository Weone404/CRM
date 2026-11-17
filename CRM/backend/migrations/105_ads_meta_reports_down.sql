-- Rollback of 105_ads_meta_reports.sql. Puts 104 back (report cache, saved views, health and warnings are dropped).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-health';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.api_ads_meta_report_options(), public.api_ads_meta_report_crm(date, date, text),
  public.api_ads_meta_report_view_save(bigint, text, jsonb, boolean), public.api_ads_meta_report_view_delete(bigint),
  public.api_ads_meta_health(), public.api_ads_meta_warning_dismiss(bigint), public.svc_ads_agents_meta_waiting(), public.svc_ads_meta_report_account(),
  public.svc_ads_meta_report_cache_get(text), public.svc_ads_meta_report_cache_put(text, jsonb, jsonb, int),
  public.svc_ads_meta_health_save(jsonb, jsonb), public.svc_ads_meta_warnings_notified(bigint[]);
DROP TABLE IF EXISTS public.ads_meta_warning, public.ads_meta_health, public.ads_meta_report_view, public.ads_meta_report_cache;
UPDATE public.ads_config SET value = '104', updated_at = now() WHERE key = 'ads_schema';
