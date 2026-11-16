-- 100: ADS only (Meta). Meta ad leads come into ADS > Ads Leads, and how far each lead gets is reported back to Meta.
--
--   Three lead sources, each switched on, off and configured in ADS > Settings > Meta (nothing is on until you turn it on):
--     instant_form  Meta lead ads (Instant Forms). Meta calls the ads-meta-webhook function ("leadgen"); ads-sync fetches the
--                   lead and files it through the normal ADS intake (same dedupe, spam checks and organic link as the website).
--                   A daily check reads each form's last 48 hours, so a lost webhook never loses a lead.
--                   Reported with the Conversions API for CRM (Conversion Leads): action_source system_generated,
--                   custom_data.event_source = crm, custom_data.lead_event_source = the CRM's name, user_data.lead_id.
--     website       Your own website's enquiries from a Meta ad click (fbclid, already captured by ads-intake).
--                   Reported as website events: action_source website, fbc, event_source_url, client_user_agent.
--     ctwa          Click-to-WhatsApp. Needs a WhatsApp Cloud API number (ctwa_clid comes from the Messages webhook referral).
--                   Reported as business messaging events: action_source business_messaging, messaging_channel whatsapp.
--   Which CRM stage is sent under which Meta event name, and the consent rule, are set per source in the dashboard.
--   Every event is sent once (lead + source + stage). Events older than 7 days are not sent (Meta discards them).
--   Contact details leave the database only as SHA-256 hashes. The emergency stop blocks all sending.
-- Re-runnable. Rollback: 100_ads_meta_signals_down.sql.

