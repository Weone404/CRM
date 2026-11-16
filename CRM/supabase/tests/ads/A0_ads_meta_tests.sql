-- 100: Meta lead sources. Settings (MS01-04), intake (MS05-09, MS20, MS22), reporting queue (MS10-19), safety (MS21, MS23-24).
-- Runs after 10_-90_ (uses pg_temp.ok / fails / as_ from 10_, the Meta campaign 555000111 from 80_).
RESET ROLE;
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
DELETE FROM public.ads_conversion_uploads;

-- A Meta lead form lead, filed the way ads-sync files it (raw row from the webhook, then svc_ads_meta_lead_finish).
CREATE OR REPLACE FUNCTION pg_temp.mpayload(p_lid text, p_phone text, p_consent text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('name', 'Meta ' || p_phone, 'phone', p_phone, 'submission_id', 'meta-lead-' || p_lid,
    'utm_source', 'facebook', 'utm_medium', 'paid_social', 'site', 'facebook.com',
    'first_touch', jsonb_build_object('utm_source', 'facebook', 'utm_medium', 'paid_social', 'meta_source', 'instant_form', 'leadgen_id', p_lid,
                                      'utm_campaignid', '555000111', 'form_id', '987654321'),
    'consent', CASE WHEN p_consent IS NULL THEN '{"notice_version": "meta_instant_form"}'::jsonb
                    ELSE jsonb_build_object('notice_version', 'meta_instant_form', 'ad_data_sharing', p_consent::boolean) END) $$;
CREATE OR REPLACE FUNCTION pg_temp.raw(p_source text, p_id text, p_payload jsonb DEFAULT NULL) RETURNS int LANGUAGE sql SECURITY DEFINER AS $$
  SELECT public.svc_ads_meta_raw_add(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('source', p_source, 'external_id', p_id,
    'page_id', '111222333444', 'form_id', '987654321', 'ad_id', '666', 'created_time', 1794800000, 'payload', p_payload))), 'webhook') $$;
CREATE OR REPLACE FUNCTION pg_temp.rawid(p_source text, p_id text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.ads_meta_lead_raw WHERE source = p_source AND external_id = p_id $$;
CREATE OR REPLACE FUNCTION pg_temp.file(p_lid text, p_phone text, p_consent text DEFAULT NULL, p_age interval DEFAULT '2 hours') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r jsonb; l uuid;
BEGIN
  PERFORM pg_temp.raw('instant_form', p_lid);
  r := public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', p_lid), 'fetched', pg_temp.mpayload(p_lid, p_phone, p_consent), 'pilot_training');
  l := (r->>'lead_id')::uuid;
  UPDATE public.ads_lead SET created_at = now() - p_age WHERE id = l;
  PERFORM pg_temp.age_events(l, p_age);
  RETURN l;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.age_events(p_lead uuid, p_age interval) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);   -- test setup only: bypass the append-only trigger
  UPDATE public.ads_lead_stage_event SET at = now() - p_age WHERE lead_id = p_lead;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;
CREATE OR REPLACE FUNCTION pg_temp.stage(p_lead uuid, p_stage text, p_age interval DEFAULT '1 hour') RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.ads_lead_stage_event (lead_id, from_stage, to_stage, source, at) VALUES (p_lead, NULL, p_stage, 'user', now() - p_age);
  UPDATE public.ads_lead SET stage = p_stage WHERE id = p_lead $$;
CREATE OR REPLACE FUNCTION pg_temp.mq() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_meta_capi_queue() $$;
CREATE OR REPLACE FUNCTION pg_temp.mw() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$ SELECT public.svc_ads_meta_capi_work() $$;
CREATE OR REPLACE FUNCTION pg_temp.ups(p_lead uuid) RETURNS SETOF public.ads_meta_capi_uploads LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.ads_meta_capi_uploads WHERE lead_id = p_lead ORDER BY id $$;
CREATE OR REPLACE FUNCTION pg_temp.src(p_source text, p_data jsonb) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  UPDATE public.ads_meta_settings SET intake_enabled = coalesce((p_data->>'intake_enabled')::boolean, intake_enabled),
    report_enabled = coalesce((p_data->>'report_enabled')::boolean, report_enabled), consent_mode = coalesce(p_data->>'consent_mode', consent_mode),
    dataset_id = coalesce(p_data->>'dataset_id', dataset_id) WHERE source = p_source $$;
