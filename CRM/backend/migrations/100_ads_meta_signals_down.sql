-- Rollback of 100_ads_meta_signals.sql. Removes the Meta lead intake and Meta reporting; nothing else changes.
-- Leads already filed in ads_lead stay (they are ordinary ADS leads). Vault secrets saved under the two new names stay
-- in Vault but are no longer read or shown.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-meta', 'crm-ads-meta-reconcile');
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.api_ads_setup_status(text), public.api_ads_platform_pause(text, boolean),
  public.svc_ads_meta_webhook_seen(), public.svc_ads_meta_test_lead(),
  public.api_ads_lead_board(text, text, boolean, text, integer, text);
DROP FUNCTION IF EXISTS public.api_ads_meta_settings(), public.api_ads_meta_source_save(text, jsonb),
  public.api_ads_meta_event_map_save(text, text, text, text, boolean), public.api_ads_meta_form_save(text, text, boolean),
  public.api_ads_meta_config_save(text, text),
  public.svc_ads_meta_webhook_cfg(), public.svc_ads_meta_raw_add(jsonb, text), public.svc_ads_meta_leads_work(),
  public.svc_ads_meta_lead_finish(bigint, text, jsonb, text, text), public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text),
  public.svc_ads_meta_forms_save(jsonb), public.svc_ads_meta_capi_work(), public.svc_ads_meta_capi_finish(bigint, text, text),
  crm_private.ads_meta_wake(), crm_private.ads_meta_capi_queue(), crm_private.ads_meta_consent_ok(text, text, text),
  crm_private.ads_meta_lead_source(public.ads_lead), crm_private.ads_meta_set(text), crm_private.ads_sha256(text),
  crm_private.ads_lead_platforms(public.ads_lead), crm_private.ads_platform_paused(text);

DROP TABLE IF EXISTS public.ads_meta_capi_uploads, public.ads_meta_lead_raw, public.ads_meta_forms, public.ads_meta_event_map,
  public.ads_meta_settings;
DROP FUNCTION IF EXISTS crm_private.ads_meta_event_ok(text, text);
DELETE FROM public.ads_config WHERE key IN ('meta_page_id', 'meta_waba_id', 'meta_crm_name', 'meta_webhook_last_at', 'meta_reconcile_last_at',
  'meta_webhook_verified_at', 'google_paused', 'meta_paused');

-- 076 definition
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN']
$$;

-- 076 definition
CREATE OR REPLACE FUNCTION public.svc_ads_secrets() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '{}'; nm text; v text;
BEGIN
  FOREACH nm IN ARRAY crm_private.ads_secret_names() LOOP
    SELECT d.decrypted_secret INTO v FROM vault.decrypted_secrets d WHERE d.name = 'ads_' || lower(nm);
    IF v IS NOT NULL THEN out := out || jsonb_build_object(nm, v); END IF;
    v := NULL;
  END LOOP;
  RETURN out || jsonb_build_object('GOOGLE_API_VERSION', crm_private.ads_cfg('google_api_version'),
    'META_API_VERSION', crm_private.ads_cfg('meta_api_version'), 'SYNC_DAYS', crm_private.ads_cfg('sync_days'),
    'EXECUTION_PAUSED', crm_private.ads_cfg('execution_paused'));
END $$;

-- 090 definition (the Ads Leads list without a platform)
CREATE OR REPLACE FUNCTION public.api_ads_lead_board(p_pipeline text DEFAULT 'pilot_training', p_stage text DEFAULT NULL,
  p_quarantined boolean DEFAULT false, p_search text DEFAULT NULL, p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pl text := coalesce(p_pipeline, 'pilot_training'); q text := nullif(btrim(coalesce(p_search, '')), '');
        today_start timestamptz := (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
        month_start timestamptz := (date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
BEGIN
  PERFORM crm_private.ads_require_view();
  IF pl NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT400'; END IF;
  RETURN jsonb_build_object(
    'role', crm_private.ads_role(),
    'stages', (SELECT jsonb_agg(jsonb_build_object('stage', d.stage, 'label', d.label, 'ord', d.ord, 'terminal', d.is_terminal,
                 'customer', d.is_customer, 'needs_evidence', d.needs_evidence) ORDER BY d.ord) FROM public.ads_stage_def d WHERE d.pipeline = pl),
    'stats', (SELECT jsonb_build_object(
       'new_today', count(*) FILTER (WHERE l.created_at >= today_start AND NOT l.quarantined),
       'not_contacted', count(*) FILTER (WHERE l.stage = 'lead_created' AND l.first_response_at IS NULL AND NOT l.quarantined),
       'qualified_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            WHERE x.pipeline = pl AND s.to_stage = 'qualified' AND s.at >= month_start AND x.deleted_at IS NULL),
       'customers_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            JOIN public.ads_stage_def d ON d.pipeline = x.pipeline AND d.stage = s.to_stage
                            WHERE x.pipeline = pl AND d.is_customer AND s.at >= month_start AND x.deleted_at IS NULL),
       'quarantined', count(*) FILTER (WHERE l.quarantined),
       'total', count(*) FILTER (WHERE NOT l.quarantined))
      FROM public.ads_lead l WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
       SELECT l.id, l.name, l.phone_e164, l.email, l.stage, l.contact_status, l.quarantined, l.quarantine_reasons,
              l.owner_employee_id, e.name AS owner_name, l.organic_lead_id, l.enquiry_count, l.course_interest, l.charter_details,
              l.first_touch, l.last_non_direct, l.first_response_at, l.last_interaction_at, l.created_at,
              CASE WHEN l.first_touch ?| ARRAY['gclid', 'gbraid', 'wbraid'] OR lower(coalesce(l.first_touch->>'utm_source', '')) LIKE '%google%' THEN 'Google'
                   WHEN l.first_touch ?| ARRAY['fbclid', 'fbc'] OR lower(coalesce(l.first_touch->>'utm_source', '')) ~ '(facebook|instagram|meta|fb|ig)' THEN 'Meta'
                   ELSE 'Ad' END AS source,
              coalesce(l.last_non_direct->>'utm_campaign', l.first_touch->>'utm_campaign') AS campaign
       FROM public.ads_lead l LEFT JOIN public.employee e ON e.id = l.owner_employee_id
       WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL
         AND l.quarantined = coalesce(p_quarantined, false)
         AND (p_stage IS NULL OR l.stage = p_stage)
         AND (q IS NULL OR l.name ILIKE '%' || q || '%' OR l.phone_e164 LIKE '%' || regexp_replace(q, '\D', '', 'g') || '%'
              AND regexp_replace(q, '\D', '', 'g') <> '' OR l.email ILIKE '%' || q || '%')
       ORDER BY l.created_at DESC LIMIT least(greatest(coalesce(p_limit, 100), 1), 300)) x), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.api_ads_lead_board(text,text,boolean,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text,text,boolean,text,integer) TO authenticated;
