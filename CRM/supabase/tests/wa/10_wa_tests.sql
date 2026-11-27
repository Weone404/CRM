-- WhatsApp (migration 150) SQL tests. Run by run.sh on a throwaway database after the stubs and 150 (applied twice).
-- Each check prints "PASS <name>"; the first failure stops the run with "FAIL <name>".
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF;
  RAISE NOTICE 'PASS %', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.fails(p_sql text, p_like text, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN RAISE NOTICE 'PASS %', name; RETURN; END IF;
    RAISE EXCEPTION 'FAIL % (wrong error: %)', name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL % (no error)', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
CREATE OR REPLACE FUNCTION pg_temp.conv(p_phone10 text, p_brand text DEFAULT 'aviation') RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT v.id FROM public.wa_conversation v JOIN public.wa_contact c ON c.id = v.contact_id WHERE c.wa_id = '91' || p_phone10 AND v.brand = p_brand $$;
CREATE OR REPLACE FUNCTION pg_temp.welcomes(p_phone10 text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.wa_queue q JOIN public.wa_conversation v ON v.id = q.conversation_id JOIN public.wa_contact c ON c.id = v.contact_id
   WHERE c.wa_id = '91' || p_phone10 AND q.kind = 'welcome' $$;
CREATE OR REPLACE FUNCTION pg_temp.all_setup_ok() RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.wa_setup_check (step, ok) SELECT k, true FROM unnest(ARRAY['business', 'app', 'number', 'payment', 'token', 'ids',
    'webhook', 'subscribed', 'registered', 'templates', 'test']) k ON CONFLICT (step) DO UPDATE SET ok = true $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Counsellor', 'IT', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Outsider', 'IT', '10000000-0000-0000-0000-00000000000d');

-- ---------------------------------------------------------------- access
SET ROLE authenticated;
SELECT pg_temp.as_('d');
SELECT pg_temp.ok(NOT (public.api_wa_access() ->> 'can_view')::boolean, 'W01 no access without a grant');
SELECT pg_temp.fails($$SELECT public.api_wa_overview()$$, '%do not have access%', 'W02 overview refused without access');
SELECT pg_temp.fails($$SELECT public.api_wa_lead_panel(gen_random_uuid())$$, '%do not have access%', 'W03 lead panel refused for non-Sales without access');
SELECT pg_temp.as_('a');
SELECT pg_temp.ok((public.api_wa_access() ->> 'can_manage')::boolean, 'W04 Admin can manage');
SELECT public.api_wa_access_set('00000000-0000-0000-0000-00000000000c', true, false);
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_wa_access() ->> 'can_view')::boolean AND NOT (public.api_wa_access() ->> 'can_manage')::boolean, 'W05 granted person can view, not manage');
SELECT pg_temp.fails($$SELECT public.api_wa_settings_save('{"pause_all": true}')$$, '%permission%', 'W06 viewer cannot change settings');
SELECT pg_temp.fails($$SELECT public.api_wa_access_set('00000000-0000-0000-0000-00000000000d', true)$$, '%Only Admin%', 'W07 only Admin grants access');
SELECT pg_temp.fails($$SELECT * FROM public.wa_message$$, '%permission denied%', 'W08 tables are not readable directly');
SELECT pg_temp.fails($$SELECT public.svc_wa_secrets()$$, '%permission denied%', 'W09 secrets function is service-only');
SELECT pg_temp.as_('b');
SELECT pg_temp.ok(public.api_wa_lead_panel(gen_random_uuid()) IS NULL, 'W10 Sales can open the lead panel');
RESET ROLE;

-- ---------------------------------------------------------------- intake while not live
INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('Aarav Sharma', '9811111111', 'website', '+919811111111');
SELECT pg_temp.ok(pg_temp.conv('9811111111') IS NOT NULL AND pg_temp.welcomes('9811111111') = 0, 'W11 not live: contact and chat made, nothing queued');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_event WHERE kind = 'skip_not_live'), 'W12 not live is logged');

SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.fails($$SELECT public.api_wa_settings_save('{"enabled": true}')$$, '%Finish every step%', 'W13 cannot go live before Setup is done');
RESET ROLE;
SELECT pg_temp.all_setup_ok();
SET ROLE authenticated; SELECT pg_temp.as_('a');
SELECT pg_temp.fails($$SELECT public.api_wa_settings_save('{"test_numbers": ["12ab"]}')$$, '%Not a phone number%', 'W14 test numbers are validated');
SELECT pg_temp.ok((public.api_wa_settings_save('{"enabled": true, "test_mode": true, "test_numbers": ["+91 98222 22222", "9833333333"]}') ->> 'enabled')::boolean, 'W15 go live once Setup is done');
RESET ROLE;
SELECT pg_temp.ok((SELECT test_numbers FROM public.wa_settings) = '{919822222222,919833333333}'::text[], 'W16 test numbers stored as WhatsApp ids');

-- ---------------------------------------------------------------- intake while live
INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('Riya Test', '98222 22222', 'website', '+919822222222');
SELECT pg_temp.ok(pg_temp.welcomes('9822222222') = 1, 'W17 website lead: one welcome queued');
SELECT pg_temp.ok((SELECT item ->> 'purpose' FROM public.wa_queue WHERE idempotency_key LIKE 'welcome:lead:%' ORDER BY id DESC LIMIT 1) = 'aviation', 'W18 welcome uses the Aviation template');
INSERT INTO public.ads_lead (pipeline, name, phone_e164, first_touch) VALUES ('pilot_training', 'Riya T', '+919822222222', '{"meta_source": "instant_form"}');
SELECT pg_temp.ok(pg_temp.welcomes('9822222222') = 1, 'W19 same person from Meta: no second welcome');
SELECT pg_temp.ok((SELECT lead_id IS NOT NULL AND ads_lead_id IS NOT NULL FROM public.wa_contact WHERE wa_id = '919822222222'), 'W20 contact linked to both the lead and the ads lead');
SELECT pg_temp.ok((SELECT count(*) FROM public.wa_contact WHERE wa_id = '919822222222') = 1, 'W21 one contact per phone across sources');
INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('JD Person', '9844444444', 'JustDial', '+919844444444');
SELECT pg_temp.ok(pg_temp.welcomes('9844444444') = 0 AND EXISTS (SELECT 1 FROM public.wa_event WHERE kind = 'skip_source_off'), 'W22 JustDial is off by default');
SELECT pg_temp.ok((SELECT NOT opted_in FROM public.wa_contact WHERE wa_id = '919844444444'), 'W23 JustDial does not count as opt-in');
INSERT INTO public.lead (name, phone, utm_source, dedup_key, segment) VALUES ('Charter Co', '9833333333', 'website', '+919833333333', 'charter');
SELECT pg_temp.ok((SELECT q.item ->> 'purpose' FROM public.wa_queue q WHERE q.conversation_id = pg_temp.conv('9833333333', 'charter')) = 'charter', 'W24 charter lead: Charter welcome');
INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('Bad Phone', '12345', 'website', '12345');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.lead WHERE dedup_key = '12345') AND EXISTS (SELECT 1 FROM public.wa_event WHERE kind = 'skip_invalid_phone'), 'W25 invalid phone: lead saved, WhatsApp skips');
INSERT INTO public.ads_lead (pipeline, name, phone_e164, quarantined) VALUES ('pilot_training', 'Spam', '+919855555555', true);
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.wa_contact WHERE wa_id = '919855555555'), 'W26 quarantined ads lead is never messaged');
INSERT INTO public.ads_lead (pipeline, name, phone_e164, first_touch) VALUES ('charter', 'Jet Set', '+919866666666', '{"utm_source": "google"}');
SELECT pg_temp.ok(pg_temp.conv('9866666666', 'charter') IS NOT NULL, 'W27 charter ads lead lands in a Charter chat');

-- The trigger never blocks a lead, even with the WhatsApp tables broken.
DO $$
BEGIN
  ALTER TABLE public.wa_contact RENAME TO wa_contact_broken;
  INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('Still Saved', '9877777777', 'website', '+919877777777');
  ALTER TABLE public.wa_contact_broken RENAME TO wa_contact;