CREATE OR REPLACE FUNCTION pg_temp.cfg(k text, v text) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$ UPDATE public.ads_config SET value = v WHERE key = k $$;
CREATE OR REPLACE FUNCTION pg_temp.wake() RETURNS boolean LANGUAGE sql SECURITY DEFINER AS $$ SELECT crm_private.ads_meta_wake() $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- ================================================================ MS01-04 settings
SELECT pg_temp.ok((SELECT bool_and(NOT intake_enabled AND NOT report_enabled AND consent_mode = 'required') FROM public.ads_meta_settings)
  AND (SELECT count(*) FROM public.ads_meta_settings) = 3, 'MS01 all three Meta sources start switched off, consent required');
SELECT pg_temp.ok(pg_temp.raw('instant_form', '1000000000000001') = 0 AND pg_temp.rawid('instant_form', '1000000000000001') IS NULL,
  'MS01b while a source is off, a webhook call stores nothing');

SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails('SELECT public.api_ads_meta_settings()', '%Only Admin%', 'MS02 a viewer cannot open the Meta settings');
SELECT pg_temp.as_('d');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_source_save('instant_form', '{"intake_enabled": true}')$q$, '%Only Admin%', 'MS02b an approver who is not Admin cannot change them');

SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_source_save('instant_form', '{"report_enabled": true}')$q$, '%dataset ID%',
  'MS03 reporting cannot be switched on without a dataset ID');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_source_save('instant_form', '{"dataset_id": "pixel-12"}')$q$, '%digits only%', 'MS03b a dataset ID that is not digits is refused');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_source_save('instant_form', '{"consent_mode": "sometimes"}')$q$, '%Consent rule%', 'MS03c an unknown consent rule is refused');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_source_save('nope', '{}')$q$, '%Unknown lead source%', 'MS03d an unknown source is refused');
SELECT public.api_ads_meta_source_save('instant_form', '{"intake_enabled": true, "dataset_id": "1122334455", "report_enabled": true}');
SELECT pg_temp.ok((public.api_ads_meta_settings()->'sources'->0->>'report_enabled')::boolean AND public.api_ads_meta_settings()->'sources'->0->>'source' = 'instant_form',
  'MS03e Admin switches lead forms on, with a dataset ID');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.api_ads_activity(50) e WHERE e::text LIKE '%meta_source_saved%'), 'MS03f the change is in the ADS activity log');

SELECT pg_temp.fails($q$SELECT public.api_ads_meta_event_map_save('website', 'pilot_training', 'admission_completed', 'Purchase', true)$q$, '%Website events%',
  'MS04 a website stage cannot be sent as Purchase (it needs a value)');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_event_map_save('ctwa', 'pilot_training', 'lead_created', 'Lead', true)$q$, '%WhatsApp events%',
  'MS04b a WhatsApp stage only accepts LeadSubmitted / QualifiedLead');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_event_map_save('instant_form', 'pilot_training', 'qualified', '<b>x', true)$q$, '%Event name%',
  'MS04c a CRM event name with odd characters is refused');
SELECT pg_temp.ok((public.api_ads_meta_event_map_save('instant_form', 'pilot_training', 'qualified', 'Qualified Lead', true)->>'saved')::boolean
  AND (public.api_ads_meta_event_map_save('website', 'pilot_training', 'qualified', 'Schedule', false)->>'saved')::boolean,
  'MS04d free text is fine for CRM events; a website stage can be renamed and switched off');
RESET ROLE;
SELECT pg_temp.fails($q$INSERT INTO public.ads_meta_event_map VALUES ('ctwa', 'charter', 'lead_created', 'Purchase', true) ON CONFLICT (source, pipeline, stage) DO UPDATE SET meta_event_name = 'Purchase'$q$,
  '%ads_meta_event_map_name_check%', 'MS04e the database itself refuses a non-listed WhatsApp event name');

-- ================================================================ MS05-09 intake (run as the database owner; MS21e checks the service role can call them)
RESET ROLE;
SELECT pg_temp.ok(pg_temp.raw('instant_form', '1000000000000001') = 1, 'MS05 a leadgen webhook stores the lead id');
SELECT pg_temp.ok(pg_temp.raw('instant_form', '1000000000000001') = 0
  AND (SELECT count(*) FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000001') = 1,
  'MS05b the same lead delivered again (Meta retries for 36 hours) is stored once');
SELECT pg_temp.ok(public.svc_ads_meta_raw_add('[{"source": "instant_form", "external_id": "12ab"}, {"source": "other", "external_id": "1000000000000009"}, 5, null]') = 0,
  'MS05c malformed ids and unknown sources are ignored');
SELECT pg_temp.ok(pg_temp.raw('ctwa', 'ARAkLkA8rmlFeiCktEJQ', '{"phone": "919811300001"}') = 0, 'MS05d WhatsApp leads are ignored while that source is off');
SELECT pg_temp.ok(nullif(crm_private.ads_cfg('meta_webhook_last_at'), '')::timestamptz > now() - interval '1 minute', 'MS05e the time of the last webhook call is recorded');
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_meta_leads_work()->'items') = 1 AND public.svc_ads_meta_leads_work()->'items'->0->>'pipeline' = 'pilot_training',
  'MS05f the stored lead is handed to ads-sync, with its pipeline');

SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000001'), 'fetched',
  pg_temp.mpayload('1000000000000001', '9811300001', 'true'), 'pilot_training')->>'status') = 'created', 'MS06 the fetched lead is filed through the ADS intake');
SELECT pg_temp.ok((SELECT r.status = 'ingested' AND r.lead_id = l.id AND l.first_touch->>'meta_source' = 'instant_form' AND l.phone_e164 = '+919811300001'
    FROM public.ads_meta_lead_raw r JOIN public.ads_lead l ON l.id = r.lead_id WHERE r.external_id = '1000000000000001'),
  'MS06b it is an Ads lead marked as a Meta lead form, and the raw row points to it');
SELECT pg_temp.ok((SELECT x.platform = 'meta' AND x.campaign_id IS NOT NULL FROM crm_private.ads_ad_leads() x JOIN public.ads_meta_lead_raw r ON r.lead_id = x.lead_id
    WHERE r.external_id = '1000000000000001'), 'MS06c ADS counts it as a Meta lead on campaign 555000111');
SELECT pg_temp.ok((SELECT count(*) FROM public.ads_lead_stage_event e JOIN public.ads_meta_lead_raw r ON r.lead_id = e.lead_id
    WHERE r.external_id = '1000000000000001' AND e.to_stage = 'lead_created') = 1, 'MS06d its first stage (Lead Created) is recorded');
SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000001'), 'fetched', pg_temp.mpayload('1000000000000001', '9811300001'), 'pilot_training')->>'skipped')::boolean,
  'MS06e a lead already filed cannot be filed twice');

SELECT pg_temp.raw('instant_form', '1000000000000002');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000002'), 'organic');
SELECT pg_temp.ok((SELECT status FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000002') = 'organic'
  AND NOT EXISTS (SELECT 1 FROM public.ads_lead WHERE phone_e164 LIKE '%1000000000000002%'), 'MS07 a form filled without an ad (organic) is not made an Ads lead');

SELECT pg_temp.raw('instant_form', '1000000000000003');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000003'), 'retry', NULL, NULL, 'Meta is busy') FROM generate_series(1, 11);
UPDATE public.ads_meta_lead_raw SET last_try_at = NULL WHERE external_id = '1000000000000003';
SELECT pg_temp.ok((SELECT status = 'pending' AND attempts = 11 FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000003'), 'MS08 a lead Meta could not give yet is tried again');
SELECT public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000003'), 'retry', NULL, NULL, 'Meta is busy');
SELECT pg_temp.ok((SELECT status = 'failed' AND error = 'Meta is busy' FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000003'),
  'MS08b after 12 tries it stops, with the reason shown');

SELECT pg_temp.raw('instant_form', '1000000000000004');
SELECT pg_temp.ok(public.svc_ads_meta_lead_finish(pg_temp.rawid('instant_form', '1000000000000004'), 'fetched', pg_temp.mpayload('1000000000000004', 'not a phone'), 'pilot_training') ? 'error',
  'MS09 a lead the ADS intake refuses (no valid phone) gets the intake''s answer');
SELECT pg_temp.ok((SELECT status = 'failed' AND error LIKE '%phone%' FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000004'),
  'MS09b ... and is marked failed with the intake''s reason');

-- ================================================================ MS10-19 reporting queue
RESET ROLE;
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE first_touch->>'leadgen_id' = '1000000000000001';
SELECT pg_temp.age_events((SELECT lead_id FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000001'), '2 hours');
CREATE TEMP TABLE ml (k text PRIMARY KEY, v uuid);
GRANT ALL ON ml TO authenticated, service_role;
INSERT INTO ml SELECT 'yes', lead_id FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000001';
INSERT INTO ml VALUES ('none', pg_temp.file('1000000000000011', '9811300011')), ('no', pg_temp.file('1000000000000012', '9811300012', 'false')),
  ('fresh', pg_temp.file('1000000000000013', '9811300013', 'true', '5 minutes')), ('old', pg_temp.file('1000000000000014', '9811300014', 'true', '8 days'));

SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes'))) = 1
  AND (SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'none'))) = 0 AND (SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'no'))) = 0,
  'MS10 consent "required": only the person who said yes on the form is reported');
SELECT pg_temp.src('instant_form', '{"consent_mode": "required_if_collected"}'); SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'none'))) = 1 AND (SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'no'))) = 0,
  'MS10b "required if collected": a form that did not ask is reported, a "no" never is');
