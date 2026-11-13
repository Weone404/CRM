-- Rollback for 096. Re-run 094_ads_agents.sql afterwards to restore svc_ads_agent_next without the playbook,
-- and 077_ads_cron.sql to restore the earlier execute schedule.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-supervise', 'crm-ads-allocate', 'crm-ads-report', 'crm-ads-learn');
  END IF;
END $$;
DROP TRIGGER IF EXISTS trg_ads_learner_done ON public.ads_agent_runs;
DROP FUNCTION IF EXISTS public.svc_ads_supervise(), public.svc_ads_allocate(), public.svc_ads_daily_report(), public.svc_ads_agents_learn(),
  public.api_ads_autopilot_status(), crm_private.ads_system_change(uuid, text, jsonb, text), crm_private.ads_agent_note(text, text, text, jsonb),
  crm_private.ads_report_data(date), crm_private.ads_learner_done();
DROP TABLE IF EXISTS public.ads_playbook;
DELETE FROM public.ads_config WHERE key = 'agents_allocator';
