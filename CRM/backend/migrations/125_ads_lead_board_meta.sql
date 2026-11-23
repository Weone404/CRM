-- 125 Leads > Meta Leads: each ad lead on the board carries what the person answered (in words), which ad brought them
-- (the creative's headline for CRM-built ads, else Meta's ad name) and the app (Instagram / Facebook). Wrapper-by-rename.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_ad_label(p_ad text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(
    (SELECT c->>'headline' FROM public.ads_meta_strategy s
       JOIN LATERAL jsonb_each(s.build->'steps') e ON e.key LIKE 'ad:%' AND e.value->>'id' = p_ad
       JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id AND v.version = coalesce((s.build->>'version')::int, s.approved_version)
       JOIN LATERAL jsonb_array_elements(v.plan->'creatives') c ON c->>'key' = split_part(e.key, ':', 3) LIMIT 1),
    (SELECT regexp_replace(o.name, '\s*·\s*CRM S\d+$', '') FROM public.ads_meta_object o WHERE o.level = 'ad' AND o.external_id = p_ad LIMIT 1)) $$;

DO $$ BEGIN
  IF to_regprocedure('public.api_ads_lead_board_v124(text,text,boolean,text,integer,text)') IS NULL THEN
    ALTER FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) RENAME TO api_ads_lead_board_v124;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ads_lead_board(p_pipeline text DEFAULT 'pilot_training', p_stage text DEFAULT NULL, p_quarantined boolean DEFAULT false,
  p_search text DEFAULT NULL, p_limit integer DEFAULT 100, p_platform text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_ads_lead_board_v124(p_pipeline, p_stage, p_quarantined, p_search, p_limit, p_platform); rows jsonb := '[]'; r jsonb; ad text;
BEGIN
  IF o IS NULL OR jsonb_typeof(o->'rows') <> 'array' THEN RETURN o; END IF;
  FOR r IN SELECT value FROM jsonb_array_elements(o->'rows') LOOP
    ad := r->'first_touch'->>'ad_id';
    rows := rows || jsonb_build_array(r || jsonb_build_object(
      'answers', crm_private.ads_meta_lead_answers((r->>'id')::uuid),
      'ad_name', CASE WHEN ad IS NOT NULL THEN crm_private.ads_meta_ad_label(ad) END,
      'app', CASE r->'first_touch'->>'meta_platform' WHEN 'ig' THEN 'Instagram' WHEN 'fb' THEN 'Facebook' WHEN 'msg' THEN 'Messenger' WHEN 'wa' THEN 'WhatsApp' END));
  END LOOP;
  RETURN o || jsonb_build_object('rows', rows);
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_meta_ad_label(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_lead_board_v124(text, text, boolean, text, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '125') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
