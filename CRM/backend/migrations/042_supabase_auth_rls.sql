-- 042: Supabase Auth + Row Level Security foundation for the CRM rebuild.
--
-- Additive and safe while the Render backend is still live:
--   * Render connects as the table owner (postgres), which bypasses RLS, so it is
--     unaffected by every policy below.
--   * Policies apply only to the `authenticated` role and only to users linked to
--     an active employee/student row. Nobody is linked yet, so nothing is exposed.
--   * The public (anon) key keeps having no access to CRM tables.
--
-- Access rules mirror the current backend (CRM/backend/main.py):
--   Admin          : everything
--   Sales          : leads, dispositions, follow-ups, outbox/quotes, courses, students
--   Every employee : own profile, own tasks, leave list, meetings, policy docs, config
--   Admin only     : employee directory details, attendance, salary, leave marking
--   Student        : own student row and own documents only
--
-- Reversible: see the DOWN section at the end of this file.

-- 1. Link CRM people to Supabase Auth users ---------------------------------
ALTER TABLE public.employee ADD COLUMN IF NOT EXISTS auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.student  ADD COLUMN IF NOT EXISTS auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. Helper functions (private schema: not exposed through the API) ----------
CREATE SCHEMA IF NOT EXISTS crm_private;
REVOKE ALL ON SCHEMA crm_private FROM PUBLIC;
GRANT USAGE ON SCHEMA crm_private TO authenticated;

CREATE OR REPLACE FUNCTION crm_private.current_employee_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.id FROM public.employee e
  WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active = true
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.current_department() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.department::text FROM public.employee e
  WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active = true
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.is_employee() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.current_employee_id() IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION crm_private.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(crm_private.current_department() = 'Admin', false)
$$;

CREATE OR REPLACE FUNCTION crm_private.is_sales_or_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(crm_private.current_department() IN ('Admin', 'Sales'), false)
$$;

CREATE OR REPLACE FUNCTION crm_private.current_student_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.id FROM public.student s
  WHERE s.auth_user_id = (SELECT auth.uid()) AND s.login_enabled IS NOT FALSE
  LIMIT 1
$$;


-- 3. Keep secrets out of the API: column-level access on sensitive tables -----
-- employee: password_hash, login_pin, pay_scale_encrypted, monthly_salary are never
-- readable or writable through the API. Creating employees, passwords and salary go
-- through Edge Functions (service role) later.
REVOKE ALL ON public.employee FROM authenticated, anon;
GRANT SELECT (id, name, phone, email, permissions, active, created_at, employee_id,
              joining_date, status, job_role, address, date_of_leaving, department,
              paid_leave_quota, login_id, date_of_birth, auth_user_id)
  ON public.employee TO authenticated;
GRANT UPDATE (name, phone, email, address, date_of_birth, permissions, active, employee_id,
              joining_date, status, job_role, date_of_leaving, department, paid_leave_quota, login_id)
  ON public.employee TO authenticated;

-- A non-admin may only change their own personal fields (RLS limits them to their own row).
CREATE OR REPLACE FUNCTION crm_private.guard_employee_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (SELECT auth.role()) = 'authenticated' AND NOT crm_private.is_admin() THEN
    IF (NEW.permissions, NEW.active, NEW.employee_id, NEW.joining_date, NEW.status, NEW.job_role,
        NEW.date_of_leaving, NEW.department, NEW.paid_leave_quota, NEW.login_id)
       IS DISTINCT FROM
       (OLD.permissions, OLD.active, OLD.employee_id, OLD.joining_date, OLD.status, OLD.job_role,
        OLD.date_of_leaving, OLD.department, OLD.paid_leave_quota, OLD.login_id) THEN
      RAISE EXCEPTION 'Only Admin can change job, role or status fields' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crm_guard_employee_update ON public.employee;
CREATE TRIGGER crm_guard_employee_update BEFORE UPDATE ON public.employee
  FOR EACH ROW EXECUTE FUNCTION crm_private.guard_employee_update();

-- student: the PIN hash, login switch and auth link are never readable or writable
-- through the API (student login is managed by an Edge Function).
REVOKE ALL ON public.student FROM authenticated, anon;
GRANT SELECT (id, first_name, middle_name, last_name, guardian_name, mobile, mobile_normalized,
              emergency_contact, address, course, admission_date, computer_number, lead_id,
              created_at, created_by, updated_at, login_enabled, last_login_at, date_of_birth,
              auth_user_id)
  ON public.student TO authenticated;
