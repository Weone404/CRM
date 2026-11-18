-- 116 Growth > Content: CT01-CT14. Each check prints PASS <name>; the first failure stops the run.
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
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
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Approver', 'IT', '10000000-0000-0000-0000-00000000000d');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES ('00000000-0000-0000-0000-00000000000c', false), ('00000000-0000-0000-0000-00000000000d', true);
-- data the Demand Analyst reads
SET ROLE service_role;
SELECT public.svc_web_save('gsc', ARRAY['query'], '[
  {"kind": "query", "k1": "cpl fees in india", "win": "cur", "m": {"clicks": 9, "impressions": 900, "ctr": 0.01, "position": 12}},
  {"kind": "query", "k1": "how to become pilot after 12th", "win": "cur", "m": {"clicks": 20, "impressions": 2500, "ctr": 0.008, "position": 7}},
  {"kind": "query", "k1": "how to become pilot after 12th", "win": "prev", "m": {"clicks": 5, "impressions": 2000, "ctr": 0.002, "position": 13}}]');
RESET ROLE;
INSERT INTO public.ads_meta_lead_archive (external_id, source, created_time, answers, name, phone_e164)
  SELECT '9000' || g, 'crm', now() - interval '3 days', '{"how_do_you_plan_to_fund_the_training?": "education_loan", "full_name": "x"}', 'n', '+919999999999' FROM generate_series(1, 3) g;
INSERT INTO public.lead (name, utm_campaign, created_at) VALUES ('A', NULL, now());

SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT v->'plan' = 'null'::jsonb AND NOT (v->>'can_edit')::boolean AND jsonb_array_length(v->'items') = 0 FROM (SELECT public.api_content_overview() v) z),
  'CT01 viewers see the Content tab (no plan yet) but cannot change it');
SELECT pg_temp.fails($q$SELECT public.api_content_plan(current_date + 7)$q$, '%approvers%', 'CT01b only approvers plan content');
RESET ROLE; SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_content_plan(current_date - 14)$q$, '%over%', 'CT02 a past week cannot be planned');
CREATE TEMP TABLE pl AS SELECT (public.api_content_plan(current_date + 7, 'Push CPL fees this week')->>'plan_id')::bigint id; GRANT SELECT ON pl TO PUBLIC;
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'working' AND note = 'Push CPL fees this week' AND extract(isodow FROM week_start) = 1 FROM public.content_plan WHERE id = (SELECT id FROM pl))
    AND (SELECT count(*) = 1 FROM public.ads_agent_runs WHERE role = 'meta_content_analyst' AND status = 'queued'),
  'CT02b planning a week queues the Demand Analyst on the agents'' queue (weeks start on Monday)');

SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agent_next2(false) IS NULL OR public.svc_ads_agent_next2(false)->'run'->>'role' NOT LIKE 'meta_content%', 'CT03 an older helper is never handed content steps');
CREATE TEMP TABLE j1 AS SELECT public.svc_ads_agent_next2(true) v; GRANT SELECT ON j1 TO PUBLIC;
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'meta_content_analyst'
    AND jsonb_array_length(v->'context'->'demand_data'->'google_searches'->'top') = 2
    AND v->'context'->'demand_data'->'google_searches'->'questions'->0->>'query' = 'how to become pilot after 12th'
    AND v->'context'->'demand_data'->'lead_form_answers'->0->'answers'->0->>'answer' = 'education_loan'
    AND NOT (v->'context'->'demand_data'->'lead_form_answers')::text LIKE '%full_name%'
    AND jsonb_array_length(v->'context'->'demand_data'->'personas') >= 6 AND jsonb_array_length(v->'context'->'demand_data'->'competitors') = 2
    AND v->'context'->>'owner_note' = 'Push CPL fees this week' FROM j1),
  'CT03b the Demand Analyst gets searches, lead answers (no names or phones), personas, competitors and the owner''s note');
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j1), true,
  '{"summary": "Fees and the after-12th path lead", "demand": [{"topic": "CPL cost broken down", "why": "900 searches", "priority": 1}]}');
CREATE TEMP TABLE j2 AS SELECT public.svc_ads_agent_next2(true) v; GRANT SELECT ON j2 TO PUBLIC;
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'meta_content_planner' AND v->'context'->'analyst'->>'summary' = 'Fees and the after-12th path lead' FROM j2)
    AND (SELECT demand->>'summary' = 'Fees and the after-12th path lead' FROM public.content_plan WHERE id = (SELECT id FROM pl)),
  'CT04 the brief is saved and the Content Planner gets it');
