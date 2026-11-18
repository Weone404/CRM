-- 104: Meta Ads > Strategy. Goal checks (SG01-03), the agent chain (SG04-12), plan checks (SG13-14), owner actions
-- (SG15-18), Create in Meta (SG19-21), plan vs actual (SG22-24), lead archive (SG25-29), speed-to-lead (SG30-35).
-- Runs after A2_ (uses A0_'s pg_temp helpers, A2_'s Meta account and campaigns 7001 / 7002).
RESET ROLE;
CREATE OR REPLACE FUNCTION pg_temp.goal() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"objective": "admissions", "target_per_month": 10, "monthly_budget": 31000, "courses": ["CPL", "DGCA Ground Classes"],
           "locations": ["Delhi NCR"], "months": 1, "lead_to_admission_pct": 2, "privacy_url": "https://weoneaviation.in/privacy-policy", "premium": false}'::jsonb $$;
CREATE OR REPLACE FUNCTION pg_temp.plan(p_daily numeric DEFAULT 500) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'title', 'CPL admissions, Delhi NCR', 'summary', 'Two lead-form ad sets, higher-intent form, test then scale.',
    'goal', jsonb_build_object('objective', 'admissions', 'monthly_target', 10, 'kpi', 'cost per qualified lead'),
    'budget', jsonb_build_object('monthly_total', round(p_daily * 2 * 30.4), 'daily_total', p_daily * 2,
      'phases', jsonb_build_array(jsonb_build_object('name', 'Test', 'days', '1-14', 'daily', p_daily * 2, 'focus', 'find the winner'))),
    'campaigns', jsonb_build_array(jsonb_build_object('key', 'c1', 'name', 'WOA | Leads | CPL', 'objective', 'OUTCOME_LEADS', 'budget_level', 'adset',
      'adsets', jsonb_build_array(
        jsonb_build_object('key', 'a1', 'name', 'Delhi NCR 18-24', 'daily_budget', p_daily, 'optimization', 'LEAD_GENERATION',
          'audience', jsonb_build_object('locations', '[{"name": "Delhi", "type": "city", "radius_km": 40}]'::jsonb, 'age_min', 18, 'age_max', 24,
            'genders', 'all', 'interests', '["Aviation"]'::jsonb, 'advantage_audience', false),
          'placements', 'advantage', 'form', 'f1', 'ads', '["v1", "i1"]'::jsonb),
        jsonb_build_object('key', 'a2', 'name', 'India broad', 'daily_budget', p_daily, 'optimization', 'LEAD_GENERATION',
          'audience', jsonb_build_object('locations', '[{"name": "India", "type": "country"}]'::jsonb, 'age_min', 18, 'age_max', 65,
            'genders', 'all', 'interests', '[]'::jsonb, 'advantage_audience', true),
          'placements', '["instagram_reels", "facebook_feed"]'::jsonb, 'form', 'f1', 'ads', '["v1"]'::jsonb)))),
    'forms', jsonb_build_array(jsonb_build_object('key', 'f1', 'name', 'CPL enquiry', 'type', 'higher_intent', 'headline', 'Talk to a counsellor',
      'intro', 'Tell us where you are in your pilot journey.',
      'questions', '[{"type": "FULL_NAME"}, {"type": "PHONE"}, {"type": "CITY"}, {"type": "CUSTOM", "label": "Have you finished class 12 with Physics and Maths?", "options": ["Yes", "Studying now", "No"]}]'::jsonb,
      'thank_you', jsonb_build_object('title', 'Thanks', 'body', 'A counsellor will call you.', 'button_text', 'Visit website'))),
    'creatives', jsonb_build_array(
      jsonb_build_object('key', 'v1', 'name', 'Reel: a day at ground classes', 'format', 'video', 'angle', 'day in the life',
        'primary_text', 'See what a day of DGCA ground classes looks like in Dwarka.', 'headline', 'DGCA ground classes', 'description', 'Dwarka, New Delhi',
        'cta', 'LEARN_MORE', 'visual_brief', '20 s vertical video of a class', 'why', 'video won in history'),
      jsonb_build_object('key', 'i1', 'name', 'Image: steps to CPL', 'format', 'image', 'angle', 'clarity',
        'primary_text', 'Five steps from class 12 to a Commercial Pilot Licence, explained by our counsellors.', 'headline', 'Your path to a CPL',
        'description', '', 'cta', 'SIGN_UP', 'visual_brief', 'Clean infographic of five steps', 'why', 'answers the first question')),
    'forecast', jsonb_build_object('horizon_days', 30,
      'assumptions', '[{"name": "Cost per lead", "value": "₹40-75", "source": "history"}, {"name": "Qualified share", "value": "35%", "source": "benchmark"}, {"name": "Lead to admission", "value": "2%", "source": "owner"}]'::jsonb,
      'scenarios', jsonb_build_object(
        'low', jsonb_build_object('spend', 30000, 'leads', 400, 'cpl', 75, 'qualified', 120, 'admissions', 6),
        'likely', jsonb_build_object('spend', 30000, 'leads', 600, 'cpl', 50, 'qualified', 200, 'admissions', 12),
        'high', jsonb_build_object('spend', 30000, 'leads', 750, 'cpl', 40, 'qualified', 260, 'admissions', 15)),
      'math', '30000 / 50 = 600 leads'),
    'rules', '[{"when": "an ad set spends 3x the target cost with no lead", "then": "pause it"}, {"when": "cost per qualified lead is 20% under target for 7 days", "then": "raise its budget by 20%"}]'::jsonb,
    'timeline', '[{"when": "Week 1-2", "what": "test"}, {"when": "Week 3-4", "what": "scale the winner"}]'::jsonb,
    'measurement', '["CRM qualified rate per ad"]'::jsonb, 'risks', '["Learning phase"]'::jsonb, 'patterns_used', '["Lead forms ₹39 per lead"]'::jsonb,
    'sources', '[{"title": "Meta Business Help", "url": "https://www.facebook.com/business/help"}]'::jsonb) $$;
