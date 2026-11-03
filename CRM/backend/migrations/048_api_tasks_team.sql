-- 048: Tasks + Team (employee directory, profiles, leave calendar) as Postgres API functions.
-- Same rules and response shapes as the Render endpoints, plus a few safety fixes:
--   * only Admin can edit employee records (Render let any non-PIN session edit anyone)
--   * missing title / bad status / unknown assignee give a clear 400 instead of a 500
--   * reopening a task clears its finish date / abort reason
--   * "today" means India time (Asia/Kolkata), not the server's clock
-- Pay scale is kept in Supabase Vault (one secret per employee), readable by Admin only.

-- Shared helpers -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.today_ist() RETURNS date
LANGUAGE sql STABLE SET search_path = '' AS $$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $$;

CREATE OR REPLACE FUNCTION crm_private.require_admin(msg text DEFAULT 'Admin access required') RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION '%', msg USING ERRCODE = 'PT403'; END IF;
  RETURN eid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.to_uuid(raw text, what text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;
  RETURN raw::uuid;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION '% is not valid', what USING ERRCODE = 'PT400';
END $$;

CREATE OR REPLACE FUNCTION crm_private.to_date(raw text, what text) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;
  RETURN left(btrim(raw), 10)::date;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION '% must be a valid date (YYYY-MM-DD)', what USING ERRCODE = 'PT400';
END $$;

CREATE OR REPLACE FUNCTION crm_private.to_ts(raw text, what text) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;
  -- a bare date means that day in India
  IF btrim(raw) ~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN (btrim(raw)::date)::timestamp AT TIME ZONE 'Asia/Kolkata'; END IF;
  RETURN btrim(raw)::timestamptz;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION '% must be a valid date', what USING ERRCODE = 'PT400';
END $$;

CREATE OR REPLACE FUNCTION crm_private.to_num(raw text, what text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;
  RETURN btrim(raw)::numeric;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION '% must be a number', what USING ERRCODE = 'PT400';
END $$;

GRANT EXECUTE ON FUNCTION crm_private.today_ist(), crm_private.require_admin(text), crm_private.to_uuid(text, text),
  crm_private.to_date(text, text), crm_private.to_ts(text, text), crm_private.to_num(text, text) TO authenticated;

-- ======================================================================================
-- TASKS
-- ======================================================================================
CREATE OR REPLACE FUNCTION crm_private.task_json(t public.task, assignee text, creator text) RETURNS json
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT json_build_object('id', t.id, 'title', t.title, 'description', t.description,
    'assigned_to', t.assigned_to, 'created_by', t.created_by, 'status', t.status,
    'due_date', t.due_date, 'created_at', t.created_at, 'finish_date', t.finish_date,
    'abort_reason', t.abort_reason, 'assignee_name', assignee, 'creator_name', creator)
$$;

-- GET /api/tasks : Admin sees all, everyone else only tasks assigned to them
CREATE OR REPLACE FUNCTION public.api_tasks() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); adm boolean := crm_private.is_admin();
BEGIN
  RETURN coalesce((SELECT json_agg(crm_private.task_json(t, a.name, c.name) ORDER BY t.created_at DESC)
    FROM public.task t
    LEFT JOIN public.employee a ON a.id = t.assigned_to
    JOIN public.employee c ON c.id = t.created_by
    WHERE adm OR t.assigned_to = eid), '[]'::json);
END $$;

CREATE OR REPLACE FUNCTION crm_private.check_task_status(s text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF s IS NULL OR s NOT IN ('pending', 'in_progress', 'done', 'aborted') THEN
    RAISE EXCEPTION 'status must be one of: pending, in_progress, done, aborted' USING ERRCODE = 'PT400';
  END IF;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION crm_private.check_assignee(raw text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE aid uuid := crm_private.to_uuid(raw, 'assigned_to');
BEGIN
  IF aid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.employee e WHERE e.id = aid AND e.active) THEN
    RAISE EXCEPTION 'Assigned employee not found' USING ERRCODE = 'PT400';
  END IF;
  RETURN aid;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.check_task_status(text), crm_private.check_assignee(text) TO authenticated;

-- POST /api/tasks : Admin can assign to anyone; others only to themselves
CREATE OR REPLACE FUNCTION public.api_task_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); adm boolean := crm_private.is_admin();
        who uuid; ttl text := nullif(btrim(p_data->>'title'), ''); tid uuid;
BEGIN
  IF ttl IS NULL THEN RAISE EXCEPTION 'Title is required' USING ERRCODE = 'PT400'; END IF;
  who := crm_private.check_assignee(p_data->>'assigned_to');
  IF NOT adm THEN
    IF who IS NOT NULL AND who <> eid THEN
      RAISE EXCEPTION 'Can only create tasks for yourself' USING ERRCODE = 'PT403';
    END IF;
    who := eid;
  END IF;
  -- double-submit guard: same title + assignee within 30 seconds
  IF EXISTS (SELECT 1 FROM public.task t WHERE t.title = ttl AND t.assigned_to IS NOT DISTINCT FROM who
             AND t.created_at > now() - interval '30 seconds') THEN
    RAISE EXCEPTION 'This task was just created.' USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO public.task (title, description, assigned_to, created_by, status, due_date)
  VALUES (ttl, nullif(btrim(p_data->>'description'), ''), who, eid,
          crm_private.check_task_status(coalesce(nullif(p_data->>'status', ''), 'pending')),
          crm_private.to_ts(p_data->>'due_date', 'due_date'))
  RETURNING id INTO tid;
  RETURN json_build_object('id', tid);
END $$;

-- PATCH /api/tasks/{id}
CREATE OR REPLACE FUNCTION public.api_task_update(p_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); adm boolean := crm_private.is_admin();
        t public.task; st text := nullif(p_data->>'status', '');
BEGIN
  SELECT * INTO t FROM public.task WHERE id = p_id;
  IF NOT FOUND THEN
    IF adm THEN RAISE EXCEPTION 'Task not found' USING ERRCODE = 'PT404'; END IF;
    RAISE EXCEPTION 'Can only update your own tasks' USING ERRCODE = 'PT403';
  END IF;
  IF NOT adm AND t.assigned_to IS DISTINCT FROM eid THEN
    RAISE EXCEPTION 'Can only update your own tasks' USING ERRCODE = 'PT403';
  END IF;

  IF st = 'done' THEN
    UPDATE public.task SET status = 'done', finish_date = now(), abort_reason = NULL WHERE id = p_id;
  ELSIF st = 'aborted' THEN
    IF nullif(btrim(p_data->>'abort_reason'), '') IS NULL THEN
      RAISE EXCEPTION 'abort_reason required when status is aborted' USING ERRCODE = 'PT400';
    END IF;
    UPDATE public.task SET status = 'aborted', abort_reason = btrim(p_data->>'abort_reason') WHERE id = p_id;
  ELSE
    IF p_data ? 'title' AND nullif(btrim(p_data->>'title'), '') IS NULL THEN
      RAISE EXCEPTION 'Title is required' USING ERRCODE = 'PT400';
    END IF;
    UPDATE public.task SET
      status       = CASE WHEN p_data ? 'status' THEN crm_private.check_task_status(st) ELSE status END,
      finish_date  = CASE WHEN p_data ? 'status' THEN NULL ELSE finish_date END,
      abort_reason = CASE WHEN p_data ? 'status' THEN NULL ELSE abort_reason END,
      title        = CASE WHEN p_data ? 'title' THEN btrim(p_data->>'title') ELSE title END,
      description  = CASE WHEN p_data ? 'description' THEN nullif(btrim(p_data->>'description'), '') ELSE description END,
      assigned_to  = CASE WHEN p_data ? 'assigned_to' AND adm THEN crm_private.check_assignee(p_data->>'assigned_to') ELSE assigned_to END,
      due_date     = CASE WHEN p_data ? 'due_date' THEN crm_private.to_ts(p_data->>'due_date', 'due_date') ELSE due_date END
    WHERE id = p_id;
  END IF;
  RETURN json_build_object('status', 'updated');
END $$;

-- DELETE /api/tasks/{id} : Admin, the creator, or the assignee (comments cascade)
CREATE OR REPLACE FUNCTION public.api_task_delete(p_id uuid) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); t public.task;
BEGIN
  SELECT * INTO t FROM public.task WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Task not found' USING ERRCODE = 'PT404'; END IF;
  IF NOT crm_private.is_admin() AND eid NOT IN (t.created_by, coalesce(t.assigned_to, '00000000-0000-0000-0000-000000000000'::uuid)) THEN
    RAISE EXCEPTION 'You can only delete tasks you created or are assigned to' USING ERRCODE = 'PT403';
  END IF;
  DELETE FROM public.task WHERE id = p_id;
  RETURN json_build_object('status', 'deleted');