END $$;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.lead WHERE dedup_key = '+919877777777'), 'W28 lead saved while WhatsApp tables were broken');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_error WHERE place = 'lead_trigger'), 'W29 the problem is logged in wa_error');
DO $$
BEGIN
  ALTER FUNCTION crm_private.wa_intake(text, uuid, text, text, text, text) RENAME TO wa_intake_gone;
  INSERT INTO public.ads_lead (pipeline, name, phone_e164) VALUES ('pilot_training', 'Also Saved', '+919878787878');
  ALTER FUNCTION crm_private.wa_intake_gone(text, uuid, text, text, text, text) RENAME TO wa_intake;
END $$;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.ads_lead WHERE phone_e164 = '+919878787878'), 'W30 ads lead saved with the WhatsApp function missing');

-- ---------------------------------------------------------------- claim (all rules in one place)
INSERT INTO public.lead (name, phone, utm_source, dedup_key) VALUES ('Not A Tester', '9888888888', 'website', '+919888888888');
SET ROLE service_role;
CREATE TEMP TABLE c1 AS SELECT public.svc_wa_claim() AS j;
SELECT pg_temp.ok(jsonb_array_length((SELECT j FROM c1)) = 2, 'W31 claim returns the two test-number welcomes');
SELECT pg_temp.ok((SELECT state FROM public.wa_queue q WHERE q.conversation_id = pg_temp.conv('9888888888')) = 'skipped', 'W32 test mode skips other numbers');
SELECT pg_temp.ok((SELECT bool_and(x -> 'template' ->> 'name' IN ('weone_welcome', 'bmc_welcome')) FROM c1, jsonb_array_elements(j) x), 'W33 claim resolves the template');
SELECT pg_temp.ok((SELECT x -> 'vars' ->> 'name' FROM c1, jsonb_array_elements(j) x WHERE x ->> 'to' = '919822222222') = 'Riya', 'W34 first name for {{1}}');
SELECT pg_temp.ok(jsonb_array_length(public.svc_wa_claim()) = 0, 'W35 nothing is claimed twice');
SELECT public.svc_wa_result((SELECT (x ->> 'id')::bigint FROM c1, jsonb_array_elements(j) x WHERE x ->> 'to' = '919822222222'),
  true, 'wamid.W1', NULL, NULL, false, '{"kind": "template", "body": "Hi Riya", "template_name": "weone_welcome", "category": "utility"}');
SELECT pg_temp.ok((SELECT welcomed_at IS NOT NULL AND current_step = 'welcome' AND next_followup_at BETWEEN now() + interval '23 hours' AND now() + interval '25 hours'
                     FROM public.wa_conversation WHERE id = pg_temp.conv('9822222222')), 'W36 welcome sent: step set, follow-up in 24 h');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_message WHERE wamid = 'wamid.W1' AND direction = 'out' AND status = 'sent'), 'W37 sent message stored');
-- crash recovery: a send stuck in 'sending' for 5 minutes goes back to pending
UPDATE public.wa_queue SET updated_at = now() - interval '6 minutes'
 WHERE conversation_id = pg_temp.conv('9833333333', 'charter') AND state = 'sending';
SELECT pg_temp.ok(jsonb_array_length(public.svc_wa_claim()) = 1, 'W38 a stuck send is picked up again');
-- retries with back-off, then dead + failed message + alert
DO $$
DECLARE qid bigint := (SELECT id FROM public.wa_queue WHERE conversation_id = pg_temp.conv('9833333333', 'charter'));
BEGIN
  PERFORM public.svc_wa_result(qid, false, NULL, 131000, 'Something went wrong', true, '{}');
  PERFORM pg_temp.ok((SELECT state = 'pending' AND run_after > now() FROM public.wa_queue WHERE id = qid), 'W39 temporary error: retried later');
  UPDATE public.wa_queue SET attempts = 5, state = 'sending' WHERE id = qid;
  PERFORM public.svc_wa_result(qid, false, NULL, 131000, 'Something went wrong', true, '{}');
  PERFORM pg_temp.ok((SELECT state = 'dead' FROM public.wa_queue WHERE id = qid), 'W40 after 5 tries: dead');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_message m WHERE m.conversation_id = pg_temp.conv('9833333333', 'charter') AND m.status = 'failed'), 'W41 failure visible in the chat');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_event e WHERE e.kind = 'send_failed' AND e.notify), 'W42 failure raises a phone alert');