-- ------------------------------------------------------------------------------------------- settings
CREATE TABLE IF NOT EXISTS public.ads_meta_settings (
  source text PRIMARY KEY CHECK (source IN ('instant_form', 'website', 'ctwa')),
  intake_enabled boolean NOT NULL DEFAULT false,      -- website: not used (its enquiries always arrive through ads-intake)
  report_enabled boolean NOT NULL DEFAULT false,
  consent_mode text NOT NULL DEFAULT 'required' CHECK (consent_mode IN ('required', 'not_required', 'required_if_collected')),
  consent_purpose text NOT NULL DEFAULT 'ad_data_sharing' CHECK (consent_purpose IN ('ad_data_sharing', 'marketing')),
  consent_field text CHECK (consent_field ~ '^[A-Za-z0-9_.\-]{1,80}$'),   -- instant_form: the form question that holds the answer
  pipeline text NOT NULL DEFAULT 'pilot_training' CHECK (pipeline IN ('pilot_training', 'charter')),   -- default for new forms / WhatsApp
  dataset_id text CHECK (dataset_id ~ '^[0-9]{5,25}$'),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_settings FROM anon, authenticated;
INSERT INTO public.ads_meta_settings (source, consent_field) VALUES ('instant_form', 'ad_data_sharing'), ('website', NULL), ('ctwa', NULL)
ON CONFLICT (source) DO NOTHING;

-- Stage -> Meta event name, per source and pipeline. website and ctwa only accept the names below (lead events that
-- need no purchase value); instant_form (CRM) names are free text, as Meta asks.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_event_ok(p_source text, p_name text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_source
    WHEN 'instant_form' THEN coalesce(p_name ~ '^[A-Za-z0-9][A-Za-z0-9 _\-]{0,49}$', false)
    WHEN 'website' THEN coalesce(p_name = ANY (ARRAY['Lead', 'Contact', 'Schedule', 'SubmitApplication', 'CompleteRegistration']), false)
    WHEN 'ctwa' THEN coalesce(p_name = ANY (ARRAY['LeadSubmitted', 'QualifiedLead']), false)
    ELSE false END $$;

CREATE TABLE IF NOT EXISTS public.ads_meta_event_map (
  source text NOT NULL REFERENCES public.ads_meta_settings(source),
  pipeline text NOT NULL, stage text NOT NULL,
  meta_event_name text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  PRIMARY KEY (source, pipeline, stage),
  FOREIGN KEY (pipeline, stage) REFERENCES public.ads_stage_def (pipeline, stage),
  CONSTRAINT ads_meta_event_map_name_check CHECK (crm_private.ads_meta_event_ok(source, meta_event_name)));
ALTER TABLE public.ads_meta_event_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_event_map FROM anon, authenticated;

INSERT INTO public.ads_meta_event_map (source, pipeline, stage, meta_event_name, enabled)
SELECT 'instant_form', d.pipeline, d.stage, d.stage, d.stage <> 'lost' FROM public.ads_stage_def d
UNION ALL
SELECT 'website', d.pipeline, d.stage,
       CASE WHEN d.stage = 'lead_created' THEN 'Lead' WHEN d.stage = 'application_completed' THEN 'SubmitApplication'
            WHEN d.is_customer THEN 'CompleteRegistration' ELSE 'Contact' END,
       d.stage = 'lead_created' OR d.stage = 'application_completed' OR d.is_customer
  FROM public.ads_stage_def d
UNION ALL
SELECT 'ctwa', d.pipeline, d.stage, CASE WHEN d.stage = 'lead_created' THEN 'LeadSubmitted' ELSE 'QualifiedLead' END,
       d.stage IN ('lead_created', 'qualified')
  FROM public.ads_stage_def d
ON CONFLICT (source, pipeline, stage) DO NOTHING;

-- Lead forms of the Page (found by "Check Page"), with the pipeline their leads go to.
CREATE TABLE IF NOT EXISTS public.ads_meta_forms (
  form_id text PRIMARY KEY CHECK (form_id ~ '^[0-9]{5,25}$'),
  name text, status text,
  pipeline text NOT NULL DEFAULT 'pilot_training' CHECK (pipeline IN ('pilot_training', 'charter')),
  active boolean NOT NULL DEFAULT true,
  last_reconciled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_forms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_forms FROM anon, authenticated;

-- What Meta told us about, before it becomes an ADS lead. One row per lead (idempotency against repeated webhooks).
CREATE TABLE IF NOT EXISTS public.ads_meta_lead_raw (
  id bigserial PRIMARY KEY,
  source text NOT NULL CHECK (source IN ('instant_form', 'ctwa')),
  external_id text NOT NULL,                      -- leadgen_id, or the ctwa_clid
  page_id text, form_id text, ad_id text, adgroup_id text, created_time timestamptz,
  payload jsonb NOT NULL DEFAULT '{}',             -- ctwa: name / phone / WABA from the message; instant_form: ids only
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ingested', 'failed', 'quarantined', 'organic')),
  attempts int NOT NULL DEFAULT 0, last_try_at timestamptz, error text, fetched_at timestamptz,
  lead_id uuid REFERENCES public.ads_lead(id) ON DELETE SET NULL,
  via text NOT NULL DEFAULT 'webhook' CHECK (via IN ('webhook', 'reconcile')),
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_id));
CREATE INDEX IF NOT EXISTS idx_ads_meta_raw_status ON public.ads_meta_lead_raw (status, last_try_at);
ALTER TABLE public.ads_meta_lead_raw ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_lead_raw FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_lead_raw_id_seq FROM anon, authenticated;

-- Report queue. No contact details are stored here.
CREATE TABLE IF NOT EXISTS public.ads_meta_capi_uploads (
  id bigserial PRIMARY KEY,
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  source text NOT NULL CHECK (source IN ('instant_form', 'website', 'ctwa')),
  stage text NOT NULL, meta_event_name text NOT NULL,
  event_id text NOT NULL,
  account_id uuid REFERENCES public.ads_accounts(id) ON DELETE SET NULL,
  happened_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
  attempts int NOT NULL DEFAULT 0, last_try_at timestamptz, error text, sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lead_id, source, stage));
CREATE INDEX IF NOT EXISTS idx_ads_meta_capi_status ON public.ads_meta_capi_uploads (status, last_try_at);
ALTER TABLE public.ads_meta_capi_uploads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_capi_uploads FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_capi_uploads_id_seq FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES
  ('meta_page_id', ''),                -- the Facebook Page whose lead forms are read
  ('meta_waba_id', ''),                -- WhatsApp Business Account id (ctwa)
  ('meta_crm_name', 'We One CRM'),     -- lead_event_source: the name of the tool the leads are managed in
  ('meta_webhook_last_at', ''),
  ('meta_reconcile_last_at', ''),
  ('meta_webhook_verified_at', ''),    -- when Meta last checked the callback URL (the verify-token handshake)
  ('google_paused', 'false'),          -- per-platform stops; execution_paused stays the stop for everything
  ('meta_paused', 'false')
ON CONFLICT (key) DO NOTHING;

-- Google Ads and Meta Ads are separate sections, each with its own stop. execution_paused stops both.
CREATE OR REPLACE FUNCTION crm_private.ads_platform_paused(p_platform text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(crm_private.ads_cfg('execution_paused'), 'false') = 'true'
      OR coalesce(crm_private.ads_cfg(p_platform || '_paused'), 'false') = 'true' $$;

-- Two more Vault secrets: the webhook verify token, and (optional) a long-lived Page token for reading leads.
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN',
               'META_WEBHOOK_VERIFY_TOKEN','META_PAGE_TOKEN']
$$;

-- ------------------------------------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION crm_private.ads_meta_set(p_source text) RETURNS public.ads_meta_settings
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT s FROM public.ads_meta_settings s WHERE s.source = p_source $$;

CREATE OR REPLACE FUNCTION crm_private.ads_sha256(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN nullif(p, '') IS NULL THEN NULL ELSE encode(sha256(convert_to(p, 'UTF8')), 'hex') END $$;

-- Which Meta source a lead belongs to, and the touch that proves it. NULL = not a Meta lead we can report.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_lead_source(l public.ads_lead) RETURNS TABLE (source text, touch jsonb)
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT CASE WHEN l.first_touch->>'meta_source' = 'instant_form' AND l.first_touch->>'leadgen_id' ~ '^[0-9]{5,25}$' THEN 'instant_form'
              WHEN l.first_touch->>'meta_source' = 'ctwa' AND nullif(l.first_touch->>'ctwa_clid', '') IS NOT NULL THEN 'ctwa'
              WHEN t.t IS NOT NULL THEN 'website' END,
         CASE WHEN l.first_touch ? 'meta_source' THEN l.first_touch ELSE t.t END
    FROM (SELECT CASE WHEN l.first_touch ?| ARRAY['fbclid', 'fbc'] AND NOT l.first_touch ? 'meta_source' THEN l.first_touch
                      WHEN l.last_non_direct ?| ARRAY['fbclid', 'fbc'] THEN l.last_non_direct
                      WHEN l.last_touch ?| ARRAY['fbclid', 'fbc'] THEN l.last_touch END AS t) t $$;

-- Consent per the source's rule; the latest answer for that person wins.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_consent_ok(p_mode text, p_purpose text, p_phone text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE p_mode
    WHEN 'not_required' THEN true
    WHEN 'required' THEN (SELECT ce.status FROM public.ads_consent_event ce WHERE ce.purpose = p_purpose AND ce.subject_phone = p_phone
                           ORDER BY ce.at DESC, ce.id DESC LIMIT 1) IS NOT DISTINCT FROM 'granted'
    WHEN 'required_if_collected' THEN coalesce((SELECT ce.status FROM public.ads_consent_event ce WHERE ce.purpose = p_purpose AND ce.subject_phone = p_phone
                           ORDER BY ce.at DESC, ce.id DESC LIMIT 1), 'granted') = 'granted'
    ELSE false END $$;

-- ------------------------------------------------------------------------------------------- intake: webhook -> raw rows
-- What the webhook function needs (service role): its two secrets and which sources accept leads.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_webhook_cfg() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'app_secret', (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.name = 'ads_meta_app_secret'),
    'verify_token', (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.name = 'ads_meta_webhook_verify_token'),
    'intake', jsonb_build_object('instant_form', (crm_private.ads_meta_set('instant_form')).intake_enabled,
                                 'ctwa', (crm_private.ads_meta_set('ctwa')).intake_enabled)) $$;

-- Adds what Meta reported. Unknown, malformed or switched-off sources are ignored. Returns how many rows are new.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_raw_add(p_items jsonb, p_via text DEFAULT 'webhook') RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := 0; x jsonb; ok boolean; ts timestamptz;
BEGIN
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RETURN 0; END IF;
  IF p_via = 'webhook' THEN
    INSERT INTO public.ads_config (key, value) VALUES ('meta_webhook_last_at', now()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    CONTINUE WHEN jsonb_typeof(x) IS DISTINCT FROM 'object' OR coalesce(x->>'source', '') NOT IN ('instant_form', 'ctwa');
    CONTINUE WHEN NOT coalesce((crm_private.ads_meta_set(x->>'source')).intake_enabled, false);
    ok := CASE x->>'source' WHEN 'instant_form' THEN coalesce(x->>'external_id' ~ '^[0-9]{5,25}$', false)
                            ELSE coalesce(x->>'external_id' ~ '^[A-Za-z0-9_\-.]{8,255}$', false) END;
    CONTINUE WHEN NOT ok;
    BEGIN ts := CASE WHEN x->>'created_time' ~ '^[0-9]{9,11}$' THEN to_timestamp((x->>'created_time')::bigint)
                     ELSE (x->>'created_time')::timestamptz END;
    EXCEPTION WHEN others THEN ts := NULL; END;
    INSERT INTO public.ads_meta_lead_raw (source, external_id, page_id, form_id, ad_id, adgroup_id, created_time, payload, via)
    VALUES (x->>'source', x->>'external_id',
      substring(x->>'page_id' FROM '^[0-9]{5,25}$'), substring(x->>'form_id' FROM '^[0-9]{5,25}$'),
      substring(x->>'ad_id' FROM '^[0-9]{5,25}$'), substring(x->>'adgroup_id' FROM '^[0-9]{5,25}$'), ts,
      CASE WHEN x->>'source' = 'ctwa' AND jsonb_typeof(x->'payload') = 'object' THEN jsonb_strip_nulls(jsonb_build_object(
        'name', left(x->'payload'->>'name', 120), 'phone', left(x->'payload'->>'phone', 30), 'waba_id', substring(x->'payload'->>'waba_id' FROM '^[0-9]{5,25}$'),
        'source_url', left(x->'payload'->>'source_url', 500), 'headline', left(x->'payload'->>'headline', 200))) ELSE '{}' END,
      CASE WHEN p_via = 'reconcile' THEN 'reconcile' ELSE 'webhook' END)
    ON CONFLICT (source, external_id) DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- Rows to turn into leads now: pending, or failed less than 12 times and not tried in the last 15 minutes.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_leads_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'consent_field', (crm_private.ads_meta_set('instant_form')).consent_field,
    'consent_purpose', (crm_private.ads_meta_set('instant_form')).consent_purpose,
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'source', r.source, 'external_id', r.external_id,
                'form_id', r.form_id, 'ad_id', r.ad_id, 'adgroup_id', r.adgroup_id, 'created_time', r.created_time, 'payload', r.payload,
                'pipeline', coalesce((SELECT f.pipeline FROM public.ads_meta_forms f WHERE f.form_id = r.form_id),
                                     (crm_private.ads_meta_set(r.source)).pipeline)) ORDER BY r.id), '[]')
                FROM (SELECT * FROM public.ads_meta_lead_raw w
                       WHERE w.status = 'pending' AND (w.last_try_at IS NULL OR w.last_try_at < now() - interval '15 minutes')
                       ORDER BY w.id LIMIT 100) r)) $$;

