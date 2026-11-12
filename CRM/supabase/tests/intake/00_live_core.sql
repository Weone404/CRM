-- Local test harness only (never run on Supabase). Copies of the LIVE production definitions
-- (read from project syytqcadmtgowckdnbqh on 2026-11-12) of everything 085 touches or calls:
-- lead/student/employee/audit_log/contact_attempt tables, the intake functions and ADS access helpers.
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE SCHEMA auth; CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
-- Supabase default: new public functions are executable by anon/authenticated unless revoked.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

CREATE TYPE public.closure_outcome_enum AS ENUM ('admission_completed','admission_aborted','booking_confirmed','booking_lost');
CREATE TYPE public.department_enum AS ENUM ('Admin','IT','Sales','Instructors');
CREATE TYPE public.disposition_enum AS ENUM ('Connected','Not reachable','Wrong number','Interested','Not interested','Callback');

CREATE TABLE public.employee (id uuid DEFAULT uuid_generate_v4() PRIMARY KEY, name text NOT NULL, phone text NOT NULL, email text,
  permissions jsonb DEFAULT '{}'::jsonb, active boolean DEFAULT true, password_hash text NOT NULL, created_at timestamptz DEFAULT now(),
  employee_id varchar, joining_date date, status varchar(20) DEFAULT 'active', job_role varchar(100), address text,
  pay_scale_encrypted text, date_of_leaving date, login_pin varchar(4), department public.department_enum NOT NULL,
  paid_leave_quota integer DEFAULT 0, monthly_salary numeric(12,2), login_id varchar(50) NOT NULL, date_of_birth date,
  auth_user_id uuid, pay_scale_vault_id uuid);
CREATE TABLE public.lead (id uuid DEFAULT uuid_generate_v4() PRIMARY KEY, name text NOT NULL, phone text NOT NULL, email text, address text,
  course_interest text, utm_source text, utm_medium text, utm_campaign text, status text DEFAULT 'new',
  assigned_to uuid REFERENCES public.employee(id), created_at timestamptz DEFAULT now(), first_contacted_at timestamptz,
  dedup_key text NOT NULL UNIQUE, last_note text, parked boolean DEFAULT false, closed boolean DEFAULT false,
  closure_outcome public.closure_outcome_enum, guardian_name text, qualifications jsonb DEFAULT '[]'::jsonb, is_eligible boolean,
  nios_interested boolean, interest_track text, segment text DEFAULT 'aviation' NOT NULL CHECK (segment IN ('aviation','charter')),
  charter_details jsonb);
CREATE TABLE public.student (id uuid DEFAULT uuid_generate_v4() PRIMARY KEY, first_name text NOT NULL, middle_name text, last_name text,
  guardian_name text, mobile text NOT NULL, mobile_normalized text NOT NULL UNIQUE, emergency_contact text, address text, course text,
  admission_date date DEFAULT CURRENT_DATE, computer_number text, lead_id uuid REFERENCES public.lead(id), created_at timestamptz DEFAULT now(),
  created_by uuid REFERENCES public.employee(id), updated_at timestamptz DEFAULT now(), login_pin_hash text, login_enabled boolean DEFAULT true,
  last_login_at timestamptz, date_of_birth date, auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL);
CREATE TABLE public.audit_log (id uuid DEFAULT uuid_generate_v4() PRIMARY KEY, actor uuid, action text NOT NULL, entity text NOT NULL,
  ts timestamptz DEFAULT now(), payload jsonb);
CREATE TABLE public.contact_attempt (id uuid DEFAULT uuid_generate_v4() PRIMARY KEY, lead_id uuid NOT NULL, staff_id uuid NOT NULL,
  channel text NOT NULL, attempted_at timestamptz DEFAULT now(), disposition public.disposition_enum, note text, connected boolean DEFAULT false);

