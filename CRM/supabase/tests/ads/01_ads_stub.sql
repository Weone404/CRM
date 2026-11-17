-- Local test harness only (never run on Supabase): CRM lead tables that 076 reads.
-- Applied after ../amazon/00_supabase_stub.sql (Supabase roles, vault, employee, crm_private helpers).
CREATE TYPE public.disposition_enum AS ENUM ('Connected', 'Not reachable', 'Wrong number', 'Interested', 'Not interested', 'Callback');
CREATE TYPE public.closure_outcome_enum AS ENUM ('admission_completed', 'admission_aborted', 'booking_confirmed', 'booking_lost');
CREATE TABLE public.lead (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, phone text NOT NULL DEFAULT '0',
  utm_source text, utm_medium text, utm_campaign text, status text DEFAULT 'new',
  created_at timestamptz DEFAULT now(), segment text NOT NULL DEFAULT 'aviation',
  is_eligible boolean, closure_outcome public.closure_outcome_enum);
CREATE TABLE public.contact_attempt (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), lead_id uuid NOT NULL REFERENCES public.lead(id) ON DELETE CASCADE,
  staff_id uuid, channel text DEFAULT 'phone', attempted_at timestamptz DEFAULT now(),
  disposition public.disposition_enum, note text, connected boolean DEFAULT false);


-- Normal website-lead intake (046 norm_phone, 052 ingest_website_lead, copied verbatim) for 101's organic Meta form leads.
ALTER TABLE public.lead ADD COLUMN IF NOT EXISTS email text, ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS course_interest text, ADD COLUMN IF NOT EXISTS dedup_key text UNIQUE, ADD COLUMN IF NOT EXISTS charter_details jsonb;
CREATE TABLE IF NOT EXISTS public.audit_log (id bigserial PRIMARY KEY, actor uuid, action text, entity text, payload jsonb, at timestamptz DEFAULT now());
CREATE OR REPLACE FUNCTION crm_private.norm_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN d ~ '^91\d{10}$' THEN '+' || d
    WHEN length(d) = 10 THEN '+91' || d
    ELSE '+' || d
  END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x
$$;
CREATE OR REPLACE FUNCTION crm_private.ingest_website_lead(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE raw_phone text := left(btrim(coalesce(p->>'phone', '')), 30); key text; ex uuid; lid uuid;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RETURN jsonb_build_object('error', 'Expected a JSON object'); END IF;
  IF length(regexp_replace(raw_phone, '\D', '', 'g')) NOT BETWEEN 7 AND 15 THEN
    RETURN jsonb_build_object('error', 'A valid phone number is required');
  END IF;
  key := crm_private.norm_phone(raw_phone);
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));      -- two identical submits at once -> one lead
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

-- 104 (Strategy, archive, speed-to-lead) reads these CRM columns and tables, as they are on Supabase.
ALTER TABLE public.lead ADD COLUMN IF NOT EXISTS assigned_to uuid, ADD COLUMN IF NOT EXISTS first_contacted_at timestamptz;
ALTER TABLE public.employee ADD COLUMN IF NOT EXISTS email text;
CREATE TABLE IF NOT EXISTS public.amazon_push_subs (id bigserial PRIMARY KEY, employee_id uuid NOT NULL, endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL, auth text NOT NULL, device text, fails int NOT NULL DEFAULT 0, last_ok_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());
CREATE OR REPLACE FUNCTION crm_private.normalize_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '') $$;