END $$;

-- opt-out blocks every send
UPDATE public.wa_contact SET opted_out = true WHERE wa_id = '919822222222';
INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item) VALUES ('followup', pg_temp.conv('9822222222'), 'test-optout', '{"type": "template", "purpose": "followup_1"}');
SELECT public.svc_wa_claim();
SELECT pg_temp.ok((SELECT state = 'skipped' FROM public.wa_queue WHERE idempotency_key = 'test-optout'), 'W43 opted-out person gets nothing');
UPDATE public.wa_contact SET opted_out = false WHERE wa_id = '919822222222';

-- quiet hours hold follow-ups (welcomes go any time)
UPDATE public.wa_settings SET quiet_start = ((now() AT TIME ZONE 'Asia/Kolkata') - interval '1 hour')::time,
                              quiet_end = ((now() AT TIME ZONE 'Asia/Kolkata') + interval '1 hour')::time;
INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item) VALUES ('followup', pg_temp.conv('9822222222'), 'test-quiet', '{"type": "template", "purpose": "followup_1"}');
SELECT public.svc_wa_claim();
SELECT pg_temp.ok((SELECT state = 'pending' AND run_after > now() + interval '50 minutes' FROM public.wa_queue WHERE idempotency_key = 'test-quiet'), 'W44 follow-up waits for quiet hours to end');
UPDATE public.wa_settings SET quiet_start = '20:00', quiet_end = '09:00';
DELETE FROM public.wa_queue WHERE idempotency_key = 'test-quiet';

-- daily cap on new people
UPDATE public.wa_settings SET daily_new_contact_cap = 1;
INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item) VALUES ('welcome', pg_temp.conv('9833333333', 'charter'), 'test-cap', '{"type": "template", "purpose": "charter"}');
SELECT public.svc_wa_claim();
SELECT pg_temp.ok((SELECT state = 'pending' AND last_error = 'Daily limit reached' FROM public.wa_queue WHERE idempotency_key = 'test-cap'), 'W45 daily limit holds new welcomes');
UPDATE public.wa_settings SET daily_new_contact_cap = 200;
DELETE FROM public.wa_queue WHERE idempotency_key = 'test-cap';

-- Pause all holds the bot but not a person's message
UPDATE public.wa_settings SET pause_all = true;
INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item) VALUES ('welcome', pg_temp.conv('9833333333', 'charter'), 'test-pause', '{"type": "template", "purpose": "charter"}');
SELECT pg_temp.ok(jsonb_array_length(public.svc_wa_claim()) = 0 AND (SELECT state FROM public.wa_queue WHERE idempotency_key = 'test-pause') = 'pending', 'W46 Pause all: nothing goes out');
UPDATE public.wa_settings SET pause_all = false;
DELETE FROM public.wa_queue WHERE idempotency_key = 'test-pause';

-- follow-ups only for people who never replied
UPDATE public.wa_conversation SET next_followup_at = now() - interval '1 minute' WHERE id = pg_temp.conv('9822222222');
SELECT pg_temp.ok(public.svc_wa_followups_due() = 1, 'W47 due follow-up queued');
SELECT pg_temp.ok((SELECT item ->> 'purpose' FROM public.wa_queue WHERE kind = 'followup' AND idempotency_key LIKE 'followup:%') = 'followup_1', 'W48 first follow-up template');
SELECT pg_temp.ok(public.svc_wa_followups_due() = 0, 'W49 never queued twice');

