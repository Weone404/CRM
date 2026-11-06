-- 074: Amazon module schedules (pg_cron -> amazon-sync Edge Function). Run after 072 and 073,
-- and after the amazon-sync function is deployed. Uses the existing crm_cron_token from 053.
-- Times are UTC (IST = UTC + 5:30). Re-running replaces the jobs.

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE 'crm-amazon-%';

-- Listings + Buy Box/pricing every 30 minutes
SELECT cron.schedule('crm-amazon-listings', '7,37 * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["listings", "pricing"]}'::jsonb, timeout_milliseconds := 140000)
$job$);

-- Approved changes nobody ran (browser closed) and executions stuck after a network drop: every 5 minutes
SELECT cron.schedule('crm-amazon-execute', '*/5 * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["execute"]}'::jsonb, timeout_milliseconds := 140000)
$job$);

-- Reports (sales & traffic per day, seller performance) and finances: hourly
SELECT cron.schedule('crm-amazon-reports', '17 * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["reports", "finances"]}'::jsonb, timeout_milliseconds := 140000)
$job$);

-- Audit engine: nightly 02:30 IST (21:00 UTC)
SELECT cron.schedule('crm-amazon-audit', '0 21 * * *', $job$ SELECT public.svc_amz_audit() $job$);
