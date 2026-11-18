-- 109: lookalikes (LK01-02), personas (PS01-03), funnel plan (BP01-02), goal (GC01-02), plan checks (PC01-03). Runs after A7_.
RESET ROLE; SET ROLE service_role;
CREATE TEMP TABLE lk AS SELECT public.svc_ads_meta_audience_work() v;
SELECT pg_temp.ok((SELECT count(*) = 4 FROM lk, jsonb_array_elements(v->'audiences') x WHERE x->>'kind' = 'lookalike')
  AND (SELECT x->'seed'->>'meta_id' = '23850000000001' AND (x->'seed'->>'size_low')::int = 1000 AND x->'spec'->>'country' = 'IN'
         FROM lk, jsonb_array_elements(v->'audiences') x WHERE x->>'key' = 'lal_customers_1')
  AND (SELECT min(i) FROM lk, jsonb_array_elements(v->'audiences') WITH ORDINALITY z(x, i) WHERE x->>'kind' = 'lookalike')
    > (SELECT max(i) FROM lk, jsonb_array_elements(v->'audiences') WITH ORDINALITY z(x, i) WHERE x->>'kind' <> 'lookalike'),
  'LK01 lookalikes go to the audience job after their seeds, with the seed''s Meta id and size');
SELECT public.svc_ads_meta_audience_saved('lal_hot_1', '{"status": "planned", "detail": "The seed has about 0 matched people; Meta needs at least 100"}');
SELECT public.svc_ads_meta_audience_saved('lal_customers_1', '{"meta_id": "23850000000099", "status": "ready", "size_low": 4000000, "size_high": 4700000}');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'planned' AND detail LIKE '%needs at least 100%' FROM public.ads_meta_audience WHERE key = 'lal_hot_1')
  AND (SELECT status = 'ready' AND stage = 'cold' AND use_as = 'prospect' FROM public.ads_meta_audience WHERE key = 'lal_customers_1'),
  'LK02 a lookalike waits (planned) until its seed has 100+ people, then is ready as a new-people hint');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE ps AS SELECT public.api_ads_meta_personas() v;
SELECT pg_temp.ok((SELECT jsonb_array_length(v) = 6 FROM ps)
  AND (SELECT bool_or(x->>'key' = 'parent' AND x->'search' @> '[{"topic": "Fees and cost"}]') FROM ps, jsonb_array_elements(v) x),
  'PS01 six personas, each with the Google searches its people make');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_persona_save('{"key": "x1", "name": "Test"}')$q$, '%Admin%', 'PS02 only Admin edits personas');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_persona_save('{"key": "x1", "name": "Test", "stages": ["awareness"]}')$q$, '%prospecting, retarget or reengage%', 'PS02b stages are checked');
SELECT public.api_ads_meta_persona_save('{"key": "nri_parent", "name": "NRI parent", "who": "Parent abroad", "angles": ["Train in India"], "stages": ["retarget"]}');
SELECT public.api_ads_meta_persona_save('{"key": "parent", "name": "Parent funding the decision", "enabled": false}');
RESET ROLE;
SELECT pg_temp.ok((SELECT name = 'NRI parent' AND angles = '["Train in India"]' FROM public.ads_meta_persona WHERE key = 'nri_parent')
  AND (SELECT NOT enabled AND jsonb_array_length(objections) = 3 FROM public.ads_meta_persona WHERE key = 'parent'),
  'PS03 Admin adds a persona and switches one off (unsent lists stay as they were)');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bp AS SELECT public.api_ads_meta_funnel_blueprint(60000, '{"prospecting": 70, "retarget": 20, "reengage": 10}') v;
SELECT pg_temp.ok((SELECT (v->>'daily')::numeric = 1973.68 AND abs((SELECT sum((s->>'daily')::numeric) FROM jsonb_array_elements(v->'stages') s) - 1973.68) < 1
    AND (v->'stages'->0->>'stage') = 'prospecting' AND (v->'stages'->0->>'share')::numeric >= 70
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'stages') s WHERE s->>'stage' = 'reengage')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v->'notes') n WHERE n LIKE 'No re-engage list is ready%')
    AND (v->'stages'->0->'include') ? 'lal_customers_1' AND (v->'stages'->0->'exclude') ? 'crm_customers'
    AND (v->'stages'->0->>'learning') IS NOT NULL FROM bp),
  'BP01 the funnel plan splits the budget, moves what a pool cannot take to new people, names audiences, exclusions and a learning check');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_funnel_blueprint(60000, '{"prospecting": 70, "retarget": 40}')$q$, '%add up to 100%', 'BP02 the split must add up to 100');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_funnel_blueprint(1000, '{}')$q$, '%at least ₹3,000%', 'BP02b at least ₹3,000 a month');
