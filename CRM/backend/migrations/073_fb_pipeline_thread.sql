-- 073: the conversation with one school, for the Pipeline's email preview: every email sent to it (exactly as sent,
-- footer included) and every reply, oldest first. Read-only, any FlightBridge member.
CREATE OR REPLACE FUNCTION public.api_fb_pipeline_thread(p_org_id text)
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE oid uuid := crm_private.fb_uuid(p_org_id, 'School not found');
BEGIN
  PERFORM crm_private.fb_member();
  IF NOT EXISTS (SELECT 1 FROM flightbridge.organisation WHERE id = oid) THEN
    RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT404';
  END IF;
  RETURN json_build_object(
    'school', (SELECT json_build_object('id', o.id, 'name', o.name, 'country', o.country, 'city', o.city,
                                        'website', o.website_domain)
                 FROM flightbridge.organisation o WHERE o.id = oid),
    'messages', coalesce((SELECT json_agg(x ORDER BY x.at) FROM (
        SELECT m.id, 'out' AS direction, m.kind, m.status, m.subject, m.body_text AS body, c.email AS address,
               coalesce(m.sent_at, m.created_at) AS at, m.ref_token, a.decided_via AS via, m.last_error
          FROM flightbridge.outbound_message m
          JOIN flightbridge.contact c ON c.id = m.contact_id
     LEFT JOIN flightbridge.approval_task a ON a.id = m.approval_task_id
         WHERE m.org_id = oid AND m.status IN ('sent', 'send_unknown', 'failed', 'sending', 'authorized')
        UNION ALL
        SELECT e.id, 'in', CASE WHEN e.is_bounce THEN 'bounce' WHEN e.is_auto_reply THEN 'auto_reply' ELSE 'reply' END,
               NULL, e.subject, e.body_text, e.from_address, e.occurred_at, NULL, NULL, NULL
          FROM flightbridge.email_message e JOIN flightbridge.email_thread t ON t.id = e.thread_id
         WHERE t.org_id = oid AND e.direction = 'inbound') x), '[]'::json));
END $function$;

REVOKE ALL ON FUNCTION public.api_fb_pipeline_thread(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_pipeline_thread(text) TO authenticated;
