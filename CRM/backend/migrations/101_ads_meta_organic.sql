-- 101: Meta lead forms, part 2 (17 Nov 2026). Needs 100_ads_meta_signals.sql. Safe to run again.
--   * A Meta lead form filled WITHOUT an ad (someone opened the form from the Page) is no longer dropped: it becomes a
--     normal lead in Leads (utm_source "Meta lead form", utm_medium "organic", utm_campaign = the form's name), with the
--     same phone de-duplication as the website forms. It is not an Ads lead and is never reported to Meta. A form set to
--     Charter files it as a charter lead. Extra form answers are kept on the raw row (ads_meta_lead_raw.payload.answers).
--   * Leads made with Meta's Lead Ads Testing Tool are recognised by ads-sync (Meta fills every field with
--     "test lead: dummy data for ...") and kept as status 'test': they prove the path works and are never filed.
--   * "Send a test event" can use a Testing Tool lead's id when there is no Ads lead from a form yet.
--   * The safety check that reads every active form now runs every hour instead of once a day.
--   * The database tells Setup its ADS version (ads_config ads_schema), so Setup shows when an update is waiting.
-- Undo: 101_ads_meta_organic_down.sql.

ALTER TABLE public.ads_meta_lead_raw ADD COLUMN IF NOT EXISTS organic_lead_id uuid REFERENCES public.lead(id) ON DELETE SET NULL;
ALTER TABLE public.ads_meta_lead_raw DROP CONSTRAINT IF EXISTS ads_meta_lead_raw_status_check;
ALTER TABLE public.ads_meta_lead_raw ADD CONSTRAINT ads_meta_lead_raw_status_check
  CHECK (status IN ('pending', 'ingested', 'failed', 'quarantined', 'organic', 'test'));

-- p_status: 'fetched' (an Ads lead: ADS intake), 'organic' (+ p_payload: a normal lead), 'test', 'retry' / 'failed'.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_lead_finish(p_id bigint, p_status text, p_payload jsonb DEFAULT NULL, p_pipeline text DEFAULT NULL,
  p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_meta_lead_raw; res jsonb; lid uuid; q boolean; p jsonb;
BEGIN
  SELECT * INTO r FROM public.ads_meta_lead_raw WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('pending') THEN RETURN jsonb_build_object('skipped', true); END IF;
  -- A lead made with Meta's Lead Ads Testing Tool: proves the path works; never filed as a lead.
  IF p_status = 'test' THEN
    UPDATE public.ads_meta_lead_raw SET status = 'test', fetched_at = now(), last_try_at = now(), attempts = attempts + 1, error = NULL WHERE id = p_id;
    RETURN jsonb_build_object('status', 'test');
  END IF;
  -- A form filled without an ad (opened from the Page): a normal lead in Leads, not an Ads lead. Same phone
  -- de-duplication as the website forms; a form set to Charter files it as a charter lead.
  IF p_status = 'organic' THEN
    IF p_payload IS NULL THEN
      UPDATE public.ads_meta_lead_raw SET status = 'organic', fetched_at = now(), last_try_at = now(), attempts = attempts + 1, error = NULL WHERE id = p_id;
      RETURN jsonb_build_object('status', 'organic');
    END IF;
    p := p_payload - 'meta_answers';
    IF coalesce(p->>'utm_campaign', '') = '' THEN
      p := p || jsonb_build_object('utm_campaign', coalesce((SELECT f.name FROM public.ads_meta_forms f WHERE f.form_id = r.form_id), r.form_id));
    END IF;
    res := crm_private.ingest_website_lead(p);
    lid := nullif(res->>'lead_id', '')::uuid;
    IF lid IS NOT NULL AND res->>'status' = 'created' AND p_pipeline = 'charter' THEN
      UPDATE public.lead SET segment = 'charter', course_interest = coalesce(nullif(course_interest, ''), 'Charter') WHERE id = lid;
    END IF;
    UPDATE public.ads_meta_lead_raw SET status = 'organic', organic_lead_id = lid, fetched_at = now(), last_try_at = now(), attempts = attempts + 1,
      payload = CASE WHEN p_payload ? 'meta_answers' THEN coalesce(payload, '{}') || jsonb_build_object('answers', p_payload->'meta_answers') ELSE payload END,
      error = CASE WHEN lid IS NULL THEN left(coalesce(res->>'error', 'not accepted as a lead'), 400) END
    WHERE id = p_id;
    RETURN res || jsonb_build_object('raw_status', 'organic');
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

-- The lead id for "Send a test event": the newest Ads lead from a form, else the newest lead Meta delivered.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_test_lead() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('lead_id', l.first_touch->>'leadgen_id', 'em', crm_private.ads_sha256(lower(btrim(l.email))),
       'ph', crm_private.ads_sha256(regexp_replace(l.phone_e164, '\D', '', 'g')))
       FROM public.ads_lead l WHERE l.first_touch->>'meta_source' = 'instant_form' AND l.deleted_at IS NULL
      ORDER BY l.created_at DESC LIMIT 1),
    -- no Ads lead from a form yet: the newest lead Meta delivered (a Testing Tool lead counts), id only
    (SELECT jsonb_build_object('lead_id', r.external_id, 'em', NULL, 'ph', NULL)
       FROM public.ads_meta_lead_raw r WHERE r.source = 'instant_form' AND r.status IN ('test', 'organic', 'ingested', 'quarantined')
      ORDER BY r.received_at DESC LIMIT 1))
  || jsonb_build_object('dataset_id', (crm_private.ads_meta_set('instant_form')).dataset_id,
       'crm_name', coalesce(nullif(crm_private.ads_cfg('meta_crm_name'), ''), 'We One CRM')) $$;

-- Setup status: adds the database version and what happened to each delivered form lead.
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
    'platform', p_platform, 'schema', coalesce(nullif(crm_private.ads_cfg('ads_schema'), ''), '100')::int, 'secrets', sec, 'runs', coalesce(run, '{}'),
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
        'leads', (SELECT jsonb_build_object('received', count(*), 'ingested', count(*) FILTER (WHERE status = 'ingested'),
                    'quarantined', count(*) FILTER (WHERE status = 'quarantined'), 'test', count(*) FILTER (WHERE status = 'test'),
                    'organic', count(*) FILTER (WHERE status = 'organic'), 'organic_filed', count(*) FILTER (WHERE organic_lead_id IS NOT NULL),
                    'pending', count(*) FILTER (WHERE status = 'pending'), 'failed', count(*) FILTER (WHERE status = 'failed'),
                    'by_webhook', count(*) FILTER (WHERE via = 'webhook'),
                    'last_error', (SELECT r2.error FROM public.ads_meta_lead_raw r2 WHERE r2.source = 'instant_form' AND r2.error IS NOT NULL
                                    ORDER BY r2.last_try_at DESC NULLS LAST LIMIT 1))
                    FROM public.ads_meta_lead_raw WHERE source = 'instant_form'),
        'sources', (SELECT jsonb_object_agg(s.source, jsonb_build_object('intake', s.intake_enabled, 'report', s.report_enabled,
                      'dataset', s.dataset_id IS NOT NULL)) FROM public.ads_meta_settings s),
        'reported', (SELECT count(*) FROM public.ads_meta_capi_uploads WHERE status = 'sent')) END);
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '101')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-reconcile';
    -- every hour (minute 15): read each active form's last 48 hours, so a lost webhook never loses a lead for long
    PERFORM cron.schedule('crm-ads-meta-reconcile', '15 * * * *', $job$
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
