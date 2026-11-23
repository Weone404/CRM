-- 129 down (ads_meta_object.info.daily_budget values stay; budget requests already made stay in the approval list)
DROP FUNCTION IF EXISTS public.api_ads_meta_budget_split_save(jsonb);
DROP FUNCTION IF EXISTS public.api_ads_meta_budget_split();
DROP FUNCTION IF EXISTS public.svc_ads_meta_budgets_save(jsonb);
DO $$ BEGIN
  IF to_regprocedure('public.svc_ads_meta_action_done_v128(bigint,text,jsonb,jsonb,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text);
    ALTER FUNCTION public.svc_ads_meta_action_done_v128(bigint, text, jsonb, jsonb, text) RENAME TO svc_ads_meta_action_done;
    GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) TO service_role;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_action_work_v128()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_action_work();
    ALTER FUNCTION public.svc_ads_meta_action_work_v128() RENAME TO svc_ads_meta_action_work;
    GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_work() TO service_role;
  END IF;
  IF to_regprocedure('public.api_ads_meta_action_request_v128(text,text,text,jsonb,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_meta_action_request(text, text, text, jsonb, text);
    ALTER FUNCTION public.api_ads_meta_action_request_v128(text, text, text, jsonb, text) RENAME TO api_ads_meta_action_request;
    GRANT EXECUTE ON FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text) TO authenticated;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_action_guard_v128(text,text,jsonb,numeric)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_action_guard(text, text, jsonb, numeric);
    ALTER FUNCTION crm_private.ads_meta_action_guard_v128(text, text, jsonb, numeric) RENAME TO ads_meta_action_guard;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_meta_split_min();
DELETE FROM public.ads_config WHERE key = 'meta_split_min_daily';
UPDATE public.ads_config SET value = '128', updated_at = now() WHERE key = 'ads_schema';
