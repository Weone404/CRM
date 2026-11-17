-- Undo 103_ads_meta_insights.sql: removes Meta Ads > Insights data, notes and monthly summaries (nothing else changes).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-history';
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_meta_history_wake();
DROP FUNCTION IF EXISTS public.svc_ads_meta_report_save(date, jsonb, jsonb, boolean, text);
DROP FUNCTION IF EXISTS public.svc_ads_meta_report_data(date);
DROP FUNCTION IF EXISTS public.svc_ads_meta_history_mark(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_meta_set_cfg(text, text);
DROP FUNCTION IF EXISTS public.svc_ads_meta_breakdowns_save(uuid, text, date, jsonb);
DROP FUNCTION IF EXISTS public.svc_ads_meta_ad_days_save(uuid, jsonb);
DROP FUNCTION IF EXISTS public.svc_ads_meta_objects_save(uuid, jsonb);
DROP FUNCTION IF EXISTS public.svc_ads_meta_history_plan();
DROP FUNCTION IF EXISTS public.svc_ads_meta_mail_config();
DROP FUNCTION IF EXISTS public.api_ads_meta_report_emails_save(jsonb);
DROP FUNCTION IF EXISTS public.api_ads_meta_reports();
DROP FUNCTION IF EXISTS crm_private.ads_meta_mail_ready();
DROP FUNCTION IF EXISTS public.api_ads_meta_note_delete(bigint);
DROP FUNCTION IF EXISTS public.api_ads_meta_note_save(date, text);
DROP FUNCTION IF EXISTS public.api_ads_meta_insights(date, date, text, text, text);
DROP FUNCTION IF EXISTS crm_private.ads_meta_insights_data(date, date, text, text, text);
DROP FUNCTION IF EXISTS crm_private.ads_meta_totals(date, date, text, text, text);
DROP FUNCTION IF EXISTS crm_private.ads_meta_crm(date, date, text, text, text);
DROP FUNCTION IF EXISTS crm_private.ads_meta_days(date, date, text, text);
DROP TABLE IF EXISTS public.ads_meta_report;
DROP TABLE IF EXISTS public.ads_meta_note;
DROP TABLE IF EXISTS public.ads_meta_breakdown;
DROP TABLE IF EXISTS public.ads_meta_ad_day;
DROP TABLE IF EXISTS public.ads_meta_object;
DELETE FROM public.ads_config WHERE key IN ('meta_history_months', 'meta_history_cursor', 'meta_history_done_at',
  'meta_history_recent_at', 'meta_history_breakdowns_at', 'meta_report_emails');
UPDATE public.ads_config SET value = '102', updated_at = now() WHERE key = 'ads_schema';