END $$;

-- Task comments: readable/writable by whoever can see the task
CREATE OR REPLACE FUNCTION crm_private.require_task_visible(p_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); t public.task;
BEGIN
  SELECT * INTO t FROM public.task WHERE id = p_id;
  IF NOT FOUND OR NOT (crm_private.is_admin() OR eid IN (t.created_by, t.assigned_to)) THEN
    RAISE EXCEPTION 'Task not found' USING ERRCODE = 'PT404';
  END IF;
  RETURN eid;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.require_task_visible(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.api_task_comments(p_id uuid) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_task_visible(p_id);
  RETURN coalesce((SELECT json_agg(json_build_object('id', c.id, 'body', c.body, 'created_at', c.created_at,
                                                     'author_name', e.name) ORDER BY c.created_at)
    FROM public.task_comment c JOIN public.employee e ON e.id = c.author_id WHERE c.task_id = p_id), '[]'::json);
END $$;

CREATE OR REPLACE FUNCTION public.api_task_comment_add(p_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_task_visible(p_id); cid uuid;
BEGIN
  IF nullif(btrim(p_data->>'body'), '') IS NULL THEN
    RAISE EXCEPTION 'Comment cannot be empty' USING ERRCODE = 'PT400';
  END IF;
  INSERT INTO public.task_comment (task_id, author_id, body) VALUES (p_id, eid, btrim(p_data->>'body'))
  RETURNING id INTO cid;
  RETURN json_build_object('id', cid);
END $$;

-- ======================================================================================
-- TEAM: employee directory, profile, create/edit, leave calendar
-- ======================================================================================
ALTER TABLE public.employee ADD COLUMN IF NOT EXISTS pay_scale_vault_id uuid;
REVOKE ALL (pay_scale_vault_id) ON public.employee FROM authenticated, anon;

-- GET /api/employees (Admin)
CREATE OR REPLACE FUNCTION public.api_employees() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_admin('Employee directory access requires Admin department');
  RETURN coalesce((SELECT json_agg(json_build_object('id', e.id, 'employee_id', e.employee_id, 'name', e.name,
      'job_role', e.job_role, 'joining_date', e.joining_date, 'status', coalesce(e.status, 'active'),
      'date_of_birth', e.date_of_birth) ORDER BY e.name)
    FROM public.employee e WHERE e.active), '[]'::json);
END $$;

-- GET /api/employees/{id} : Admin any, others only themselves
CREATE OR REPLACE FUNCTION public.api_employee_get(p_id uuid) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); adm boolean := crm_private.is_admin();
        e public.employee; today date := crm_private.today_ist();
        m_start date := date_trunc('month', crm_private.today_ist())::date;
        m_end date := (date_trunc('month', crm_private.today_ist()) + interval '1 month')::date;
        dim int := extract(day from (date_trunc('month', crm_private.today_ist()) + interval '1 month - 1 day'))::int;
        days json; counts jsonb; used int; pay text; per_day numeric; ded_days numeric; ded numeric;
BEGIN
  IF NOT adm AND p_id <> eid THEN RAISE EXCEPTION 'Can only view your own profile' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO e FROM public.employee WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found' USING ERRCODE = 'PT404'; END IF;

  SELECT coalesce(json_agg(json_build_object('date', l.leave_date, 'type', l.leave_type) ORDER BY l.leave_date), '[]'::json)
    INTO days FROM public.employee_leave_day l
   WHERE l.employee_id = p_id AND l.leave_date >= m_start AND l.leave_date < m_end;
  SELECT coalesce(jsonb_object_agg(x.leave_type, x.n), '{}'::jsonb) INTO counts
    FROM (SELECT l.leave_type, count(*) n FROM public.employee_leave_day l
           WHERE l.employee_id = p_id AND l.leave_date >= m_start AND l.leave_date < m_end GROUP BY l.leave_type) x;
  used := coalesce((counts->>'paid_leave')::int, 0);

  IF e.pay_scale_vault_id IS NOT NULL THEN
    IF adm THEN SELECT d.decrypted_secret INTO pay FROM vault.decrypted_secrets d WHERE d.id = e.pay_scale_vault_id;
    ELSE pay := '••••••'; END IF;
  END IF;

  IF e.monthly_salary IS NOT NULL AND e.monthly_salary <> 0 THEN
    per_day := e.monthly_salary / dim;
    ded_days := coalesce((counts->>'leave')::numeric, 0) + coalesce((counts->>'half_day')::numeric, 0) * 0.5;
    ded := ded_days * per_day;
  END IF;

  RETURN json_build_object(
    'id', e.id, 'employee_id', e.employee_id, 'name', e.name, 'phone', e.phone, 'email', e.email,
    'job_role', e.job_role, 'address', e.address, 'pay_scale', pay,
    'joining_date', e.joining_date, 'status', coalesce(e.status, 'active'), 'date_of_leaving', e.date_of_leaving,
    'paid_leave_quota', coalesce(e.paid_leave_quota, 0),
    'monthly_salary', CASE WHEN e.monthly_salary <> 0 THEN e.monthly_salary::float8 END,
    'department', e.department, 'date_of_birth', e.date_of_birth, 'login_id', e.login_id,
    'leave_days', days, 'leave_counts', counts,
    'paid_leave_used', used, 'paid_leave_remaining', coalesce(e.paid_leave_quota, 0) - used,
    'days_in_month', CASE WHEN per_day IS NOT NULL THEN dim END,
    'per_day_salary', round(per_day, 2)::float8,
    'deduction_amount', round(ded, 2)::float8,
    'net_salary', round(e.monthly_salary - ded, 2)::float8);
END $$;

CREATE OR REPLACE FUNCTION crm_private.check_department(raw text) RETURNS public.department_enum
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF raw NOT IN ('Admin', 'IT', 'Sales', 'Instructors') THEN
    RAISE EXCEPTION 'department must be one of: Admin, IT, Sales, Instructors' USING ERRCODE = 'PT400';
  END IF;
  RETURN raw::public.department_enum;
END $$;

CREATE OR REPLACE FUNCTION crm_private.check_emp_dob(raw text) RETURNS date
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE d date := crm_private.to_date(raw, 'Date of birth');
BEGIN
  IF d IS NULL THEN RETURN NULL; END IF;
  IF d > crm_private.today_ist() THEN RAISE EXCEPTION 'Date of birth cannot be in the future' USING ERRCODE = 'PT400'; END IF;
  IF d < (crm_private.today_ist() - interval '100 years')::date THEN
    RAISE EXCEPTION 'Date of birth cannot be more than 100 years ago' USING ERRCODE = 'PT400';
  END IF;
  RETURN d;
END $$;

CREATE OR REPLACE FUNCTION crm_private.set_pay_scale(p_emp uuid, p_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE vid uuid; v text := nullif(btrim(coalesce(p_value, '')), '');
BEGIN
  SELECT e.pay_scale_vault_id INTO vid FROM public.employee e WHERE e.id = p_emp;
  IF v IS NULL THEN
    IF vid IS NOT NULL THEN
      UPDATE public.employee SET pay_scale_vault_id = NULL WHERE id = p_emp;
      DELETE FROM vault.secrets WHERE id = vid;
    END IF;
  ELSIF vid IS NULL THEN
    vid := vault.create_secret(v, 'crm_pay_scale_' || p_emp, 'CRM employee pay scale');
    UPDATE public.employee SET pay_scale_vault_id = vid WHERE id = p_emp;
  ELSE
    PERFORM vault.update_secret(vid, v);
  END IF;
END $$;
REVOKE ALL ON FUNCTION crm_private.set_pay_scale(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION crm_private.employee_unique_check(p_id uuid, p_login text, p_phone text, p_code text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_login IS NOT NULL AND EXISTS (SELECT 1 FROM public.employee e WHERE lower(e.login_id) = lower(p_login) AND e.id IS DISTINCT FROM p_id) THEN
    RAISE EXCEPTION 'An employee with this login ID already exists' USING ERRCODE = 'PT409';
  END IF;
  IF p_phone IS NOT NULL AND EXISTS (SELECT 1 FROM public.employee e WHERE e.id IS DISTINCT FROM p_id
                                     AND (e.phone = p_phone OR crm_private.normalize_phone(e.phone) = crm_private.normalize_phone(p_phone))) THEN
    RAISE EXCEPTION 'An employee with this phone number already exists' USING ERRCODE = 'PT409';
  END IF;
  IF p_code IS NOT NULL AND EXISTS (SELECT 1 FROM public.employee e WHERE e.employee_id = p_code AND e.id IS DISTINCT FROM p_id) THEN
    RAISE EXCEPTION 'An employee with this employee ID already exists' USING ERRCODE = 'PT409';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.check_department(text), crm_private.check_emp_dob(text),
  crm_private.employee_unique_check(uuid, text, text, text) TO authenticated;

-- POST /api/employees (Admin). First password = their mobile number (login created by crm-auth "provision").
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

-- PATCH /api/employees/{id} (Admin)
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

-- POST /api/employees/{id}/leave : Admin for anyone, others for themselves
CREATE OR REPLACE FUNCTION public.api_leave_mark(p_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); lt text := p_data->>'leave_type'; d date;
        quota int; used int; lid uuid;
BEGIN
  IF NOT crm_private.is_admin() AND p_id <> eid THEN
    RAISE EXCEPTION 'Can only mark your own leave' USING ERRCODE = 'PT403';
  END IF;
  IF lt IS NULL OR lt NOT IN ('leave', 'half_day', 'paid_leave', 'wfh') THEN
    RAISE EXCEPTION 'Invalid leave_type ''%''. Must be one of: leave, half_day, paid_leave, wfh', coalesce(lt, 'None')
      USING ERRCODE = 'PT400';
  END IF;
  IF nullif(btrim(coalesce(p_data->>'leave_date', '')), '') IS NULL THEN
    RAISE EXCEPTION 'leave_date is required' USING ERRCODE = 'PT400';
  END IF;
  d := crm_private.to_date(p_data->>'leave_date', 'leave_date');
  IF NOT EXISTS (SELECT 1 FROM public.employee e WHERE e.id = p_id) THEN
    RAISE EXCEPTION 'Employee not found' USING ERRCODE = 'PT404';
  END IF;
  IF lt = 'paid_leave' THEN
    SELECT coalesce(e.paid_leave_quota, 0) INTO quota FROM public.employee e WHERE e.id = p_id;
    IF quota = 0 THEN RAISE EXCEPTION 'No paid leave quota assigned. Contact admin.' USING ERRCODE = 'PT400'; END IF;
    SELECT count(*) INTO used FROM public.employee_leave_day l
     WHERE l.employee_id = p_id AND l.leave_type = 'paid_leave' AND l.leave_date <> d
       AND l.leave_date >= date_trunc('month', d)::date AND l.leave_date < (date_trunc('month', d) + interval '1 month')::date;
    IF used >= quota THEN
      RAISE EXCEPTION 'No More Paid Leaves Available. Used %/% for this month', used, quota USING ERRCODE = 'PT400';
    END IF;
  END IF;
  INSERT INTO public.employee_leave_day (employee_id, leave_date, leave_type, marked_by)
  VALUES (p_id, d, lt, eid)
  ON CONFLICT (employee_id, leave_date) DO UPDATE SET leave_type = EXCLUDED.leave_type, marked_by = EXCLUDED.marked_by
  RETURNING id INTO lid;
  RETURN json_build_object('id', lid);
END $$;

-- DELETE /api/employees/{id}/leave/{date}
CREATE OR REPLACE FUNCTION public.api_leave_unmark(p_id uuid, p_date text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
BEGIN
  IF NOT crm_private.is_admin() AND p_id <> eid THEN
    RAISE EXCEPTION 'Can only unmark your own leave' USING ERRCODE = 'PT403';
  END IF;
  DELETE FROM public.employee_leave_day WHERE employee_id = p_id AND leave_date = crm_private.to_date(p_date, 'leave_date');
  RETURN json_build_object('status', 'deleted');
END $$;

-- Permissions: API functions callable by signed-in users only
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['api_tasks()', 'api_task_create(jsonb)', 'api_task_update(uuid, jsonb)', 'api_task_delete(uuid)',
    'api_task_comments(uuid)', 'api_task_comment_add(uuid, jsonb)', 'api_employees()', 'api_employee_get(uuid)',
    'api_employee_create(jsonb)', 'api_employee_update(uuid, jsonb)', 'api_leave_mark(uuid, jsonb)', 'api_leave_unmark(uuid, text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION crm_private.task_json(public.task, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_private.task_json(public.task, text, text) TO authenticated;
