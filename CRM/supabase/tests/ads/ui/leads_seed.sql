-- Ads Leads UI test data (local throwaway database only).
INSERT INTO public.ads_access (employee_id, role) VALUES ('00000000-0000-0000-0000-00000000000b', 'counsellor');
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, email, course_interest, first_touch, last_touch, created_at)
VALUES
 ('40000000-0000-0000-0000-000000000001', 'pilot_training', 'Ravi Kumar', '+919822200002', 'ravi@example.com', 'CPL',
  '{"gclid":"G1","utm_source":"google","utm_medium":"cpc","utm_campaign":"cpl-delhi","landing_page":"https://weoneaviation.in/cpl?gclid=G1"}', '{}', now() - interval '40 minutes'),
 ('40000000-0000-0000-0000-000000000002', 'pilot_training', 'Neha Sharma', '+919811100002', NULL, 'PPL',
  '{"fbclid":"F1","utm_source":"facebook","utm_medium":"paid_social","utm_campaign":"ppl-meta"}', '{}', now() - interval '5 minutes');
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, charter_details, first_touch, last_touch, quarantined, quarantine_reasons)
VALUES
 ('40000000-0000-0000-0000-000000000003', 'charter', 'Jet Client', '+919900000003', '{"from":"Delhi","to":"Goa","departureDate":"2027-01-10","passengers":4}',
  '{"gclid":"G3","utm_campaign":"charter-goa"}', '{}', false, '{}'),
 ('40000000-0000-0000-0000-000000000004', 'pilot_training', 'Bot Spam', '+919844400004', NULL,
  '{"gclid":"G4"}', '{}', true, '{honeypot_filled}');
INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, source, note, at)
SELECT id, NULL, 'lead_created', 'system', 'Enquiry received', created_at FROM public.ads_lead;
