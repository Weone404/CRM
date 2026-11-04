-- 054: FlightBridge AI screens on Supabase (port of backend/flightbridge_routes.py).
--
-- The FlightBridge tab now reads and writes the database directly through these functions, so it works
-- without the Render server. The research engine (nikkk07/FlightBridge-AI) keeps running as a background job
-- (the Mac Mini runner, or Render until it is switched off) against the same tables; "Run now" only queues a
-- job_request that the engine picks up.
--
-- Nothing here sends email. Approvals are recorded; the engine's sending service runs the jurisdiction and
-- content gates and is the only component that can transmit (DRY_RUN / OUTBOUND_ENABLED / kill switch).
--
-- Roles (unchanged): 'admin' = CRM Admin department or employee.permissions.flightbridge = 'admin';
-- 'researcher' = permissions.flightbridge = 'researcher' (can verify schools/evidence, never approve or send).
-- Every write is recorded in flightbridge.audit_log with actor_type 'employee'.
--
-- API keys (Settings > Integrations) are saved and tested by the crm-flightbridge Edge Function, which encrypts
-- them exactly like the engine does (Fernet, FB_SECRETS_KEY), so the engine can keep reading them.

-- ===========================================================================================
-- Roles and helpers
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.fb_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN e.department::text = 'Admin' THEN 'admin'
              WHEN e.permissions->>'flightbridge' IN ('admin', 'researcher') THEN e.permissions->>'flightbridge' END
    FROM public.employee e WHERE e.auth_user_id = (SELECT auth.uid()) AND e.active = true LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.fb_member() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
BEGIN
  IF crm_private.fb_role() IS NULL THEN
    RAISE EXCEPTION 'FlightBridge access has not been granted to this account' USING ERRCODE = 'PT403';
  END IF;
  RETURN eid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.fb_admin() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
BEGIN
  IF crm_private.fb_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'This action needs a FlightBridge admin' USING ERRCODE = 'PT403';
  END IF;
  RETURN eid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.fb_audit(p_emp uuid, p_action text, p_entity text, p_entity_id text, p_payload jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO flightbridge.audit_log (actor_type, actor_id, action, entity, entity_id, payload)
  VALUES ('employee', p_emp, p_action, p_entity, p_entity_id, coalesce(p_payload, '{}'::jsonb))
$$;

-- Request-body readers (same rules as the old request models; a bad value answers 422).
CREATE OR REPLACE FUNCTION crm_private.fb_text(p jsonb, k text, maxlen int, required boolean DEFAULT false, minlen int DEFAULT 0)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v jsonb := p->k; s text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    IF required THEN RAISE EXCEPTION '% is required', k USING ERRCODE = 'PT422'; END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'string' THEN RAISE EXCEPTION '% must be text', k USING ERRCODE = 'PT422'; END IF;
  s := v #>> '{}';
  IF maxlen IS NOT NULL AND length(s) > maxlen THEN
    RAISE EXCEPTION '% must be at most % characters', k, maxlen USING ERRCODE = 'PT422';
  END IF;
  IF length(s) < minlen THEN RAISE EXCEPTION '% must be at least % characters', k, minlen USING ERRCODE = 'PT422'; END IF;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION crm_private.fb_bool(p jsonb, k text, dflt boolean DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v jsonb := p->k;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    IF dflt IS NULL THEN RAISE EXCEPTION '% is required', k USING ERRCODE = 'PT422'; END IF;
    RETURN dflt;
  END IF;
  IF jsonb_typeof(v) <> 'boolean' THEN RAISE EXCEPTION '% must be true or false', k USING ERRCODE = 'PT422'; END IF;
  RETURN v::boolean;
END $$;

-- Optional integer with bounds; NULL when absent (unless dflt given).
CREATE OR REPLACE FUNCTION crm_private.fb_int(p jsonb, k text, lo bigint, hi bigint, dflt bigint DEFAULT NULL, required boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v jsonb := p->k; n numeric;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    IF required THEN RAISE EXCEPTION '% is required', k USING ERRCODE = 'PT422'; END IF;
    RETURN dflt;
  END IF;
  IF jsonb_typeof(v) = 'number' THEN n := v::numeric;
  ELSIF jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^\s*-?\d+\s*$' THEN n := btrim(v #>> '{}')::numeric;
  ELSE RAISE EXCEPTION '% must be a whole number', k USING ERRCODE = 'PT422';
  END IF;
  IF n <> trunc(n) THEN RAISE EXCEPTION '% must be a whole number', k USING ERRCODE = 'PT422'; END IF;
  IF (lo IS NOT NULL AND n < lo) OR (hi IS NOT NULL AND n > hi) THEN
    RAISE EXCEPTION '% must be between % and %', k, lo, hi USING ERRCODE = 'PT422';
  END IF;
  RETURN n::bigint;
END $$;

CREATE OR REPLACE FUNCTION crm_private.fb_uuid(raw text, msg text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  RETURN raw::uuid;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION '%', msg USING ERRCODE = 'PT404';
END $$;

-- Python str.strip()
CREATE OR REPLACE FUNCTION crm_private.fb_strip(s text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT regexp_replace(coalesce(s, ''), '^\s+|\s+$', '', 'g') $$;

CREATE OR REPLACE FUNCTION crm_private.fb_set_setting(p_key text, p_value jsonb, p_emp uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO flightbridge.system_setting (key, value, updated_at, updated_by) VALUES (p_key, p_value, now(), p_emp)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by
$$;

-- A FlightBridge admin outside the Admin department may change only the 'flightbridge' entry of an
-- employee's permissions (Team screen); everything else still needs a CRM Admin.
CREATE OR REPLACE FUNCTION crm_private.guard_employee_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE np jsonb := NEW.permissions; op jsonb := OLD.permissions;
BEGIN
  IF (SELECT auth.role()) = 'authenticated' AND NOT crm_private.is_admin() THEN
    IF crm_private.fb_role() = 'admin' THEN
      np := coalesce(np, '{}'::jsonb) - 'flightbridge';
      op := coalesce(op, '{}'::jsonb) - 'flightbridge';
    END IF;
    IF (np, NEW.active, NEW.employee_id, NEW.joining_date, NEW.status, NEW.job_role,
        NEW.date_of_leaving, NEW.department, NEW.paid_leave_quota, NEW.login_id)
       IS DISTINCT FROM
       (op, OLD.active, OLD.employee_id, OLD.joining_date, OLD.status, OLD.job_role,
        OLD.date_of_leaving, OLD.department, OLD.paid_leave_quota, OLD.login_id) THEN
      RAISE EXCEPTION 'Only Admin can change job, role or status fields' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ===========================================================================================
-- Overview, approvals, outbound
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_fb_summary() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN json_build_object(
    'organisations', (SELECT coalesce(json_object_agg(status, n), '{}') FROM
        (SELECT status, count(*) n FROM flightbridge.organisation WHERE deleted_at IS NULL GROUP BY 1) s),
    'approvals', (SELECT coalesce(json_object_agg(status, n), '{}') FROM
        (SELECT status, count(*) n FROM flightbridge.approval_task GROUP BY 1) s),
    'outbound', (SELECT coalesce(json_object_agg(status, n), '{}') FROM
        (SELECT status, count(*) n FROM flightbridge.outbound_message GROUP BY 1) s),
    'kill_switches', (SELECT coalesce(json_object_agg(key, value), '{}') FROM flightbridge.system_setting WHERE key LIKE '%kill_switch'),
    'suppressions', (SELECT count(*) FROM flightbridge.suppression));
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_approvals(p_status text DEFAULT 'open') RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT a.id, a.status, a.risk, a.escalation_reason, a.created_at, a.assigned_to,
           d.kind, d.subject, o.name AS org_name, o.country, c.email
      FROM flightbridge.approval_task a
      JOIN flightbridge.ai_draft d ON d.id = a.draft_id
      JOIN flightbridge.organisation o ON o.id = d.org_id
      JOIN flightbridge.contact c ON c.id = d.contact_id
     WHERE a.status = p_status
     ORDER BY CASE a.risk WHEN 'RED' THEN 0 WHEN 'AMBER' THEN 1 ELSE 2 END, a.created_at
     LIMIT 200) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_approval(p_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE tid uuid; t jsonb; org uuid; con uuid; th uuid;
BEGIN
  PERFORM crm_private.fb_member();
  tid := crm_private.fb_uuid(p_id, 'Approval task not found');
  SELECT to_jsonb(x), x.org_id, x.contact_id, x.thread_id INTO t, org, con, th FROM (
    SELECT a.*, d.kind, d.intent, d.summary, d.extracted_questions, d.subject AS draft_subject,
           d.body_text AS draft_body, d.evidence, d.generator, d.thread_id, d.inbound_message_id, d.org_id, d.contact_id
      FROM flightbridge.approval_task a JOIN flightbridge.ai_draft d ON d.id = a.draft_id WHERE a.id = tid) x;
  IF t IS NULL THEN RAISE EXCEPTION 'Approval task not found' USING ERRCODE = 'PT404'; END IF;
  RETURN t || jsonb_build_object(
    'organisation', (SELECT to_jsonb(x) FROM (SELECT id, name, country, city, website_domain, status, entity_type
                       FROM flightbridge.organisation WHERE id = org) x),
    'regulatory', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT authority_code, classification, approval_ref, status,
                       source_url, checked_at, next_check_due FROM flightbridge.regulatory_approval WHERE org_id = org) x), '[]'),
    'qualification', (SELECT to_jsonb(x) FROM (SELECT score, breakdown, missing, risks, recommended_action, confidence, computed_at
                       FROM flightbridge.qualification_result WHERE org_id = org ORDER BY computed_at DESC LIMIT 1) x),
    'contact', (SELECT to_jsonb(x) FROM (SELECT id, email, is_role_address, role, source_url
                       FROM flightbridge.contact WHERE id = con) x),
    'contact_evidence', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.verified_at DESC) FROM (SELECT fact, method, source_url,
                       excerpt, verified_at, expires_at FROM flightbridge.contact_fact_evidence WHERE contact_id = con) x), '[]'),
    'thread', CASE WHEN th IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurred_at) FROM (
                       SELECT direction, from_address, subject, body_text, occurred_at
                         FROM flightbridge.email_message WHERE thread_id = th) x), '[]') END);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_decision(p_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); tid uuid;
  act text := crm_private.fb_text(p_data, 'action', NULL, true);
  subj text := crm_private.fb_text(p_data, 'subject', 150);
  body text := crm_private.fb_text(p_data, 'body', 20000);
  note text := crm_private.fb_text(p_data, 'note', 2000);
  assign text := crm_private.fb_text(p_data, 'assign_to', NULL);
  st text; dsubj text; dbody text; new_status text; fs text; fb text; aid uuid;
