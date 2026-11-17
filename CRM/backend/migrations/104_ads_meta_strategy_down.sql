-- Rollback of 104_ads_meta_strategy.sql. Puts 103 back (the strategy, archive and alert tables are dropped).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-meta-track', 'crm-ads-lead-alerts');
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_ads_meta_archive ON public.ads_meta_lead_raw;
DROP FUNCTION IF EXISTS public.api_ads_meta_strategy_create(jsonb), public.api_ads_meta_strategy_change(bigint, text, boolean, jsonb),
  public.api_ads_meta_strategy_approve(bigint, int), public.api_ads_meta_strategy_archive(bigint, boolean),
  public.api_ads_meta_strategy_link(bigint, jsonb), public.api_ads_meta_strategies(), public.api_ads_meta_strategy(bigint, int),
  public.api_ads_meta_strategy_build(bigint), public.api_ads_meta_leads_import(jsonb), public.api_ads_meta_archive(),
  public.api_ads_meta_archive_export(), public.api_ads_lead_alerts(), public.api_ads_lead_alerts_save(jsonb),
  public.svc_ads_agent_next2(boolean), public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text),
  public.svc_ads_meta_build_work(bigint), public.svc_ads_meta_build_work_peek(bigint), public.svc_ads_meta_build_step(bigint, text, jsonb), public.svc_ads_meta_build_end(bigint, text, text),
  public.svc_ads_meta_build_image(bigint, text, text, text), public.svc_ads_meta_strategy_track(),
  public.svc_ads_lead_alerts_claim(), public.svc_ads_lead_alerts_done(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_meta_agent_ctx(public.ads_agent_runs), crm_private.ads_meta_queue(bigint, text, int, jsonb, bigint),
  crm_private.ads_meta_save_version(public.ads_agent_runs, jsonb, jsonb, text), crm_private.ads_meta_chain_stop(public.ads_agent_runs, text),
  crm_private.ads_meta_runs_left(), crm_private.ads_meta_strategy_actual(public.ads_meta_strategy, date, date),
  crm_private.ads_meta_strategy_campaigns(public.ads_meta_strategy), crm_private.ads_meta_plan_daily(jsonb),
  crm_private.ads_meta_plan_check(jsonb, jsonb), crm_private.ads_meta_goal_clean(jsonb), crm_private.ads_meta_leads_30d(),
  crm_private.ads_meta_archive_raw(public.ads_meta_lead_raw), crm_private.ads_meta_archive_trg(),
  crm_private.ads_lead_alerts_due(), crm_private.ads_lead_waiting(), crm_private.ads_lead_alert_start(timestamptz),
  crm_private.ads_meta_https(text), crm_private.ads_meta_today(), crm_private.ads_meta_acct();

DROP TABLE IF EXISTS public.ads_lead_alert, public.ads_meta_lead_archive, public.ads_meta_strategy_check,
  public.ads_meta_strategy_version, public.ads_meta_strategy;
ALTER TABLE public.ads_meta_forms DROP COLUMN IF EXISTS full_swept_at;

-- reconcile as in 100
CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconcile_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'enabled', (crm_private.ads_meta_set('instant_form')).intake_enabled,
    'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('form_id', f.form_id,
                'since', floor(extract(epoch FROM least(now() - interval '48 hours', coalesce(f.last_reconciled_at - interval '1 hour', now() - interval '48 hours')))))
                ORDER BY f.form_id), '[]') FROM public.ads_meta_forms f WHERE f.active)) $$;
CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconciled(p_form text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_forms SET last_reconciled_at = now() WHERE form_id = p_form;
  INSERT INTO public.ads_config (key, value) VALUES ('meta_reconcile_last_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
$$;
REVOKE ALL ON FUNCTION public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text) TO service_role;

DELETE FROM public.ads_agent_runs WHERE role LIKE 'meta\_%';
ALTER TABLE public.ads_agent_runs DROP CONSTRAINT IF EXISTS ads_agent_runs_role_check;
ALTER TABLE public.ads_agent_runs ADD CONSTRAINT ads_agent_runs_role_check
  CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor', 'team_lead', 'tracking'));
DELETE FROM public.ads_config WHERE key IN ('meta_strategy_per_day', 'lead_alert_on', 'lead_alert_minutes', 'lead_alert_escalate_minutes',
  'lead_alert_from', 'lead_alert_to', 'lead_alert_since');
UPDATE public.ads_config SET value = '103', updated_at = now() WHERE key = 'ads_schema';
