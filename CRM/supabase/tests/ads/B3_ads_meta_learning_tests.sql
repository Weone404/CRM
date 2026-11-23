-- 124: the Meta learning loop (LL01-LL06). Runs after B2_ (its 'Live test' strategy, form 777100, ads 9101/9102).
RESET ROLE;
UPDATE public.ads_meta_strategy_version v SET plan = plan || '{"forms": [{"key": "f1", "questions": [{"type": "FULL_NAME"}, {"type": "PHONE"}, {"type": "CITY"},
    {"type": "CUSTOM", "label": "Who is filling this form?", "options": ["Student (18+)", "Parent / guardian"]},
    {"type": "CUSTOM", "label": "Class 12 status?", "options": ["Passed with Physics & Maths", "Passed with other subjects"]}]}]}'::jsonb
 WHERE strategy_id = (SELECT id FROM public.ads_meta_strategy WHERE title = 'Live test');
SELECT pg_temp.ok((SELECT jsonb_agg(x->>'a' ORDER BY x->>'a') FROM jsonb_array_elements(crm_private.ads_meta_answer_text('777100',
    '{"q1": "q1o2", "q2": "q2o1", "city": "Indirapuram Ghaziabad", "phone_number": "+91999"}')) x)
    = '["Indirapuram Ghaziabad", "Parent / guardian", "Passed with Physics & Maths"]'::jsonb
  AND (SELECT bool_or(x->>'q' = 'Who is filling this form?') FROM jsonb_array_elements(crm_private.ads_meta_answer_text('777100', '{"q1": "q1o2"}')) x),
  'LL01 coded form answers (q1o2) read back as the question and option text; phone never shown');
SELECT pg_temp.ok(crm_private.ads_meta_answer_text('999', '{"q1": "q1o1"}') = '[{"q": "Q1", "a": "q1o1"}]'::jsonb, 'LL02 an unknown form keeps the raw answer');
INSERT INTO public.ads_enquiry (received_at, idempotency_key, pipeline, channel, name, phone_raw, phone_e164, touch, quality, quality_reasons, dedup_result, ads_lead_id, result, payload_extra)
SELECT now(), 'b3-enq-1', 'pilot_training', 'ads', 'Meena K', '+919811400121', '+919811400121', '{"form_id": "777100"}', 'ok', '{}', 'new_contact', '5b000000-0000-0000-0000-000000000121', '{"status": "created"}',
       '{"meta_answers": {"q1": "q1o2", "q2": "q2o1", "city": "Delhi"}}'
WHERE NOT EXISTS (SELECT 1 FROM public.ads_enquiry WHERE idempotency_key = 'b3-enq-1');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE lv124 AS SELECT public.api_ads_meta_live() v;
RESET ROLE;
SELECT pg_temp.ok((SELECT bool_or(l->>'name' = 'Meena K' AND l->'answers' @> '[{"a": "Parent / guardian"}]' AND l->'answers' @> '[{"a": "Delhi"}]')
    FROM lv124, jsonb_array_elements(v->'campaigns') c, jsonb_array_elements(c->'latest') l), 'LL03 Overview shows what each lead answered, in words');
SELECT pg_temp.ok((SELECT (t->'ads'->0->>'spend')::numeric = 180 AND (t->'ads'->0->>'cost_per_1000_views')::numeric = 44 AND jsonb_array_length(t->'leads') = 2
    AND t->'leads'->0->'answers' @> '[{"a": "Parent / guardian"}]' AND (t->'leads'->0->>'called')::boolean
    FROM (SELECT crm_private.ads_meta_last_test((SELECT id FROM public.ads_meta_strategy WHERE title = 'Live test')) t) z),
  'LL04 the Strategist sees the running test per ad (spend, cost per 1,000 views) and each lead (answers, called)');
INSERT INTO public.ads_meta_lesson (lesson, evidence, source) VALUES ('Owner: target all of India, not only Delhi NCR.', '23 Nov 2026', 'owner');
INSERT INTO public.ads_agent_runs (account_id, role, job, attempt, input, status)
VALUES (pg_temp.acct(), 'meta_strategist', 'meta_strategy', 1, jsonb_build_object('strategy_id', (SELECT id FROM public.ads_meta_strategy WHERE title = 'Live test')), 'running');
UPDATE public.ads_agent_runs SET status = 'done', output = '{"lessons": [{"lesson": "Judge a creative only after it has spent 500 rupees.", "evidence": "3 days, 4 leads"},
  {"lesson": "x"}]}' WHERE id = (SELECT max(id) FROM public.ads_agent_runs);
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.ads_meta_lesson WHERE active) AND EXISTS (SELECT 1 FROM public.ads_meta_lesson WHERE source = 'strategist' AND evidence = '3 days, 4 leads'),
  'LL05 the Strategist''s lessons from a test are kept (too-short ones ignored) next to the owner''s');
SELECT pg_temp.ok((SELECT c->'lessons' @> '[{"source": "owner"}]' AND c ? 'last_test' FROM (SELECT crm_private.ads_meta_agent_ctx(r) c FROM public.ads_agent_runs r WHERE id = (SELECT max(id) FROM public.ads_agent_runs)) z),
  'LL06 every Strategist and Reviewer run reads the lessons and the last test');
\echo ALL ADS META 124 TESTS PASSED