-- ---------------------------------------------------------------- inbound
CREATE TEMP TABLE i1 AS SELECT public.svc_wa_inbound('{"wamid": "wamid.IN1", "from": "919822222222", "profile_name": "Riya", "kind": "button", "button_title": "I''m a student", "ts": "1795000000"}') AS j;
SELECT pg_temp.ok((SELECT j ->> 'conversation_id' FROM i1)::uuid = pg_temp.conv('9822222222'), 'W50 reply lands in the chat we wrote in');
SELECT pg_temp.ok((SELECT jsonb_array_length(j -> 'steps') = 8 AND jsonb_array_length(j -> 'rules') >= 10 AND (j ->> 'bot_on')::boolean FROM i1), 'W51 engine gets steps, rules, bot on');
SELECT pg_temp.ok((SELECT unread = 1 AND last_inbound_at > now() - interval '1 minute' AND next_followup_at IS NULL FROM public.wa_conversation WHERE id = pg_temp.conv('9822222222')), 'W52 reply: unread, window open, follow-ups stop');
SELECT pg_temp.ok((public.svc_wa_inbound('{"wamid": "wamid.IN1", "from": "919822222222", "kind": "text", "text": "again"}') ->> 'duplicate')::boolean, 'W53 same message twice is ignored');
SELECT pg_temp.ok((SELECT count(*) FROM public.wa_message WHERE wamid = 'wamid.IN1') = 1, 'W54 stored once');
SELECT public.svc_wa_inbound('{"wamid": "wamid.IN2", "from": "919899999999", "profile_name": "New Person", "kind": "text", "text": "hello"}');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.lead WHERE dedup_key = '+919899999999' AND utm_source = 'whatsapp'), 'W55 new person who writes becomes a lead');
SELECT pg_temp.ok(pg_temp.welcomes('9899999999') = 0, 'W56 no welcome template for someone who wrote first');
SELECT pg_temp.ok((SELECT lead_id IS NOT NULL FROM public.wa_contact WHERE wa_id = '919899999999'), 'W57 contact linked to that lead');

-- apply: hand-off, lead note, idempotent replies
CREATE TEMP TABLE a1 AS SELECT public.svc_wa_apply(pg_temp.conv('9822222222'), '{"status": "human", "current_step": "pcm"}',
  '[{"type": "text", "body": "Our counsellor will call you."}]', '[{"kind": "counselling_requested", "notify": true}]', 'wamid.IN1') AS ids;
SELECT pg_temp.ok((SELECT cardinality(ids) FROM a1) = 1, 'W58 reply queued');
SELECT pg_temp.ok(cardinality(public.svc_wa_apply(pg_temp.conv('9822222222'), '{}', '[{"type": "text", "body": "Our counsellor will call you."}]', '[]', 'wamid.IN1')) = 0, 'W59 same reply never queued twice');
SELECT pg_temp.ok((SELECT status = 'human' AND needs_human_since IS NOT NULL FROM public.wa_conversation WHERE id = pg_temp.conv('9822222222')), 'W60 hand-off: needs a person');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.lead_note n JOIN public.wa_contact c ON c.lead_id = n.lead_id WHERE c.wa_id = '919822222222' AND n.body LIKE 'WhatsApp:%counselling%'), 'W61 counselling ask added to the lead''s notes');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.wa_event WHERE kind = 'counselling_requested' AND notify), 'W62 counselling ask alerts the team');
-- the bot's own hand-off message still goes out
SELECT pg_temp.ok(jsonb_array_length(public.svc_wa_claim((SELECT ids FROM a1))) = 1, 'W63a the bot''s hand-off message is sent');
-- staff take over after the bot queued a reply: that reply is dropped
CREATE TEMP TABLE a0 AS SELECT public.svc_wa_apply(pg_temp.conv('9822222222'), '{}', '[{"type": "text", "body": "queued before takeover"}]', '[]', 'before-takeover') AS ids;
UPDATE public.wa_conversation SET status = 'human', taken_over_at = now() + interval '1 second' WHERE id = pg_temp.conv('9822222222');
SELECT public.svc_wa_claim((SELECT ids FROM a0));
SELECT pg_temp.ok((SELECT state = 'skipped' FROM public.wa_queue WHERE id = (SELECT ids[1] FROM a0)), 'W63 bot replies stop when a person takes over');
-- 24-hour window: free text after it closed is refused
UPDATE public.wa_conversation SET status = 'bot', last_inbound_at = now() - interval '25 hours' WHERE id = pg_temp.conv('9822222222');
CREATE TEMP TABLE a2 AS SELECT public.svc_wa_apply(pg_temp.conv('9822222222'), '{}', '[{"type": "text", "body": "late"}]', '[]', 'late') AS ids;
SELECT public.svc_wa_claim((SELECT ids FROM a2));
SELECT pg_temp.ok((SELECT state = 'dead' AND last_error LIKE '24-hour%' FROM public.wa_queue WHERE id = (SELECT ids[1] FROM a2)), 'W64 free text after 24 hours is refused');
-- opt-out and START
SELECT public.svc_wa_apply(pg_temp.conv('9822222222'), '{"opted_out": true}', '[]', '[]', 'stop');
SELECT pg_temp.ok((SELECT opted_out FROM public.wa_contact WHERE wa_id = '919822222222'), 'W65 STOP opts out');
SELECT public.svc_wa_apply(pg_temp.conv('9822222222'), '{"opted_in": true}', '[]', '[]', 'start');
SELECT pg_temp.ok((SELECT NOT opted_out AND opt_in_source = 'replied START' FROM public.wa_contact WHERE wa_id = '919822222222'), 'W66 START opts back in');

