-- 043: login resolution, login throttling, one-time provisioning token and
--      AI integration keys (stored encrypted in Supabase Vault).
--
-- Additive. Nothing here is reachable by `anon`; the login helpers are only
-- callable by the service role (used inside the `crm-auth` Edge Function).
-- Reversible: DROP the objects listed at the end.

-- 1. Resolve "login ID / phone / email" to the Supabase Auth email ------------
CREATE OR REPLACE FUNCTION crm_private.normalize_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '')
$$;

CREATE OR REPLACE FUNCTION crm_private.resolve_login(identifier text)
RETURNS TABLE (auth_email text, person_type text, person_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH id AS (SELECT lower(trim(identifier)) AS v,
                     crm_private.normalize_phone(identifier) AS ph)
  SELECT u.email::text, 'employee', e.id
  FROM public.employee e JOIN auth.users u ON u.id = e.auth_user_id, id
  WHERE e.active = true
    AND (lower(e.login_id) = id.v
         OR lower(coalesce(e.email, '')) = id.v
         OR (id.ph IS NOT NULL AND length(id.ph) >= 9 AND crm_private.normalize_phone(e.phone) = id.ph))
  UNION ALL
  SELECT u.email::text, 'student', s.id
  FROM public.student s JOIN auth.users u ON u.id = s.auth_user_id, id
  WHERE s.login_enabled IS NOT FALSE
    AND id.ph IS NOT NULL AND length(id.ph) >= 9
    AND crm_private.normalize_phone(s.mobile) = id.ph
  LIMIT 2
$$;

-- 2. Login throttling: 10 failed attempts per identifier -> 15-minute lock ----
CREATE TABLE IF NOT EXISTS crm_private.login_attempt (
  identifier   text PRIMARY KEY,
  failures     int NOT NULL DEFAULT 0,
  locked_until timestamptz,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION crm_private.login_check(identifier text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT EXISTS (SELECT 1 FROM crm_private.login_attempt a
                     WHERE a.identifier = lower(trim(login_check.identifier))
                       AND a.locked_until > now())
$$;

CREATE OR REPLACE FUNCTION crm_private.login_record(identifier text, ok boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text := lower(trim(identifier));
BEGIN
  IF ok THEN
    DELETE FROM crm_private.login_attempt WHERE login_attempt.identifier = k;
  ELSE
    INSERT INTO crm_private.login_attempt AS a (identifier, failures, updated_at)
    VALUES (k, 1, now())
    ON CONFLICT (identifier) DO UPDATE
      SET failures = CASE WHEN a.updated_at < now() - interval '15 minutes' THEN 1 ELSE a.failures + 1 END,
          locked_until = CASE WHEN (CASE WHEN a.updated_at < now() - interval '15 minutes' THEN 1 ELSE a.failures + 1 END) >= 10
                              THEN now() + interval '15 minutes' ELSE NULL END,
          updated_at = now();
  END IF;
END $$;

-- 3. One-time provisioning token (bootstrap before any admin can sign in) ------
CREATE TABLE IF NOT EXISTS crm_private.bootstrap_token (
  token_hash text PRIMARY KEY,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz
);

CREATE OR REPLACE FUNCTION crm_private.use_bootstrap_token(token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  UPDATE crm_private.bootstrap_token
     SET used_at = now()
   WHERE token_hash = encode(extensions.digest(token, 'sha256'), 'hex')
     AND used_at IS NULL AND expires_at > now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;

-- Used by provisioning: everyone without a login yet, with their temporary password source.
CREATE OR REPLACE FUNCTION crm_private.people_to_provision()
RETURNS TABLE (person_type text, person_id uuid, name text, email text, phone_digits text, password_hash text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 'employee', e.id, e.name, nullif(lower(trim(e.email)), ''),
         nullif(regexp_replace(coalesce(e.phone, ''), '\D', '', 'g'), ''), e.password_hash
  FROM public.employee e WHERE e.active = true AND e.auth_user_id IS NULL
  UNION ALL
  SELECT 'student', s.id, concat_ws(' ', s.first_name, s.last_name), NULL,
         nullif(regexp_replace(coalesce(s.mobile, ''), '\D', '', 'g'), ''), NULL
  FROM public.student s WHERE s.auth_user_id IS NULL
$$;

CREATE OR REPLACE FUNCTION crm_private.link_auth_user(person_type text, person_id uuid, auth_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF person_type = 'employee' THEN
    UPDATE public.employee SET auth_user_id = auth_id WHERE id = person_id AND auth_user_id IS NULL;
  ELSIF person_type = 'student' THEN
    UPDATE public.student SET auth_user_id = auth_id WHERE id = person_id AND auth_user_id IS NULL;
  END IF;
END $$;

-- 4. AI integration keys (Admin only; values encrypted in Vault, never readable back)
CREATE TABLE IF NOT EXISTS crm_private.ai_integration (
  provider    text PRIMARY KEY CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  vault_id    uuid NOT NULL,
  last4       text NOT NULL,
  enabled     boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid
);

CREATE OR REPLACE FUNCTION public.ai_integrations_list()
RETURNS TABLE (provider text, last4 text, enabled boolean, updated_at timestamptz, updated_by_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can view AI integrations' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT a.provider, a.last4, a.enabled, a.updated_at, e.name
    FROM crm_private.ai_integration a LEFT JOIN public.employee e ON e.id = a.updated_by
    ORDER BY a.provider;
END $$;

CREATE OR REPLACE FUNCTION public.ai_integration_set(provider text, api_key text, enabled boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p text := lower(trim(provider)); k text := trim(api_key); vid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  IF p !~ '^[a-z][a-z0-9_]{1,30}$' THEN RAISE EXCEPTION 'Invalid provider name'; END IF;
  IF length(k) < 8 THEN RAISE EXCEPTION 'API key looks too short'; END IF;
  SELECT a.vault_id INTO vid FROM crm_private.ai_integration a WHERE a.provider = p;
  IF vid IS NULL THEN
    vid := vault.create_secret(k, 'crm_ai_' || p, 'CRM AI integration key: ' || p);
  ELSE
    PERFORM vault.update_secret(vid, k);
  END IF;
  INSERT INTO crm_private.ai_integration AS a (provider, vault_id, last4, enabled, updated_at, updated_by)
  VALUES (p, vid, right(k, 4), enabled, now(), crm_private.current_employee_id())
  ON CONFLICT (provider) DO UPDATE
    SET vault_id = EXCLUDED.vault_id, last4 = EXCLUDED.last4, enabled = EXCLUDED.enabled,
        updated_at = now(), updated_by = EXCLUDED.updated_by;
END $$;

CREATE OR REPLACE FUNCTION public.ai_integration_toggle(provider text, enabled boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  UPDATE crm_private.ai_integration a
     SET enabled = ai_integration_toggle.enabled, updated_at = now(),
         updated_by = crm_private.current_employee_id()
   WHERE a.provider = lower(trim(ai_integration_toggle.provider));
END $$;

CREATE OR REPLACE FUNCTION public.ai_integration_delete(provider text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE vid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  DELETE FROM crm_private.ai_integration a WHERE a.provider = lower(trim(ai_integration_delete.provider))
  RETURNING a.vault_id INTO vid;
  IF vid IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = vid; END IF;
END $$;

-- Edge Functions (service role) read a key for server-side AI calls.
CREATE OR REPLACE FUNCTION crm_private.get_ai_key(provider text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT d.decrypted_secret
  FROM crm_private.ai_integration a JOIN vault.decrypted_secrets d ON d.id = a.vault_id
  WHERE a.provider = lower(trim(get_ai_key.provider)) AND a.enabled
$$;

-- 5. Privileges -----------------------------------------------------------------
-- Login/provisioning/key-reading helpers: service role only.
REVOKE ALL ON FUNCTION crm_private.resolve_login(text), crm_private.login_check(text),
  crm_private.login_record(text, boolean), crm_private.use_bootstrap_token(text),
  crm_private.people_to_provision(), crm_private.link_auth_user(text, uuid, uuid),
  crm_private.get_ai_key(text), crm_private.normalize_phone(text)
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA crm_private TO service_role;
GRANT EXECUTE ON FUNCTION crm_private.resolve_login(text), crm_private.login_check(text),
  crm_private.login_record(text, boolean), crm_private.use_bootstrap_token(text),
  crm_private.people_to_provision(), crm_private.link_auth_user(text, uuid, uuid),
  crm_private.get_ai_key(text), crm_private.normalize_phone(text)
  TO service_role;
REVOKE ALL ON crm_private.login_attempt, crm_private.bootstrap_token, crm_private.ai_integration
  FROM PUBLIC, anon, authenticated;

-- AI settings RPCs: signed-in users may call them; each checks Admin itself.
REVOKE ALL ON FUNCTION public.ai_integrations_list(), public.ai_integration_set(text, text, boolean),
  public.ai_integration_toggle(text, boolean), public.ai_integration_delete(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ai_integrations_list(), public.ai_integration_set(text, text, boolean),
  public.ai_integration_toggle(text, boolean), public.ai_integration_delete(text) TO authenticated;

-- DOWN (manual):
--   DROP FUNCTION public.ai_integrations_list(), public.ai_integration_set(text,text,boolean),
--     public.ai_integration_toggle(text,boolean), public.ai_integration_delete(text);
--   DROP TABLE crm_private.ai_integration, crm_private.login_attempt, crm_private.bootstrap_token;
--   DROP FUNCTION crm_private.resolve_login(text), crm_private.login_check(text), crm_private.login_record(text,boolean),
--     crm_private.use_bootstrap_token(text), crm_private.people_to_provision(), crm_private.link_auth_user(text,uuid,uuid),
--     crm_private.get_ai_key(text), crm_private.normalize_phone(text);
