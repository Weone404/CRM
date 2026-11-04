-- 051: Attendance (Hikvision terminal + CCTV feed) as Postgres functions.
-- Same rules and response shapes as the Render endpoints:
--   daily view, Admin corrections, device -> CRM person mapping, monthly view,
--   archived monthly summaries, per-employee monthly attendance, and the punch
--   logic used by the device webhook (stale / duplicate / re-tap guards).
-- The device and partner tokens live in Supabase Vault; the crm-attendance Edge
-- Function checks them through svc_* wrappers that only the service role can call.
-- Also creates attendance_monthly_summary (Render migration 027 was never applied).

-- Archived monthly rollups ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.attendance_monthly_summary (
    id SERIAL PRIMARY KEY,
    month            DATE NOT NULL,
    source_person_id TEXT NOT NULL,
    person_name      TEXT NOT NULL,
    person_role      TEXT,
    crm_id           TEXT,
    days_present     INTEGER NOT NULL,
    first_date       DATE,
    last_date        DATE,
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (month, source_person_id)
);
CREATE INDEX IF NOT EXISTS idx_attendance_monthly_summary_month ON public.attendance_monthly_summary(month);
ALTER TABLE public.attendance_monthly_summary ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.attendance_monthly_summary FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS idx_cctv_attendance_crm_date ON public.cctv_attendance (crm_id, date);
CREATE INDEX IF NOT EXISTS idx_cctv_attendance_date ON public.cctv_attendance (date);

-- Time helpers (ports of _parse_hms / _fmt_hms / _compute_day_status / _report_status) ------
CREATE OR REPLACE FUNCTION crm_private.hms_secs(t text) RETURNS int
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE p text[];
BEGIN
  IF t IS NULL OR btrim(t) = '' THEN RETURN NULL; END IF;
  p := string_to_array(btrim(t), ':');
  RETURN p[1]::int * 3600 + coalesce(nullif(p[2], '')::int, 0) * 60 + coalesce(nullif(p[3], '')::int, 0);
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION crm_private.fmt_hm(secs numeric) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN secs IS NULL THEN NULL
         ELSE lpad(((trunc(secs)::int % 86400) / 3600)::text, 2, '0') || ':' ||
              lpad((((trunc(secs)::int % 86400) % 3600) / 60)::text, 2, '0') END
$$;

-- Hours between two times, rounded to 2 decimals exactly like the old backend (Python round on the
-- binary double). Only exact .xx5 ties can differ from plain decimal rounding; those are decided from
-- the double's exact value so both systems always agree.
CREATE OR REPLACE FUNCTION crm_private.hours2(secs int) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE k int; b bytea; bits bigint; e int; m numeric; lhs numeric; rhs numeric;
BEGIN
  IF secs IS NULL THEN RETURN NULL; END IF;
  IF secs % 36 <> 18 THEN RETURN round(secs / 3600.0, 2); END IF;
  k := (secs - 18) / 36;                      -- tie between k/100 and (k+1)/100
  b := float8send(secs::float8 / 3600.0);
  bits := ('x' || encode(b, 'hex'))::bit(64)::bigint;
  e := ((bits >> 52) & 2047)::int - 1075;      -- value = m * 2^e
  m := ((bits & 4503599627370495) | 4503599627370496)::numeric;
  -- compare value with the tie (2k+1)/200:  m*200  vs  (2k+1) * 2^(-e)
  lhs := m * 200; rhs := (2 * k + 1)::numeric * power(2::numeric, -e);
  IF lhs > rhs THEN RETURN (k + 1) / 100.0;
  ELSIF lhs < rhs THEN RETURN k / 100.0;
  ELSE RETURN CASE WHEN k % 2 = 0 THEN k / 100.0 ELSE (k + 1) / 100.0 END; END IF;
END $$;

-- -> (status, hours). Full day >= 7h, half day >= 4h, short_day / missing_exit = needs review.
CREATE OR REPLACE FUNCTION crm_private.day_status(p_entry text, p_exit text, OUT status text, OUT hours numeric)
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE e int := crm_private.hms_secs(p_entry); x int := crm_private.hms_secs(p_exit);
BEGIN
  IF e IS NULL THEN RETURN; END IF;
  IF x IS NULL OR x < e THEN status := 'missing_exit'; RETURN; END IF;
  hours := crm_private.hours2(x - e);
  status := CASE WHEN hours >= 7 THEN 'full_day' WHEN hours >= 4 THEN 'half_day' ELSE 'short_day' END;
