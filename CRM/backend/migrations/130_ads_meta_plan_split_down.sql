-- 130 down
DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_plan_check_v129(jsonb,jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_plan_check(jsonb, jsonb);
    ALTER FUNCTION crm_private.ads_meta_plan_check_v129(jsonb, jsonb) RENAME TO ads_meta_plan_check;
  END IF;
END $$;
UPDATE public.ads_config SET value = '129', updated_at = now() WHERE key = 'ads_schema';
