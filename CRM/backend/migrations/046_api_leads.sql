-- 046: Leads module API on Supabase (port of the Render endpoints, same JSON shapes).
--
-- Every function is called by the CRM frontend through PostgREST (supabase.rpc).
-- Errors use SQLSTATE 'PTnnn', which PostgREST turns into HTTP status nnn, so the
-- frontend sees the same status codes and `detail` messages as from Render.
-- SECURITY INVOKER (default) unless stated: Row Level Security still applies.

-- Helper: same phone normalisation as lead_ingestion.normalize_phone (Python).
CREATE OR REPLACE FUNCTION crm_private.norm_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN d ~ '^91\d{10}$' THEN '+' || d
    WHEN length(d) = 10 THEN '+91' || d
    ELSE '+' || d
  END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x
$$;
GRANT EXECUTE ON FUNCTION crm_private.norm_phone(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION crm_private.require_employee() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.current_employee_id();
BEGIN
  IF eid IS NULL THEN
    RAISE EXCEPTION 'Could not validate credentials' USING ERRCODE = 'PT401';
  END IF;
  RETURN eid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.require_sales_or_admin(msg text DEFAULT 'Lead access requires Admin or Sales department')
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
BEGIN
  IF NOT crm_private.is_sales_or_admin() THEN
    RAISE EXCEPTION '%', msg USING ERRCODE = 'PT403';
  END IF;
  RETURN eid;
END $$;
GRANT EXECUTE ON FUNCTION crm_private.require_employee(), crm_private.require_sales_or_admin(text) TO authenticated;

-- GET /api/me -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_me() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee(); r json;
BEGIN
  SELECT json_build_object('id', e.id, 'name', e.name, 'phone', e.phone, 'email', e.email,
                           'department', e.department, 'active', e.active)
    INTO r FROM public.employee e WHERE e.id = eid;
  RETURN r;
END $$;

-- GET /api/config ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_config() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((SELECT json_object_agg(c.key, c.value) FROM public.config c), '{}'::json);
END $$;

-- GET /api/leads ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_leads() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_sales_or_admin();
  RETURN coalesce((
    SELECT json_agg(json_build_object(
      'id', l.id, 'name', l.name, 'phone', l.phone, 'email', l.email, 'address', l.address,
      'course_interest', l.course_interest, 'utm_source', l.utm_source, 'utm_medium', l.utm_medium,
      'utm_campaign', l.utm_campaign, 'status', coalesce(l.status, 'new'), 'assigned_to', l.assigned_to,
      'created_at', l.created_at, 'first_contacted_at', l.first_contacted_at, 'dedup_key', l.dedup_key,
      'last_note', l.last_note, 'parked', coalesce(l.parked, false), 'closed', coalesce(l.closed, false),
      'not_reachable_count', coalesce(nr.cnt, 0),
      'age_minutes', extract(epoch FROM (now() - l.created_at)) / 60,
      'closure_outcome', l.closure_outcome, 'guardian_name', l.guardian_name,
      'qualifications', coalesce(l.qualifications, '[]'::jsonb), 'is_eligible', l.is_eligible,
      'nios_interested', l.nios_interested, 'interest_track', l.interest_track,
      'segment', coalesce(l.segment, 'aviation'), 'charter_details', l.charter_details
    ) ORDER BY l.created_at DESC)
    FROM public.lead l
    LEFT JOIN (SELECT ca.lead_id, count(*) AS cnt FROM public.contact_attempt ca
               WHERE ca.disposition = 'Not reachable' GROUP BY ca.lead_id) nr ON nr.lead_id = l.id
  ), '[]'::json);
END $$;

-- POST /api/leads/{id}/contact ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_lead_contact(p_lead_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin();
        disp text := p_data->>'disposition'; note text := p_data->>'note';
        track text := p_data->>'interest_track'; attempt_id uuid; nr_count int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.lead WHERE id = p_lead_id) THEN
    RAISE EXCEPTION 'Lead not found' USING ERRCODE = 'PT404';
  END IF;
  INSERT INTO public.contact_attempt (lead_id, staff_id, channel, disposition, note, connected, attempted_at)
  VALUES (p_lead_id, eid, coalesce(p_data->>'channel', 'phone'), disp::public.disposition_enum, note,
          coalesce(disp IN ('Connected', 'Interested', 'Callback'), false), now())
  RETURNING id INTO attempt_id;

  UPDATE public.lead SET first_contacted_at = coalesce(first_contacted_at, now()), status = disp, last_note = note
   WHERE id = p_lead_id;
  IF disp = 'Interested' AND track IS NOT NULL AND track <> '' THEN
    UPDATE public.lead SET interest_track = track WHERE id = p_lead_id;
  END IF;
  IF disp = 'Not interested' THEN
    UPDATE public.lead SET closed = true WHERE id = p_lead_id;
  END IF;
  IF disp = 'Not reachable' THEN
    SELECT count(*) INTO nr_count FROM public.contact_attempt WHERE lead_id = p_lead_id AND disposition = 'Not reachable';
    IF nr_count >= 3 THEN UPDATE public.lead SET parked = true WHERE id = p_lead_id; END IF;
  END IF;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'contact', 'lead', json_build_object('lead_id', p_lead_id, 'disposition', disp)::jsonb);
  RETURN json_build_object('id', attempt_id);