SELECT pg_temp.src('instant_form', '{"consent_mode": "not_required"}'); SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'no'))) = 1, 'MS10c "not required": everyone is reported');
SELECT pg_temp.src('instant_form', '{"consent_mode": "required"}');
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'fresh'))) = 0, 'MS11 a lead under 30 minutes old waits (spam checks first)');

SELECT pg_temp.stage((SELECT v FROM ml WHERE k = 'yes'), 'contacted'); SELECT pg_temp.stage((SELECT v FROM ml WHERE k = 'yes'), 'qualified', '30 minutes');
SELECT pg_temp.mq(); SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT count(*) = 3 AND count(DISTINCT stage) = 3 FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')))
  AND (SELECT meta_event_name FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) WHERE stage = 'qualified') = 'Qualified Lead',
  'MS12 each stage the lead reaches is queued once, under the event name set in the dashboard');
SELECT pg_temp.ok((SELECT bool_and(status = 'skipped' AND error LIKE '%7 days%') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'old')))
  AND (SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'old'))) = 1, 'MS13 a stage reached more than 7 days ago is skipped, with the reason');

SELECT pg_temp.ok((SELECT bool_and(i->>'source' = 'instant_form' AND i->>'lead_id' ~ '^1000000000000\d{3}$' AND (i->>'event_time')::bigint < extract(epoch FROM now()))
                    FROM jsonb_array_elements(pg_temp.mw()->'items') i)
  AND (SELECT count(*) FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' LIKE '%:lead_created') >= 1
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' LIKE (SELECT v FROM ml WHERE k = 'old')::text || '%')
  AND pg_temp.mw()->>'crm_name' = 'We One CRM' AND pg_temp.mw()->'datasets'->>'instant_form' = '1122334455',
  'MS14 the reporter gets each event with the Meta lead id, time in seconds, the CRM name and the dataset; skipped ones are not sent');
SELECT pg_temp.ok((SELECT i->>'ph' FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' LIKE (SELECT v FROM ml WHERE k = 'yes')::text || '%' LIMIT 1)
    = encode(sha256(convert_to('919811300001', 'UTF8')), 'hex')
  AND crm_private.ads_sha256('919811200001') = 'f77667a8777bcb65d8ffb30434830d854552d739e2b840b28fa78d7a6c428a02'
  AND pg_temp.mw()::text NOT LIKE '%9811300001"%' AND pg_temp.mw()::text NOT LIKE '%+91%',
  'MS14b the phone leaves only as a SHA-256 hash (digits with country code, the same hash as the code test MC08)');

SELECT pg_temp.cfg('execution_paused', 'true');
SELECT pg_temp.ok(pg_temp.mq() = 0 AND (pg_temp.mw()->>'paused')::boolean AND jsonb_array_length(pg_temp.mw()->'items') = 0,
  'MS15 emergency stop: nothing is queued or handed out for sending');
SELECT pg_temp.cfg('execution_paused', 'false');

SELECT pg_temp.src('instant_form', '{"report_enabled": false}');
SELECT pg_temp.stage((SELECT v FROM ml WHERE k = 'yes'), 'application_completed', '20 minutes'); SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes'))) = 3 AND jsonb_array_length(pg_temp.mw()->'items') = 0,
  'MS16 reporting switched off for the source: nothing new is queued and nothing waiting is sent');
SELECT pg_temp.src('instant_form', '{"report_enabled": true}');

SELECT public.svc_ads_meta_capi_finish(u.id, 'sent') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) u WHERE u.stage = 'lead_created';
SELECT public.svc_ads_meta_capi_finish(u.id, 'retry', 'later') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) u, generate_series(1, 11) WHERE u.stage = 'contacted';
SELECT public.svc_ads_meta_capi_finish(u.id, 'failed', 'Invalid parameter') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) u WHERE u.stage = 'lead_created';
SELECT pg_temp.ok((SELECT status = 'sent' AND sent_at IS NOT NULL AND error IS NULL FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) WHERE stage = 'lead_created')
  AND (SELECT status = 'pending' AND attempts = 11 FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) WHERE stage = 'contacted'),
  'MS17 sent stays sent (a late answer cannot change it); a retry waits and is tried again');
