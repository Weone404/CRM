-- 044: API-reachable wrappers for the crm_private helpers, executable ONLY by the
-- service role (the crm-auth Edge Function). crm_private is not exposed through the API.
CREATE OR REPLACE FUNCTION public.svc_resolve_login(identifier text)
RETURNS TABLE (auth_email text, person_type text, person_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT * FROM crm_private.resolve_login(identifier) $$;
CREATE OR REPLACE FUNCTION public.svc_login_check(identifier text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.login_check(identifier) $$;
CREATE OR REPLACE FUNCTION public.svc_login_record(identifier text, ok boolean) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.login_record(identifier, ok) $$;
CREATE OR REPLACE FUNCTION public.svc_use_bootstrap_token(token text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.use_bootstrap_token(token) $$;
CREATE OR REPLACE FUNCTION public.svc_people_to_provision()
RETURNS TABLE (person_type text, person_id uuid, name text, email text, phone_digits text, password_hash text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT * FROM crm_private.people_to_provision() $$;
CREATE OR REPLACE FUNCTION public.svc_link_auth_user(person_type text, person_id uuid, auth_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.link_auth_user(person_type, person_id, auth_id) $$;
CREATE OR REPLACE FUNCTION public.svc_get_ai_key(provider text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.get_ai_key(provider) $$;
CREATE OR REPLACE FUNCTION public.svc_person_profile(auth_id uuid)
RETURNS TABLE (person_type text, person_id uuid, name text, department text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 'employee', e.id, e.name, e.department::text FROM public.employee e WHERE e.auth_user_id = auth_id AND e.active
  UNION ALL
  SELECT 'student', s.id, concat_ws(' ', s.first_name, s.last_name), NULL FROM public.student s WHERE s.auth_user_id = auth_id
  LIMIT 1
$$;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.svc_resolve_login(text)','public.svc_login_check(text)',
    'public.svc_login_record(text, boolean)','public.svc_use_bootstrap_token(text)',
    'public.svc_people_to_provision()','public.svc_link_auth_user(text, uuid, uuid)',
    'public.svc_get_ai_key(text)','public.svc_person_profile(uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
