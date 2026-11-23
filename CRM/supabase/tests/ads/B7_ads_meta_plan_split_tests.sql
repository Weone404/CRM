-- 130: plan check for a CPL / NIOS budget split (PS01-PS03). Runs after B6_.
RESET ROLE;
CREATE TEMP TABLE ps_plan AS SELECT '{"budget": {"monthly_total": 3000},
  "campaigns": [{"key": "c1", "name": "Split campaign", "objective": "OUTCOME_LEADS", "budget_level": "adset",
    "adsets": [{"key": "a2", "name": "CPL ads", "daily_budget": 70}, {"key": "a3", "name": "NIOS ads", "daily_budget": 30}]}]}'::jsonb p;
CREATE TEMP TABLE ps1 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 3000}', p) r FROM ps_plan;
SELECT pg_temp.ok((SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r) m WHERE m LIKE 'Ad set %: budget of at least ₹100%' OR m LIKE 'Daily budgets add up%') FROM ps1),
  'PS01 (130) ₹70 / ₹30 ad sets that make ₹100 a day together pass the budget rules');
CREATE TEMP TABLE ps2 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 3000}',
  jsonb_set(p, '{campaigns,0,adsets,1,daily_budget}', '20')) r FROM ps_plan;
SELECT pg_temp.ok((SELECT r @> '["Ad set a2: budget of at least ₹100 a day.", "Ad set a3: budget of at least ₹100 a day."]' FROM ps2),
  'PS02 a side under the split minimum (₹20) or a total under ₹100 is still refused');
CREATE TEMP TABLE ps3 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 3000}',
  jsonb_set(p, '{campaigns,0,adsets}', '[{"key": "a2", "name": "CPL ads", "daily_budget": 70}]')) r FROM ps_plan;
SELECT pg_temp.ok((SELECT r @> '["Ad set a2: budget of at least ₹100 a day."]' FROM ps3), 'PS03 a single ad set under ₹100 a day is still refused');
CREATE TEMP TABLE ps4 AS SELECT crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 3000, "premium": true}',
  p || '{"creatives": [{"key": "v1", "primary_text": "Pilot after 12th"}], "forms": [{"key": "f2", "questions": [{"type": "CUSTOM", "label": "Class 12 status?"}]}]}') r,
  crm_private.ads_meta_plan_check('{"objective": "leads", "monthly_budget": 3000, "premium": true}',
  p || '{"fee_line": "owner_declined", "creatives": [{"key": "v1", "primary_text": "Pilot after 12th"}], "forms": [{"key": "f2", "questions": [{"type": "CUSTOM", "label": "Class 12 status?"}]}]}') r2
  FROM ps_plan;
SELECT pg_temp.ok((SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r) m WHERE m LIKE 'State the training investment%')
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r2) m WHERE m LIKE 'State the training investment%')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(r2) m WHERE m LIKE 'Form f2: add a question on how training will be funded%') FROM ps4),
  'PS04 fee_line owner_declined drops only the fee-wording rule; the funding question is still required');
\echo ALL ADS META 130 TESTS PASSED
