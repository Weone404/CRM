-- 079: Orders to ship (amazon-sync job "orders") every 15 minutes. Run after 078 and after amazon-sync is redeployed.
-- Times are UTC. Re-running replaces the job.

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-amazon-orders';

SELECT cron.schedule('crm-amazon-orders', '2,17,32,47 * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{"jobs": ["orders"]}'::jsonb, timeout_milliseconds := 140000)
$job$);
