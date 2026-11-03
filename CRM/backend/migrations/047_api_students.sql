-- 047: Students module + student portal on Supabase (port of the Render endpoints).
--
-- Documents move from Cloudflare R2 to a private Supabase Storage bucket
-- (`student-documents`, 10 MB, JPEG/PNG only). There were 0 documents in R2, so
-- nothing needs copying. `student_document.r2_key` now holds the Storage path.
-- Errors use SQLSTATE 'PTnnn' -> HTTP status nnn (same detail messages as Render).

-- Storage bucket + access rules ---------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('student-documents', 'student-documents', false, 10485760, ARRAY['image/jpeg', 'image/png'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png'];

DROP POLICY IF EXISTS crm_student_docs_staff ON storage.objects;
CREATE POLICY crm_student_docs_staff ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'student-documents' AND (SELECT crm_private.is_sales_or_admin()))
  WITH CHECK (bucket_id = 'student-documents' AND (SELECT crm_private.is_sales_or_admin()));

-- A student may read and upload only inside students/<their own id>/.
DROP POLICY IF EXISTS crm_student_docs_own_read ON storage.objects;
DROP POLICY IF EXISTS crm_student_docs_own_insert ON storage.objects;
CREATE POLICY crm_student_docs_own_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'student-documents'
         AND (storage.foldername(name))[1] = 'students'
         AND (storage.foldername(name))[2] = (SELECT crm_private.current_student_id())::text);
CREATE POLICY crm_student_docs_own_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'student-documents'
         AND (storage.foldername(name))[1] = 'students'
         AND (storage.foldername(name))[2] = (SELECT crm_private.current_student_id())::text);

-- Helpers -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.student_doc_types() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['photo_id_proof', 'passport_photo', 'signature',
               'marksheet_10', 'certificate_10', 'marksheet_12', 'certificate_12',
               'board_verification_10', 'board_verification_12',
               'passport', 'i20_admission_letter', 'medical']
$$;

CREATE OR REPLACE FUNCTION crm_private.require_students_access() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  RETURN crm_private.require_sales_or_admin('Students access requires Admin or Sales department');
END $$;

CREATE OR REPLACE FUNCTION crm_private.require_student() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE sid uuid := crm_private.current_student_id();
BEGIN
  IF sid IS NULL THEN RAISE EXCEPTION 'Could not validate credentials' USING ERRCODE = 'PT401'; END IF;
  RETURN sid;
END $$;

