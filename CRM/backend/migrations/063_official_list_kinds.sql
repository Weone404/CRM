-- 063: Official lists for more countries: Transport Canada Flight Training Units (tc_ftu), IRCC Designated Learning
-- Institutions (ircc_dli) and CASA Part 141/142 operators (casa_ato), besides the FAA Part 141 list. Saved web pages
-- (.html) accepted too. Upload history shows the last 40 uploads.
ALTER TABLE flightbridge.register_upload DROP CONSTRAINT IF EXISTS register_upload_kind_check;
ALTER TABLE flightbridge.register_upload ADD CONSTRAINT register_upload_kind_check CHECK (kind ~ '^[a-z0-9_]{2,40}$');

CREATE OR REPLACE FUNCTION public.api_fb_register_upload(p_data jsonb)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  v_kind text := p_data->>'kind'; v_name text := btrim(coalesce(p_data->>'filename', ''));
  v_b64 text := regexp_replace(coalesce(p_data->>'content_b64', ''), '\s', '', 'g'); v_bytes bytea; v_id bigint; v_sha text;
BEGIN
  IF v_kind IS NULL OR v_kind NOT IN ('faa_part141', 'tc_ftu', 'ircc_dli', 'casa_ato') THEN
    RAISE EXCEPTION 'Unknown list type' USING ERRCODE = 'PT422';
  END IF;
  IF v_name = '' OR length(v_name) > 200 OR v_name !~* '\.(csv|xlsx|txt|tsv|html|htm)$' THEN
    RAISE EXCEPTION 'Choose a CSV, Excel (.xlsx) or saved web page (.html) file' USING ERRCODE = 'PT422';
  END IF;
  IF v_b64 = '' THEN RAISE EXCEPTION 'The file is empty' USING ERRCODE = 'PT422'; END IF;
  IF length(v_b64) > 14000000 THEN RAISE EXCEPTION 'The file is too large (10 MB at most)' USING ERRCODE = 'PT422'; END IF;
  BEGIN
    v_bytes := decode(v_b64, 'base64');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'The file could not be read' USING ERRCODE = 'PT422';
  END;
  v_sha := encode(extensions.digest(v_bytes, 'sha256'), 'hex');
  IF EXISTS (SELECT 1 FROM flightbridge.register_upload WHERE sha256 = v_sha AND status IN ('pending', 'imported')
             AND uploaded_at > now() - interval '1 day') THEN
    RAISE EXCEPTION 'This same file was already uploaded today' USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO flightbridge.register_upload (kind, filename, content_b64, sha256, uploaded_by)
  VALUES (v_kind, v_name, v_b64, v_sha, eid) RETURNING id INTO v_id;
  PERFORM crm_private.fb_audit(eid, 'register_uploaded', 'register', 'upload/' || v_id,
                               jsonb_build_object('kind', v_kind, 'filename', v_name, 'bytes', length(v_bytes), 'sha256', v_sha));
  RETURN json_build_object('id', v_id, 'status', 'pending');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_register_uploads()
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x ORDER BY x.uploaded_at DESC) FROM (
    SELECT u.id, u.kind, u.filename, u.uploaded_at, e.name AS uploaded_by, u.status, u.result, u.processed_at
      FROM flightbridge.register_upload u LEFT JOIN public.employee e ON e.id = u.uploaded_by
     ORDER BY u.uploaded_at DESC LIMIT 40) x), '[]');
END $$;
REVOKE ALL ON FUNCTION public.api_fb_register_upload(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_fb_register_uploads() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_register_upload(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_register_uploads() TO authenticated;
