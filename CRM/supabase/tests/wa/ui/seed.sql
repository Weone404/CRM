-- UI test data: four chats in different states, built through the same svc_wa_* calls the Edge Functions use.
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Nikhil (Admin)', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Priya', 'Sales', '10000000-0000-0000-0000-00000000000b');
INSERT INTO public.wa_setup_check (step, ok, detail) SELECT k, true, 'Done' FROM unnest(ARRAY['business','app','number','payment','token','ids','webhook','subscribed','registered','templates']) k;
INSERT INTO public.wa_setup_check (step, ok, detail) VALUES ('test', false, 'Welcome delivered. Now tap a button on it from your phone.');
INSERT INTO public.wa_number (label, phone_number_id, waba_id, app_id, display_phone, verified_name, name_status, quality_rating, status, messaging_limit)
VALUES ('We One Aviation', '612345678901234', '512345678901234', '1234567890', '+91 98100 00000', 'We One Aviation', 'APPROVED', 'GREEN', 'CONNECTED', 'TIER_250');
UPDATE public.wa_settings SET enabled = true, test_mode = true, test_numbers = '{919811000001,919811000002,919811000003,919811000004}',
  brochure_url = 'https://weoneaviation.in/brochure.pdf', webhook_seen_at = now() - interval '2 hours', last_inbound_at = now() - interval '5 minutes';
UPDATE public.wa_template SET meta_status = 'approved', synced_at = now() WHERE name IN ('weone_welcome', 'bmc_welcome', 'weone_followup_1');
UPDATE public.wa_template SET meta_status = 'rejected', rejection_reason = 'Promotional content in a utility template' WHERE name = 'weone_followup_2';

INSERT INTO public.lead (name, phone, utm_source, dedup_key, course_interest) VALUES
  ('Riya Sharma', '9811000001', 'website', '+919811000001', 'CPL'),
  ('Kabir Mehta', '9811000002', 'facebook', '+919811000002', 'CPL'),
  ('Ananya Rao', '9811000004', 'google', '+919811000004', 'PPL');
INSERT INTO public.lead (name, phone, utm_source, dedup_key, segment) VALUES ('Vikram Jet Charters', '9811000003', 'website', '+919811000003', 'charter');

-- Sends whatever is queued, the way wa-worker does (Meta replaced by a fake message id).
CREATE OR REPLACE FUNCTION pg_temp.flush() RETURNS void LANGUAGE plpgsql AS $f$
DECLARE c jsonb;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(public.svc_wa_claim()) LOOP
    PERFORM public.svc_wa_result((c ->> 'id')::bigint, true, 'wamid.q' || (c ->> 'id'), NULL, NULL, false,
      CASE WHEN c -> 'item' ->> 'type' = 'template'
           THEN jsonb_build_object('kind', 'template', 'body', replace(c -> 'template' ->> 'body', '{{1}}', c -> 'vars' ->> 'name'), 'template_name', c -> 'template' ->> 'name')
           ELSE jsonb_build_object('kind', c -> 'item' ->> 'type', 'body', coalesce(c -> 'item' ->> 'body', c -> 'item' ->> 'caption'),
             'payload', CASE WHEN c -> 'item' ? 'buttons' THEN jsonb_build_object('buttons', (SELECT jsonb_agg(b ->> 'title') FROM jsonb_array_elements(c -> 'item' -> 'buttons') b))
                             WHEN c -> 'item' ->> 'type' = 'document' THEN jsonb_build_object('filename', c -> 'item' ->> 'filename') ELSE '{}'::jsonb END) END);
  END LOOP;
END $f$;

