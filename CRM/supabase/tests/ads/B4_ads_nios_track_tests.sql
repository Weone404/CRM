-- 126: the NIOS route track (NT01-NT09). Runs after B3_ (its 'Live test' form 777100: q1 who is filling, q2 Class 12 status).
RESET ROLE;
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, stage, created_at) VALUES
  ('5b000000-0000-0000-0000-000000000126', 'pilot_training', 'Kavya N', '+919811400126', 'lead_created', now() - interval '20 minutes'),
  ('5b000000-0000-0000-0000-000000000127', 'pilot_training', 'Arjun P', '+919811400127', 'lead_created', now() - interval '10 minutes'),
  ('5b000000-0000-0000-0000-000000000128', 'pilot_training', 'Spam Q', '+919811400128', 'lead_created', now() - interval '5 minutes')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.ads_enquiry (received_at, idempotency_key, pipeline, channel, name, phone_raw, phone_e164, reported_first_touch, quality, quality_reasons, dedup_result, ads_lead_id, result, payload_extra) VALUES
  (now() - interval '20 minutes', 'b4-enq-1', 'pilot_training', 'ads', 'Kavya N', '+919811400126', '+919811400126', '{"form_id": "777100"}', 'ok', '{}', 'new_contact',
   '5b000000-0000-0000-0000-000000000126', '{"status": "created"}', '{"meta_answers": {"q1": "q1o1", "q2": "q2o2", "city": "Jaipur"}}'),
  (now() - interval '10 minutes', 'b4-enq-2', 'pilot_training', 'ads', 'Arjun P', '+919811400127', '+919811400127', '{"form_id": "999"}', 'ok', '{}', 'new_contact',
   '5b000000-0000-0000-0000-000000000127', '{"status": "created"}', '{"meta_answers": {"class_12_status?": "passed_with_other_subjects"}}'),
  (now() - interval '5 minutes', 'b4-enq-3', 'pilot_training', 'ads', 'Spam Q', '+919811400128', '+919811400128', '{"form_id": "777100"}', 'ok', '{}', 'new_contact',
   '5b000000-0000-0000-0000-000000000128', '{"status": "created"}', '{"meta_answers": {"q2": "q2o2"}}')
ON CONFLICT (idempotency_key) DO NOTHING;
UPDATE public.ads_lead SET quarantined = true, quarantine_reasons = '{test}' WHERE id = '5b000000-0000-0000-0000-000000000128';
SELECT pg_temp.ok((SELECT track FROM public.ads_lead WHERE id = '5b000000-0000-0000-0000-000000000126') = 'nios',
  'NT01 "Class 12 status?" = "Passed with other subjects" (coded q2o2 on a CRM-built form) puts the lead on the NIOS route');
SELECT pg_temp.ok((SELECT track FROM public.ads_lead WHERE id = '5b000000-0000-0000-0000-000000000127') = 'nios'
    AND (SELECT track FROM public.ads_lead WHERE id = '5b000000-0000-0000-0000-000000000121') IS NULL,
  'NT02 a form the CRM did not build (raw Meta keys) is read too; "Passed with Physics & Maths" stays on the CPL track');

SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bd126 AS SELECT public.api_ads_lead_board('pilot_training', NULL, false, NULL, 50, NULL, 'nios') b, public.api_ads_lead_board('pilot_training', NULL, false, NULL, 50, NULL) a;
RESET ROLE;
SELECT pg_temp.ok((SELECT jsonb_agg(r->>'name' ORDER BY r->>'name') = '["Arjun P", "Kavya N"]'::jsonb AND bool_and(r->>'track' = 'nios') FROM bd126, jsonb_array_elements(b->'rows') r)
    AND (SELECT (b->'stats'->>'nios')::int = 2 AND (a->'stats'->>'nios')::int = 2 FROM bd126),
  'NT03 p_track => nios lists only NIOS-route leads; stats.nios counts them (a quarantined one is not counted)');