END $$;

CREATE OR REPLACE FUNCTION crm_private.report_status(p_entry text, p_exit text, p_day_status text, p_override text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(p_override, p_day_status, (crm_private.day_status(p_entry, p_exit)).status)
$$;

CREATE OR REPLACE FUNCTION crm_private.require_attendance_admin(msg text DEFAULT 'Only the Admin department can manage CCTV attendance')
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  RETURN crm_private.require_admin(msg);
END $$;

CREATE OR REPLACE FUNCTION crm_private.month_range(p_month text, OUT m_start date, OUT m_end date)
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE t text := coalesce(nullif(btrim(p_month), ''), to_char(crm_private.today_ist(), 'YYYY-MM'));
BEGIN
  IF t !~ '^\d{4}-\d{2}$' THEN RAISE EXCEPTION 'month must be YYYY-MM' USING ERRCODE = 'PT422'; END IF;
  BEGIN m_start := (t || '-01')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'month must be YYYY-MM' USING ERRCODE = 'PT422'; END;
  m_end := (m_start + interval '1 month')::date;
END $$;

GRANT EXECUTE ON FUNCTION crm_private.hms_secs(text), crm_private.hours2(int), crm_private.fmt_hm(numeric), crm_private.day_status(text, text),
  crm_private.report_status(text, text, text, text), crm_private.require_attendance_admin(text),
  crm_private.month_range(text) TO authenticated;

-- GET /api/attendance?date= (Admin) ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_day(p_date text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE d date; rows json;
BEGIN
  PERFORM crm_private.require_attendance_admin('Only the Admin department can view CCTV attendance');
  d := coalesce(crm_private.to_date(p_date, 'date'), crm_private.today_ist());
  SELECT coalesce(json_agg(r ORDER BY r.ord NULLS LAST, r.record_id), '[]'::json) INTO rows FROM (
    SELECT a.id AS record_id, a.source_person_id AS person_id, a.person_name AS name, a.person_role AS role,
           a.crm_id, a.date, a.entry_time, a.exit_time, a.updated_at, a.day_status,
           a.hours_worked::float8 AS hours_worked, a.status_override,
           crm_private.report_status(a.entry_time, a.exit_time, a.day_status, a.status_override) AS effective_status,
           a.override_at, a.entry_time AS ord
      FROM public.cctv_attendance a WHERE a.date = d) r;
  RETURN json_build_object('date', to_char(d, 'YYYY-MM-DD'),
    'rows', (SELECT coalesce(json_agg(e::jsonb - 'ord'), '[]'::json) FROM json_array_elements(rows) e),
    'present', json_array_length(rows),
    'inside', (SELECT count(*) FROM json_array_elements(rows) e WHERE nullif(e->>'exit_time', '') IS NULL),
    'needs_review', (SELECT count(*) FROM json_array_elements(rows) e WHERE e->>'effective_status' IN ('short_day', 'missing_exit')));
END $$;

-- PATCH /api/attendance/{id} (Admin correction) -----------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_override(p_id int, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_attendance_admin(); a public.cctv_attendance;
        ne text; nx text; ov text; changed jsonb := '{}'::jsonb; ds record; touched boolean := false;
BEGIN
  SELECT * INTO a FROM public.cctv_attendance WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Attendance record not found' USING ERRCODE = 'PT404'; END IF;
  ne := a.entry_time; nx := a.exit_time;
  IF p_data ? 'entry_time' THEN
    IF nullif(p_data->>'entry_time', '') IS NOT NULL AND crm_private.hms_secs(p_data->>'entry_time') IS NULL THEN
      RAISE EXCEPTION 'entry_time must be HH:MM:SS' USING ERRCODE = 'PT422'; END IF;
    ne := nullif(p_data->>'entry_time', ''); changed := changed || jsonb_build_object('entry_time', ne); touched := true;
  END IF;
  IF p_data ? 'exit_time' THEN
    IF nullif(p_data->>'exit_time', '') IS NOT NULL AND crm_private.hms_secs(p_data->>'exit_time') IS NULL THEN
      RAISE EXCEPTION 'exit_time must be HH:MM:SS' USING ERRCODE = 'PT422'; END IF;
    nx := nullif(p_data->>'exit_time', ''); changed := changed || jsonb_build_object('exit_time', nx); touched := true;
  END IF;
  IF p_data ? 'status_override' THEN
    ov := nullif(p_data->>'status_override', '');
    IF ov IS NOT NULL AND ov NOT IN ('full_day', 'half_day', 'absent', 'leave') THEN
      RAISE EXCEPTION 'status_override must be one of (''full_day'', ''half_day'', ''absent'', ''leave'') or null' USING ERRCODE = 'PT422';
    END IF;
    changed := changed || jsonb_build_object('status_override', ov);
  END IF;
  IF changed = '{}'::jsonb THEN RAISE EXCEPTION 'Nothing to update' USING ERRCODE = 'PT400'; END IF;
  ds := crm_private.day_status(ne, nx);
  UPDATE public.cctv_attendance SET
    entry_time = ne, exit_time = nx,
    day_status = CASE WHEN touched THEN ds.status ELSE day_status END,
    hours_worked = CASE WHEN touched THEN ds.hours ELSE hours_worked END,
    status_override = CASE WHEN p_data ? 'status_override' THEN ov ELSE status_override END,
    override_by = eid, override_at = now(), updated_at = now()
  WHERE id = p_id;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'attendance_override', 'cctv_attendance', jsonb_build_object('record_id', p_id) || changed);
  RETURN json_build_object('status', 'updated', 'record_id', p_id, 'changes', changed);
END $$;

-- GET /api/attendance/device-people (Admin) -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_device_people() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE people json;
BEGIN
  PERFORM crm_private.require_attendance_admin();
  SELECT coalesce(json_agg(json_build_object(
      'device_person_id', regexp_replace(seen.source_person_id, '^hik:', ''),
      'source_person_id', seen.source_person_id, 'device_name', seen.device_name, 'last_seen', seen.last_seen,
      'is_mapped', m.display_name IS NOT NULL,
      'mapping', CASE WHEN m.display_name IS NOT NULL THEN json_build_object('person_type', m.person_type,
                   'crm_person_id', m.crm_person_id, 'display_name', m.display_name, 'role', m.role) END)
      ORDER BY (m.device_person_id IS NOT NULL), seen.last_seen DESC), '[]'::json)
    INTO people
    FROM (SELECT a.source_person_id, (array_agg(a.person_name ORDER BY a.date DESC))[1] AS device_name, max(a.date) AS last_seen
            FROM public.cctv_attendance a GROUP BY a.source_person_id) seen
    LEFT JOIN public.device_person_map m ON m.device_person_id = regexp_replace(seen.source_person_id, '^hik:', '');
  RETURN json_build_object('people', people,
    'unmapped', (SELECT count(*) FROM json_array_elements(people) p WHERE NOT (p->>'is_mapped')::boolean));
END $$;

-- POST /api/attendance/device-people/{id}/map (Admin) -------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_map(p_device_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_attendance_admin();
        pt text := btrim(coalesce(p_data->>'person_type', '')); rl text := btrim(coalesce(p_data->>'role', ''));
        dn text := btrim(coalesce(p_data->>'display_name', '')); cid uuid; n int;
BEGIN
  IF pt NOT IN ('employee', 'student') THEN RAISE EXCEPTION 'person_type must be ''employee'' or ''student''' USING ERRCODE = 'PT422'; END IF;
  IF rl NOT IN ('employee', 'student') THEN RAISE EXCEPTION 'role must be ''employee'' or ''student''' USING ERRCODE = 'PT422'; END IF;
  IF dn = '' THEN RAISE EXCEPTION 'display_name is required' USING ERRCODE = 'PT422'; END IF;
  cid := crm_private.to_uuid(p_data->>'crm_person_id', 'crm_person_id');
  IF cid IS NOT NULL AND NOT (
       (pt = 'employee' AND EXISTS (SELECT 1 FROM public.employee e WHERE e.id = cid)) OR
       (pt = 'student' AND EXISTS (SELECT 1 FROM public.student s WHERE s.id = cid))) THEN
    RAISE EXCEPTION 'No % found with id %', pt, cid USING ERRCODE = 'PT404';
  END IF;
  INSERT INTO public.device_person_map (device_person_id, person_type, crm_person_id, display_name, role)
  VALUES (p_device_id, pt, cid, dn, rl)
  ON CONFLICT (device_person_id) DO UPDATE SET person_type = EXCLUDED.person_type, crm_person_id = EXCLUDED.crm_person_id,
    display_name = EXCLUDED.display_name, role = EXCLUDED.role;
  UPDATE public.cctv_attendance SET person_name = dn, person_role = rl, crm_id = cid::text, updated_at = now()
   WHERE source_person_id IN (p_device_id, 'hik:' || p_device_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'map_device_person', 'device_person_map', jsonb_build_object('device_person_id', p_device_id, 'crm_person_id', cid));
  RETURN json_build_object('status', 'mapped', 'device_person_id', p_device_id, 'backfilled_rows', n);
END $$;

-- DELETE /api/attendance/device-people/{id}/map (Admin) -----------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_unmap(p_device_id text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_attendance_admin(); n int;
BEGIN
  DELETE FROM public.device_person_map WHERE device_person_id = p_device_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'No mapping for that device person' USING ERRCODE = 'PT404'; END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'unmap_device_person', 'device_person_map', jsonb_build_object('device_person_id', p_device_id));
  RETURN json_build_object('status', 'unmapped', 'device_person_id', p_device_id);
END $$;

-- GET /api/attendance/monthly?month=YYYY-MM (Admin) --------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_monthly(p_month text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r record; people json;
BEGIN
  PERFORM crm_private.require_attendance_admin();
  r := crm_private.month_range(p_month);
  WITH d AS (
    SELECT a.*, crm_private.report_status(a.entry_time, a.exit_time, a.day_status, a.status_override) AS st
      FROM public.cctv_attendance a WHERE a.date >= r.m_start AND a.date < r.m_end
  ), p AS (
    SELECT d.source_person_id,
           (array_agg(d.person_name ORDER BY d.date DESC))[1] AS name,
           (array_agg(d.person_role ORDER BY d.date DESC))[1] AS role,
           (array_agg(d.crm_id ORDER BY d.date DESC))[1] AS crm_id,
           count(*) AS days_present, min(d.date) AS first_seen, max(d.date) AS last_seen,
           count(*) FILTER (WHERE d.st = 'full_day') AS full_days,
           count(*) FILTER (WHERE d.st = 'half_day') AS half_days,
           count(*) FILTER (WHERE d.st IN ('short_day', 'missing_exit')) AS review,
           json_agg(json_build_object('date', d.date, 'entry_time', d.entry_time, 'exit_time', d.exit_time,
                    'status', d.st, 'hours_worked', d.hours_worked::float8) ORDER BY d.date) AS days
      FROM d GROUP BY d.source_person_id)
  SELECT coalesce(json_agg(json_build_object('source_person_id', p.source_person_id,
           'device_person_id', regexp_replace(p.source_person_id, '^hik:', ''), 'name', p.name, 'role', p.role,
           'crm_id', p.crm_id, 'days_present', p.days_present, 'first_seen', p.first_seen, 'last_seen', p.last_seen,
           'full_days', p.full_days, 'half_days', p.half_days, 'days_needing_review', p.review, 'days', p.days)
         ORDER BY coalesce(p.name, '') COLLATE "C"), '[]'::json)   -- same order as before (case-sensitive)
    INTO people FROM p;
  RETURN json_build_object('month', to_char(r.m_start, 'YYYY-MM'), 'people', people, 'person_count', json_array_length(people));
END $$;

-- GET /api/attendance/summary?months= (Admin) ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_attendance_summary(p_months int DEFAULT 12) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := greatest(1, least(coalesce(p_months, 12), 120));
BEGIN
  PERFORM crm_private.require_attendance_admin();
  RETURN json_build_object('months', n, 'rows', coalesce((
    SELECT json_agg(json_build_object('month', to_char(s.month, 'YYYY-MM'), 'source_person_id', s.source_person_id,
             'device_person_id', regexp_replace(s.source_person_id, '^hik:', ''), 'name', s.person_name, 'role', s.person_role,
             'crm_id', s.crm_id, 'days_present', s.days_present, 'first_date', s.first_date, 'last_date', s.last_date)
           ORDER BY s.month DESC, s.person_name)
      FROM public.attendance_monthly_summary s
     WHERE s.month >= (date_trunc('month', crm_private.today_ist()) - make_interval(months => n))::date), '[]'::json));
END $$;

-- GET /api/employees/{id}/attendance/{year}/{month} (self or Admin) -----------------------------
CREATE OR REPLACE FUNCTION public.api_employee_attendance(p_id uuid, p_year int, p_month int) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); nm text; mapped boolean; m_start date; m_end date;
        today date := crm_private.today_ist(); working int; wfh int; leave_wd int; present int; days json; summary json;
BEGIN
  IF NOT crm_private.is_admin() AND p_id <> eid THEN
    RAISE EXCEPTION 'Can only view your own attendance' USING ERRCODE = 'PT403';
  END IF;
  IF p_month NOT BETWEEN 1 AND 12 OR p_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Invalid year or month' USING ERRCODE = 'PT422';
  END IF;
  SELECT e.name INTO nm FROM public.employee e WHERE e.id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found' USING ERRCODE = 'PT404'; END IF;
  mapped := EXISTS (SELECT 1 FROM public.device_person_map m WHERE m.crm_person_id = p_id AND m.person_type = 'employee');
  m_start := make_date(p_year, p_month, 1); m_end := (m_start + interval '1 month')::date;

  -- working days: Mon-Sat, not after today
  SELECT count(*) INTO working FROM generate_series(m_start, m_end - 1, interval '1 day') g
   WHERE extract(isodow FROM g) <> 7 AND g::date <= today;
  SELECT count(*) FILTER (WHERE l.leave_type = 'wfh'),
         count(DISTINCT l.leave_date) FILTER (WHERE extract(isodow FROM l.leave_date) <> 7)
    INTO wfh, leave_wd
    FROM public.employee_leave_day l WHERE l.employee_id = p_id AND l.leave_date >= m_start AND l.leave_date < m_end;

  IF NOT mapped THEN
    RETURN json_build_object('employee_id', p_id, 'employee_name', nm, 'year', p_year, 'month', p_month, 'mapped', false,
      'days', '[]'::json, 'summary', json_build_object('days_present', 0, 'days_absent', 0, 'total_hours', 0.0,
        'average_entry_time', NULL, 'average_exit_time', NULL, 'working_days', working, 'full_days', 0, 'half_days', 0,
        'days_needing_review', 0, 'wfh_days', wfh));
  END IF;

  WITH a AS (
    SELECT c.date, c.entry_time, c.exit_time, crm_private.hms_secs(c.entry_time) AS e, crm_private.hms_secs(c.exit_time) AS x,
           crm_private.report_status(c.entry_time, c.exit_time, c.day_status, c.status_override) AS st
      FROM public.cctv_attendance c WHERE c.crm_id = p_id::text AND c.date >= m_start AND c.date < m_end
  ), h AS (
    SELECT a.*, CASE WHEN a.e IS NOT NULL AND a.x IS NOT NULL AND a.x >= a.e THEN crm_private.hours2(a.x - a.e) END AS hrs FROM a
  )
  SELECT coalesce(json_agg(json_build_object('date', h.date, 'entry_time', h.entry_time, 'exit_time', h.exit_time,
           'hours_worked', h.hrs::float8, 'status', h.st) ORDER BY h.date), '[]'::json),
         count(DISTINCT h.date) FILTER (WHERE nullif(h.entry_time, '') IS NOT NULL),
         json_build_object(
           'total_hours', round(coalesce(sum(h.hrs), 0), 2)::float8,
           'average_entry_time', crm_private.fmt_hm(avg(h.e) FILTER (WHERE nullif(h.entry_time, '') IS NOT NULL AND h.e IS NOT NULL)),
           'average_exit_time', crm_private.fmt_hm(avg(h.x)),
           'full_days', count(*) FILTER (WHERE h.st = 'full_day'),
           'half_days', count(*) FILTER (WHERE h.st = 'half_day'),
           'days_needing_review', count(*) FILTER (WHERE h.st IN ('short_day', 'missing_exit')))
    INTO days, present, summary FROM h;

  RETURN json_build_object('employee_id', p_id, 'employee_name', nm, 'year', p_year, 'month', p_month, 'mapped', true,
    'days', days,
    'summary', (summary::jsonb || jsonb_build_object('days_present', present,
                 'days_absent', greatest(working - present - leave_wd, 0), 'working_days', working, 'wfh_days', wfh))::json);
END $$;

-- ===========================================================================================
-- Device webhook / CCTV feed / partner lookup (called only by the crm-attendance Edge Function)
-- ===========================================================================================

-- One punch from the Hikvision terminal. Mirrors the Render webhook exactly.
CREATE OR REPLACE FUNCTION crm_private.hik_punch(p_emp text, p_name text, p_status text, p_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE local_ts timestamp := coalesce(p_at, now()) AT TIME ZONE 'Asia/Kolkata';
        d date := local_ts::date; t text := to_char(local_ts, 'HH24:MI:SS');
        src text := 'hik:' || btrim(p_emp); age int; ex record; m record; is_entry boolean; had_row boolean;
        pn text; pr text; pc text; ps int := crm_private.hms_secs(to_char(local_ts, 'HH24:MI:SS')); ds record;
BEGIN
  age := crm_private.today_ist() - d;
  IF age > 2 OR age < -1 THEN
    RETURN jsonb_build_object('status', 'ignored-stale', 'person_id', src, 'date', d);
  END IF;
  -- one punch at a time per person/day
  PERFORM pg_advisory_xact_lock(hashtext(src || '|' || d));

  SELECT a.entry_time, a.exit_time INTO ex FROM public.cctv_attendance a WHERE a.source_person_id = src AND a.date = d;
  had_row := FOUND;
  IF had_row AND (ex.entry_time = t OR ex.exit_time = t) THEN
    RETURN jsonb_build_object('status', 'ignored-duplicate', 'person_id', src, 'date', d, 'time', t);
  END IF;
  IF had_row AND ((crm_private.hms_secs(ex.entry_time) IS NOT NULL AND abs(ps - crm_private.hms_secs(ex.entry_time)) < 300) OR
                (crm_private.hms_secs(ex.exit_time) IS NOT NULL AND abs(ps - crm_private.hms_secs(ex.exit_time)) < 300)) THEN
    RETURN jsonb_build_object('status', 'ignored-retap', 'person_id', src, 'date', d, 'time', t);
  END IF;

  SELECT dm.display_name, dm.role, dm.crm_person_id INTO m FROM public.device_person_map dm WHERE dm.device_person_id = btrim(p_emp);
  IF FOUND THEN pn := m.display_name; pr := m.role; pc := m.crm_person_id::text;
  ELSE pn := coalesce(nullif(btrim(p_name), ''), btrim(p_emp)); pr := 'unmapped'; pc := NULL; END IF;

  is_entry := CASE lower(btrim(coalesce(p_status, ''))) WHEN 'checkin' THEN true WHEN 'checkout' THEN false
              ELSE NOT had_row END;   -- no in/out flag: first punch of the day = entry, later punches = exit

  IF is_entry THEN
    INSERT INTO public.cctv_attendance (source_person_id, person_name, person_role, crm_id, date, entry_time, updated_at)
    VALUES (src, pn, pr, pc, d, t, now())
    ON CONFLICT (source_person_id, date) DO UPDATE SET person_name = EXCLUDED.person_name, person_role = EXCLUDED.person_role,
      crm_id = EXCLUDED.crm_id, entry_time = coalesce(public.cctv_attendance.entry_time, EXCLUDED.entry_time), updated_at = now();
  ELSE
    INSERT INTO public.cctv_attendance (source_person_id, person_name, person_role, crm_id, date, exit_time, updated_at)
    VALUES (src, pn, pr, pc, d, t, now())
    ON CONFLICT (source_person_id, date) DO UPDATE SET person_name = EXCLUDED.person_name, person_role = EXCLUDED.person_role,
      crm_id = EXCLUDED.crm_id, exit_time = EXCLUDED.exit_time, updated_at = now();
  END IF;

  UPDATE public.cctv_attendance a SET day_status = s.status, hours_worked = s.hours
    FROM (SELECT (crm_private.day_status(b.entry_time, b.exit_time)).* FROM public.cctv_attendance b
           WHERE b.source_person_id = src AND b.date = d) s
   WHERE a.source_person_id = src AND a.date = d;

  RETURN jsonb_build_object('status', 'ok', 'person_id', src, 'date', d, 'time', t,
                            'type', CASE WHEN is_entry THEN 'entry' ELSE 'exit' END);
END $$;

-- CCTV system feed (Mac Mini): full upsert of a person's day.
CREATE OR REPLACE FUNCTION crm_private.cctv_ingest(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF nullif(p->>'person_id', '') IS NULL OR nullif(p->>'name', '') IS NULL OR nullif(p->>'date', '') IS NULL THEN
    RETURN jsonb_build_object('error', 'Fields required: (''person_id'', ''name'', ''date'')');
  END IF;
  INSERT INTO public.cctv_attendance (source_person_id, person_name, person_role, crm_id, date, entry_time, exit_time, updated_at)
  VALUES (p->>'person_id', p->>'name', p->>'role', p->>'crm_id', (p->>'date')::date, p->>'entry_time', p->>'exit_time', now())
  ON CONFLICT (source_person_id, date) DO UPDATE SET person_name = EXCLUDED.person_name, person_role = EXCLUDED.person_role,
    crm_id = EXCLUDED.crm_id, entry_time = EXCLUDED.entry_time, exit_time = EXCLUDED.exit_time, updated_at = now();
  RETURN jsonb_build_object('status', 'ok');
END $$;

-- Partner read-only lookup (e.g. DGCA prep site): one student's attendance by mobile number.
CREATE OR REPLACE FUNCTION crm_private.partner_attendance(p_mobile text, p_month text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE dg text := regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'); r record; s record; mapped boolean;
BEGIN
  IF length(dg) < 10 THEN RETURN jsonb_build_object('error', 'mobile must contain at least 10 digits', 'code', 422); END IF;
  BEGIN r := crm_private.month_range(p_month);
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('error', 'month must be YYYY-MM', 'code', 422); END;
  SELECT st.id, st.first_name, st.last_name, st.course INTO s FROM public.student st WHERE st.mobile_normalized = '+91' || right(dg, 10);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('linked', false, 'device_mapped', false, 'month', to_char(r.m_start, 'YYYY-MM'),
                              'student', NULL, 'days', '[]'::jsonb, 'recent', '[]'::jsonb);
  END IF;
  mapped := EXISTS (SELECT 1 FROM public.device_person_map m WHERE m.crm_person_id = s.id);
  RETURN jsonb_build_object('linked', true, 'device_mapped', mapped, 'month', to_char(r.m_start, 'YYYY-MM'),
    'student', jsonb_build_object('id', s.id, 'name', concat_ws(' ', nullif(s.first_name, ''), nullif(s.last_name, '')), 'course', s.course),
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('date', a.date, 'entry_time', a.entry_time, 'exit_time', a.exit_time,
               'status', crm_private.report_status(a.entry_time, a.exit_time, a.day_status, a.status_override),
               'hours_worked', a.hours_worked::float8) ORDER BY a.date)
             FROM public.cctv_attendance a WHERE a.crm_id = s.id::text AND a.date >= r.m_start AND a.date < r.m_end), '[]'::jsonb),
    'recent', coalesce((SELECT jsonb_agg(x.j ORDER BY x.date DESC) FROM (
               SELECT a.date, jsonb_build_object('date', a.date, 'entry_time', a.entry_time, 'exit_time', a.exit_time,
                 'status', crm_private.report_status(a.entry_time, a.exit_time, a.day_status, a.status_override),
                 'hours_worked', a.hours_worked::float8) AS j
                 FROM public.cctv_attendance a WHERE a.crm_id = s.id::text ORDER BY a.date DESC LIMIT 15) x), '[]'::jsonb));
END $$;

-- Monthly retention: roll months older than 3 months into the summary, then purge them (one transaction).
CREATE OR REPLACE FUNCTION crm_private.attendance_retention() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cutoff date := (date_trunc('month', crm_private.today_ist()) - interval '3 months')::date; ns int; nd int;
BEGIN
  INSERT INTO public.attendance_monthly_summary (month, source_person_id, person_name, person_role, crm_id, days_present, first_date, last_date)
  SELECT date_trunc('month', a.date)::date, a.source_person_id,
         (array_agg(a.person_name ORDER BY a.date DESC))[1], (array_agg(a.person_role ORDER BY a.date DESC))[1],
         (array_agg(a.crm_id ORDER BY a.date DESC))[1], count(DISTINCT a.date), min(a.date), max(a.date)
    FROM public.cctv_attendance a WHERE a.date < cutoff
   GROUP BY 1, 2
  ON CONFLICT (month, source_person_id) DO UPDATE SET person_name = EXCLUDED.person_name, person_role = EXCLUDED.person_role,
    crm_id = EXCLUDED.crm_id, days_present = EXCLUDED.days_present, first_date = EXCLUDED.first_date, last_date = EXCLUDED.last_date;
  GET DIAGNOSTICS ns = ROW_COUNT;
  DELETE FROM public.cctv_attendance WHERE date < cutoff;
  GET DIAGNOSTICS nd = ROW_COUNT;
  RETURN jsonb_build_object('cutoff', cutoff, 'rows_summarized', ns, 'rows_deleted', nd);
END $$;

-- Device / partner tokens in Vault (generated here, never shown in code or logs) -------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_attendance_ingest_token') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'crm_attendance_ingest_token',
                                'Token for the Hikvision terminal / CCTV feed (crm-attendance Edge Function)');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_partner_api_token') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'crm_partner_api_token',
                                'Token for partner apps reading student attendance (crm-attendance Edge Function)');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.token_ok(p_name text, p_token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN d.decrypted_secret IS NULL THEN NULL
              ELSE extensions.digest(coalesce(p_token, ''), 'sha256') = extensions.digest(d.decrypted_secret, 'sha256') END
    FROM (SELECT (SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.name = p_name) AS decrypted_secret) d
$$;

-- service_role-only wrappers for the Edge Function
CREATE OR REPLACE FUNCTION public.svc_attendance_token_ok(kind text, token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.token_ok(CASE kind WHEN 'partner' THEN 'crm_partner_api_token' ELSE 'crm_attendance_ingest_token' END, token)
$$;
CREATE OR REPLACE FUNCTION public.svc_hik_punch(emp text, name text, att_status text, at timestamptz) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.hik_punch(emp, name, att_status, at) $$;
CREATE OR REPLACE FUNCTION public.svc_cctv_ingest(payload jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.cctv_ingest(payload) $$;
CREATE OR REPLACE FUNCTION public.svc_partner_attendance(mobile text, month text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.partner_attendance(mobile, month) $$;
CREATE OR REPLACE FUNCTION public.svc_attendance_retention() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.attendance_retention() $$;

-- Permissions ----------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION crm_private.hik_punch(text, text, text, timestamptz), crm_private.cctv_ingest(jsonb),
  crm_private.partner_attendance(text, text), crm_private.attendance_retention(), crm_private.token_ok(text, text)
  FROM PUBLIC, anon, authenticated;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['svc_attendance_token_ok(text, text)', 'svc_hik_punch(text, text, text, timestamptz)',
    'svc_cctv_ingest(jsonb)', 'svc_partner_attendance(text, text)', 'svc_attendance_retention()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['api_attendance_day(text)', 'api_attendance_override(int, jsonb)', 'api_attendance_device_people()',
    'api_attendance_map(text, jsonb)', 'api_attendance_unmap(text)', 'api_attendance_monthly(text)',
    'api_attendance_summary(int)', 'api_employee_attendance(uuid, int, int)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