SELECT public.svc_ads_meta_capi_finish(u.id, 'retry', 'later') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) u WHERE u.stage = 'contacted';
SELECT public.svc_ads_meta_capi_finish(u.id, 'failed', 'Invalid parameter') FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) u WHERE u.stage = 'qualified';
SELECT pg_temp.ok((SELECT status FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) WHERE stage = 'contacted') = 'failed'
  AND (SELECT status = 'failed' AND error = 'Invalid parameter' FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'yes')) WHERE stage = 'qualified'),
  'MS17b after 12 tries, or when Meta refuses the event, it stops and keeps Meta''s reason');

UPDATE public.ads_meta_capi_uploads SET status = 'pending', attempts = 0, last_try_at = NULL WHERE lead_id = (SELECT v FROM ml WHERE k = 'none');
UPDATE public.ads_lead SET quarantined = true WHERE id = (SELECT v FROM ml WHERE k = 'none');
SELECT pg_temp.src('instant_form', '{"consent_mode": "not_required"}');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' LIKE (SELECT v FROM ml WHERE k = 'none')::text || '%'),
  'MS18 a lead quarantined after it was queued is not sent');
UPDATE public.ads_lead SET quarantined = false WHERE id = (SELECT v FROM ml WHERE k = 'none');
SELECT pg_temp.src('instant_form', '{"consent_mode": "required"}');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'event_id' LIKE (SELECT v FROM ml WHERE k = 'none')::text || '%'),
  'MS18b a lead whose consent no longer meets the rule (rule tightened) is not sent');

-- Website: an enquiry from a Meta ad click on the website, with and without browser details.
SELECT pg_temp.src('website', '{"report_enabled": true, "dataset_id": "1122334455", "consent_mode": "required"}');
SET ROLE service_role;
SELECT public.svc_ads_ingest_enquiry(jsonb_build_object('name', 'Web Meta', 'phone', '9811300021', 'fbclid', 'IwAR2F4-dbP0l7Mn1', 'utm_source', 'facebook', 'utm_medium', 'paid_social',
  'page_url', 'https://weoneaviation.in/cpl?fbclid=IwAR2F4-dbP0l7Mn1', 'touch_at', '2026-11-16T08:00:00Z', 'submission_id', 'web-meta-1', 'client_user_agent', 'Mozilla/5.0 Test',
  'consent', jsonb_build_object('notice_version', 'v1', 'ad_data_sharing', true)), 'pilot_training');
SELECT public.svc_ads_ingest_enquiry(jsonb_build_object('name', 'Web Meta Two', 'phone', '9811300022', 'fbclid', 'IwAR2F4-zzz', 'utm_medium', 'paid_social',
  'page_url', 'https://weoneaviation.in/cpl', 'submission_id', 'web-meta-2', 'consent', jsonb_build_object('ad_data_sharing', true)), 'pilot_training');
RESET ROLE;
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE phone_e164 IN ('+919811300021', '+919811300022');
SELECT pg_temp.age_events(id, '2 hours') FROM public.ads_lead WHERE phone_e164 IN ('+919811300021', '+919811300022') AND deleted_at IS NULL;
INSERT INTO ml SELECT 'web', id FROM public.ads_lead WHERE phone_e164 = '+919811300021' AND deleted_at IS NULL;
INSERT INTO ml SELECT 'web_noua', id FROM public.ads_lead WHERE phone_e164 = '+919811300022' AND deleted_at IS NULL;
SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT i->>'fbc' = 'fb.1.' || (extract(epoch FROM '2026-11-16T08:00:00Z'::timestamptz) * 1000)::bigint || '.IwAR2F4-dbP0l7Mn1'
    AND i->>'event_name' = 'Lead' AND i->>'client_user_agent' = 'Mozilla/5.0 Test' AND i->>'event_source_url' LIKE 'https://weoneaviation.in/cpl%' AND i->>'lead_id' IS NULL
    FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'source' = 'website' AND i->>'event_id' LIKE (SELECT v FROM ml WHERE k = 'web')::text || '%'),
  'MS19 a website enquiry from a Meta ad is reported as a website Lead with fbc (fb.1.<first click ms>.<fbclid>), page and browser');
SELECT pg_temp.ok((SELECT status = 'skipped' AND error LIKE '%browser%' FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'web_noua'))),
  'MS19b without browser details it is skipped (Meta requires them for website events), with the reason');
