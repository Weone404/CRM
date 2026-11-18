-- Rollback of 109_ads_meta_funnel_plan.sql. Puts 108 back (lookalike rows and personas dropped; lookalikes already in Meta stay).
DROP FUNCTION IF EXISTS public.api_ads_meta_personas(), public.api_ads_meta_persona_save(jsonb), public.api_ads_meta_funnel_blueprint(numeric, jsonb),
  crm_private.ads_meta_funnel_blueprint(numeric, jsonb);
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_meta_goal_clean_base(jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_goal_clean(jsonb);
    ALTER FUNCTION crm_private.ads_meta_goal_clean_base(jsonb) RENAME TO ads_meta_goal_clean;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_plan_check_base(jsonb,jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_meta_plan_check(jsonb, jsonb);
    ALTER FUNCTION crm_private.ads_meta_plan_check_base(jsonb, jsonb) RENAME TO ads_meta_plan_check;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_text_overlap(text, text);
DROP TABLE IF EXISTS public.ads_meta_persona;
DELETE FROM public.ads_meta_audience WHERE kind = 'lookalike';
ALTER TABLE public.ads_meta_audience DROP CONSTRAINT IF EXISTS ads_meta_audience_use_as_check;
ALTER TABLE public.ads_meta_audience ADD CONSTRAINT ads_meta_audience_use_as_check CHECK (use_as IN ('retarget', 'exclude', 'seed', 'reengage'));
ALTER TABLE public.ads_meta_audience DROP CONSTRAINT IF EXISTS ads_meta_audience_stage_check;
ALTER TABLE public.ads_meta_audience ADD CONSTRAINT ads_meta_audience_stage_check CHECK (stage IN ('engaged', 'hot', 'lead', 'qualified', 'customer'));

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('on', crm_private.ads_cfg('meta_audiences_on') = 'true',
    'account_id', (crm_private.ads_meta_acct()).external_id,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'pixel_id', nullif(crm_private.ads_cfg('meta_pixel'), '')::jsonb->>'id',
    'forms', (SELECT coalesce(jsonb_agg(f.form_id ORDER BY f.updated_at DESC), '[]') FROM (SELECT * FROM public.ads_meta_forms ORDER BY updated_at DESC LIMIT 50) f),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'spec', a.spec, 'meta_id', a.meta_id, 'why', a.why,
        'people', CASE WHEN a.kind = 'crm' THEN (SELECT coalesce(jsonb_agg(jsonb_build_array(p.ph, p.em)), '[]')
                                                  FROM (SELECT * FROM crm_private.ads_meta_audience_people(a.spec) LIMIT 50000) p) END) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled AND a.kind IN ('engagement', 'crm', 'website'))) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_saved(p_key text, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_audience SET
    meta_id = coalesce(substring(p_data->>'meta_id' FROM '^[0-9]{5,25}$'), meta_id),
    status = CASE WHEN p_data->>'status' IN ('ready', 'error') THEN p_data->>'status' ELSE status END,
    size_low = CASE WHEN p_data ? 'size_low' THEN nullif(p_data->>'size_low', '')::bigint ELSE size_low END,
    size_high = CASE WHEN p_data ? 'size_high' THEN nullif(p_data->>'size_high', '')::bigint ELSE size_high END,
    members = CASE WHEN p_data ? 'members' THEN (p_data->>'members')::int ELSE members END,
    detail = left(p_data->>'detail', 600), synced_at = now(), updated_at = now()
   WHERE key = p_key $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_strategy_extra() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := crm_private.ads_meta_today(); f jsonb; g jsonb; s jsonb;
BEGIN
  f := crm_private.ads_meta_funnel_data(today - 90, today);
  g := crm_private.ads_meta_geo_data(today - 365, today);
  s := crm_private.ads_site_signals();
  RETURN jsonb_build_object(
    'funnel_90d', jsonb_build_object('stages', f->'stages', 'spend', f->'spend', 'first_call_min', f->'first_call_min', 'qualify_days', f->'qualify_days', 'notes', f->'notes'),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'stage', a.stage, 'use_as', a.use_as,
        'ready_in_meta', a.status = 'ready', 'size', a.size_high, 'excluded_by_default', a.exclude_default) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled),
    'locations', jsonb_build_object('avg_q_rate', g->'avg_q_rate', 'regions', (SELECT coalesce(jsonb_agg(r), '[]') FROM (SELECT r FROM jsonb_array_elements(g->'regions') r LIMIT 15) z),
      'unknown_location', g->'unknown_location'),
    'website', jsonb_build_object('configured', s->'configured', 'totals', s->'totals', 'pixel', s->'pixel',
      'topics', s->'topics', 'rising', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'rising') x LIMIT 10) z),
      'pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'pages') x LIMIT 10) z),
      'cities', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'cities') x LIMIT 10) z),
      'web_funnel', s->'web_funnel'));
END $$;

REVOKE ALL ON FUNCTION public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_strategy_extra() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_strategy_extra() TO service_role;
UPDATE public.ads_config SET value = '108', updated_at = now() WHERE key = 'ads_schema';