-- a bad week is sent back with the reasons
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j2), true, jsonb_build_object('answer', 'x', 'items', jsonb_build_array(
  jsonb_build_object('kind', 'reel', 'day', (SELECT week_start FROM public.content_plan WHERE id = (SELECT id FROM pl)), 'title', 'Guaranteed job after CPL', 'hook', 'You will get a job, guaranteed job', 'evidence', '[{"signal": "search"}]'::jsonb),
  jsonb_build_object('kind', 'reel', 'day', (SELECT week_start FROM public.content_plan WHERE id = (SELECT id FROM pl)), 'title', 'Second reel same day', 'hook', 'Another opening line here', 'evidence', '[{"signal": "search"}]'::jsonb),
  jsonb_build_object('kind', 'story', 'day', '2020-01-01', 'title', 'Bad', 'hook', 'x', 'evidence', '[]'::jsonb))));
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'rejected' AND error LIKE '%kind must be reel or carousel%' AND error LIKE '%day must be a date in the week%' AND error LIKE '%give the evidence%'
      AND error LIKE '%At most one reel and one carousel a day%' FROM public.ads_agent_runs WHERE id = (SELECT (v->'run'->>'id')::bigint FROM j2))
    AND (SELECT count(*) = 1 FROM public.ads_agent_runs WHERE role = 'meta_content_planner' AND status = 'queued' AND input ? 'fix_these'),
  'CT05 a week that breaks the rules goes back to the Planner with each reason');
SET ROLE service_role;
CREATE TEMP TABLE j3 AS SELECT public.svc_ads_agent_next2(true) v; GRANT SELECT ON j3 TO PUBLIC;
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j3), true, jsonb_build_object('answer', 'Fees, the path after 12th and parents first.', 'items', jsonb_build_array(
  jsonb_build_object('kind', 'reel', 'day', (SELECT week_start FROM public.content_plan WHERE id = (SELECT id FROM pl)), 'time', '13:30', 'title', 'CPL cost, line by line', 'hook', 'Where does ₹45 lakh actually go?', 'persona', 'parent', 'angle', 'cost', 'evidence', '[{"signal": "search", "detail": "cpl fees in india, 900 seen"}]'::jsonb),
  jsonb_build_object('kind', 'carousel', 'day', (SELECT week_start + 1 FROM public.content_plan WHERE id = (SELECT id FROM pl)), 'title', 'Pilot after 12th: 6 steps', 'hook', 'The whole path on one swipe', 'persona', 'pcm_finisher', 'evidence', '[{"signal": "search", "detail": "how to become pilot after 12th"}]'::jsonb),
  jsonb_build_object('kind', 'reel', 'day', (SELECT week_start + 2 FROM public.content_plan WHERE id = (SELECT id FROM pl)), 'time', '19:00', 'title', 'Funding: loan or family?', 'hook', 'Three ways families fund CPL', 'evidence', '[{"signal": "lead_answer", "detail": "education_loan x3"}]'::jsonb))));
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'ready' AND summary LIKE 'Fees, the path%' FROM public.content_plan WHERE id = (SELECT id FROM pl))
    AND (SELECT count(*) = 3 FROM public.content_item WHERE plan_id = (SELECT id FROM pl))
    AND (SELECT to_char(slot AT TIME ZONE 'Asia/Kolkata', 'HH24:MI') = '19:00' AND brief->>'hook' = 'Three ways families fund CPL' AND NOT (brief ? 'kind')
           FROM public.content_item WHERE title = 'Funding: loan or family?'),
  'CT06 a good week becomes calendar items at India time, with hook and evidence kept');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'items') = 3 AND v->'plan'->>'status' = 'ready' AND (v->'items'->0->>'link') LIKE 'https://weoneaviation.in/?utm_source=instagram&utm_medium=reel&utm_campaign=content_%'
    FROM (SELECT public.api_content_overview(current_date + 7) v) z),
  'CT06b the week shows its items, each with its own tracked link');
