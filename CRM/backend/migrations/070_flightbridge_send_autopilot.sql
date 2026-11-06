-- 070: Email Auto-Pilot (engine 1.8.0). Engine part = flightbridge/migrations/011_send_autopilot.sql (same SQL), then the
-- CRM's api_* functions: Auto-Pilot screen and settings, outreach pipeline (one row per school emailed) and moves,
-- follow-ups 0-5, and the one-click unsubscribe used by the crm-flightbridge Edge Function.

-- 011: Email Auto-Pilot (engine 1.8.0).
-- When the owner switches Auto-Pilot ON in the CRM, the engine sends the owner's APPROVED templates to Eligible
-- schools by itself: a warm-up pace (or the owner's daily number), each school's own business hours, random gaps,
-- automatic follow-ups (owner's count and days), and an automatic pause on bounces, complaints or mailbox errors.
-- Every email still passes the same compliance gates, the kill switch and DRY_RUN / OUTBOUND_ENABLED.
--   system_setting 'send_autopilot'        owner's settings (written by the CRM)
--   system_setting 'send_autopilot_state'  engine's state: pre-flight checklist, pace, pause (written by the engine)

-- up to 5 follow-ups (was 3)
ALTER TABLE flightbridge.follow_up_task DROP CONSTRAINT IF EXISTS follow_up_task_step_check;
ALTER TABLE flightbridge.follow_up_task ADD CONSTRAINT follow_up_task_step_check CHECK (step BETWEEN 1 AND 5);
ALTER TABLE flightbridge.outreach_template DROP CONSTRAINT IF EXISTS outreach_template_kind_check;
ALTER TABLE flightbridge.outreach_template ADD CONSTRAINT outreach_template_kind_check
    CHECK (kind IN ('initial','followup_1','followup_2','followup_3','followup_4','followup_5'));

-- who/what approved an email: a person, or Auto-Pilot on the owner's behalf
ALTER TABLE flightbridge.approval_task ADD COLUMN IF NOT EXISTS decided_via TEXT NOT NULL DEFAULT 'person';
ALTER TABLE flightbridge.approval_task DROP CONSTRAINT IF EXISTS approval_task_decided_via_check;
ALTER TABLE flightbridge.approval_task ADD CONSTRAINT approval_task_decided_via_check CHECK (decided_via IN ('person','autopilot'));

INSERT INTO flightbridge.system_setting (key, value) VALUES
  ('send_autopilot', '{"enabled": false, "daily_limit": 40, "warmup": true}'::jsonb),
  ('send_autopilot_state', '{}'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_fb_outbound_sent_at ON flightbridge.outbound_message (sent_at) WHERE sent_at IS NOT NULL;

-- ================================================================== CRM side (api_* functions)
INSERT INTO flightbridge.system_setting (key, value) VALUES
  ('unsubscribe_url_base', '"https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-flightbridge/u"'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- templates: follow-ups 1-5
CREATE OR REPLACE FUNCTION public.api_fb_template_save(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  k text := crm_private.fb_text(p_data, 'kind', NULL, true);
  subj text := crm_private.fb_text(p_data, 'subject', 150, true);
  body text := crm_private.fb_text(p_data, 'body', 20000, true);
  v jsonb; ver int; tid uuid;
BEGIN
  IF k NOT IN ('initial', 'followup_1', 'followup_2', 'followup_3', 'followup_4', 'followup_5') THEN
    RAISE EXCEPTION 'kind must be initial or followup_1 … followup_5' USING ERRCODE = 'PT400';
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

-- follow-up days: 0-5 follow-ups (an empty list = no follow-ups)
CREATE OR REPLACE FUNCTION crm_private.fb_followup_days(d jsonb) RETURNS int[]
LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE days int[] := '{}'; e jsonb; i int;
  bad text := 'Give 0-5 increasing day numbers between 2 and 90, e.g. 4, 9, 16';
BEGIN
  IF d IS NULL OR jsonb_typeof(d) <> 'array' THEN RAISE EXCEPTION 'days must be a list of whole numbers' USING ERRCODE = 'PT422'; END IF;
  FOR e IN SELECT value FROM jsonb_array_elements(d) LOOP
    IF jsonb_typeof(e) <> 'number' OR e::numeric <> trunc(e::numeric) THEN
      RAISE EXCEPTION 'days must be a list of whole numbers' USING ERRCODE = 'PT422';
    END IF;
    days := days || e::numeric::int;
  END LOOP;
  IF cardinality(days) > 5 THEN RAISE EXCEPTION '%', bad USING ERRCODE = 'PT400'; END IF;
  FOR i IN 1 .. coalesce(cardinality(days), 0) LOOP
    IF days[i] < 2 OR days[i] > 90 OR (i > 1 AND days[i] <= days[i - 1]) THEN RAISE EXCEPTION '%', bad USING ERRCODE = 'PT400'; END IF;
  END LOOP;
  RETURN days;
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_followups_set(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); days int[] := crm_private.fb_followup_days(p_data->'days');
BEGIN
  PERFORM crm_private.fb_set_setting('followup_schedule_days', to_jsonb(days), eid);
  PERFORM crm_private.fb_audit(eid, 'followup_schedule_set', 'system_setting', 'followup_schedule_days', jsonb_build_object('days', days));
  RETURN json_build_object('followup_schedule_days', days);
END $$;

-- ------------------------------------------------------------------ outreach pipeline (one row per school emailed)
CREATE OR REPLACE FUNCTION crm_private.fb_pipeline() RETURNS TABLE (
  org_id uuid, name text, country text, region text, city text, website text, email text, stage text, note text,
  subject text, sent_at timestamptz, followups_sent int, followups_planned int, next_followup_at timestamptz,
  reply_at timestamptz, reply_intent text, reply_snippet text, last_at timestamptz, via text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  WITH b AS (
    SELECT g.id, g.name, g.country, g.region, g.city, g.website_domain, g.status AS gstatus, g.rejection_reason,
           io.status AS ostatus, io.subject, io.sent_at, io.thread_id, io.created_at AS ocreated, io.last_error,
           coalesce(c.email, dc.email) AS email, coalesce(c.verification_level, dc.verification_level) AS vlevel,
           coalesce(c.email_hash, dc.email_hash) AS ehash, dr.astatus, dr.acreated, dr.dsubject, ap.decided_via
      FROM flightbridge.organisation g
      LEFT JOIN LATERAL (SELECT o.* FROM flightbridge.outbound_message o WHERE o.org_id = g.id AND o.kind = 'initial'
                          ORDER BY o.created_at DESC LIMIT 1) io ON true
      LEFT JOIN flightbridge.contact c ON c.id = io.contact_id
      LEFT JOIN LATERAL (SELECT a.status AS astatus, a.created_at AS acreated, d.subject AS dsubject, d.contact_id
                           FROM flightbridge.ai_draft d JOIN flightbridge.approval_task a ON a.draft_id = d.id
                          WHERE d.org_id = g.id AND d.kind = 'initial' ORDER BY a.created_at DESC LIMIT 1) dr ON true
      LEFT JOIN flightbridge.contact dc ON dc.id = dr.contact_id
      LEFT JOIN flightbridge.approval_task ap ON ap.id = io.approval_task_id
     WHERE g.deleted_at IS NULL AND (io.id IS NOT NULL OR dr.astatus IS NOT NULL)
  ), x AS (
    SELECT b.*,
      (SELECT count(*)::int FROM flightbridge.outbound_message f WHERE f.thread_id = b.thread_id AND f.kind = 'followup'
          AND f.status IN ('sent', 'send_unknown')) AS fsent,
      (SELECT count(*)::int FROM flightbridge.follow_up_task t WHERE t.thread_id = b.thread_id) AS fplanned,
      (SELECT min(t.due_at) FROM flightbridge.follow_up_task t WHERE t.thread_id = b.thread_id AND t.status IN ('scheduled', 'enqueued')) AS fnext,
      (SELECT max(f.sent_at) FROM flightbridge.outbound_message f WHERE f.thread_id = b.thread_id AND f.status = 'sent') AS lastsent,
      r.occurred_at AS rat, r.intent AS rintent, r.snip AS rsnip,
      EXISTS (SELECT 1 FROM flightbridge.suppression s WHERE s.scope = 'contact' AND s.email_hash = b.ehash
                 AND s.reason = 'unsubscribe') AS unsub
    FROM b
    LEFT JOIN LATERAL (SELECT m.occurred_at, cl.intent, left(regexp_replace(coalesce(m.body_text, ''), '\s+', ' ', 'g'), 160) AS snip
                         FROM flightbridge.email_message m LEFT JOIN flightbridge.ai_classification cl ON cl.message_id = m.id
                        WHERE m.thread_id = b.thread_id AND m.direction = 'inbound' AND NOT m.is_bounce AND NOT m.is_auto_reply
                        ORDER BY m.occurred_at DESC LIMIT 1) r ON b.thread_id IS NOT NULL
  )
  SELECT x.id, x.name, x.country, x.region, x.city, x.website_domain, x.email,
    CASE
      WHEN x.gstatus = 'partner' THEN 'partner'
      WHEN x.gstatus = 'negotiation' THEN 'meeting'
      WHEN x.vlevel = 'bounced' OR x.ostatus = 'failed' OR x.unsub OR x.gstatus = 'rejected' THEN 'closed'
      WHEN x.rat IS NOT NULL THEN 'replied'
      WHEN x.ostatus IN ('sent', 'send_unknown') AND x.fnext IS NULL AND x.fsent >= x.fplanned
           AND coalesce(x.lastsent, x.sent_at) < now() - interval '7 days' THEN 'closed'
      WHEN x.ostatus IN ('sent', 'send_unknown') AND x.fsent > 0 THEN 'followup'
      WHEN x.ostatus IN ('sent', 'send_unknown') THEN 'sent'
      ELSE 'queued' END,
    CASE
      WHEN x.gstatus = 'partner' THEN 'Partner'
      WHEN x.gstatus = 'negotiation' THEN 'In talks / meeting'
      WHEN x.vlevel = 'bounced' THEN 'Bounced: address does not exist'
      WHEN x.ostatus = 'failed' THEN 'Mailbox refused: ' || coalesce(x.last_error, '')
      WHEN x.unsub THEN 'Unsubscribed'
      WHEN x.gstatus = 'rejected' AND x.rejection_reason = 'declined_by_school' THEN 'Declined'
      WHEN x.gstatus = 'rejected' THEN 'Closed by you'
      WHEN x.rat IS NOT NULL THEN CASE
           WHEN x.rintent IN ('positive_interest', 'meeting_request', 'profile_request') THEN 'Interested'
           WHEN x.rintent IN ('commercial_terms', 'agreement_request', 'student_volume', 'regulatory_question',
                              'liability_question') THEN 'Asked a question'
           ELSE 'Replied' END
      WHEN x.ostatus IN ('sent', 'send_unknown') AND x.fnext IS NULL AND x.fsent >= x.fplanned
           AND coalesce(x.lastsent, x.sent_at) < now() - interval '7 days' THEN 'No reply'
      WHEN x.ostatus IN ('sent', 'send_unknown') AND x.fnext IS NOT NULL THEN 'Waiting for reply'
      WHEN x.ostatus IN ('sent', 'send_unknown') THEN 'Waiting for reply'
      WHEN x.ostatus = 'blocked' THEN 'Stopped by a safety check'
      WHEN x.ostatus = 'needs_review' THEN 'Needs your review'
      WHEN x.ostatus = 'dry_run_rendered' THEN 'Rehearsal only (dry run)'
      WHEN x.ostatus IN ('pending_checks', 'authorized', 'sending') THEN 'Sending'
      WHEN x.astatus = 'open' THEN 'Ready to send'
      WHEN x.astatus = 'rejected' THEN 'Draft rejected'
      ELSE 'Waiting' END,
    coalesce(x.subject, x.dsubject), x.sent_at, x.fsent, x.fplanned, x.fnext, x.rat, x.rintent, x.rsnip,
    greatest(x.rat, x.lastsent, x.sent_at, x.ocreated, x.acreated), x.decided_via
  FROM x
$$;
REVOKE ALL ON FUNCTION crm_private.fb_pipeline() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.api_fb_pipeline(p_data jsonb DEFAULT '{}') RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE stg text := coalesce(crm_private.fb_text(p_data, 'stage', 20), 'all');
  q text := nullif(btrim(coalesce(crm_private.fb_text(p_data, 'q', 100), '')), '');
  lim int := coalesce(crm_private.fb_int(p_data, 'limit', 1, 1000, 300), 300);
BEGIN
  PERFORM crm_private.fb_member();
  RETURN json_build_object(
    'counts', (SELECT json_object_agg(s, n) FROM (SELECT p.stage s, count(*) n FROM crm_private.fb_pipeline() p GROUP BY 1) z),
    'rows', coalesce((SELECT json_agg(row_to_json(p) ORDER BY p.last_at DESC NULLS LAST) FROM (
        SELECT * FROM crm_private.fb_pipeline() p
         WHERE (stg = 'all' OR p.stage = stg)
           AND (q IS NULL OR p.name ILIKE '%' || q || '%' OR p.email ILIKE '%' || q || '%' OR p.country ILIKE q)
         ORDER BY p.last_at DESC NULLS LAST LIMIT lim) p), '[]'::json));
END $$;

-- move a school by hand: meeting / partner / closed (stops every email to it) / reopen
CREATE OR REPLACE FUNCTION public.api_fb_pipeline_move(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  oid uuid := crm_private.fb_uuid(crm_private.fb_text(p_data, 'org_id', 60, true), 'org_id is not valid');
  stg text := crm_private.fb_text(p_data, 'stage', 20, true); n int := 0;
BEGIN
  IF stg NOT IN ('meeting', 'partner', 'closed', 'reopen') THEN
    RAISE EXCEPTION 'stage must be meeting, partner, closed or reopen' USING ERRCODE = 'PT400';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM flightbridge.organisation WHERE id = oid AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'school not found' USING ERRCODE = 'PT404';
  END IF;
  IF stg = 'meeting' THEN
    UPDATE flightbridge.organisation SET status = 'negotiation', rejection_reason = NULL, updated_at = now() WHERE id = oid;
  ELSIF stg = 'partner' THEN
    UPDATE flightbridge.organisation SET status = 'partner', rejection_reason = NULL, updated_at = now() WHERE id = oid;
  ELSIF stg = 'reopen' THEN
    UPDATE flightbridge.organisation SET status = 'contacted', rejection_reason = NULL, updated_at = now() WHERE id = oid;
  ELSE
    UPDATE flightbridge.organisation SET status = 'rejected', rejection_reason = 'closed_by_owner', updated_at = now() WHERE id = oid;
  END IF;
  IF stg IN ('meeting', 'partner', 'closed') THEN   -- a person is handling it now: no more automatic emails
    UPDATE flightbridge.follow_up_task t SET status = 'cancelled', cancelled_reason = 'moved_by_owner:' || stg
      FROM flightbridge.email_thread th WHERE th.id = t.thread_id AND th.org_id = oid AND t.status = 'scheduled';
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE flightbridge.approval_task a SET status = 'rejected', decided_by = eid, decided_at = now(),
           decision_note = 'School moved to ' || stg || ' by hand'
      FROM flightbridge.ai_draft d WHERE d.id = a.draft_id AND d.org_id = oid AND a.status = 'open' AND d.kind IN ('initial', 'followup');
  END IF;
  PERFORM crm_private.fb_audit(eid, 'pipeline_moved', 'organisation', oid::text, jsonb_build_object('stage', stg, 'followups_cancelled', n));
  RETURN json_build_object('ok', true, 'stage', stg, 'followups_cancelled', n);
END $$;

-- ------------------------------------------------------------------ Email Auto-Pilot screen
-- the mailboxes the owner can send from (a drop-down on the screen); integrations.send_from holds the choice
CREATE OR REPLACE FUNCTION crm_private.fb_mailboxes() RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  WITH cfg AS (SELECT coalesce((SELECT value FROM flightbridge.system_setting WHERE key = 'integrations'), '{}'::jsonb) v)
  SELECT json_agg(m ORDER BY m.o) FROM (
    SELECT 1 o, 'hiox' id, coalesce(cfg.v->>'hiox_mail_user', 'partnership@weoneaviation.in') address, 'HIOX India' provider,
           coalesce((SELECT s.last_test_ok FROM flightbridge.integration_secret s WHERE s.name = 'hiox_mail_password'), false) connected,
           coalesce(cfg.v->>'send_from', 'hostinger') = 'hiox' selected FROM cfg
    UNION ALL
    SELECT 2, 'hostinger', 'Hostinger mailbox', 'Hostinger',
           coalesce((SELECT s.last_test_ok FROM flightbridge.integration_secret s WHERE s.name = 'hostinger_mail_api_token'), false),
           coalesce(cfg.v->>'send_from', 'hostinger') = 'hostinger' FROM cfg) m
$$;
REVOKE ALL ON FUNCTION crm_private.fb_mailboxes() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.api_fb_send_autopilot() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE cfg jsonb; st jsonb; env jsonb; ks jsonb; days jsonb;
BEGIN
  PERFORM crm_private.fb_member();
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'send_autopilot';
  SELECT value INTO st FROM flightbridge.system_setting WHERE key = 'send_autopilot_state';
  SELECT value INTO env FROM flightbridge.system_setting WHERE key = 'engine_status';
  SELECT value INTO ks FROM flightbridge.system_setting WHERE key = 'outbound_kill_switch';
  SELECT value INTO days FROM flightbridge.system_setting WHERE key = 'followup_schedule_days';
  RETURN json_build_object(
    'config', coalesce(cfg, '{}') - 'by',
    'enabled_by', (SELECT e.name FROM public.employee e WHERE e.id::text = cfg->>'by'),
    'state', coalesce(st, '{}'),
    'engine', env,
    'engine_online', coalesce((env->>'at')::timestamptz > now() - interval '3 minutes', false),
    'kill_switch_engaged', ks IS DISTINCT FROM 'false'::jsonb,
    'followup_days', coalesce(days, '[4, 9, 16]'),
    'mailboxes', crm_private.fb_mailboxes(),
    'templates', (SELECT coalesce(json_object_agg(t.kind, true), '{}') FROM flightbridge.outreach_template t WHERE t.status = 'approved'),
    'ready', (SELECT count(*) FROM flightbridge.approval_task a JOIN flightbridge.ai_draft d ON d.id = a.draft_id
                JOIN flightbridge.organisation g ON g.id = d.org_id
               WHERE a.status = 'open' AND d.kind = 'initial' AND g.eligibility = 'eligible_verified' AND g.deleted_at IS NULL),
    'followups_waiting', (SELECT count(*) FROM flightbridge.approval_task a JOIN flightbridge.ai_draft d ON d.id = a.draft_id
                          WHERE a.status = 'open' AND d.kind = 'followup'),
    'eligible', (SELECT count(*) FROM flightbridge.organisation g WHERE g.eligibility = 'eligible_verified' AND g.deleted_at IS NULL
                   AND g.status <> 'rejected'),
    'eligible_with_email', (SELECT count(*) FROM flightbridge.organisation g WHERE g.eligibility = 'eligible_verified'
                   AND g.deleted_at IS NULL AND g.status <> 'rejected'
                   AND EXISTS (SELECT 1 FROM flightbridge.contact c WHERE c.org_id = g.id)),
    'sent_total', (SELECT count(*) FROM flightbridge.outbound_message o WHERE o.status IN ('sent', 'send_unknown')),
    'recent', coalesce((SELECT json_agg(r ORDER BY r.at DESC) FROM (
        SELECT o.id, g.name, g.country, o.kind, o.status, o.subject, coalesce(o.sent_at, o.created_at) AS at, o.last_error
          FROM flightbridge.outbound_message o JOIN flightbridge.approval_task a ON a.id = o.approval_task_id
          JOIN flightbridge.organisation g ON g.id = o.org_id
         WHERE a.decided_via = 'autopilot' ORDER BY o.created_at DESC LIMIT 15) r), '[]'::json));
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_send_autopilot_set(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); cur jsonb; v jsonb; on_now boolean; days int[];
  sf text := crm_private.fb_text(p_data, 'send_from', 20); integ jsonb;
BEGIN
  SELECT value INTO cur FROM flightbridge.system_setting WHERE key = 'send_autopilot' FOR UPDATE;
  IF jsonb_typeof(cur) IS DISTINCT FROM 'object' THEN cur := '{}'; END IF;
  v := cur;
  IF sf IS NOT NULL THEN
    IF sf NOT IN ('hostinger', 'hiox') THEN RAISE EXCEPTION 'Choose a mailbox from the list' USING ERRCODE = 'PT400'; END IF;
    IF NOT EXISTS (SELECT 1 FROM flightbridge.integration_secret WHERE last_test_ok
                    AND name = CASE sf WHEN 'hiox' THEN 'hiox_mail_password' ELSE 'hostinger_mail_api_token' END) THEN
      RAISE EXCEPTION 'That mailbox isn''t connected yet: connect it in Settings > Email (Save & test) first' USING ERRCODE = 'PT400';
    END IF;
    SELECT value INTO integ FROM flightbridge.system_setting WHERE key = 'integrations' FOR UPDATE;
    IF jsonb_typeof(integ) IS DISTINCT FROM 'object' THEN integ := '{}'; END IF;
    PERFORM crm_private.fb_set_setting('integrations', integ || jsonb_build_object('send_from', sf), eid);
    v := v || jsonb_build_object('check_requested_at', now());       -- the checklist follows the new mailbox
  END IF;
  IF p_data ? 'enabled' THEN
    on_now := crm_private.fb_bool(p_data, 'enabled', false);
    IF on_now AND NOT coalesce((cur->>'enabled')::boolean, false) THEN
      v := v || jsonb_build_object('enabled', true, 'by', eid, 'since', now(), 'check_requested_at', now());
    ELSIF NOT on_now THEN
      v := v || jsonb_build_object('enabled', false);
    END IF;
  END IF;
  IF p_data ? 'daily_limit' THEN v := v || jsonb_build_object('daily_limit', crm_private.fb_int(p_data, 'daily_limit', 1, 100, 40)); END IF;
  IF p_data ? 'warmup' THEN v := v || jsonb_build_object('warmup', crm_private.fb_bool(p_data, 'warmup', true)); END IF;
  IF crm_private.fb_bool(p_data, 'check_now', false) THEN v := v || jsonb_build_object('check_requested_at', now()); END IF;
  IF crm_private.fb_bool(p_data, 'resume', false) THEN v := v || jsonb_build_object('resume_at', now(), 'check_requested_at', now()); END IF;
  IF p_data ? 'followup_days' THEN
    days := crm_private.fb_followup_days(p_data->'followup_days');
    PERFORM crm_private.fb_set_setting('followup_schedule_days', to_jsonb(days), eid);
  END IF;
  PERFORM crm_private.fb_set_setting('send_autopilot', v, eid);
  PERFORM crm_private.fb_audit(eid, 'send_autopilot_set', 'system_setting', 'send_autopilot', (v - 'by') || jsonb_build_object('input', p_data));
  RETURN (v - 'by')::json;
END $$;

-- one-click unsubscribe (List-Unsubscribe header; called by the Edge Function with the service role only)
CREATE OR REPLACE FUNCTION public.svc_fb_unsubscribe(p_ref text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE r record; n int;
BEGIN
  IF p_ref IS NULL OR p_ref !~ '^FB-[0-9A-F]{12}$' THEN RETURN json_build_object('ok', false); END IF;
  SELECT o.thread_id, c.email_hash, g.name INTO r FROM flightbridge.outbound_message o
    JOIN flightbridge.contact c ON c.id = o.contact_id JOIN flightbridge.organisation g ON g.id = o.org_id
   WHERE o.ref_token = p_ref;
  IF NOT FOUND THEN RETURN json_build_object('ok', false); END IF;
  INSERT INTO flightbridge.suppression (scope, email_hash, reason, source_ref)
  SELECT 'contact', r.email_hash, 'unsubscribe', 'one_click:' || p_ref
   WHERE NOT EXISTS (SELECT 1 FROM flightbridge.suppression s WHERE s.scope = 'contact' AND s.email_hash = r.email_hash
                       AND s.reason = 'unsubscribe');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF r.thread_id IS NOT NULL THEN
    UPDATE flightbridge.follow_up_task SET status = 'cancelled', cancelled_reason = 'unsubscribe'
     WHERE thread_id = r.thread_id AND status = 'scheduled';
    UPDATE flightbridge.email_thread SET status = 'suppressed', updated_at = now() WHERE id = r.thread_id;
  END IF;
  INSERT INTO flightbridge.audit_log (actor_type, action, entity, entity_id, payload)
  VALUES ('system', 'one_click_unsubscribe', 'outbound_message', p_ref, jsonb_build_object('new', n > 0));
  RETURN json_build_object('ok', true, 'already', n = 0);
END $$;
REVOKE ALL ON FUNCTION public.svc_fb_unsubscribe(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_fb_unsubscribe(text) TO service_role;

GRANT EXECUTE ON FUNCTION public.api_fb_pipeline(jsonb), public.api_fb_pipeline_move(jsonb), public.api_fb_send_autopilot(),
  public.api_fb_send_autopilot_set(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.api_fb_pipeline(jsonb), public.api_fb_pipeline_move(jsonb), public.api_fb_send_autopilot(),
  public.api_fb_send_autopilot_set(jsonb), crm_private.fb_followup_days(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_private.fb_pipeline() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_pipeline(jsonb), public.api_fb_pipeline_move(jsonb), public.api_fb_send_autopilot(),
  public.api_fb_send_autopilot_set(jsonb) TO authenticated;

-- "Write follow-ups with AI" (Auto-Pilot): the approved first email, the remembered brief and the follow-up days.
-- Shares the 40-a-day limit of "Write with AI".
CREATE OR REPLACE FUNCTION public.api_fb_followup_generate_start() RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); used int; b jsonb; d jsonb; t record;
BEGIN
  SELECT subject, body INTO t FROM flightbridge.outreach_template WHERE kind = 'initial' AND status = 'approved';
  IF NOT FOUND THEN RAISE EXCEPTION 'Approve a first email first (Email templates)' USING ERRCODE = 'PT400'; END IF;
  SELECT value INTO d FROM flightbridge.system_setting WHERE key = 'followup_schedule_days';
  IF d IS NULL OR jsonb_typeof(d) <> 'array' THEN d := '[4, 9, 16]'; END IF;
  IF jsonb_array_length(d) = 0 THEN RAISE EXCEPTION 'Follow-ups are set to none' USING ERRCODE = 'PT400'; END IF;
  SELECT count(*) INTO used FROM flightbridge.audit_log
   WHERE action = 'template_generated' AND actor_id::text = eid::text AND at > now() - interval '1 day';
  IF used >= 40 THEN RAISE EXCEPTION 'Daily limit reached (40 generations). Try again tomorrow.' USING ERRCODE = 'PT429'; END IF;
  SELECT value INTO b FROM flightbridge.system_setting WHERE key = 'template_brief';
  PERFORM crm_private.fb_audit(eid, 'template_generated', 'outreach_template', 'ai_followups', jsonb_build_object('count', jsonb_array_length(d)));
  RETURN json_build_object('brief', b, 'initial', json_build_object('subject', t.subject, 'body', t.body), 'days', d);
END $$;
REVOKE ALL ON FUNCTION public.api_fb_followup_generate_start() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_followup_generate_start() TO authenticated;