BEGIN
  IF act NOT IN ('approve', 'edit_approve', 'reject', 'more_research', 'resolve', 'reassign') THEN
    RAISE EXCEPTION 'action must be one of [''approve'', ''edit_approve'', ''more_research'', ''reassign'', ''reject'', ''resolve'']'
      USING ERRCODE = 'PT400';
  END IF;
  tid := crm_private.fb_uuid(p_id, 'Approval task not found');
  SELECT a.status, d.subject, d.body_text INTO st, dsubj, dbody
    FROM flightbridge.approval_task a JOIN flightbridge.ai_draft d ON d.id = a.draft_id WHERE a.id = tid FOR UPDATE OF a;
  IF NOT FOUND THEN RAISE EXCEPTION 'Approval task not found' USING ERRCODE = 'PT404'; END IF;
  IF st <> 'open' THEN RAISE EXCEPTION 'Task already decided (%)', st USING ERRCODE = 'PT409'; END IF;

  IF act = 'reassign' THEN
    IF assign IS NULL OR assign = '' THEN RAISE EXCEPTION 'assign_to is required' USING ERRCODE = 'PT400'; END IF;
    BEGIN aid := assign::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'assign_to is not valid' USING ERRCODE = 'PT400'; END;
    UPDATE flightbridge.approval_task SET assigned_to = aid WHERE id = tid;
    PERFORM crm_private.fb_audit(eid, 'approval_reassigned', 'approval_task', tid::text, jsonb_build_object('to', assign));
    RETURN json_build_object('status', 'open', 'assigned_to', assign);
  END IF;

  new_status := CASE act WHEN 'approve' THEN 'approved' WHEN 'edit_approve' THEN 'edited_approved' WHEN 'reject' THEN 'rejected'
                         WHEN 'more_research' THEN 'more_research' ELSE 'resolved' END;
  IF act = 'approve' THEN
    fs := dsubj; fb := dbody;
  ELSIF act = 'edit_approve' THEN
    IF crm_private.fb_strip(subj) = '' OR crm_private.fb_strip(body) = '' THEN
      RAISE EXCEPTION 'Edited subject and body are required' USING ERRCODE = 'PT400';
    END IF;
    fs := crm_private.fb_strip(subj); fb := crm_private.fb_strip(body);
  END IF;
  UPDATE flightbridge.approval_task SET status = new_status, decided_by = eid, decided_at = now(),
         final_subject = fs, final_body = fb, decision_note = note
   WHERE id = tid AND status = 'open';
  PERFORM crm_private.fb_audit(eid, 'approval_' || new_status, 'approval_task', tid::text, jsonb_build_object(
    'note', note, 'edited', act = 'edit_approve',
    'original_subject', CASE WHEN act = 'edit_approve' THEN dsubj END,
    'original_body', CASE WHEN act = 'edit_approve' THEN dbody END));
  RETURN json_build_object('status', new_status, 'message', CASE WHEN new_status IN ('approved', 'edited_approved') THEN
    'Queued for the central sending service; it will run jurisdiction and content checks. '
    'Nothing is sent while DRY_RUN is on or the kill switch is engaged.' END);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_outbound(p_limit int DEFAULT 50) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT m.id, m.status, m.kind, m.subject, m.created_at, m.authorized_at, m.sent_at, m.ref_token,
           c.email, o.name AS org_name, o.country, e.decision AS jurisdiction, e.reasons AS jurisdiction_reasons,
           k.decision AS content, k.reasons AS content_reasons
      FROM flightbridge.outbound_message m
      JOIN flightbridge.contact c ON c.id = m.contact_id
      JOIN flightbridge.organisation o ON o.id = m.org_id
 LEFT JOIN LATERAL (SELECT decision, reasons FROM flightbridge.compliance_check
                     WHERE outbound_id = m.id AND kind = 'jurisdiction' ORDER BY id DESC LIMIT 1) e ON true
 LEFT JOIN LATERAL (SELECT decision, reasons FROM flightbridge.compliance_check
                     WHERE outbound_id = m.id AND kind = 'content' ORDER BY id DESC LIMIT 1) k ON true
     ORDER BY m.created_at DESC LIMIT greatest(1, least(coalesce(p_limit, 50), 200))) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_outbound_get(p_id text) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r json;
BEGIN
  PERFORM crm_private.fb_member();
  SELECT row_to_json(x) INTO r FROM (SELECT id, status, kind, subject, body_text, ref_token, created_at
    FROM flightbridge.outbound_message WHERE id = crm_private.fb_uuid(p_id, 'Not found')) x;
  IF r IS NULL THEN RAISE EXCEPTION 'Not found' USING ERRCODE = 'PT404'; END IF;
  RETURN r;
END $$;

-- After a person adds evidence, send a 'needs_review' message back through the gates.
CREATE OR REPLACE FUNCTION public.api_fb_outbound_recheck(p_id text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); v_org uuid;
BEGIN
  UPDATE flightbridge.outbound_message SET status = 'pending_checks', authorized_at = NULL
   WHERE id = crm_private.fb_uuid(p_id, 'Only messages in needs_review can be re-checked') AND status = 'needs_review'
  RETURNING id INTO v_org;
  IF v_org IS NULL THEN RAISE EXCEPTION 'Only messages in needs_review can be re-checked' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.fb_audit(eid, 'outbound_recheck_requested', 'outbound_message', v_org::text, '{}');
  RETURN json_build_object('status', 'pending_checks');
END $$;

-- ===========================================================================================
-- Evidence, suppressions, kill switch
-- ===========================================================================================
-- Facts a person may attest to, with the maximum validity the FlightBridge rules accept (days).
CREATE OR REPLACE FUNCTION crm_private.fb_human_fact_days(f text) RETURNS int
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE f WHEN 'address_conspicuously_published' THEN 90 WHEN 'no_refusal_statement_near_address' THEN 90
    WHEN 'message_relevant_to_business_role' THEN 180 WHEN 'recipient_is_corporate_subscriber' THEN 365
    WHEN 'legitimate_interests_assessment_done' THEN 365 WHEN 'refusal_statement_present' THEN 3650
    WHEN 'recipient_is_sole_trader_or_non_scottish_partnership' THEN 3650 END
$$;