-- ---------------------------------------------------------------- delivery receipts
SELECT public.svc_wa_status('[{"wamid": "wamid.W1", "status": "read"}]');
SELECT public.svc_wa_status('[{"wamid": "wamid.W1", "status": "delivered"}]');
SELECT pg_temp.ok((SELECT status FROM public.wa_message WHERE wamid = 'wamid.W1') = 'read', 'W67 status only moves forward');
INSERT INTO public.wa_message (conversation_id, direction, wamid, kind, status) VALUES (pg_temp.conv('9833333333', 'charter'), 'out', 'wamid.NOWA', 'template', 'sent');
SELECT public.svc_wa_status('[{"wamid": "wamid.NOWA", "status": "failed", "error_code": 131026, "error_text": "Message undeliverable"}]');
SELECT pg_temp.ok((SELECT not_on_whatsapp FROM public.wa_contact WHERE wa_id = '919833333333')
               AND EXISTS (SELECT 1 FROM public.wa_event WHERE kind = 'call_needed' AND notify), 'W68 not on WhatsApp: call alert');
SELECT public.svc_wa_status('[{"wamid": "wamid.NOWA", "status": "delivered"}]');
SELECT pg_temp.ok((SELECT status FROM public.wa_message WHERE wamid = 'wamid.NOWA') = 'failed', 'W69 failed sticks');
SELECT pg_temp.ok(public.svc_wa_raw_add('{"a": 1}', 'sha-1', 'gateway') IS NOT NULL AND public.svc_wa_raw_add('{"a": 1}', 'sha-1', 'direct') IS NULL, 'W70 same webhook stored once');
SELECT pg_temp.ok((SELECT gateway_seen_at IS NOT NULL FROM public.wa_settings), 'W71 gateway deliveries are recorded');
RESET ROLE;

