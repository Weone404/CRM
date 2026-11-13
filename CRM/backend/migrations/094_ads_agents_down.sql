-- Rollback for 094 (ADS agents queue).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-agents-tick';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.svc_ads_agent_next(), public.svc_ads_agent_release(bigint, text),
  public.svc_ads_agent_finish(bigint, boolean, jsonb, text, text), public.svc_ads_agents_tick(),
  crm_private.ads_agent_context(public.ads_agent_runs), crm_private.ads_agent_close(public.ads_agent_runs, boolean, text),
  crm_private.ads_agent_check(jsonb);
ALTER TABLE public.ads_agent_runs DROP COLUMN IF EXISTS claims;
DELETE FROM public.ads_config WHERE key IN ('google_brand_facts', 'agents_daily_review');