CREATE OR REPLACE FUNCTION public.api_fb_evidence_add(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  con text := crm_private.fb_text(p_data, 'contact_id', NULL, true);
  fact text := crm_private.fb_text(p_data, 'fact', NULL, true);
  src text := crm_private.fb_text(p_data, 'source_url', 2048, true);
  ex text := crm_private.fb_text(p_data, 'excerpt', 2000, true, 3);
  days int; exp timestamptz; cid uuid; new_id bigint;
BEGIN
  days := crm_private.fb_human_fact_days(fact);
  IF days IS NULL THEN
    RAISE EXCEPTION 'fact must be one of [''address_conspicuously_published'', ''legitimate_interests_assessment_done'', '
      '''message_relevant_to_business_role'', ''no_refusal_statement_near_address'', ''recipient_is_corporate_subscriber'', '
      '''recipient_is_sole_trader_or_non_scottish_partnership'', ''refusal_statement_present'']' USING ERRCODE = 'PT400';
  END IF;
  IF NOT (lower(src) LIKE 'https://%' OR lower(src) LIKE 'http://%') THEN
    RAISE EXCEPTION 'source_url must be http(s)' USING ERRCODE = 'PT400';
  END IF;
  cid := crm_private.fb_uuid(con, 'Contact not found');
  IF NOT EXISTS (SELECT 1 FROM flightbridge.contact c WHERE c.id = cid) THEN
    RAISE EXCEPTION 'Contact not found' USING ERRCODE = 'PT404';
  END IF;
  exp := now() + make_interval(days => days);
  INSERT INTO flightbridge.contact_fact_evidence (contact_id, fact, source_url, excerpt, method, verified_by, expires_at)
  VALUES (cid, fact, src, crm_private.fb_strip(ex), 'human_verified', eid, exp) RETURNING id INTO new_id;
  PERFORM crm_private.fb_audit(eid, 'evidence_added', 'contact', cid::text, jsonb_build_object('fact', fact, 'evidence_id', new_id));
  RETURN json_build_object('id', new_id, 'expires_at', exp);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_suppressions() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT s.id, s.scope, s.domain, s.reason, s.created_at, o.name AS org_name
      FROM flightbridge.suppression s LEFT JOIN flightbridge.organisation o ON o.id = s.org_id
     ORDER BY s.created_at DESC LIMIT 500) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_suppression_add(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  sc text := crm_private.fb_text(p_data, 'scope', NULL, true);
  em text := crm_private.fb_text(p_data, 'email', NULL);
  org text := crm_private.fb_text(p_data, 'org_id', NULL);
  dom text := crm_private.fb_text(p_data, 'domain', NULL);
  v_reason text := coalesce(crm_private.fb_text(p_data, 'reason', NULL), 'manual');
  h text; o uuid; d text; new_id bigint;
BEGIN
  IF sc = 'contact' AND coalesce(em, '') <> '' THEN
    h := encode(sha256(convert_to(lower(crm_private.fb_strip(em)), 'UTF8')), 'hex');
  ELSIF sc = 'organisation' AND coalesce(org, '') <> '' THEN
    BEGIN o := org::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'org_id is not valid' USING ERRCODE = 'PT400'; END;
  ELSIF sc = 'domain' AND coalesce(dom, '') <> '' THEN
    d := lower(crm_private.fb_strip(dom));
  ELSE
    RAISE EXCEPTION 'scope must be contact(email) | organisation(org_id) | domain(domain)' USING ERRCODE = 'PT400';
  END IF;
  BEGIN
    INSERT INTO flightbridge.suppression (scope, email_hash, org_id, domain, reason, created_by)
    VALUES (sc, h, o, d, v_reason, eid) ON CONFLICT DO NOTHING RETURNING id INTO new_id;
    PERFORM crm_private.fb_audit(eid, 'suppression_added', 'suppression', coalesce(new_id::text, 'existing'),
                                 jsonb_build_object('scope', sc));
  EXCEPTION
    WHEN raise_exception THEN RAISE EXCEPTION '%', split_part(SQLERRM, E'\n', 1) USING ERRCODE = 'PT400';
    WHEN check_violation THEN RAISE EXCEPTION 'Invalid suppression (scope/reason)' USING ERRCODE = 'PT400';
    WHEN foreign_key_violation THEN RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT400';
  END;
  RETURN json_build_object('status', 'suppressed');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_kill_switch(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); on_ boolean := crm_private.fb_bool(p_data, 'engaged');
BEGIN
  PERFORM crm_private.fb_set_setting('outbound_kill_switch', to_jsonb(on_), eid);
  PERFORM crm_private.fb_audit(eid, 'kill_switch_set', 'system_setting', 'outbound_kill_switch', jsonb_build_object('engaged', on_));
  RETURN json_build_object('outbound_kill_switch', on_,
    'note', 'Releasing the kill switch alone sends nothing: DRY_RUN=false and OUTBOUND_ENABLED=true are also required.');
END $$;

-- ===========================================================================================
-- Outreach templates. Save-time checks are a COPY of flightbridge/outreach/templates.py validate() and the
-- BANNED_CLAIMS list in flightbridge/compliance/content.py (as was backend/flightbridge_template_rules.py).
-- They only give the editor instant feedback; the engine's content gate re-checks every email at send time.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.fb_template_validate(p_subject text, p_body text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE subj text := crm_private.fb_strip(p_subject); body text := crm_private.fb_strip(p_body);
  errors text[] := '{}'; warnings text[] := '{}'; used text[]; nm text; stripped text; hits text[];
  allowed text[] := ARRAY['city', 'country', 'school_name'];
  var_re text := '\{\{\s*([a-zA-Z_]+)\s*\}\}';
BEGIN
  IF subj = '' OR length(subj) > 150 THEN errors := errors || 'subject must be 1-150 characters'::text; END IF;
  IF length(body) < 20 THEN errors := errors || 'body is too short'::text; END IF;
  IF subj ~* '^\s*(re|fw|fwd)\s*:' THEN
    errors := errors || 'subject must not start with Re:/Fwd: (it would look like a reply)'::text;
  END IF;
  SELECT coalesce(array_agg(x ORDER BY x COLLATE "C"), '{}') INTO used
    FROM (SELECT DISTINCT m[1] AS x FROM regexp_matches(subj || body, var_re, 'g') m) s;
  FOREACH nm IN ARRAY used LOOP
    IF NOT nm = ANY (allowed) THEN
      errors := errors || format('unknown placeholder {{%s}} (allowed: {{city}}, {{country}}, {{school_name}})', nm);
    END IF;
  END LOOP;
  stripped := regexp_replace(subj || E'\n' || body, var_re, 'X', 'g');
  IF stripped ~* '\{\{|\}\}|\[\[|\]\]|PLACEHOLDER|\yTODO\y|lorem ipsum|<insert' THEN
    errors := errors || 'contains an unresolved placeholder or TODO'::text;
  END IF;
  SELECT array_agg(DISTINCT tag COLLATE "C" ORDER BY tag COLLATE "C") INTO hits FROM (VALUES
    ('\y\d[\d,]*\s*\+?\s*(pilots|students|candidates|graduates)\y', 'unverified_volume_claim'),
    ('100\s*%\s*placement', 'unverified_placement_claim'),
    ('\yplacement (guarantee|assured|assistance)\y', 'unverified_placement_claim'),
    ('(?n)\yguarantee(d)?\y.*\y(job|placement|licen[cs]e|pass)\y', 'guarantee_claim'),
    ('\your (flying school|aircraft|fleet)\y', 'operates_aircraft_claim'),
    ('\yDGCA[- ]approved\y', 'unverified_regulatory_claim'),
    ('\y(approved|certified|registered) (FTO|flying training organi[sz]ation|ATO)\y', 'unverified_regulatory_claim'),
    ('\ysince 2011\y', 'contradicted_founding_year'),
    ('\y(airline partners?|partner airlines?)\y', 'unverified_partner_claim'),
    ('\y(india''?s )?(most trusted|best|no\.? ?1|#1|premier|leading)\y', 'superlative_claim'),
    ('flystar|flying star', 'other_brand')) b(pat, tag)
   WHERE stripped ~* pat;
  IF hits IS NOT NULL THEN
    errors := errors || ('contains claims that are not approved: ' || array_to_string(hits, ', '));
  END IF;
  IF body ~* '(?n)(unsubscribe|^\s*--\s*$|\yRef:\s*FB-)' THEN
    warnings := warnings || 'do not add an unsubscribe line, signature divider or Ref: — the system appends the legal footer'::text;
  END IF;
  RETURN jsonb_build_object('ok', cardinality(errors) = 0, 'errors', to_jsonb(errors), 'warnings', to_jsonb(warnings),
    'placeholders', to_jsonb(ARRAY(SELECT u FROM unnest(used) u WHERE u = ANY (allowed) ORDER BY u COLLATE "C")));
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_templates() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT id, kind, version, subject, body, status, validation, created_at, approved_at
      FROM flightbridge.outreach_template ORDER BY kind, version DESC LIMIT 200) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_template_save(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  k text := crm_private.fb_text(p_data, 'kind', NULL, true);
  subj text := crm_private.fb_text(p_data, 'subject', 150, true);
  body text := crm_private.fb_text(p_data, 'body', 20000, true);
  v jsonb; ver int; tid uuid;
BEGIN
  IF k NOT IN ('initial', 'followup_1', 'followup_2', 'followup_3') THEN
    RAISE EXCEPTION 'kind must be one of [''initial'', ''followup_1'', ''followup_2'', ''followup_3'']' USING ERRCODE = 'PT400';
  END IF;
  v := crm_private.fb_template_validate(subj, body);
  IF length(crm_private.fb_strip(body)) < 20 OR crm_private.fb_strip(subj) = '' THEN
    RAISE EXCEPTION '%', coalesce(nullif((SELECT string_agg(e, '; ') FROM jsonb_array_elements_text(v->'errors') e), ''),
                                  'subject and body are required') USING ERRCODE = 'PT400';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('fb_template|' || k));
  SELECT coalesce(max(version), 0) + 1 INTO ver FROM flightbridge.outreach_template WHERE kind = k;
  INSERT INTO flightbridge.outreach_template (kind, version, subject, body, validation, created_by)
  VALUES (k, ver, crm_private.fb_strip(subj), crm_private.fb_strip(body), v, eid) RETURNING id INTO tid;
  PERFORM crm_private.fb_audit(eid, 'template_saved', 'outreach_template', tid::text,
                               jsonb_build_object('kind', k, 'version', ver, 'ok', v->'ok'));
  RETURN json_build_object('id', tid, 'version', ver, 'validation', v);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_template_approve(p_id text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); tid uuid := crm_private.fb_uuid(p_id, 'Template not found'); t record; v jsonb;
BEGIN
  SELECT kind, subject, body, status INTO t FROM flightbridge.outreach_template WHERE id = tid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Template not found' USING ERRCODE = 'PT404'; END IF;
  v := crm_private.fb_template_validate(t.subject, t.body);
  IF NOT (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'Fix before approving: %', (SELECT string_agg(e, '; ') FROM jsonb_array_elements_text(v->'errors') e)
      USING ERRCODE = 'PT400';
  END IF;
  UPDATE flightbridge.outreach_template SET status = 'archived' WHERE kind = t.kind AND status = 'approved';
  UPDATE flightbridge.outreach_template SET status = 'approved', approved_by = eid, approved_at = now(), validation = v WHERE id = tid;
  PERFORM crm_private.fb_audit(eid, 'template_approved', 'outreach_template', tid::text, jsonb_build_object('kind', t.kind));
  RETURN json_build_object('status', 'approved', 'kind', t.kind);
END $$;

-- ===========================================================================================
-- Inbox, settings, metrics
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_fb_inbox(p_risk text DEFAULT NULL, p_unmatched boolean DEFAULT false, p_limit int DEFAULT 100)
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT m.id, m.thread_id, m.from_address, m.subject, left(m.body_text, 600) AS preview, m.occurred_at,
           m.match_method, m.is_bounce, m.is_auto_reply, m.is_unsubscribe, k.intent, k.risk, k.confidence,
           k.signals, k.injection, o.name AS org_name, o.country
      FROM flightbridge.email_message m
 LEFT JOIN flightbridge.ai_classification k ON k.message_id = m.id
      JOIN flightbridge.email_thread t ON t.id = m.thread_id
 LEFT JOIN flightbridge.organisation o ON o.id = t.org_id
     WHERE m.direction = 'inbound'
       AND (p_risk IS NULL OR p_risk NOT IN ('GREEN', 'AMBER', 'RED') OR k.risk = p_risk)
       AND (NOT coalesce(p_unmatched, false) OR m.match_method = 'unmatched')
     ORDER BY m.occurred_at DESC LIMIT greatest(1, least(coalesce(p_limit, 100), 300))) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_settings() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_object_agg(key, value) FROM flightbridge.system_setting), '{}');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_followups_set(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); d jsonb := p_data->'days'; days int[] := '{}'; e jsonb; i int;
  bad text := 'Give 1-3 increasing day offsets between 2 and 60, e.g. [4, 9, 16]';