SELECT pg_temp.ok((SELECT count(*) FROM pg_temp.ups((SELECT v FROM ml WHERE k = 'web')) WHERE source <> 'website') = 0
  AND NOT EXISTS (SELECT 1 FROM public.ads_conversion_uploads u JOIN ml ON ml.v = u.lead_id),
  'MS19c a Meta lead goes only to Meta: never to the Google report queue');

-- WhatsApp ads
SELECT pg_temp.src('ctwa', '{"intake_enabled": true, "report_enabled": true, "dataset_id": "1122334466", "consent_mode": "not_required"}');
SET ROLE service_role;
SELECT pg_temp.ok(pg_temp.raw('ctwa', 'ARAkLkA8rmlFeiCktEJQ', '{"phone": "919811300031", "name": "Wa Lead", "waba_id": "123456789012"}') = 1, 'MS20 a WhatsApp ad chat is stored once switched on');
SELECT pg_temp.ok((public.svc_ads_meta_lead_finish(pg_temp.rawid('ctwa', 'ARAkLkA8rmlFeiCktEJQ'), 'fetched', jsonb_build_object('name', 'Wa Lead', 'phone', '919811300031',
    'submission_id', 'meta-ctwa-ARAkLkA8rmlFeiCktEJQ', 'utm_source', 'facebook', 'utm_medium', 'paid_social', 'site', 'wa.me',
    'first_touch', jsonb_build_object('utm_source', 'facebook', 'utm_medium', 'paid_social', 'meta_source', 'ctwa', 'ctwa_clid', 'ARAkLkA8rmlFeiCktEJQ', 'waba_id', '123456789012'),
    'consent', '{"notice_version": "meta_ctwa"}'::jsonb), 'pilot_training')->>'status') = 'created', 'MS20b it becomes an Ads lead (phone 91XXXXXXXXXX understood)');
RESET ROLE;
INSERT INTO ml SELECT 'wa', id FROM public.ads_lead WHERE phone_e164 = '+919811300031' AND deleted_at IS NULL;
UPDATE public.ads_lead SET created_at = now() - interval '2 hours' WHERE id = (SELECT v FROM ml WHERE k = 'wa');
SELECT pg_temp.age_events((SELECT v FROM ml WHERE k = 'wa'), '2 hours');
SELECT pg_temp.mq();
SELECT pg_temp.ok((SELECT i->>'event_name' = 'LeadSubmitted' AND i->>'ctwa_clid' = 'ARAkLkA8rmlFeiCktEJQ' AND i->>'waba_id' = '123456789012'
    FROM jsonb_array_elements(pg_temp.mw()->'items') i WHERE i->>'source' = 'ctwa'),
  'MS20c it is reported as LeadSubmitted with its WhatsApp click id and Business Account id');

-- ================================================================ MS21-25 safety and plumbing
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails('SELECT count(*) FROM public.ads_meta_lead_raw', '%permission denied%', 'MS21 the browser cannot read Meta lead rows, even as Admin');
SELECT pg_temp.fails('SELECT count(*) FROM public.ads_meta_capi_uploads', '%permission denied%', 'MS21b ... or the report queue');
SELECT pg_temp.fails('SELECT public.svc_ads_meta_capi_work()', '%permission denied%', 'MS21c ... or call the reporter''s functions');
SELECT pg_temp.fails('SELECT public.svc_ads_meta_webhook_cfg()', '%permission denied%', 'MS21d ... or read the webhook secrets');
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_meta_leads_work() ? 'items' AND public.svc_ads_meta_capi_work() ? 'items' AND public.svc_ads_meta_reconcile_work() ? 'forms',
  'MS21e the Edge Functions (service role) can call them');
RESET ROLE;

SET ROLE service_role;
SELECT public.svc_ads_meta_forms_save('[{"id": "987654321", "name": "CPL enquiry", "status": "ACTIVE"}, {"id": "987654322", "name": "Old form", "status": "ARCHIVED"}, {"id": "x"}]');
RESET ROLE;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_meta_form_save('987654321', 'charter', true);
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_form_save('987654321', 'flights', true)$q$, '%Unknown pipeline%', 'MS22 a form cannot be sent to an unknown pipeline');
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_meta_forms_save('[{"id": "987654321", "name": "CPL enquiry v2", "status": "ACTIVE"}]');
SELECT pg_temp.ok((SELECT pipeline = 'charter' AND name = 'CPL enquiry v2' FROM public.ads_meta_forms WHERE form_id = '987654321')
  AND (SELECT NOT active FROM public.ads_meta_forms WHERE form_id = '987654322'),
  'MS22b re-reading the Page updates names but keeps the owner''s pipeline; archived forms start inactive');