-- Files one Meta lead through the normal ADS intake. p_payload is built by ads-sync from what Meta returned.
-- p_status: 'fetched' (ingest it), 'organic' (a form filled without an ad: not an ADS lead), 'retry' / 'failed'.
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

-- Daily check of every active form: which forms, and since when (48 hours, at least back to the last check).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconcile_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'enabled', (crm_private.ads_meta_set('instant_form')).intake_enabled,
    'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('form_id', f.form_id,
                'since', floor(extract(epoch FROM least(now() - interval '48 hours', coalesce(f.last_reconciled_at - interval '1 hour', now() - interval '48 hours')))))
                ORDER BY f.form_id), '[]') FROM public.ads_meta_forms f WHERE f.active)) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconciled(p_form text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_forms SET last_reconciled_at = now() WHERE form_id = p_form;
  INSERT INTO public.ads_config (key, value) VALUES ('meta_reconcile_last_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
$$;

-- Forms found on the Page. New forms get the instant_form default pipeline; existing ones keep the owner's choices.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_forms_save(p_forms jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x jsonb; n int := 0;
BEGIN
  IF jsonb_typeof(p_forms) IS DISTINCT FROM 'array' THEN RETURN 0; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_forms) LOOP
    CONTINUE WHEN coalesce(x->>'id', '') !~ '^[0-9]{5,25}$';
    INSERT INTO public.ads_meta_forms (form_id, name, status, pipeline, active)
    VALUES (x->>'id', left(x->>'name', 200), left(x->>'status', 30), (crm_private.ads_meta_set('instant_form')).pipeline,
            coalesce(x->>'status', 'ACTIVE') = 'ACTIVE')
    ON CONFLICT (form_id) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status, updated_at = now();
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- ------------------------------------------------------------------------------------------- reporting to Meta
-- Queues what is ready and returns how many reports are due now.
-- Queued: a Meta lead (by source) whose source reports, for every mapped and enabled stage it has reached; not quarantined,
-- deleted or anonymised; at least 30 minutes old (spam checks first); consent per the source's rule.
-- Skipped (shown, never sent): a stage reached more than 7 days ago, or a website lead without browser details.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_capi_queue() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF crm_private.ads_platform_paused('meta') THEN RETURN 0; END IF;
  INSERT INTO public.ads_meta_capi_uploads (lead_id, source, stage, meta_event_name, event_id, account_id, happened_at, status, error)
  SELECT l.id, ms.source, m.stage, m.meta_event_name, l.id::text || ':' || m.stage,
         (SELECT x.account_id FROM crm_private.ads_ad_leads() x WHERE x.lead_id = l.id LIMIT 1),
         greatest(ev.at, l.created_at),
         CASE WHEN ev.at < now() - interval '7 days' THEN 'skipped'
              WHEN ms.source = 'website' AND ua.v IS NULL THEN 'skipped' ELSE 'pending' END,
         CASE WHEN ev.at < now() - interval '7 days' THEN 'Reached this stage more than 7 days ago; Meta does not accept events that old.'
              WHEN ms.source = 'website' AND ua.v IS NULL THEN 'No browser details were recorded with this enquiry (needed for website events).' END
    FROM public.ads_lead l
    CROSS JOIN LATERAL crm_private.ads_meta_lead_source(l) src
    JOIN public.ads_meta_settings ms ON ms.source = src.source AND ms.report_enabled
    JOIN public.ads_meta_event_map m ON m.source = ms.source AND m.pipeline = l.pipeline AND m.enabled
    CROSS JOIN LATERAL (SELECT min(se.at) AS at FROM public.ads_lead_stage_event se WHERE se.lead_id = l.id AND se.to_stage = m.stage) ev
    LEFT JOIN LATERAL (SELECT e.payload_extra->>'client_user_agent' AS v FROM public.ads_enquiry e
                        WHERE e.ads_lead_id = l.id AND nullif(e.payload_extra->>'client_user_agent', '') IS NOT NULL
                        ORDER BY e.received_at LIMIT 1) ua ON true
   WHERE ev.at IS NOT NULL
     AND l.deleted_at IS NULL AND l.anonymised_at IS NULL AND NOT l.quarantined AND l.contact_status <> 'wrong_number'
     AND l.created_at < now() - interval '30 minutes'
     AND crm_private.ads_meta_consent_ok(ms.consent_mode, ms.consent_purpose, l.phone_e164)
     AND (ms.source <> 'ctwa' OR nullif(crm_private.ads_cfg('meta_waba_id'), '') IS NOT NULL OR src.touch ? 'waba_id')
  ON CONFLICT (lead_id, source, stage) DO NOTHING;
  RETURN (SELECT count(*) FROM public.ads_meta_capi_uploads u WHERE u.status = 'pending'
            AND (u.last_try_at IS NULL OR u.last_try_at < now() - interval '1 hour'));
END $$;

-- What the reporter sends now. Contact details are SHA-256 hashed here (normalised as Meta asks); the raw values never leave.
-- A lead that was deleted, quarantined, anonymised or whose consent was withdrawn since it was queued is not sent.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_capi_work() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF crm_private.ads_platform_paused('meta') THEN
    RETURN jsonb_build_object('paused', true, 'datasets', '{}'::jsonb, 'items', '[]'::jsonb);
  END IF;
  PERFORM crm_private.ads_meta_capi_queue();
  RETURN jsonb_build_object(
    'crm_name', coalesce(nullif(crm_private.ads_cfg('meta_crm_name'), ''), 'We One CRM'),
    'datasets', (SELECT coalesce(jsonb_object_agg(s.source, s.dataset_id), '{}') FROM public.ads_meta_settings s WHERE s.dataset_id IS NOT NULL),
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', u.id, 'source', u.source, 'event_name', u.meta_event_name, 'event_id', u.event_id,
        'event_time', floor(extract(epoch FROM u.happened_at))::bigint,
        'lead_id', CASE WHEN u.source = 'instant_form' THEN src.touch->>'leadgen_id' END,
        'ctwa_clid', CASE WHEN u.source = 'ctwa' THEN src.touch->>'ctwa_clid' END,
        'waba_id', CASE WHEN u.source = 'ctwa' THEN coalesce(src.touch->>'waba_id', nullif(crm_private.ads_cfg('meta_waba_id'), '')) END,
        'fbc', CASE WHEN u.source = 'website' THEN CASE WHEN src.touch->>'fbc' ~ '^fb\.[0-9]\.[0-9]{10,13}\.' THEN src.touch->>'fbc'
                 WHEN nullif(src.touch->>'fbclid', '') IS NOT NULL THEN 'fb.1.' ||
                   floor(extract(epoch FROM coalesce((CASE WHEN src.touch->>'at' ~ '^\d{4}-\d\d-\d\dT' THEN (src.touch->>'at')::timestamptz END), l.created_at)) * 1000)::bigint
                   || '.' || (src.touch->>'fbclid') END END,
        'event_source_url', CASE WHEN u.source = 'website' THEN coalesce(src.touch->>'page_url', src.touch->>'landing_page') END,
        'client_user_agent', CASE WHEN u.source = 'website' THEN (SELECT e.payload_extra->>'client_user_agent' FROM public.ads_enquiry e
                               WHERE e.ads_lead_id = l.id AND nullif(e.payload_extra->>'client_user_agent', '') IS NOT NULL ORDER BY e.received_at LIMIT 1) END,
        'em', crm_private.ads_sha256(lower(btrim(l.email))),
        'ph', crm_private.ads_sha256(regexp_replace(l.phone_e164, '\D', '', 'g'))) ORDER BY u.id), '[]')
      FROM (SELECT * FROM public.ads_meta_capi_uploads w WHERE w.status = 'pending'
              AND (w.last_try_at IS NULL OR w.last_try_at < now() - interval '1 hour') ORDER BY w.id LIMIT 200) u
      JOIN public.ads_lead l ON l.id = u.lead_id
      JOIN public.ads_meta_settings ms ON ms.source = u.source
      CROSS JOIN LATERAL crm_private.ads_meta_lead_source(l) src
     WHERE ms.report_enabled AND src.source = u.source
       AND l.deleted_at IS NULL AND l.anonymised_at IS NULL AND NOT l.quarantined
       AND crm_private.ads_meta_consent_ok(ms.consent_mode, ms.consent_purpose, l.phone_e164)));
