-- 128 down (builds already made stay as they are in build; pause requests stay in the approval queue)
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_strategy_build_v127(bigint)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_meta_strategy_build(bigint);
    ALTER FUNCTION public.api_ads_meta_strategy_build_v127(bigint) RENAME TO api_ads_meta_strategy_build;
    GRANT EXECUTE ON FUNCTION public.api_ads_meta_strategy_build(bigint) TO authenticated;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_answer_text_v127(text,jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_answer_text(text, jsonb);
    ALTER FUNCTION crm_private.ads_meta_answer_text_v127(text, jsonb) RENAME TO ads_meta_answer_text;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_meta_plan_keys(jsonb);
UPDATE public.ads_config SET value = '127', updated_at = now() WHERE key = 'ads_schema';