CREATE OR REPLACE FUNCTION pg_temp.next_meta() RETURNS jsonb LANGUAGE sql AS $$ SELECT public.svc_ads_agent_next2(true) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
UPDATE public.ads_agent_runs SET status = 'done' WHERE status IN ('queued', 'running');   -- earlier tests' leftovers
INSERT INTO public.ads_config (key, value) VALUES ('meta_page_id', '100521046017357')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- ---------------------------------------------------------------- goal
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_create('{"objective": "admissions", "monthly_budget": 30000}')$q$, '%at least one course%', 'SG01 a goal needs a course');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_create('{"courses": ["CPL"], "monthly_budget": 500}')$q$, '%at least ₹3,000%', 'SG01b a tiny budget limit is refused');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_create('{"courses": ["CPL"], "privacy_url": "http://x.in", "monthly_budget": 9000}')$q$, '%https%', 'SG01c the privacy policy must be https');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_create(pg_temp.goal())$q$, '%Admin%', 'SG02 only Admin starts a strategy');
SELECT pg_temp.as_('a');
SELECT public.api_ads_meta_strategy_create(pg_temp.goal());
RESET ROLE;
CREATE OR REPLACE FUNCTION pg_temp.sid() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT max(id) FROM public.ads_meta_strategy $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SELECT pg_temp.ok((SELECT status = 'working' AND version = 0 AND goal->>'start_date' IS NOT NULL AND goal->'languages' @> '["Hinglish"]'
    AND title LIKE 'Admissions · CPL, DGCA Ground Classes%' FROM public.ads_meta_strategy WHERE id = pg_temp.sid())
  AND (SELECT count(*) = 1 FROM public.ads_agent_runs WHERE role = 'meta_researcher' AND status = 'queued' AND (input->>'strategy_id')::bigint = pg_temp.sid()),
  'SG03 a new strategy is cleaned, titled and handed to the Researcher');

-- ---------------------------------------------------------------- chain
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agent_next2(false) IS NULL, 'SG04 a helper without the Meta roles never gets a Meta step');
CREATE TEMP TABLE j AS SELECT pg_temp.next_meta() AS v;
SELECT pg_temp.ok((SELECT v->'run'->>'role' = 'meta_researcher' AND v->'context'->'goal'->>'objective' = 'admissions'
    AND v->'context'->'insights' ? 'board' AND jsonb_typeof(v->'context'->'history_by_month') = 'array'
    AND v->'context'->'page'->>'page_id' = '100521046017357' AND v->'context' ? 'lead_archive' AND NOT (v->'context' ? 'snapshot') FROM j),
  'SG05 the Researcher gets the goal, 37-month insights, history by month, the Page and the archive (no Google data)');
