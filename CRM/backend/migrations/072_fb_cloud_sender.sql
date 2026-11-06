-- 072: the Auto-Pilot screen shows the cloud sender (GitHub Actions, engine 1.8.3 'cloud-send'), which sends during
-- school hours when the Mac Mini is off. It reports in system_setting 'cloud_sender' {at, state, may_send}.
--   cloud_online: reported in the last 15 minutes;  cloud_ready: reported in the last 3 days (set up and running).
CREATE OR REPLACE FUNCTION public.api_fb_send_autopilot()
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE cfg jsonb; st jsonb; env jsonb; ks jsonb; days jsonb; cl jsonb;
BEGIN
  PERFORM crm_private.fb_member();
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'send_autopilot';
  SELECT value INTO st FROM flightbridge.system_setting WHERE key = 'send_autopilot_state';
  SELECT value INTO env FROM flightbridge.system_setting WHERE key = 'engine_status';
  SELECT value INTO ks FROM flightbridge.system_setting WHERE key = 'outbound_kill_switch';
  SELECT value INTO days FROM flightbridge.system_setting WHERE key = 'followup_schedule_days';
  SELECT value INTO cl FROM flightbridge.system_setting WHERE key = 'cloud_sender';
  RETURN json_build_object(
    'config', coalesce(cfg, '{}') - 'by',
    'enabled_by', (SELECT e.name FROM public.employee e WHERE e.id::text = cfg->>'by'),
    'state', coalesce(st, '{}'),
    'engine', env,
    'engine_online', coalesce((env->>'at')::timestamptz > now() - interval '3 minutes', false),
    'cloud', cl,
    'cloud_online', coalesce((cl->>'at')::timestamptz > now() - interval '15 minutes', false),
    'cloud_ready', coalesce((cl->>'at')::timestamptz > now() - interval '3 days', false),
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
END $function$;