-- "" -> NULL (HTML forms send empty strings for untouched optional inputs).
CREATE OR REPLACE FUNCTION crm_private.blank(v text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT nullif(btrim(v), '') $$;

CREATE OR REPLACE FUNCTION crm_private.check_dob(raw text) RETURNS date
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE d date; today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF crm_private.blank(raw) IS NULL THEN RETURN NULL; END IF;
  BEGIN d := left(raw, 10)::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Date of birth must be a valid date (YYYY-MM-DD)' USING ERRCODE = 'PT400';
  END;
  IF d > today THEN RAISE EXCEPTION 'Date of birth cannot be in the future' USING ERRCODE = 'PT400'; END IF;
  IF d < (today - interval '100 years')::date THEN
    RAISE EXCEPTION 'Date of birth cannot be more than 100 years ago' USING ERRCODE = 'PT400';
  END IF;
  RETURN d;
END $$;

-- Port of validate_student_mobile(): 10-digit Indian mobile starting 6-9.
CREATE OR REPLACE FUNCTION crm_private.check_student_mobile(raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE d text := regexp_replace(coalesce(raw, ''), '\D', '', 'g');
BEGIN
  IF length(d) = 12 AND left(d, 2) = '91' THEN d := substr(d, 3);
  ELSIF length(d) = 11 AND left(d, 1) = '0' THEN d := substr(d, 2); END IF;
  IF length(d) <> 10 OR left(d, 1) NOT IN ('6', '7', '8', '9') THEN
    RAISE EXCEPTION 'Mobile must be a 10-digit Indian mobile number (starting 6-9)' USING ERRCODE = 'PT400';
  END IF;
  RETURN crm_private.norm_phone(d);
END $$;

CREATE OR REPLACE FUNCTION crm_private.require_text(p_data jsonb, field text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := crm_private.blank(p_data->>field);
BEGIN
  IF v IS NULL THEN RAISE EXCEPTION '% is required', field USING ERRCODE = 'PT400'; END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION crm_private.doc_json(d public.student_document) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'original_filename', d.original_filename,
                            'mime_type', d.mime_type, 'size_bytes', d.size_bytes, 'uploaded_at', d.uploaded_at)
$$;

GRANT EXECUTE ON FUNCTION crm_private.student_doc_types(), crm_private.require_students_access(),
  crm_private.require_student(), crm_private.blank(text), crm_private.check_dob(text),
  crm_private.check_student_mobile(text), crm_private.require_text(jsonb, text),
  crm_private.doc_json(public.student_document) TO authenticated;

-- GET /api/students?search= ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_students_list(p_search text DEFAULT '') RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE q text := btrim(coalesce(p_search, '')); lk text; total int := cardinality(crm_private.student_doc_types());
BEGIN
  PERFORM crm_private.require_students_access();
  lk := '%' || q || '%';
  RETURN coalesce((
    SELECT json_agg(json_build_object(
      'id', s.id, 'name', concat_ws(' ', nullif(s.first_name, ''), nullif(s.middle_name, ''), nullif(s.last_name, '')),
      'mobile', s.mobile, 'course', s.course, 'admission_date', s.admission_date,
      'computer_number', s.computer_number, 'date_of_birth', s.date_of_birth,
      'documents_complete', (SELECT count(DISTINCT d.doc_type) FROM public.student_document d WHERE d.student_id = s.id),
      'documents_total', total) ORDER BY s.created_at DESC)
    FROM public.student s
    WHERE q = '' OR s.first_name ILIKE lk OR s.last_name ILIKE lk OR s.middle_name ILIKE lk
          OR s.mobile ILIKE lk OR s.computer_number ILIKE lk OR s.course ILIKE lk
  ), '[]'::json);
END $$;

-- GET /api/students/prefill-leads ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_students_prefill_leads() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_students_access();
  RETURN coalesce((
    SELECT json_agg(json_build_object('id', l.id, 'name', l.name, 'guardian_name', l.guardian_name,
             'phone', l.phone, 'address', l.address, 'course_interest', l.course_interest) ORDER BY l.created_at DESC)
    FROM public.lead l WHERE l.closure_outcome = 'admission_completed'
  ), '[]'::json);
END $$;

-- GET /api/students/{id} -------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_student_get(p_id uuid) RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM crm_private.require_students_access();
  SELECT jsonb_build_object('id', s.id, 'first_name', s.first_name, 'middle_name', s.middle_name,
           'last_name', s.last_name, 'guardian_name', s.guardian_name, 'mobile', s.mobile,
           'emergency_contact', s.emergency_contact, 'address', s.address, 'course', s.course,
           'admission_date', s.admission_date, 'computer_number', s.computer_number, 'lead_id', s.lead_id,
           'created_at', s.created_at, 'date_of_birth', s.date_of_birth)
    INTO r FROM public.student s WHERE s.id = p_id;
  IF r IS NULL THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  RETURN (r || jsonb_build_object(
    'doc_types', to_jsonb(crm_private.student_doc_types()),
    'documents', coalesce((SELECT jsonb_object_agg(x.doc_type, x.j) FROM (
        SELECT DISTINCT ON (d.doc_type) d.doc_type::text AS doc_type, crm_private.doc_json(d) AS j
        FROM public.student_document d WHERE d.student_id = p_id
        ORDER BY d.doc_type, d.uploaded_at DESC) x), '{}'::jsonb)))::json;
END $$;

-- POST /api/students ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_student_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access();
        first text; mob text; emer text; dob date; dup record; sid uuid;
BEGIN
  first := crm_private.require_text(p_data, 'first_name');
  PERFORM crm_private.require_text(p_data, 'mobile');
  dob := crm_private.check_dob(p_data->>'date_of_birth');
  mob := crm_private.norm_phone(btrim(p_data->>'mobile'));
  emer := CASE WHEN crm_private.blank(p_data->>'emergency_contact') IS NOT NULL
               THEN crm_private.norm_phone(p_data->>'emergency_contact') END;
  SELECT s.id, s.first_name, s.last_name INTO dup FROM public.student s WHERE s.mobile_normalized = mob;
  IF dup.id IS NOT NULL THEN
    RETURN json_build_object('status', 'duplicate', 'student_id', dup.id,
                             'name', concat_ws(' ', nullif(dup.first_name, ''), nullif(dup.last_name, '')));
  END IF;
  INSERT INTO public.student (first_name, middle_name, last_name, guardian_name, mobile, mobile_normalized,
                              emergency_contact, address, course, admission_date, computer_number, lead_id,
                              date_of_birth, created_by)
  VALUES (first, crm_private.blank(p_data->>'middle_name'), crm_private.blank(p_data->>'last_name'),
          crm_private.blank(p_data->>'guardian_name'), mob, mob, emer, crm_private.blank(p_data->>'address'),
          crm_private.blank(p_data->>'course'),
          coalesce(crm_private.blank(p_data->>'admission_date')::date, (now() AT TIME ZONE 'Asia/Kolkata')::date),
          crm_private.blank(p_data->>'computer_number'), crm_private.blank(p_data->>'lead_id')::uuid, dob, eid)
  RETURNING id INTO sid;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'create', 'student', jsonb_build_object('student_id', sid));
  RETURN json_build_object('status', 'created', 'student_id', sid);
END $$;

-- PATCH /api/students/{id} -----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_student_update(p_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access();
        allowed text[] := ARRAY['first_name','middle_name','last_name','guardian_name','address','course',
                                'admission_date','computer_number','emergency_contact','date_of_birth','mobile'];
        changed text[]; mob text; dob date; n int;
BEGIN
  SELECT array_agg(k ORDER BY k) INTO changed FROM jsonb_object_keys(p_data) k WHERE k = ANY(allowed);
  IF changed IS NULL THEN RAISE EXCEPTION 'No editable fields provided' USING ERRCODE = 'PT400'; END IF;
  IF p_data ? 'first_name' THEN PERFORM crm_private.require_text(p_data, 'first_name'); END IF;
  IF p_data ? 'mobile' THEN
    PERFORM crm_private.require_text(p_data, 'mobile');
    mob := crm_private.check_student_mobile(p_data->>'mobile');
    IF EXISTS (SELECT 1 FROM public.student WHERE mobile_normalized = mob AND id <> p_id) THEN
      RAISE EXCEPTION 'A student with this mobile number already exists' USING ERRCODE = 'PT409';
    END IF;
  END IF;
  IF p_data ? 'date_of_birth' THEN dob := crm_private.check_dob(p_data->>'date_of_birth'); END IF;

  UPDATE public.student s SET
    first_name        = CASE WHEN p_data ? 'first_name' THEN btrim(p_data->>'first_name') ELSE s.first_name END,
    middle_name       = CASE WHEN p_data ? 'middle_name' THEN crm_private.blank(p_data->>'middle_name') ELSE s.middle_name END,
    last_name         = CASE WHEN p_data ? 'last_name' THEN crm_private.blank(p_data->>'last_name') ELSE s.last_name END,
    guardian_name     = CASE WHEN p_data ? 'guardian_name' THEN crm_private.blank(p_data->>'guardian_name') ELSE s.guardian_name END,
    address           = CASE WHEN p_data ? 'address' THEN crm_private.blank(p_data->>'address') ELSE s.address END,
    course            = CASE WHEN p_data ? 'course' THEN crm_private.blank(p_data->>'course') ELSE s.course END,
    admission_date    = CASE WHEN p_data ? 'admission_date' THEN crm_private.blank(p_data->>'admission_date')::date ELSE s.admission_date END,
    computer_number   = CASE WHEN p_data ? 'computer_number' THEN crm_private.blank(p_data->>'computer_number') ELSE s.computer_number END,
    emergency_contact = CASE WHEN p_data ? 'emergency_contact' THEN
                          CASE WHEN crm_private.blank(p_data->>'emergency_contact') IS NULL THEN NULL
                               ELSE crm_private.norm_phone(p_data->>'emergency_contact') END
                        ELSE s.emergency_contact END,
    date_of_birth     = CASE WHEN p_data ? 'date_of_birth' THEN dob ELSE s.date_of_birth END,
    mobile            = coalesce(mob, s.mobile),
    mobile_normalized = coalesce(mob, s.mobile_normalized),
    updated_at        = now()
  WHERE s.id = p_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'edit', 'student', jsonb_build_object('student_id', p_id, 'fields',
          to_jsonb(changed || CASE WHEN mob IS NOT NULL THEN ARRAY['mobile_normalized'] ELSE ARRAY[]::text[] END)));
  RETURN json_build_object('status', 'updated');
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'A student with this mobile number already exists' USING ERRCODE = 'PT409';
END $$;

-- DELETE /api/students/{id} (the browser removes the Storage files first) -----------
-- SECURITY DEFINER so it can also remove the student's login account.
CREATE OR REPLACE FUNCTION public.api_student_delete(p_id uuid) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access(); s record; docs int; leftover int;
BEGIN
  SELECT st.first_name, st.middle_name, st.last_name, st.mobile, st.auth_user_id INTO s
    FROM public.student st WHERE st.id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  SELECT count(*) INTO leftover FROM storage.objects o
   WHERE o.bucket_id = 'student-documents' AND o.name LIKE 'students/' || p_id || '/%';
  IF leftover > 0 THEN
    RAISE EXCEPTION 'Document files are still stored for this student; aborted, nothing removed' USING ERRCODE = 'PT502';
  END IF;
  SELECT count(*) INTO docs FROM public.student_document WHERE student_id = p_id;
  DELETE FROM public.student_document WHERE student_id = p_id;
  DELETE FROM public.student WHERE id = p_id;
  IF s.auth_user_id IS NOT NULL THEN DELETE FROM auth.users WHERE id = s.auth_user_id; END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'delete', 'student', jsonb_build_object('student_id', p_id,
          'name', concat_ws(' ', nullif(s.first_name, ''), nullif(s.middle_name, ''), nullif(s.last_name, '')),
          'mobile', s.mobile, 'documents_removed', docs));
  RETURN json_build_object('status', 'deleted', 'documents_removed', docs);