SELECT pg_temp.ok((SELECT working_note LIKE 'Researcher%' FROM public.ads_meta_strategy WHERE id = pg_temp.sid()), 'SG05b the strategy shows who is working');
RESET ROLE;
INSERT INTO public.ads_agent_runs (role, job, status) VALUES ('researcher', 'sg06', 'done');
SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_meta_agent_finish((SELECT max(id) FROM public.ads_agent_runs WHERE job = 'sg06'), true, '{}')->>'handled')::boolean = false,
  'SG06 Google steps are left to the Google chain');
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true,
  '{"summary": "Lead forms with a qualifying question work best in Indian education.", "facts": [{"fact": "Learning phase needs about 50 results a week", "source": "https://www.facebook.com/business/help/112167992830700"}], "sources": [{"title": "Meta", "url": "https://www.facebook.com/business/help"}]}');
SELECT pg_temp.ok((SELECT input->'research'->>'summary' LIKE 'Lead forms%' AND attempt = 1 FROM public.ads_agent_runs
    WHERE role = 'meta_strategist' AND status = 'queued'), 'SG07 the Strategist is queued with the research');
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
-- a plan that breaks the checks goes back to the Strategist with the problems
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true,
  jsonb_build_object('plan', pg_temp.plan() - 'forms', 'answer', 'first try'));
SELECT pg_temp.ok((SELECT attempt = 2 AND input->>'from' = 'code checks' AND jsonb_array_length(input->'fix_these') > 0
    AND input->'previous_answer'->>'answer' = 'first try' AND input->'research' ? 'summary'
    FROM public.ads_agent_runs WHERE role = 'meta_strategist' AND status = 'queued'), 'SG08 code checks send a broken plan back with the problems');
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true,
  jsonb_build_object('plan', pg_temp.plan(), 'answer', 'Two ad sets, one form.', 'changes', '[]'::jsonb));
SELECT pg_temp.ok((SELECT attempt = 2 AND input->'strategist'->'plan'->>'title' = 'CPL admissions, Delhi NCR'
    FROM public.ads_agent_runs WHERE role = 'meta_reviewer' AND status = 'queued'), 'SG09 a clean plan goes to the Reviewer');
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true,
  '{"verdict": "reject", "problems": ["The likely cost per lead ignores the 2026 rise"]}');
SELECT pg_temp.ok((SELECT attempt = 3 AND input->>'from' = 'reviewer' AND input->'fix_these'->>0 LIKE 'The likely%'
    FROM public.ads_agent_runs WHERE role = 'meta_strategist' AND status = 'queued'), 'SG10 the Reviewer''s objections go back to the Strategist');
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true,
  jsonb_build_object('plan', pg_temp.plan(), 'answer', 'Fixed the cost per lead.', 'changes', '["Cost per lead now uses 2026 numbers"]'::jsonb));
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true, '{"verdict": "approve", "notes": "Numbers add up."}');
RESET ROLE;
SELECT pg_temp.ok((SELECT s.status = 'ready' AND s.version = 1 AND s.title = 'CPL admissions, Delhi NCR' AND s.working_note IS NULL
    AND v.review->>'verdict' = 'approve' AND v.answer = 'Fixed the cost per lead.' AND v.changes->>0 LIKE 'Cost per lead%'
    AND v.research->>'summary' LIKE 'Lead forms%' AND v.request = ''
    FROM public.ads_meta_strategy s JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id AND v.version = 1 WHERE s.id = pg_temp.sid()),
  'SG11 an approved plan becomes version 1, ready for the owner, with research, answer and changes');