DO $$
DECLARE conv uuid;
BEGIN
  -- every welcome goes out
  PERFORM pg_temp.flush();
  PERFORM public.svc_wa_status('[{"wamid": "wamid.q1", "status": "read"}, {"wamid": "wamid.q2", "status": "delivered"}, {"wamid": "wamid.q3", "status": "read"}]');

  -- Riya: student, PCM yes, Mohali, brochure, asked for counselling -> needs a person
  PERFORM public.svc_wa_inbound('{"wamid": "in1", "from": "919811000001", "profile_name": "Riya", "kind": "button", "button_title": "I''m a student"}');
  conv := (SELECT v.id FROM public.wa_conversation v JOIN public.wa_contact k ON k.id = v.contact_id WHERE k.wa_id = '919811000001');
  PERFORM public.svc_wa_apply(conv, '{"current_step": "pcm"}', '[{"type": "buttons", "body": "Has the student studied Physics and Maths in 12th?", "buttons": [{"id": "pcm_yes", "title": "Yes"}, {"id": "pcm_no", "title": "No"}, {"id": "pcm_unsure", "title": "Not sure"}]}]', '[]', 'in1');
  PERFORM pg_temp.flush();
  PERFORM public.svc_wa_inbound('{"wamid": "in2", "from": "919811000001", "kind": "interactive", "button_title": "Yes"}');
  PERFORM public.svc_wa_apply(conv, '{"current_step": "city"}', '[{"type": "text", "body": "Which city are you in?"}]', '[]', 'in2');
  PERFORM pg_temp.flush();
  PERFORM public.svc_wa_inbound('{"wamid": "in3", "from": "919811000001", "kind": "text", "text": "Mohali"}');
  PERFORM public.svc_wa_apply(conv, '{"current_step": "counselling", "answers": {"city": "Mohali"}}', '[{"type": "document", "link": "https://weoneaviation.in/brochure.pdf", "filename": "We One Aviation brochure.pdf", "caption": "Here is our brochure."}, {"type": "buttons", "body": "Would you like a free counselling session?", "buttons": [{"id": "book", "title": "Book free counselling"}, {"id": "later", "title": "Call me later"}, {"id": "browse", "title": "Just browsing"}]}]', '[]', 'in3');
  PERFORM pg_temp.flush();
  PERFORM public.svc_wa_inbound('{"wamid": "in4", "from": "919811000001", "kind": "interactive", "button_title": "Book free counselling"}');
  PERFORM public.svc_wa_apply(conv, '{"current_step": "booked", "status": "human"}', '[{"type": "text", "body": "Great! Our counsellor will call you shortly to fix a time. You can also call us on 9355566991."}]', '[{"kind": "counselling_requested", "notify": true}]', 'in4');
  PERFORM pg_temp.flush();
  -- Kabir: asked about fees -> needs a person
  PERFORM public.svc_wa_inbound('{"wamid": "in5", "from": "919811000002", "profile_name": "Kabir", "kind": "text", "text": "fees kitna hai?"}');
  conv := (SELECT v.id FROM public.wa_conversation v JOIN public.wa_contact k ON k.id = v.contact_id WHERE k.wa_id = '919811000002');
  PERFORM public.svc_wa_apply(conv, '{"status": "human"}', '[{"type": "text", "body": "Our counsellor will share the complete details on a call. They will reach you shortly."}]', '[{"kind": "handoff", "notify": true}]', 'in5');
  PERFORM pg_temp.flush();
  -- Charter: wants options
  PERFORM public.svc_wa_inbound('{"wamid": "in6", "from": "919811000003", "profile_name": "Vikram", "kind": "button", "button_title": "Yes, share options"}');
  conv := (SELECT v.id FROM public.wa_conversation v JOIN public.wa_contact k ON k.id = v.contact_id WHERE k.wa_id = '919811000003');
  PERFORM public.svc_wa_apply(conv, '{"current_step": "trip"}', '[{"type": "text", "body": "Please share your trip: from city, to city, date and number of passengers."}]', '[]', 'in6');
  PERFORM pg_temp.flush();
  -- Ananya: welcome sent, never replied (follow-up due tomorrow); the last message failed once
  PERFORM public.svc_wa_status('[{"wamid": "wamid.q4", "status": "delivered"}]');
END $$;
