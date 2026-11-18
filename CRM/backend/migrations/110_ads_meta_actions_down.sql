-- Rollback of 110_ads_meta_actions.sql. Puts 109 back (action history, rules and tests are dropped; nothing is changed in Meta).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-meta-rules', 'crm-ads-meta-actions');
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.api_ads_meta_action_request(text, text, text, jsonb, text), public.api_ads_meta_action_decide(bigint, boolean, text),
  public.api_ads_meta_actions(int), public.api_ads_meta_objects(text, int), public.api_ads_meta_rules_run(bigint), public.api_ads_meta_rules(),
  public.api_ads_meta_rule_save(jsonb), public.api_ads_meta_tests(), public.api_ads_meta_test_save(jsonb),
  public.svc_ads_meta_action_work(), public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_rules_run(),
  public.svc_ads_meta_test_work(), public.svc_ads_meta_test_saved(bigint, text, text),
  crm_private.ads_meta_test_result(public.ads_meta_test), crm_private.ads_norm_cdf(numeric), crm_private.ads_meta_rules_run(bigint),
  crm_private.ads_meta_action_add(text, text, text, jsonb, text, text, bigint, bigint, uuid), crm_private.ads_meta_action_guard(text, text, jsonb, numeric),
  crm_private.ads_meta_metric(text, numeric, bigint, bigint, bigint, bigint, numeric), crm_private.ads_meta_obj_stats(text, date, date);
DROP TABLE IF EXISTS public.ads_meta_action, public.ads_meta_rule, public.ads_meta_test;
DELETE FROM public.ads_meta_warning WHERE kind LIKE 'rule\_%';
DELETE FROM public.ads_config WHERE key IN ('meta_action_min_daily', 'meta_action_max_daily', 'meta_actions_two_person');
UPDATE public.ads_config SET value = '109', updated_at = now() WHERE key = 'ads_schema';