CREATE SCHEMA crm_private; GRANT USAGE ON SCHEMA crm_private TO authenticated;
CREATE OR REPLACE FUNCTION crm_private.current_employee_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT e.id FROM public.employee e WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active = true LIMIT 1 $$;
CREATE OR REPLACE FUNCTION crm_private.current_department() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT e.department::text FROM public.employee e WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active = true LIMIT 1 $$;
CREATE OR REPLACE FUNCTION crm_private.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT coalesce(crm_private.current_department() = 'Admin', false) $$;
CREATE OR REPLACE FUNCTION crm_private.norm_phone(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE WHEN d ~ '^91\d{10}$' THEN '+' || d WHEN length(d) = 10 THEN '+91' || d ELSE '+' || d END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x $$;
CREATE OR REPLACE FUNCTION crm_private.charter_text(v jsonb, lim integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE WHEN v IS NULL OR jsonb_typeof(v) = 'null' THEN NULL
              ELSE nullif(left(btrim(CASE jsonb_typeof(v) WHEN 'string' THEN v #>> '{}' ELSE v::text END), lim), '') END $$;
CREATE OR REPLACE FUNCTION crm_private.valid_iso_date(s text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
BEGIN
  IF s IS NULL OR s !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN false; END IF;
  PERFORM s::date; RETURN true;
EXCEPTION WHEN others THEN RETURN false;
END $$;
CREATE OR REPLACE FUNCTION crm_private.charter_reference(lead_id uuid) RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT 'BMC-' || upper(left(replace(lead_id::text, '-', ''), 8)) $$;
CREATE OR REPLACE FUNCTION crm_private.validate_charter(d jsonb, require_date boolean) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE errs text[] := '{}'; name text; raw_phone text; digits text; origin text; dest text;
        dep text; pax_raw jsonb; pax int; email text; details jsonb; k text; lim int; v text;
        opt jsonb := '{"departureTime":5,"tripType":20,"returnDate":10,"aircraftPreference":40,"purpose":40,"additionalRequirements":2000,"sourcePath":200}';
BEGIN
  name := crm_private.charter_text(d->'name', 120);
  IF name IS NULL THEN errs := errs || 'name: Required'::text; END IF;
  raw_phone := coalesce(crm_private.charter_text(d->'phone', 30), '');
  digits := regexp_replace(raw_phone, '\D', '', 'g');
  IF length(digits) NOT BETWEEN 7 AND 15 THEN errs := errs || 'phone: Enter a valid phone number'::text; END IF;
  origin := crm_private.charter_text(d->'from', 200);
  dest := crm_private.charter_text(d->'to', 200);
  IF origin IS NULL THEN errs := errs || 'from: Required'::text; END IF;
  IF dest IS NULL THEN errs := errs || 'to: Required'::text; END IF;
  dep := crm_private.charter_text(d->'departureDate', 10);
  IF dep IS NOT NULL AND NOT crm_private.valid_iso_date(dep) THEN errs := errs || 'departureDate: Use YYYY-MM-DD'::text;
  ELSIF require_date AND dep IS NULL THEN errs := errs || 'departureDate: Required'::text; END IF;
  pax_raw := d->'passengers';
  IF pax_raw IS NULL OR jsonb_typeof(pax_raw) = 'null' OR (pax_raw #>> '{}') = '' THEN pax := NULL;
  ELSE
    BEGIN pax := (pax_raw #>> '{}')::numeric::int; EXCEPTION WHEN others THEN pax := -1; END;
  END IF;
  IF pax IS NOT NULL AND pax NOT BETWEEN 1 AND 500 THEN errs := errs || 'passengers: Between 1 and 500'::text; END IF;
  IF require_date AND pax IS NULL THEN errs := errs || 'passengers: Required'::text; END IF;
  email := crm_private.charter_text(d->'email', 200);
  IF email IS NOT NULL AND position('@' IN email) = 0 THEN errs := errs || 'email: Enter a valid email'::text; END IF;
  details := jsonb_build_object('from', origin, 'to', dest, 'departureDate', dep, 'passengers', pax);
  FOR k, lim IN SELECT key, value::int FROM jsonb_each_text(opt) LOOP
    v := crm_private.charter_text(d->k, lim);
    IF v IS NOT NULL THEN details := details || jsonb_build_object(k, v); END IF;
  END LOOP;
  IF details ? 'departureTime' AND (details->>'departureTime') !~ '^([01]\d|2[0-3]):[0-5]\d$' THEN
    errs := errs || 'departureTime: Use HH:MM'::text; END IF;
  IF details ? 'returnDate' AND NOT crm_private.valid_iso_date(details->>'returnDate') THEN
    errs := errs || 'returnDate: Use YYYY-MM-DD'::text; END IF;
  IF jsonb_typeof(d->'flexibleDates') = 'boolean' THEN details := details || jsonb_build_object('flexibleDates', d->'flexibleDates'); END IF;
  IF cardinality(errs) > 0 THEN
    RAISE EXCEPTION '%', errs[1] USING ERRCODE = 'PT400',
      DETAIL = (SELECT json_object(array_agg(split_part(e, ': ', 1) ORDER BY o), array_agg(split_part(e, ': ', 2) ORDER BY o))::text
                  FROM unnest(errs) WITH ORDINALITY AS u(e, o));
  END IF;
  RETURN jsonb_build_object('name', name, 'phone', crm_private.norm_phone(raw_phone), 'email', email, 'details', jsonb_strip_nulls(details));
END $$;
CREATE OR REPLACE FUNCTION crm_private.ingest_charter_lead(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE c jsonb; key text; ex record; lid uuid; det text;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('errors_json', '{"body": "Expected a JSON object"}');
  END IF;
  BEGIN
    c := crm_private.validate_charter(p, true);
  EXCEPTION WHEN SQLSTATE 'PT400' THEN
    GET STACKED DIAGNOSTICS det = PG_EXCEPTION_DETAIL;
    RETURN jsonb_build_object('errors_json', det);
  END;
  key := 'charter:' || (c->>'phone') || ':' || lower(coalesce(btrim(c->'details'->>'from'), '')) || '|'
         || lower(coalesce(btrim(c->'details'->>'to'), '')) || '|' || lower(coalesce(btrim(c->'details'->>'departureDate'), ''));
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));
  SELECT l.id, l.name INTO ex FROM public.lead l WHERE l.dedup_key = key;
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate', 'lead_id', ex.id, 'name', ex.name, 'reference', crm_private.charter_reference(ex.id));
  END IF;
  INSERT INTO public.lead (name, phone, email, course_interest, utm_source, utm_medium, utm_campaign, status, dedup_key, segment, charter_details)
  VALUES (c->>'name', c->>'phone', c->>'email', 'Charter', 'Book My Charter website', 'website', c->'details'->>'sourcePath',
          'new', key, 'charter', c->'details')
  RETURNING id INTO lid;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (NULL, 'create', 'lead', jsonb_build_object('lead_id', lid, 'segment', 'charter', 'source', 'Book My Charter website'));
  RETURN jsonb_build_object('status', 'created', 'lead_id', lid, 'reference', crm_private.charter_reference(lid));
END $$;
CREATE OR REPLACE FUNCTION crm_private.ingest_website_lead(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE raw_phone text := left(btrim(coalesce(p->>'phone', '')), 30); key text; ex uuid; lid uuid;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RETURN jsonb_build_object('error', 'Expected a JSON object'); END IF;
  IF length(regexp_replace(raw_phone, '\D', '', 'g')) NOT BETWEEN 7 AND 15 THEN
    RETURN jsonb_build_object('error', 'A valid phone number is required');
  END IF;
  key := crm_private.norm_phone(raw_phone);
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));
  SELECT l.id INTO ex FROM public.lead l WHERE l.dedup_key = key;
  IF FOUND THEN RETURN jsonb_build_object('status', 'duplicate', 'lead_id', ex); END IF;
  INSERT INTO public.lead (name, phone, email, address, course_interest, utm_source, utm_medium, utm_campaign, status, dedup_key)
  VALUES (left(btrim(p->>'name'), 120), raw_phone, left(btrim(p->>'email'), 200), left(btrim(p->>'address'), 500),
          left(btrim(p->>'course_interest'), 120), left(btrim(p->>'utm_source'), 200), left(btrim(p->>'utm_medium'), 200),
          left(btrim(p->>'utm_campaign'), 200), 'new', key)
  RETURNING id INTO lid;
  INSERT INTO public.audit_log (action, entity, payload)
  VALUES ('create', 'lead', jsonb_build_object('lead_id', lid, 'source', 'website'));
  RETURN jsonb_build_object('status', 'created', 'lead_id', lid);
END $$;
CREATE OR REPLACE FUNCTION public.svc_ingest_website_lead(payload jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT crm_private.ingest_website_lead(payload) $$;
CREATE OR REPLACE FUNCTION public.svc_ingest_charter_lead(payload jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT crm_private.ingest_charter_lead(payload) $$;
REVOKE ALL ON FUNCTION public.svc_ingest_website_lead(jsonb), public.svc_ingest_charter_lead(jsonb) FROM PUBLIC, anon, authenticated;

-- From 076_ads_module.sql (live).
CREATE TABLE public.ads_access (employee_id uuid PRIMARY KEY REFERENCES public.employee(id) ON DELETE CASCADE,
  can_approve boolean NOT NULL DEFAULT false, granted_by uuid, granted_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.ads_activity_log (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), actor uuid,
  actor_type text NOT NULL DEFAULT 'user', action text NOT NULL, entity text, entity_id text, details jsonb);
CREATE OR REPLACE FUNCTION crm_private.ads_can_view() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (SELECT 1 FROM public.ads_access a WHERE a.employee_id = crm_private.current_employee_id()) $$;
CREATE OR REPLACE FUNCTION crm_private.ads_require_view() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_view() THEN RAISE EXCEPTION 'You do not have access to the ADS section' USING ERRCODE = 'PT403'; END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.ads_require_admin() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can do this' USING ERRCODE = 'PT403'; END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.ads_log(p_action text, p_entity text, p_entity_id text, p_details jsonb,
  p_actor_type text DEFAULT 'user') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_activity_log (actor, actor_type, action, entity, entity_id, details)
  VALUES (crm_private.current_employee_id(), p_actor_type, p_action, p_entity, p_entity_id, p_details)
$$;
