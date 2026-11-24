-- Down for 134: back to the 124 wrapper.
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_live_v133()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_meta_live();
    ALTER FUNCTION public.api_ads_meta_live_v133() RENAME TO api_ads_meta_live;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_action_done_v133(bigint,text,jsonb,jsonb,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text);
    ALTER FUNCTION public.svc_ads_meta_action_done_v133(bigint, text, jsonb, jsonb, text) RENAME TO svc_ads_meta_action_done;
  END IF;
  DROP FUNCTION IF EXISTS crm_private.ads_meta_object_status_from(text, text, jsonb);
END $$;
REVOKE ALL ON FUNCTION public.api_ads_meta_live() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
REVOKE ALL ON FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) TO service_role;
UPDATE public.ads_config SET value = '130', updated_at = now() WHERE key = 'ads_schema' AND value = '134';
