-- 045: fixes for 043 (applied live as crm_042_fix_login_record + crm_043_fix_ai_integration_fns).
-- Parameter names clashed with column names inside ON CONFLICT / UPDATE.
CREATE OR REPLACE FUNCTION crm_private.login_record(identifier text, ok boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE k text := lower(trim(login_record.identifier));
BEGIN
  IF login_record.ok THEN
    DELETE FROM crm_private.login_attempt la WHERE la.identifier = k;
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
REVOKE ALL ON FUNCTION crm_private.login_record(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION crm_private.login_record(text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.ai_integration_set(provider text, api_key text, enabled boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE p text := lower(trim(ai_integration_set.provider));
        k text := trim(ai_integration_set.api_key);
        en boolean := coalesce(ai_integration_set.enabled, true);
        vid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  IF p !~ '^[a-z][a-z0-9_]{1,30}$' THEN RAISE EXCEPTION 'Invalid provider name'; END IF;
  IF length(k) < 8 THEN RAISE EXCEPTION 'API key looks too short'; END IF;
  SELECT ai.vault_id INTO vid FROM crm_private.ai_integration ai WHERE ai.provider = p;
  IF vid IS NULL THEN
    vid := vault.create_secret(k, 'crm_ai_' || p, 'CRM AI integration key: ' || p);
  ELSE
    PERFORM vault.update_secret(vid, k);
  END IF;
  INSERT INTO crm_private.ai_integration AS a (provider, vault_id, last4, enabled, updated_at, updated_by)
  VALUES (p, vid, right(k, 4), en, now(), crm_private.current_employee_id())
  ON CONFLICT (provider) DO UPDATE
    SET vault_id = EXCLUDED.vault_id, last4 = EXCLUDED.last4, enabled = EXCLUDED.enabled,
        updated_at = now(), updated_by = EXCLUDED.updated_by;
END $$;

CREATE OR REPLACE FUNCTION public.ai_integration_toggle(provider text, enabled boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE p text := lower(trim(ai_integration_toggle.provider)); en boolean := ai_integration_toggle.enabled;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  UPDATE crm_private.ai_integration a
     SET enabled = en, updated_at = now(), updated_by = crm_private.current_employee_id()
   WHERE a.provider = p;
END $$;

CREATE OR REPLACE FUNCTION public.ai_integration_delete(provider text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
#variable_conflict use_column
DECLARE p text := lower(trim(ai_integration_delete.provider)); vid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can change AI integrations' USING ERRCODE = '42501';
  END IF;
  DELETE FROM crm_private.ai_integration a WHERE a.provider = p RETURNING a.vault_id INTO vid;
  IF vid IS NOT NULL THEN DELETE FROM vault.secrets s WHERE s.id = vid; END IF;
END $$;

REVOKE ALL ON FUNCTION public.ai_integration_set(text, text, boolean), public.ai_integration_toggle(text, boolean),
  public.ai_integration_delete(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ai_integration_set(text, text, boolean), public.ai_integration_toggle(text, boolean),
  public.ai_integration_delete(text) TO authenticated;