-- a third failed review: the plan is kept but marked for the owner's own review (tested through the code-check path)
SELECT crm_private.ads_meta_queue(pg_temp.sid(), 'meta_strategist', 3, '{"request": "x"}');
UPDATE public.ads_meta_strategy SET status = 'working', resume_status = 'ready' WHERE id = pg_temp.sid();
SET ROLE service_role;
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), true, jsonb_build_object('plan', pg_temp.plan(5000)));
RESET ROLE;
SELECT pg_temp.ok((SELECT s.status = 'needs_review' AND s.version = 2 AND v.review->>'verdict' = 'not_approved' AND v.review->>'by' = 'code checks'
    AND v.review->'problems'->>0 LIKE '%limit is ₹31000%'
    FROM public.ads_meta_strategy s JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id AND v.version = 2 WHERE s.id = pg_temp.sid()),
  'SG12 after 3 tries the plan is kept as "needs review" with the problems shown');

-- ---------------------------------------------------------------- plan checks
SELECT pg_temp.ok((SELECT bool_and(x) FROM (VALUES
    (crm_private.ads_meta_plan_check(pg_temp.goal(), pg_temp.plan()) = '[]'::jsonb),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{creatives,0,headline}', '"The best pilot school"'))->>0 LIKE '%banned claim ("best")%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{campaigns,0,adsets,0,optimization}', '"QUALITY_LEAD"'))->>0 LIKE '%about 200 Meta leads a month%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{forecast,scenarios,likely,cpl}', '90'))->>0 LIKE '%spend ÷ leads is ₹50%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{campaigns,0,adsets,0,audience,age_min}', '16'))->>0 LIKE '%18 or more%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{campaigns,0,adsets,1,ads}', '["zz"]'))->>0 LIKE '%"zz" is not a creative key%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{forms,0,questions}', '[{"type": "FULL_NAME"}, {"type": "EMAIL"}]'))->>0 LIKE '%phone number%'),
    (crm_private.ads_meta_plan_check(pg_temp.goal(), jsonb_set(pg_temp.plan(), '{budget,monthly_total}', '60000'))->>0 LIKE '%Daily budgets add up%')) t(x)),
  'SG13 code checks catch banned claims, early QUALITY_LEAD, wrong maths, minors, missing keys, no phone and budget mismatches');
SELECT pg_temp.ok(crm_private.ads_meta_plan_check(pg_temp.goal() - 'monthly_budget', pg_temp.plan(5000))::text NOT LIKE '%limit%',
  'SG14 with no budget limit only the plan''s own numbers are checked');

-- ---------------------------------------------------------------- owner actions
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_meta_strategy_change(pg_temp.sid(), 'Only Delhi NCR, and add a Hindi creative');
RESET ROLE;
SELECT pg_temp.ok((SELECT s.status = 'working' AND s.resume_status = 'needs_review' FROM public.ads_meta_strategy s WHERE s.id = pg_temp.sid())
  AND (SELECT (input->>'base_version')::int = 2 AND input->>'request' LIKE 'Only Delhi%' AND input ? 'research'
         FROM public.ads_agent_runs WHERE role = 'meta_strategist' AND status = 'queued'),
  'SG15 a change request goes straight to the Strategist with the latest version and its research');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_change(pg_temp.sid(), 'again')$q$, '%still working%', 'SG15b one change at a time');
RESET ROLE; SET ROLE service_role;
DELETE FROM j; INSERT INTO j SELECT pg_temp.next_meta();
SELECT pg_temp.ok((SELECT v->'context'->'current_plan'->>'version' = '2' AND v->'context'->'current_plan'->'plan' ? 'campaigns' FROM j),
  'SG16 the Strategist sees the version it is changing');
SELECT public.svc_ads_meta_agent_finish((SELECT (v->'run'->>'id')::bigint FROM j), false, NULL, NULL, 'Claude stopped');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'needs_review' AND working_note LIKE 'The agents could not finish: Claude stopped%' AND version = 2
    FROM public.ads_meta_strategy WHERE id = pg_temp.sid()), 'SG17 a failed change leaves the strategy as it was, with the reason');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_meta_strategy_approve(pg_temp.sid(), 1);
SELECT pg_temp.ok((SELECT r->'strategy'->>'status' = 'approved' AND (r->'strategy'->>'approved_version')::int = 1
    AND jsonb_array_length(r->'versions') = 2 AND r->'current'->>'version' = '1' AND jsonb_array_length(r->'chain') > 3
    AND r->'since_start'->'planned' ? 'spend' AND (r->>'can_build')::boolean
    FROM public.api_ads_meta_strategy(pg_temp.sid(), 1) r), 'SG18 the owner approves a version; the page shows versions, the chain and plan vs actual');