BEGIN
  IF d IS NULL OR jsonb_typeof(d) <> 'array' THEN RAISE EXCEPTION 'days must be a list of whole numbers' USING ERRCODE = 'PT422'; END IF;
  FOR e IN SELECT value FROM jsonb_array_elements(d) LOOP
    IF jsonb_typeof(e) <> 'number' OR e::numeric <> trunc(e::numeric) THEN
      RAISE EXCEPTION 'days must be a list of whole numbers' USING ERRCODE = 'PT422';
    END IF;
    days := days || e::numeric::int;
  END LOOP;
  IF cardinality(days) NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION '%', bad USING ERRCODE = 'PT400'; END IF;
  FOR i IN 1 .. cardinality(days) LOOP
    IF days[i] < 2 OR days[i] > 60 OR (i > 1 AND days[i] <= days[i - 1]) THEN RAISE EXCEPTION '%', bad USING ERRCODE = 'PT400'; END IF;
  END LOOP;
  PERFORM crm_private.fb_set_setting('followup_schedule_days', to_jsonb(days), eid);
  PERFORM crm_private.fb_audit(eid, 'followup_schedule_set', 'system_setting', 'followup_schedule_days', jsonb_build_object('days', days));
  RETURN json_build_object('followup_schedule_days', days);
END $$;

-- contacted = distinct orgs with >=1 SENT initial; replied = contacted orgs with >=1 non-auto, non-bounce inbound;
-- response_rate = replied / contacted. Opens are NOT tracked (a pixel cannot prove an email was read).
CREATE OR REPLACE FUNCTION public.api_fb_metrics() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r record;
BEGIN
  PERFORM crm_private.fb_member();
  WITH sent AS (SELECT DISTINCT org_id FROM flightbridge.outbound_message WHERE kind = 'initial' AND status = 'sent'),
       replied AS (SELECT DISTINCT t.org_id FROM flightbridge.email_message m JOIN flightbridge.email_thread t ON t.id = m.thread_id
                   WHERE m.direction = 'inbound' AND NOT m.is_auto_reply AND NOT m.is_bounce AND t.org_id IN (SELECT org_id FROM sent))
  SELECT (SELECT count(*) FROM sent) AS contacted, (SELECT count(*) FROM replied) AS replied,
         (SELECT count(*) FROM flightbridge.email_message WHERE direction = 'inbound') AS inbound_total,
         (SELECT count(*) FROM flightbridge.email_message WHERE direction = 'inbound' AND is_bounce) AS bounces,
         (SELECT count(*) FROM flightbridge.approval_task WHERE status = 'open') AS a_open,
         (SELECT count(*) FROM flightbridge.approval_task WHERE status IN ('approved', 'edited_approved')) AS a_ok,
         (SELECT count(*) FROM flightbridge.approval_task WHERE status = 'edited_approved') AS a_edit,
         (SELECT count(*) FROM flightbridge.approval_task WHERE status = 'rejected') AS a_rej
    INTO r;
  RETURN json_build_object('schools_contacted', r.contacted, 'schools_replied', r.replied,
    'response_rate', CASE WHEN r.contacted > 0 THEN round(r.replied::numeric / r.contacted, 3)::float8 END,
    'inbound_total', r.inbound_total, 'bounces', r.bounces, 'approvals_open', r.a_open, 'approvals_approved', r.a_ok,
    'approvals_edited', r.a_edit, 'approvals_rejected', r.a_rej,
    'inbound_by_risk', (SELECT coalesce(json_object_agg(coalesce(risk, 'null'), n), '{}') FROM
        (SELECT risk, count(*) n FROM flightbridge.ai_classification GROUP BY 1) s),
    'schools_by_country', (SELECT coalesce(json_object_agg(country, n ORDER BY n DESC), '{}') FROM
        (SELECT o.country, count(DISTINCT o.id) n FROM flightbridge.organisation o WHERE o.deleted_at IS NULL GROUP BY 1) s));
END $$;

