-- 101: Meta lead forms part 2. Testing Tool leads (MS40), form fills without an ad -> normal Leads (MS41-44),
-- Setup status and test-event lead (MS45-47). Runs after A0_ (uses its pg_temp helpers).
RESET ROLE;
SELECT pg_temp.src('instant_form', '{"intake_enabled": true}');
INSERT INTO public.ads_meta_forms (form_id, name, pipeline, active) VALUES ('987654321', 'Pilot course enquiry', 'pilot_training', true),
  ('987654322', 'Charter enquiry', 'charter', true)
ON CONFLICT (form_id) DO UPDATE SET name = EXCLUDED.name, pipeline = EXCLUDED.pipeline, active = true;
CREATE OR REPLACE FUNCTION pg_temp.opay(p_phone text, p_name text DEFAULT 'Organic Person') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('name', p_name, 'phone', p_phone, 'email', 'o@example.com', 'course_interest', 'CPL',
    'utm_source', 'Meta lead form', 'utm_medium', 'organic', 'meta_answers', jsonb_build_object('city', 'Delhi'))) $$;
CREATE OR REPLACE FUNCTION pg_temp.raw2(p_id text, p_form text) RETURNS int LANGUAGE sql SECURITY DEFINER AS $$
  SELECT public.svc_ads_meta_raw_add(jsonb_build_array(jsonb_build_object('source', 'instant_form', 'external_id', p_id,
    'page_id', '111222333444', 'form_id', p_form, 'created_time', 1794800000)), 'webhook') $$;

-- Testing Tool lead
SELECT pg_temp.raw2('2000000000000001', '987654321');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000001'), 'test');
SELECT pg_temp.ok((SELECT status = 'test' AND lead_id IS NULL AND organic_lead_id IS NULL FROM public.ads_meta_lead_raw WHERE external_id = '2000000000000001'),
  'MS40 a Lead Ads Testing Tool lead is kept as a test: not an Ads lead, not a normal lead');

-- Form filled without an ad -> normal Leads
SELECT pg_temp.raw2('2000000000000002', '987654321');
SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000002'), 'organic', pg_temp.opay('9811400001'), 'pilot_training')->>'status') = 'created',
  'MS41 a form filled without an ad becomes a normal lead');
SELECT pg_temp.ok((SELECT l.utm_source = 'Meta lead form' AND l.utm_medium = 'organic' AND l.utm_campaign = 'Pilot course enquiry' AND l.segment = 'aviation'
    AND l.course_interest = 'CPL' AND l.phone = '9811400001' AND r.status = 'organic'
    FROM public.ads_meta_lead_raw r JOIN public.lead l ON l.id = r.organic_lead_id WHERE r.external_id = '2000000000000002'),
  'MS41b it is labelled Meta lead form / organic / the form''s name, and the raw row points to it');
SELECT pg_temp.ok((SELECT payload->'answers'->>'city' = 'Delhi' FROM public.ads_meta_lead_raw WHERE external_id = '2000000000000002')
  AND NOT EXISTS (SELECT 1 FROM public.ads_lead WHERE phone_e164 = '+919811400001'),
  'MS41c the extra form answers are kept, and it is not an Ads lead');
SELECT pg_temp.raw2('2000000000000003', '987654321');
SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000003'), 'organic', pg_temp.opay('+91 98114 00001', 'Same Person'), 'pilot_training')->>'status') = 'duplicate',
  'MS42 the same phone again is not a second lead (same de-duplication as the website)');
SELECT pg_temp.ok((SELECT count(*) FROM public.lead WHERE dedup_key = '+919811400001') = 1
  AND (SELECT r3.organic_lead_id = r2.organic_lead_id FROM public.ads_meta_lead_raw r2, public.ads_meta_lead_raw r3
        WHERE r2.external_id = '2000000000000002' AND r3.external_id = '2000000000000003'),
  'MS42b ... both form fills point to the one lead');
SELECT pg_temp.raw2('2000000000000004', '987654322');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000004'), 'organic', pg_temp.opay('9811400004') - 'course_interest', 'charter');
SELECT pg_temp.ok((SELECT l.segment = 'charter' AND l.course_interest = 'Charter' AND l.utm_campaign = 'Charter enquiry'
    FROM public.ads_meta_lead_raw r JOIN public.lead l ON l.id = r.organic_lead_id WHERE r.external_id = '2000000000000004'),
  'MS43 a Charter form files a charter lead');
SELECT pg_temp.raw2('2000000000000005', '987654321');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000005'), 'organic', pg_temp.opay('no phone'), 'pilot_training');
SELECT pg_temp.ok((SELECT status = 'organic' AND organic_lead_id IS NULL AND error LIKE '%phone%' FROM public.ads_meta_lead_raw WHERE external_id = '2000000000000005'),
  'MS44 a fill without a valid phone is not filed, and the reason is shown');
SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '2000000000000002'), 'organic', pg_temp.opay('9811400099'), 'pilot_training')->>'skipped')::boolean,
  'MS44b a handled lead is never filed again');
SELECT pg_temp.ok((SELECT count(*) FROM public.lead WHERE dedup_key = '+919811400099') = 0, 'MS44c ... and nothing new is created');
SELECT pg_temp.fails($q$UPDATE public.ads_meta_lead_raw SET status = 'bogus' WHERE external_id = '2000000000000001'$q$, '%status_check%',
  'MS44d only known statuses are allowed');

-- Setup status and the test-event lead
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT (s->>'schema')::int >= 102 AND (s->'meta'->'leads'->>'test')::int >= 1 AND (s->'meta'->'leads'->>'organic_filed')::int >= 3
    AND (s->'meta'->'leads'->>'by_webhook')::int >= 5 AND s->'meta'->'leads'->>'last_error' LIKE '%phone%' FROM public.api_ads_setup_status('meta') s),
  'MS45 Setup sees the database version and what happened to each delivered lead');
RESET ROLE;
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT t->>'lead_id' = '2000000000000005' AND t->>'em' IS NULL AND t ? 'dataset_id' AND t->>'crm_name' <> '' FROM public.svc_ads_meta_test_lead() t),
  'MS46 with no Ads lead from a form, the test event uses the newest lead Meta delivered');
SELECT pg_temp.ok((SELECT v->>'lead_id' = '2000000000000001' AND v->>'event_name' <> '' AND v ? 'dataset_id' FROM public.svc_ads_meta_verification_lead() v),
  'MS48 Meta''s CRM check uses the newest test lead (never a real one), with the dashboard''s Lead Created event name');
RESET ROLE;
UPDATE public.ads_meta_lead_raw SET received_at = now() - interval '8 days' WHERE status = 'test';
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_meta_verification_lead() IS NULL, 'MS48b a test lead older than 7 days is not used (Meta drops events that old)');
RESET ROLE;
SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.svc_ads_meta_verification_lead()$q$, '%permission denied%', 'MS48c the browser cannot read it');
RESET ROLE;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.ads_meta_capi_uploads u JOIN public.ads_meta_lead_raw r ON r.lead_id = u.lead_id WHERE r.external_id LIKE '2000000000000%'),
  'MS47 test leads and form fills without an ad are never reported to Meta');

RESET ROLE;
UPDATE public.ads_meta_settings SET intake_enabled = false, report_enabled = false, consent_mode = 'required';
\echo ALL ADS META 101 TESTS PASSED