GRANT INSERT (first_name, middle_name, last_name, guardian_name, mobile, mobile_normalized,
              emergency_contact, address, course, admission_date, computer_number, lead_id,
              created_by, date_of_birth)
  ON public.student TO authenticated;
GRANT UPDATE (first_name, middle_name, last_name, guardian_name, mobile, mobile_normalized,
              emergency_contact, address, course, admission_date, computer_number, lead_id,
              updated_at, date_of_birth)
  ON public.student TO authenticated;
GRANT DELETE ON public.student TO authenticated;

-- A student may only edit guardian, emergency contact and address on their own row
-- (same as today's student portal).
CREATE OR REPLACE FUNCTION crm_private.guard_student_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (SELECT auth.role()) = 'authenticated' AND NOT crm_private.is_sales_or_admin() THEN
    IF (NEW.first_name, NEW.middle_name, NEW.last_name, NEW.mobile, NEW.mobile_normalized, NEW.course,
        NEW.admission_date, NEW.computer_number, NEW.lead_id, NEW.date_of_birth)
       IS DISTINCT FROM
       (OLD.first_name, OLD.middle_name, OLD.last_name, OLD.mobile, OLD.mobile_normalized, OLD.course,
        OLD.admission_date, OLD.computer_number, OLD.lead_id, OLD.date_of_birth) THEN
      RAISE EXCEPTION 'Students can only update guardian, emergency contact and address' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crm_guard_student_update ON public.student;
CREATE TRIGGER crm_guard_student_update BEFORE UPDATE ON public.student
  FOR EACH ROW EXECUTE FUNCTION crm_private.guard_student_update();

-- 4. Staff directory: names/departments every employee may see -----------------
-- A function (not a view) so it does not bypass RLS for anyone who is not an employee.
CREATE OR REPLACE FUNCTION public.staff_directory()
RETURNS TABLE (id uuid, name text, department text, job_role text, active boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT e.id, e.name, e.department::text, e.job_role::text, e.active
  FROM public.employee e
  WHERE crm_private.is_employee() AND e.active = true
  ORDER BY e.name
$$;
REVOKE ALL ON FUNCTION public.staff_directory() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_directory() TO authenticated;

-- 5. Policies -------------------------------------------------------------------
-- Leads and everything hanging off a lead: Admin + Sales.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lead','contact_attempt','followup','interested','not_interested',
                           'not_reachable','callback','outbox_message']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS crm_sales_select ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_sales_insert ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_sales_update ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_admin_delete ON public.%I', t);
    EXECUTE format('CREATE POLICY crm_sales_select ON public.%I FOR SELECT TO authenticated USING ((SELECT crm_private.is_sales_or_admin()))', t);
    EXECUTE format('CREATE POLICY crm_sales_insert ON public.%I FOR INSERT TO authenticated WITH CHECK ((SELECT crm_private.is_sales_or_admin()))', t);
    EXECUTE format('CREATE POLICY crm_sales_update ON public.%I FOR UPDATE TO authenticated USING ((SELECT crm_private.is_sales_or_admin())) WITH CHECK ((SELECT crm_private.is_sales_or_admin()))', t);
    EXECUTE format('CREATE POLICY crm_admin_delete ON public.%I FOR DELETE TO authenticated USING ((SELECT crm_private.is_admin()))', t);
  END LOOP;
END $$;

-- Courses / fee lines (used by quotes): Sales + Admin read and edit.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['course','course_line_item'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS crm_sales_select ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_sales_update ON public.%I', t);
    EXECUTE format('CREATE POLICY crm_sales_select ON public.%I FOR SELECT TO authenticated USING ((SELECT crm_private.is_sales_or_admin()))', t);
    EXECUTE format('CREATE POLICY crm_sales_update ON public.%I FOR UPDATE TO authenticated USING ((SELECT crm_private.is_sales_or_admin())) WITH CHECK ((SELECT crm_private.is_sales_or_admin()))', t);
  END LOOP;
END $$;

-- Config: every employee reads; Admin writes.
DROP POLICY IF EXISTS crm_employee_select ON public.config;
DROP POLICY IF EXISTS crm_admin_write ON public.config;
CREATE POLICY crm_employee_select ON public.config FOR SELECT TO authenticated USING ((SELECT crm_private.is_employee()));
CREATE POLICY crm_admin_write ON public.config FOR ALL TO authenticated
  USING ((SELECT crm_private.is_admin())) WITH CHECK ((SELECT crm_private.is_admin()));

-- Employee rows: own row; Admin sees and edits all.
DROP POLICY IF EXISTS crm_self_or_admin_select ON public.employee;
DROP POLICY IF EXISTS crm_self_or_admin_update ON public.employee;
CREATE POLICY crm_self_or_admin_select ON public.employee FOR SELECT TO authenticated
  USING (auth_user_id = (SELECT auth.uid()) OR (SELECT crm_private.is_admin()));
CREATE POLICY crm_self_or_admin_update ON public.employee FOR UPDATE TO authenticated
  USING (auth_user_id = (SELECT auth.uid()) OR (SELECT crm_private.is_admin()))
  WITH CHECK (auth_user_id = (SELECT auth.uid()) OR (SELECT crm_private.is_admin()));

-- Tasks: Admin all; others only tasks assigned to them (as the backend does today).
DROP POLICY IF EXISTS crm_task_select ON public.task;
DROP POLICY IF EXISTS crm_task_insert ON public.task;
DROP POLICY IF EXISTS crm_task_update ON public.task;
DROP POLICY IF EXISTS crm_task_delete ON public.task;
CREATE POLICY crm_task_select ON public.task FOR SELECT TO authenticated
  USING ((SELECT crm_private.is_admin()) OR assigned_to = (SELECT crm_private.current_employee_id()));
CREATE POLICY crm_task_insert ON public.task FOR INSERT TO authenticated
  WITH CHECK ((SELECT crm_private.is_admin())
              OR (assigned_to = (SELECT crm_private.current_employee_id())
                  AND created_by = (SELECT crm_private.current_employee_id())));
CREATE POLICY crm_task_update ON public.task FOR UPDATE TO authenticated
  USING ((SELECT crm_private.is_admin()) OR assigned_to = (SELECT crm_private.current_employee_id()))
  WITH CHECK ((SELECT crm_private.is_admin()) OR assigned_to = (SELECT crm_private.current_employee_id()));
CREATE POLICY crm_task_delete ON public.task FOR DELETE TO authenticated
  USING ((SELECT crm_private.is_admin())
         OR created_by = (SELECT crm_private.current_employee_id())
         OR assigned_to = (SELECT crm_private.current_employee_id()));

DROP POLICY IF EXISTS crm_task_comment_select ON public.task_comment;
DROP POLICY IF EXISTS crm_task_comment_insert ON public.task_comment;
CREATE POLICY crm_task_comment_select ON public.task_comment FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.task t WHERE t.id = task_id));  -- task RLS decides visibility
CREATE POLICY crm_task_comment_insert ON public.task_comment FOR INSERT TO authenticated
  WITH CHECK (author_id = (SELECT crm_private.current_employee_id())
              AND EXISTS (SELECT 1 FROM public.task t WHERE t.id = task_id));