-- ===========================================================================================
-- Me and team
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_fb_me() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
BEGIN
  RETURN (SELECT json_build_object('id', e.id, 'name', e.name, 'department', e.department, 'role', crm_private.fb_role())
            FROM public.employee e WHERE e.id = eid);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_team() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_admin();
  RETURN coalesce((SELECT json_agg(json_build_object('id', e.id, 'name', e.name, 'department', e.department,
      'fb_role', coalesce(e.permissions->>'flightbridge', ''),
      'effective_role', CASE WHEN e.department::text = 'Admin' THEN 'admin' ELSE nullif(coalesce(e.permissions->>'flightbridge', ''), '') END)
      ORDER BY e.name) FROM public.employee e WHERE e.active = true), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_team_role(p_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); v_role text := crm_private.fb_text(p_data, 'role', NULL); tid uuid; got uuid;
BEGIN
  IF v_role IS NOT NULL AND v_role NOT IN ('researcher', 'admin') THEN
    RAISE EXCEPTION 'role must be researcher, admin or null' USING ERRCODE = 'PT400';
  END IF;
  tid := crm_private.fb_uuid(p_id, 'Employee not found');
  IF v_role IS NULL THEN
    UPDATE public.employee SET permissions = coalesce(permissions, '{}'::jsonb) - 'flightbridge' WHERE id = tid RETURNING id INTO got;
  ELSE
    UPDATE public.employee SET permissions = coalesce(permissions, '{}'::jsonb) || jsonb_build_object('flightbridge', v_role)
     WHERE id = tid RETURNING id INTO got;
  END IF;
  IF got IS NULL THEN RAISE EXCEPTION 'Employee not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.fb_audit(eid, 'flightbridge_role_set', 'employee', tid::text, jsonb_build_object('role', v_role));
  RETURN json_build_object('employee_id', tid, 'role', v_role);
END $$;

-- ===========================================================================================
-- Schools
-- ===========================================================================================
-- Per-country eligibility rules: COPY of flightbridge/config/eligibility.json (without "_comment"),
-- as shipped in the engine version pinned in backend/requirements.txt. Keep in sync.
CREATE OR REPLACE FUNCTION crm_private.fb_eligibility_rules() RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $rules$ SELECT '{"US":{"credential":"FAA Part 141 pilot school; SEVP certification for M-1 student visas","verified":["PART141_FAA","SEVP_M1"],"claims":["part141","sevp"],"confirm_as":{"authority":"FAA","classification":"PART141_FAA"},"lookup":[["FAA facility dashboard","https://www.faa.gov/av-info/facility-dashboard"],["SEVP school search","https://studyinthestates.dhs.gov/school-search"]]},"CA":{"credential":"Transport Canada Flight Training Unit; Designated Learning Institution (DLI) for study permits","verified":["FTU_TC","DLI_CA"],"claims":["transport_canada","dli"],"confirm_as":{"authority":"TC","classification":"FTU_TC"},"lookup":[["Transport Canada - choosing a flight school","https://tc.canada.ca/en/aviation/licensing-pilots-personnel/getting-trained-pilot-crew-member/how-select-flying-school"],["IRCC DLI list","https://www.canada.ca/en/immigration-refugees-citizenship/services/study-canada/study-permit/prepare/designated-learning-institutions-list.html"]]},"AU":{"credential":"CASA Part 141/142 operator; CRICOS registration for student-visa holders","verified":["CRICOS_PROVIDER","PART141_CASA","PART142_CASA"],"claims":["casa_part14x","cricos_on_site"],"confirm_as":{"authority":"CASA","classification":"PART141_CASA"},"lookup":[["CRICOS search","https://cricos.education.gov.au/"],["CASA flight training operators","https://www.casa.gov.au/search-centre/flight-training-operators"]]},"NZ":{"credential":"CAA NZ Part 141 aviation training organisation; NZQA international student provider","verified":["PART141_NZ","NZQA_PROVIDER"],"claims":["caa_nz_part141","nzqa"],"confirm_as":{"authority":"CAA_NZ","classification":"PART141_NZ"},"lookup":[["CAA NZ","https://www.aviation.govt.nz/"],["NZQA","https://www.nzqa.govt.nz/"]]},"GB":{"credential":"UK CAA Approved Training Organisation (ATO)","verified":["ATO_UK"],"claims":[],"confirm_as":{"authority":"UK_CAA","classification":"ATO_UK"},"lookup":[["UK CAA SD31","https://www.caa.co.uk/publication/download/13488"]]}}'::jsonb $rules$;

CREATE OR REPLACE FUNCTION public.api_fb_schools(p_filters jsonb DEFAULT '{}') RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE f jsonb := coalesce(p_filters, '{}');
  v_country text := nullif(f->>'country', ''); v_status text := nullif(f->>'status', ''); v_q text := nullif(f->>'q', '');
  v_region text := nullif(f->>'region', ''); v_elig text := f->>'eligibility'; v_kind text := f->>'kind';
  v_area bigint := crm_private.fb_int(f, 'area_id', NULL, NULL);
  lim int := greatest(1, least(coalesce(crm_private.fb_int(f, 'limit', NULL, NULL), 300), 1000));
BEGIN
  PERFORM crm_private.fb_member();
  IF v_elig NOT IN ('unknown', 'eligible_verified', 'eligible_claimed', 'unqualified') THEN v_elig := NULL; END IF;
  IF v_kind NOT IN ('flying_school', 'ground_school') THEN v_kind := NULL; END IF;
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT o.id, o.name, o.country, o.region, o.city, o.website_domain, o.status, o.rejection_reason, o.updated_at,
           o.area_id, o.eligibility, o.org_kind,
           (SELECT count(*) FROM flightbridge.contact_phone p WHERE p.org_id = o.id) AS phones,
           (SELECT array_agg(DISTINCT ch.kind) FROM flightbridge.contact_channel ch WHERE ch.org_id = o.id) AS channels,
           ra.authority_code, ra.classification, ra.approval_ref, ra.status AS approval_status, ra.checked_at,
           qr.score, qr.recommended_action,
           (SELECT count(*) FROM flightbridge.contact c WHERE c.org_id = o.id) AS contacts
      FROM flightbridge.organisation o
 LEFT JOIN LATERAL (SELECT * FROM flightbridge.regulatory_approval r WHERE r.org_id = o.id
                     ORDER BY r.checked_at DESC LIMIT 1) ra ON true
 LEFT JOIN LATERAL (SELECT score, recommended_action FROM flightbridge.qualification_result x WHERE x.org_id = o.id
                     ORDER BY computed_at DESC LIMIT 1) qr ON true
     WHERE o.deleted_at IS NULL
       AND (v_area IS NULL OR (v_area = 0 AND o.area_id IS NULL) OR (v_area <> 0 AND o.area_id = v_area))
       AND (v_elig IS NULL OR o.eligibility = v_elig)
       AND (v_kind IS NULL OR o.org_kind = v_kind)
       AND (v_country IS NULL OR o.country = left(upper(v_country), 2))
       AND (v_region IS NULL OR (v_region = '__none__' AND o.region IS NULL) OR (v_region <> '__none__' AND o.region = v_region))
       AND (v_status IS NULL OR o.status = v_status)
       AND (v_q IS NULL OR o.name ILIKE '%' || v_q || '%' OR o.website_domain ILIKE '%' || v_q || '%' OR ra.approval_ref ILIKE '%' || v_q || '%')
     ORDER BY o.country, o.region NULLS LAST, o.name LIMIT lim) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_school(p_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; o jsonb; rule jsonb;
BEGIN
  PERFORM crm_private.fb_member();
  v_org := crm_private.fb_uuid(p_id, 'School not found');
  SELECT to_jsonb(x) INTO o FROM flightbridge.organisation x WHERE x.id = v_org;
  IF o IS NULL THEN RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT404'; END IF;
  rule := crm_private.fb_eligibility_rules() -> (o->>'country');
  RETURN o || jsonb_build_object(
    'identifiers', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT scheme, value, source_url
        FROM flightbridge.organisation_identifier WHERE org_id = v_org) x), '[]'),
    'regulatory', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT id, authority_code, classification, approval_ref, courses,
        status, source_url, source_version, checked_at, next_check_due FROM flightbridge.regulatory_approval WHERE org_id = v_org) x), '[]'),
    'contacts', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.is_role_address DESC, x.email) FROM (
        SELECT c.id, c.email, c.is_role_address, c.role, c.source_url, c.verification_level,
               (SELECT json_agg(json_build_object('fact', e.fact, 'method', e.method, 'excerpt', e.excerpt,
                       'source_url', e.source_url, 'expires_at', e.expires_at) ORDER BY e.verified_at DESC)
                  FROM flightbridge.contact_fact_evidence e WHERE e.contact_id = c.id) AS evidence
          FROM flightbridge.contact c WHERE c.org_id = v_org) x), '[]'),
    'qualification', (SELECT to_jsonb(x) FROM (SELECT score, breakdown, missing, risks, recommended_action, confidence, computed_at
        FROM flightbridge.qualification_result WHERE org_id = v_org ORDER BY computed_at DESC LIMIT 1) x),
    'pages', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fetched_at DESC) FROM (SELECT url, http_status, robots_allowed, fetched_at
        FROM flightbridge.website_page WHERE org_id = v_org ORDER BY fetched_at DESC LIMIT 30) x), '[]'),
    'profile', (SELECT to_jsonb(x) FROM (SELECT summary, signals, evidence, generator, updated_at
        FROM flightbridge.organisation_profile WHERE org_id = v_org) x),
    'phones', coalesce((SELECT jsonb_agg(to_jsonb(x) - 'o' - 'id' ORDER BY x.o, x.id) FROM (SELECT id, phone, display, source, source_url, found_at,
        CASE source WHEN 'website' THEN 0 WHEN 'regulator' THEN 1 WHEN 'human' THEN 2 ELSE 3 END AS o
        FROM flightbridge.contact_phone WHERE org_id = v_org) x), '[]'),
    'area', (SELECT jsonb_build_object('id', a.id, 'name', a.name, 'region', a.region, 'kind', a.kind)
        FROM flightbridge.area a WHERE a.id = (o->>'area_id')::bigint),
    'channels', coalesce((SELECT jsonb_agg(to_jsonb(x) - 'o' ORDER BY x.o, x.url) FROM (SELECT kind, url, source_url, found_at,
        CASE kind WHEN 'contact_form' THEN 0 WHEN 'linkedin' THEN 1 ELSE 2 END AS o
        FROM flightbridge.contact_channel WHERE org_id = v_org) x), '[]'),
    'jobs', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.requested_at DESC) FROM (SELECT id, kind, status, requested_at, finished_at, result
        FROM flightbridge.job_request WHERE org_id = v_org ORDER BY requested_at DESC LIMIT 5) x), '[]'),
    'history', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.at DESC) FROM (SELECT at, actor_type, action, payload
        FROM flightbridge.audit_log WHERE entity = 'organisation' AND entity_id = v_org::text ORDER BY at DESC LIMIT 30) x), '[]'),
    'eligibility_rule', CASE WHEN rule IS NULL THEN NULL
        ELSE jsonb_build_object('credential', rule->'credential', 'lookup', rule->'lookup') END);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_school_review(p_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  dec text := crm_private.fb_text(p_data, 'decision', NULL, true);
  reason text := crm_private.fb_text(p_data, 'reason', 500); got uuid;
BEGIN
  IF dec NOT IN ('qualified', 'rejected', 'needs_human_review') THEN
    RAISE EXCEPTION 'decision must be qualified, rejected or needs_human_review' USING ERRCODE = 'PT400';
  END IF;
  IF dec = 'rejected' AND crm_private.fb_strip(reason) = '' THEN
    RAISE EXCEPTION 'A reason is required to reject a school' USING ERRCODE = 'PT400';
  END IF;
  UPDATE flightbridge.organisation SET status = dec, rejection_reason = CASE WHEN dec = 'rejected' THEN crm_private.fb_strip(reason) END,
         updated_at = now()
   WHERE id = crm_private.fb_uuid(p_id, 'School not found or already in conversation')
     AND status NOT IN ('contacted', 'interested', 'negotiation', 'partner') RETURNING id INTO got;
  IF got IS NULL THEN RAISE EXCEPTION 'School not found or already in conversation' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.fb_audit(eid, 'school_' || dec, 'organisation', got::text,
                               jsonb_build_object('reason', reason, 'by_role', crm_private.fb_role()));
  RETURN json_build_object('status', dec);
END $$;

-- A person confirmed this record on the regulator's own site (needed for FAA / Transport Canada / CASA).
CREATE OR REPLACE FUNCTION public.api_fb_regulatory_verify(p_org text, p_approval bigint) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member(); v_org uuid := crm_private.fb_uuid(p_org, 'Regulatory record not found'); got bigint;
BEGIN
  UPDATE flightbridge.regulatory_approval
     SET status = 'verified_by_human', checked_by = eid, checked_at = now(), next_check_due = now() + interval '90 days'
   WHERE id = p_approval AND org_id = v_org RETURNING id INTO got;
  IF got IS NULL THEN RAISE EXCEPTION 'Regulatory record not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.fb_audit(eid, 'regulatory_verified_by_human', 'organisation', v_org::text, jsonb_build_object('approval_id', got));
  RETURN json_build_object('status', 'verified_by_human');
END $$;

-- Country > State > Area tree (areas with no schools yet still show, so they can be searched).
CREATE OR REPLACE FUNCTION public.api_fb_regions() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((
    WITH r AS (
      SELECT country, region, count(*) AS total,
             count(*) FILTER (WHERE status = 'needs_human_review') AS needs_look,
             count(*) FILTER (WHERE status IN ('qualified', 'ready_for_outreach')) AS good_fit,
             count(*) FILTER (WHERE status IN ('contacted', 'interested', 'negotiation', 'partner')) AS in_contact
        FROM flightbridge.organisation WHERE deleted_at IS NULL GROUP BY 1, 2),
    a AS (
      SELECT a.id, a.country, a.region, a.name, a.kind, a.enabled, a.last_searched_at,
             count(o.id) AS total,
             count(o.id) FILTER (WHERE o.eligibility = 'eligible_verified') AS verified,
             count(o.id) FILTER (WHERE o.eligibility = 'eligible_claimed') AS claimed,
             count(o.id) FILTER (WHERE o.eligibility = 'unqualified') AS unqualified
        FROM flightbridge.area a
   LEFT JOIN flightbridge.organisation o ON o.area_id = a.id AND o.deleted_at IS NULL
       GROUP BY a.id),
    u AS (SELECT country, region, count(*) AS n FROM flightbridge.organisation
           WHERE deleted_at IS NULL AND area_id IS NULL GROUP BY 1, 2),
    regs AS (
      SELECT country, region, total, needs_look, good_fit, in_contact FROM r
      UNION ALL
      SELECT DISTINCT a.country, a.region, 0, 0, 0, 0 FROM a
       WHERE NOT EXISTS (SELECT 1 FROM r WHERE r.country = a.country AND r.region = a.region)),
    rj AS (
      SELECT g.country, g.total, g.needs_look, g.region,
             json_build_object('region', g.region, 'total', g.total, 'needs_look', g.needs_look, 'good_fit', g.good_fit,
               'in_contact', g.in_contact,
               'areas', coalesce((SELECT json_agg(json_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'enabled', a.enabled,
                          'last_searched_at', a.last_searched_at, 'total', a.total, 'verified', a.verified, 'claimed', a.claimed,
                          'unqualified', a.unqualified) ORDER BY a.name)
                          FROM a WHERE a.country = g.country AND a.region = g.region), '[]'),
               'unplaced', coalesce((SELECT u.n FROM u WHERE u.country = g.country AND u.region IS NOT DISTINCT FROM g.region), 0)) AS j
        FROM regs g),
    cj AS (
      SELECT country, sum(total) AS total, sum(needs_look) AS needs_look,
             json_agg(j ORDER BY total DESC, coalesce(region, '') COLLATE "C") AS regions
        FROM rj GROUP BY country)
    SELECT json_agg(json_build_object('country', country, 'total', total, 'needs_look', needs_look, 'regions', regions)
                    ORDER BY total DESC, country::text COLLATE "C")
      FROM cj), '[]');
