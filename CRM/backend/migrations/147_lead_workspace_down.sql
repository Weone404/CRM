-- Undo 147. Restores api_leads to its 146 form first (it reads the new tables).
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
      'segment', coalesce(l.segment, 'aviation'), 'charter_details', l.charter_details
    ) ORDER BY l.created_at DESC)
    FROM public.lead l
    LEFT JOIN (SELECT ca.lead_id, count(*) AS cnt FROM public.contact_attempt ca
               WHERE ca.disposition = 'Not reachable' GROUP BY ca.lead_id) nr ON nr.lead_id = l.id
  ), '[]'::json);
END $function$;
DROP FUNCTION IF EXISTS public.api_lead_ws(text, uuid), public.api_lead_ws_save(text, uuid, jsonb), public.api_lead_ws_demo(uuid, text),
  public.api_lead_ws_followup_done(uuid), public.api_leads_today();
DROP FUNCTION IF EXISTS crm_private.lw_access(text, uuid, boolean), crm_private.lw_owner(text, uuid, uuid), crm_private.lw_name(text, uuid),
  crm_private.lw_task(uuid, uuid, text, text, timestamptz), crm_private.lw_ts(text, text);
DELETE FROM public.followup WHERE ads_lead_id IS NOT NULL;
ALTER TABLE public.followup DROP CONSTRAINT IF EXISTS followup_one_lead;
DROP INDEX IF EXISTS public.followup_ads_idx; DROP INDEX IF EXISTS public.followup_open_due_idx;
ALTER TABLE public.followup DROP COLUMN IF EXISTS task_id, DROP COLUMN IF EXISTS has_time, DROP COLUMN IF EXISTS ads_lead_id;
ALTER TABLE public.followup ALTER COLUMN lead_id SET NOT NULL;
DROP TABLE IF EXISTS public.lead_note, public.demo_class, public.lead_profile;