END $$;

-- POST /api/leads/{id}/close -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_lead_close(p_lead_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin();
        outcome text := p_data->>'closure_outcome'; seg text;
BEGIN
  SELECT coalesce(segment, 'aviation') INTO seg FROM public.lead WHERE id = p_lead_id;
  IF seg IS NULL THEN RAISE EXCEPTION 'Lead not found' USING ERRCODE = 'PT404'; END IF;
  IF (seg = 'aviation' AND outcome NOT IN ('admission_completed', 'admission_aborted'))
     OR (seg = 'charter' AND outcome NOT IN ('booking_confirmed', 'booking_lost'))
     OR outcome IS NULL THEN
    RAISE EXCEPTION 'closure_outcome must be one of %', CASE seg WHEN 'charter'
      THEN '(''booking_confirmed'', ''booking_lost'')' ELSE '(''admission_completed'', ''admission_aborted'')' END
      USING ERRCODE = 'PT400';
  END IF;
  UPDATE public.lead
     SET status = 'closed', closed = true, closure_outcome = outcome::public.closure_outcome_enum,
         first_contacted_at = coalesce(first_contacted_at, now()),
         last_note = coalesce(p_data->>'note', last_note)
   WHERE id = p_lead_id;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'close', 'lead', json_build_object('lead_id', p_lead_id, 'closure_outcome', outcome)::jsonb);
  RETURN json_build_object('status', 'closed', 'closure_outcome', outcome);
END $$;

