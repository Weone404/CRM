-- 071: edit and delete email versions from the CRM.
-- Editing saves a new version (history stays intact); "Save and use" also approves it.
-- Delete removes a version that no draft used; a version that drafts used is hidden instead (kept for the audit trail)
-- and, if it was the one in use, stops being approved. The engine only reads status = 'approved', so it is unaffected.

ALTER TABLE flightbridge.outreach_template ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

CREATE OR REPLACE FUNCTION public.api_fb_templates()
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  PERFORM crm_private.fb_member();
  RETURN coalesce((SELECT json_agg(x) FROM (
    SELECT id, kind, version, subject, body, status, validation, created_at, approved_at
      FROM flightbridge.outreach_template WHERE deleted_at IS NULL ORDER BY kind, version DESC LIMIT 200) x), '[]');
END $function$;

CREATE OR REPLACE FUNCTION public.api_fb_template_approve(p_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE eid uuid := crm_private.fb_admin(); tid uuid := crm_private.fb_uuid(p_id, 'Template not found'); t record; v jsonb;
BEGIN
  SELECT kind, subject, body, status INTO t FROM flightbridge.outreach_template WHERE id = tid AND deleted_at IS NULL FOR UPDATE;
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
END $function$;

CREATE OR REPLACE FUNCTION public.api_fb_template_delete(p_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE eid uuid := crm_private.fb_admin(); tid uuid := crm_private.fb_uuid(p_id, 'Template not found'); t record; used boolean;
BEGIN
  SELECT kind, version, status INTO t FROM flightbridge.outreach_template WHERE id = tid AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Template not found' USING ERRCODE = 'PT404'; END IF;
  used := EXISTS (SELECT 1 FROM flightbridge.ai_draft WHERE template_id = tid);
  IF used THEN
    UPDATE flightbridge.outreach_template SET deleted_at = now(),
           status = CASE WHEN status = 'approved' THEN 'archived' ELSE status END WHERE id = tid;
  ELSE
    DELETE FROM flightbridge.outreach_template WHERE id = tid;
  END IF;
  PERFORM crm_private.fb_audit(eid, 'template_deleted', 'outreach_template', tid::text,
          jsonb_build_object('kind', t.kind, 'version', t.version, 'was_in_use', t.status = 'approved', 'kept_hidden', used));
  RETURN json_build_object('deleted', true, 'kind', t.kind, 'was_in_use', t.status = 'approved');
END $function$;

REVOKE ALL ON FUNCTION public.api_fb_template_delete(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_template_delete(text) TO authenticated;