RESET ROLE;
CREATE TEMP TABLE ids AS SELECT title, id FROM public.content_item; GRANT SELECT ON ids TO PUBLIC;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT public.api_content_item_save(jsonb_build_object('action', 'skip', 'id', (SELECT id FROM ids WHERE title = 'Pilot after 12th: 6 steps')));
SELECT public.api_content_item_save(jsonb_build_object('id', (SELECT id FROM ids WHERE title = 'CPL cost, line by line'), 'hook', 'Where does the money go?'));
SELECT public.api_content_item_save(jsonb_build_object('action', 'add', 'kind', 'reel', 'title', 'Campus tour in 30 seconds', 'slot', (now() + interval '3 days')::text));
SELECT pg_temp.fails($q$SELECT public.api_content_item_save('{"action": "add", "kind": "reel", "title": "Old", "slot": "2020-01-01T10:00+05:30"}')$q$, '%5-120%', 'CT07 a manual idea needs a real topic');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'skipped' FROM public.content_item WHERE title = 'Pilot after 12th: 6 steps')
    AND (SELECT brief->>'hook' = 'Where does the money go?' FROM public.content_item WHERE title = 'CPL cost, line by line')
    AND (SELECT source = 'manual' AND status = 'planned' FROM public.content_item WHERE title = 'Campus tour in 30 seconds'),
  'CT07b approvers skip, edit and add items');

-- ad creatives from an approved strategy
INSERT INTO public.ads_meta_strategy (id, title, status, goal, version, approved_version) VALUES (77, 'Test', 'approved', '{}', 1, 1);
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) VALUES (77, 1, '{"creatives": [
  {"key": "i1", "name": "Cost card", "format": "image", "headline": "CPL cost", "primary_text": "₹45-55 lakh, step by step", "visual_brief": "Clean card with the 5 cost blocks", "persona": "parent"},
  {"key": "v1", "name": "Day in training", "format": "video", "headline": "A day at ground school", "primary_text": "See a full day", "visual_brief": "Vertical walk-through"},
  {"key": "c1", "name": "Carousel", "format": "carousel", "headline": "x", "primary_text": "y", "visual_brief": "z"}]}');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT public.api_content_from_strategy(77); SELECT public.api_content_from_strategy(77);
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.content_item WHERE strategy_id = 77)
    AND (SELECT brief->'sizes' = '["1080x1350", "1080x1920"]' AND brief->>'visual_brief' LIKE 'Clean card%' FROM public.content_item WHERE strategy_id = 77 AND kind = 'ad_image'),
  'CT08 an approved strategy orders one picture per image ad and one video per video ad, once (carousels stay in Ads Manager)');

-- Reel Studio's side
SET ROLE service_role;
CREATE TEMP TABLE n1 AS SELECT public.svc_content_next() v; GRANT SELECT ON n1 TO PUBLIC;
CREATE TEMP TABLE n2 AS SELECT public.svc_content_next() v; GRANT SELECT ON n2 TO PUBLIC;
CREATE TEMP TABLE n3 AS SELECT public.svc_content_next() v; GRANT SELECT ON n3 TO PUBLIC;
RESET ROLE;
SELECT pg_temp.ok((SELECT v->>'kind' LIKE 'ad\_%' FROM n1) AND (SELECT v->>'kind' LIKE 'ad\_%' FROM n2)
    AND (SELECT v IS NULL OR v->>'kind' NOT LIKE 'ad\_%' FROM n3)
    AND (SELECT status = 'queued' FROM public.content_item WHERE id = (SELECT (v->>'id')::bigint FROM n1))
    AND (SELECT v->'brand_facts' IS NOT NULL AND v ? 'banned_claims' FROM n1)
    AND crm_private.ads_cfg('content_studio_seen') IS NOT NULL,
  'CT09 Reel Studio gets ad pictures first, then posts due within 36 hours; each is claimed once and its visit is recorded');
UPDATE public.content_item SET slot = now() + interval '5 hours' WHERE title = 'CPL cost, line by line';
SET ROLE service_role;
CREATE TEMP TABLE n4 AS SELECT public.svc_content_next() v; GRANT SELECT ON n4 TO PUBLIC;
SELECT public.svc_content_update((SELECT (v->>'id')::bigint FROM n4), '{"status": "producing", "studio_job": "job-123"}');
SELECT public.svc_content_update((SELECT (v->>'id')::bigint FROM n4), jsonb_build_object('status', 'posted', 'posted_at', now()::text,
  'media', '{"permalink": "https://www.instagram.com/reel/abc/"}'::jsonb, 'stats', '{"views": 1200, "shares": 30}'::jsonb));