-- Charter helpers (port of charter_ingestion.py) ---------------------------------
CREATE OR REPLACE FUNCTION crm_private.charter_text(v jsonb, lim int) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN v IS NULL OR jsonb_typeof(v) = 'null' THEN NULL
              ELSE nullif(left(btrim(CASE jsonb_typeof(v) WHEN 'string' THEN v #>> '{}' ELSE v::text END), lim), '') END
$$;

CREATE OR REPLACE FUNCTION crm_private.valid_iso_date(s text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF s IS NULL OR s !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN false; END IF;
  PERFORM s::date; RETURN true;
EXCEPTION WHEN others THEN RETURN false;
END $$;

-- Returns the cleaned charter object or raises PT400 with "field: message" (first error),
-- the same message format the Render endpoint returned for Add Query.
CREATE OR REPLACE FUNCTION crm_private.validate_charter(d jsonb, require_date boolean) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE errs text[] := '{}'; name text; raw_phone text; digits text; origin text; dest text;
        dep text; pax_raw jsonb; pax int; email text; details jsonb; k text; lim int; v text;
        opt jsonb := '{"departureTime":5,"tripType":20,"returnDate":10,"aircraftPreference":40,"purpose":40,"additionalRequirements":2000,"sourcePath":200}';
BEGIN
  name := crm_private.charter_text(d->'name', 120);
  IF name IS NULL THEN errs := errs || 'name: Required'::text; END IF;
  raw_phone := coalesce(crm_private.charter_text(d->'phone', 30), '');
  digits := regexp_replace(raw_phone, '\D', '', 'g');
  IF length(digits) NOT BETWEEN 7 AND 15 THEN errs := errs || 'phone: Enter a valid phone number'::text; END IF;
  origin := crm_private.charter_text(d->'from', 200);
  dest := crm_private.charter_text(d->'to', 200);
  IF origin IS NULL THEN errs := errs || 'from: Required'::text; END IF;
  IF dest IS NULL THEN errs := errs || 'to: Required'::text; END IF;
  dep := crm_private.charter_text(d->'departureDate', 10);
  IF dep IS NOT NULL AND NOT crm_private.valid_iso_date(dep) THEN errs := errs || 'departureDate: Use YYYY-MM-DD'::text;
  ELSIF require_date AND dep IS NULL THEN errs := errs || 'departureDate: Required'::text; END IF;
  pax_raw := d->'passengers';
  IF pax_raw IS NULL OR jsonb_typeof(pax_raw) = 'null' OR (pax_raw #>> '{}') = '' THEN pax := NULL;
  ELSE
    BEGIN pax := (pax_raw #>> '{}')::numeric::int; EXCEPTION WHEN others THEN pax := -1; END;
  END IF;
  IF pax IS NOT NULL AND pax NOT BETWEEN 1 AND 500 THEN errs := errs || 'passengers: Between 1 and 500'::text; END IF;
  IF require_date AND pax IS NULL THEN errs := errs || 'passengers: Required'::text; END IF;
  email := crm_private.charter_text(d->'email', 200);
  IF email IS NOT NULL AND position('@' IN email) = 0 THEN errs := errs || 'email: Enter a valid email'::text; END IF;

  details := jsonb_build_object('from', origin, 'to', dest, 'departureDate', dep, 'passengers', pax);
  FOR k, lim IN SELECT key, value::int FROM jsonb_each_text(opt) LOOP
    v := crm_private.charter_text(d->k, lim);
    IF v IS NOT NULL THEN details := details || jsonb_build_object(k, v); END IF;
  END LOOP;
  IF details ? 'departureTime' AND (details->>'departureTime') !~ '^([01]\d|2[0-3]):[0-5]\d$' THEN
    errs := errs || 'departureTime: Use HH:MM'::text; END IF;
  IF details ? 'returnDate' AND NOT crm_private.valid_iso_date(details->>'returnDate') THEN
    errs := errs || 'returnDate: Use YYYY-MM-DD'::text; END IF;
  IF jsonb_typeof(d->'flexibleDates') = 'boolean' THEN details := details || jsonb_build_object('flexibleDates', d->'flexibleDates'); END IF;

  IF cardinality(errs) > 0 THEN
    RAISE EXCEPTION '%', errs[1] USING ERRCODE = 'PT400';  -- first error, same order as the Python version
  END IF;
  RETURN jsonb_build_object('name', name, 'phone', crm_private.norm_phone(raw_phone), 'email', email,
                            'details', jsonb_strip_nulls(details));
END $$;

CREATE OR REPLACE FUNCTION crm_private.charter_reference(lead_id uuid) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT 'BMC-' || upper(left(replace(lead_id::text, '-', ''), 8)) $$;

GRANT EXECUTE ON FUNCTION crm_private.charter_text(jsonb, int), crm_private.valid_iso_date(text),
  crm_private.validate_charter(jsonb, boolean), crm_private.charter_reference(uuid) TO authenticated, service_role;

-- POST /api/leads/query (Add Query) ----------------------------------------------
CREATE OR REPLACE FUNCTION public.api_lead_query(p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin();
        c jsonb; dkey text; ex_id uuid; ex_name text; new_id uuid; src text;
        name text; raw_phone text; course text; phone_n text; quals jsonb;
        req_qual text; elig boolean; nios boolean;
BEGIN
  IF p_data->>'segment' = 'charter' THEN
    c := crm_private.validate_charter(p_data, false);
    src := left(coalesce(nullif(p_data->>'utm_source', ''), 'Direct Call'), 80);
    dkey := 'charter:' || (c->>'phone') || ':' || lower(coalesce(btrim(c->'details'->>'from'), '')) || '|'
            || lower(coalesce(btrim(c->'details'->>'to'), '')) || '|' || lower(coalesce(btrim(c->'details'->>'departureDate'), ''));
    SELECT id, l.name INTO ex_id, ex_name FROM public.lead l WHERE dedup_key = dkey;
    IF ex_id IS NOT NULL THEN
      RETURN json_build_object('status', 'duplicate', 'lead_id', ex_id, 'name', ex_name,
                               'reference', crm_private.charter_reference(ex_id));
    END IF;
    INSERT INTO public.lead (name, phone, email, course_interest, utm_source, utm_medium, utm_campaign,
                             status, dedup_key, segment, charter_details)
    VALUES (c->>'name', c->>'phone', c->>'email', 'Charter', src, 'manual', 'add_query', 'new', dkey,
            'charter', c->'details')
    RETURNING id INTO new_id;
    INSERT INTO public.audit_log (actor, action, entity, payload)
    VALUES (eid, 'create', 'lead', json_build_object('lead_id', new_id, 'segment', 'charter', 'source', src)::jsonb);
    RETURN json_build_object('status', 'created', 'lead_id', new_id, 'reference', crm_private.charter_reference(new_id));
  END IF;

  name := btrim(coalesce(p_data->>'name', ''));
  raw_phone := btrim(coalesce(p_data->>'phone', ''));
  course := p_data->>'course_interest';
  IF name = '' OR raw_phone = '' OR course IS NULL OR course = '' THEN
    RAISE EXCEPTION 'Name, phone and course are required' USING ERRCODE = 'PT400';
  END IF;
  phone_n := crm_private.norm_phone(raw_phone);
  quals := coalesce(p_data->'qualifications', '[]'::jsonb);
  IF jsonb_typeof(quals) <> 'array' THEN quals := '[]'::jsonb; END IF;

  SELECT id, l.name INTO ex_id, ex_name FROM public.lead l WHERE dedup_key = phone_n;
  IF ex_id IS NOT NULL THEN
    RETURN json_build_object('status', 'duplicate', 'lead_id', ex_id, 'name', ex_name);
  END IF;

  SELECT value #>> '{}' INTO req_qual FROM public.config WHERE key = 'eligibility_required_qualification';
  req_qual := coalesce(req_qual, '12th with Physics & Maths');
  elig := quals ? req_qual;
  nios := CASE WHEN elig THEN NULL ELSE (p_data->>'nios_interested')::boolean END;

  INSERT INTO public.lead (name, phone, email, address, course_interest, utm_source, utm_medium, utm_campaign,
                           status, dedup_key, guardian_name, qualifications, is_eligible, nios_interested)
  VALUES (name, phone_n, p_data->>'email', p_data->>'address', course, p_data->>'utm_source', 'manual',
          'add_query', 'new', phone_n, p_data->>'guardian_name', quals, elig, nios)
  RETURNING id INTO new_id;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'create_query', 'lead', json_build_object('lead_id', new_id, 'source', p_data->>'utm_source',
          'is_eligible', elig, 'nios_interested', nios)::jsonb);
  RETURN json_build_object('status', 'created', 'lead_id', new_id, 'is_eligible', elig);
END $$;

-- POST /api/leads/{id}/followup ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_lead_followup(p_lead_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin(); fid uuid;
BEGIN
  INSERT INTO public.followup (lead_id, due_date, reason, created_by)
  VALUES (p_lead_id, (p_data->>'due_date')::timestamptz, p_data->>'reason', eid)
  RETURNING id INTO fid;
  RETURN json_build_object('id', fid);
END $$;

-- GET /api/followups/pending ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_followups_pending() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((
    SELECT json_agg(json_build_object('id', f.id, 'lead_id', f.lead_id, 'due_date', f.due_date,
             'reason', f.reason, 'lead_name', l.name, 'lead_phone', l.phone, 'course_interest', l.course_interest)
           ORDER BY f.due_date)
    FROM public.followup f JOIN public.lead l ON l.id = f.lead_id
    WHERE f.done = false AND f.due_date <= now() + interval '24 hours'
  ), '[]'::json);
END $$;

-- GET /api/reports/funnel ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_funnel() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((
    SELECT json_agg(row_to_json(x) ORDER BY x.total_leads DESC) FROM (
      SELECT l.utm_source, l.utm_medium, l.utm_campaign, count(*) AS total_leads,
             count(*) FILTER (WHERE l.first_contacted_at IS NOT NULL) AS contacted,
             count(*) FILTER (WHERE l.status = 'closed' AND l.id IN
               (SELECT ca.lead_id FROM public.contact_attempt ca WHERE ca.disposition = 'Interested')) AS interested
      FROM public.lead l GROUP BY l.utm_source, l.utm_medium, l.utm_campaign) x
  ), '[]'::json);
END $$;

-- GET /api/courses ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_courses() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((
    SELECT json_agg(json_build_object('id', c.id, 'code', c.code, 'name', c.name, 'base_fee', c.base_fee,
             'installment_count', c.installment_count, 'total_fee', c.base_fee + coalesce(li.total, 0))
           ORDER BY c.name)
    FROM public.course c
    LEFT JOIN (SELECT course_id, sum(amount) AS total FROM public.course_line_item GROUP BY course_id) li ON li.course_id = c.id
    WHERE c.active = true
  ), '[]'::json);
END $$;

-- PATCH /api/courses/{id}/installments -------------------------------------------
CREATE OR REPLACE FUNCTION public.api_course_installments(p_course_id uuid, p_data jsonb) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_sales_or_admin();
  UPDATE public.course SET installment_count = coalesce((p_data->>'installment_count')::int, 1) WHERE id = p_course_id;
  RETURN json_build_object('status', 'updated');
END $$;

-- GET /api/outbox ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_outbox() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_sales_or_admin('Outbox access requires Admin or Sales department');
  RETURN coalesce((
    SELECT json_agg(json_build_object('id', o.id, 'lead_id', o.lead_id, 'type', o.type, 'body', o.body,
             'status', o.status, 'created_at', o.created_at, 'lead_name', l.name, 'lead_phone', l.phone,
             'pdf_url', CASE WHEN o.type = 'quote' THEN '/api/quotes/' || o.id || '/pdf' END)
           ORDER BY o.created_at DESC)
    FROM public.outbox_message o JOIN public.lead l ON l.id = o.lead_id
    WHERE o.status::text IN ('draft', 'pending', 'approved')
  ), '[]'::json);
END $$;

CREATE OR REPLACE FUNCTION public.api_outbox_set_status(p_message_id uuid, p_status text) RETURNS json
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin('Outbox access requires Admin or Sales department');
BEGIN
  IF p_status NOT IN ('approved', 'sent') THEN RAISE EXCEPTION 'Invalid status' USING ERRCODE = 'PT400'; END IF;
  UPDATE public.outbox_message SET status = p_status::public.outbox_status_enum, approved_by = eid, approved_at = now() WHERE id = p_message_id;
  IF p_status = 'sent' THEN
    INSERT INTO public.audit_log (actor, action, entity, payload)
    VALUES (eid, 'mark_sent', 'outbox_message', json_build_object('message_id', p_message_id)::jsonb);
  END IF;
  RETURN json_build_object('status', p_status);
END $$;

-- GET /api/dispositions/* ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_disposition_stats() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN json_build_object(
    'interested', (SELECT count(*) FROM public.interested),
    'not_interested', (SELECT count(*) FROM public.not_interested),
    'not_reachable', (SELECT count(*) FROM public.not_reachable),
    'callback', (SELECT count(*) FROM public.callback));
END $$;

CREATE OR REPLACE FUNCTION public.api_disposition_list(p_kind text) RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  IF p_kind = 'callback' THEN
    RETURN coalesce((SELECT json_agg(json_build_object('id', t.id, 'lead_id', t.lead_id, 'name', t.name,
      'phone', t.phone, 'email', t.email, 'course_interest', t.course_interest, 'address', t.address, 'note', t.note,
      'callback_date', t.callback_date, 'callback_reason', t.callback_reason, 'marked_by', t.marked_by,
      'marked_at', t.marked_at) ORDER BY t.marked_at DESC) FROM public.callback t), '[]'::json);
  ELSIF p_kind = 'interested' THEN
    RETURN coalesce((SELECT json_agg(json_build_object('id', t.id, 'lead_id', t.lead_id, 'name', t.name,
      'phone', t.phone, 'email', t.email, 'course_interest', t.course_interest, 'address', t.address, 'note', t.note,
      'marked_by', t.marked_by, 'marked_at', t.marked_at) ORDER BY t.marked_at DESC) FROM public.interested t), '[]'::json);
  ELSIF p_kind = 'not-interested' THEN
    RETURN coalesce((SELECT json_agg(json_build_object('id', t.id, 'lead_id', t.lead_id, 'name', t.name,
      'phone', t.phone, 'email', t.email, 'course_interest', t.course_interest, 'address', t.address, 'note', t.note,
      'marked_by', t.marked_by, 'marked_at', t.marked_at) ORDER BY t.marked_at DESC) FROM public.not_interested t), '[]'::json);
  ELSIF p_kind = 'not-reachable' THEN
    RETURN coalesce((SELECT json_agg(json_build_object('id', t.id, 'lead_id', t.lead_id, 'name', t.name,
      'phone', t.phone, 'email', t.email, 'course_interest', t.course_interest, 'address', t.address, 'note', t.note,
      'marked_by', t.marked_by, 'marked_at', t.marked_at) ORDER BY t.marked_at DESC) FROM public.not_reachable t), '[]'::json);
  END IF;
  RAISE EXCEPTION 'Not Found' USING ERRCODE = 'PT404';
END $$;

-- GET /api/birthdays/today (needs other people's names: SECURITY DEFINER, employees only)
CREATE OR REPLACE FUNCTION public.api_birthdays_today() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; feb29 boolean;
BEGIN
  PERFORM crm_private.require_employee();
  feb29 := extract(month FROM today) = 2 AND extract(day FROM today) = 28
           AND NOT (extract(year FROM today)::int % 4 = 0 AND (extract(year FROM today)::int % 100 <> 0 OR extract(year FROM today)::int % 400 = 0));
  RETURN (
    SELECT coalesce(json_agg(x.j ORDER BY x.k1, x.k2), '[]'::json) FROM (
      SELECT 0 AS k1, e.name AS k2,
             json_build_object('id', e.id, 'name', e.name, 'type', 'employee', 'job_role', e.job_role,
                               'department', e.department) AS j
      FROM public.employee e
      WHERE e.active = true AND coalesce(e.status, 'active') <> 'non-active' AND e.date_of_birth IS NOT NULL
        AND ((extract(month FROM e.date_of_birth) = extract(month FROM today) AND extract(day FROM e.date_of_birth) = extract(day FROM today))
             OR (feb29 AND extract(month FROM e.date_of_birth) = 2 AND extract(day FROM e.date_of_birth) = 29))
      UNION ALL
      SELECT 1, coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, ''),
             json_build_object('id', s.id, 'name', concat_ws(' ', nullif(s.first_name, ''), nullif(s.middle_name, ''), nullif(s.last_name, '')),
                               'type', 'student', 'course', s.course)
      FROM public.student s
      WHERE s.date_of_birth IS NOT NULL
        AND ((extract(month FROM s.date_of_birth) = extract(month FROM today) AND extract(day FROM s.date_of_birth) = extract(day FROM today))
             OR (feb29 AND extract(month FROM s.date_of_birth) = 2 AND extract(day FROM s.date_of_birth) = 29))
    ) x
  );
END $$;

-- Privileges: signed-in users only (each function checks the role itself).
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_me()','public.api_config()','public.api_leads()',
    'public.api_lead_contact(uuid, jsonb)','public.api_lead_close(uuid, jsonb)','public.api_lead_query(jsonb)',
    'public.api_lead_followup(uuid, jsonb)','public.api_followups_pending()','public.api_funnel()',
    'public.api_courses()','public.api_course_installments(uuid, jsonb)','public.api_outbox()',
    'public.api_outbox_set_status(uuid, text)','public.api_disposition_stats()','public.api_disposition_list(text)',
    'public.api_birthdays_today()']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $$;