SELECT pg_temp.ok((SELECT (r->'items'->0->>'approved_version')::int = 1 AND r->'items'->0->'likely'->>'leads' = '600' AND (r->>'runs_left')::int >= 0
    FROM public.api_ads_meta_strategies() r), 'SG18b the list shows the approved plan''s likely result');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_ads_meta_strategies()->'items'->0->>'id')::bigint = pg_temp.sid(), 'SG18c viewers can read strategies');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_approve(pg_temp.sid(), 1)$q$, '%Admin%', 'SG18d viewers cannot approve');

-- ---------------------------------------------------------------- Create in Meta
SELECT pg_temp.as_('a');
SELECT public.api_ads_meta_strategy_build(pg_temp.sid());
RESET ROLE; SET ROLE service_role;
DELETE FROM j; INSERT INTO j SELECT public.svc_ads_meta_build_work(pg_temp.sid());
SELECT pg_temp.ok((SELECT v->>'account_id' = '564511644492586' AND v->>'page_id' = '100521046017357' AND (v->>'version')::int = 1
    AND v->'plan'->>'title' = 'CPL admissions, Delhi NCR' AND v->'goal'->>'privacy_url' LIKE 'https://%' FROM j),
  'SG19 Create in Meta hands ads-sync the approved plan, the account and the Page');
SELECT public.svc_ads_meta_build_step(pg_temp.sid(), 'campaign:c1', '{"id": "120200000000001", "status": "done"}');
SELECT public.svc_ads_meta_build_image(pg_temp.sid(), 'i1', 'abc123hash', 'steps.png');
SELECT public.svc_ads_meta_build_end(pg_temp.sid(), 'partial', '1 ad needs a picture');
RESET ROLE;
SELECT pg_temp.ok((SELECT build->>'status' = 'partial' AND build->'steps'->'campaign:c1'->>'id' = '120200000000001' AND build->'images'->'i1'->>'hash' = 'abc123hash'
    AND crm_private.ads_meta_strategy_campaigns(s) = ARRAY['120200000000001'] FROM public.ads_meta_strategy s WHERE id = pg_temp.sid()),
  'SG20 each step is saved as it happens, so a retry never makes a second copy');
UPDATE public.ads_meta_strategy SET approved_version = 2 WHERE id = pg_temp.sid();
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_build(pg_temp.sid())$q$, '%Version 1 was already created%', 'SG21 a different version is never built on top of one already in Meta');
RESET ROLE;
UPDATE public.ads_meta_strategy SET approved_version = 1 WHERE id = pg_temp.sid();

-- ---------------------------------------------------------------- plan vs actual
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_link(pg_temp.sid(), '{"c1": "abc"}')$q$, '%Not a Meta campaign id%', 'SG22 links must be Meta campaign ids');
SELECT public.api_ads_meta_strategy_link(pg_temp.sid(), '{"c1": "7001"}');
RESET ROLE;
UPDATE public.ads_meta_strategy SET goal = goal || jsonb_build_object('start_date', (current_date - 30)::text), build = '{}' WHERE id = pg_temp.sid();
SET ROLE service_role;
SELECT public.svc_ads_meta_ad_days_save(pg_temp.acct(), (SELECT jsonb_agg(jsonb_build_object('ad_ext', '9001', 'adset_ext', '8001', 'campaign_ext', '7001',
    'day', (date_trunc('week', current_date - 7)::date + g)::text, 'spend', 1000, 'impressions', 8000, 'clicks', 80, 'leads', 2)) FROM generate_series(0, 6) g));
SELECT pg_temp.ok((public.svc_ads_meta_strategy_track()->>'checked')::int = 1, 'SG23 the weekly check runs for approved strategies with linked campaigns');
RESET ROLE;
SELECT pg_temp.ok((SELECT k.verdict = 'behind' AND (k.data->'actual'->>'meta_leads')::int = 14 AND (k.data->'planned'->>'leads')::numeric = 140
    FROM public.ads_meta_strategy_check k WHERE k.strategy_id = pg_temp.sid())
  AND (SELECT status = 'working' AND resume_status = 'approved' AND last_auto_at IS NOT NULL FROM public.ads_meta_strategy WHERE id = pg_temp.sid())
  AND (SELECT (input->>'auto')::boolean AND input->>'request' LIKE 'Plan vs actual%' FROM public.ads_agent_runs WHERE role = 'meta_strategist' AND status = 'queued'),
  'SG24 a plan that falls behind gets a revision drafted for the owner (the approved version stays)');