SELECT pg_temp.cfg('meta_page_id', '111222333444');
SELECT pg_temp.ok((SELECT jsonb_array_length(w->'forms') = 1 AND w->>'page_id' = '111222333444' AND (w->'forms'->0->>'since')::bigint <= extract(epoch FROM now() - interval '48 hours')
    FROM public.svc_ads_meta_reconcile_work() w), 'MS22c the daily check reads the active forms for (at least) the last 48 hours');
SELECT public.svc_ads_meta_reconciled('987654321');
SELECT pg_temp.ok(public.svc_ads_meta_raw_add('[{"source": "instant_form", "external_id": "1000000000000099"}]', 'reconcile') = 1, 'MS22d a lead the webhook missed is added by the daily check');
SELECT pg_temp.ok((SELECT last_reconciled_at > now() - interval '1 minute' FROM public.ads_meta_forms WHERE form_id = '987654321')
  AND (SELECT via FROM public.ads_meta_lead_raw WHERE external_id = '1000000000000099') = 'reconcile',
  'MS22e ... marked as such, and the form''s check time is recorded');
RESET ROLE;

SELECT pg_temp.ok(pg_temp.wake(), 'MS23 the scheduler wakes the function when a Meta lead is waiting');
UPDATE public.ads_meta_lead_raw SET status = 'failed' WHERE status = 'pending';
UPDATE public.ads_meta_capi_uploads SET status = 'sent' WHERE status = 'pending';
SELECT pg_temp.ok(NOT pg_temp.wake(), 'MS23b nothing waiting: it sleeps (no pointless calls)');

SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((public.api_ads_settings_save('META_WEBHOOK_VERIFY_TOKEN', 'verify-word-123456')->>'last4') = '3456', 'MS24 the webhook verify token is saved like the other keys');
SELECT pg_temp.ok((public.api_ads_settings()->'secrets'->'META_WEBHOOK_VERIFY_TOKEN'->>'set')::boolean AND (public.api_ads_settings()->'secrets'->'META_PAGE_TOKEN'->>'set') = 'false',
  'MS24a both new keys are listed in Settings (set / not set)');
SELECT pg_temp.ok((public.api_ads_meta_settings()->'secrets'->>'META_WEBHOOK_VERIFY_TOKEN')::boolean
  AND public.api_ads_meta_settings()::text NOT LIKE '%verify-word%', 'MS24b the dashboard sees that it is set, never the value');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_config_save('meta_page_id', 'my page')$q$, '%Digits only%', 'MS24c the Page ID must be digits');
RESET ROLE; SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_meta_webhook_cfg()->>'verify_token' = 'verify-word-123456' AND (public.svc_ads_meta_webhook_cfg()->'intake'->>'ctwa')::boolean,
  'MS24d the webhook function (server only) gets its token and which sources accept leads');
RESET ROLE;

-- ================================================================ MS30-39 two sections: stops, per-platform lists, setup status
RESET ROLE;
UPDATE public.ads_meta_capi_uploads SET status = 'pending', attempts = 0, last_try_at = NULL WHERE lead_id = (SELECT v FROM ml WHERE k = 'wa');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_platform_pause('meta', true)$q$, '%Only Admin%', 'MS30 only Admin can stop a platform');
SELECT pg_temp.as_('a');
SELECT public.api_ads_platform_pause('meta', true);
RESET ROLE;
SELECT pg_temp.ok(crm_private.ads_platform_paused('meta') AND NOT crm_private.ads_platform_paused('google'), 'MS31 stopping Meta does not stop Google');
SELECT pg_temp.ok((pg_temp.mw()->>'paused')::boolean AND pg_temp.mq() = 0, 'MS31b with Meta stopped nothing is queued or handed out for Meta');
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_secrets()->>'META_PAUSED' = 'true' AND public.svc_ads_secrets()->>'GOOGLE_PAUSED' = 'false', 'MS31c ads-sync is told which platform is stopped');
RESET ROLE;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_platform_pause('meta', false);
RESET ROLE;
SELECT pg_temp.ok(NOT (pg_temp.mw()->>'paused' IS NOT NULL) AND jsonb_array_length(pg_temp.mw()->'items') >= 1, 'MS31d resumed: Meta reports flow again');
SELECT pg_temp.cfg('execution_paused', 'true');
SELECT pg_temp.ok(crm_private.ads_platform_paused('google') AND crm_private.ads_platform_paused('meta'), 'MS32 the emergency stop still stops both');
SELECT pg_temp.cfg('execution_paused', 'false');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_platform_pause('tiktok', true)$q$, '%Unknown platform%', 'MS32b an unknown platform is refused');

