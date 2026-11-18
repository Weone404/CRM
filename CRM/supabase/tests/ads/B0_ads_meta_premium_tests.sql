-- 114: premium audience (PM01-PM08). Runs after A9_.
RESET ROLE;
UPDATE public.ads_meta_persona SET enabled = true WHERE key = 'parent';
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE bp5 AS SELECT public.api_ads_meta_funnel_blueprint(5000, '{"prospecting": 70, "retarget": 20, "reengage": 10}') v;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'stages') = 1 AND v->'stages'->0->>'stage' = 'prospecting'
    AND abs((v->'stages'->0->>'daily')::numeric - 164.47) < 0.02 AND (v->'stages'->0->>'share')::numeric = 100
    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v->'notes') n WHERE n LIKE '%under ₹100 a day%' AND n LIKE '%₹30,400%') FROM bp5),
  'PM01 ₹5,000 a month: shares under ₹100 a day fold into one new-people ad set, with the budget a full funnel needs');
SELECT pg_temp.ok((SELECT v ? 'folded' AND (v->'stages'->0->>'daily')::numeric > 1900
    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v->'notes') n WHERE n LIKE '%audience is still too small%') AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v->'notes') n WHERE n LIKE '%full funnel needs%')
    FROM (SELECT public.api_ads_meta_funnel_blueprint(60000, '{}') v) z),
  'PM01b with enough budget, a warm pool that can only take ₹54 a day is folded and the note blames the pool, not the budget');
RESET ROLE;
SELECT pg_temp.ok((SELECT (crm_private.ads_meta_goal_clean('{"objective": "leads", "monthly_budget": 60000, "courses": ["CPL"]}')->>'premium')::boolean
    AND NOT (crm_private.ads_meta_goal_clean('{"objective": "leads", "monthly_budget": 60000, "courses": ["CPL"], "premium": false}')->>'premium')::boolean),
  'PM02 premium audience is on unless the goal switches it off');

CREATE TEMP TABLE pm AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 60000, "premium": true}',
  '{"title": "t", "summary": "s",
    "forms": [{"key": "f1", "questions": [{"type": "FULL_NAME"}, {"type": "PHONE"}, {"type": "CUSTOM", "label": "When do you want to start?"}]}],
    "campaigns": [{"key": "c1", "adsets": [
      {"key": "a1", "daily_budget": 150, "ads": ["p1"], "audience": {"funnel": "prospecting", "age_min": 25, "locations": [{"type": "zip", "name": "110021"}]}},
      {"key": "a2", "daily_budget": 150, "ads": ["s1"], "audience": {"funnel": "prospecting", "age_min": 18, "income": ["6002714898572"], "locations": [{"type": "zip", "name": "11002"}]}}]}],
    "creatives": [{"key": "p1", "persona": "parent", "angle": "a", "primary_text": "Every step of the training, explained for parents."},
                  {"key": "s1", "persona": "pcm_finisher", "angle": "b", "primary_text": "From class 12 to your CPL, step by step."}]}') v;
SELECT pg_temp.ok((SELECT bool_or(x LIKE 'Form f1: add a question on how training will be funded%') AND bool_or(x LIKE 'State the training investment%')
    AND bool_or(x LIKE 'Ad set a1 shows only parent ads: set its minimum age to 35%') FROM pm, jsonb_array_elements_text(v) x),
  'PM03 premium filter: the funding question, the stated fee and parent-only ad sets aged 35+ are required');
SELECT pg_temp.ok((SELECT bool_or(x LIKE 'Ad set a1 uses PIN codes, but Meta has not confirmed%') AND bool_or(x LIKE 'Ad set a2: income option "6002714898572" is not one Meta offers%')
    AND bool_or(x LIKE 'Ad set a2: locations need a name and a type (country, region, city, or zip%') FROM pm, jsonb_array_elements_text(v) x),
  'PM04 PIN codes and income only when Meta confirmed them; PIN codes are 6 digits');
