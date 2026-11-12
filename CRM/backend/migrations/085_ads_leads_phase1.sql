-- 085: ADS Phase 1 - data integrity for Ads leads.
--   * ADS-only. Nothing outside ADS is created, replaced or written: the organic intake
--     (svc_ingest_website_lead / svc_ingest_charter_lead / crm-leads), the `lead`, `student` and
--     `audit_log` tables are untouched. `lead` and `student` are only READ (to link the same person).
--   * Ad enquiries arrive through their own entry point svc_ads_ingest_enquiry (Edge Function ads-intake).
--     Only enquiries carrying an ad click ID or a paid UTM medium are accepted; anything else is refused.
--   * Every ad enquiry is logged (ads_enquiry), even repeats and rejects; replays are idempotent.
--   * Append-only stage, assignment and contact history; consent history; verified lead-to-student
--     links; configurable retention. Pilot Training and Charter use separate stage lists.
-- Additive only: no existing row is changed. Re-runnable. Rollback: 085_ads_leads_phase1_down.sql.

-- ===========================================================================================
-- 1. Normalisation helpers
-- ===========================================================================================
-- E.164. Indian numbers: 10 digits (mobile 6-9, landline STD+number), optional 0 / 91 / 0091 prefix.
-- A number written with '+' and another country code is kept as given. Anything else -> NULL.
CREATE OR REPLACE FUNCTION crm_private.ads_phone_e164(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE raw text := btrim(coalesce(p, '')); d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
BEGIN
  IF raw ~ '[A-Za-z]' THEN RETURN NULL; END IF;
  IF d ~ '^0091[1-9]\d{9}$' THEN RETURN '+' || substr(d, 3); END IF;
  IF d ~ '^91[1-9]\d{9}$' AND (raw LIKE '+%' OR length(d) = 12) THEN RETURN '+' || d; END IF;
  IF d ~ '^0[1-9]\d{9}$' THEN RETURN '+91' || substr(d, 2); END IF;
  IF d ~ '^[1-9]\d{9}$' AND raw NOT LIKE '+%' THEN RETURN '+91' || d; END IF;
  IF raw LIKE '+%' AND d ~ '^[1-9]\d{7,14}$' AND d !~ '^91' THEN RETURN '+' || d; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_phone_kind(e164 text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN e164 IS NULL THEN NULL WHEN e164 ~ '^\+91[6-9]\d{9}$' THEN 'in_mobile'
              WHEN e164 ~ '^\+91' THEN 'in_landline' ELSE 'international' END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_email_norm(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN e ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' THEN e END
  FROM (SELECT lower(btrim(coalesce(p, ''))) AS e) x $$;

-- Short text from a JSON field (NULL when missing/blank).
CREATE OR REPLACE FUNCTION crm_private.ads_jtext(p jsonb, k text, lim int) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(left(btrim(coalesce(p->>k, '')), lim), '') $$;

CREATE OR REPLACE FUNCTION crm_private.ads_url_host(u text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(regexp_replace(lower(substring(coalesce(u, '') FROM '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#:]+)')), '^www\.', ''), '') $$;

-- ===========================================================================================
-- 2. Tables
-- ===========================================================================================
-- Our own websites (a referrer from these is not a new traffic source).
CREATE TABLE IF NOT EXISTS public.ads_site (
  domain text PRIMARY KEY CHECK (domain = lower(domain)),
  pipeline text NOT NULL CHECK (pipeline IN ('pilot_training', 'charter')),
  label text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.ads_site (domain, pipeline, label) VALUES
  ('weoneaviation.com', 'pilot_training', 'We One Aviation'), ('weoneaviation.in', 'pilot_training', 'We One Aviation'),
  ('pilotschool.in', 'pilot_training', 'Pilot School'), ('bookmycharter.in', 'charter', 'Book My Charter')
ON CONFLICT (domain) DO NOTHING;

-- Stage lists, one per pipeline (never shared).
CREATE TABLE IF NOT EXISTS public.ads_stage_def (
  pipeline text NOT NULL CHECK (pipeline IN ('pilot_training', 'charter')),
  stage text NOT NULL, ord int NOT NULL, label text NOT NULL,
  is_customer boolean NOT NULL DEFAULT false, is_terminal boolean NOT NULL DEFAULT false,
  needs_evidence boolean NOT NULL DEFAULT false,
  PRIMARY KEY (pipeline, stage));
INSERT INTO public.ads_stage_def (pipeline, stage, ord, label, is_customer, is_terminal, needs_evidence) VALUES
  ('pilot_training', 'lead_created', 10, 'Lead Created', false, false, false),
  ('pilot_training', 'contacted', 20, 'Contacted', false, false, false),
  ('pilot_training', 'interested', 30, 'Interested', false, false, false),
  ('pilot_training', 'qualified', 40, 'Qualified Lead', false, false, true),
  ('pilot_training', 'application_completed', 50, 'Application Completed', false, false, false),
  ('pilot_training', 'admission_completed', 60, 'Admission Completed', true, true, false),
  ('pilot_training', 'lost', 90, 'Lost', false, true, false),
  ('charter', 'lead_created', 10, 'Lead Created', false, false, false),
  ('charter', 'contacted', 20, 'Contacted', false, false, false),
  ('charter', 'quote_sent', 30, 'Quote Sent', false, false, false),
  ('charter', 'qualified', 40, 'Qualified Lead', false, false, true),
  ('charter', 'booking_confirmed', 60, 'Booking Confirmed', true, true, false),
  ('charter', 'lost', 90, 'Lost', false, true, false)
ON CONFLICT (pipeline, stage) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.ads_lead (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline text NOT NULL CHECK (pipeline IN ('pilot_training', 'charter')),
  name text NOT NULL, phone_e164 text NOT NULL, email text,
  stage text NOT NULL DEFAULT 'lead_created',
  contact_status text NOT NULL DEFAULT 'valid'
    CHECK (contact_status IN ('valid', 'contactable', 'unreachable', 'wrong_number')),
  quarantined boolean NOT NULL DEFAULT false, quarantine_reasons text[] NOT NULL DEFAULT '{}',
  owner_employee_id uuid,
  organic_lead_id uuid,                     -- same person in the organic Leads list (plain id, no constraint on lead)
  course_interest text, charter_details jsonb,
  first_touch jsonb NOT NULL DEFAULT '{}', last_touch jsonb NOT NULL DEFAULT '{}', last_non_direct jsonb,
  enquiry_count int NOT NULL DEFAULT 1,
  first_response_at timestamptz,
  last_interaction_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz, anonymised_at timestamptz,
  FOREIGN KEY (pipeline, stage) REFERENCES public.ads_stage_def (pipeline, stage));
CREATE UNIQUE INDEX IF NOT EXISTS ux_ads_lead_contact ON public.ads_lead (pipeline, phone_e164) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ads_lead_stage ON public.ads_lead (pipeline, stage, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ads_lead_email ON public.ads_lead (pipeline, email) WHERE email IS NOT NULL;

-- Every submission, organic or ads, valid or not. Never updated after insert except by retention.
CREATE TABLE IF NOT EXISTS public.ads_enquiry (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL UNIQUE,
  pipeline text NOT NULL CHECK (pipeline IN ('pilot_training', 'charter')),
  channel text NOT NULL CHECK (channel IN ('organic', 'ads')),
  site text,
  name text, phone_raw text, phone_e164 text, phone_kind text, email text, email_valid boolean,
  touch jsonb NOT NULL DEFAULT '{}',          -- click IDs, UTMs, referrer, landing page of this visit
  reported_first_touch jsonb,                   -- first touch as stored by the website script, if sent
  quality text NOT NULL DEFAULT 'ok' CHECK (quality IN ('ok', 'suspect', 'spam')),
  quality_reasons text[] NOT NULL DEFAULT '{}',
  dedup_result text NOT NULL CHECK (dedup_result IN ('new_contact', 'repeat_enquiry', 'probable_duplicate', 'rejected')),
  probable_duplicate_of uuid REFERENCES public.ads_lead(id),
  ads_lead_id uuid REFERENCES public.ads_lead(id),
  result jsonb NOT NULL,
  payload_extra jsonb NOT NULL DEFAULT '{}');   -- other form fields, for audit
CREATE INDEX IF NOT EXISTS idx_ads_enquiry_phone ON public.ads_enquiry (phone_e164, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_ads_enquiry_ads_lead ON public.ads_enquiry (ads_lead_id, received_at);

CREATE TABLE IF NOT EXISTS public.ads_lead_stage_event (
  id bigserial PRIMARY KEY,
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id),
  from_stage text, to_stage text NOT NULL,
  employee_id uuid,
  source text NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'system')),
  note text, evidence jsonb NOT NULL DEFAULT '{}',
  at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_stage_event_lead ON public.ads_lead_stage_event (lead_id, at);

CREATE TABLE IF NOT EXISTS public.ads_lead_assignment (
  id bigserial PRIMARY KEY,
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id),
  from_employee uuid, to_employee uuid,
  by_employee uuid, reason text,
  at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_assignment_lead ON public.ads_lead_assignment (lead_id, at);

CREATE TABLE IF NOT EXISTS public.ads_lead_contact (
  id bigserial PRIMARY KEY,
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id),
  employee_id uuid,
  channel text NOT NULL CHECK (channel IN ('phone', 'whatsapp', 'email', 'sms', 'in_person')),
  outcome text NOT NULL CHECK (outcome IN ('connected', 'no_answer', 'busy', 'wrong_number', 'callback_requested', 'message_sent')),
  note text, at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_contact_lead ON public.ads_lead_contact (lead_id, at);

-- Consent history. purpose: enquiry_response (reply to this enquiry), marketing (optional promotions),
-- ad_data_sharing (sending this person's data to Google/Meta for measurement).
CREATE TABLE IF NOT EXISTS public.ads_consent_event (
  id bigserial PRIMARY KEY,
  subject_phone text, subject_email text,
  purpose text NOT NULL CHECK (purpose IN ('enquiry_response', 'marketing', 'ad_data_sharing')),
  status text NOT NULL CHECK (status IN ('granted', 'denied', 'withdrawn')),
  notice_version text NOT NULL DEFAULT 'unspecified',
  source text NOT NULL CHECK (source IN ('web_form', 'phone', 'whatsapp', 'email', 'staff', 'import')),
  enquiry_id uuid REFERENCES public.ads_enquiry(id),
  recorded_by uuid,
  note text, at timestamptz NOT NULL DEFAULT now(),
  CHECK (subject_phone IS NOT NULL OR subject_email IS NOT NULL));
CREATE INDEX IF NOT EXISTS idx_consent_phone ON public.ads_consent_event (subject_phone, purpose, at DESC);
CREATE INDEX IF NOT EXISTS idx_consent_email ON public.ads_consent_event (subject_email, purpose, at DESC);

-- Verified links from a student to the Ads lead they came from (ADS reporting; the student record is not changed).
CREATE TABLE IF NOT EXISTS public.ads_student_link (
  id bigserial PRIMARY KEY,
  student_id uuid NOT NULL,
  lead_kind text NOT NULL DEFAULT 'ads' CHECK (lead_kind = 'ads'),
  ads_lead_id uuid NOT NULL REFERENCES public.ads_lead(id),
  match_method text NOT NULL CHECK (match_method IN ('phone_exact', 'email_exact', 'name_exact', 'manual')),
  evidence jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'verified', 'rejected')),
  proposed_at timestamptz NOT NULL DEFAULT now(),
  decided_by uuid, decided_at timestamptz, note text,
  CHECK (status = 'proposed' OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)));
CREATE UNIQUE INDEX IF NOT EXISTS ux_student_link_verified ON public.ads_student_link (student_id) WHERE status = 'verified';
CREATE UNIQUE INDEX IF NOT EXISTS ux_student_link_pair ON public.ads_student_link (student_id, ads_lead_id);

CREATE TABLE IF NOT EXISTS public.ads_retention_policy (
  category text PRIMARY KEY,
  months int NOT NULL CHECK (months > 0),
  basis text NOT NULL,
  legal_review_status text NOT NULL DEFAULT 'pending' CHECK (legal_review_status IN ('pending', 'approved')),
  enabled boolean NOT NULL DEFAULT false,
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.ads_retention_policy (category, months, basis) VALUES
  ('ads_lead_lost', 12, 'Lost Ads lead: 12 months after the last meaningful interaction (business decision, pending legal review)'),
  ('student_training_record', 60, 'Student training records: 5 years minimum as stated by the business for DGCA; not verified against the CAR text, pending legal review. Report only - never auto-deleted.')
ON CONFLICT (category) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.ads_retention_run (
  id bigserial PRIMARY KEY, category text NOT NULL, as_of timestamptz NOT NULL, dry_run boolean NOT NULL,
  affected int NOT NULL, ids uuid[] NOT NULL DEFAULT '{}', run_by uuid, at timestamptz NOT NULL DEFAULT now());

-- Roles inside ADS. Existing rows keep working (default 'marketer'); Admin always has full rights.
ALTER TABLE public.ads_access ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'marketer';
DO $$ BEGIN
  ALTER TABLE public.ads_access ADD CONSTRAINT ads_access_role_chk CHECK (role IN ('viewer', 'counsellor', 'marketer', 'approver'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Lock everything down: reached only through the functions below.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['ads_site', 'ads_stage_def', 'ads_lead', 'ads_enquiry', 'ads_lead_stage_event',
    'ads_lead_assignment', 'ads_lead_contact', 'ads_consent_event', 'ads_student_link',
    'ads_retention_policy', 'ads_retention_run'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;
REVOKE ALL ON SEQUENCE public.ads_lead_stage_event_id_seq, public.ads_lead_assignment_id_seq,
  public.ads_lead_contact_id_seq, public.ads_consent_event_id_seq, public.ads_student_link_id_seq,
  public.ads_retention_run_id_seq FROM anon, authenticated;

-- History tables are append-only. Retention anonymisation is the single allowed exception.
CREATE OR REPLACE FUNCTION crm_private.ads_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF current_setting('ads.retention_run', true) = 'on' AND TG_OP = 'UPDATE' THEN RETURN NEW; END IF;
  RAISE EXCEPTION '% is append-only (% not allowed)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'PT409';
END $$;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['ads_lead_stage_event', 'ads_lead_assignment', 'ads_lead_contact', 'ads_consent_event', 'ads_enquiry'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_append_only ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_append_only BEFORE UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION crm_private.ads_append_only()', t, t);
  END LOOP;
END $$;
-- Ads leads and student links are never hard-deleted (soft delete / reject instead).
DROP TRIGGER IF EXISTS trg_ads_lead_no_delete ON public.ads_lead;
CREATE TRIGGER trg_ads_lead_no_delete BEFORE DELETE ON public.ads_lead FOR EACH ROW EXECUTE FUNCTION crm_private.ads_append_only();
DROP TRIGGER IF EXISTS trg_student_link_no_delete ON public.ads_student_link;
CREATE TRIGGER trg_student_link_no_delete BEFORE DELETE ON public.ads_student_link FOR EACH ROW EXECUTE FUNCTION crm_private.ads_append_only();

-- ===========================================================================================
-- 3. Access helpers
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.is_admin() THEN 'admin'
    ELSE (SELECT a.role FROM public.ads_access a WHERE a.employee_id = crm_private.current_employee_id()) END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_require_lead_edit() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r text := crm_private.ads_role(); me uuid := crm_private.current_employee_id();
BEGIN
  IF r IS NULL THEN RAISE EXCEPTION 'You do not have access to the ADS section' USING ERRCODE = 'PT403'; END IF;
  IF r = 'viewer' THEN RAISE EXCEPTION 'Your ADS role is view-only' USING ERRCODE = 'PT403'; END IF;
  IF me IS NULL THEN RAISE EXCEPTION 'No active employee for this login' USING ERRCODE = 'PT403'; END IF;
  RETURN me;
END $$;

-- ===========================================================================================
-- 4. Intake
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_touch_from(p jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'gclid', crm_private.ads_jtext(p, 'gclid', 200), 'gbraid', crm_private.ads_jtext(p, 'gbraid', 200),
    'wbraid', crm_private.ads_jtext(p, 'wbraid', 200), 'fbclid', crm_private.ads_jtext(p, 'fbclid', 300),
    'fbc', crm_private.ads_jtext(p, 'fbc', 300), 'fbp', crm_private.ads_jtext(p, 'fbp', 100),
    'utm_source', crm_private.ads_jtext(p, 'utm_source', 200), 'utm_medium', crm_private.ads_jtext(p, 'utm_medium', 200),
    'utm_campaign', crm_private.ads_jtext(p, 'utm_campaign', 200), 'utm_term', crm_private.ads_jtext(p, 'utm_term', 200),
    'utm_content', crm_private.ads_jtext(p, 'utm_content', 200),
    'referrer', crm_private.ads_jtext(p, 'referrer', 1000), 'landing_page', crm_private.ads_jtext(p, 'landing_page', 1000),
    'page_url', crm_private.ads_jtext(p, 'page_url', 1000),
    'site', coalesce(crm_private.ads_jtext(p, 'site', 200), crm_private.ads_url_host(p->>'page_url'), crm_private.ads_url_host(p->>'landing_page')),
    'at', coalesce(crm_private.ads_jtext(p, 'touch_at', 40), to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))) $$;

-- Paid traffic: an ad click ID, or a paid UTM medium. _fbp alone is not an ad signal (set on every visit).
CREATE OR REPLACE FUNCTION crm_private.ads_touch_is_ads(t jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT t ?| ARRAY['gclid', 'gbraid', 'wbraid', 'fbclid', 'fbc']
      OR lower(coalesce(t->>'utm_medium', '')) IN ('cpc', 'ppc', 'paid', 'paidsearch', 'paid_search', 'paid_social', 'paidsocial', 'cpm', 'display') $$;

-- Non-direct: any source information other than a referral from our own sites.
CREATE OR REPLACE FUNCTION crm_private.ads_touch_is_non_direct(t jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_touch_is_ads(t) OR t ? 'utm_source'
      OR (crm_private.ads_url_host(t->>'referrer') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.ads_site s WHERE crm_private.ads_url_host(t->>'referrer') = s.domain
                                                          OR crm_private.ads_url_host(t->>'referrer') LIKE '%.' || s.domain)) $$;

CREATE OR REPLACE FUNCTION crm_private.ads_ingest_enquiry(p jsonb, p_pipeline text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  k text; prev record; t jsonb; ads boolean; e164 text; em text; nm text; reasons text[] := '{}'; q text := 'ok';
  res jsonb; dedup text; lid uuid; olid uuid; dup_of uuid; ex record; c jsonb; det text; eid uuid;
  ft jsonb; ms numeric; consent jsonb; nv text; known text[] := ARRAY['name', 'phone', 'email', 'address', 'course_interest',
    'submission_id', 'hp', 'company_website', 'elapsed_ms', 'consent', 'first_touch', 'touch_at', 'site', 'page_url',
    'landing_page', 'referrer', 'gclid', 'gbraid', 'wbraid', 'fbclid', 'fbc', 'fbp',
    'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RETURN CASE WHEN p_pipeline = 'charter' THEN jsonb_build_object('errors_json', '{"body": "Expected a JSON object"}')
                ELSE jsonb_build_object('error', 'Expected a JSON object') END;
  END IF;
  e164 := crm_private.ads_phone_e164(p->>'phone');
  em := crm_private.ads_email_norm(p->>'email');
  nm := crm_private.ads_jtext(p, 'name', 120);
  t := crm_private.ads_touch_from(p);
  ft := CASE WHEN jsonb_typeof(p->'first_touch') = 'object' THEN p->'first_touch' END;
  ads := crm_private.ads_touch_is_ads(t);
  IF NOT ads THEN
    -- Not an ad enquiry: belongs to the normal (organic) enquiry form. Nothing is stored here.
    RETURN jsonb_build_object('error', 'not_an_ad_enquiry');
  END IF;

  -- Idempotency: the form's submission_id, otherwise identical content within the same 2-minute window.
  k := coalesce('sub:' || crm_private.ads_jtext(p, 'submission_id', 100),
         'auto:' || encode(sha256(convert_to(concat_ws('|', p_pipeline, coalesce(e164, p->>'phone'), em, nm,
           p->>'course_interest', p->>'from', p->>'to', p->>'departureDate', floor(extract(epoch FROM now()) / 120)), 'UTF8')), 'hex'));
  PERFORM pg_advisory_xact_lock(hashtext('enquiry|' || k));
  SELECT e.result INTO prev FROM public.ads_enquiry e WHERE e.idempotency_key = k;
  IF FOUND THEN RETURN prev.result; END IF;

  -- Spam / fraud indicators (flag + quarantine; nothing is deleted).
  IF coalesce(crm_private.ads_jtext(p, 'hp', 200), crm_private.ads_jtext(p, 'company_website', 200)) IS NOT NULL THEN
    reasons := reasons || 'honeypot_filled'::text; q := 'spam'; END IF;
  BEGIN ms := (p->>'elapsed_ms')::numeric; EXCEPTION WHEN others THEN ms := NULL; END;
  IF ms IS NOT NULL AND ms < 2500 THEN reasons := reasons || 'submitted_too_fast'::text; END IF;
  IF e164 IS NULL THEN reasons := reasons || 'invalid_phone'::text; END IF;
  IF nullif(btrim(coalesce(p->>'email', '')), '') IS NOT NULL AND em IS NULL THEN reasons := reasons || 'invalid_email'::text; END IF;
  IF em ~ '@(mailinator\.com|guerrillamail\.com|10minutemail\.com|tempmail\.com|yopmail\.com|trashmail\.com)$' THEN
    reasons := reasons || 'disposable_email'::text; END IF;
  IF nm ~* '(https?://|www\.|<|>)' THEN reasons := reasons || 'link_in_name'::text; END IF;
  IF nm IS NULL THEN reasons := reasons || 'missing_name'::text; END IF;
  IF e164 IS NOT NULL AND (SELECT count(*) FROM public.ads_enquiry e
        WHERE e.phone_e164 = e164 AND e.received_at > now() - interval '1 hour') >= 5 THEN
    reasons := reasons || 'too_many_enquiries_1h'::text; END IF;
  IF q <> 'spam' AND reasons && ARRAY['submitted_too_fast', 'disposable_email', 'link_in_name', 'too_many_enquiries_1h', 'invalid_email'] THEN
    q := 'suspect'; END IF;
  IF e164 IS NULL THEN q := 'spam'; END IF;

  -- Ads enquiry -------------------------------------------------------------------------------
  IF p_pipeline = 'charter' THEN
    BEGIN
      c := crm_private.validate_charter(p, true);
    EXCEPTION WHEN SQLSTATE 'PT400' THEN
      GET STACKED DIAGNOSTICS det = PG_EXCEPTION_DETAIL;
      res := jsonb_build_object('errors_json', det);
    END;
  ELSIF e164 IS NULL THEN
    res := jsonb_build_object('error', 'A valid phone number is required');
  END IF;
  IF res IS NULL AND e164 IS NULL THEN
    res := CASE WHEN p_pipeline = 'charter' THEN jsonb_build_object('errors_json', '{"phone": "Enter a valid phone number"}')
                ELSE jsonb_build_object('error', 'A valid phone number is required') END;
  END IF;
  IF res IS NULL AND nm IS NULL AND p_pipeline = 'pilot_training' THEN
    res := jsonb_build_object('error', 'Name is required');
  END IF;
  IF res IS NOT NULL THEN
    INSERT INTO public.ads_enquiry (idempotency_key, pipeline, channel, site, name, phone_raw, phone_e164, phone_kind,
      email, email_valid, touch, reported_first_touch, quality, quality_reasons, dedup_result, result, payload_extra)
    VALUES (k, p_pipeline, 'ads', t->>'site', nm, left(p->>'phone', 30), e164, crm_private.ads_phone_kind(e164),
      coalesce(em, crm_private.ads_jtext(p, 'email', 200)), em IS NOT NULL, t, ft, 'spam',
      reasons || 'failed_validation'::text, 'rejected', res, p - known);
    RETURN res;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('adslead|' || p_pipeline || '|' || e164));
  SELECT * INTO ex FROM public.ads_lead l WHERE l.pipeline = p_pipeline AND l.phone_e164 = e164 AND l.deleted_at IS NULL;
  IF FOUND THEN
    lid := ex.id; dedup := 'repeat_enquiry';
    UPDATE public.ads_lead SET enquiry_count = enquiry_count + 1, last_touch = t,
      last_non_direct = CASE WHEN crm_private.ads_touch_is_non_direct(t) THEN t ELSE last_non_direct END,
      email = coalesce(email, em), last_interaction_at = now(), updated_at = now(),
      quarantine_reasons = CASE WHEN q <> 'ok' THEN (SELECT array_agg(DISTINCT r) FROM unnest(quarantine_reasons || reasons) r) ELSE quarantine_reasons END
    WHERE id = lid;
    res := jsonb_build_object('status', 'duplicate', 'lead_id', lid);
  ELSE
    IF em IS NOT NULL THEN
      SELECT l.id INTO dup_of FROM public.ads_lead l
      WHERE l.pipeline = p_pipeline AND l.email = em AND l.deleted_at IS NULL ORDER BY l.created_at LIMIT 1;
    END IF;
    dedup := CASE WHEN dup_of IS NOT NULL THEN 'probable_duplicate' ELSE 'new_contact' END;
    IF dup_of IS NOT NULL THEN reasons := reasons || 'same_email_other_phone'::text; END IF;
    -- Same person already in the organic list: link, never move or change the organic record.
    SELECT o.id INTO olid FROM public.lead o
    WHERE crm_private.norm_phone(o.phone) = e164 AND o.segment = CASE p_pipeline WHEN 'charter' THEN 'charter' ELSE 'aviation' END
    ORDER BY o.created_at LIMIT 1;
    INSERT INTO public.ads_lead (pipeline, name, phone_e164, email, quarantined, quarantine_reasons, organic_lead_id,
      course_interest, charter_details, first_touch, last_touch, last_non_direct)
    VALUES (p_pipeline, coalesce(nm, c->>'name'), e164, em, q <> 'ok', CASE WHEN q <> 'ok' THEN reasons ELSE '{}' END, olid,
      crm_private.ads_jtext(p, 'course_interest', 120), c->'details',
      coalesce(ft, t), t, CASE WHEN crm_private.ads_touch_is_non_direct(t) THEN t END)
    RETURNING id INTO lid;
    INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, source, note)
    VALUES (lid, NULL, 'lead_created', 'system', 'Enquiry received');
    res := jsonb_build_object('status', 'created', 'lead_id', lid);
  END IF;
  IF p_pipeline = 'charter' THEN res := res || jsonb_build_object('reference', crm_private.charter_reference(lid)); END IF;

  INSERT INTO public.ads_enquiry (idempotency_key, pipeline, channel, site, name, phone_raw, phone_e164, phone_kind,
    email, email_valid, touch, reported_first_touch, quality, quality_reasons, dedup_result, probable_duplicate_of,
    ads_lead_id, result, payload_extra)
  VALUES (k, p_pipeline, 'ads', t->>'site', nm, left(p->>'phone', 30), e164, crm_private.ads_phone_kind(e164),
    em, em IS NOT NULL, t, ft, q, reasons, dedup, dup_of, lid, res, p - known)
  RETURNING id INTO eid;

  -- Consent as given on the form. Submitting an enquiry is a request to be contacted about it.
  consent := CASE WHEN jsonb_typeof(p->'consent') = 'object' THEN p->'consent' ELSE '{}' END;
  nv := coalesce(crm_private.ads_jtext(consent, 'notice_version', 50), 'unspecified');
  INSERT INTO public.ads_consent_event (subject_phone, subject_email, purpose, status, notice_version, source, enquiry_id)
  SELECT e164, em, x.purpose, x.status, nv, 'web_form', eid
  FROM (VALUES ('enquiry_response', 'granted'),
               ('marketing', CASE consent->>'marketing' WHEN 'true' THEN 'granted' WHEN 'false' THEN 'denied' END),
               ('ad_data_sharing', CASE consent->>'ad_data_sharing' WHEN 'true' THEN 'granted' WHEN 'false' THEN 'denied' END)
       ) x(purpose, status)
  WHERE x.status IS NOT NULL;

  INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('system', CASE WHEN dedup = 'repeat_enquiry' THEN 'enquiry' ELSE 'create' END, 'ads_lead', lid::text,
          jsonb_build_object('pipeline', p_pipeline, 'quality', q));
  RETURN res;
END $$;

-- ADS entry point (service_role only; called by the ads-intake Edge Function).
CREATE OR REPLACE FUNCTION public.svc_ads_ingest_enquiry(payload jsonb, pipeline text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF pipeline IS NULL OR pipeline NOT IN ('pilot_training', 'charter') THEN RETURN jsonb_build_object('error', 'unknown_pipeline'); END IF;
  RETURN crm_private.ads_ingest_enquiry(payload, pipeline);
END $$;
REVOKE ALL ON FUNCTION public.svc_ads_ingest_enquiry(jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_ingest_enquiry(jsonb, text) TO service_role;

-- ===========================================================================================
-- 5. Consent
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_consent_status(p_phone text, p_email text, p_purpose text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT c.status FROM public.ads_consent_event c
    WHERE c.purpose = p_purpose AND ((p_phone IS NOT NULL AND c.subject_phone = p_phone) OR (p_email IS NOT NULL AND c.subject_email = p_email))
    ORDER BY c.at DESC, c.id DESC LIMIT 1), 'none') $$;

-- Phase 3 must call this before sending anything to Google/Meta.
CREATE OR REPLACE FUNCTION crm_private.ads_consent_allows(p_phone text, p_email text, p_purpose text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_consent_status(p_phone, p_email, p_purpose) = 'granted' $$;

CREATE OR REPLACE FUNCTION public.api_ads_consent_record(p_phone text, p_email text, p_purpose text, p_status text,
  p_source text, p_notice_version text DEFAULT 'unspecified', p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.ads_require_lead_edit(); ph text := crm_private.ads_phone_e164(p_phone);
        em text := crm_private.ads_email_norm(p_email); nid bigint;
BEGIN
  IF ph IS NULL AND em IS NULL THEN RAISE EXCEPTION 'A valid phone or email is required' USING ERRCODE = 'PT400'; END IF;
  INSERT INTO public.ads_consent_event (subject_phone, subject_email, purpose, status, notice_version, source, recorded_by, note)
  VALUES (ph, em, p_purpose, p_status, coalesce(p_notice_version, 'unspecified'), p_source, me, p_note) RETURNING id INTO nid;
  PERFORM crm_private.ads_log('consent_' || p_status, 'consent', nid::text, jsonb_build_object('purpose', p_purpose));
  RETURN jsonb_build_object('id', nid, 'status', crm_private.ads_consent_status(ph, em, p_purpose));
END $$;

-- ===========================================================================================
-- 6. Ads lead work: stage, assignment, contact, quarantine
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_ads_lead_set_stage(p_lead uuid, p_stage text, p_note text DEFAULT NULL,
  p_evidence jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.ads_require_lead_edit(); l record; cur record; nxt record;
BEGIN
  SELECT * INTO l FROM public.ads_lead WHERE id = p_lead AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ads lead not found' USING ERRCODE = 'PT404'; END IF;
  SELECT * INTO nxt FROM public.ads_stage_def WHERE pipeline = l.pipeline AND stage = p_stage;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stage % does not exist for %', p_stage, l.pipeline USING ERRCODE = 'PT400'; END IF;
  IF p_stage = l.stage THEN RETURN jsonb_build_object('lead_id', p_lead, 'stage', l.stage, 'changed', false); END IF;
  SELECT * INTO cur FROM public.ads_stage_def WHERE pipeline = l.pipeline AND stage = l.stage;
  IF cur.is_terminal AND NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can reopen a lead at %', cur.label USING ERRCODE = 'PT403'; END IF;
  IF cur.is_terminal AND nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A reason is required to reopen a lead' USING ERRCODE = 'PT400'; END IF;
  IF nxt.needs_evidence AND (p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' OR p_evidence = '{}'::jsonb) THEN
    RAISE EXCEPTION '% needs the qualification answers recorded', nxt.label USING ERRCODE = 'PT400'; END IF;
  IF l.quarantined AND nxt.ord > 10 AND p_stage <> 'lost' THEN
    RAISE EXCEPTION 'Release this lead from quarantine first' USING ERRCODE = 'PT409'; END IF;
  INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, employee_id, note, evidence)
  VALUES (p_lead, l.stage, p_stage, me, p_note, coalesce(p_evidence, '{}'));
  UPDATE public.ads_lead SET stage = p_stage, updated_at = now(), last_interaction_at = now(),
    first_response_at = coalesce(first_response_at, CASE WHEN p_stage <> 'lost' THEN now() END)
  WHERE id = p_lead;
  RETURN jsonb_build_object('lead_id', p_lead, 'stage', p_stage, 'changed', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_assign(p_lead uuid, p_employee uuid, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.ads_require_lead_edit(); l record;
BEGIN
  SELECT * INTO l FROM public.ads_lead WHERE id = p_lead AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ads lead not found' USING ERRCODE = 'PT404'; END IF;
  IF p_employee IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.employee e WHERE e.id = p_employee AND e.active) THEN
    RAISE EXCEPTION 'Employee is not active' USING ERRCODE = 'PT400'; END IF;
  IF l.owner_employee_id IS NOT DISTINCT FROM p_employee THEN RETURN jsonb_build_object('changed', false); END IF;
  INSERT INTO public.ads_lead_assignment (lead_id, from_employee, to_employee, by_employee, reason)
  VALUES (p_lead, l.owner_employee_id, p_employee, me, p_reason);
  UPDATE public.ads_lead SET owner_employee_id = p_employee, updated_at = now() WHERE id = p_lead;
  RETURN jsonb_build_object('changed', true, 'owner', p_employee);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_log_contact(p_lead uuid, p_channel text, p_outcome text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.ads_require_lead_edit(); l record; cid bigint;
BEGIN
  SELECT * INTO l FROM public.ads_lead WHERE id = p_lead AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ads lead not found' USING ERRCODE = 'PT404'; END IF;
  INSERT INTO public.ads_lead_contact (lead_id, employee_id, channel, outcome, note)
  VALUES (p_lead, me, p_channel, p_outcome, p_note) RETURNING id INTO cid;
  UPDATE public.ads_lead SET
    contact_status = CASE p_outcome WHEN 'connected' THEN 'contactable' WHEN 'callback_requested' THEN 'contactable'
                       WHEN 'wrong_number' THEN 'wrong_number'
                       WHEN 'no_answer' THEN CASE WHEN contact_status = 'contactable' THEN contact_status ELSE 'unreachable' END
                       WHEN 'busy' THEN CASE WHEN contact_status = 'contactable' THEN contact_status ELSE 'unreachable' END
                       ELSE contact_status END,
    first_response_at = coalesce(first_response_at, now()), last_interaction_at = now(), updated_at = now()
  WHERE id = p_lead;
  -- A real conversation moves a new lead to Contacted, credited to the person who made it.
  IF p_outcome IN ('connected', 'callback_requested') AND l.stage = 'lead_created' AND NOT l.quarantined THEN
    PERFORM public.api_ads_lead_set_stage(p_lead, 'contacted', 'Contact logged', '{}');
  END IF;
  RETURN jsonb_build_object('contact_id', cid);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_quarantine(p_lead uuid, p_quarantined boolean, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.ads_require_lead_edit(); l record;
BEGIN
  IF nullif(btrim(coalesce(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'A reason is required' USING ERRCODE = 'PT400'; END IF;
  SELECT * INTO l FROM public.ads_lead WHERE id = p_lead AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ads lead not found' USING ERRCODE = 'PT404'; END IF;
  UPDATE public.ads_lead SET quarantined = p_quarantined, updated_at = now(),
    quarantine_reasons = CASE WHEN p_quarantined THEN quarantine_reasons || ('staff: ' || p_reason) ELSE quarantine_reasons END
  WHERE id = p_lead;
  INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, employee_id, note, evidence)
  VALUES (p_lead, l.stage, l.stage, me, CASE WHEN p_quarantined THEN 'Quarantined: ' ELSE 'Released: ' END || p_reason,
          jsonb_build_object('quarantine', p_quarantined));
  RETURN jsonb_build_object('lead_id', p_lead, 'quarantined', p_quarantined);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_list(p_pipeline text DEFAULT NULL, p_stage text DEFAULT NULL,
  p_quarantined boolean DEFAULT false, p_limit int DEFAULT 50, p_offset int DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
    SELECT l.id, l.pipeline, l.name, l.phone_e164, l.email, l.stage, l.contact_status, l.quarantined, l.quarantine_reasons,
           l.owner_employee_id, l.organic_lead_id, l.enquiry_count, l.first_touch, l.last_non_direct, l.first_response_at,
           l.last_interaction_at, l.created_at
    FROM public.ads_lead l
    WHERE l.deleted_at IS NULL AND (p_pipeline IS NULL OR l.pipeline = p_pipeline) AND (p_stage IS NULL OR l.stage = p_stage)
      AND l.quarantined = coalesce(p_quarantined, false)
    ORDER BY l.created_at DESC LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0)) x), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead(p_lead uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l record;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO l FROM public.ads_lead WHERE id = p_lead AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ads lead not found' USING ERRCODE = 'PT404'; END IF;
  RETURN to_jsonb(l) || jsonb_build_object(
    'enquiries', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'at', e.received_at, 'touch', e.touch, 'quality', e.quality,
                    'reasons', e.quality_reasons, 'dedup', e.dedup_result) ORDER BY e.received_at), '[]') FROM public.ads_enquiry e WHERE e.ads_lead_id = p_lead),
    'stages', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.at, s.id), '[]') FROM public.ads_lead_stage_event s WHERE s.lead_id = p_lead),
    'assignments', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.at, a.id), '[]') FROM public.ads_lead_assignment a WHERE a.lead_id = p_lead),
    'contacts', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.at, c.id), '[]') FROM public.ads_lead_contact c WHERE c.lead_id = p_lead),
    'consent', jsonb_build_object(
       'enquiry_response', crm_private.ads_consent_status(l.phone_e164, l.email, 'enquiry_response'),
       'marketing', crm_private.ads_consent_status(l.phone_e164, l.email, 'marketing'),
       'ad_data_sharing', crm_private.ads_consent_status(l.phone_e164, l.email, 'ad_data_sharing')));
END $$;

-- Counsellor credit = who actually moved leads forward (stage events), not who owns them now.
CREATE OR REPLACE FUNCTION public.api_ads_counsellor_credit(p_pipeline text, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.employee_id) FROM (
    SELECT s.employee_id, s.to_stage, count(*) AS moves, count(DISTINCT s.lead_id) AS leads
    FROM public.ads_lead_stage_event s JOIN public.ads_lead l ON l.id = s.lead_id
    JOIN public.ads_stage_def f ON f.pipeline = l.pipeline AND f.stage = s.to_stage
    LEFT JOIN public.ads_stage_def b ON b.pipeline = l.pipeline AND b.stage = s.from_stage
    WHERE l.pipeline = p_pipeline AND s.source = 'user' AND s.employee_id IS NOT NULL
      AND s.at >= p_from AND s.at < p_to + 1 AND (b.ord IS NULL OR f.ord > b.ord) AND s.to_stage <> 'lost'
    GROUP BY s.employee_id, s.to_stage) x), '[]'::jsonb);
END $$;

-- ===========================================================================================
-- 7. Lead-to-student links (proposals from evidence; a person verifies)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_student_link_propose() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  WITH cand AS (   -- Ads leads (Pilot Training) only; student rows are read, never changed.
    SELECT s.id sid, 'ads'::text kind, a.id aid, 'phone_exact'::text m,
           jsonb_build_object('student_mobile', s.mobile_normalized, 'ads_phone', a.phone_e164) ev
    FROM public.student s JOIN public.ads_lead a ON a.phone_e164 = crm_private.ads_phone_e164(s.mobile)
      AND a.deleted_at IS NULL AND a.pipeline = 'pilot_training'
    UNION ALL
    SELECT s.id, 'ads', a.id, 'name_exact',
           jsonb_build_object('student_name', concat_ws(' ', s.first_name, s.middle_name, s.last_name), 'ads_name', a.name,
                              'note', 'Name only - check guardian, course and dates before verifying')
    FROM public.student s JOIN public.ads_lead a
      ON lower(regexp_replace(btrim(a.name), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(concat_ws(' ', s.first_name, s.middle_name, s.last_name)), '\s+', ' ', 'g'))
      AND a.deleted_at IS NULL AND a.pipeline = 'pilot_training' AND a.phone_e164 <> crm_private.ads_phone_e164(s.mobile))
  INSERT INTO public.ads_student_link (student_id, lead_kind, ads_lead_id, match_method, evidence)
  SELECT sid, kind, aid, m, ev FROM cand
  ON CONFLICT (student_id, ads_lead_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_student_links_propose() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  RETURN jsonb_build_object('proposed', crm_private.ads_student_link_propose());
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_student_link_decide(p_link bigint, p_verify boolean, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid; r record;
BEGIN
  PERFORM crm_private.ads_require_admin();
  me := crm_private.current_employee_id();
  IF nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN RAISE EXCEPTION 'Say what you checked' USING ERRCODE = 'PT400'; END IF;
  SELECT * INTO r FROM public.ads_student_link WHERE id = p_link FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Link not found' USING ERRCODE = 'PT404'; END IF;
  IF r.status <> 'proposed' THEN RAISE EXCEPTION 'Already decided' USING ERRCODE = 'PT409'; END IF;
  UPDATE public.ads_student_link SET status = CASE WHEN p_verify THEN 'verified' ELSE 'rejected' END,
    decided_by = me, decided_at = now(), note = p_note WHERE id = p_link;
  PERFORM crm_private.ads_log(CASE WHEN p_verify THEN 'verify' ELSE 'reject' END, 'lead_student_link', p_link::text,
    jsonb_build_object('student_id', r.student_id));
  RETURN jsonb_build_object('link_id', p_link, 'status', CASE WHEN p_verify THEN 'verified' ELSE 'rejected' END);
END $$;

-- ===========================================================================================
-- 8. Retention (report first; anonymise only when enabled AND legally approved)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.ads_retention_candidates(p_as_of timestamptz) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.id FROM public.ads_lead l, public.ads_retention_policy rp
  WHERE rp.category = 'ads_lead_lost' AND l.stage = 'lost' AND l.deleted_at IS NULL AND l.anonymised_at IS NULL
    AND l.last_interaction_at < p_as_of - make_interval(months => rp.months)
    AND NOT EXISTS (SELECT 1 FROM public.ads_student_link k WHERE k.ads_lead_id = l.id AND k.status = 'verified') $$;

CREATE OR REPLACE FUNCTION public.api_ads_retention_run(p_dry_run boolean DEFAULT true, p_as_of timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rp record; ids uuid[]; me uuid;
BEGIN
  PERFORM crm_private.ads_require_admin();
  me := crm_private.current_employee_id();
  SELECT * INTO rp FROM public.ads_retention_policy WHERE category = 'ads_lead_lost';
  ids := ARRAY(SELECT crm_private.ads_retention_candidates(p_as_of));
  IF NOT p_dry_run AND NOT (rp.enabled AND rp.legal_review_status = 'approved') THEN
    RAISE EXCEPTION 'Retention is not enabled and legally approved yet; run a dry run instead' USING ERRCODE = 'PT409';
  END IF;
  IF NOT p_dry_run AND cardinality(ids) > 0 THEN
    PERFORM set_config('ads.retention_run', 'on', true);
    UPDATE public.ads_lead SET name = '[removed]', phone_e164 = 'removed:' || id::text, email = NULL, charter_details = NULL,
      first_touch = '{}', last_touch = '{}', last_non_direct = NULL, anonymised_at = now(), updated_at = now()
    WHERE id = ANY (ids);
    UPDATE public.ads_enquiry SET name = NULL, phone_raw = NULL, phone_e164 = NULL, email = NULL, touch = '{}',
      reported_first_touch = NULL, payload_extra = '{}' WHERE ads_lead_id = ANY (ids);
    UPDATE public.ads_lead_contact SET note = NULL WHERE lead_id = ANY (ids);
    UPDATE public.ads_lead_stage_event SET note = NULL, evidence = '{}' WHERE lead_id = ANY (ids);
    PERFORM set_config('ads.retention_run', 'off', true);
  END IF;
  INSERT INTO public.ads_retention_run (category, as_of, dry_run, affected, ids, run_by)
  VALUES ('ads_lead_lost', p_as_of, p_dry_run, cardinality(ids), ids, me);
  RETURN jsonb_build_object('dry_run', p_dry_run, 'affected', cardinality(ids), 'ids', to_jsonb(ids));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_retention_policy_set(p_category text, p_months int, p_enabled boolean, p_legal_review_status text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_category = 'student_training_record' AND p_enabled THEN
    RAISE EXCEPTION 'Student training records are report-only' USING ERRCODE = 'PT400'; END IF;
  UPDATE public.ads_retention_policy SET months = p_months, enabled = p_enabled, legal_review_status = p_legal_review_status,
    updated_by = crm_private.current_employee_id(), updated_at = now() WHERE category = p_category;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown category' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('set', 'retention_policy', p_category,
    jsonb_build_object('months', p_months, 'enabled', p_enabled, 'legal', p_legal_review_status));
  RETURN jsonb_build_object('category', p_category, 'months', p_months, 'enabled', p_enabled, 'legal_review_status', p_legal_review_status);
END $$;

-- ===========================================================================================
-- 9. Grants
-- ===========================================================================================
DO $$ DECLARE f text; BEGIN
  FOREACH f IN ARRAY ARRAY['api_ads_consent_record(text,text,text,text,text,text,text)', 'api_ads_lead_set_stage(uuid,text,text,jsonb)',
    'api_ads_lead_assign(uuid,uuid,text)', 'api_ads_lead_log_contact(uuid,text,text,text)', 'api_ads_lead_quarantine(uuid,boolean,text)',
    'api_ads_lead_list(text,text,boolean,integer,integer)', 'api_ads_lead(uuid)', 'api_ads_counsellor_credit(text,date,date)',
    'api_ads_student_links_propose()', 'api_ads_student_link_decide(bigint,boolean,text)', 'api_ads_retention_run(boolean,timestamptz)',
    'api_ads_retention_policy_set(text,integer,boolean,text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
DO $$ DECLARE f text; BEGIN
  FOREACH f IN ARRAY ARRAY['ads_phone_e164(text)', 'ads_phone_kind(text)', 'ads_email_norm(text)', 'ads_jtext(jsonb,text,integer)', 'ads_url_host(text)',
    'ads_touch_from(jsonb)', 'ads_touch_is_ads(jsonb)', 'ads_touch_is_non_direct(jsonb)', 'ads_ingest_enquiry(jsonb,text)', 'ads_consent_status(text,text,text)',
    'ads_consent_allows(text,text,text)', 'ads_role()', 'ads_require_lead_edit()', 'ads_student_link_propose()',
    'ads_retention_candidates(timestamptz)', 'ads_append_only()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION crm_private.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;
-- API functions run as their owner (SECURITY DEFINER) and call these internally; ads_require_* checks stay callable.
GRANT EXECUTE ON FUNCTION crm_private.ads_role(), crm_private.ads_require_lead_edit() TO authenticated;