END $$;

-- sent = Meta has it; retry = again in an hour (12 tries at most); failed = final (Meta refused it).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_capi_finish(p_id bigint, p_status text, p_error text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_capi_uploads SET
    attempts = attempts + 1, last_try_at = now(),
    status = CASE WHEN p_status = 'sent' THEN 'sent' WHEN p_status = 'retry' AND attempts + 1 < 12 THEN 'pending' ELSE 'failed' END,
    sent_at = CASE WHEN p_status = 'sent' THEN now() END,
    error = CASE WHEN p_status = 'sent' THEN NULL ELSE left(coalesce(p_error, 'not accepted'), 400) END
   WHERE id = p_id AND status = 'pending'
$$;

-- True when the Meta jobs have something to do (the scheduler only wakes the Edge Function then).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_wake() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ads_meta_lead_raw r WHERE r.status = 'pending'
              AND (r.last_try_at IS NULL OR r.last_try_at < now() - interval '15 minutes')) THEN RETURN true; END IF;
  IF crm_private.ads_platform_paused('meta') OR NOT EXISTS (SELECT 1 FROM public.ads_meta_settings WHERE report_enabled) THEN RETURN false; END IF;
  RETURN crm_private.ads_meta_capi_queue() > 0;
END $$;

-- ------------------------------------------------------------------------------------------- dashboard (Admin)
CREATE OR REPLACE FUNCTION public.api_ads_meta_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  RETURN jsonb_build_object(
    'config', jsonb_build_object('page_id', crm_private.ads_cfg('meta_page_id'), 'waba_id', crm_private.ads_cfg('meta_waba_id'),
      'crm_name', crm_private.ads_cfg('meta_crm_name'), 'webhook_last_at', nullif(crm_private.ads_cfg('meta_webhook_last_at'), ''),
      'reconcile_last_at', nullif(crm_private.ads_cfg('meta_reconcile_last_at'), ''), 'api_version', crm_private.ads_cfg('meta_api_version'),
      'execution_paused', crm_private.ads_platform_paused('meta'),
      'webhook_verified_at', nullif(crm_private.ads_cfg('meta_webhook_verified_at'), '')),
    'secrets', (SELECT jsonb_object_agg(n, EXISTS (SELECT 1 FROM vault.secrets v WHERE v.name = 'ads_' || lower(n)))
                  FROM unnest(ARRAY['META_ACCESS_TOKEN', 'META_APP_SECRET', 'META_WEBHOOK_VERIFY_TOKEN', 'META_PAGE_TOKEN']) n),
    'meta_test', (SELECT jsonb_build_object('status', r.status, 'detail', r.detail, 'at', r.finished_at) FROM public.ads_sync_runs r
                   WHERE r.job = 'test_meta' ORDER BY r.started_at DESC LIMIT 1),
    'page_check', (SELECT jsonb_build_object('status', r.status, 'detail', r.detail, 'at', r.finished_at) FROM public.ads_sync_runs r
                   WHERE r.job = 'meta_page' ORDER BY r.started_at DESC LIMIT 1),
    'meta_accounts', (SELECT count(*) FROM public.ads_accounts a WHERE a.platform = 'meta'),
    'sources', (SELECT jsonb_agg(jsonb_build_object('source', s.source, 'intake_enabled', s.intake_enabled, 'report_enabled', s.report_enabled,
        'consent_mode', s.consent_mode, 'consent_purpose', s.consent_purpose, 'consent_field', s.consent_field, 'pipeline', s.pipeline,
        'dataset_id', s.dataset_id, 'updated_at', s.updated_at,
        'leads', (SELECT jsonb_build_object('received', count(*), 'ingested', count(*) FILTER (WHERE r.status = 'ingested'),
                    'pending', count(*) FILTER (WHERE r.status = 'pending'), 'failed', count(*) FILTER (WHERE r.status = 'failed'),
                    'quarantined', count(*) FILTER (WHERE r.status = 'quarantined'), 'organic', count(*) FILTER (WHERE r.status = 'organic'),
                    'last_error', (SELECT r2.error FROM public.ads_meta_lead_raw r2 WHERE r2.source = s.source AND r2.error IS NOT NULL ORDER BY r2.last_try_at DESC LIMIT 1))
                    FROM public.ads_meta_lead_raw r WHERE r.source = s.source),
        'reports', (SELECT jsonb_build_object('sent', count(*) FILTER (WHERE u.status = 'sent'), 'pending', count(*) FILTER (WHERE u.status = 'pending'),
                    'failed', count(*) FILTER (WHERE u.status = 'failed'), 'skipped', count(*) FILTER (WHERE u.status = 'skipped'),
                    'last_sent_at', max(u.sent_at),
                    'last_error', (SELECT u2.error FROM public.ads_meta_capi_uploads u2 WHERE u2.source = s.source AND u2.status = 'failed' ORDER BY u2.last_try_at DESC LIMIT 1))
                    FROM public.ads_meta_capi_uploads u WHERE u.source = s.source)) ORDER BY array_position(ARRAY['instant_form', 'website', 'ctwa'], s.source))
                  FROM public.ads_meta_settings s),
    'event_map', (SELECT jsonb_agg(jsonb_build_object('source', m.source, 'pipeline', m.pipeline, 'stage', m.stage, 'label', d.label,
                    'meta_event_name', m.meta_event_name, 'enabled', m.enabled) ORDER BY m.source, m.pipeline, d.ord)
                  FROM public.ads_meta_event_map m JOIN public.ads_stage_def d ON d.pipeline = m.pipeline AND d.stage = m.stage),
    'event_names', jsonb_build_object('website', jsonb_build_array('Lead', 'Contact', 'Schedule', 'SubmitApplication', 'CompleteRegistration'),
                                      'ctwa', jsonb_build_array('LeadSubmitted', 'QualifiedLead')),
    'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('form_id', f.form_id, 'name', f.name, 'status', f.status, 'pipeline', f.pipeline,
                'active', f.active, 'last_reconciled_at', f.last_reconciled_at) ORDER BY f.name NULLS LAST), '[]') FROM public.ads_meta_forms f));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_source_save(p_source text, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_settings; d text; f text;
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_settings WHERE source = p_source;
  IF s.source IS NULL THEN RAISE EXCEPTION 'Unknown lead source' USING ERRCODE = 'PT404'; END IF;
  IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save' USING ERRCODE = 'PT422'; END IF;
  IF p_data ? 'intake_enabled' AND jsonb_typeof(p_data->'intake_enabled') <> 'boolean' THEN RAISE EXCEPTION 'On or off' USING ERRCODE = 'PT422'; END IF;
  IF p_data ? 'report_enabled' AND jsonb_typeof(p_data->'report_enabled') <> 'boolean' THEN RAISE EXCEPTION 'On or off' USING ERRCODE = 'PT422'; END IF;
  IF p_data ? 'consent_mode' AND p_data->>'consent_mode' NOT IN ('required', 'not_required', 'required_if_collected') THEN
    RAISE EXCEPTION 'Consent rule is one of: required, not required, required if collected' USING ERRCODE = 'PT422'; END IF;
  IF p_data ? 'consent_purpose' AND p_data->>'consent_purpose' NOT IN ('ad_data_sharing', 'marketing') THEN
    RAISE EXCEPTION 'Consent purpose is ad data sharing or marketing' USING ERRCODE = 'PT422'; END IF;
  IF p_data ? 'pipeline' AND p_data->>'pipeline' NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT422'; END IF;
  d := CASE WHEN p_data ? 'dataset_id' THEN nullif(btrim(p_data->>'dataset_id'), '') ELSE s.dataset_id END;
  IF d IS NOT NULL AND d !~ '^[0-9]{5,25}$' THEN RAISE EXCEPTION 'Dataset ID is digits only (Events Manager > Data sources)' USING ERRCODE = 'PT422'; END IF;
  f := CASE WHEN p_data ? 'consent_field' THEN nullif(btrim(p_data->>'consent_field'), '') ELSE s.consent_field END;
  IF f IS NOT NULL AND f !~ '^[A-Za-z0-9_.\-]{1,80}$' THEN RAISE EXCEPTION 'Form question key: letters, digits, _ . - only' USING ERRCODE = 'PT422'; END IF;
  IF coalesce((p_data->>'report_enabled')::boolean, s.report_enabled) AND d IS NULL THEN
    RAISE EXCEPTION 'Add the dataset ID before switching reporting on' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.ads_meta_settings SET
    intake_enabled = coalesce((p_data->>'intake_enabled')::boolean, intake_enabled),
    report_enabled = coalesce((p_data->>'report_enabled')::boolean, report_enabled),
    consent_mode = coalesce(p_data->>'consent_mode', consent_mode),
    consent_purpose = coalesce(p_data->>'consent_purpose', consent_purpose),
    consent_field = f, dataset_id = d,
    pipeline = coalesce(p_data->>'pipeline', pipeline),
    updated_by = crm_private.current_employee_id(), updated_at = now()
   WHERE source = p_source;
  PERFORM crm_private.ads_log('meta_source_saved', 'meta_source', p_source, p_data);
  RETURN jsonb_build_object('saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_event_map_save(p_source text, p_pipeline text, p_stage text, p_event text, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e text := btrim(coalesce(p_event, ''));
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF NOT EXISTS (SELECT 1 FROM public.ads_meta_event_map WHERE source = p_source AND pipeline = p_pipeline AND stage = p_stage) THEN
    RAISE EXCEPTION 'Unknown stage' USING ERRCODE = 'PT404'; END IF;
  IF NOT crm_private.ads_meta_event_ok(p_source, e) THEN
    RAISE EXCEPTION '%', CASE p_source WHEN 'website' THEN 'Website events: Lead, Contact, Schedule, SubmitApplication or CompleteRegistration'
      WHEN 'ctwa' THEN 'WhatsApp events: LeadSubmitted or QualifiedLead'
      ELSE 'Event name: letters, digits, spaces, _ or -, up to 50' END USING ERRCODE = 'PT422';
  END IF;
  UPDATE public.ads_meta_event_map SET meta_event_name = e, enabled = coalesce(p_enabled, enabled)
   WHERE source = p_source AND pipeline = p_pipeline AND stage = p_stage;
  PERFORM crm_private.ads_log('meta_event_map_saved', 'meta_event_map', p_source || ':' || p_pipeline || ':' || p_stage,
    jsonb_build_object('event', e, 'enabled', p_enabled));
  RETURN jsonb_build_object('saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_form_save(p_form text, p_pipeline text, p_active boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_pipeline NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.ads_meta_forms SET pipeline = p_pipeline, active = coalesce(p_active, active), updated_at = now() WHERE form_id = p_form;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown form' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('meta_form_saved', 'meta_form', p_form, jsonb_build_object('pipeline', p_pipeline, 'active', p_active));
  RETURN jsonb_build_object('saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_config_save(p_key text, p_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text := btrim(coalesce(p_value, ''));
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_key NOT IN ('meta_page_id', 'meta_waba_id', 'meta_crm_name') THEN RAISE EXCEPTION 'Unknown setting' USING ERRCODE = 'PT404'; END IF;
  IF p_key IN ('meta_page_id', 'meta_waba_id') AND v <> '' AND v !~ '^[0-9]{5,25}$' THEN RAISE EXCEPTION 'Digits only' USING ERRCODE = 'PT422'; END IF;
  IF p_key = 'meta_crm_name' AND v !~ '^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,59}$' THEN RAISE EXCEPTION 'Name: letters, digits, spaces, up to 60' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_config (key, value) VALUES (p_key, v) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('config_saved', 'config', p_key, jsonb_build_object('value', v));
  RETURN jsonb_build_object('saved', true);
END $$;

-- ------------------------------------------------------------------------------------------- two sections: Google Ads and Meta Ads
-- Which ad platforms brought this person (any of their touches). A person who came through both is in both lists.
CREATE OR REPLACE FUNCTION crm_private.ads_lead_platforms(l public.ads_lead) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT p ORDER BY p), '{}') FROM (
    SELECT CASE WHEN t ? 'meta_source' THEN 'meta' ELSE crm_private.ads_touch_platform(t) END AS p
      FROM unnest(ARRAY[l.first_touch, l.last_non_direct, l.last_touch]) t) x
   WHERE p IS NOT NULL $$;

-- The Ads Leads list (090) with an optional platform: 'google' or 'meta'. Without it, as before.
DROP FUNCTION IF EXISTS public.api_ads_lead_board(text, text, boolean, text, integer);
CREATE OR REPLACE FUNCTION public.api_ads_lead_board(p_pipeline text DEFAULT 'pilot_training', p_stage text DEFAULT NULL,
  p_quarantined boolean DEFAULT false, p_search text DEFAULT NULL, p_limit int DEFAULT 100, p_platform text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pl text := coalesce(p_pipeline, 'pilot_training'); q text := nullif(btrim(coalesce(p_search, '')), '');
        today_start timestamptz := (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
        month_start timestamptz := (date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
BEGIN
  PERFORM crm_private.ads_require_view();
  IF pl NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT400'; END IF;
  IF p_platform IS NOT NULL AND p_platform NOT IN ('google', 'meta') THEN RAISE EXCEPTION 'Unknown platform' USING ERRCODE = 'PT400'; END IF;
  RETURN jsonb_build_object(
    'role', crm_private.ads_role(),
    'stages', (SELECT jsonb_agg(jsonb_build_object('stage', d.stage, 'label', d.label, 'ord', d.ord, 'terminal', d.is_terminal,
                 'customer', d.is_customer, 'needs_evidence', d.needs_evidence) ORDER BY d.ord) FROM public.ads_stage_def d WHERE d.pipeline = pl),
    'stats', (SELECT jsonb_build_object(
       'new_today', count(*) FILTER (WHERE l.created_at >= today_start AND NOT l.quarantined),
       'not_contacted', count(*) FILTER (WHERE l.stage = 'lead_created' AND l.first_response_at IS NULL AND NOT l.quarantined),
       'qualified_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            WHERE x.pipeline = pl AND s.to_stage = 'qualified' AND s.at >= month_start AND x.deleted_at IS NULL
                              AND (p_platform IS NULL OR p_platform = ANY (crm_private.ads_lead_platforms(x)))),
       'customers_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            JOIN public.ads_stage_def d ON d.pipeline = x.pipeline AND d.stage = s.to_stage
                            WHERE x.pipeline = pl AND d.is_customer AND s.at >= month_start AND x.deleted_at IS NULL
                              AND (p_platform IS NULL OR p_platform = ANY (crm_private.ads_lead_platforms(x)))),
       'quarantined', count(*) FILTER (WHERE l.quarantined),
       'total', count(*) FILTER (WHERE NOT l.quarantined))
      FROM public.ads_lead l WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL AND (p_platform IS NULL OR p_platform = ANY (crm_private.ads_lead_platforms(l)))),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
       SELECT l.id, l.name, l.phone_e164, l.email, l.stage, l.contact_status, l.quarantined, l.quarantine_reasons,
              l.owner_employee_id, e.name AS owner_name, l.organic_lead_id, l.enquiry_count, l.course_interest, l.charter_details,
              l.first_touch, l.last_non_direct, l.first_response_at, l.last_interaction_at, l.created_at,
              CASE WHEN l.first_touch ?| ARRAY['gclid', 'gbraid', 'wbraid'] OR lower(coalesce(l.first_touch->>'utm_source', '')) LIKE '%google%' THEN 'Google'
                   WHEN l.first_touch ?| ARRAY['fbclid', 'fbc'] OR lower(coalesce(l.first_touch->>'utm_source', '')) ~ '(facebook|instagram|meta|fb|ig)' THEN 'Meta'
                   ELSE 'Ad' END AS source,
              coalesce(l.last_non_direct->>'utm_campaign', l.first_touch->>'utm_campaign') AS campaign,
              crm_private.ads_lead_platforms(l) AS platforms
       FROM public.ads_lead l LEFT JOIN public.employee e ON e.id = l.owner_employee_id
       WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL AND (p_platform IS NULL OR p_platform = ANY (crm_private.ads_lead_platforms(l)))
         AND l.quarantined = coalesce(p_quarantined, false)
         AND (p_stage IS NULL OR l.stage = p_stage)
         AND (q IS NULL OR l.name ILIKE '%' || q || '%' OR l.phone_e164 LIKE '%' || regexp_replace(q, '\D', '', 'g') || '%'
              AND regexp_replace(q, '\D', '', 'g') <> '' OR l.email ILIKE '%' || q || '%')
       ORDER BY l.created_at DESC LIMIT least(greatest(coalesce(p_limit, 100), 1), 300)) x), '[]'::jsonb));
