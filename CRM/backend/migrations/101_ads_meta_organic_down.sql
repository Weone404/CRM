-- Undo 101_ads_meta_organic.sql: back to 100's behaviour (organic form fills are skipped, daily form check).
-- Leads already filed in Leads stay there. Test rows become 'organic' (what 100 called them).

UPDATE public.ads_meta_lead_raw SET status = 'organic' WHERE status = 'test';
ALTER TABLE public.ads_meta_lead_raw DROP CONSTRAINT IF EXISTS ads_meta_lead_raw_status_check;
ALTER TABLE public.ads_meta_lead_raw ADD CONSTRAINT ads_meta_lead_raw_status_check
  CHECK (status IN ('pending', 'ingested', 'failed', 'quarantined', 'organic'));
ALTER TABLE public.ads_meta_lead_raw DROP COLUMN IF EXISTS organic_lead_id;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_lead_finish(p_id bigint, p_status text, p_payload jsonb DEFAULT NULL, p_pipeline text DEFAULT NULL,
  p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_meta_lead_raw; res jsonb; lid uuid; q boolean;
BEGIN
  SELECT * INTO r FROM public.ads_meta_lead_raw WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('pending') THEN RETURN jsonb_build_object('skipped', true); END IF;
  IF p_status = 'organic' THEN
    UPDATE public.ads_meta_lead_raw SET status = 'organic', fetched_at = now(), last_try_at = now(), attempts = attempts + 1, error = NULL WHERE id = p_id;
    RETURN jsonb_build_object('status', 'organic');
  END IF;
  IF p_status <> 'fetched' THEN
    UPDATE public.ads_meta_lead_raw SET attempts = attempts + 1, last_try_at = now(), error = left(coalesce(p_error, 'not fetched'), 400),
      status = CASE WHEN p_status = 'retry' AND attempts + 1 < 12 THEN 'pending' ELSE 'failed' END WHERE id = p_id;
    RETURN jsonb_build_object('status', 'not_fetched');
  END IF;
  res := public.svc_ads_ingest_enquiry(p_payload, coalesce(p_pipeline, 'pilot_training'));
  lid := nullif(res->>'lead_id', '')::uuid;
  IF lid IS NULL THEN
    UPDATE public.ads_meta_lead_raw SET status = 'failed', attempts = attempts + 1, last_try_at = now(), fetched_at = now(),
      error = left(coalesce(res->>'error', res->>'errors_json', 'not accepted by the ADS intake'), 400) WHERE id = p_id;
    RETURN res;
  END IF;
  SELECT l.quarantined INTO q FROM public.ads_lead l WHERE l.id = lid;
  UPDATE public.ads_meta_lead_raw SET status = CASE WHEN q THEN 'quarantined' ELSE 'ingested' END, lead_id = lid,
    attempts = attempts + 1, last_try_at = now(), fetched_at = now(), error = NULL WHERE id = p_id;
  RETURN res;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_test_lead() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('lead_id', l.first_touch->>'leadgen_id', 'em', crm_private.ads_sha256(lower(btrim(l.email))),
    'ph', crm_private.ads_sha256(regexp_replace(l.phone_e164, '\D', '', 'g')),
    'dataset_id', (crm_private.ads_meta_set('instant_form')).dataset_id, 'crm_name', coalesce(nullif(crm_private.ads_cfg('meta_crm_name'), ''), 'We One CRM'))
    FROM public.ads_lead l WHERE l.first_touch->>'meta_source' = 'instant_form' AND l.deleted_at IS NULL
   ORDER BY l.created_at DESC LIMIT 1 $$;

CREATE OR REPLACE FUNCTION public.api_ads_setup_status(p_platform text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE sec jsonb; run jsonb;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_platform NOT IN ('google', 'meta') THEN RAISE EXCEPTION 'Unknown platform' USING ERRCODE = 'PT422'; END IF;
  SELECT jsonb_object_agg(n, EXISTS (SELECT 1 FROM vault.secrets v WHERE v.name = 'ads_' || lower(n))) INTO sec
    FROM unnest(crm_private.ads_secret_names()) n;
  SELECT jsonb_object_agg(r.job, jsonb_build_object('status', r.status, 'detail', r.detail, 'at', coalesce(r.finished_at, r.started_at))) INTO run
    FROM (SELECT DISTINCT ON (job) job, status, detail, finished_at, started_at FROM public.ads_sync_runs
           WHERE job IN ('test_google', 'test_meta', 'meta_page', 'meta_test_event', 'meta_leads', 'meta_convert', 'convert', 'sync')
             AND status <> 'skipped' ORDER BY job, started_at DESC) r;
  RETURN jsonb_build_object(
    'platform', p_platform, 'secrets', sec, 'runs', coalesce(run, '{}'),
    'paused', jsonb_build_object('all', crm_private.ads_cfg('execution_paused') = 'true',
                                 'platform', coalesce(crm_private.ads_cfg(p_platform || '_paused'), 'false') = 'true'),
    'accounts', (SELECT jsonb_build_object('total', count(*), 'connected', count(*) FILTER (WHERE a.status = 'connected'))
                   FROM public.ads_accounts a WHERE a.platform = p_platform),
    'google', CASE WHEN p_platform = 'google' THEN jsonb_build_object(
        'conv_upload', crm_private.ads_cfg('google_conv_upload') = 'on',
        'conv_actions', (SELECT count(*) FROM jsonb_object_keys(crm_private.ads_conversion_actions())),
        'cap_daily', nullif(crm_private.ads_cfg('google_cap_daily'), ''),
        'agents_last_seen', nullif(crm_private.ads_cfg('agents_last_seen'), ''),
        'reported', (SELECT count(*) FROM public.ads_conversion_uploads WHERE status = 'sent')) END,
    'meta', CASE WHEN p_platform = 'meta' THEN jsonb_build_object(
        'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''), 'waba_id', nullif(crm_private.ads_cfg('meta_waba_id'), ''),
        'webhook_verified_at', nullif(crm_private.ads_cfg('meta_webhook_verified_at'), ''),
        'webhook_last_at', nullif(crm_private.ads_cfg('meta_webhook_last_at'), ''),
        'forms', (SELECT count(*) FROM public.ads_meta_forms WHERE active),
        'leads', (SELECT jsonb_build_object('received', count(*), 'ingested', count(*) FILTER (WHERE status = 'ingested'))
                    FROM public.ads_meta_lead_raw WHERE source = 'instant_form'),
        'sources', (SELECT jsonb_object_agg(s.source, jsonb_build_object('intake', s.intake_enabled, 'report', s.report_enabled,
                      'dataset', s.dataset_id IS NOT NULL)) FROM public.ads_meta_settings s),
        'reported', (SELECT count(*) FROM public.ads_meta_capi_uploads WHERE status = 'sent')) END);
END $$;

DELETE FROM public.ads_config WHERE key = 'ads_schema';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-reconcile';
    -- daily 07:15 IST: read each active form's last 48 hours, so a lost webhook never loses a lead
    PERFORM cron.schedule('crm-ads-meta-reconcile', '45 1 * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_leads_reconcile", "meta_leads"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE (SELECT intake_enabled FROM public.ads_meta_settings WHERE source = 'instant_form')
        AND EXISTS (SELECT 1 FROM public.ads_meta_forms WHERE active)
    $job$);
  END IF;
END $$;
