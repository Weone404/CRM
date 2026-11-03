-- 050: Mobile numbers are stored and shown as plain 10 digits (no +91).
-- Anything typed or pasted as "+91 98765 43210", "098765-43210", "919876543210" is cleaned to 9876543210.
-- A trigger does this for every writer (the new backend and, until switch-over, the Render backend too).
-- student.mobile_normalized stays "+91XXXXXXXXXX": it is the internal match key the Render
-- backend still uses for student login and duplicate checks. Lead phones are not touched here
-- (the website intake on Render de-duplicates on the +91 form); the screens hide +91 instead.

CREATE OR REPLACE FUNCTION crm_private.mobile10(raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE t text := btrim(coalesce(raw, '')); d text;
BEGIN
  IF t = '' OR t !~ '^[\s+().\-\d]+$' THEN RETURN nullif(t, ''); END IF;   -- not a phone number: leave it
  d := regexp_replace(t, '\D', '', 'g');
  IF length(d) = 12 AND left(d, 2) = '91' THEN d := substr(d, 3);
  ELSIF length(d) = 13 AND left(d, 3) = '091' THEN d := substr(d, 4);
  ELSIF length(d) = 11 AND left(d, 1) = '0' THEN d := substr(d, 2); END IF;
  RETURN CASE WHEN length(d) = 10 THEN d ELSE t END;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.mobile10(text) TO authenticated, service_role;

-- Student mobile check: 10-digit Indian mobile starting 6-9; returns the internal "+91" key.
CREATE OR REPLACE FUNCTION crm_private.check_student_mobile(raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE d text := crm_private.mobile10(raw);
BEGIN
  IF d IS NULL OR d !~ '^[6-9]\d{9}$' THEN
    RAISE EXCEPTION 'Enter a valid 10-digit mobile number (starting 6-9)' USING ERRCODE = 'PT400';
  END IF;
  RETURN '+91' || d;
END $$;

CREATE OR REPLACE FUNCTION crm_private.check_employee_phone(raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE d text := crm_private.mobile10(raw);
BEGIN
  IF d IS NULL OR d !~ '^\d{10}$' THEN
    RAISE EXCEPTION 'Enter a valid 10-digit mobile number' USING ERRCODE = 'PT400';
  END IF;
  RETURN d;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.check_employee_phone(text) TO authenticated;

-- Triggers: clean numbers on every insert/update -----------------------------------------
CREATE OR REPLACE FUNCTION crm_private.clean_student_phones() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.mobile := crm_private.mobile10(NEW.mobile);
  IF NEW.mobile ~ '^\d{10}$' THEN NEW.mobile_normalized := '+91' || NEW.mobile; END IF;
  NEW.emergency_contact := crm_private.mobile10(NEW.emergency_contact);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crm_clean_student_phones ON public.student;
CREATE TRIGGER crm_clean_student_phones BEFORE INSERT OR UPDATE OF mobile, mobile_normalized, emergency_contact
  ON public.student FOR EACH ROW EXECUTE FUNCTION crm_private.clean_student_phones();

CREATE OR REPLACE FUNCTION crm_private.clean_employee_phone() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.phone := coalesce(crm_private.mobile10(NEW.phone), NEW.phone);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crm_clean_employee_phone ON public.employee;
CREATE TRIGGER crm_clean_employee_phone BEFORE INSERT OR UPDATE OF phone
  ON public.employee FOR EACH ROW EXECUTE FUNCTION crm_private.clean_employee_phone();

-- API functions updated to validate/clean numbers -----------------------------------------
CREATE OR REPLACE FUNCTION public.api_student_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_students_access();
        first text; mob text; emer text; dob date; dup record; sid uuid;
BEGIN
  first := crm_private.require_text(p_data, 'first_name');
  PERFORM crm_private.require_text(p_data, 'mobile');
  dob := crm_private.check_dob(p_data->>'date_of_birth');
  mob := crm_private.check_student_mobile(p_data->>'mobile');
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

CREATE OR REPLACE FUNCTION public.api_students_list(p_search text DEFAULT '') RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE q text := btrim(coalesce(p_search, '')); lk text; qd text := regexp_replace(regexp_replace(btrim(coalesce(p_search, '')), '^(\+\s*91|0)', ''), '\D', '', 'g'); total int := cardinality(crm_private.student_doc_types());
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
          OR (qd ~ '^\d{4,}$' AND s.mobile LIKE '%' || qd || '%')
  ), '[]'::json);
END $$;

CREATE OR REPLACE FUNCTION public.api_employee_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_admin('Only Admin can add employees');
        nm text := nullif(btrim(p_data->>'name'), ''); ph text := nullif(btrim(p_data->>'phone'), '');
        code text := nullif(btrim(p_data->>'employee_id'), ''); lid text; nid uuid;
BEGIN
  IF nm IS NULL OR ph IS NULL THEN
    RAISE EXCEPTION 'Missing required field(s): %', concat_ws(', ', CASE WHEN nm IS NULL THEN 'name' END,
                                                             CASE WHEN ph IS NULL THEN 'phone' END) USING ERRCODE = 'PT400';
  END IF;
  ph := crm_private.check_employee_phone(ph);
  lid := coalesce(nullif(btrim(p_data->>'login_id'), ''), code, ph);
  PERFORM crm_private.employee_unique_check(NULL, lid, ph, code);
  INSERT INTO public.employee (employee_id, login_id, name, phone, email, job_role, address, joining_date, status,
                               date_of_leaving, date_of_birth, department, paid_leave_quota, monthly_salary,
                               password_hash, permissions)
  VALUES (code, lid, nm, ph, nullif(btrim(p_data->>'email'), ''), nullif(btrim(p_data->>'job_role'), ''),
          nullif(btrim(p_data->>'address'), ''), crm_private.to_date(p_data->>'joining_date', 'Joining date'),
          coalesce(nullif(p_data->>'status', ''), 'active'), crm_private.to_date(p_data->>'date_of_leaving', 'Date of leaving'),
          crm_private.check_emp_dob(p_data->>'date_of_birth'),
          crm_private.check_department(coalesce(nullif(p_data->>'department', ''), 'IT')),
          coalesce(crm_private.to_num(p_data->>'paid_leave_quota', 'Paid leave quota')::int, 0),
          crm_private.to_num(p_data->>'monthly_salary', 'Monthly salary'),
          -- same first password on the old system too, so both logins agree
          extensions.crypt(coalesce(crm_private.normalize_phone(ph), ph), extensions.gen_salt('bf', 12)),
          coalesce(p_data->'permissions', '{}'::jsonb))
  RETURNING id INTO nid;
  IF nullif(btrim(coalesce(p_data->>'pay_scale', '')), '') IS NOT NULL THEN
    PERFORM crm_private.set_pay_scale(nid, p_data->>'pay_scale');
  END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'create', 'employee', jsonb_build_object('employee_id', nid));
  RETURN json_build_object('id', nid);
