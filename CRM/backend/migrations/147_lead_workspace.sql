-- 147: lead workspace. One set of student details, follow-ups, demo classes and notes for every Aviation lead:
-- organic leads (public.lead: website, JustDial, walk-in...) and Meta / Google leads (public.ads_lead).
-- Reads and writes go through the api_lead_ws_* functions below (security definer, with the same access checks as
-- the existing Leads and ADS functions). The ADS stage machine, Meta reporting and quality checks are not touched.

-- ---------------------------------------------------------------- student details
CREATE TABLE IF NOT EXISTS public.lead_profile (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id uuid UNIQUE REFERENCES public.lead(id) ON DELETE CASCADE,
  ads_lead_id uuid UNIQUE REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  class12 text CHECK (class12 IN ('appearing', 'completed', 'not_done')),
  class12_stream text CHECK (class12_stream IN ('pcm', 'pcmb', 'pcb', 'commerce', 'arts', 'other')),
  graduation text CHECK (graduation IN ('appearing', 'completed', 'not_done')),
  financial_issue boolean NOT NULL DEFAULT false,
  finance_help text[] NOT NULL DEFAULT '{}' CHECK (finance_help <@ ARRAY['loan', 'emi', 'scholarship']),
  updated_by uuid REFERENCES public.employee(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lead_profile_one_lead CHECK ((lead_id IS NULL) <> (ads_lead_id IS NULL))
);

-- ---------------------------------------------------------------- demo classes (online with a link, or at the institute)
CREATE TABLE IF NOT EXISTS public.demo_class (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id uuid REFERENCES public.lead(id) ON DELETE CASCADE,
  ads_lead_id uuid REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  mode text NOT NULL CHECK (mode IN ('online', 'offline')),
  scheduled_at timestamptz NOT NULL,
  has_time boolean NOT NULL DEFAULT true,
  meet_link text CHECK (meet_link IS NULL OR meet_link ~* '^https://[^\s]+$'),
  place text,
  note text,
  status text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'attended', 'no_show', 'cancelled')),
  task_id uuid REFERENCES public.task(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.employee(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT demo_class_one_lead CHECK ((lead_id IS NULL) <> (ads_lead_id IS NULL))
);
CREATE INDEX IF NOT EXISTS demo_class_lead_idx ON public.demo_class (lead_id) WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS demo_class_ads_idx ON public.demo_class (ads_lead_id) WHERE ads_lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS demo_class_when_idx ON public.demo_class (scheduled_at) WHERE status = 'scheduled';

-- ---------------------------------------------------------------- notes (with or without a call outcome)
CREATE TABLE IF NOT EXISTS public.lead_note (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id uuid REFERENCES public.lead(id) ON DELETE CASCADE,
  ads_lead_id uuid REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(btrim(body)) BETWEEN 1 AND 4000),
  created_by uuid REFERENCES public.employee(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lead_note_one_lead CHECK ((lead_id IS NULL) <> (ads_lead_id IS NULL))
);
CREATE INDEX IF NOT EXISTS lead_note_lead_idx ON public.lead_note (lead_id, created_at DESC) WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS lead_note_ads_idx ON public.lead_note (ads_lead_id, created_at DESC) WHERE ads_lead_id IS NOT NULL;

-- ---------------------------------------------------------------- follow-ups ("When to connect") for both kinds
ALTER TABLE public.followup ALTER COLUMN lead_id DROP NOT NULL;
ALTER TABLE public.followup ADD COLUMN IF NOT EXISTS ads_lead_id uuid REFERENCES public.ads_lead(id) ON DELETE CASCADE;
ALTER TABLE public.followup ADD COLUMN IF NOT EXISTS has_time boolean NOT NULL DEFAULT true;
ALTER TABLE public.followup ADD COLUMN IF NOT EXISTS task_id uuid REFERENCES public.task(id) ON DELETE SET NULL;
DO $$ BEGIN
  ALTER TABLE public.followup ADD CONSTRAINT followup_one_lead CHECK ((lead_id IS NULL) <> (ads_lead_id IS NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS followup_ads_idx ON public.followup (ads_lead_id) WHERE ads_lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS followup_open_due_idx ON public.followup (due_date) WHERE NOT coalesce(done, false);

-- Row security: the Leads page (api_leads, security invoker) reads organic rows; everything else goes through the
-- definer functions. Ads rows are visible to people with ADS access.
ALTER TABLE public.lead_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.demo_class ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lead_note ENABLE ROW LEVEL SECURITY;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['lead_profile', 'demo_class', 'lead_note'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS lw_select ON public.%I', t);
    EXECUTE format($p$CREATE POLICY lw_select ON public.%I FOR SELECT TO authenticated USING (
      (lead_id IS NOT NULL AND (SELECT crm_private.is_sales_or_admin())) OR
      (ads_lead_id IS NOT NULL AND (SELECT crm_private.ads_can_view())))$p$, t);
  END LOOP;
END $$;
REVOKE ALL ON public.lead_profile, public.demo_class, public.lead_note FROM anon;
GRANT SELECT ON public.lead_profile, public.demo_class, public.lead_note TO authenticated;

-- ---------------------------------------------------------------- helpers
-- Who may read (p_edit false) or change (p_edit true) this lead; returns the acting employee.
CREATE OR REPLACE FUNCTION crm_private.lw_access(p_kind text, p_id uuid, p_edit boolean)
 RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE me uuid;
BEGIN
  IF p_kind = 'lead' THEN
    me := crm_private.require_sales_or_admin('Only Sales or Admin can work on leads');
    IF NOT EXISTS (SELECT 1 FROM public.lead WHERE id = p_id) THEN RAISE EXCEPTION 'Lead not found' USING ERRCODE = 'PT404'; END IF;
  ELSIF p_kind = 'ads' THEN
    IF p_edit THEN me := crm_private.ads_require_lead_edit();
    ELSE PERFORM crm_private.ads_require_view(); me := crm_private.current_employee_id(); END IF;
    IF NOT EXISTS (SELECT 1 FROM public.ads_lead WHERE id = p_id AND deleted_at IS NULL) THEN
      RAISE EXCEPTION 'Lead not found' USING ERRCODE = 'PT404';
    END IF;
  ELSE
    RAISE EXCEPTION 'kind must be lead or ads' USING ERRCODE = 'PT400';
  END IF;
  RETURN me;
END $function$;

-- The employee a lead belongs to (falls back to the person acting).
CREATE OR REPLACE FUNCTION crm_private.lw_owner(p_kind text, p_id uuid, p_fallback uuid)
 RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT coalesce(
    CASE WHEN p_kind = 'lead' THEN (SELECT e.id FROM public.lead l JOIN public.employee e ON e.id = l.assigned_to AND e.active WHERE l.id = p_id)
         ELSE (SELECT e.id FROM public.ads_lead l JOIN public.employee e ON e.id = l.owner_employee_id AND e.active WHERE l.id = p_id) END,
    p_fallback)
$function$;

CREATE OR REPLACE FUNCTION crm_private.lw_name(p_kind text, p_id uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT CASE WHEN p_kind = 'lead' THEN (SELECT name FROM public.lead WHERE id = p_id)
              ELSE (SELECT name FROM public.ads_lead WHERE id = p_id) END
$function$;

-- A task on the Tasks board for the lead's owner (follow-up or demo).
CREATE OR REPLACE FUNCTION crm_private.lw_task(p_owner uuid, p_by uuid, p_title text, p_desc text, p_due timestamptz)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE tid uuid;
BEGIN
  INSERT INTO public.task (title, description, assigned_to, created_by, status, due_date)
  VALUES (left(p_title, 200), p_desc, p_owner, p_by, 'pending', p_due) RETURNING id INTO tid;
  RETURN tid;
END $function$;

CREATE OR REPLACE FUNCTION crm_private.lw_ts(p_raw text, p_what text)
 RETURNS timestamptz LANGUAGE plpgsql STABLE SET search_path TO ''
AS $function$
BEGIN
  IF p_raw IS NULL OR btrim(p_raw) = '' THEN RAISE EXCEPTION '% needs a date', p_what USING ERRCODE = 'PT400'; END IF;
  RETURN btrim(p_raw)::timestamptz;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  RAISE EXCEPTION '% must be a valid date', p_what USING ERRCODE = 'PT400';
END $function$;

-- ---------------------------------------------------------------- read: everything the lead window shows
CREATE OR REPLACE FUNCTION public.api_lead_ws(p_kind text, p_id uuid)
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE me uuid := crm_private.lw_access(p_kind, p_id, false); own uuid;
BEGIN
  own := CASE WHEN p_kind = 'lead' THEN (SELECT assigned_to FROM public.lead WHERE id = p_id)
              ELSE (SELECT owner_employee_id FROM public.ads_lead WHERE id = p_id) END;
  RETURN json_build_object(
    'profile', (SELECT to_json(p) FROM public.lead_profile p
                 WHERE (p_kind = 'lead' AND p.lead_id = p_id) OR (p_kind = 'ads' AND p.ads_lead_id = p_id)),
    'owner', (SELECT json_build_object('id', e.id, 'name', e.name) FROM public.employee e WHERE e.id = own),
    'followups', coalesce((SELECT json_agg(json_build_object('id', f.id, 'due_at', f.due_date, 'has_time', f.has_time,
                   'reason', f.reason, 'done', coalesce(f.done, false), 'completed_at', f.completed_at, 'created_at', f.created_at,
                   'by', e.name) ORDER BY f.due_date DESC)
                   FROM public.followup f LEFT JOIN public.employee e ON e.id = f.created_by
                  WHERE (p_kind = 'lead' AND f.lead_id = p_id) OR (p_kind = 'ads' AND f.ads_lead_id = p_id)), '[]'),
    'demos', coalesce((SELECT json_agg(json_build_object('id', d.id, 'mode', d.mode, 'at', d.scheduled_at, 'has_time', d.has_time,
                   'meet_link', d.meet_link, 'place', d.place, 'note', d.note, 'status', d.status, 'created_at', d.created_at,
                   'updated_at', d.updated_at, 'by', e.name) ORDER BY d.scheduled_at DESC)
                   FROM public.demo_class d LEFT JOIN public.employee e ON e.id = d.created_by
                  WHERE (p_kind = 'lead' AND d.lead_id = p_id) OR (p_kind = 'ads' AND d.ads_lead_id = p_id)), '[]'),
    'notes', coalesce((SELECT json_agg(json_build_object('id', n.id, 'body', n.body, 'at', n.created_at, 'by', e.name) ORDER BY n.created_at DESC)
                   FROM public.lead_note n LEFT JOIN public.employee e ON e.id = n.created_by
                  WHERE (p_kind = 'lead' AND n.lead_id = p_id) OR (p_kind = 'ads' AND n.ads_lead_id = p_id)), '[]'),
    'calls', CASE WHEN p_kind = 'lead' THEN coalesce((SELECT json_agg(json_build_object('id', c.id, 'at', c.attempted_at,
                   'outcome', c.disposition, 'note', c.note, 'channel', c.channel, 'by', e.name) ORDER BY c.attempted_at DESC)
                   FROM public.contact_attempt c LEFT JOIN public.employee e ON e.id = c.staff_id WHERE c.lead_id = p_id), '[]')
             ELSE '[]'::json END);
END $function$;

-- ---------------------------------------------------------------- write: details, note, when to connect, demo (one save)
-- p_data: { profile: {class12, class12_stream, graduation, financial_issue, finance_help[]},
--           note: text,
--           followup: {at, has_time, reason},
--           demo: {mode, at, has_time, meet_link, place, note} }
CREATE OR REPLACE FUNCTION public.api_lead_ws_save(p_kind text, p_id uuid, p_data jsonb)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE me uuid := crm_private.lw_access(p_kind, p_id, true);
        v_owner uuid := crm_private.lw_owner(p_kind, p_id, me);
        who text := crm_private.lw_name(p_kind, p_id);
        pr jsonb := p_data->'profile'; fu jsonb := p_data->'followup'; dm jsonb := p_data->'demo';
        nt text := nullif(btrim(p_data->>'note'), '');
        v_at timestamptz; tid uuid; fid uuid; did uuid; nid uuid; help text[];
BEGIN
  IF pr IS NOT NULL AND jsonb_typeof(pr) = 'object' THEN
    help := coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(pr->'finance_help', '[]'))), '{}');
    IF NOT coalesce((pr->>'financial_issue')::boolean, false) THEN help := '{}'; END IF;
    UPDATE public.lead_profile SET
      class12 = nullif(pr->>'class12', ''),
      class12_stream = CASE WHEN pr->>'class12' IN ('appearing', 'completed') THEN nullif(pr->>'class12_stream', '') END,
      graduation = nullif(pr->>'graduation', ''),
      financial_issue = coalesce((pr->>'financial_issue')::boolean, false), finance_help = help,
      updated_by = me, updated_at = now()
    WHERE (p_kind = 'lead' AND lead_id = p_id) OR (p_kind = 'ads' AND ads_lead_id = p_id);
    IF NOT FOUND THEN
      INSERT INTO public.lead_profile (lead_id, ads_lead_id, class12, class12_stream, graduation, financial_issue, finance_help, updated_by)
      VALUES (CASE WHEN p_kind = 'lead' THEN p_id END, CASE WHEN p_kind = 'ads' THEN p_id END,
              nullif(pr->>'class12', ''), CASE WHEN pr->>'class12' IN ('appearing', 'completed') THEN nullif(pr->>'class12_stream', '') END,
              nullif(pr->>'graduation', ''), coalesce((pr->>'financial_issue')::boolean, false), help, me);
    END IF;
    -- the existing Leads list shows qualifications: keep it in step for organic leads
    IF p_kind = 'lead' AND pr->>'class12' = 'completed' AND pr->>'class12_stream' IN ('pcm', 'pcmb') THEN
      UPDATE public.lead SET qualifications = (SELECT to_jsonb(array_agg(DISTINCT q)) FROM
        (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(qualifications) = 'array' THEN qualifications ELSE '[]' END) q UNION SELECT '12th with Physics & Maths') s)
      WHERE id = p_id;
    END IF;
  END IF;

  IF nt IS NOT NULL THEN
    INSERT INTO public.lead_note (lead_id, ads_lead_id, body, created_by)
    VALUES (CASE WHEN p_kind = 'lead' THEN p_id END, CASE WHEN p_kind = 'ads' THEN p_id END, left(nt, 4000), me) RETURNING id INTO nid;
    IF p_kind = 'lead' THEN UPDATE public.lead SET last_note = left(nt, 4000) WHERE id = p_id; END IF;
  END IF;

  IF fu IS NOT NULL AND jsonb_typeof(fu) = 'object' THEN
    v_at := crm_private.lw_ts(fu->>'at', 'When to connect');
    -- a new "when to connect" replaces the open ones (and their tasks)
    UPDATE public.task t SET status = 'done', completed_at = now() FROM public.followup f
     WHERE t.id = f.task_id AND NOT coalesce(f.done, false) AND t.status IN ('pending', 'in_progress')
       AND ((p_kind = 'lead' AND f.lead_id = p_id) OR (p_kind = 'ads' AND f.ads_lead_id = p_id));
    UPDATE public.followup SET done = true, completed_at = now()
     WHERE NOT coalesce(done, false) AND ((p_kind = 'lead' AND lead_id = p_id) OR (p_kind = 'ads' AND ads_lead_id = p_id));
    tid := crm_private.lw_task(v_owner, me, 'Call ' || coalesce(who, 'lead'),
             coalesce(nullif(btrim(fu->>'reason'), ''), 'Follow-up call') || ' (from Leads)', v_at);
    INSERT INTO public.followup (lead_id, ads_lead_id, due_date, has_time, reason, created_by, task_id)
    VALUES (CASE WHEN p_kind = 'lead' THEN p_id END, CASE WHEN p_kind = 'ads' THEN p_id END, v_at,
            coalesce((fu->>'has_time')::boolean, true), nullif(btrim(fu->>'reason'), ''), me, tid) RETURNING id INTO fid;
  END IF;

  IF dm IS NOT NULL AND jsonb_typeof(dm) = 'object' THEN
    v_at := crm_private.lw_ts(dm->>'at', 'Demo class');
    IF dm->>'mode' NOT IN ('online', 'offline') THEN RAISE EXCEPTION 'Choose Online or At the institute' USING ERRCODE = 'PT400'; END IF;
    IF nullif(btrim(dm->>'meet_link'), '') IS NOT NULL AND btrim(dm->>'meet_link') !~* '^https://[^\s]+$' THEN
      RAISE EXCEPTION 'The meeting link must start with https://' USING ERRCODE = 'PT400';
    END IF;
    tid := crm_private.lw_task(v_owner, me, 'Demo class: ' || coalesce(who, 'lead'),
             CASE WHEN dm->>'mode' = 'online' THEN 'Online demo' || coalesce(' · ' || nullif(btrim(dm->>'meet_link'), ''), '')
                  ELSE 'Demo at the institute' || coalesce(' · ' || nullif(btrim(dm->>'place'), ''), '') END, v_at);
    INSERT INTO public.demo_class (lead_id, ads_lead_id, mode, scheduled_at, has_time, meet_link, place, note, task_id, created_by)
    VALUES (CASE WHEN p_kind = 'lead' THEN p_id END, CASE WHEN p_kind = 'ads' THEN p_id END, dm->>'mode', v_at,
            coalesce((dm->>'has_time')::boolean, true), nullif(btrim(dm->>'meet_link'), ''), nullif(btrim(dm->>'place'), ''),
            nullif(btrim(dm->>'note'), ''), tid, me) RETURNING id INTO did;
  END IF;

  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (me, 'lead_workspace', p_kind, jsonb_build_object('lead_id', p_id, 'profile', pr IS NOT NULL, 'note', nid IS NOT NULL,
          'followup', fid, 'demo', did));
  RETURN json_build_object('followup_id', fid, 'demo_id', did, 'note_id', nid);
END $function$;

-- ---------------------------------------------------------------- demo outcome, follow-up done
CREATE OR REPLACE FUNCTION public.api_lead_ws_demo(p_demo uuid, p_status text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE d record; me uuid;
BEGIN
  SELECT * INTO d FROM public.demo_class WHERE id = p_demo FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Demo not found' USING ERRCODE = 'PT404'; END IF;
  me := crm_private.lw_access(CASE WHEN d.lead_id IS NOT NULL THEN 'lead' ELSE 'ads' END, coalesce(d.lead_id, d.ads_lead_id), true);
  IF p_status NOT IN ('scheduled', 'attended', 'no_show', 'cancelled') THEN RAISE EXCEPTION 'Unknown demo status' USING ERRCODE = 'PT400'; END IF;
  UPDATE public.demo_class SET status = p_status, updated_at = now() WHERE id = p_demo;
  UPDATE public.task SET status = CASE WHEN p_status = 'scheduled' THEN 'pending' WHEN p_status = 'cancelled' THEN 'aborted' ELSE 'done' END,
         completed_at = CASE WHEN p_status = 'scheduled' THEN NULL ELSE now() END
   WHERE id = d.task_id;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (me, 'demo_status', 'demo_class', jsonb_build_object('demo_id', p_demo, 'status', p_status));
  RETURN json_build_object('status', p_status);
END $function$;

CREATE OR REPLACE FUNCTION public.api_lead_ws_followup_done(p_followup uuid)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM public.followup WHERE id = p_followup FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Follow-up not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.lw_access(CASE WHEN f.lead_id IS NOT NULL THEN 'lead' ELSE 'ads' END, coalesce(f.lead_id, f.ads_lead_id), true);
  UPDATE public.followup SET done = true, completed_at = now() WHERE id = p_followup;
  UPDATE public.task SET status = 'done', completed_at = now() WHERE id = f.task_id AND status IN ('pending', 'in_progress');
  RETURN json_build_object('done', true);
END $function$;

-- ---------------------------------------------------------------- Today: calls and demos due (today + overdue), both kinds
CREATE OR REPLACE FUNCTION public.api_leads_today()
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE sales boolean := crm_private.is_sales_or_admin(); ads boolean := crm_private.ads_can_view();
        eod timestamptz := ((now() AT TIME ZONE 'Asia/Kolkata')::date + 1)::timestamp AT TIME ZONE 'Asia/Kolkata';
        sod timestamptz := ((now() AT TIME ZONE 'Asia/Kolkata')::date)::timestamp AT TIME ZONE 'Asia/Kolkata';
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((SELECT json_agg(x ORDER BY x.at) FROM (
    SELECT 'call' AS type, f.id, CASE WHEN f.lead_id IS NOT NULL THEN 'lead' ELSE 'ads' END AS kind,
           coalesce(f.lead_id, f.ads_lead_id) AS lead_id, coalesce(l.name, a.name) AS name, coalesce(l.phone, a.phone_e164) AS phone,
           f.due_date AS at, f.has_time, f.reason AS detail, NULL::text AS mode, NULL::text AS meet_link,
           f.due_date < sod AS overdue, e.name AS owner
      FROM public.followup f
 LEFT JOIN public.lead l ON l.id = f.lead_id
 LEFT JOIN public.ads_lead a ON a.id = f.ads_lead_id AND a.deleted_at IS NULL
 LEFT JOIN public.employee e ON e.id = coalesce(l.assigned_to, a.owner_employee_id)
     WHERE NOT coalesce(f.done, false) AND f.due_date < eod
       AND ((f.lead_id IS NOT NULL AND sales AND NOT coalesce(l.closed, false)) OR (a.id IS NOT NULL AND ads))
    UNION ALL
    SELECT 'demo', d.id, CASE WHEN d.lead_id IS NOT NULL THEN 'lead' ELSE 'ads' END, coalesce(d.lead_id, d.ads_lead_id),
           coalesce(l.name, a.name), coalesce(l.phone, a.phone_e164), d.scheduled_at, d.has_time,
           coalesce(d.place, d.note), d.mode, d.meet_link, d.scheduled_at < sod, e.name
      FROM public.demo_class d
 LEFT JOIN public.lead l ON l.id = d.lead_id
 LEFT JOIN public.ads_lead a ON a.id = d.ads_lead_id AND a.deleted_at IS NULL
 LEFT JOIN public.employee e ON e.id = coalesce(l.assigned_to, a.owner_employee_id)
     WHERE d.status = 'scheduled' AND d.scheduled_at < eod AND d.scheduled_at >= sod - interval '7 days'
       AND ((d.lead_id IS NOT NULL AND sales) OR (a.id IS NOT NULL AND ads))) x), '[]');
END $function$;

-- ---------------------------------------------------------------- Leads list: the new details on each organic lead
CREATE OR REPLACE FUNCTION public.api_leads()
 RETURNS json LANGUAGE plpgsql STABLE SET search_path TO ''
AS $function$
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
      'segment', coalesce(l.segment, 'aviation'), 'charter_details', l.charter_details,
      'profile', CASE WHEN p.id IS NULL THEN NULL ELSE json_build_object('class12', p.class12, 'class12_stream', p.class12_stream,
                   'graduation', p.graduation, 'financial_issue', p.financial_issue, 'finance_help', p.finance_help) END,
      'next_followup_at', nf.due_date, 'next_followup_has_time', nf.has_time,
      'demo', CASE WHEN dm.id IS NULL THEN NULL ELSE json_build_object('id', dm.id, 'at', dm.scheduled_at, 'has_time', dm.has_time,
                   'mode', dm.mode, 'status', dm.status) END
    ) ORDER BY l.created_at DESC)
    FROM public.lead l
    LEFT JOIN (SELECT ca.lead_id, count(*) AS cnt FROM public.contact_attempt ca
               WHERE ca.disposition = 'Not reachable' GROUP BY ca.lead_id) nr ON nr.lead_id = l.id
    LEFT JOIN public.lead_profile p ON p.lead_id = l.id
    LEFT JOIN LATERAL (SELECT f.due_date, f.has_time FROM public.followup f
                        WHERE f.lead_id = l.id AND NOT coalesce(f.done, false) ORDER BY f.due_date LIMIT 1) nf ON true
    LEFT JOIN LATERAL (SELECT d.id, d.scheduled_at, d.has_time, d.mode, d.status FROM public.demo_class d
                        WHERE d.lead_id = l.id AND d.status <> 'cancelled' ORDER BY (d.status = 'scheduled') DESC, d.scheduled_at DESC LIMIT 1) dm ON true
  ), '[]'::json);
END $function$;

REVOKE ALL ON FUNCTION public.api_lead_ws(text, uuid), public.api_lead_ws_save(text, uuid, jsonb), public.api_lead_ws_demo(uuid, text),
  public.api_lead_ws_followup_done(uuid), public.api_leads_today() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.api_lead_ws(text, uuid), public.api_lead_ws_save(text, uuid, jsonb), public.api_lead_ws_demo(uuid, text),
  public.api_lead_ws_followup_done(uuid), public.api_leads_today() TO authenticated;
REVOKE ALL ON FUNCTION crm_private.lw_access(text, uuid, boolean), crm_private.lw_owner(text, uuid, uuid), crm_private.lw_name(text, uuid),
  crm_private.lw_task(uuid, uuid, text, text, timestamptz), crm_private.lw_ts(text, text) FROM public, anon, authenticated;