UPDATE public.ads_config SET value = '{"zip": {"ok": true, "sample": "IN:110021"}, "income": {"ok": true, "options": [{"id": "6002714898572", "name": "Top 10%", "type": "income"}]}}' WHERE key = 'meta_targeting_support';
CREATE TEMP TABLE pm2 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 60000}',
  '{"title": "t", "summary": "s",
    "forms": [{"key": "f1", "questions": [{"type": "FULL_NAME"}, {"type": "PHONE"}, {"type": "CUSTOM", "label": "How do you plan to fund the training?", "options": ["Family funded", "Education loan", "Still exploring"]}]}],
    "campaigns": [{"key": "c1", "adsets": [
      {"key": "a1", "daily_budget": 200, "ads": ["p1"], "audience": {"funnel": "prospecting", "age_min": 38, "locations": [{"type": "city", "name": "Delhi"}]}},
      {"key": "a2", "daily_budget": 200, "ads": ["s1"], "audience": {"funnel": "prospecting", "age_min": 18, "income": ["6002714898572"], "locations": [{"type": "zip", "name": "110021"}]}}]}],
    "creatives": [{"key": "p1", "persona": "parent", "angle": "a", "primary_text": "CPL training costs about ₹45-55 lakh in all; here is every step."},
                  {"key": "s1", "persona": "pcm_finisher", "angle": "b", "primary_text": "From class 12 to your CPL, step by step."}]}') v;
SELECT pg_temp.ok((SELECT NOT bool_or(x ~ '(funded|training investment|Speak to parents|minimum age to 35|PIN code|income option|locations need)') FROM pm2, jsonb_array_elements_text(v) x),
  'PM05 a plan with the funding question, a stated fee, a 38+ parent ad set and confirmed PIN codes / income passes the premium checks');
CREATE TEMP TABLE pm3 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 5000, "funnel": {"split": {"prospecting": 70, "retarget": 20, "reengage": 10}}}',
  '{"title": "t", "summary": "s", "campaigns": [{"key": "c1", "adsets": [{"key": "a1", "daily_budget": 164, "ads": ["s1"],
     "audience": {"funnel": "prospecting", "age_min": 18, "locations": [{"type": "zip", "name": "110021"}]}}]}],
    "creatives": [{"key": "s1", "persona": "pcm_finisher", "angle": "b", "primary_text": "From class 12 to your CPL, step by step."}]}') v;
SELECT pg_temp.ok((SELECT NOT bool_or(x LIKE 'The goal splits%') AND bool_or(x LIKE 'Ad set a1: PIN-code ad sets are a test for budgets of ₹300%') FROM pm3, jsonb_array_elements_text(v) x),
  'PM06 a ₹5,000 plan with one new-people ad set is not sent back for the funnel split; PIN codes wait for ₹300 a day');
SET ROLE service_role;
SELECT public.svc_ads_meta_targeting_save('{"zip": {"ok": false, "detail": "no results"}}');
RESET ROLE;
SELECT pg_temp.ok((SELECT (value::jsonb->'zip'->>'ok')::boolean = false AND value::jsonb ? 'checked_at' FROM public.ads_config WHERE key = 'meta_targeting_support'),
  'PM07 what Meta offers is saved by the sync job with the time it was checked');
CREATE TEMP TABLE ex AS SELECT public.svc_ads_meta_strategy_extra() v;
GRANT SELECT ON ex TO PUBLIC;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'premium'->'metros') = 10 AND jsonb_array_length(v->'premium'->'rules') = 5 AND v ? 'personas' AND v ? 'funnel_90d' FROM ex)
    AND (SELECT jsonb_array_length(public.api_ads_meta_targeting()->'metros') = 10),
  'PM08 agents get the metro preset, what Meta offers and the premium rules on top of the 109 context; viewers see the preset');
RESET ROLE;
\echo ALL ADS META 114 TESTS PASSED