RESET ROLE;
SELECT pg_temp.ok((SELECT g->'funnel'->'split' = '{"prospecting": 60, "retarget": 30, "reengage": 10}' AND g->'personas' = '["pcm_finisher"]'
    FROM (SELECT crm_private.ads_meta_goal_clean('{"objective": "admissions", "monthly_budget": "60000", "courses": ["CPL"],
      "funnel": {"split": {"prospecting": 60, "retarget": 30, "reengage": 10}}, "personas": ["pcm_finisher", "parent", "nobody"]}') g) z),
  'GC01 the goal keeps the funnel split and only known, switched-on personas');
SELECT pg_temp.fails($q$SELECT crm_private.ads_meta_goal_clean('{"objective": "leads", "monthly_budget": "60000", "courses": ["CPL"], "funnel": {"split": {"prospecting": 90, "retarget": 20}}}')$q$,
  '%add up to 100%', 'GC02 a funnel split that does not add up is refused');
CREATE TEMP TABLE pc AS SELECT crm_private.ads_meta_plan_check(
  '{"objective": "leads", "monthly_budget": 60000, "funnel": {"split": {"prospecting": 70, "retarget": 20, "reengage": 10}}, "personas": ["pcm_finisher", "career_switcher"]}',
  '{"title": "t", "summary": "s",
    "campaigns": [{"key": "c1", "adsets": [
      {"key": "a1", "daily_budget": 1000, "audience": {"funnel": "prospecting", "advantage_audience": false, "include_audiences": ["lal_customers_1"], "exclude_audiences": ["no_such"]}},
      {"key": "a2", "daily_budget": 1000, "audience": {"funnel": "retarget"}},
      {"key": "a3", "daily_budget": 100, "audience": {"funnel": "awareness"}}]}],
    "creatives": [
      {"key": "v1", "angle": "path", "persona": "pcm_finisher", "primary_text": "Finished class 12 with PCM? See the five steps from DGCA ground classes to your CPL with We One Aviation in Dwarka.", "headline": "Your CPL path in 5 steps"},
      {"key": "v2", "angle": "path", "persona": "pcm_finisher", "primary_text": "Finished class 12 with PCM? See the five steps from DGCA ground classes to your CPL with We One Aviation in Dwarka today.", "headline": "Your CPL path in 5 steps"},
      {"key": "v3", "angle": "Path", "persona": "ghost", "primary_text": "Parents: here is every cost, in order.", "headline": "Cost, step by step"},
      {"key": "v4", "angle": "cost", "primary_text": "Visit the classroom before you decide.", "headline": "Come and see"}]}') v;
SELECT pg_temp.ok((SELECT bool_or(x LIKE 'Creatives v1 and v2 are near copies%') AND bool_or(x LIKE '4 creatives but only 2 distinct angles%')
    AND bool_or(x LIKE 'Creative v3: persona "ghost"%') AND bool_or(x LIKE 'The goal asks for persona career_switcher%') FROM pc, jsonb_array_elements_text(v) x),
  'PC01 near-copy creatives, too few angles, unknown personas and uncovered goal personas are sent back');
SELECT pg_temp.ok((SELECT bool_or(x LIKE 'Ad set a1 finds new people but includes audiences without Advantage+%') AND bool_or(x LIKE 'Ad set a1: audience "no_such"%')
    AND bool_or(x LIKE 'Ad set a2 is retarget but names no audience%') AND bool_or(x LIKE 'Ad set a3: funnel must be%') FROM pc, jsonb_array_elements_text(v) x),
  'PC02 seeds as hard limits on new-people ad sets, unknown audiences, retargeting without an audience and bad stages are sent back');
SELECT pg_temp.ok((SELECT bool_or(x LIKE 'The goal splits 70% to prospecting but the plan gives it%') FROM pc, jsonb_array_elements_text(v) x)
  AND (SELECT bool_or(x LIKE 'Creative v1: format must be%') FROM pc, jsonb_array_elements_text(v) x),
  'PC03 the funnel split must hold within 10 points; the original checks still run');
\echo ALL ADS META 109 TESTS PASSED