END $$;

-- Stop one platform (Google or Meta) without stopping the other. The emergency stop (execution_paused) still stops both.
CREATE OR REPLACE FUNCTION public.api_ads_platform_pause(p_platform text, p_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_platform NOT IN ('google', 'meta') OR p_on IS NULL THEN RAISE EXCEPTION 'Unknown platform' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_config (key, value) VALUES (p_platform || '_paused', CASE WHEN p_on THEN 'true' ELSE 'false' END)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log(p_platform || '_stop_' || CASE WHEN p_on THEN 'on' ELSE 'off' END, 'config', p_platform || '_paused', '{}');
  RETURN jsonb_build_object('saved', true);
END $$;

-- 076 definition plus the two platform stops, so ads-sync can honour them.
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
    'EXECUTION_PAUSED', crm_private.ads_cfg('execution_paused'),
    'GOOGLE_PAUSED', CASE WHEN crm_private.ads_platform_paused('google') THEN 'true' ELSE 'false' END,
    'META_PAUSED', CASE WHEN crm_private.ads_platform_paused('meta') THEN 'true' ELSE 'false' END);
END $$;

-- The webhook function records Meta's verify-token handshake (the callback URL was saved in the App Dashboard).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_webhook_seen() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value) VALUES ('meta_webhook_verified_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

