-- Undo 112: removes the Website section's tables, functions and nightly jobs. Keys in Vault are kept, except the
-- optional PageSpeed key added by 112 (crm_web_psi_api_key). Leads, ADS and Search Console data elsewhere are untouched.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-web-data', 'crm-web-scan', 'crm-web-speed');
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.svc_web_run_end(bigint, text, text);
DROP FUNCTION IF EXISTS public.svc_web_run_begin(text);
DROP FUNCTION IF EXISTS public.svc_web_checks_prune(text, text[]);
DROP FUNCTION IF EXISTS public.svc_web_check_save(text, jsonb);
DROP FUNCTION IF EXISTS public.svc_web_pages_save(jsonb);
DROP FUNCTION IF EXISTS public.svc_web_save(text, text[], jsonb);
DROP FUNCTION IF EXISTS public.svc_web_work();
DROP FUNCTION IF EXISTS public.api_web_copilot_upload(text, jsonb);
DROP FUNCTION IF EXISTS public.api_web_settings_save(text, text, text);
DROP FUNCTION IF EXISTS public.api_web_settings();
DROP FUNCTION IF EXISTS public.api_web_queries(text, text, int);
DROP FUNCTION IF EXISTS public.api_web_overview();
DROP FUNCTION IF EXISTS public.api_web_access();
DROP FUNCTION IF EXISTS crm_private.web_queries();
DROP FUNCTION IF EXISTS crm_private.web_is_question(text);
DROP FUNCTION IF EXISTS crm_private.web_is_brand(text);
DROP FUNCTION IF EXISTS crm_private.web_ai_tool(text);
DROP FUNCTION IF EXISTS crm_private.web_can_run();
DROP FUNCTION IF EXISTS crm_private.web_can_view();
DROP FUNCTION IF EXISTS crm_private.web_google_cfg(text);
DROP FUNCTION IF EXISTS crm_private.web_cfg(text);
DROP TABLE IF EXISTS public.web_config, public.web_run, public.web_copilot, public.web_check, public.web_page, public.web_row;
DELETE FROM vault.secrets WHERE name = 'crm_web_psi_api_key';
