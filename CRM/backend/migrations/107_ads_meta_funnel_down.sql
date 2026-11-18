-- Rollback of 107_ads_meta_funnel.sql. Puts 106 back. Audiences already made in Meta stay there (delete them in Ads Manager if wanted).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-audiences';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.api_ads_meta_audiences(),
  public.api_ads_meta_audience_save(text, boolean, boolean), public.api_ads_meta_audiences_on(boolean),
  public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_audiences_done(jsonb),
  crm_private.ads_meta_audience_people(jsonb);
DROP TABLE IF EXISTS public.ads_meta_audience, public.ads_geo_in;
DELETE FROM public.ads_config WHERE key IN ('meta_audiences_on', 'meta_audiences_last');
-- the 104 version of the build work
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; acc public.ads_accounts := crm_private.ads_meta_acct();
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL OR coalesce(s.build->>'status', '') NOT IN ('queued', 'running', 'error', 'partial') OR s.approved_version IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('status', 'running', 'at', now()) WHERE id = p_id;
  RETURN jsonb_build_object('strategy_id', s.id, 'version', s.approved_version, 'account_id', acc.external_id, 'currency', acc.currency,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''), 'goal', s.goal,
    'plan', (SELECT v.plan FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.approved_version),
    'steps', coalesce(s.build->'steps', '{}'), 'images', coalesce(s.build->'images', '{}'));
END $$;

REVOKE ALL ON FUNCTION public.svc_ads_meta_build_work(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_build_work(bigint) TO service_role;
UPDATE public.ads_config SET value = '106', updated_at = now() WHERE key = 'ads_schema';