-- Everything the Setup checklist needs for one platform, in one call (Admin). Never returns secret values.
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

-- The newest Meta lead-form lead, for "Send test event" (a test event must carry a real lead id).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_test_lead() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('lead_id', l.first_touch->>'leadgen_id', 'em', crm_private.ads_sha256(lower(btrim(l.email))),
    'ph', crm_private.ads_sha256(regexp_replace(l.phone_e164, '\D', '', 'g')),
    'dataset_id', (crm_private.ads_meta_set('instant_form')).dataset_id, 'crm_name', coalesce(nullif(crm_private.ads_cfg('meta_crm_name'), ''), 'We One CRM'))
    FROM public.ads_lead l WHERE l.first_touch->>'meta_source' = 'instant_form' AND l.deleted_at IS NULL
   ORDER BY l.created_at DESC LIMIT 1 $$;

-- ------------------------------------------------------------------------------------------- permissions and schedule
REVOKE ALL ON FUNCTION public.svc_ads_meta_webhook_cfg(), public.svc_ads_meta_raw_add(jsonb, text), public.svc_ads_meta_leads_work(),
  public.svc_ads_meta_lead_finish(bigint, text, jsonb, text, text), public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text),
  public.svc_ads_meta_forms_save(jsonb), public.svc_ads_meta_capi_work(), public.svc_ads_meta_capi_finish(bigint, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_webhook_cfg(), public.svc_ads_meta_raw_add(jsonb, text), public.svc_ads_meta_leads_work(),
  public.svc_ads_meta_lead_finish(bigint, text, jsonb, text, text), public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text),
  public.svc_ads_meta_forms_save(jsonb), public.svc_ads_meta_capi_work(), public.svc_ads_meta_capi_finish(bigint, text, text) TO service_role;
