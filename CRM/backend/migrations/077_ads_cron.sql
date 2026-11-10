-- 077: ADS module schedules (pg_cron -> ads-sync Edge Function). Run after 076 and after ads-sync is deployed.
-- Uses the existing crm_cron_token from 053. Times are UTC (IST = UTC + 5:30). Re-running replaces the jobs.
-- With no keys saved, each run records "Not configured" and makes no platform calls.

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE 'crm-ads-%';

-- Campaigns + daily metrics for every account: every 3 hours at :23
SELECT cron.schedule('crm-ads-sync', '23 */3 * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["sync"]}'::jsonb, timeout_milliseconds := 140000)
$job$);

-- Approved changes nobody ran (browser closed) and outcome-unknown re-checks: every 5 minutes, only when there is work
SELECT cron.schedule('crm-ads-execute', '*/5 * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["execute"]}'::jsonb, timeout_milliseconds := 140000)
  WHERE EXISTS (SELECT 1 FROM public.ads_change_queue WHERE status IN ('approved', 'outcome_unknown')
                 OR (status = 'executing' AND executed_at < now() - interval '10 minutes'))
$job$);
