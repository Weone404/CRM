-- 122 Meta Ads > Overview: "updated" shows when the CRM last read Meta's numbers (meta_history), not the date of the last
-- spend row (a new campaign with no spend yet showed "updated 3 d ago"). Wrapper-by-rename over 121.
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_live_v121()') IS NULL THEN ALTER FUNCTION public.api_ads_meta_live() RENAME TO api_ads_meta_live_v121; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ads_meta_live() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_ads_meta_live_v121(); r timestamptz;
BEGIN
  r := nullif(crm_private.ads_cfg('meta_history_recent_at'), '')::timestamptz;
  RETURN o || jsonb_build_object('numbers_at', to_jsonb(greatest(r, nullif(o->>'numbers_at', '')::timestamptz)));
END $$;
REVOKE ALL ON FUNCTION public.api_ads_meta_live(), public.api_ads_meta_live_v121() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_ads_meta_live_v121() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '122') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