END $$;

-- Staff document actions --------------------------------------------------------------
-- Upload: the browser stores the file in Storage, then registers it here.
-- Returns the replaced file's path (if any) so the browser can remove it.
CREATE OR REPLACE FUNCTION public.api_student_doc_register(p_student_id uuid, p_doc_type text, p_path text,
  p_filename text, p_mime text, p_size bigint) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access(); old record; did uuid;
BEGIN
  IF NOT (p_doc_type = ANY(crm_private.student_doc_types())) THEN
    RAISE EXCEPTION 'Invalid doc_type' USING ERRCODE = 'PT400';
  END IF;
  IF p_path NOT LIKE 'students/' || p_student_id || '/%' THEN
    RAISE EXCEPTION 'Invalid storage path' USING ERRCODE = 'PT400';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.student WHERE id = p_student_id) THEN
    RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404';
  END IF;
  SELECT d.id, d.r2_key INTO old FROM public.student_document d WHERE d.student_id = p_student_id AND d.doc_type = p_doc_type::public.student_doc_type;
  IF old.id IS NOT NULL THEN DELETE FROM public.student_document WHERE id = old.id; END IF;
  INSERT INTO public.student_document (student_id, doc_type, r2_key, original_filename, mime_type, size_bytes, uploaded_by)
  VALUES (p_student_id, p_doc_type::public.student_doc_type, p_path, p_filename, p_mime, p_size, eid) RETURNING id INTO did;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'upload_document', 'student_document', jsonb_build_object('student_id', p_student_id,
          'doc_type', p_doc_type, 'replaced', old.id IS NOT NULL));
  RETURN json_build_object('status', 'uploaded', 'id', did, 'doc_type', p_doc_type, 'old_path', old.r2_key);
