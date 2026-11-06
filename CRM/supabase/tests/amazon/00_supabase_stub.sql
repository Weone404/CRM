-- Local test harness only (never run on Supabase): the minimum of Supabase + earlier CRM migrations
-- that 071/072 depend on, so the Amazon SQL can be tested on a plain Postgres.
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE SCHEMA auth; CREATE SCHEMA vault; CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT current_user::text $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE TABLE vault.secrets (id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), name text UNIQUE, description text,
  secret text, updated_at timestamptz DEFAULT now());
CREATE VIEW vault.decrypted_secrets AS SELECT id, name, description, secret AS decrypted_secret, updated_at FROM vault.secrets;
CREATE FUNCTION vault.create_secret(new_secret text, new_name text, new_description text) RETURNS uuid
LANGUAGE sql AS $$ INSERT INTO vault.secrets (name, description, secret) VALUES (new_name, new_description, new_secret) RETURNING id $$;
CREATE FUNCTION vault.update_secret(secret_id uuid, new_secret text) RETURNS void
LANGUAGE sql AS $$ UPDATE vault.secrets SET secret = new_secret, updated_at = now() WHERE id = secret_id $$;
REVOKE ALL ON ALL TABLES IN SCHEMA vault FROM PUBLIC;

CREATE TABLE public.employee (id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), name text, department text,
  active boolean DEFAULT true, auth_user_id uuid UNIQUE);
CREATE TABLE public.job_lease (name text PRIMARY KEY, holder text, lease_until timestamptz);

CREATE SCHEMA crm_private; GRANT USAGE ON SCHEMA crm_private TO authenticated;
CREATE FUNCTION crm_private.current_employee_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.id FROM public.employee e WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active LIMIT 1 $$;
CREATE FUNCTION crm_private.current_department() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.department FROM public.employee e WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active LIMIT 1 $$;
CREATE FUNCTION crm_private.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(crm_private.current_department() = 'Admin', false) $$;
CREATE FUNCTION crm_private.take_lease(p_name text, p_seconds int) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH t AS (INSERT INTO public.job_lease (name, holder, lease_until) VALUES (p_name, 'supabase', now() + make_interval(secs => p_seconds))
    ON CONFLICT (name) DO UPDATE SET holder = EXCLUDED.holder, lease_until = EXCLUDED.lease_until
      WHERE public.job_lease.lease_until < now() OR public.job_lease.holder = EXCLUDED.holder RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM t) $$;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
-- Supabase gives service_role full rights on new public tables/sequences by default.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
