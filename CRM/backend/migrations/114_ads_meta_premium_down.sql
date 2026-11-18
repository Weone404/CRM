-- 114 rollback: back to the 109 checks, goal, blueprint and agents' context.
DROP FUNCTION IF EXISTS public.svc_ads_meta_targeting_save(jsonb);
DROP FUNCTION IF EXISTS public.api_ads_meta_targeting();
DROP FUNCTION IF EXISTS public.svc_ads_meta_targeting_get();
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_meta_goal_clean_v109(jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_goal_clean(jsonb);
    ALTER FUNCTION crm_private.ads_meta_goal_clean_v109(jsonb) RENAME TO ads_meta_goal_clean;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_plan_check_v109(jsonb,jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_plan_check(jsonb, jsonb);
    ALTER FUNCTION crm_private.ads_meta_plan_check_v109(jsonb, jsonb) RENAME TO ads_meta_plan_check;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_funnel_blueprint_v109(numeric,jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_funnel_blueprint(numeric, jsonb);
    ALTER FUNCTION crm_private.ads_meta_funnel_blueprint_v109(numeric, jsonb) RENAME TO ads_meta_funnel_blueprint;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_strategy_extra_v109()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_strategy_extra();
    ALTER FUNCTION public.svc_ads_meta_strategy_extra_v109() RENAME TO svc_ads_meta_strategy_extra;
  END IF;
END $$;
UPDATE public.ads_meta_persona SET name = 'Graduate or working professional switching career',
  who = 'Finished a degree or working, in their 20s, wants a career change into flying; time and money are the main worries.'
 WHERE key = 'career_switcher' AND name = 'Graduate, MBA or working professional switching career';
UPDATE public.ads_meta_persona SET stages = '["retarget", "reengage"]' WHERE key = 'parent' AND stages = '["prospecting", "retarget", "reengage"]'::jsonb;
DELETE FROM public.ads_config WHERE key IN ('meta_metro_preset', 'meta_targeting_support');
UPDATE public.ads_config SET value = '109', updated_at = now() WHERE key = 'ads_schema';
-- the base check keeps accepting zip locations; harmless without the 114 wrapper (Meta build ignores unknown types)