END $$;

-- ===========================================================================================
-- Automation (worker status, Run now, autopilot)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_fb_automation() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN json_build_object(
    'runs', coalesce((SELECT json_agg(x) FROM (SELECT id, started_at, finished_at, runner, trigger, status, stats, error
        FROM flightbridge.worker_run ORDER BY started_at DESC LIMIT 20) x), '[]'),
    'jobs', coalesce((SELECT json_agg(x) FROM (SELECT j.id, j.kind, j.status, j.requested_at, j.started_at, j.finished_at, j.result,
               coalesce(o.name, ar.name) AS org_name, e.name AS requested_by_name
          FROM flightbridge.job_request j
     LEFT JOIN flightbridge.organisation o ON o.id = j.org_id
     LEFT JOIN flightbridge.area ar ON ar.id = j.area_id
     LEFT JOIN public.employee e ON e.id = j.requested_by
         ORDER BY j.requested_at DESC LIMIT 20) x), '[]'),
    'runners', coalesce((SELECT json_agg(x) FROM (SELECT runner, max(started_at) AS last_seen FROM flightbridge.worker_run
         WHERE started_at > now() - interval '7 days' GROUP BY 1 ORDER BY 2 DESC) x), '[]'),
    'activity', coalesce((SELECT json_agg(x) FROM (SELECT a.at, a.actor_type, a.action, a.entity, a.entity_id, a.payload,
               coalesce(o.name, ar.name) AS org_name
          FROM flightbridge.audit_log a
     LEFT JOIN flightbridge.organisation o ON a.entity = 'organisation' AND o.id::text = a.entity_id
     LEFT JOIN flightbridge.area ar ON a.entity = 'area' AND ar.id::text = a.entity_id
         WHERE a.action IN ('website_search', 'research_stored', 'qualified', 'draft_created', 'draft_skipped',
                            'organisation_created', 'school_qualified', 'school_rejected', 'regulatory_verified_by_human',
                            'approval_approved', 'approval_edited_approved', 'template_approved', 'kill_switch_set',
                            'area_searched', 'eligibility_set', 'contact_hunt')
         ORDER BY a.at DESC LIMIT 40) x), '[]'),
    'autopilot', (SELECT value FROM flightbridge.system_setting WHERE key = 'autopilot'),
    'backlog', (SELECT json_build_object(
        'need_website', count(*) FILTER (WHERE website_domain IS NULL AND status IN ('discovered', 'research_pending')),
        'need_research', count(*) FILTER (WHERE website_domain IS NOT NULL AND status IN ('discovered', 'research_pending')),
        'need_scoring', count(*) FILTER (WHERE status = 'research_completed'),
        'no_email', count(*) FILTER (WHERE website_domain IS NOT NULL AND status NOT IN ('discovered', 'research_pending')
                                     AND NOT EXISTS (SELECT 1 FROM flightbridge.contact c WHERE c.org_id = o.id)))
        FROM flightbridge.organisation o WHERE deleted_at IS NULL));
END $$;

