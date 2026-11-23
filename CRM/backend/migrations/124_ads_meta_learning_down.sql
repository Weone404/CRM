-- 124 down
DROP TRIGGER IF EXISTS ads_meta_keep_lessons ON public.ads_agent_runs;
DROP FUNCTION IF EXISTS crm_private.ads_meta_keep_lessons();
DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_agent_ctx_v123(public.ads_agent_runs)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_agent_ctx(public.ads_agent_runs);
    ALTER FUNCTION crm_private.ads_meta_agent_ctx_v123(public.ads_agent_runs) RENAME TO ads_meta_agent_ctx;
  END IF;
  IF to_regprocedure('public.api_ads_meta_live_v122()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_meta_live();
    ALTER FUNCTION public.api_ads_meta_live_v122() RENAME TO api_ads_meta_live;
    GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_meta_last_test(bigint);
DROP FUNCTION IF EXISTS crm_private.ads_meta_lead_answers(uuid);
DROP FUNCTION IF EXISTS crm_private.ads_meta_answer_text(text, jsonb);
DROP TABLE IF EXISTS public.ads_meta_lesson;
UPDATE public.ads_config SET value = '123', updated_at = now() WHERE key = 'ads_schema';
