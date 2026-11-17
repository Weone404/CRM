-- 102: Meta's own CRM check (Events Manager > dataset > Test events > channel CRM). Needs 101. Safe to run again.
-- There Meta creates a "Verification Lead" (a Lead Ads Testing Tool lead, delivered to the CRM by the webhook and kept
-- as status 'test' by 101) and waits for the CRM to send an ordinary Conversions API event for that lead id, without a
-- test code. ads-sync job meta_test_event with no code uses this: the newest test lead of the last 7 days (Meta drops
-- older events), the dataset and the event name the dashboard maps to Lead Created. Real leads are never used.
-- Undo: 102_ads_meta_verification_down.sql.

CREATE OR REPLACE FUNCTION public.svc_ads_meta_verification_lead() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('lead_id', r.external_id, 'received_at', r.received_at,
    'dataset_id', (crm_private.ads_meta_set('instant_form')).dataset_id,
    'crm_name', coalesce(nullif(crm_private.ads_cfg('meta_crm_name'), ''), 'We One CRM'),
    'event_name', coalesce((SELECT m.meta_event_name FROM public.ads_meta_event_map m
                             WHERE m.source = 'instant_form' AND m.stage = 'lead_created' AND m.enabled
                             ORDER BY m.pipeline = coalesce((SELECT f.pipeline FROM public.ads_meta_forms f WHERE f.form_id = r.form_id), 'pilot_training') DESC,
                                      m.pipeline LIMIT 1), 'Lead'))
    FROM public.ads_meta_lead_raw r
   WHERE r.source = 'instant_form' AND r.status = 'test' AND r.received_at > now() - interval '7 days'
   ORDER BY r.received_at DESC LIMIT 1 $$;
REVOKE ALL ON FUNCTION public.svc_ads_meta_verification_lead() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_verification_lead() TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '102')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