SELECT pg_temp.ok((SELECT bool_and(r ? 'track') AND bool_or(r->>'name' = 'Meena K' AND r->'track' = 'null'::jsonb) AND bool_or(r->>'name' = 'Kavya N' AND r->>'track' = 'nios')
      AND bool_or(r->>'name' = 'Meena K' AND r->>'ad_name' = 'Pilot after 12th')
    FROM bd126, jsonb_array_elements(a->'rows') r),
  'NT04 every board row carries its track; the 125 fields (answers, ad, app) are still there');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($$SELECT public.api_ads_lead_board('pilot_training', NULL, false, NULL, 50, NULL, 'cpl')$$, '%Unknown track%', 'NT05 an unknown track is refused');
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($$SELECT public.api_ads_lead_board('pilot_training', NULL, false, NULL, 50, NULL, 'nios')$$, '%do not have access%', 'NT06 a user without ADS access cannot read the NIOS list');
RESET ROLE;

-- the latest answer decides: the same person fills the form again with Physics & Maths
INSERT INTO public.ads_enquiry (received_at, idempotency_key, pipeline, channel, name, phone_raw, phone_e164, reported_first_touch, quality, quality_reasons, dedup_result, ads_lead_id, result, payload_extra)
VALUES (now(), 'b4-enq-4', 'pilot_training', 'ads', 'Arjun P', '+919811400127', '+919811400127', '{"form_id": "777100"}', 'ok', '{}', 'repeat_enquiry',
  '5b000000-0000-0000-0000-000000000127', '{"status": "repeat"}', '{"meta_answers": {"q2": "q2o1"}}') ON CONFLICT (idempotency_key) DO NOTHING;
SELECT pg_temp.ok((SELECT track FROM public.ads_lead WHERE id = '5b000000-0000-0000-0000-000000000127') IS NULL,
  'NT07 a later enquiry with "Passed with Physics & Maths" moves the lead back to the CPL track');

-- Conversions API: a NIOS-route lead is reported as Contacted, never as Qualified Lead
UPDATE public.ads_lead SET first_touch = '{"meta_source": "instant_form", "leadgen_id": "1260000000001"}', created_at = now() - interval '2 hours'
 WHERE id = '5b000000-0000-0000-0000-000000000126';
SELECT pg_temp.src('instant_form', '{"report_enabled": true, "consent_mode": "not_required"}');
SELECT pg_temp.stage('5b000000-0000-0000-0000-000000000126', 'contacted', '90 minutes');
SELECT pg_temp.stage('5b000000-0000-0000-0000-000000000126', 'qualified', '60 minutes');
SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT status FROM pg_temp.ups('5b000000-0000-0000-0000-000000000126') WHERE stage = 'contacted') = 'pending'
    AND (SELECT status = 'skipped' AND error LIKE 'NIOS route lead%' FROM pg_temp.ups('5b000000-0000-0000-0000-000000000126') WHERE stage = 'qualified')
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' = '5b000000-0000-0000-0000-000000000126:qualified')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' = '5b000000-0000-0000-0000-000000000126:contacted'),
  'NT09 a NIOS-route lead is never sent to Meta as Qualified Lead (kept as skipped, with the reason); Contacted still is');

-- leads from before 126: re-running the migration fills the track in
UPDATE public.ads_lead SET track = NULL WHERE id = '5b000000-0000-0000-0000-000000000126';
\i ../../../backend/migrations/126_ads_nios_track.sql
SELECT pg_temp.ok((SELECT track FROM public.ads_lead WHERE id = '5b000000-0000-0000-0000-000000000126') = 'nios'
    AND (SELECT value FROM public.ads_config WHERE key = 'ads_schema') = '126',
  'NT08 126 re-applies on live data and backfills the track of earlier leads');
\echo ALL ADS NIOS 126 TESTS PASSED
