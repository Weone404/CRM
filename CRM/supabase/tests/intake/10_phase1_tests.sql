-- Phase 1 tests. Each check prints PASS/FAIL; the last line prints the totals.
CREATE TEMP TABLE r (n serial, name text, ok boolean, info text);
CREATE FUNCTION pg_temp.ok(p_name text, p_ok boolean, p_info text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO r (name, ok, info) VALUES (p_name, coalesce(p_ok, false), p_info);
  RAISE NOTICE '%', CASE WHEN coalesce(p_ok, false) THEN 'PASS ' ELSE 'FAIL ' END || p_name || coalesce(' -- ' || p_info, ''); END $$;
-- Run an expression as a logged-in user (role authenticated). Returns {"state": SQLSTATE or "", "v": value}.
CREATE FUNCTION pg_temp.as_user(p_uid uuid, p_expr text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb; st text := '';
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  SET LOCAL ROLE authenticated;
  BEGIN EXECUTE 'SELECT to_jsonb((' || p_expr || '))' INTO v; EXCEPTION WHEN others THEN st := SQLSTATE; v := to_jsonb(SQLERRM); END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN jsonb_build_object('state', st, 'v', v);
END $$;
CREATE FUNCTION pg_temp.as_role(p_role text, p_expr text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_role);
  BEGIN EXECUTE p_expr; EXCEPTION WHEN others THEN st := SQLSTATE; END;
  RESET ROLE; RETURN st;
END $$;
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN ''; EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;

-- People: admin, two counsellors, a viewer, an outsider (no ADS access)
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-0000000000c2'), ('00000000-0000-0000-0000-0000000000b1'), ('00000000-0000-0000-0000-0000000000d1');
INSERT INTO public.employee (id, name, phone, password_hash, department, login_id, auth_user_id) VALUES
  ('10000000-0000-0000-0000-0000000000a1', 'Admin', '1', 'x', 'Admin', 'adm', '00000000-0000-0000-0000-0000000000a1'),
  ('10000000-0000-0000-0000-0000000000c1', 'Counsellor One', '2', 'x', 'Sales', 'c1', '00000000-0000-0000-0000-0000000000c1'),
  ('10000000-0000-0000-0000-0000000000c2', 'Counsellor Two', '3', 'x', 'Sales', 'c2', '00000000-0000-0000-0000-0000000000c2'),
  ('10000000-0000-0000-0000-0000000000b1', 'Viewer', '4', 'x', 'Sales', 'v1', '00000000-0000-0000-0000-0000000000b1'),
  ('10000000-0000-0000-0000-0000000000d1', 'Outsider', '5', 'x', 'Sales', 'o1', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO public.ads_access (employee_id, role) VALUES ('10000000-0000-0000-0000-0000000000c1', 'counsellor'),
  ('10000000-0000-0000-0000-0000000000c2', 'counsellor'), ('10000000-0000-0000-0000-0000000000b1', 'viewer');
-- Existing organic data, like production
INSERT INTO public.lead (id, name, phone, dedup_key, utm_source, segment) VALUES
  ('20000000-0000-0000-0000-000000000001', 'Organic Asha', '+919811100001', '+919811100001', 'website', 'aviation');
INSERT INTO public.student (id, first_name, last_name, mobile, mobile_normalized) VALUES
  ('30000000-0000-0000-0000-000000000001', 'Asha', NULL, '9811100001', '+919811100001'),
  ('30000000-0000-0000-0000-000000000002', 'Ravi', 'Kumar', '9822200002', '+919822200002');

DO $$
DECLARE a uuid := '00000000-0000-0000-0000-0000000000a1'; c1 uuid := '00000000-0000-0000-0000-0000000000c1';
  c2 uuid := '00000000-0000-0000-0000-0000000000c2'; vw uuid := '00000000-0000-0000-0000-0000000000b1';
  outsider uuid := '00000000-0000-0000-0000-0000000000d1';
  e1 uuid := '10000000-0000-0000-0000-0000000000c1'; e2 uuid := '10000000-0000-0000-0000-0000000000c2';
  res jsonb; res2 jsonb; n int; lid uuid; lid2 uuid; x record; j jsonb; t text;
  before_lead jsonb;
BEGIN
  -- ---------------------------------------------------------------- B. normalisation
  PERFORM pg_temp.ok('B01 phone 10-digit mobile', crm_private.ads_phone_e164('98765 43210') = '+919876543210');
  PERFORM pg_temp.ok('B02 phone with 0 prefix', crm_private.ads_phone_e164('09876543210') = '+919876543210');
  PERFORM pg_temp.ok('B03 phone +91 spaced', crm_private.ads_phone_e164('+91 98765-43210') = '+919876543210');
  PERFORM pg_temp.ok('B04 phone 91 prefix no plus', crm_private.ads_phone_e164('919876543210') = '+919876543210');
  PERFORM pg_temp.ok('B05 phone 0091 prefix', crm_private.ads_phone_e164('0091 9876543210') = '+919876543210');
  PERFORM pg_temp.ok('B06 international kept', crm_private.ads_phone_e164('+1 415 555 0123') = '+14155550123');
  PERFORM pg_temp.ok('B07 too short rejected', crm_private.ads_phone_e164('12345') IS NULL);
  PERFORM pg_temp.ok('B08 letters rejected', crm_private.ads_phone_e164('98765abc10') IS NULL);
  PERFORM pg_temp.ok('B09 landline STD', crm_private.ads_phone_e164('011-23456789') = '+911123456789'
                     AND crm_private.ads_phone_kind('+911123456789') = 'in_landline' AND crm_private.ads_phone_kind('+919876543210') = 'in_mobile');
  PERFORM pg_temp.ok('B10 email lower+trim', crm_private.ads_email_norm('  Asha.K@Example.COM ') = 'asha.k@example.com');
  PERFORM pg_temp.ok('B11 bad email -> NULL', crm_private.ads_email_norm('asha@') IS NULL AND crm_private.ads_email_norm('a b@x.com') IS NULL);

  -- ---------------------------------------------------------------- nothing outside ADS changes
  before_lead := (SELECT to_jsonb(l) FROM public.lead l WHERE id = '20000000-0000-0000-0000-000000000001');
  res := public.svc_ads_ingest_enquiry('{"name":"Neha","phone":"9811100002","utm_source":"website","submission_id":"s-org-1"}', 'pilot_training');
  PERFORM pg_temp.ok('O01 non-ad enquiry refused by ADS intake', res = '{"error": "not_an_ad_enquiry"}'::jsonb, res::text);
  PERFORM pg_temp.ok('O02 refused enquiry stores nothing anywhere', NOT EXISTS (SELECT 1 FROM public.ads_enquiry) AND NOT EXISTS (SELECT 1 FROM public.ads_lead)
     AND (SELECT count(*) FROM public.lead) = 1);
  res := public.svc_ads_ingest_enquiry('{"name":"Fbp","phone":"9811100003","fbp":"fb.1.1.1"}', 'pilot_training');
  PERFORM pg_temp.ok('O03 _fbp alone is not an ad enquiry', res->>'error' = 'not_an_ad_enquiry');
  res := public.svc_ads_ingest_enquiry('{"name":"X","phone":"9811100003","gclid":"G"}', 'other');
  PERFORM pg_temp.ok('O04 unknown pipeline refused', res->>'error' = 'unknown_pipeline');
  -- organic intake still works exactly as before, and ADS never sees it
  res := public.svc_ingest_website_lead('{"name":"Org","phone":"9811100010","gclid":"G-org"}');
  PERFORM pg_temp.ok('O05 organic intake untouched (even with a click ID it creates an organic lead)', res->>'status' = 'created');
  PERFORM pg_temp.ok('O06 organic intake writes nothing into ADS', EXISTS (SELECT 1 FROM public.lead WHERE dedup_key = '+919811100010')
     AND NOT EXISTS (SELECT 1 FROM public.ads_enquiry) AND NOT EXISTS (SELECT 1 FROM public.ads_lead));
  res := public.svc_ingest_charter_lead('{"name":"Jet","phone":"9811100004","from":"Delhi","to":"Goa","departureDate":"2027-01-10","passengers":4}');
  PERFORM pg_temp.ok('O07 organic charter intake untouched', res->>'status' = 'created' AND res->>'reference' LIKE 'BMC-%');

  -- ---------------------------------------------------------------- idempotency
  res := public.svc_ads_ingest_enquiry('{"name":"Idem","phone":"9811100005","gclid":"G-1","submission_id":"same-1"}', 'pilot_training');
  res2 := public.svc_ads_ingest_enquiry('{"name":"Idem","phone":"9811100005","gclid":"G-1","submission_id":"same-1"}', 'pilot_training');
  PERFORM pg_temp.ok('I01 same submission_id -> same answer', res = res2);
  PERFORM pg_temp.ok('I02 same submission_id -> one enquiry', (SELECT count(*) FROM public.ads_enquiry WHERE idempotency_key = 'sub:same-1') = 1
     AND (SELECT enquiry_count FROM public.ads_lead WHERE id = (res->>'lead_id')::uuid) = 1);
  res := public.svc_ads_ingest_enquiry('{"name":"Dbl","phone":"9811100006","gclid":"G-2"}', 'pilot_training');
  res2 := public.svc_ads_ingest_enquiry('{"name":"Dbl","phone":"9811100006","gclid":"G-2"}', 'pilot_training');
  PERFORM pg_temp.ok('I03 double-click without id -> one enquiry', res = res2 AND (SELECT count(*) FROM public.ads_enquiry WHERE phone_e164 = '+919811100006') = 1);

  -- ---------------------------------------------------------------- C. ads routing + attribution
  res := public.svc_ads_ingest_enquiry('{"name":"Ads Ravi","phone":"98222 00002","email":"Ravi@Example.com","course_interest":"CPL",
     "gclid":"Cj0-first","utm_source":"google","utm_medium":"cpc","utm_campaign":"cpl-delhi","landing_page":"https://weoneaviation.in/cpl?gclid=Cj0-first",
     "referrer":"https://www.google.com/","page_url":"https://weoneaviation.in/cpl","submission_id":"ads-1",
     "consent":{"notice_version":"privacy-2026-11","marketing":true,"ad_data_sharing":false}}', 'pilot_training');
  lid := (res->>'lead_id')::uuid;
  PERFORM pg_temp.ok('C01 click ID -> Ads lead, not organic', res->>'status' = 'created' AND EXISTS (SELECT 1 FROM public.ads_lead WHERE id = lid)
     AND NOT EXISTS (SELECT 1 FROM public.lead WHERE dedup_key = '+919822200002'));
  SELECT * INTO x FROM public.ads_lead WHERE id = lid;
  PERFORM pg_temp.ok('C02 normalised contact stored', x.phone_e164 = '+919822200002' AND x.email = 'ravi@example.com' AND x.pipeline = 'pilot_training');
  PERFORM pg_temp.ok('C03 attribution persisted', x.first_touch->>'gclid' = 'Cj0-first' AND x.first_touch->>'utm_campaign' = 'cpl-delhi'
     AND x.first_touch->>'site' = 'weoneaviation.in' AND x.first_touch ? 'landing_page' AND x.first_touch ? 'referrer', x.first_touch::text);
  PERFORM pg_temp.ok('C04 stage history starts at Lead Created', (SELECT count(*) FROM public.ads_lead_stage_event WHERE lead_id = lid AND to_stage = 'lead_created' AND source = 'system') = 1);
  -- second visit: direct (no source), then a Meta click
  PERFORM public.svc_ads_ingest_enquiry('{"name":"Ads Ravi","phone":"+919822200002","gclid":"Cj0-first","page_url":"https://weoneaviation.in/apply","referrer":"https://weoneaviation.in/cpl","submission_id":"ads-2"}', 'pilot_training');
  SELECT * INTO x FROM public.ads_lead WHERE id = lid;
  PERFORM pg_temp.ok('C05 repeat by other format -> same Ads lead', x.enquiry_count = 2);
  PERFORM pg_temp.ok('C06 first touch never overwritten', x.first_touch->>'utm_campaign' = 'cpl-delhi');
  PERFORM pg_temp.ok('C07 stored click ID on a later visit still counts as non-direct', x.last_non_direct->>'page_url' = 'https://weoneaviation.in/apply');
  PERFORM public.svc_ads_ingest_enquiry('{"name":"Ads Ravi","phone":"9822200002","referrer":"https://weoneaviation.in/","page_url":"https://weoneaviation.in/contact","utm_medium":"paid_social","submission_id":"ads-3"}', 'pilot_training');
  PERFORM public.svc_ads_ingest_enquiry('{"name":"Ads Ravi","phone":"9822200002","fbclid":"IwAR-x","fbc":"fb.1.1700000000.IwAR-x","fbp":"fb.1.1.2","utm_source":"facebook","utm_medium":"paid_social","submission_id":"ads-4"}', 'pilot_training');
  SELECT * INTO x FROM public.ads_lead WHERE id = lid;
  PERFORM pg_temp.ok('C08 last non-direct = latest paid touch', x.last_non_direct->>'fbclid' = 'IwAR-x' AND x.last_non_direct->>'fbc' LIKE 'fb.1.%' AND x.last_non_direct->>'fbp' = 'fb.1.1.2');
  -- direct visit with only own-site referrer and no IDs is organic routing; with stored gclid it stays ads.
  PERFORM pg_temp.ok('C09 own-site referrer is not a source', NOT crm_private.ads_touch_is_non_direct('{"referrer":"https://www.weoneaviation.in/x"}')
     AND crm_private.ads_touch_is_non_direct('{"referrer":"https://www.google.com/"}'));
  PERFORM pg_temp.ok('C10 every visit kept as its own enquiry', (SELECT count(*) FROM public.ads_enquiry WHERE ads_lead_id = lid) = 4);
  res := public.svc_ads_ingest_enquiry('{"name":"Wb","phone":"9811100007","wbraid":"WB1","submission_id":"wb"}', 'pilot_training');
  res2 := public.svc_ads_ingest_enquiry('{"name":"Gb","phone":"9811100008","gbraid":"GB1","submission_id":"gb"}', 'pilot_training');
  PERFORM pg_temp.ok('C11 gbraid / wbraid route to Ads', res->>'status' = 'created' AND res2->>'status' = 'created'
     AND (SELECT first_touch->>'wbraid' FROM public.ads_lead WHERE id = (res->>'lead_id')::uuid) = 'WB1');
  res := public.svc_ads_ingest_enquiry('{"name":"Ft","phone":"9811100009","gclid":"G-ft","first_touch":{"utm_source":"google","utm_medium":"cpc","gclid":"G-old","at":"2026-10-01T10:00:00Z"},"submission_id":"ft"}', 'pilot_training');
  PERFORM pg_temp.ok('C12 site-reported first touch used as first touch', (SELECT first_touch->>'gclid' FROM public.ads_lead WHERE id = (res->>'lead_id')::uuid) = 'G-old');

  -- ---------------------------------------------------------------- overlap with organic + duplicates
  res := public.svc_ads_ingest_enquiry('{"name":"Asha via ad","phone":"9811100001","gclid":"G-asha","submission_id":"ov"}', 'pilot_training');
  PERFORM pg_temp.ok('D01 known organic person -> new Ads lead linked', (SELECT organic_lead_id FROM public.ads_lead WHERE id = (res->>'lead_id')::uuid) = '20000000-0000-0000-0000-000000000001');
  PERFORM pg_temp.ok('D02 organic record not moved or changed', (SELECT to_jsonb(l) FROM public.lead l WHERE id = '20000000-0000-0000-0000-000000000001') = before_lead);
  res := public.svc_ads_ingest_enquiry('{"name":"Other Ravi","phone":"9833300003","email":"ravi@example.com","gclid":"G-3","submission_id":"pd"}', 'pilot_training');
  PERFORM pg_temp.ok('D03 same email, other phone -> probable duplicate, not merged',
     (SELECT dedup_result = 'probable_duplicate' AND probable_duplicate_of = lid FROM public.ads_enquiry WHERE idempotency_key = 'sub:pd')
     AND (res->>'lead_id')::uuid <> lid);
  res := public.svc_ads_ingest_enquiry('{"name":"Ravi Charter","phone":"9822200002","from":"Delhi","to":"Dehradun","departureDate":"2027-02-01","passengers":2,"gclid":"G-ch","submission_id":"ch-1"}', 'charter');
  lid2 := (res->>'lead_id')::uuid;
  PERFORM pg_temp.ok('H01 same phone in Charter -> separate Charter lead', (SELECT pipeline FROM public.ads_lead WHERE id = lid2) = 'charter' AND lid2 <> lid
     AND res->>'reference' LIKE 'BMC-%');
  res := public.svc_ads_ingest_enquiry('{"name":"Ravi Charter","phone":"9822200099","gclid":"G-ch2","submission_id":"ch-2"}', 'charter');
  PERFORM pg_temp.ok('H02 ads charter keeps charter validation answer', res ? 'errors_json' AND res->>'errors_json' LIKE '%departureDate%', res::text);

  -- ---------------------------------------------------------------- spam / quarantine
  res := public.svc_ads_ingest_enquiry('{"name":"Bot","phone":"9844400004","gclid":"G-bot","hp":"http://spam","submission_id":"sp1"}', 'pilot_training');
  PERFORM pg_temp.ok('S01 honeypot -> quarantined, not deleted', (SELECT quarantined AND 'honeypot_filled' = ANY (quarantine_reasons) FROM public.ads_lead WHERE id = (res->>'lead_id')::uuid));
  res := public.svc_ads_ingest_enquiry('{"name":"Fast","phone":"9844400005","gclid":"G-f","elapsed_ms":800,"email":"x@mailinator.com","submission_id":"sp2"}', 'pilot_training');
  PERFORM pg_temp.ok('S02 too fast + disposable email -> suspect', (SELECT quality = 'suspect' AND quality_reasons @> ARRAY['submitted_too_fast', 'disposable_email'] FROM public.ads_enquiry WHERE idempotency_key = 'sub:sp2'));
  res := public.svc_ads_ingest_enquiry('{"name":"NoPhone","phone":"12","gclid":"G-np","submission_id":"sp3"}', 'pilot_training');
  PERFORM pg_temp.ok('S03 ads enquiry with bad phone: error, stored, no lead', res = '{"error": "A valid phone number is required"}'::jsonb
     AND EXISTS (SELECT 1 FROM public.ads_enquiry WHERE idempotency_key = 'sub:sp3' AND dedup_result = 'rejected' AND ads_lead_id IS NULL));
  FOR n IN 1..6 LOOP PERFORM public.svc_ads_ingest_enquiry(jsonb_build_object('name', 'Flood', 'phone', '9855500005', 'gclid', 'G-fl', 'submission_id', 'fl' || n), 'pilot_training'); END LOOP;
  PERFORM pg_temp.ok('S04 flood from one number flagged', (SELECT 'too_many_enquiries_1h' = ANY (quality_reasons) FROM public.ads_enquiry WHERE idempotency_key = 'sub:fl6'));

  -- ---------------------------------------------------------------- D. consent
  PERFORM pg_temp.ok('K01 enquiry_response granted by submitting', crm_private.ads_consent_status('+919822200002', NULL, 'enquiry_response') = 'granted');
  PERFORM pg_temp.ok('K02 optional marketing recorded separately', crm_private.ads_consent_status('+919822200002', NULL, 'marketing') = 'granted');
  PERFORM pg_temp.ok('K03 ad sharing explicitly refused', crm_private.ads_consent_status('+919822200002', NULL, 'ad_data_sharing') = 'denied'
     AND NOT crm_private.ads_consent_allows('+919822200002', NULL, 'ad_data_sharing'));
  PERFORM pg_temp.ok('K04 nothing assumed when not asked', crm_private.ads_consent_status('+919811100006', NULL, 'ad_data_sharing') = 'none');
  PERFORM pg_temp.ok('K05 notice version + source stored', EXISTS (SELECT 1 FROM public.ads_consent_event WHERE subject_phone = '+919822200002'
     AND notice_version = 'privacy-2026-11' AND source = 'web_form' AND enquiry_id IS NOT NULL));
  j := pg_temp.as_user(c1, $q$public.api_ads_consent_record('9822200002', NULL, 'marketing', 'withdrawn', 'phone', 'privacy-2026-11', 'Asked to stop on call')$q$);
  PERFORM pg_temp.ok('K06 staff records withdrawal', j->>'state' = '' AND j->'v'->>'status' = 'withdrawn', j::text);
  PERFORM pg_temp.ok('K07 history kept after withdrawal', (SELECT count(*) FROM public.ads_consent_event WHERE subject_phone = '+919822200002' AND purpose = 'marketing') >= 2
     AND crm_private.ads_consent_status('+919822200002', NULL, 'marketing') = 'withdrawn');
  PERFORM pg_temp.ok('K08 consent history is append-only', pg_temp.err('UPDATE public.ads_consent_event SET status = ''granted''') = 'PT409'
     AND pg_temp.err('DELETE FROM public.ads_consent_event') = 'PT409');

  -- ---------------------------------------------------------------- F. stages, assignment, counsellor credit
  j := pg_temp.as_user(c1, format('public.api_ads_lead_assign(%L, %L, %L)', lid, e1, 'new lead'));
  PERFORM pg_temp.ok('F01 assign', j->>'state' = '', j::text);
  j := pg_temp.as_user(c1, format('public.api_ads_lead_log_contact(%L, ''phone'', ''connected'', ''Spoke to Ravi'')', lid));
  SELECT * INTO x FROM public.ads_lead WHERE id = lid;
  PERFORM pg_temp.ok('F02 connected call -> Contacted + contactable + response time', j->>'state' = '' AND x.stage = 'contacted'
     AND x.contact_status = 'contactable' AND x.first_response_at IS NOT NULL, j::text);
  j := pg_temp.as_user(c1, format('public.api_ads_lead_set_stage(%L, ''interested'', ''wants CPL'')', lid));
  PERFORM pg_temp.ok('F03 Interested', j->>'state' = '');
  j := pg_temp.as_user(c1, format('public.api_ads_lead_set_stage(%L, ''qualified'', ''looks good'')', lid));
  PERFORM pg_temp.ok('F04 Qualified refused without qualification answers', j->>'state' = 'PT400', j::text);
  -- reassign before qualification: c2 takes over and qualifies
  j := pg_temp.as_user(a, format('public.api_ads_lead_assign(%L, %L, %L)', lid, e2, 'c1 on leave'));
  j := pg_temp.as_user(c2, format('public.api_ads_lead_set_stage(%L, ''qualified'', ''checked'', %L::jsonb)', lid, '{"10+2_pcm":true,"age_ok":true,"start":"2027-01"}'));
  PERFORM pg_temp.ok('F05 Qualified with answers', j->>'state' = '', j::text);
  j := pg_temp.as_user(c2, format('public.api_ads_lead_set_stage(%L, ''booking_confirmed'')', lid));
  PERFORM pg_temp.ok('F06 Charter stage refused on Pilot lead', j->>'state' = 'PT400');
  j := pg_temp.as_user(c2, format('public.api_ads_lead_set_stage(%L, ''application_completed'')', lid));
  j := pg_temp.as_user(c2, format('public.api_ads_lead_set_stage(%L, ''admission_completed'')', lid));
  PERFORM pg_temp.ok('F07 Admission completed', j->>'state' = '' AND (SELECT stage FROM public.ads_lead WHERE id = lid) = 'admission_completed');
  j := pg_temp.as_user(c2, format('public.api_ads_lead_set_stage(%L, ''interested'', ''oops'')', lid));
  PERFORM pg_temp.ok('F08 only Admin can reopen a finished lead', j->>'state' = 'PT403');
  PERFORM pg_temp.ok('F09 every move recorded with from/to/who', (SELECT count(*) FROM public.ads_lead_stage_event WHERE lead_id = lid AND source = 'user'
     AND from_stage IS NOT NULL AND employee_id IS NOT NULL) = 5);
  PERFORM pg_temp.ok('F10 assignment history kept', (SELECT count(*) FROM public.ads_lead_assignment WHERE lead_id = lid) = 2
     AND (SELECT from_employee FROM public.ads_lead_assignment WHERE lead_id = lid ORDER BY id DESC LIMIT 1) = e1);
  j := pg_temp.as_user(a, format('public.api_ads_counsellor_credit(''pilot_training'', %L, %L)', current_date - 1, current_date));
  PERFORM pg_temp.ok('F11 credit follows who moved the lead, not last owner',
     (SELECT count(*) FROM jsonb_array_elements(j->'v') e WHERE (e->>'employee_id')::uuid = e1 AND e->>'to_stage' IN ('contacted', 'interested')) = 2
     AND (SELECT count(*) FROM jsonb_array_elements(j->'v') e WHERE (e->>'employee_id')::uuid = e2 AND e->>'to_stage' = 'qualified') = 1
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'v') e WHERE (e->>'employee_id')::uuid = e2 AND e->>'to_stage' = 'contacted'), j::text);
  PERFORM pg_temp.ok('F12 stage history append-only', pg_temp.err(format('UPDATE public.ads_lead_stage_event SET note = ''x'' WHERE lead_id = %L', lid)) = 'PT409'
     AND pg_temp.err('DELETE FROM public.ads_lead_stage_event') = 'PT409' AND pg_temp.err('DELETE FROM public.ads_lead_assignment') = 'PT409');
  PERFORM pg_temp.ok('F13 Ads leads cannot be hard-deleted', pg_temp.err(format('DELETE FROM public.ads_lead WHERE id = %L', lid)) = 'PT409');
  j := pg_temp.as_user(vw, format('public.api_ads_lead_set_stage(%L, ''lost'')', lid2));
  PERFORM pg_temp.ok('F14 viewer is read-only', j->>'state' = 'PT403');
  j := pg_temp.as_user(vw, $q$public.api_ads_lead_list('pilot_training')$q$);
  PERFORM pg_temp.ok('F15 viewer can list', j->>'state' = '' AND jsonb_array_length(j->'v') > 0);
  j := pg_temp.as_user(outsider, $q$public.api_ads_lead_list(NULL)$q$);
  PERFORM pg_temp.ok('F16 no ADS access -> refused', j->>'state' = 'PT403');
  SELECT id INTO lid2 FROM public.ads_lead WHERE quarantined LIMIT 1;
  j := pg_temp.as_user(c1, format('public.api_ads_lead_set_stage(%L, ''contacted'')', lid2));
  PERFORM pg_temp.ok('F17 quarantined lead must be released first', j->>'state' = 'PT409');
  j := pg_temp.as_user(c1, format('public.api_ads_lead_quarantine(%L, false, ''real person, called back'')', lid2));
  PERFORM pg_temp.ok('F18 release from quarantine is recorded', j->>'state' = '' AND EXISTS (SELECT 1 FROM public.ads_lead_stage_event WHERE lead_id = lid2 AND note LIKE 'Released:%'));
  j := pg_temp.as_user(c1, format('public.api_ads_lead(%L)', lid));
  PERFORM pg_temp.ok('F19 lead detail returns full history + consent', j->>'state' = '' AND jsonb_array_length(j->'v'->'stages') = 6
     AND j->'v'->'consent'->>'marketing' = 'withdrawn', j->>'state');

  -- ---------------------------------------------------------------- E. students
  j := pg_temp.as_user(c1, 'public.api_ads_student_links_propose()');
  PERFORM pg_temp.ok('E01 only Admin proposes links', j->>'state' = 'PT403');
  j := pg_temp.as_user(a, 'public.api_ads_student_links_propose()');
  PERFORM pg_temp.ok('E02 proposals from evidence', j->>'state' = '' AND (j->'v'->>'proposed')::int >= 2, j::text);
  PERFORM pg_temp.ok('E03 phone matches proposed for Ads leads only', EXISTS (SELECT 1 FROM public.ads_student_link WHERE student_id = '30000000-0000-0000-0000-000000000001'
     AND match_method = 'phone_exact' AND status = 'proposed')
     AND EXISTS (SELECT 1 FROM public.ads_student_link WHERE student_id = '30000000-0000-0000-0000-000000000002' AND lead_kind = 'ads' AND status = 'proposed'));
  PERFORM pg_temp.ok('E04 nothing auto-verified, student rows untouched', NOT EXISTS (SELECT 1 FROM public.ads_student_link WHERE status <> 'proposed')
     AND NOT EXISTS (SELECT 1 FROM public.student WHERE lead_id IS NOT NULL));
  SELECT id INTO n FROM public.ads_student_link WHERE student_id = '30000000-0000-0000-0000-000000000002';
  j := pg_temp.as_user(a, format('public.api_ads_student_link_decide(%s, true, NULL)', n));
  PERFORM pg_temp.ok('E05 verify needs a note of what was checked', j->>'state' = 'PT400');
  j := pg_temp.as_user(a, format('public.api_ads_student_link_decide(%s, true, ''Same mobile, same course, admission date after enquiry'')', n));
  PERFORM pg_temp.ok('E06 verified with who/when/evidence', j->>'state' = '' AND (SELECT decided_by IS NOT NULL AND decided_at IS NOT NULL AND evidence ? 'ads_phone'
     FROM public.ads_student_link WHERE id = n));
  PERFORM pg_temp.ok('E07 one verified link per student', pg_temp.err(format(
     'INSERT INTO public.ads_student_link (student_id, ads_lead_id, match_method, status, decided_by, decided_at) VALUES (%L, %L, ''manual'', ''verified'', %L, now())',
     '30000000-0000-0000-0000-000000000002', (SELECT id FROM public.ads_lead WHERE name = 'Asha via ad'), '10000000-0000-0000-0000-0000000000a1')) = '23505');
  j := pg_temp.as_user(a, 'public.api_ads_student_links_propose()');
  PERFORM pg_temp.ok('E08 re-proposing is idempotent', (j->'v'->>'proposed')::int = 0);

  -- ---------------------------------------------------------------- G. retention
  res := public.svc_ads_ingest_enquiry('{"name":"Old Lost","phone":"9866600006","gclid":"G-old","submission_id":"ret1"}', 'pilot_training');
  lid2 := (res->>'lead_id')::uuid;
  j := pg_temp.as_user(c1, format('public.api_ads_lead_set_stage(%L, ''lost'', ''not interested'')', lid2));
  UPDATE public.ads_lead SET last_interaction_at = now() - interval '13 months' WHERE id = lid2;
  j := pg_temp.as_user(a, 'public.api_ads_retention_run(true)');
  PERFORM pg_temp.ok('G01 dry run lists lost lead older than 12 months only', j->>'state' = '' AND (j->'v'->>'affected')::int = 1
     AND j->'v'->'ids'->>0 = lid2::text, j::text);
  j := pg_temp.as_user(a, 'public.api_ads_retention_run(false)');
  PERFORM pg_temp.ok('G02 real run refused until enabled + legally approved', j->>'state' = 'PT409');
  j := pg_temp.as_user(a, $q$public.api_ads_retention_policy_set('student_training_record', 60, true, 'approved')$q$);
  PERFORM pg_temp.ok('G03 student records can never be auto-deleted', j->>'state' = 'PT400');
  j := pg_temp.as_user(a, $q$public.api_ads_retention_policy_set('ads_lead_lost', 12, true, 'approved')$q$);
  j := pg_temp.as_user(a, 'public.api_ads_retention_run(false)');
  SELECT * INTO x FROM public.ads_lead WHERE id = lid2;
  PERFORM pg_temp.ok('G04 anonymised, row and history kept', j->>'state' = '' AND x.name = '[removed]' AND x.email IS NULL AND x.anonymised_at IS NOT NULL
     AND (SELECT count(*) FROM public.ads_lead_stage_event WHERE lead_id = lid2) = 2
     AND NOT EXISTS (SELECT 1 FROM public.ads_enquiry WHERE ads_lead_id = lid2 AND (phone_e164 IS NOT NULL OR name IS NOT NULL)), j::text);
  PERFORM pg_temp.ok('G05 active / customer leads untouched', (SELECT name FROM public.ads_lead WHERE id = lid) = 'Ads Ravi');
  PERFORM pg_temp.ok('G06 retention run logged', (SELECT count(*) FROM public.ads_retention_run) = 2);
  PERFORM pg_temp.ok('G07 append-only restored after run', pg_temp.err('UPDATE public.ads_enquiry SET name = ''x''') = 'PT409');

  -- ---------------------------------------------------------------- I. security
  PERFORM pg_temp.ok('X01 anon cannot read new tables', pg_temp.as_role('anon', 'SELECT 1 FROM public.ads_lead LIMIT 1') = '42501'
     AND pg_temp.as_role('anon', 'SELECT 1 FROM public.ads_enquiry LIMIT 1') = '42501');
  PERFORM pg_temp.ok('X02 logged-in users cannot read tables directly', pg_temp.as_role('authenticated', 'SELECT 1 FROM public.ads_consent_event LIMIT 1') = '42501'
     AND pg_temp.as_role('authenticated', 'SELECT 1 FROM public.ads_lead_stage_event LIMIT 1') = '42501');
  PERFORM pg_temp.ok('X03 intake not callable by browser roles', pg_temp.as_role('anon', $q$SELECT public.svc_ads_ingest_enquiry('{}', 'pilot_training')$q$) = '42501'
     AND pg_temp.as_role('authenticated', $q$SELECT public.svc_ads_ingest_enquiry('{}', 'pilot_training')$q$) = '42501');
  PERFORM pg_temp.ok('X04 anon cannot call ADS lead APIs', pg_temp.as_role('anon', 'SELECT public.api_ads_lead_list(NULL)') = '42501');
  PERFORM pg_temp.ok('X05 RLS on for every new table', (SELECT bool_and(relrowsecurity) FROM pg_class WHERE relname IN ('ads_site', 'ads_stage_def', 'ads_lead',
     'ads_enquiry', 'ads_lead_stage_event', 'ads_lead_assignment', 'ads_lead_contact', 'ads_consent_event', 'ads_student_link',
     'ads_retention_policy', 'ads_retention_run') AND relnamespace = 'public'::regnamespace));
  PERFORM pg_temp.ok('X07 ADS wrote nothing to lead / student / audit_log', (SELECT count(*) FROM public.lead) = 3
     AND NOT EXISTS (SELECT 1 FROM public.student WHERE lead_id IS NOT NULL OR updated_at > created_at)
     AND (SELECT count(*) FROM public.audit_log) = 2, (SELECT count(*) FROM public.lead)::text || ' leads, ' || (SELECT count(*) FROM public.audit_log)::text || ' audit rows');
  PERFORM pg_temp.ok('X06 Pilot and Charter stage lists separate', NOT EXISTS (SELECT 1 FROM public.ads_stage_def WHERE pipeline = 'charter' AND stage LIKE 'admission%')
     AND NOT EXISTS (SELECT 1 FROM public.ads_stage_def WHERE pipeline = 'pilot_training' AND stage LIKE 'booking%'));
END $$;

SELECT format('ALL PHASE1: %s passed, %s failed', count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok)) FROM r;
