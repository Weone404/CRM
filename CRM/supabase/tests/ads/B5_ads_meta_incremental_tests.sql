-- 128: Create in Meta for a newer approved version, on top of the one already running (IB01-IB07).
-- Runs after B4_: B2_'s 'Live test' strategy is built at version 1 (form:f1 777100, campaign:c1 7101, adset:a1 8101,
-- ads 9101 / 9102, the Instagram post of v1). Version 2 is plan v5's shape: same campaign c1, new ad set a2 for all of
-- India with the new call-button form f2, ads v1 (its post reused) and v5 (new).
RESET ROLE;
CREATE TEMP TABLE ib_s AS SELECT id FROM public.ads_meta_strategy WHERE title = 'Live test';
GRANT SELECT ON ib_s TO PUBLIC;
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) SELECT id, 2,
  '{"title": "Live test v2", "budget": {"daily_total": 100, "monthly_total": 3000},
    "campaigns": [{"key": "c1", "name": "CPL leads India", "objective": "OUTCOME_LEADS", "budget_level": "adset",
      "adsets": [{"key": "a2", "name": "India", "daily_budget": 100, "form": "f2", "ads": ["v1", "v5"],
                  "audience": {"locations": [{"name": "India", "type": "country"}], "age_min": 18, "age_max": 65, "advantage_audience": true}}]}],
    "forms": [{"key": "f2", "name": "CPL call", "type": "higher_intent", "questions": [{"type": "FULL_NAME"}, {"type": "PHONE"},
      {"type": "CUSTOM", "label": "Who is filling this form?", "options": ["Student (18+)", "Parent / guardian"]},
      {"type": "CUSTOM", "label": "Class 12 status?", "options": ["Passed with Physics & Maths", "Passed with other subjects", "Currently in class 12", "Graduate"]}],
      "thank_you": {"title": "Thank you", "button_type": "CALL_BUSINESS", "phone": "+919355566991"}}],
    "creatives": [{"key": "v1", "format": "video", "headline": "Pilot after 12th"}, {"key": "v5", "format": "video", "headline": "PCM nahi li?"}]}'
  FROM ib_s ON CONFLICT DO NOTHING;
UPDATE public.ads_meta_strategy SET approved_version = 2, version = 2, status = 'approved' WHERE id = (SELECT id FROM ib_s);
INSERT INTO public.ads_meta_object (account_id, level, external_id, campaign_ext, name, status)
SELECT pg_temp.acct(), 'adset', '8101', '7101', 'Delhi + 40 km', 'ACTIVE' WHERE NOT EXISTS (SELECT 1 FROM public.ads_meta_object WHERE level = 'adset' AND external_id = '8101');
INSERT INTO public.ads_config (key, value) VALUES ('meta_page_id', '100521046017357') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
DELETE FROM public.ads_meta_action WHERE object_id = '8101';

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_build((SELECT id FROM ib_s))$q$, '%Admin%', 'IB01 only Admin can create a new version in Meta');
SELECT pg_temp.as_('a');
CREATE TEMP TABLE ib1 AS SELECT public.api_ads_meta_strategy_build((SELECT id FROM ib_s)) r;
RESET ROLE;
SELECT pg_temp.ok((SELECT (r->>'incremental')::boolean AND (r->>'base_version')::int = 1 AND r->'reused' = '["campaign:c1"]'
      AND r->'retired' @> '["form:f1", "adset:a1", "ad:a1:v1", "ad:a1:v2"]' FROM ib1)
    AND (SELECT build->>'status' = 'queued' AND (build->>'version')::int = 2 AND (build->>'base_version')::int = 1
      AND build->'steps'->'campaign:c1'->>'id' = '7101' AND build->'steps'->'ad:a1:v1'->>'id' = '9101'
      AND build->'posts'->'v1'->>'permalink' IS NOT NULL FROM public.ads_meta_strategy WHERE id = (SELECT id FROM ib_s)),
  'IB02 a newer approved version is queued on top: campaign c1 reused, the old steps and v1''s post kept, the dropped ones listed');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(a.level = 'adset' AND a.kind = 'pause' AND a.status = 'pending' AND a.expires_at > now() + interval '13 days'
      AND a.reason LIKE '%version 2 replaces this ad set (a1 from version 1)%') FROM public.ads_meta_action a WHERE a.object_id = '8101')
    AND NOT EXISTS (SELECT 1 FROM public.ads_meta_action WHERE object_id IN ('9101', '9102', '7101'))
    AND (SELECT (build->'pause_requests'->0->>'action_id')::bigint = (SELECT id FROM public.ads_meta_action WHERE object_id = '8101')
      FROM public.ads_meta_strategy WHERE id = (SELECT id FROM ib_s)),
  'IB03 the old ad set is not paused: a pause request waits for approval (14 days); the campaign and ads get none');
SET ROLE service_role;
CREATE TEMP TABLE ib2 AS SELECT public.svc_ads_meta_build_work((SELECT id FROM ib_s)) w;
RESET ROLE;
SELECT pg_temp.ok((SELECT (w->>'version')::int = 2 AND w->'plan'->>'title' = 'Live test v2' AND w->'steps'->'campaign:c1'->>'id' = '7101' FROM ib2)
    AND crm_private.ads_meta_plan_keys((SELECT plan FROM public.ads_meta_strategy_version WHERE strategy_id = (SELECT id FROM ib_s) AND version = 2))
      = ARRAY['ad:a2:v1', 'ad:a2:v5', 'adset:a2', 'campaign:c1', 'creative:v1:f2', 'creative:v5:f2', 'form:f2'],
  'IB04 ads-sync gets version 2 with campaign c1''s id, so it creates only form f2, ad set a2, the creatives and ads of a2');
SELECT public.svc_ads_meta_build_step((SELECT id FROM ib_s), 'form:f2', '{"id": "888200", "status": "done"}');
SELECT public.svc_ads_meta_build_end((SELECT id FROM ib_s), 'partial', 'ad set a2 waits for a picture');
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_meta_strategy_build((SELECT id FROM ib_s));
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_meta_action WHERE object_id = '8101') AND (SELECT (build->>'base_version')::int = 1 AND build->>'status' = 'queued'
      AND build->'steps'->'form:f2'->>'id' = '888200' FROM public.ads_meta_strategy WHERE id = (SELECT id FROM ib_s)),
  'IB05 pressing it again retries the same build (no second pause request)');
SELECT pg_temp.ok((SELECT jsonb_agg(x->>'a' ORDER BY x->>'a') FROM jsonb_array_elements(crm_private.ads_meta_answer_text('777100', '{"q1": "q1o2", "q2": "q2o1"}')) x)
      = '["Parent / guardian", "Passed with Physics & Maths"]'::jsonb
    AND (SELECT bool_or(x->>'a' = 'Passed with other subjects') FROM jsonb_array_elements(crm_private.ads_meta_answer_text('888200', '{"q1": "q1o1", "q2": "q2o2"}')) x),
  'IB06 answers of the old form (f1, version 1) and the new one (f2, version 2) both read in words');
UPDATE public.ads_meta_strategy SET approved_version = 1 WHERE id = (SELECT id FROM ib_s);
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_strategy_build((SELECT id FROM ib_s))$q$, '%Version 2 was already created%', 'IB07 an older version is still never built over a newer one');
RESET ROLE;
-- leave B2_'s strategy at version 1 for the rollback checks in run.sh (126's backfill reads its form f1)
UPDATE public.ads_meta_strategy SET build = jsonb_set(build, '{version}', '1') WHERE id = (SELECT id FROM ib_s);
\echo ALL ADS META 128 TESTS PASSED