-- "Run now": queues a job; the engine (Mac Mini runner / Render) polls the queue every 30 seconds.
CREATE OR REPLACE FUNCTION public.api_fb_run(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  k text := crm_private.fb_text(p_data, 'kind', NULL, true);
  org_raw text := crm_private.fb_text(p_data, 'org_id', NULL);
  area bigint := crm_private.fb_int(p_data, 'area_id', NULL, NULL);
  org uuid; jid bigint;
BEGIN
  IF k NOT IN ('cycle', 'research_school', 'find_websites', 'research_batch', 'search_area') THEN
    RAISE EXCEPTION 'kind must be one of [''cycle'', ''find_websites'', ''research_batch'', ''research_school'', ''search_area'']'
      USING ERRCODE = 'PT400';
  END IF;
  IF k = 'research_school' AND coalesce(org_raw, '') = '' THEN
    RAISE EXCEPTION 'org_id is required to research one school' USING ERRCODE = 'PT400';
  END IF;
  IF k = 'search_area' AND coalesce(area, 0) = 0 THEN
    RAISE EXCEPTION 'area_id is required to search an area' USING ERRCODE = 'PT400';
  END IF;
  IF coalesce(org_raw, '') <> '' THEN
    BEGIN org := org_raw::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT404'; END;
  END IF;
  BEGIN
    INSERT INTO flightbridge.job_request (kind, org_id, area_id, requested_by) VALUES (k, org, area, eid)
    ON CONFLICT DO NOTHING RETURNING id INTO jid;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION '%', CASE WHEN area IS NOT NULL THEN 'Area not found' ELSE 'School not found' END USING ERRCODE = 'PT404';
  END;
  IF jid IS NOT NULL THEN
    PERFORM crm_private.fb_audit(eid, 'run_requested', 'job_request', jid::text,
                                 jsonb_build_object('kind', k, 'org_id', org_raw, 'area_id', area));
  END IF;
  RETURN json_build_object('queued', jid IS NOT NULL, 'already_queued', jid IS NULL, 'started_now', false,
    'message', CASE WHEN jid IS NOT NULL THEN 'Queued – starts within a minute.' ELSE 'Already queued.' END);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_autopilot_set(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); v json;
BEGIN
  v := json_build_object(
    'discover_areas', crm_private.fb_bool(p_data, 'discover_areas', true),
    'find_websites', crm_private.fb_bool(p_data, 'find_websites'),
    'research', crm_private.fb_bool(p_data, 'research'),
    'find_contacts', crm_private.fb_bool(p_data, 'find_contacts', true),
    'eligibility', crm_private.fb_bool(p_data, 'eligibility', true),
    'qualify', crm_private.fb_bool(p_data, 'qualify'),
    'draft', crm_private.fb_bool(p_data, 'draft'),
    'batch_size', crm_private.fb_int(p_data, 'batch_size', 1, 50, NULL, true),
    'areas_per_cycle', crm_private.fb_int(p_data, 'areas_per_cycle', 1, 10, 2));
  PERFORM crm_private.fb_set_setting('autopilot', v::jsonb, eid);
  PERFORM crm_private.fb_audit(eid, 'autopilot_set', 'system_setting', 'autopilot', v::jsonb);
  RETURN v;
END $$;

-- ===========================================================================================
-- Integrations (API keys). Listing, settings and removal here; saving and testing in the crm-flightbridge
-- Edge Function (it encrypts with FB_SECRETS_KEY and calls the provider to test the key).
-- The engine reports its own environment in system_setting 'engine_status' (Mac Mini runner).
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.fb_integration_label(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_name WHEN 'google_places_api_key' THEN 'Google Places API key' WHEN 'groq_api_key' THEN 'Groq API key'
    WHEN 'gemini_api_key' THEN 'Gemini API key' WHEN 'hostinger_mail_api_token' THEN 'Hostinger Mail API token'
    WHEN 'hostinger_mailbox_resource_id' THEN 'Hostinger mailbox ID' END
$$;

CREATE OR REPLACE FUNCTION public.api_fb_integrations() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE env jsonb; cfg jsonb;
BEGIN
  PERFORM crm_private.fb_admin();
  SELECT value INTO env FROM flightbridge.system_setting WHERE key = 'engine_status';
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'integrations';
  IF jsonb_typeof(cfg) IS DISTINCT FROM 'object' THEN cfg := '{}'; END IF;
  RETURN json_build_object(
    'keys', (SELECT json_agg(json_build_object('name', n.name, 'label', crm_private.fb_integration_label(n.name),
        'saved', s.name IS NOT NULL, 'last4', s.last4, 'updated_at', s.updated_at,
        'from_server_env', coalesce(env->'env_keys' ? upper(n.name), false),
        'last_test_at', s.last_test_at, 'last_test_ok', s.last_test_ok, 'last_test_message', s.last_test_message) ORDER BY n.o)
        FROM (VALUES (1, 'google_places_api_key'), (2, 'groq_api_key'), (3, 'gemini_api_key'),
                     (4, 'hostinger_mail_api_token'), (5, 'hostinger_mailbox_resource_id')) n(o, name)
   LEFT JOIN flightbridge.integration_secret s ON s.name = n.name),
    'settings', json_build_object(
        'engine_in_crm', coalesce(cfg->'engine_in_crm', 'true'), 'llm_provider', coalesce(cfg->'llm_provider', '"none"'),
        'llm_model', coalesce(cfg->'llm_model', '""'), 'inbound_source', coalesce(cfg->'inbound_source', '"none"'),
        'store_google_contacts', coalesce(cfg->'store_google_contacts', 'true')),
    'engine_env_off', coalesce((env->>'engine_off')::boolean, false),
    'dry_run', coalesce((env->>'dry_run')::boolean, true),
    'outbound_enabled', coalesce((env->>'outbound_enabled')::boolean, false),
    'engine_status', env);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_integration_check(p_name text) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
BEGIN
  IF crm_private.fb_integration_label(p_name) IS NULL THEN RAISE EXCEPTION 'Unknown key' USING ERRCODE = 'PT404'; END IF;
  RETURN json_build_object('employee_id', eid);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_integration_delete(p_name text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
BEGIN
  IF crm_private.fb_integration_label(p_name) IS NULL THEN RAISE EXCEPTION 'Unknown key' USING ERRCODE = 'PT404'; END IF;
  DELETE FROM flightbridge.integration_secret WHERE name = p_name;
  PERFORM crm_private.fb_audit(eid, 'integration_key_removed', 'integration', p_name, '{}');
  RETURN json_build_object('name', p_name, 'saved', false);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_integration_settings(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); v json;
  prov text := coalesce(crm_private.fb_text(p_data, 'llm_provider', NULL), 'none');
  inb text := coalesce(crm_private.fb_text(p_data, 'inbound_source', NULL), 'none');
BEGIN
  v := json_build_object('engine_in_crm', crm_private.fb_bool(p_data, 'engine_in_crm', true), 'llm_provider', prov,
                         'llm_model', coalesce(crm_private.fb_text(p_data, 'llm_model', 100), ''), 'inbound_source', inb);
  IF prov NOT IN ('none', 'groq', 'gemini') THEN
    RAISE EXCEPTION 'llm_provider must be none, groq or gemini' USING ERRCODE = 'PT400';
  END IF;
  IF inb NOT IN ('none', 'hostinger') THEN RAISE EXCEPTION 'inbound_source must be none or hostinger' USING ERRCODE = 'PT400'; END IF;
  PERFORM crm_private.fb_set_setting('integrations', v::jsonb, eid);
  PERFORM crm_private.fb_audit(eid, 'integration_settings_set', 'system_setting', 'integrations', v::jsonb);
  RETURN v;
END $$;

-- Service-role helpers for the crm-flightbridge Edge Function (never callable from the browser).
CREATE OR REPLACE FUNCTION public.svc_fb_secret_get(p_name text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ciphertext FROM flightbridge.integration_secret WHERE name = p_name
$$;

CREATE OR REPLACE FUNCTION public.svc_fb_secret_save(p_name text, p_ciphertext text, p_last4 text, p_emp uuid, p_ok boolean, p_msg text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO flightbridge.integration_secret (name, ciphertext, last4, updated_at, updated_by, last_test_at, last_test_ok, last_test_message)
  VALUES (p_name, p_ciphertext, p_last4, now(), p_emp, now(), p_ok, left(p_msg, 500))
  ON CONFLICT (name) DO UPDATE SET ciphertext = EXCLUDED.ciphertext, last4 = EXCLUDED.last4, updated_at = now(),
    updated_by = EXCLUDED.updated_by, last_test_at = now(), last_test_ok = EXCLUDED.last_test_ok,
    last_test_message = EXCLUDED.last_test_message;
  PERFORM crm_private.fb_audit(p_emp, 'integration_key_saved', 'integration', p_name, jsonb_build_object('last4', p_last4, 'test_ok', p_ok));
END $$;

CREATE OR REPLACE FUNCTION public.svc_fb_secret_tested(p_name text, p_ok boolean, p_msg text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE flightbridge.integration_secret SET last_test_at = now(), last_test_ok = p_ok, last_test_message = left(p_msg, 500)
   WHERE name = p_name
$$;

-- Hostinger webhook: stored once (dedupe on the payload hash); the engine re-reads the mailbox over the API.
CREATE OR REPLACE FUNCTION public.svc_fb_webhook(p_key text, p_payload jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO flightbridge.webhook_event (provider, event_key, payload) VALUES ('hostinger', p_key, p_payload)
  ON CONFLICT (provider, event_key) DO NOTHING
$$;

-- ===========================================================================================
-- Areas (Country > State > Area)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_fb_areas() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT a.*, (SELECT count(*) FROM flightbridge.organisation o WHERE o.area_id = a.id AND o.deleted_at IS NULL) AS schools
      FROM flightbridge.area a ORDER BY a.country, a.region, a.name) x), '[]');
END $$;

-- Checks a new area; returns the cleaned fields (the Edge Function uses this before asking Google for coordinates).
CREATE OR REPLACE FUNCTION public.api_fb_area_check(p_data jsonb) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c text; r text; n text; k text; rad bigint; lat float8; lng float8;
BEGIN
  PERFORM crm_private.fb_admin();
  c := crm_private.fb_text(p_data, 'country', 2, true, 2);
  r := crm_private.fb_text(p_data, 'region', 80, true, 1);
  n := crm_private.fb_text(p_data, 'name', 120, true, 1);
  k := coalesce(crm_private.fb_text(p_data, 'kind', NULL), 'training_hub');
  rad := crm_private.fb_int(p_data, 'radius_km', 2, 50, 40);
  IF p_data->'lat' IS NOT NULL AND jsonb_typeof(p_data->'lat') <> 'null' THEN
    IF jsonb_typeof(p_data->'lat') <> 'number' OR (p_data->>'lat')::float8 NOT BETWEEN -90 AND 90 THEN
      RAISE EXCEPTION 'lat must be a number between -90 and 90' USING ERRCODE = 'PT422';
    END IF;
    lat := (p_data->>'lat')::float8;
  END IF;
  IF p_data->'lng' IS NOT NULL AND jsonb_typeof(p_data->'lng') <> 'null' THEN
    IF jsonb_typeof(p_data->'lng') <> 'number' OR (p_data->>'lng')::float8 NOT BETWEEN -180 AND 180 THEN
      RAISE EXCEPTION 'lng must be a number between -180 and 180' USING ERRCODE = 'PT422';
    END IF;
    lng := (p_data->>'lng')::float8;
  END IF;
  IF k NOT IN ('training_hub', 'demand_hub') THEN
    RAISE EXCEPTION 'kind must be training_hub or demand_hub' USING ERRCODE = 'PT400';
  END IF;
  RETURN json_build_object('country', upper(c), 'region', crm_private.fb_strip(r), 'name', crm_private.fb_strip(n), 'kind', k,
                           'radius_km', rad, 'lat', lat, 'lng', lng);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_area_add(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); a json := public.api_fb_area_check(p_data); new_id bigint;
BEGIN
  IF a->>'lat' IS NULL OR a->>'lng' IS NULL THEN
    RAISE EXCEPTION 'Enter the coordinates, or add the area by name so Google can find it' USING ERRCODE = 'PT400';
  END IF;
  INSERT INTO flightbridge.area (country, region, name, kind, lat, lng, radius_km, notes)
  VALUES (a->>'country', a->>'region', a->>'name', a->>'kind', (a->>'lat')::float8, (a->>'lng')::float8, (a->>'radius_km')::int,
          'added in the app')
  ON CONFLICT (country, region, name) DO NOTHING RETURNING id INTO new_id;
  IF new_id IS NULL THEN RAISE EXCEPTION 'That area already exists' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.fb_audit(eid, 'area_added', 'area', new_id::text,
    jsonb_build_object('name', p_data->>'name', 'region', p_data->>'region', 'country', p_data->>'country'));
  RETURN json_build_object('id', new_id, 'lat', (a->>'lat')::float8, 'lng', (a->>'lng')::float8);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_area_patch(p_id bigint, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  en boolean := CASE WHEN p_data->'enabled' IS NULL OR jsonb_typeof(p_data->'enabled') = 'null' THEN NULL
                     ELSE crm_private.fb_bool(p_data, 'enabled') END;
  rad bigint := crm_private.fb_int(p_data, 'radius_km', 2, 50);
  ch jsonb; got bigint;
BEGIN
  UPDATE flightbridge.area SET enabled = coalesce(en, enabled), radius_km = coalesce(rad::int, radius_km)
   WHERE id = p_id RETURNING id INTO got;
  IF got IS NULL THEN RAISE EXCEPTION 'Area not found' USING ERRCODE = 'PT404'; END IF;
  ch := jsonb_strip_nulls(jsonb_build_object('enabled', en, 'radius_km', rad));
  PERFORM crm_private.fb_audit(eid, 'area_changed', 'area', p_id::text, ch);
  RETURN jsonb_build_object('id', p_id) || ch;
END $$;

-- ===========================================================================================
-- Eligibility decisions by a person. COPY of flightbridge/eligibility.py (evaluate, evaluate_org,
-- mark_unqualified, confirm); keep in sync.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.fb_truthy(v jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE jsonb_typeof(v) WHEN 'boolean' THEN v::boolean WHEN 'number' THEN v::numeric <> 0
    WHEN 'string' THEN (v #>> '{}') <> '' WHEN 'array' THEN jsonb_array_length(v) > 0
    WHEN 'object' THEN v <> '{}'::jsonb ELSE false END
$$;

CREATE OR REPLACE FUNCTION crm_private.fb_claim_text(c text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(CASE c
    WHEN 'part141' THEN 'Website says FAA Part 141'
    WHEN 'sevp' THEN 'Website says SEVP / I-20 / M-1 (international students)'
    WHEN 'casa_part14x' THEN 'Website says CASA Part 141/142'
    WHEN 'cricos_on_site' THEN 'Website shows a CRICOS registration'
    WHEN 'transport_canada' THEN 'Website says Transport Canada approved / Flight Training Unit'
    WHEN 'dli' THEN 'Website shows a Designated Learning Institution (DLI) number'
    WHEN 'caa_nz_part141' THEN 'Website says CAA NZ Part 141'
    WHEN 'nzqa' THEN 'Website says NZQA' END, c)
$$;

-- Re-evaluates one school; a person's "unqualified" is never overwritten by automation.
CREATE OR REPLACE FUNCTION crm_private.fb_evaluate_org(p_org uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o record; rule jsonb; reasons jsonb := '[]'; decision text; sig jsonb := '{}'; ev jsonb := '{}';
  prof record; pages bigint; closed boolean; r record; claims text[] := '{}'; c text; e jsonb;
BEGIN
  SELECT country, org_kind, eligibility, eligibility_reasons INTO o FROM flightbridge.organisation WHERE id = p_org;
  IF NOT FOUND THEN RETURN 'unknown'; END IF;
  IF o.org_kind = 'ground_school' THEN RETURN 'unknown'; END IF;
  IF o.eligibility = 'unqualified' AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(o.eligibility_reasons, '[]')) x
                                                WHERE x->>'code' = 'human_unqualified') THEN
    RETURN 'unqualified';
  END IF;
  rule := crm_private.fb_eligibility_rules() -> (o.country::text);
  SELECT signals, evidence INTO prof FROM flightbridge.organisation_profile WHERE org_id = p_org;
  SELECT count(*) INTO pages FROM flightbridge.website_page WHERE org_id = p_org AND http_status = 200;
  closed := EXISTS (SELECT 1 FROM flightbridge.audit_log WHERE entity = 'organisation' AND entity_id = p_org::text
                     AND action = 'place_closed' LIMIT 1);
  IF prof.signals IS NOT NULL AND jsonb_typeof(prof.signals) = 'object' THEN sig := prof.signals; END IF;
  IF jsonb_typeof(prof.evidence) = 'array' THEN
    FOR e IN SELECT value FROM jsonb_array_elements(prof.evidence) LOOP
      ev := ev || jsonb_build_object(e->>'signal', e);      -- later entries win, as in the dict comprehension
    END LOOP;
  END IF;

  IF rule IS NULL THEN
    decision := 'unknown';
    reasons := jsonb_build_array(jsonb_build_object('code', 'no_rules', 'text', format('No eligibility rules set for %s yet', o.country)));
  ELSIF closed THEN
    decision := 'unqualified';
    reasons := '[{"code": "closed", "text": "Listed as permanently closed"}]';
  ELSE
    FOR r IN SELECT classification, status, authority_code, approval_ref, source_url FROM flightbridge.regulatory_approval
              WHERE org_id = p_org LOOP
      IF rule->'verified' ? r.classification AND r.status IN ('listed_in_register', 'verified_by_human') THEN
        reasons := reasons || jsonb_build_array(jsonb_build_object('code', 'verified',
          'text', crm_private.fb_strip(format('%s: %s %s', CASE WHEN r.status = 'verified_by_human'
                   THEN 'Confirmed by a person on the regulator''s site' ELSE 'Listed in the official register' END,
                   r.authority_code, coalesce(r.approval_ref, ''))),
          'source_url', r.source_url));
      END IF;
    END LOOP;
    IF jsonb_array_length(reasons) > 0 THEN
      decision := 'eligible_verified';
    ELSE
      FOR c IN SELECT value FROM jsonb_array_elements_text(rule->'claims') LOOP
        IF crm_private.fb_truthy(sig->c) THEN claims := claims || c; END IF;
      END LOOP;
      IF crm_private.fb_truthy(sig->'helicopter') AND NOT crm_private.fb_truthy(sig->'aeroplane')
         AND NOT crm_private.fb_truthy(sig->'has_cpl') THEN
        decision := 'unqualified';
        reasons := '[{"code": "helicopter_only", "text": "Website mentions helicopters only (no aeroplane training)"}]';
      ELSIF crm_private.fb_truthy(sig->'drone') AND NOT crm_private.fb_truthy(sig->'aeroplane')
         AND NOT crm_private.fb_truthy(sig->'has_cpl') AND cardinality(claims) = 0 THEN
        decision := 'unqualified';
        reasons := '[{"code": "drone_only", "text": "Website is about drones, not pilot training"}]';
      ELSIF cardinality(claims) > 0 THEN
        decision := 'eligible_claimed';
        FOREACH c IN ARRAY claims LOOP
          reasons := reasons || jsonb_build_array(jsonb_build_object('code', 'claim:' || c, 'text', crm_private.fb_claim_text(c),
            'excerpt', coalesce(ev->c->'excerpt', 'null'), 'source_url', coalesce(ev->c->'url', 'null')));
        END LOOP;
      ELSIF pages > 0 THEN
        decision := 'unqualified';
        reasons := jsonb_build_array(jsonb_build_object('code', 'no_credential',
          'text', format('Website read (%s pages): no %s found', pages, rule->>'credential')));
      ELSE
        decision := 'unknown';
        reasons := '[{"code": "not_researched", "text": "Website not read yet"}]';
      END IF;
    END IF;
  END IF;

  UPDATE flightbridge.organisation SET eligibility = decision, eligibility_reasons = reasons, eligibility_checked_at = now()
   WHERE id = p_org;
  IF o.eligibility IS DISTINCT FROM decision THEN
    INSERT INTO flightbridge.audit_log (actor_type, actor_id, action, entity, entity_id, payload)
    VALUES ('system', NULL, 'eligibility_set', 'organisation', p_org::text,
            jsonb_build_object('from', o.eligibility, 'to', decision, 'reasons', reasons));
  END IF;
  RETURN decision;
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_eligibility(p_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  dec text := crm_private.fb_text(p_data, 'decision', NULL, true);
  ref text := crm_private.fb_text(p_data, 'reference', 80);
  src text := crm_private.fb_text(p_data, 'source_url', 2048);
  note text := crm_private.fb_text(p_data, 'note', 500);
  v_org uuid; ctry text; rule jsonb; result text;
BEGIN
  IF dec NOT IN ('confirm', 'unqualified', 'recheck') THEN
    RAISE EXCEPTION 'decision must be confirm, unqualified or recheck' USING ERRCODE = 'PT400';
  END IF;
  IF dec = 'unqualified' AND crm_private.fb_strip(note) = '' THEN
    RAISE EXCEPTION 'Say why it''s unqualified' USING ERRCODE = 'PT400';
  END IF;
  IF coalesce(src, '') <> '' AND NOT (lower(src) LIKE 'https://%' OR lower(src) LIKE 'http://%') THEN
    RAISE EXCEPTION 'source_url must be a web address' USING ERRCODE = 'PT400';
  END IF;
  v_org := crm_private.fb_uuid(p_id, 'School not found');
  SELECT country::text INTO ctry FROM flightbridge.organisation WHERE id = v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT404'; END IF;

  IF dec = 'confirm' THEN
    -- A person checked the regulator's site: record the country's main credential as verified_by_human.
    rule := crm_private.fb_eligibility_rules() -> ctry;
    IF rule IS NULL THEN RAISE EXCEPTION 'No eligibility rules for %', ctry USING ERRCODE = 'PT400'; END IF;
    INSERT INTO flightbridge.regulatory_approval (org_id, authority_code, classification, approval_ref, status,
                                                  source_url, checked_at, checked_by, next_check_due)
    VALUES (v_org, rule->'confirm_as'->>'authority', rule->'confirm_as'->>'classification', nullif(ref, ''), 'verified_by_human',
            coalesce(nullif(src, ''), rule->'lookup'->0->>1), now(), eid, now() + interval '90 days')
    ON CONFLICT (org_id, authority_code, classification) DO UPDATE
      SET status = 'verified_by_human', approval_ref = coalesce(EXCLUDED.approval_ref, flightbridge.regulatory_approval.approval_ref),
          source_url = EXCLUDED.source_url, checked_at = now(), checked_by = EXCLUDED.checked_by,
          next_check_due = EXCLUDED.next_check_due;
    UPDATE flightbridge.organisation SET eligibility_reasons = '[]'::jsonb WHERE id = v_org;   -- clears human_unqualified
    result := crm_private.fb_evaluate_org(v_org);
  ELSIF dec = 'unqualified' THEN
    UPDATE flightbridge.organisation SET eligibility = 'unqualified',
           eligibility_reasons = jsonb_build_array(jsonb_build_object('code', 'human_unqualified',
             'text', 'Marked unqualified by a person: ' || crm_private.fb_strip(note))),
           eligibility_checked_at = now() WHERE id = v_org;
    PERFORM crm_private.fb_audit(eid, 'eligibility_set', 'organisation', v_org::text,
      jsonb_build_object('to', 'unqualified', 'by', 'employee', 'note', crm_private.fb_strip(note)));
    result := 'unqualified';
  ELSE
    UPDATE flightbridge.organisation SET eligibility_reasons = '[]'::jsonb WHERE id = v_org;
    result := crm_private.fb_evaluate_org(v_org);
  END IF;
  PERFORM crm_private.fb_audit(eid, 'eligibility_' || dec, 'organisation', v_org::text,
    jsonb_build_object('result', result, 'reference', ref, 'note', note, 'by_role', crm_private.fb_role()));
  RETURN json_build_object('eligibility', result);
END $$;

-- ===========================================================================================
-- Grants
-- ===========================================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE (n.nspname = 'public' AND (p.proname LIKE 'api\_fb\_%' OR p.proname LIKE 'svc\_fb\_%'))
               OR (n.nspname = 'crm_private' AND p.proname LIKE 'fb\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    IF f.proname LIKE 'svc\_fb\_%' THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    ELSIF f.nspname = 'public' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    ELSIF f.proname IN ('fb_evaluate_org', 'fb_audit', 'fb_set_setting') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f.sig);
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END $$;
