-- Down for 135: stops comment-to-DM on the CRM. The log, people and settings are dropped; the token stays in Vault
-- (delete ads_instagram_login_token there if it should go too).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ig-dm'; END IF;
END $$;
DROP FUNCTION IF EXISTS public.svc_ig_dm_work(), public.svc_ig_dm_cfg(jsonb), public.svc_ig_dm_token_save(text),
  public.api_ig_dm_status(), public.api_ig_dm_settings_save(jsonb);
DROP TABLE IF EXISTS public.ig_dm_log, public.ig_dm_person, public.ig_dm_send;
DELETE FROM public.ads_config WHERE key = 'ig_dm';
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN',
               'META_WEBHOOK_VERIFY_TOKEN','META_PAGE_TOKEN','GOOGLE_SITE_REFRESH_TOKEN']
$$;
UPDATE public.ads_config SET value = '134', updated_at = now() WHERE key = 'ads_schema' AND value = '135';
