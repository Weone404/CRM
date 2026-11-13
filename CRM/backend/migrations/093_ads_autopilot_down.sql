-- Rollback for 093 (ADS Autopilot). Restores the 076 evaluator by re-running 076's function, so run
-- 076_ads_module.sql afterwards (it is re-runnable) to put ads_evaluate back without the spend limits.
DROP FUNCTION IF EXISTS public.api_ads_autopilot(), public.api_ads_autopilot_save(text, numeric, numeric),
  public.api_ads_autopilot_stop(boolean), public.api_ads_funds_add(numeric, date, text), public.api_ads_funds_delete(bigint),
  public.api_ads_agent_instruct(text, text), public.api_ads_suggestion_decide(bigint, text, text, text[]),
  public.api_ads_agents_token_rotate(), public.svc_ads_agents_token_ok(text);
DROP TABLE IF EXISTS public.ads_agent_instructions, public.ads_autopilot_suggestions, public.ads_funds, public.ads_agent_runs;
DELETE FROM public.ads_config WHERE key IN ('google_cap_daily', 'google_cap_monthly', 'agents_token_sha256');
-- ads_google_* helpers are left in place until 076 is re-run (the 093 evaluator uses them).
