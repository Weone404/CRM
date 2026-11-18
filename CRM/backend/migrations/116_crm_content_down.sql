-- 116 rollback: Content out; the agents' queue, the vault overview and connections go back to before.
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-content-week'; END IF; END $$;
DROP POLICY IF EXISTS content_read ON storage.objects;
DROP FUNCTION IF EXISTS public.svc_content_token_ok(text);
DROP FUNCTION IF EXISTS public.svc_content_next();
DROP FUNCTION IF EXISTS public.svc_content_update(bigint, jsonb);
DROP FUNCTION IF EXISTS public.svc_content_signals();
DROP FUNCTION IF EXISTS public.svc_content_picture(bigint, text, text);
DROP FUNCTION IF EXISTS public.api_content_overview(date);
DROP FUNCTION IF EXISTS public.api_content_plan(date, text);
DROP FUNCTION IF EXISTS public.api_content_item_save(jsonb);
DROP FUNCTION IF EXISTS public.api_content_from_strategy(bigint);
DROP FUNCTION IF EXISTS public.api_content_settings_save(jsonb);
DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_agent_next2_v104(boolean)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_agent_next2(boolean);
    ALTER FUNCTION public.svc_ads_agent_next2_v104(boolean) RENAME TO svc_ads_agent_next2;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_agent_finish_v104(bigint,boolean,jsonb,text,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text);
    ALTER FUNCTION public.svc_ads_meta_agent_finish_v104(bigint, boolean, jsonb, text, text) RENAME TO svc_ads_meta_agent_finish;
  END IF;
  IF to_regprocedure('public.api_vault_overview_v111()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_vault_overview();
    ALTER FUNCTION public.api_vault_overview_v111() RENAME TO api_vault_overview;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.content_agent_ctx(public.ads_agent_runs);
DROP FUNCTION IF EXISTS crm_private.content_plan_check(date, jsonb);
DROP FUNCTION IF EXISTS crm_private.content_week_tick();
DROP FUNCTION IF EXISTS crm_private.content_plan_queue(date, text, uuid);
DROP FUNCTION IF EXISTS crm_private.content_demand();
DROP FUNCTION IF EXISTS crm_private.content_leads(bigint);
DROP FUNCTION IF EXISTS crm_private.content_link(bigint, text);
UPDATE public.ads_agent_runs SET status = 'failed', error = 'Content removed' WHERE role IN ('meta_content_analyst', 'meta_content_planner') AND status IN ('queued', 'running');
DROP TABLE IF EXISTS public.content_item, public.content_plan;
-- the role list keeps the content roles (old runs stay readable); the Reel Studio token stays in the Vault.
CREATE OR REPLACE FUNCTION crm_private.connection_secret(p_id text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_id WHEN 'charter' THEN 'crm_charter_ingest_token' WHEN 'hikvision' THEN 'crm_attendance_ingest_token' WHEN 'partner' THEN 'crm_partner_api_token' END $$;
CREATE OR REPLACE FUNCTION public.api_connections() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can view connections' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT json_object_agg(c.id, json_build_object('last4', right(s.decrypted_secret, 4), 'updated_at', s.updated_at))
    FROM (VALUES ('charter'), ('hikvision'), ('partner')) c(id) JOIN vault.decrypted_secrets s ON s.name = crm_private.connection_secret(c.id)), '{}');
END $$;
UPDATE public.ads_config SET value = '115', updated_at = now() WHERE key = 'ads_schema';