REVOKE ALL ON FUNCTION crm_private.ads_meta_set(text), crm_private.ads_meta_lead_source(public.ads_lead),
  crm_private.ads_meta_consent_ok(text, text, text), crm_private.ads_meta_capi_queue(), crm_private.ads_meta_wake()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.svc_ads_meta_webhook_seen(), public.svc_ads_meta_test_lead() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_webhook_seen(), public.svc_ads_meta_test_lead() TO service_role;
REVOKE ALL ON FUNCTION crm_private.ads_platform_paused(text), crm_private.ads_lead_platforms(public.ads_lead) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text), public.api_ads_platform_pause(text, boolean),
  public.api_ads_setup_status(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text), public.api_ads_platform_pause(text, boolean),
  public.api_ads_setup_status(text) TO authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_settings(), public.api_ads_meta_source_save(text, jsonb),
  public.api_ads_meta_event_map_save(text, text, text, text, boolean), public.api_ads_meta_form_save(text, text, boolean),
  public.api_ads_meta_config_save(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_settings(), public.api_ads_meta_source_save(text, jsonb),
  public.api_ads_meta_event_map_save(text, text, text, text, boolean), public.api_ads_meta_form_save(text, text, boolean),
  public.api_ads_meta_config_save(text, text) TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-meta', 'crm-ads-meta-reconcile');
    -- every 2 minutes, only when a Meta lead is waiting or a report is due
    PERFORM cron.schedule('crm-ads-meta', '*/2 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_leads", "meta_convert"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE crm_private.ads_meta_wake()
    $job$);
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