SET ROLE service_role;
SELECT public.svc_ads_meta_strategy_track();
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_agent_runs WHERE role = 'meta_strategist' AND status = 'queued'),
  'SG24b at most one drafted revision in 14 days');
UPDATE public.ads_agent_runs SET status = 'done' WHERE role LIKE 'meta\_%' AND status = 'queued';
UPDATE public.ads_meta_strategy SET status = 'approved', resume_status = NULL WHERE id = pg_temp.sid();

-- ---------------------------------------------------------------- lead archive
SELECT pg_temp.ok((SELECT count(*) >= 3 FROM public.ads_meta_lead_archive WHERE source = 'crm' AND is_organic)
  AND (SELECT answers->>'city' = 'Delhi' AND phone_e164 = '+919811400001' AND crm_lead_id IS NOT NULL
         FROM public.ads_meta_lead_archive WHERE external_id = '2000000000000002'),
  'SG25 every Meta lead the CRM files is copied to the archive, with its answers');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.ads_meta_lead_archive WHERE external_id = '2000000000000001'), 'SG25b test leads are not archived');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT r->>'added' = '2' AND r->>'skipped' = '1' AND r->>'matched' = '1' FROM public.api_ads_meta_leads_import(
    '[{"id": "l:3000000000000001", "created_time": "2024-01-05T10:00:00+0530", "campaign_name": "Pilot Training Nov (With Audiences)", "campaign_id": "c:23850000000000001", "full_name": "x", "name": "Asha", "phone": "+91 98114 00001", "answers": {"qualification": "12th PCM"}},
      {"id": "3000000000000002", "campaign_name": "Pilot Training Nov (With Audiences)", "phone": "p:+919999900002", "email": "B@Example.com", "is_organic": "false"},
      {"id": "not-a-lead", "phone": "1"}]') r),
  'SG26 old CSV downloads import; bad rows are skipped; leads already in Leads are matched by phone');
SELECT public.api_ads_meta_leads_import('[{"id": "3000000000000002", "name": "Bina", "phone": "9999900002"}]');
RESET ROLE;
SELECT pg_temp.ok((SELECT name = 'Bina' AND email = 'b@example.com' AND phone_e164 = '+919999900002'
    AND campaign_name = 'Pilot Training Nov (With Audiences)' AND source = 'csv' FROM public.ads_meta_lead_archive WHERE external_id = '3000000000000002'), 'SG27 importing again fills gaps and never loses data');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT (r->>'imported')::int = 2 AND (r->>'total')::int >= 5 FROM public.api_ads_meta_archive() r)
  AND jsonb_array_length(public.api_ads_meta_archive_export()) >= 5, 'SG28 the archive counts and the full download');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_archive_export()$q$, '%Admin%', 'SG28b only Admin downloads contact details');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_leads_import('[]')$q$, '%Admin%', 'SG28c only Admin imports');
RESET ROLE; SET ROLE service_role;
INSERT INTO public.ads_meta_forms (form_id, name) VALUES ('777000111', 'Swept form') ON CONFLICT DO NOTHING;
SELECT pg_temp.ok((SELECT (f->>'since')::bigint < extract(epoch FROM now() - interval '88 days') FROM jsonb_array_elements(public.svc_ads_meta_reconcile_work()->'forms') f
    WHERE f->>'form_id' = '777000111'), 'SG29 a form is first read for the 89 days Meta still holds');
SELECT public.svc_ads_meta_reconciled('777000111');
SELECT pg_temp.ok((SELECT (f->>'since')::bigint > extract(epoch FROM now() - interval '49 hours') FROM jsonb_array_elements(public.svc_ads_meta_reconcile_work()->'forms') f
    WHERE f->>'form_id' = '777000111'), 'SG29b then only the last 48 hours');
RESET ROLE;