SELECT public.svc_content_update((SELECT id FROM public.content_item WHERE title = 'Pilot after 12th: 6 steps'), '{"status": "producing"}');
RESET ROLE;
INSERT INTO public.lead (name, utm_campaign) VALUES ('B', 'content_' || (SELECT v->>'id' FROM n4));
SELECT pg_temp.ok((SELECT v->>'title' = 'CPL cost, line by line' AND v->>'link' LIKE '%content_%' FROM n4)
    AND (SELECT status = 'posted' AND studio_job = 'job-123' AND media->>'permalink' LIKE 'https://www.instagram.com/%' AND (stats->>'views')::int = 1200
           FROM public.content_item WHERE title = 'CPL cost, line by line')
    AND (SELECT status = 'skipped' FROM public.content_item WHERE title = 'Pilot after 12th: 6 steps')
    AND (SELECT crm_private.content_leads(id) = 1 FROM public.content_item WHERE title = 'CPL cost, line by line'),
  'CT10 Reel Studio reports producing, posted, the post link and results; a skipped item is not brought back; enquiries are counted by its link');
SET ROLE service_role;
SELECT pg_temp.ok((SELECT v->'demand'->>'summary' = 'Fees and the after-12th path lead' AND v->'best'->0->>'title' = 'CPL cost, line by line' FROM (SELECT public.svc_content_signals() v) z),
  'CT10b Reel Studio''s Strategist reads the demand brief and what worked best');
RESET ROLE;
CREATE TEMP TABLE adi AS SELECT id FROM public.content_item WHERE strategy_id = 77 AND kind = 'ad_image'; GRANT SELECT ON adi TO PUBLIC;
SET ROLE service_role;
SELECT public.svc_content_picture((SELECT id FROM adi), '1080x1350', 'ad/' || (SELECT id FROM adi) || '/1080x1350.png');
SELECT pg_temp.ok((SELECT status = 'queued' FROM public.content_item WHERE id = (SELECT id FROM adi))
    AND (public.svc_content_picture((SELECT id FROM adi), '1080x1920', '../../etc/passwd')->>'ok')::boolean = false, 'CT10c one of two sizes is not ready yet; odd paths are refused');
SELECT public.svc_content_picture((SELECT id FROM adi), '1080x1920', 'ad/' || (SELECT id FROM adi) || '/1080x1920.jpg');
RESET ROLE; SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT x->>'status' = 'ready' AND (x->>'has_picture')::boolean AND x->'paths' ? '1080x1920' FROM (SELECT public.api_content_overview() v) z, jsonb_array_elements(v->'ad_creatives') x WHERE x->>'kind' = 'ad_image'),
  'CT10d with both sizes the ad picture is ready in Content > Ad creatives');
RESET ROLE; CREATE TEMP TABLE tk AS SELECT decrypted_secret t FROM vault.decrypted_secrets WHERE name = 'crm_reelstudio_token'; GRANT SELECT ON tk TO PUBLIC; SET ROLE service_role;
SELECT pg_temp.ok(public.svc_content_token_ok((SELECT t FROM tk)) AND NOT public.svc_content_token_ok('x') AND NOT public.svc_content_token_ok(NULL),
  'CT11 the Reel Studio token is checked against the Vault');
RESET ROLE; SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((public.api_connections())::jsonb ? 'reelstudio' AND public.api_vault_overview()->'inbound' ? 'reelstudio' AND public.api_vault_overview()->'inbound' ? 'charter',
  'CT11b Admin sees the Reel Studio token with the other inbound tokens (value only through the audited reveal)');
RESET ROLE;
-- Google / Meta steps still go to their own handlers
INSERT INTO public.ads_agent_runs (role, job, status, input) VALUES ('researcher', 'x', 'running', '{}');
SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_meta_agent_finish((SELECT max(id) FROM public.ads_agent_runs WHERE role = 'researcher'), true, '{}')->>'handled')::boolean = false,
  'CT12 other agents'' steps are passed through unchanged');
RESET ROLE;
SELECT crm_private.content_week_tick(); SELECT crm_private.content_week_tick();
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.content_plan WHERE week_start = (date_trunc('week', (now() AT TIME ZONE 'Asia/Kolkata')::date) + interval '7 days')::date),
  'CT13 the Sunday clock plans next week once');
SELECT pg_temp.ok(NOT has_function_privilege('anon', 'public.api_content_overview(date)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.svc_content_next()', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'public.content_item', 'SELECT'), 'CT14 not callable without signing in; data and Reel Studio functions are private');
SELECT 'ALL CONTENT SQL CHECKS PASSED';