END $$;

CREATE OR REPLACE FUNCTION public.api_employee_update(p_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); e public.employee; ph text; lid text; code text;
BEGIN
  IF NOT crm_private.is_admin() THEN
    IF p_id <> eid THEN RAISE EXCEPTION 'Can only edit your own profile' USING ERRCODE = 'PT403'; END IF;
    RAISE EXCEPTION 'Cannot edit profile fields' USING ERRCODE = 'PT403';
  END IF;
  SELECT * INTO e FROM public.employee WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found' USING ERRCODE = 'PT404'; END IF;
  IF p_data ? 'name' AND nullif(btrim(p_data->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'Missing required field(s): name' USING ERRCODE = 'PT400'; END IF;
  IF p_data ? 'phone' AND nullif(btrim(p_data->>'phone'), '') IS NULL THEN
    RAISE EXCEPTION 'Missing required field(s): phone' USING ERRCODE = 'PT400'; END IF;
  IF p_data ? 'login_id' AND nullif(btrim(p_data->>'login_id'), '') IS NULL THEN
    RAISE EXCEPTION 'Login ID cannot be empty' USING ERRCODE = 'PT400'; END IF;
  IF p_id = eid AND p_data ? 'department' AND p_data->>'department' <> 'Admin' THEN
    RAISE EXCEPTION 'You cannot remove your own Admin access' USING ERRCODE = 'PT400'; END IF;

  ph   := CASE WHEN p_data ? 'phone' THEN btrim(p_data->>'phone') END;
  -- validate only a changed number (Admin's record has no real phone)
  IF ph IS NOT NULL AND crm_private.mobile10(ph) IS DISTINCT FROM crm_private.mobile10(e.phone) THEN
    ph := crm_private.check_employee_phone(ph);
  ELSE ph := NULL; END IF;
  lid  := CASE WHEN p_data ? 'login_id' THEN btrim(p_data->>'login_id') END;
  code := CASE WHEN p_data ? 'employee_id' THEN nullif(btrim(p_data->>'employee_id'), '') END;
  PERFORM crm_private.employee_unique_check(p_id, lid, ph, code);

  UPDATE public.employee SET
    employee_id     = CASE WHEN p_data ? 'employee_id' THEN code ELSE employee_id END,
    name            = CASE WHEN p_data ? 'name' THEN btrim(p_data->>'name') ELSE name END,
    phone           = coalesce(ph, phone),
    email           = CASE WHEN p_data ? 'email' THEN nullif(btrim(p_data->>'email'), '') ELSE email END,
    job_role        = CASE WHEN p_data ? 'job_role' THEN nullif(btrim(p_data->>'job_role'), '') ELSE job_role END,
    address         = CASE WHEN p_data ? 'address' THEN nullif(btrim(p_data->>'address'), '') ELSE address END,
    joining_date    = CASE WHEN p_data ? 'joining_date' THEN crm_private.to_date(p_data->>'joining_date', 'Joining date') ELSE joining_date END,
    status          = CASE WHEN p_data ? 'status' THEN coalesce(nullif(p_data->>'status', ''), 'active') ELSE status END,
    date_of_leaving = CASE WHEN p_data ? 'date_of_leaving' THEN crm_private.to_date(p_data->>'date_of_leaving', 'Date of leaving') ELSE date_of_leaving END,
    date_of_birth   = CASE WHEN p_data ? 'date_of_birth' THEN crm_private.check_emp_dob(p_data->>'date_of_birth') ELSE date_of_birth END,
    paid_leave_quota= CASE WHEN p_data ? 'paid_leave_quota' THEN coalesce(crm_private.to_num(p_data->>'paid_leave_quota', 'Paid leave quota')::int, 0) ELSE paid_leave_quota END,
    monthly_salary  = CASE WHEN p_data ? 'monthly_salary' THEN crm_private.to_num(p_data->>'monthly_salary', 'Monthly salary') ELSE monthly_salary END,
    department      = CASE WHEN p_data ? 'department' THEN crm_private.check_department(p_data->>'department') ELSE department END,
    login_id        = coalesce(lid, login_id)
  WHERE id = p_id;
  -- the profile form echoes back the masked value for non-Admins; only store a real change
  IF p_data ? 'pay_scale' AND coalesce(p_data->>'pay_scale', '') <> '••••••' THEN
    PERFORM crm_private.set_pay_scale(p_id, p_data->>'pay_scale');
  END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'update', 'employee', jsonb_build_object('employee_id', p_id));
  RETURN json_build_object('status', 'updated');
END $$;

-- Clean the numbers already stored --------------------------------------------------------
UPDATE public.student SET mobile = mobile, emergency_contact = emergency_contact
 WHERE mobile ~ '^\+?91\d{10}$' OR mobile ~ '^0\d{10}$' OR emergency_contact ~ '^\+?91\d{10}$';
UPDATE public.employee SET phone = phone WHERE phone ~ '^\+?91\d{10}$' OR phone ~ '^0\d{10}$' OR phone ~ '\s|-';