END $$;

CREATE OR REPLACE FUNCTION public.api_student_doc_path(p_student_id uuid, p_doc_id uuid, p_action text) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access(); r record;
BEGIN
  SELECT d.r2_key, d.doc_type INTO r FROM public.student_document d WHERE d.id = p_doc_id AND d.student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found' USING ERRCODE = 'PT404'; END IF;
  IF p_action = 'delete' THEN
    DELETE FROM public.student_document WHERE id = p_doc_id;
    INSERT INTO public.audit_log (actor, action, entity, payload)
    VALUES (eid, 'delete_document', 'student_document', jsonb_build_object('student_id', p_student_id, 'doc_id', p_doc_id, 'doc_type', r.doc_type));
  ELSE
    INSERT INTO public.audit_log (actor, action, entity, payload)
    VALUES (eid, 'view_document', 'student_document', jsonb_build_object('student_id', p_student_id, 'doc_id', p_doc_id, 'doc_type', r.doc_type));
  END IF;
  RETURN json_build_object('path', r.r2_key);
END $$;

-- POST /api/students/{id}/set-pin -> login on/off (Admin). Password resets go through crm-auth.
CREATE OR REPLACE FUNCTION public.api_student_set_login(p_student_id uuid, p_login_enabled boolean, p_password_reset boolean DEFAULT false)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); n int;
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only the Admin department can manage student PINs' USING ERRCODE = 'PT403';
  END IF;
  IF p_login_enabled IS NOT NULL THEN
    UPDATE public.student SET login_enabled = p_login_enabled WHERE id = p_student_id;
  ELSE
    PERFORM 1 FROM public.student WHERE id = p_student_id;
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'set_pin', 'student', jsonb_build_object('student_id', p_student_id,
          'pin_changed', coalesce(p_password_reset, false), 'login_enabled', p_login_enabled));
  RETURN json_build_object('status', 'updated');