-- ---------------------------------------------------------------- speed-to-lead
UPDATE public.ads_config SET value = '00:00' WHERE key = 'lead_alert_from';
UPDATE public.ads_config SET value = '23:59' WHERE key = 'lead_alert_to';
UPDATE public.ads_config SET value = (now() - interval '1 day')::text WHERE key = 'lead_alert_since';
UPDATE public.ads_lead SET first_response_at = coalesce(first_response_at, created_at) WHERE first_response_at IS NULL;
UPDATE public.employee SET email = 'admin@example.com' WHERE id = '00000000-0000-0000-0000-00000000000a';
INSERT INTO public.amazon_push_subs (employee_id, endpoint, p256dh, auth) VALUES ('00000000-0000-0000-0000-00000000000a', 'https://push.example/1', 'k', 'a')
ON CONFLICT DO NOTHING;
INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, stage, created_at, owner_employee_id)
VALUES ('5a000000-0000-0000-0000-000000000001', 'pilot_training', 'Ravi Kumar', '+919811455501', 'lead_created', now() - interval '7 minutes', '00000000-0000-0000-0000-00000000000c'),
       ('5a000000-0000-0000-0000-000000000002', 'pilot_training', 'Old Lead', '+919811455502', 'lead_created', now() - interval '2 days', NULL);
SELECT pg_temp.ok(crm_private.ads_lead_alerts_due(), 'SG30 a lead waiting 7 minutes is due for an alert');
SET ROLE service_role;
DELETE FROM j; INSERT INTO j SELECT public.svc_ads_lead_alerts_claim();
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'alerts') = 1 AND v->'alerts'->0->>'level' = '1' AND v->'alerts'->0->>'first_name' = 'Ravi'
    AND v->'alerts'->0->'emails' = '[]'::jsonb AND NOT (v->'mail'->>'ready')::boolean FROM j),
  'SG31 the first alert goes to the lead''s owner only; leads from before alerts were on never alert');
SELECT public.svc_ads_lead_alerts_done('[{"lead_id": "5a000000-0000-0000-0000-000000000001", "level": 1, "sent": {"push": 0}}]');
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_lead_alerts_claim()->'alerts') = 0, 'SG32 each alert is sent once');
RESET ROLE;
UPDATE public.ads_lead SET created_at = now() - interval '20 minutes' WHERE id = '5a000000-0000-0000-0000-000000000001';
SET ROLE service_role;
DELETE FROM j; INSERT INTO j SELECT public.svc_ads_lead_alerts_claim();
SELECT pg_temp.ok((SELECT v->'alerts'->0->>'level' = '2' AND v->'alerts'->0->'emails' ? 'admin@example.com'
    AND jsonb_array_length(v->'alerts'->0->'subs') = 1 FROM j), 'SG33 after 15 minutes Admin is alerted too (phone and email)');
RESET ROLE;
UPDATE public.ads_lead SET first_response_at = now() WHERE id = '5a000000-0000-0000-0000-000000000001';
SELECT pg_temp.ok(NOT crm_private.ads_lead_alerts_due(), 'SG34 a called lead stops alerting');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_alerts_save('{"on": true, "minutes": 10, "escalate_minutes": 5, "from": "09:00", "to": "20:00"}')$q$,
  '%after the first alert%', 'SG35 the Admin alert must come after the first');
SELECT pg_temp.ok((SELECT r->'settings'->>'minutes' = '10' AND r->'settings'->>'from' = '09:30' AND (r->'last_7d'->>'alerts')::int = 2
    FROM public.api_ads_lead_alerts_save('{"on": true, "minutes": 10, "escalate_minutes": 30, "from": "09:30", "to": "19:00"}') r),
  'SG35b alert settings are saved and the last week is counted');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_alerts_save('{"on": false, "minutes": 5, "escalate_minutes": 15, "from": "09:00", "to": "20:00"}')$q$, '%Admin%', 'SG35c only Admin changes alerts');
RESET ROLE;
SELECT pg_temp.ok(crm_private.ads_lead_alert_start('2026-11-17 22:00:00+05:30') > '2026-11-17 22:00:00+05:30'::timestamptz,
  'SG36 a lead after working hours waits for the next morning''s clock');
\echo ALL ADS META 104 TESTS PASSED
