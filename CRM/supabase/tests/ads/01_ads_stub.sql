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
