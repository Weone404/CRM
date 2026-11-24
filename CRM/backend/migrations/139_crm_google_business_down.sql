-- Rollback of 139: removes the Google My Business tables, functions, schedule and the refresh tokens it stored.
-- The shared Google OAuth client (ads_google_ads_client_id / _secret) and every other module are left alone.
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-gbp-sync'; END IF; END $$;
DELETE FROM vault.secrets WHERE name LIKE 'crm\_gbp\_refresh\_%';
DROP FUNCTION IF EXISTS public.api_gbp_access(), public.api_gbp_overview(uuid, int), public.api_gbp_reviews(uuid, text, int),
  public.api_gbp_connection_add(text, text), public.api_gbp_connection_token(uuid, text), public.api_gbp_connection_remove(uuid),
  public.api_gbp_location_track(uuid, boolean), public.api_google_hub(),
  public.svc_gbp_work(uuid), public.svc_gbp_connection_status(uuid, text, text, text), public.svc_gbp_locations_save(uuid, jsonb),
  public.svc_gbp_metrics_save(uuid, jsonb), public.svc_gbp_keywords_save(uuid, date, jsonb), public.svc_gbp_reviews_save(uuid, jsonb, int, numeric),
  public.svc_gbp_run_begin(text), public.svc_gbp_run_end(bigint, text, text),
  crm_private.gbp_can_view(), crm_private.gbp_can_run(), crm_private.gbp_secret_name(uuid),
  crm_private.gbp_totals(uuid[], date, date), crm_private.gbp_days(uuid[], date, date);
DROP TABLE IF EXISTS public.gbp_run, public.gbp_review, public.gbp_keyword_monthly, public.gbp_metric_daily, public.gbp_location, public.gbp_connection;