-- per-platform Ads Leads lists: a Google click, a Meta form, and one person who came through both
RESET ROLE;
SELECT pg_temp.click('Gina Google', '9811300041');
SELECT pg_temp.click('Bo Both', '9811300042');
SELECT public.svc_ads_ingest_enquiry(jsonb_build_object('name', 'Bo Both', 'phone', '9811300042', 'fbclid', 'IwAR-both', 'utm_medium', 'paid_social',
  'page_url', 'https://weoneaviation.in/x', 'submission_id', 'both-2'), 'pilot_training');
CREATE OR REPLACE FUNCTION pg_temp.names(p_platform text) RETURNS text[] LANGUAGE sql AS $$
  SELECT array_agg(r->>'name' ORDER BY r->>'name') FROM jsonb_array_elements(public.api_ads_lead_board('pilot_training', NULL, false, NULL, 300, p_platform)->'rows') r $$;
GRANT EXECUTE ON FUNCTION pg_temp.names(text) TO authenticated;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok('Gina Google' = ANY (pg_temp.names('google')) AND NOT 'Gina Google' = ANY (pg_temp.names('meta')),
  'MS33 a Google lead is only in the Google Ads list');
SELECT pg_temp.ok('Meta 9811300001' = ANY (pg_temp.names('meta')) AND NOT 'Meta 9811300001' = ANY (pg_temp.names('google')),
  'MS33b a Meta form lead is only in the Meta Ads list');
SELECT pg_temp.ok('Bo Both' = ANY (pg_temp.names('google')) AND 'Bo Both' = ANY (pg_temp.names('meta'))
  AND (SELECT r->'platforms' = '["google", "meta"]' FROM jsonb_array_elements(public.api_ads_lead_board('pilot_training', NULL, false, NULL, 300, 'meta')->'rows') r WHERE r->>'name' = 'Bo Both'),
  'MS33c someone who came through both is in both lists, marked with both platforms');
SELECT pg_temp.ok(cardinality(pg_temp.names(NULL)) >= cardinality(pg_temp.names('google')) + cardinality(pg_temp.names('meta')) - 1, 'MS33d without a platform the list is the combined one, as before');
SELECT pg_temp.ok((public.api_ads_lead_board('pilot_training', NULL, false, NULL, 300, 'google')->'stats'->>'total')::int = cardinality(pg_temp.names('google')),
  'MS33e the counts at the top follow the platform too');
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_board('pilot_training', NULL, false, NULL, 300, 'tiktok')$q$, '%Unknown platform%', 'MS33f an unknown platform is refused');

-- setup status
SELECT pg_temp.ok((SELECT s ? 'secrets' AND s ? 'accounts' AND s->'meta' ? 'webhook_verified_at' AND (s->'secrets'->>'META_WEBHOOK_VERIFY_TOKEN')::boolean
    AND s::text NOT LIKE '%verify-word%' FROM public.api_ads_setup_status('meta') s), 'MS34 the Meta setup status says which keys are saved, never their values');
SELECT pg_temp.ok((SELECT s->'google' ? 'conv_actions' AND s->'meta' = 'null'::jsonb FROM public.api_ads_setup_status('google') s), 'MS34b the Google setup status has the Google checks');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_ads_setup_status('meta')$q$, '%Only Admin%', 'MS34c only Admin sees the setup status');
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_meta_webhook_seen();
SELECT pg_temp.ok((public.svc_ads_meta_test_lead()->>'lead_id') ~ '^1000000000000\d{3}$' AND public.svc_ads_meta_test_lead()::text NOT LIKE '%98113%',
  'MS35 the test event uses the newest real Meta form lead id, contact details only as hashes');
RESET ROLE;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok(public.api_ads_setup_status('meta')->'meta'->>'webhook_verified_at' IS NOT NULL, 'MS35b Meta''s check of the callback URL shows in Setup');
RESET ROLE;

-- clean up for later files
RESET ROLE;
UPDATE public.ads_meta_settings SET intake_enabled = false, report_enabled = false, consent_mode = 'required';
UPDATE public.ads_lead SET deleted_at = now() WHERE deleted_at IS NULL;
\echo ALL ADS META TESTS PASSED