-- ---------------------------------------------------------------- staff functions
SET ROLE authenticated; SELECT pg_temp.as_('c');
SELECT pg_temp.ok(jsonb_array_length(public.api_wa_inbox('all')) >= 1, 'W72 inbox lists chats');
SELECT pg_temp.ok(jsonb_array_length(public.api_wa_inbox('all', '98222')) = 1, 'W73 inbox search by number');
SELECT pg_temp.ok((public.api_wa_thread(pg_temp.conv('9822222222')) -> 'lead' ->> 'name') = 'Riya Test', 'W74 chat shows the lead card');
SELECT pg_temp.fails(format($$SELECT public.api_wa_send(%L, '{"type": "text", "body": "hi"}')$$, pg_temp.conv('9822222222')), '%24 hours%', 'W75 typed text needs an open window');
SELECT pg_temp.fails(format($$SELECT public.api_wa_send(%L, '{"type": "template", "name": "weone_welcome"}')$$, pg_temp.conv('9822222222')), '%not approved%', 'W76 only approved templates');
SELECT public.api_wa_set_status(pg_temp.conv('9822222222'), 'human');
SELECT pg_temp.ok((public.api_wa_thread(pg_temp.conv('9822222222')) -> 'conversation' ->> 'assigned_to') = '00000000-0000-0000-0000-00000000000c', 'W77 take over assigns the chat');
SELECT public.api_wa_note_add(pg_temp.conv('9822222222'), 'Called, will visit Saturday');
SELECT pg_temp.ok(jsonb_array_length(public.api_wa_thread(pg_temp.conv('9822222222')) -> 'notes') = 1, 'W78 internal note saved');
SELECT pg_temp.fails($$SELECT public.api_wa_step_save('{"brand": "aviation", "key": "x", "body": "x"}')$$, '%permission%', 'W79 viewer cannot edit the flow');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($$SELECT public.api_wa_step_save('{"brand": "aviation", "key": "Bad Key", "body": "x"}')$$, '%small letters%', 'W80 step names are checked');
SELECT pg_temp.fails($$SELECT public.api_wa_step_save('{"brand": "aviation", "key": "x", "kind": "buttons", "body": "x", "buttons": [{"title": "a"}, {"title": "b"}, {"title": "c"}, {"title": "d"}]}')$$, '%up to 3%', 'W81 max 3 buttons');
SELECT pg_temp.ok(public.api_wa_step_save('{"brand": "aviation", "key": "visit", "body": "Visit us at Dwarka", "sort": 90}') IS NOT NULL, 'W82 new step saved');
SELECT pg_temp.fails($$SELECT public.api_wa_step_save('{"brand": "aviation", "key": "visit", "body": "dup"}')$$, '%already exists%', 'W83 duplicate step name refused');
SELECT pg_temp.ok(public.api_wa_rule_save('{"brand": "aviation", "match_type": "contains", "patterns": ["address", "location"], "action": "goto", "goto_key": "visit"}') IS NOT NULL, 'W84 new rule saved');
SELECT pg_temp.ok(public.api_wa_template_save('{"name": "weone_visit", "body": "Hi {{1}}, our Dwarka office is open 10 to 6.", "buttons": ["Get directions"]}') IS NOT NULL, 'W85 new template draft');
SELECT pg_temp.fails($$SELECT public.api_wa_secret_save('access_token', 'short')$$, '%does not look right%', 'W86 secrets are checked');
SELECT public.api_wa_secret_save('access_token', 'EAAG1234567890abcdTOKEN');
SELECT pg_temp.ok((public.api_wa_setup() -> 'secrets' -> 'access_token' ->> 'last4') = 'OKEN' AND public.api_wa_setup()::text NOT LIKE '%EAAG1234%', 'W87 Setup shows only the last 4 characters');
SELECT pg_temp.ok(length(public.api_wa_verify_token_new()) > 20, 'W88 verify token generated');
SELECT public.api_wa_number_save('{"phone_number_id": "1234 5678 9012", "waba_id": "998877", "app_id": "5566"}');
SELECT pg_temp.ok((public.api_wa_setup() -> 'number' ->> 'phone_number_id') = '123456789012', 'W89 ids saved as digits');
SELECT pg_temp.fails($$SELECT public.api_wa_test_welcome('9811111111')$$, '%Test numbers%', 'W90 test send only to test numbers');
SELECT pg_temp.ok(public.api_wa_test_welcome('9822222222') IS NOT NULL, 'W91 test welcome queued');
SELECT pg_temp.ok((public.api_wa_insights(30) -> 'by_source') IS NOT NULL AND (public.api_wa_insights(30) -> 'cost' ->> 'before_gst') IS NOT NULL, 'W92 insights');
SELECT pg_temp.ok((public.api_wa_overview() ->> 'needs_human')::int >= 1, 'W93 overview counts chats needing a person');
RESET ROLE;
CREATE TEMP TABLE riya AS SELECT lead_id FROM public.wa_contact WHERE wa_id = '919822222222';
GRANT SELECT ON riya TO authenticated;
SET ROLE authenticated; SELECT pg_temp.as_('b');
SELECT pg_temp.ok((public.api_wa_lead_panel((SELECT lead_id FROM riya)) ->> 'status') = 'bot', 'W94 lead panel shows the chat state');
RESET ROLE;
SELECT 'ALL SQL TESTS PASSED';
