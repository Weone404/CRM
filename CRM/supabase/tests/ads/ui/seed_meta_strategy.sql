-- UI test seed for Meta Ads > Strategy (migration 104): one plan ready for the owner, with research and a review.
INSERT INTO public.ads_meta_strategy (id, title, status, goal, version, created_at, updated_at)
VALUES (900, 'CPL admissions, Delhi NCR', 'ready',
  '{"objective": "admissions", "target_per_month": 10, "monthly_budget": 31000, "courses": ["CPL"], "locations": ["Delhi NCR"], "languages": ["English", "Hinglish"],
    "start_date": "2026-12-01", "months": 1, "pipeline": "pilot_training", "website_url": "https://weoneaviation.in", "privacy_url": "https://weoneaviation.in/privacy-policy",
    "admission_value": 250000, "notes": ""}', 1, now() - interval '1 hour', now() - interval '1 hour')
ON CONFLICT (id) DO NOTHING;
SELECT setval('public.ads_meta_strategy_id_seq', 900);
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan, changes, answer, review, research, request)
VALUES (900, 1, '{
  "title": "CPL admissions, Delhi NCR", "summary": "Two lead-form ad sets with a higher-intent form. Test for two weeks, then move money to the winner.",
  "goal": {"objective": "admissions", "monthly_target": 10, "kpi": "cost per qualified lead"},
  "budget": {"monthly_total": 30400, "daily_total": 1000, "phases": [{"name": "Test", "days": "1-14", "daily": 1000, "focus": "find the winning ad"}]},
  "campaigns": [{"key": "c1", "name": "WOA Leads CPL", "objective": "OUTCOME_LEADS", "budget_level": "adset", "reason": "Lead forms cost ₹39 a lead in 2023-24",
    "adsets": [
      {"key": "a1", "name": "Delhi NCR 18-24", "daily_budget": 500, "optimization": "LEAD_GENERATION", "placements": "advantage", "form": "f1", "ads": ["v1", "i1"],
       "audience": {"locations": [{"name": "Delhi", "type": "city", "radius_km": 40}], "age_min": 18, "age_max": 24, "genders": "all", "interests": ["Aviation"], "advantage_audience": false}},
      {"key": "a2", "name": "India broad", "daily_budget": 500, "optimization": "LEAD_GENERATION", "placements": ["instagram_reels", "facebook_feed"], "form": "f1", "ads": ["i1"],
       "audience": {"locations": [{"name": "India", "type": "country"}], "age_min": 18, "age_max": 65, "genders": "all", "interests": [], "advantage_audience": true}}]}],
  "forms": [{"key": "f1", "name": "CPL enquiry", "type": "higher_intent", "headline": "Talk to a counsellor", "intro": "Tell us where you are in your pilot journey.",
    "questions": [{"type": "FULL_NAME"}, {"type": "PHONE"}, {"type": "CUSTOM", "label": "Finished class 12 with Physics and Maths?", "options": ["Yes", "Studying now", "No"]}],
    "thank_you": {"title": "Thanks", "body": "A counsellor will call you.", "button_text": "Visit website"}}],
  "creatives": [
    {"key": "v1", "name": "Reel: a day at ground classes", "format": "video", "angle": "day in the life", "primary_text": "See a day of DGCA ground classes in Dwarka.",
     "headline": "DGCA ground classes", "description": "Dwarka, New Delhi", "cta": "LEARN_MORE", "visual_brief": "20 s vertical video of a class", "why": "video won before"},
    {"key": "i1", "name": "Image: steps to CPL", "format": "image", "angle": "clarity", "primary_text": "Five steps from class 12 to a Commercial Pilot Licence.",
     "headline": "Your path to a CPL", "description": "", "cta": "SIGN_UP", "visual_brief": "Infographic of five steps", "why": "answers the first question"}],
  "forecast": {"horizon_days": 30, "math": "30000 / 50 = 600 leads; 600 x 33% = 200 qualified; 600 x 2% = 12 admissions",
    "assumptions": [{"name": "Cost per lead", "value": "₹40-75", "source": "history", "note": "2023-24 lead forms ₹39, Feb 2026 ₹46"},
                    {"name": "Qualified share", "value": "33%", "source": "benchmark", "note": "education lead forms"},
                    {"name": "Lead to admission", "value": "2%", "source": "owner"}],
    "scenarios": {"low": {"spend": 30000, "leads": 400, "cpl": 75, "qualified": 120, "admissions": 6},
                  "likely": {"spend": 30000, "leads": 600, "cpl": 50, "qualified": 200, "admissions": 12},
                  "high": {"spend": 30000, "leads": 750, "cpl": 40, "qualified": 260, "admissions": 15}}},
  "rules": [{"when": "an ad set spends ₹150 with no lead", "then": "pause it"}, {"when": "cost per qualified lead is 20% under target for 7 days", "then": "raise its budget by 20%"}],
  "timeline": [{"when": "Week 1-2", "what": "test both ad sets"}, {"when": "Week 3-4", "what": "scale the winner"}],
  "measurement": ["CRM qualified rate per ad", "Call every lead within 5 minutes"], "risks": ["Learning phase in week 1"],
  "patterns_used": ["Lead-form campaigns ₹39 per lead vs engagement campaigns with no leads"],
  "sources": [{"title": "Meta Business Help Centre", "url": "https://www.facebook.com/business/help"}]}',
  '[]', 'Two ad sets and one higher-intent form; about 12 admissions a month is the likely case.',
  '{"verdict": "approve", "by": "reviewer", "notes": "Numbers follow the account history."}',
  '{"summary": "Lead forms with one qualifying question work best for education in India.", "facts": [{"fact": "Office in Dwarka, New Delhi", "url": "https://weoneaviation.in"}],
    "benchmarks": [{"metric": "Cost per lead, education, India", "value": "₹40-120", "note": "2025 agency data"}], "sources": [{"title": "We One Aviation", "url": "https://weoneaviation.in"}]}',
  '')
ON CONFLICT DO NOTHING;
INSERT INTO public.ads_agent_runs (role, job, status, attempt, input, summary, created_at, finished_at) VALUES
  ('meta_researcher', 'meta_strategy', 'done', 1, '{"strategy_id": 900}', 'Lead forms work best', now() - interval '50 minutes', now() - interval '45 minutes'),
  ('meta_strategist', 'meta_strategy', 'done', 1, '{"strategy_id": 900}', 'Plan written', now() - interval '44 minutes', now() - interval '40 minutes'),
  ('meta_reviewer', 'meta_strategy', 'done', 1, '{"strategy_id": 900}', 'Approved', now() - interval '39 minutes', now() - interval '38 minutes');
INSERT INTO public.ads_config (key, value) VALUES ('agents_last_seen', now()::text), ('meta_page_id', '100521046017357')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
