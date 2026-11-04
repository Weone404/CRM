-- 056: Settings > Connections (Admin only). Shows the tokens outside systems use to send data to the CRM,
-- and lets Admin replace one if it leaks. Tokens stay in Supabase Vault; every view and change is audit-logged.
CREATE OR REPLACE FUNCTION crm_private.connection_secret(p_id text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_id WHEN 'charter' THEN 'crm_charter_ingest_token'
                   WHEN 'hikvision' THEN 'crm_attendance_ingest_token'
                   WHEN 'partner' THEN 'crm_partner_api_token' END
$$;

-- List: last 4 characters and date only.
CREATE OR REPLACE FUNCTION public.api_connections() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can view connections' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT json_object_agg(c.id, json_build_object(
      'last4', right(s.decrypted_secret, 4), 'updated_at', s.updated_at))
    FROM (VALUES ('charter'), ('hikvision'), ('partner')) c(id)
    JOIN vault.decrypted_secrets s ON s.name = crm_private.connection_secret(c.id)), '{}');
END $$;

-- Full token, for copying into the outside system.
CREATE OR REPLACE FUNCTION public.api_connection_token(p_id text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_name text := crm_private.connection_secret(p_id); v_tok text;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can view connections' USING ERRCODE = '42501'; END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Unknown connection' USING ERRCODE = 'PT404'; END IF;
  SELECT decrypted_secret INTO v_tok FROM vault.decrypted_secrets WHERE name = v_name;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (crm_private.current_employee_id(), 'connection_token_viewed', 'connection', jsonb_build_object('id', p_id));
  RETURN v_tok;
END $$;

-- New token. The old one stops working at once, so the outside system must be updated.
CREATE OR REPLACE FUNCTION public.api_connection_rotate(p_id text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_name text := crm_private.connection_secret(p_id); v_sid uuid; v_tok text;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change connections' USING ERRCODE = '42501'; END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Unknown connection' USING ERRCODE = 'PT404'; END IF;
  SELECT id INTO v_sid FROM vault.secrets WHERE name = v_name;
  IF v_sid IS NULL THEN RAISE EXCEPTION 'Token not found' USING ERRCODE = 'PT404'; END IF;
  v_tok := translate(encode(extensions.gen_random_bytes(36), 'base64'), '+/', '-_');
  PERFORM vault.update_secret(v_sid, v_tok);
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (crm_private.current_employee_id(), 'connection_token_rotated', 'connection', jsonb_build_object('id', p_id));
  RETURN v_tok;
END $$;

REVOKE ALL ON FUNCTION crm_private.connection_secret(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_connections() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_connection_token(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_connection_rotate(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_connections() TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_connection_token(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_connection_rotate(text) TO authenticated;
