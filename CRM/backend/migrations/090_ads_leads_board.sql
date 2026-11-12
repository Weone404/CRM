-- 090: ADS > Ads Leads screen. Read functions only; ADS-only (reads employee names, writes nothing outside ADS).
-- Rollback: DROP FUNCTION public.api_ads_lead_board(text,text,boolean,text,integer), public.api_ads_staff();

-- Everything the Ads Leads list needs in one call: counts, stage list for the pipeline, rows.
CREATE OR REPLACE FUNCTION public.api_ads_lead_board(p_pipeline text DEFAULT 'pilot_training', p_stage text DEFAULT NULL,
  p_quarantined boolean DEFAULT false, p_search text DEFAULT NULL, p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pl text := coalesce(p_pipeline, 'pilot_training'); q text := nullif(btrim(coalesce(p_search, '')), '');
        today_start timestamptz := (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
        month_start timestamptz := (date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
BEGIN
  PERFORM crm_private.ads_require_view();
  IF pl NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT400'; END IF;
  RETURN jsonb_build_object(
    'role', crm_private.ads_role(),
    'stages', (SELECT jsonb_agg(jsonb_build_object('stage', d.stage, 'label', d.label, 'ord', d.ord, 'terminal', d.is_terminal,
                 'customer', d.is_customer, 'needs_evidence', d.needs_evidence) ORDER BY d.ord) FROM public.ads_stage_def d WHERE d.pipeline = pl),
    'stats', (SELECT jsonb_build_object(
       'new_today', count(*) FILTER (WHERE l.created_at >= today_start AND NOT l.quarantined),
       'not_contacted', count(*) FILTER (WHERE l.stage = 'lead_created' AND l.first_response_at IS NULL AND NOT l.quarantined),
       'qualified_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            WHERE x.pipeline = pl AND s.to_stage = 'qualified' AND s.at >= month_start AND x.deleted_at IS NULL),
       'customers_month', (SELECT count(DISTINCT s.lead_id) FROM public.ads_lead_stage_event s JOIN public.ads_lead x ON x.id = s.lead_id
                            JOIN public.ads_stage_def d ON d.pipeline = x.pipeline AND d.stage = s.to_stage
                            WHERE x.pipeline = pl AND d.is_customer AND s.at >= month_start AND x.deleted_at IS NULL),
       'quarantined', count(*) FILTER (WHERE l.quarantined),
       'total', count(*) FILTER (WHERE NOT l.quarantined))
      FROM public.ads_lead l WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
       SELECT l.id, l.name, l.phone_e164, l.email, l.stage, l.contact_status, l.quarantined, l.quarantine_reasons,
              l.owner_employee_id, e.name AS owner_name, l.organic_lead_id, l.enquiry_count, l.course_interest, l.charter_details,
              l.first_touch, l.last_non_direct, l.first_response_at, l.last_interaction_at, l.created_at,
              CASE WHEN l.first_touch ?| ARRAY['gclid', 'gbraid', 'wbraid'] OR lower(coalesce(l.first_touch->>'utm_source', '')) LIKE '%google%' THEN 'Google'
                   WHEN l.first_touch ?| ARRAY['fbclid', 'fbc'] OR lower(coalesce(l.first_touch->>'utm_source', '')) ~ '(facebook|instagram|meta|fb|ig)' THEN 'Meta'
                   ELSE 'Ad' END AS source,
              coalesce(l.last_non_direct->>'utm_campaign', l.first_touch->>'utm_campaign') AS campaign
       FROM public.ads_lead l LEFT JOIN public.employee e ON e.id = l.owner_employee_id
       WHERE l.pipeline = pl AND l.deleted_at IS NULL AND l.anonymised_at IS NULL
         AND l.quarantined = coalesce(p_quarantined, false)
         AND (p_stage IS NULL OR l.stage = p_stage)
         AND (q IS NULL OR l.name ILIKE '%' || q || '%' OR l.phone_e164 LIKE '%' || regexp_replace(q, '\D', '', 'g') || '%'
              AND regexp_replace(q, '\D', '', 'g') <> '' OR l.email ILIKE '%' || q || '%')
       ORDER BY l.created_at DESC LIMIT least(greatest(coalesce(p_limit, 100), 1), 300)) x), '[]'::jsonb));
END $$;

-- People an Ads lead can be assigned to: Admins and ADS members who can work leads (not viewers).
CREATE OR REPLACE FUNCTION public.api_ads_staff() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) ORDER BY e.name)
    FROM public.employee e
    WHERE e.active AND (e.department::text = 'Admin'
       OR EXISTS (SELECT 1 FROM public.ads_access a WHERE a.employee_id = e.id AND a.role <> 'viewer'))), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.api_ads_lead_board(text,text,boolean,text,integer), public.api_ads_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text,text,boolean,text,integer), public.api_ads_staff() TO authenticated;