-- Leave requests: every employee sees the list (as today); creates own; Admin approves.
DROP POLICY IF EXISTS crm_leave_select ON public.leave_record;
DROP POLICY IF EXISTS crm_leave_insert ON public.leave_record;
DROP POLICY IF EXISTS crm_leave_admin_update ON public.leave_record;
CREATE POLICY crm_leave_select ON public.leave_record FOR SELECT TO authenticated USING ((SELECT crm_private.is_employee()));
CREATE POLICY crm_leave_insert ON public.leave_record FOR INSERT TO authenticated
  WITH CHECK (employee_id = (SELECT crm_private.current_employee_id()));
CREATE POLICY crm_leave_admin_update ON public.leave_record FOR UPDATE TO authenticated
  USING ((SELECT crm_private.is_admin())) WITH CHECK ((SELECT crm_private.is_admin()));

-- Leave days and salary reports: own rows; Admin all and writes.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['employee_leave_day','monthly_salary_report'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS crm_self_or_admin_select ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_admin_write ON public.%I', t);
    EXECUTE format('CREATE POLICY crm_self_or_admin_select ON public.%I FOR SELECT TO authenticated USING (employee_id = (SELECT crm_private.current_employee_id()) OR (SELECT crm_private.is_admin()))', t);
    EXECUTE format('CREATE POLICY crm_admin_write ON public.%I FOR ALL TO authenticated USING ((SELECT crm_private.is_admin())) WITH CHECK ((SELECT crm_private.is_admin()))', t);
  END LOOP;
END $$;

-- Meetings and policy docs: every employee reads and creates.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['meeting','meeting_attendee','policy_doc'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS crm_employee_select ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS crm_employee_insert ON public.%I', t);
    EXECUTE format('CREATE POLICY crm_employee_select ON public.%I FOR SELECT TO authenticated USING ((SELECT crm_private.is_employee()))', t);
    EXECUTE format('CREATE POLICY crm_employee_insert ON public.%I FOR INSERT TO authenticated WITH CHECK ((SELECT crm_private.is_employee()))', t);
  END LOOP;
END $$;

-- Students: Admin + Sales manage; a student sees only their own row.
DROP POLICY IF EXISTS crm_student_select ON public.student;
DROP POLICY IF EXISTS crm_student_insert ON public.student;
DROP POLICY IF EXISTS crm_student_update ON public.student;
DROP POLICY IF EXISTS crm_student_delete ON public.student;
CREATE POLICY crm_student_select ON public.student FOR SELECT TO authenticated
  USING ((SELECT crm_private.is_sales_or_admin()) OR id = (SELECT crm_private.current_student_id()));
CREATE POLICY crm_student_insert ON public.student FOR INSERT TO authenticated
  WITH CHECK ((SELECT crm_private.is_sales_or_admin()));
CREATE POLICY crm_student_update ON public.student FOR UPDATE TO authenticated
  USING ((SELECT crm_private.is_sales_or_admin()) OR id = (SELECT crm_private.current_student_id()))
  WITH CHECK ((SELECT crm_private.is_sales_or_admin()) OR id = (SELECT crm_private.current_student_id()));
CREATE POLICY crm_student_delete ON public.student FOR DELETE TO authenticated
  USING ((SELECT crm_private.is_sales_or_admin()));

DROP POLICY IF EXISTS crm_student_doc_select ON public.student_document;
DROP POLICY IF EXISTS crm_student_doc_insert ON public.student_document;
DROP POLICY IF EXISTS crm_student_doc_delete ON public.student_document;
CREATE POLICY crm_student_doc_select ON public.student_document FOR SELECT TO authenticated
  USING ((SELECT crm_private.is_sales_or_admin()) OR student_id = (SELECT crm_private.current_student_id()));
CREATE POLICY crm_student_doc_insert ON public.student_document FOR INSERT TO authenticated
  WITH CHECK ((SELECT crm_private.is_sales_or_admin()) OR student_id = (SELECT crm_private.current_student_id()));
CREATE POLICY crm_student_doc_delete ON public.student_document FOR DELETE TO authenticated
  USING ((SELECT crm_private.is_sales_or_admin()));

-- Attendance and device mapping: Admin only.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cctv_attendance','device_person_map'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS crm_admin_all ON public.%I', t);
    EXECUTE format('CREATE POLICY crm_admin_all ON public.%I FOR ALL TO authenticated USING ((SELECT crm_private.is_admin())) WITH CHECK ((SELECT crm_private.is_admin()))', t);
  END LOOP;
END $$;

-- Audit log: any employee appends; Admin reads.
DROP POLICY IF EXISTS crm_audit_insert ON public.audit_log;
DROP POLICY IF EXISTS crm_audit_admin_select ON public.audit_log;
CREATE POLICY crm_audit_insert ON public.audit_log FOR INSERT TO authenticated WITH CHECK ((SELECT crm_private.is_employee()));
CREATE POLICY crm_audit_admin_select ON public.audit_log FOR SELECT TO authenticated USING ((SELECT crm_private.is_admin()));

-- Function privileges: only signed-in users may call the helpers.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA crm_private FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA crm_private TO authenticated;

-- Indexes that the policies filter on.
CREATE INDEX IF NOT EXISTS idx_employee_auth_user ON public.employee (auth_user_id);
CREATE INDEX IF NOT EXISTS idx_student_auth_user  ON public.student (auth_user_id);
CREATE INDEX IF NOT EXISTS idx_task_assigned_to   ON public.task (assigned_to);

-- DOWN (manual):
--   DROP FUNCTION public.staff_directory(); DROP SCHEMA crm_private CASCADE;  (drops policies/triggers that use it)
--   ALTER TABLE public.employee DROP COLUMN auth_user_id; ALTER TABLE public.student DROP COLUMN auth_user_id;
--   GRANT ALL ON public.employee, public.student TO authenticated, anon;  (restores the previous default grants)
