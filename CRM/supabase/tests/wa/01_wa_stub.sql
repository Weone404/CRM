-- Local test harness only (never run on Supabase): the CRM tables 150 reads, shaped as they are on Supabase.
-- Applied after ../amazon/00_supabase_stub.sql (Supabase roles, vault, employee, crm_private helpers).
CREATE TABLE public.lead (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, phone text NOT NULL, email text, address text,
  course_interest text, utm_source text, utm_medium text, utm_campaign text, status text DEFAULT 'new',
  assigned_to uuid, created_at timestamptz DEFAULT now(), first_contacted_at timestamptz, dedup_key text NOT NULL UNIQUE,
  segment text NOT NULL DEFAULT 'aviation' CHECK (segment IN ('aviation', 'charter')), closed boolean DEFAULT false);
CREATE TABLE public.ads_lead (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline text NOT NULL CHECK (pipeline IN ('pilot_training', 'charter')),
  name text NOT NULL, phone_e164 text NOT NULL, email text, stage text NOT NULL DEFAULT 'lead_created',
  quarantined boolean NOT NULL DEFAULT false, course_interest text, first_touch jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE TABLE public.lead_note (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id uuid REFERENCES public.lead(id) ON DELETE CASCADE, ads_lead_id uuid REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(btrim(body)) BETWEEN 1 AND 4000), created_by uuid REFERENCES public.employee(id),
  created_at timestamptz NOT NULL DEFAULT now(), CONSTRAINT lead_note_one_lead CHECK ((lead_id IS NULL) <> (ads_lead_id IS NULL)));
CREATE TABLE public.ads_config (key text PRIMARY KEY, value text, updated_at timestamptz DEFAULT now());
INSERT INTO public.ads_config (key, value) VALUES ('meta_api_version', 'v26.0');
CREATE TABLE public.amazon_push_subs (id bigserial PRIMARY KEY, employee_id uuid NOT NULL, endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL, auth text NOT NULL, device text, fails int NOT NULL DEFAULT 0, last_ok_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());