END $$;

-- Student portal (scoped to the signed-in student) ------------------------------------
CREATE OR REPLACE FUNCTION public.api_student_me() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE sid uuid := crm_private.require_student(); r json;
BEGIN
  SELECT json_build_object('id', s.id, 'first_name', s.first_name, 'middle_name', s.middle_name,
           'last_name', s.last_name, 'guardian_name', s.guardian_name, 'mobile', s.mobile,
           'emergency_contact', s.emergency_contact, 'address', s.address, 'course', s.course,
           'admission_date', s.admission_date, 'computer_number', s.computer_number,
           'created_at', s.created_at, 'last_login_at', s.last_login_at)
    INTO r FROM public.student s WHERE s.id = sid;
  IF r IS NULL THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.api_student_update_me(p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE sid uuid := crm_private.require_student(); bad text; d jsonb := p_data - 'email'; n int;
BEGIN
  SELECT string_agg(k, ', ' ORDER BY k) INTO bad FROM jsonb_object_keys(d) k
   WHERE k NOT IN ('guardian_name', 'emergency_contact', 'address');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'You may not edit: %', bad USING ERRCODE = 'PT403'; END IF;
  IF NOT (d ? 'guardian_name' OR d ? 'emergency_contact' OR d ? 'address') THEN
    RAISE EXCEPTION 'No editable fields provided' USING ERRCODE = 'PT400';
  END IF;
  UPDATE public.student s SET
    guardian_name = CASE WHEN d ? 'guardian_name' THEN d->>'guardian_name' ELSE s.guardian_name END,
    address = CASE WHEN d ? 'address' THEN d->>'address' ELSE s.address END,
    emergency_contact = CASE WHEN d ? 'emergency_contact' THEN
      CASE WHEN coalesce(d->>'emergency_contact', '') = '' THEN d->>'emergency_contact'
           ELSE crm_private.norm_phone(d->>'emergency_contact') END
      ELSE s.emergency_contact END,
    updated_at = now()
  WHERE s.id = sid;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Student not found' USING ERRCODE = 'PT404'; END IF;
  RETURN json_build_object('status', 'updated');
END $$;

CREATE OR REPLACE FUNCTION public.api_student_my_documents() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE sid uuid := crm_private.require_student();
BEGIN
  RETURN json_build_object('doc_types', to_jsonb(crm_private.student_doc_types()),
    'documents', coalesce((SELECT jsonb_object_agg(x.doc_type, x.j) FROM (
        SELECT DISTINCT ON (d.doc_type) d.doc_type::text AS doc_type, crm_private.doc_json(d) AS j
        FROM public.student_document d WHERE d.student_id = sid
        ORDER BY d.doc_type, d.uploaded_at DESC) x), '{}'::jsonb));
END $$;

-- Student upload register: SECURITY DEFINER because it replaces (deletes) the old row,
-- which students cannot do directly; scoped strictly to the caller's own student id.
CREATE OR REPLACE FUNCTION public.api_student_my_doc_register(p_doc_type text, p_path text, p_filename text,
  p_mime text, p_size bigint) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE sid uuid := crm_private.require_student(); old record; did uuid;
BEGIN
  IF NOT (p_doc_type = ANY(crm_private.student_doc_types())) THEN
    RAISE EXCEPTION 'Invalid doc_type' USING ERRCODE = 'PT400';
  END IF;
  IF p_path NOT LIKE 'students/' || sid || '/%' THEN RAISE EXCEPTION 'Invalid storage path' USING ERRCODE = 'PT400'; END IF;
  IF p_size > 10485760 THEN RAISE EXCEPTION 'File exceeds 10MB limit' USING ERRCODE = 'PT400'; END IF;
  SELECT d.id, d.r2_key INTO old FROM public.student_document d WHERE d.student_id = sid AND d.doc_type = p_doc_type::public.student_doc_type;
  IF old.id IS NOT NULL THEN DELETE FROM public.student_document WHERE id = old.id; END IF;
  INSERT INTO public.student_document (student_id, doc_type, r2_key, original_filename, mime_type, size_bytes, uploaded_by)
  VALUES (sid, p_doc_type::public.student_doc_type, p_path, p_filename, p_mime, p_size, NULL) RETURNING id INTO did;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (NULL, 'upload_document', 'student_document', jsonb_build_object('student_id', sid,
          'doc_type', p_doc_type, 'by', 'student', 'replaced', old.id IS NOT NULL));
  RETURN json_build_object('status', 'uploaded', 'id', did, 'doc_type', p_doc_type, 'old_path', old.r2_key);
END $$;

CREATE OR REPLACE FUNCTION public.api_student_my_doc_path(p_doc_id uuid) RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE sid uuid := crm_private.require_student(); p text;
BEGIN
  SELECT d.r2_key INTO p FROM public.student_document d WHERE d.id = p_doc_id AND d.student_id = sid;
  IF p IS NULL THEN RAISE EXCEPTION 'Document not found' USING ERRCODE = 'PT404'; END IF;
  RETURN json_build_object('path', p);
END $$;

-- The student's own login time (the old backend set it on every sign-in).
CREATE OR REPLACE FUNCTION public.api_student_touch_login() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.student SET last_login_at = now() WHERE id = crm_private.current_student_id()
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_students_list(text)','public.api_students_prefill_leads()',
    'public.api_student_get(uuid)','public.api_student_create(jsonb)','public.api_student_update(uuid, jsonb)',
    'public.api_student_delete(uuid)','public.api_student_doc_register(uuid, text, text, text, text, bigint)',
    'public.api_student_doc_path(uuid, uuid, text)','public.api_student_set_login(uuid, boolean, boolean)',
    'public.api_student_me()','public.api_student_update_me(jsonb)','public.api_student_my_documents()',
    'public.api_student_my_doc_register(text, text, text, text, bigint)','public.api_student_my_doc_path(uuid)',
    'public.api_student_touch_login()']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $$;
