-- 104: Meta Ads > Strategy. Run after 103. Re-runnable. Rollback: 104_ads_meta_strategy_down.sql.
--
--  * Strategy: the owner sets a goal (what, how many, budget limit, courses, cities, start). The ADS agents work on it in
--    three steps, on the same helper that runs the Google agents (no extra cost):
--      meta_researcher (web only)  -> current Meta guidance, benchmarks, timing, competitors' public messaging, with sources
--      meta_strategist             -> the full plan (budget, structure, forms, creatives, forecast, rules, timeline)
--      meta_reviewer               -> checks numbers, budget, claims and Meta policy; up to 3 tries in all
--    Code checks run before the Reviewer (ads_meta_plan_check). Every plan is a version; changes make a new version.
--    Nothing is sent to Meta by the agents.
--  * Create in Meta: after approval, ads-sync (job meta_build) creates the approved plan in the ad account, everything
--    PAUSED; the owner reviews it in Ads Manager and switches it on there.
--  * Plan vs actual: weekly check of linked campaigns against the plan; when a plan falls behind, the Strategist drafts
--    a revision (at most once in 14 days) that waits for the owner's approval.
--  * Lead archive: every Meta lead the CRM receives is copied to ads_meta_lead_archive and kept (Meta deletes form
--    answers after 90 days); old CSV downloads can be imported; Admin can download everything. Each lead form is read
--    once for the full 89 days Meta still holds.
--  * Speed-to-lead: an ad lead with no first call after N minutes (working hours) alerts its owner, then Admin.
--    Phone notifications go to people who turned them on in the CRM; email when the CRM's business email is on.

-- ------------------------------------------------------------------------------------------- agent roles
ALTER TABLE public.ads_agent_runs DROP CONSTRAINT IF EXISTS ads_agent_runs_role_check;
ALTER TABLE public.ads_agent_runs ADD CONSTRAINT ads_agent_runs_role_check
  CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor', 'team_lead', 'tracking',
                  'meta_researcher', 'meta_strategist', 'meta_reviewer'));

-- ------------------------------------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS public.ads_meta_strategy (
  id bigserial PRIMARY KEY,
  title text NOT NULL DEFAULT 'New strategy',
  status text NOT NULL DEFAULT 'working' CHECK (status IN ('working', 'ready', 'needs_review', 'failed', 'approved', 'archived')),
  goal jsonb NOT NULL,
  version int NOT NULL DEFAULT 0,                 -- latest version
  approved_version int,
  working_note text,                              -- what the agents are doing, or why they stopped
  resume_status text,                             -- status to go back to when a change request fails
  build jsonb NOT NULL DEFAULT '{}',              -- Create in Meta: {status, version, steps{}, images{}, at, detail}
  links jsonb NOT NULL DEFAULT '{}',              -- plan campaign key -> Meta campaign id (for plan vs actual)
  last_auto_at timestamptz,                       -- last revision drafted by the weekly check
  created_by uuid, approved_by uuid, approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_strategy ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_strategy FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_strategy_id_seq FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_strategy_version (
  strategy_id bigint NOT NULL REFERENCES public.ads_meta_strategy(id) ON DELETE CASCADE,
  version int NOT NULL,
  plan jsonb NOT NULL,
  changes jsonb NOT NULL DEFAULT '[]',            -- what changed against the version before (Strategist)
  answer text,                                    -- the Strategist's note to the owner
  review jsonb NOT NULL DEFAULT '{}',             -- {verdict, problems[], notes} (Reviewer or code checks)
  research jsonb NOT NULL DEFAULT '{}',           -- the Researcher's answer: {summary, facts[], benchmarks[], timing[], competitors[], sources[], gaps[]}
  request text,                                   -- the owner's change request ('' for the first version)
  auto boolean NOT NULL DEFAULT false,            -- drafted by the weekly plan-vs-actual check
  agent_run_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (strategy_id, version));
ALTER TABLE public.ads_meta_strategy_version ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_strategy_version FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_strategy_check (
  strategy_id bigint NOT NULL REFERENCES public.ads_meta_strategy(id) ON DELETE CASCADE,
  week_start date NOT NULL,
  data jsonb NOT NULL,                            -- {planned{spend,leads,cpl}, actual{spend,meta_leads,crm_leads,qualified,customers,cpl}}
  verdict text NOT NULL CHECK (verdict IN ('on_track', 'behind', 'ahead', 'no_data')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (strategy_id, week_start));
ALTER TABLE public.ads_meta_strategy_check ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_strategy_check FROM anon, authenticated;

-- Every Meta lead, kept for good. source 'crm': copied when the CRM files it; 'csv': imported from a Meta download.
CREATE TABLE IF NOT EXISTS public.ads_meta_lead_archive (
  id bigserial PRIMARY KEY,
  external_id text NOT NULL UNIQUE,               -- Meta lead id (digits)
  source text NOT NULL CHECK (source IN ('crm', 'csv')),
  created_time timestamptz,
  ad_id text, ad_name text, adset_id text, adset_name text, campaign_id text, campaign_name text,
  form_id text, form_name text, platform text, is_organic boolean,
  name text, phone_e164 text, email text,
  answers jsonb NOT NULL DEFAULT '{}',
  crm_lead_id uuid,                               -- matching lead in Leads (by phone)
  ads_lead_id uuid,
  imported_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_meta_archive_time ON public.ads_meta_lead_archive (created_time DESC);
CREATE INDEX IF NOT EXISTS idx_ads_meta_archive_campaign ON public.ads_meta_lead_archive (campaign_id);
ALTER TABLE public.ads_meta_lead_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_lead_archive FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_lead_archive_id_seq FROM anon, authenticated;

ALTER TABLE public.ads_meta_forms ADD COLUMN IF NOT EXISTS full_swept_at timestamptz;

CREATE TABLE IF NOT EXISTS public.ads_lead_alert (
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  level int NOT NULL CHECK (level IN (1, 2)),     -- 1: owner (or the ADS team), 2: Admin
  recipients jsonb NOT NULL DEFAULT '[]',
  sent jsonb NOT NULL DEFAULT '{}',               -- {push, email, error}
  created_at timestamptz NOT NULL DEFAULT now(), done_at timestamptz,
  PRIMARY KEY (lead_id, level));
ALTER TABLE public.ads_lead_alert ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_lead_alert FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES
  ('meta_strategy_per_day', '8'),                 -- agent runs the owner can start in 24 hours (new strategies + changes)
  ('lead_alert_on', 'on'),
  ('lead_alert_minutes', '5'),
  ('lead_alert_escalate_minutes', '15'),
  ('lead_alert_from', '09:00'),                   -- working hours, India time
  ('lead_alert_to', '20:00'),
  ('lead_alert_since', now()::text)               -- leads older than this never alert (no flood when this is switched on)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------------------------------- helpers
-- The Meta ad account strategies are for: the connected one with Insights history (then the most recently working).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_acct() RETURNS public.ads_accounts
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT a.* FROM public.ads_accounts a WHERE a.platform = 'meta' AND a.status = 'connected'
   ORDER BY EXISTS (SELECT 1 FROM public.ads_meta_ad_day d WHERE d.account_id = a.id) DESC, a.last_ok_at DESC NULLS LAST, a.created_at LIMIT 1 $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_today() RETURNS date
LANGUAGE sql STABLE SET search_path = '' AS $$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_https(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(p ~ '^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[^\s<>"]*)?$' AND length(p) <= 300, false) $$;

-- The owner's goal, checked and cleaned. Raises PT422 with a plain message.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_goal_clean(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE o jsonb := '{}'; v text; n numeric; arr jsonb; x text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RAISE EXCEPTION 'Fill in the goal first' USING ERRCODE = 'PT422'; END IF;
  v := coalesce(p->>'objective', 'admissions');
  IF v NOT IN ('admissions', 'qualified', 'leads') THEN RAISE EXCEPTION 'Pick what to aim for: admissions, qualified leads or leads' USING ERRCODE = 'PT422'; END IF;
  o := o || jsonb_build_object('objective', v);
  IF coalesce(p->>'target_per_month', '') <> '' THEN
    IF p->>'target_per_month' !~ '^\d{1,5}$' OR (p->>'target_per_month')::int < 1 THEN RAISE EXCEPTION 'Target per month must be a whole number' USING ERRCODE = 'PT422'; END IF;
    o := o || jsonb_build_object('target_per_month', (p->>'target_per_month')::int);
  END IF;
  IF coalesce(p->>'monthly_budget', '') <> '' THEN
    IF p->>'monthly_budget' !~ '^\d{1,8}(\.\d{1,2})?$' THEN RAISE EXCEPTION 'Monthly budget must be a number in rupees' USING ERRCODE = 'PT422'; END IF;
    n := (p->>'monthly_budget')::numeric;
    IF n < 3000 THEN RAISE EXCEPTION 'Monthly budget limit must be at least ₹3,000' USING ERRCODE = 'PT422'; END IF;
    o := o || jsonb_build_object('monthly_budget', n);
  END IF;
  IF NOT o ? 'monthly_budget' AND NOT o ? 'target_per_month' THEN
    RAISE EXCEPTION 'Give a monthly budget limit, a target per month, or both' USING ERRCODE = 'PT422';
  END IF;
  FOREACH v IN ARRAY ARRAY['courses', 'locations', 'languages'] LOOP
    arr := '[]';
    IF jsonb_typeof(p->v) = 'array' THEN
      FOR x IN SELECT btrim(e) FROM jsonb_array_elements_text(p->v) e LOOP
        CONTINUE WHEN x = '' OR jsonb_array_length(arr) >= 12;
        arr := arr || to_jsonb(left(x, 60));
      END LOOP;
    END IF;
    o := o || jsonb_build_object(v, arr);
  END LOOP;
  IF jsonb_array_length(o->'courses') = 0 THEN RAISE EXCEPTION 'Pick at least one course' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_array_length(o->'locations') = 0 THEN o := o || jsonb_build_object('locations', '["Delhi NCR"]'::jsonb); END IF;
  IF jsonb_array_length(o->'languages') = 0 THEN o := o || jsonb_build_object('languages', '["English", "Hinglish"]'::jsonb); END IF;
  v := coalesce(nullif(p->>'start_date', ''), crm_private.ads_meta_today()::text);
  IF v !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'Start date is not a date' USING ERRCODE = 'PT422'; END IF;
  IF v::date < crm_private.ads_meta_today() - 1 OR v::date > crm_private.ads_meta_today() + 365 THEN
    RAISE EXCEPTION 'Start date must be today or within a year' USING ERRCODE = 'PT422';
  END IF;
  o := o || jsonb_build_object('start_date', v);
  v := coalesce(nullif(p->>'months', ''), '1');
  IF v !~ '^\d{1,2}$' OR v::int NOT BETWEEN 1 AND 6 THEN RAISE EXCEPTION 'Plan length is 1 to 6 months' USING ERRCODE = 'PT422'; END IF;
  o := o || jsonb_build_object('months', v::int);
  IF coalesce(p->>'lead_to_admission_pct', '') <> '' THEN
    IF p->>'lead_to_admission_pct' !~ '^\d{1,3}(\.\d{1,2})?$' OR (p->>'lead_to_admission_pct')::numeric NOT BETWEEN 0.1 AND 100 THEN
      RAISE EXCEPTION 'Leads that become admissions: a percentage between 0.1 and 100' USING ERRCODE = 'PT422';
    END IF;
    o := o || jsonb_build_object('lead_to_admission_pct', (p->>'lead_to_admission_pct')::numeric);
  END IF;
  IF coalesce(p->>'admission_value', '') <> '' THEN
    IF p->>'admission_value' !~ '^\d{1,9}(\.\d{1,2})?$' THEN RAISE EXCEPTION 'Value of one admission must be a number in rupees' USING ERRCODE = 'PT422'; END IF;
    o := o || jsonb_build_object('admission_value', (p->>'admission_value')::numeric);
  END IF;
  v := coalesce(nullif(p->>'pipeline', ''), 'pilot_training');
  IF v NOT IN ('pilot_training', 'charter') THEN RAISE EXCEPTION 'Pipeline must be pilot training or charter' USING ERRCODE = 'PT422'; END IF;
  o := o || jsonb_build_object('pipeline', v);
  v := coalesce(nullif(btrim(p->>'website_url'), ''), 'https://weoneaviation.in');
  IF NOT crm_private.ads_meta_https(v) THEN RAISE EXCEPTION 'Website must be a full https:// address' USING ERRCODE = 'PT422'; END IF;
  o := o || jsonb_build_object('website_url', v);
  v := nullif(btrim(p->>'privacy_url'), '');
  IF v IS NOT NULL AND NOT crm_private.ads_meta_https(v) THEN RAISE EXCEPTION 'Privacy policy must be a full https:// address' USING ERRCODE = 'PT422'; END IF;
  IF v IS NOT NULL THEN o := o || jsonb_build_object('privacy_url', v); END IF;
  o := o || jsonb_build_object('notes', left(coalesce(btrim(p->>'notes'), ''), 2000));
  RETURN o;
END $$;

-- Meta leads in the last 30 days (Meta's count), for the "qualified leads" goal (Meta asks for about 200 a month).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_leads_30d() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(sum(leads), 0)::int FROM public.ads_meta_ad_day WHERE day > crm_private.ads_meta_today() - 30 $$;

-- ------------------------------------------------------------------------------------------- plan checks (code)
-- Plan format (the Strategist's "plan"):
--   title, summary,
--   goal {objective, monthly_target, kpi},
--   budget {monthly_total, daily_total, phases[{name, days, daily, focus}]},
--   campaigns[{key, name, objective:"OUTCOME_LEADS", budget_level:"adset"|"campaign", daily_budget, reason,
--     adsets[{key, name, daily_budget, optimization:"LEAD_GENERATION"|"QUALITY_LEAD",
--       audience{locations[{name, type:"country"|"region"|"city", radius_km}], age_min, age_max, genders:"all"|"male"|"female",
--                interests[], advantage_audience}, placements:"advantage"|[...], form, ads[], reason}]}],
--   forms[{key, name, type:"higher_intent"|"more_volume", headline, intro, questions[{type, label, options[]}],
--          thank_you{title, body, button_text}}],
--   creatives[{key, name, format:"image"|"video"|"carousel", angle, primary_text, headline, description, cta, visual_brief, why}],
--   forecast{horizon_days, assumptions[{name, value, source:"history"|"benchmark"|"owner"|"research", note}],
--            scenarios{low|likely|high:{spend, leads, cpl, qualified, admissions}}, math},
--   rules[{when, then}], timeline[{when, what}], measurement[], risks[], patterns_used[], sources[{title, url}]
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_check(p_goal jsonb, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pr text[] := '{}'; c jsonb; a jsonb; f jsonb; q jsonb; cr jsonb; s jsonb; k text; t text;
        forms text[] := '{}'; ads text[] := '{}'; used_forms text[] := '{}'; used_ads text[] := '{}';
        daily numeric := 0; d numeric; monthly numeric; nadsets int := 0; lo numeric; li numeric; hi numeric;
        claims text[]; ph text; txt text; leads30 int;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN '["The answer has no plan object."]'::jsonb; END IF;
  IF coalesce(btrim(p->>'title'), '') = '' THEN pr := pr || 'Plan has no title.'::text; END IF;
  IF coalesce(btrim(p->>'summary'), '') = '' THEN pr := pr || 'Plan has no summary.'::text; END IF;
  SELECT coalesce(array_agg(lower(x)), '{}') INTO claims FROM jsonb_array_elements_text(coalesce(crm_private.ads_rule('g_claim_phrases')->'phrases', '[]')) x;

  -- forms
  IF jsonb_typeof(p->'forms') <> 'array' OR jsonb_array_length(p->'forms') NOT BETWEEN 1 AND 3 THEN
    pr := pr || 'Give 1 to 3 lead forms.'::text;
  ELSE
    FOR f IN SELECT * FROM jsonb_array_elements(p->'forms') LOOP
      k := coalesce(f->>'key', '');
      IF k = '' OR k = ANY (forms) THEN pr := pr || format('Every form needs its own key (form "%s").', left(coalesce(f->>'name', '?'), 40)); END IF;
      forms := forms || k;
      IF coalesce(f->>'type', '') NOT IN ('higher_intent', 'more_volume') THEN pr := pr || format('Form %s: type must be higher_intent or more_volume.', k); END IF;
      IF length(coalesce(f->>'name', '')) NOT BETWEEN 1 AND 100 THEN pr := pr || format('Form %s: name of 1-100 characters.', k); END IF;
      IF jsonb_typeof(f->'questions') <> 'array' OR jsonb_array_length(f->'questions') NOT BETWEEN 2 AND 12 THEN
        pr := pr || format('Form %s: 2 to 12 questions.', k);
      ELSE
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(f->'questions') x WHERE x->>'type' = 'PHONE') THEN pr := pr || format('Form %s: must ask for the phone number (PHONE).', k); END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(f->'questions') x WHERE x->>'type' = 'FULL_NAME') THEN pr := pr || format('Form %s: must ask for the name (FULL_NAME).', k); END IF;
        FOR q IN SELECT * FROM jsonb_array_elements(f->'questions') LOOP
          IF coalesce(q->>'type', '') NOT IN ('FULL_NAME', 'EMAIL', 'PHONE', 'CITY', 'STATE', 'CUSTOM') THEN
            pr := pr || format('Form %s: question type %s is not allowed (FULL_NAME, EMAIL, PHONE, CITY, STATE, CUSTOM).', k, coalesce(q->>'type', '?'));
          ELSIF q->>'type' = 'CUSTOM' THEN
            IF length(coalesce(q->>'label', '')) NOT BETWEEN 3 AND 80 THEN pr := pr || format('Form %s: custom question label of 3-80 characters.', k); END IF;
            IF jsonb_typeof(q->'options') = 'array' AND jsonb_array_length(q->'options') > 0
               AND (jsonb_array_length(q->'options') NOT BETWEEN 2 AND 10
                    OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(q->'options') o WHERE length(o) NOT BETWEEN 1 AND 60)) THEN
              pr := pr || format('Form %s: "%s" needs 2-10 options of up to 60 characters.', k, left(q->>'label', 40));
            END IF;
          END IF;
        END LOOP;
      END IF;
      txt := lower(concat_ws(' ', f->>'headline', f->>'intro', f->'thank_you'->>'title', f->'thank_you'->>'body'));
      FOREACH ph IN ARRAY claims LOOP
        IF position(ph IN txt) > 0 THEN pr := pr || format('Form %s uses a banned claim ("%s").', k, ph); END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- creatives
  IF jsonb_typeof(p->'creatives') <> 'array' OR jsonb_array_length(p->'creatives') NOT BETWEEN 1 AND 10 THEN
    pr := pr || 'Give 1 to 10 creatives.'::text;
  ELSE
    FOR cr IN SELECT * FROM jsonb_array_elements(p->'creatives') LOOP
      k := coalesce(cr->>'key', '');
      IF k = '' OR k = ANY (ads) THEN pr := pr || format('Every creative needs its own key (creative "%s").', left(coalesce(cr->>'name', '?'), 40)); END IF;
      ads := ads || k;
      IF coalesce(cr->>'format', '') NOT IN ('image', 'video', 'carousel') THEN pr := pr || format('Creative %s: format must be image, video or carousel.', k); END IF;
      IF length(coalesce(cr->>'primary_text', '')) NOT BETWEEN 20 AND 600 THEN pr := pr || format('Creative %s: primary text of 20-600 characters.', k); END IF;
      IF length(coalesce(cr->>'headline', '')) NOT BETWEEN 3 AND 60 THEN pr := pr || format('Creative %s: headline of 3-60 characters.', k); END IF;
      IF length(coalesce(cr->>'description', '')) > 60 THEN pr := pr || format('Creative %s: description of up to 60 characters.', k); END IF;
      IF coalesce(cr->>'cta', '') NOT IN ('APPLY_NOW', 'DOWNLOAD', 'GET_QUOTE', 'LEARN_MORE', 'SIGN_UP', 'SUBSCRIBE') THEN
        pr := pr || format('Creative %s: call to action must be APPLY_NOW, DOWNLOAD, GET_QUOTE, LEARN_MORE, SIGN_UP or SUBSCRIBE.', k);
      END IF;
      IF coalesce(btrim(cr->>'visual_brief'), '') = '' THEN pr := pr || format('Creative %s: describe the picture or video (visual_brief).', k); END IF;
      txt := lower(concat_ws(' ', cr->>'primary_text', cr->>'headline', cr->>'description'));
      FOREACH ph IN ARRAY claims LOOP
        IF position(ph IN txt) > 0 THEN pr := pr || format('Creative %s uses a banned claim ("%s").', k, ph); END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- structure and budget
  IF jsonb_typeof(p->'campaigns') <> 'array' OR jsonb_array_length(p->'campaigns') NOT BETWEEN 1 AND 4 THEN
    pr := pr || 'Give 1 to 4 campaigns.'::text;
  ELSE
    leads30 := crm_private.ads_meta_leads_30d();
    FOR c IN SELECT * FROM jsonb_array_elements(p->'campaigns') LOOP
      k := coalesce(c->>'key', '?');
      IF length(coalesce(c->>'name', '')) NOT BETWEEN 3 AND 100 THEN pr := pr || format('Campaign %s: name of 3-100 characters.', k); END IF;
      IF coalesce(c->>'objective', '') <> 'OUTCOME_LEADS' THEN pr := pr || format('Campaign %s: objective must be OUTCOME_LEADS (lead forms).', k); END IF;
      IF coalesce(c->>'budget_level', '') NOT IN ('adset', 'campaign') THEN pr := pr || format('Campaign %s: budget_level must be adset or campaign.', k); END IF;
      IF c->>'budget_level' = 'campaign' THEN
        d := CASE WHEN jsonb_typeof(c->'daily_budget') = 'number' THEN (c->>'daily_budget')::numeric END;
        IF d IS NULL OR d < 100 THEN pr := pr || format('Campaign %s: campaign budget of at least ₹100 a day.', k); ELSE daily := daily + d; END IF;
      END IF;
      IF jsonb_typeof(c->'adsets') <> 'array' OR jsonb_array_length(c->'adsets') NOT BETWEEN 1 AND 6 THEN
        pr := pr || format('Campaign %s: 1 to 6 ad sets.', k);
        CONTINUE;
      END IF;
      FOR a IN SELECT * FROM jsonb_array_elements(c->'adsets') LOOP
        nadsets := nadsets + 1;
        t := coalesce(a->>'key', '?');
        IF length(coalesce(a->>'name', '')) NOT BETWEEN 3 AND 100 THEN pr := pr || format('Ad set %s: name of 3-100 characters.', t); END IF;
        IF c->>'budget_level' = 'adset' THEN
          d := CASE WHEN jsonb_typeof(a->'daily_budget') = 'number' THEN (a->>'daily_budget')::numeric END;
          IF d IS NULL OR d < 100 THEN pr := pr || format('Ad set %s: budget of at least ₹100 a day.', t); ELSE daily := daily + d; END IF;
        END IF;
        IF coalesce(a->>'optimization', '') NOT IN ('LEAD_GENERATION', 'QUALITY_LEAD') THEN
          pr := pr || format('Ad set %s: optimization must be LEAD_GENERATION or QUALITY_LEAD.', t);
        ELSIF a->>'optimization' = 'QUALITY_LEAD' AND leads30 < 200 THEN
          pr := pr || format('Ad set %s: QUALITY_LEAD (conversion leads) needs about 200 Meta leads a month; the account had %s in the last 30 days. Use LEAD_GENERATION now and plan the switch.', t, leads30);
        END IF;
        IF coalesce(a->>'form', '') = '' OR NOT (a->>'form' = ANY (forms)) THEN pr := pr || format('Ad set %s: form must be one of the form keys.', t); END IF;
        used_forms := used_forms || coalesce(a->>'form', '');
        IF jsonb_typeof(a->'ads') <> 'array' OR jsonb_array_length(a->'ads') NOT BETWEEN 1 AND 6 THEN
          pr := pr || format('Ad set %s: 1 to 6 ads (creative keys).', t);
        ELSE
          FOR s IN SELECT * FROM jsonb_array_elements(a->'ads') LOOP
            IF NOT (s #>> '{}' = ANY (ads)) THEN pr := pr || format('Ad set %s: ad "%s" is not a creative key.', t, left(s #>> '{}', 30)); END IF;
            used_ads := used_ads || (s #>> '{}');
          END LOOP;
        END IF;
        IF jsonb_typeof(a->'audience') <> 'object' THEN
          pr := pr || format('Ad set %s: audience is missing.', t);
        ELSE
          IF jsonb_typeof(a->'audience'->'locations') <> 'array' OR jsonb_array_length(a->'audience'->'locations') = 0
             OR EXISTS (SELECT 1 FROM jsonb_array_elements(a->'audience'->'locations') l
                         WHERE coalesce(l->>'type', '') NOT IN ('country', 'region', 'city') OR coalesce(l->>'name', '') = '') THEN
            pr := pr || format('Ad set %s: locations need a name and a type (country, region or city).', t);
          END IF;
          IF coalesce(a->'audience'->>'age_min', '') !~ '^\d{2}$' OR (a->'audience'->>'age_min')::int < 18 THEN
            pr := pr || format('Ad set %s: minimum age must be 18 or more.', t);
          END IF;
          IF coalesce(a->'audience'->>'age_max', '') !~ '^\d{2}$' OR (a->'audience'->>'age_max')::int > 65
             OR (a->'audience'->>'age_max')::int < coalesce(nullif(a->'audience'->>'age_min', '')::int, 18) THEN
            pr := pr || format('Ad set %s: maximum age between the minimum and 65.', t);
          END IF;
          IF jsonb_typeof(a->'audience'->'advantage_audience') <> 'boolean' THEN pr := pr || format('Ad set %s: say whether Advantage+ audience is on (true/false).', t); END IF;
        END IF;
        IF NOT (a->>'placements' = 'advantage' OR (jsonb_typeof(a->'placements') = 'array' AND jsonb_array_length(a->'placements') > 0
                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(a->'placements') x
                                 WHERE x NOT IN ('facebook_feed', 'facebook_reels', 'facebook_stories', 'instagram_feed', 'instagram_reels',
                                                 'instagram_stories', 'instagram_explore')))) THEN
          pr := pr || format('Ad set %s: placements must be "advantage" or a list of facebook_feed, facebook_reels, facebook_stories, instagram_feed, instagram_reels, instagram_stories, instagram_explore.', t);
        END IF;
      END LOOP;
    END LOOP;
    IF nadsets > 10 THEN pr := pr || 'More than 10 ad sets in all: too thin for Meta to learn.'::text; END IF;
    FOREACH k IN ARRAY forms LOOP
      IF NOT (k = ANY (used_forms)) THEN pr := pr || format('Form %s is not used by any ad set.', k); END IF;
    END LOOP;
    FOREACH k IN ARRAY ads LOOP
      IF NOT (k = ANY (used_ads)) THEN pr := pr || format('Creative %s is not used by any ad set.', k); END IF;
    END LOOP;
  END IF;

  monthly := CASE WHEN jsonb_typeof(p->'budget'->'monthly_total') = 'number' THEN (p->'budget'->>'monthly_total')::numeric END;
  IF monthly IS NULL OR monthly <= 0 THEN
    pr := pr || 'budget.monthly_total is missing.'::text;
  ELSE
    IF daily > 0 AND abs(daily * 30.4 - monthly) > monthly * 0.10 THEN
      pr := pr || format('Daily budgets add up to ₹%s a day (₹%s a month), but budget.monthly_total says ₹%s.', round(daily), round(daily * 30.4), round(monthly));
    END IF;
    IF (p_goal->>'monthly_budget') IS NOT NULL AND monthly > (p_goal->>'monthly_budget')::numeric * 1.02 THEN
      pr := pr || format('The plan spends ₹%s a month; the owner''s limit is ₹%s.', round(monthly), round((p_goal->>'monthly_budget')::numeric));
    END IF;
  END IF;

  -- forecast
  s := p->'forecast'->'scenarios';
  IF jsonb_typeof(s) <> 'object' OR NOT (s ? 'low' AND s ? 'likely' AND s ? 'high') THEN
    pr := pr || 'forecast.scenarios needs low, likely and high.'::text;
  ELSE
    FOREACH k IN ARRAY ARRAY['low', 'likely', 'high'] LOOP
      IF jsonb_typeof(s->k->'spend') <> 'number' OR jsonb_typeof(s->k->'leads') <> 'number' OR jsonb_typeof(s->k->'cpl') <> 'number' THEN
        pr := pr || format('Forecast %s: spend, leads and cpl must be numbers.', k); CONTINUE;
      END IF;
      IF (s->k->>'leads')::numeric > 0 AND abs((s->k->>'spend')::numeric / (s->k->>'leads')::numeric - (s->k->>'cpl')::numeric) > (s->k->>'cpl')::numeric * 0.15 + 1 THEN
        pr := pr || format('Forecast %s: spend ÷ leads is ₹%s, not the ₹%s given as cost per lead.', k,
          round((s->k->>'spend')::numeric / (s->k->>'leads')::numeric), round((s->k->>'cpl')::numeric));
      END IF;
      IF jsonb_typeof(s->k->'qualified') = 'number' AND (s->k->>'qualified')::numeric > (s->k->>'leads')::numeric THEN
        pr := pr || format('Forecast %s: more qualified leads than leads.', k);
      END IF;
      IF jsonb_typeof(s->k->'admissions') = 'number' AND jsonb_typeof(s->k->'qualified') = 'number'
         AND (s->k->>'admissions')::numeric > (s->k->>'qualified')::numeric THEN
        pr := pr || format('Forecast %s: more admissions than qualified leads.', k);
      END IF;
      IF monthly IS NOT NULL AND (s->k->>'spend')::numeric > monthly * coalesce(nullif(p->'forecast'->>'horizon_days', '')::numeric, 30) / 30.4 * 1.05 THEN
        pr := pr || format('Forecast %s spends more than the plan''s budget for the forecast period.', k);
      END IF;
    END LOOP;
    lo := nullif(s->'low'->>'leads', '')::numeric; li := nullif(s->'likely'->>'leads', '')::numeric; hi := nullif(s->'high'->>'leads', '')::numeric;
    IF lo IS NOT NULL AND li IS NOT NULL AND hi IS NOT NULL AND NOT (lo <= li AND li <= hi) THEN pr := pr || 'Forecast leads must go low ≤ likely ≤ high.'::text; END IF;
  END IF;
  IF jsonb_typeof(p->'forecast'->'assumptions') <> 'array' OR jsonb_array_length(p->'forecast'->'assumptions') < 3
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(p->'forecast'->'assumptions') x
                 WHERE coalesce(x->>'source', '') NOT IN ('history', 'benchmark', 'owner', 'research')) THEN
    pr := pr || 'forecast.assumptions: at least 3, each with source history, benchmark, owner or research.'::text;
  END IF;
  IF jsonb_typeof(p->'rules') <> 'array' OR jsonb_array_length(p->'rules') < 2 THEN pr := pr || 'Give at least 2 rules (when → then) for pausing and scaling.'::text; END IF;
  IF jsonb_typeof(p->'timeline') <> 'array' OR jsonb_array_length(p->'timeline') < 2 THEN pr := pr || 'Give a timeline of at least 2 steps.'::text; END IF;
  IF jsonb_typeof(p->'sources') = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p->'sources') x WHERE NOT crm_private.ads_meta_https(x->>'url')) THEN
    pr := pr || 'Every source needs a full https:// url.'::text;
  END IF;
  RETURN to_jsonb(pr[1:30]);
END $$;

-- ------------------------------------------------------------------------------------------- what the agents get
CREATE OR REPLACE FUNCTION crm_private.ads_meta_agent_ctx(p_run public.ads_agent_runs) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; acc public.ads_accounts := crm_private.ads_meta_acct(); today date := crm_private.ads_meta_today();
        base int; cur jsonb;
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = (p_run.input->>'strategy_id')::bigint;
  base := coalesce((p_run.input->>'base_version')::int, s.version);
  SELECT jsonb_build_object('version', v.version, 'plan', v.plan, 'review', v.review) INTO cur
    FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = base;
  RETURN jsonb_build_object(
    'today', today,
    'strategy', jsonb_build_object('id', s.id, 'title', s.title, 'status', s.status, 'approved_version', s.approved_version),
    'goal', s.goal,
    'current_plan', cur,
    'brand_facts', crm_private.ads_cfg('google_brand_facts'),
    'banned_claims', crm_private.ads_rule('g_claim_phrases')->'phrases',
    'account', CASE WHEN acc.id IS NOT NULL THEN jsonb_build_object('id', acc.external_id, 'name', acc.name, 'currency', acc.currency,
                 'timezone', acc.timezone) END,
    'page', jsonb_build_object('page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
              'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.form_id, 'name', f.name, 'status', f.status, 'pipeline', f.pipeline)), '[]')
                          FROM public.ads_meta_forms f)),
    'meta_leads_last_30d', crm_private.ads_meta_leads_30d(),
    'history_by_month', (SELECT coalesce(jsonb_agg(m ORDER BY m->>'month'), '[]') FROM (
        SELECT jsonb_build_object('month', to_char(date_trunc('month', day), 'YYYY-MM'), 'spend', round(sum(spend)), 'impressions', sum(impressions),
               'clicks', sum(clicks), 'link_clicks', sum(link_clicks), 'meta_leads', sum(leads), 'ads', count(DISTINCT ad_ext)) m
          FROM public.ads_meta_ad_day GROUP BY date_trunc('month', day)) z),
    'insights', crm_private.ads_meta_insights_data(today - 1124, today, NULL, NULL, NULL),
    'insights_last_90d', crm_private.ads_meta_totals(today - 89, today, NULL, NULL, NULL),
    'crm', jsonb_build_object(
      'meta_ad_leads_by_stage', (SELECT coalesce(jsonb_object_agg(stage, n), '{}') FROM (
          SELECT x.stage, count(*) n FROM crm_private.ads_ad_leads() x WHERE x.platform = 'meta' GROUP BY 1) z),
      'all_ad_leads', (SELECT jsonb_build_object('leads', count(*), 'qualified', count(*) FILTER (WHERE x.qualified),
          'customers', count(*) FILTER (WHERE x.customer)) FROM crm_private.ads_ad_leads() x),
      'minutes_to_first_call_median', (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM l.first_response_at - l.created_at) / 60)::numeric)
          FROM public.ads_lead l WHERE l.first_response_at IS NOT NULL AND l.created_at > now() - interval '180 days'),
      'leads_last_120d_by_source', (SELECT coalesce(jsonb_object_agg(src, n), '{}') FROM (
          SELECT coalesce(nullif(l.utm_source, ''), '(none)') src, count(*) n FROM public.lead l WHERE l.created_at > now() - interval '120 days' GROUP BY 1) z),
      'leads_last_120d_by_course', (SELECT coalesce(jsonb_object_agg(c, n), '{}') FROM (
          SELECT coalesce(nullif(l.course_interest, ''), 'Not specified') c, count(*) n FROM public.lead l WHERE l.created_at > now() - interval '120 days' GROUP BY 1) z),
      'closed_outcomes', (SELECT coalesce(jsonb_object_agg(o, n), '{}') FROM (
          SELECT l.closure_outcome::text o, count(*) n FROM public.lead l WHERE l.closure_outcome IS NOT NULL GROUP BY 1) z)),
    'lead_archive', jsonb_build_object(
      'total', (SELECT count(*) FROM public.ads_meta_lead_archive),
      'by_campaign', (SELECT coalesce(jsonb_agg(z ORDER BY (z->>'leads')::int DESC), '[]') FROM (
          SELECT jsonb_build_object('campaign', coalesce(a.campaign_name, a.campaign_id, '(no campaign)'), 'leads', count(*),
                 'in_crm', count(a.crm_lead_id), 'first', min(a.created_time)::date, 'last', max(a.created_time)::date) z
            FROM public.ads_meta_lead_archive a GROUP BY coalesce(a.campaign_name, a.campaign_id, '(no campaign)') LIMIT 40) y),
      'answers_sample', (SELECT coalesce(jsonb_agg(a.answers), '[]') FROM (
          SELECT answers FROM public.ads_meta_lead_archive WHERE answers <> '{}' ORDER BY created_time DESC NULLS LAST LIMIT 60) a)),
    'past_strategies', (SELECT coalesce(jsonb_agg(z), '[]') FROM (
        SELECT jsonb_build_object('id', o.id, 'title', o.title, 'status', o.status, 'approved_version', o.approved_version,
               'summary', (SELECT v.plan->>'summary' FROM public.ads_meta_strategy_version v WHERE v.strategy_id = o.id
                             AND v.version = coalesce(o.approved_version, o.version)),
               'checks', (SELECT coalesce(jsonb_agg(jsonb_build_object('week', k.week_start, 'verdict', k.verdict, 'data', k.data)
                             ORDER BY k.week_start DESC), '[]') FROM (SELECT * FROM public.ads_meta_strategy_check k2
                             WHERE k2.strategy_id = o.id ORDER BY k2.week_start DESC LIMIT 6) k)) z
          FROM public.ads_meta_strategy o WHERE o.id <> s.id AND o.version > 0 ORDER BY o.updated_at DESC LIMIT 5) y),
    'this_strategy_checks', (SELECT coalesce(jsonb_agg(jsonb_build_object('week', k.week_start, 'verdict', k.verdict, 'data', k.data)
          ORDER BY k.week_start DESC), '[]') FROM public.ads_meta_strategy_check k WHERE k.strategy_id = s.id),
    'meta_build_rules', jsonb_build_object('currency', 'INR', 'objective', 'OUTCOME_LEADS', 'min_age', 18,
      'quality_lead_needs_monthly_leads', 200,
      'placements', '["advantage", "facebook_feed", "facebook_reels", "facebook_stories", "instagram_feed", "instagram_reels", "instagram_stories", "instagram_explore"]'::jsonb,
      'ctas', '["APPLY_NOW", "DOWNLOAD", "GET_QUOTE", "LEARN_MORE", "SIGN_UP", "SUBSCRIBE"]'::jsonb,
      'question_types', '["FULL_NAME", "EMAIL", "PHONE", "CITY", "STATE", "CUSTOM"]'::jsonb));
END $$;

-- Claims the next agent step. p_meta = false for helpers that do not know the Meta roles yet (they get only Google steps).
CREATE OR REPLACE FUNCTION public.svc_ads_agent_next2(p_meta boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs;
BEGIN
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.ads_agent_runs WHERE status = 'queued' AND (coalesce(p_meta, false) OR role NOT LIKE 'meta\_%')
   ORDER BY created_at, id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_agent_runs SET status = 'running', claimed_at = now(), claims = claims + 1 WHERE id = r.id RETURNING * INTO r;
  IF r.role LIKE 'meta\_%' THEN
    UPDATE public.ads_meta_strategy SET working_note = CASE r.role WHEN 'meta_researcher' THEN 'Researcher is reading Meta guidance, benchmarks and competitors'
        WHEN 'meta_strategist' THEN 'Strategist is writing the plan' ELSE 'Reviewer is checking the plan' END, updated_at = now()
     WHERE id = (r.input->>'strategy_id')::bigint AND status = 'working';
    RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'attempt', r.attempt, 'input', r.input),
      'context', crm_private.ads_meta_agent_ctx(r));
  END IF;
  IF r.instruction_id IS NOT NULL THEN
    UPDATE public.ads_agent_instructions SET status = 'working' WHERE id = r.instruction_id AND status = 'new';
  END IF;
  RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'attempt', r.attempt, 'input', r.input),
    'context', crm_private.ads_agent_context(r) || jsonb_build_object('playbook',
      (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', p.lesson, 'evidence', p.evidence) ORDER BY p.id), '[]') FROM public.ads_playbook p WHERE p.active)));
END $$;

-- ------------------------------------------------------------------------------------------- the chain
CREATE OR REPLACE FUNCTION crm_private.ads_meta_queue(p_strategy bigint, p_role text, p_attempt int, p_input jsonb, p_parent bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid bigint;
BEGIN
  INSERT INTO public.ads_agent_runs (account_id, role, job, parent_id, attempt, input)
  VALUES ((crm_private.ads_meta_acct()).id, p_role, 'meta_strategy', p_parent, p_attempt,
          p_input || jsonb_build_object('strategy_id', p_strategy)) RETURNING id INTO nid;
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_save_version(p_run public.ads_agent_runs, p_plan jsonb, p_review jsonb, p_status text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; v int;
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = (p_run.input->>'strategy_id')::bigint FOR UPDATE;
  v := s.version + 1;
  INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan, changes, answer, review, research, request, auto, agent_run_id)
  VALUES (s.id, v, p_plan,
          CASE WHEN jsonb_typeof(p_run.input->'strategist'->'changes') = 'array' THEN p_run.input->'strategist'->'changes' ELSE '[]' END,
          left(p_run.input->'strategist'->>'answer', 2000), coalesce(p_review, '{}'),
          coalesce(p_run.input->'research', '{}'),
          coalesce(p_run.input->>'request', ''), coalesce((p_run.input->>'auto')::boolean, false), p_run.id);
  UPDATE public.ads_meta_strategy SET version = v, status = p_status, working_note = NULL, resume_status = NULL,
    title = CASE WHEN s.version = 0 AND coalesce(btrim(p_plan->>'title'), '') <> '' THEN left(p_plan->>'title', 120) ELSE s.title END,
    updated_at = now() WHERE id = s.id;
  INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('agent', 'meta_strategy_version', 'meta_strategy', s.id::text, jsonb_build_object('version', v, 'status', p_status));
  RETURN v;
END $$;

-- Stops a chain that cannot finish: the strategy goes back to where it was (or 'failed' if it has no plan yet).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_chain_stop(p_run public.ads_agent_runs, p_why text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.ads_meta_strategy SET status = CASE WHEN version = 0 THEN 'failed' ELSE coalesce(resume_status, 'ready') END,
    resume_status = NULL, working_note = left('The agents could not finish: ' || coalesce(p_why, 'no usable answer'), 500), updated_at = now()
   WHERE id = (p_run.input->>'strategy_id')::bigint AND status = 'working';
END $$;

-- Stores a Meta strategy step and queues the next. {handled: false} for any other role (the Google chain handles it).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_agent_finish(p_id bigint, p_ok boolean, p_output jsonb, p_summary text DEFAULT NULL,
  p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs; probs jsonb; plan jsonb; nid bigint; v int; goal jsonb; verdict text; sid bigint;
BEGIN
  SELECT * INTO r FROM public.ads_agent_runs WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.role NOT LIKE 'meta\_%' THEN RETURN jsonb_build_object('handled', false); END IF;
  IF r.status <> 'running' THEN RETURN jsonb_build_object('handled', true, 'ignored', true); END IF;
  sid := (r.input->>'strategy_id')::bigint;
  SELECT s.goal INTO goal FROM public.ads_meta_strategy s WHERE s.id = sid;
  IF goal IS NULL THEN
    UPDATE public.ads_agent_runs SET status = 'failed', error = 'Strategy was deleted', finished_at = now() WHERE id = r.id;
    RETURN jsonb_build_object('handled', true, 'next', NULL);
  END IF;

  IF NOT coalesce(p_ok, false) OR p_output IS NULL OR jsonb_typeof(p_output) <> 'object' THEN
    UPDATE public.ads_agent_runs SET status = 'failed', error = left(coalesce(p_error, 'No usable answer'), 900), finished_at = now() WHERE id = r.id;
    PERFORM crm_private.ads_meta_chain_stop(r, left(coalesce(p_error, 'no usable answer'), 300));
    RETURN jsonb_build_object('handled', true, 'next', NULL);
  END IF;

  IF r.role = 'meta_researcher' THEN
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, finished_at = now(),
      summary = left(coalesce(p_summary, p_output->>'summary'), 500) WHERE id = r.id;
    nid := crm_private.ads_meta_queue(sid, 'meta_strategist', 1,
      jsonb_build_object('request', r.input->>'request', 'base_version', r.input->'base_version', 'auto', r.input->'auto',
        'research', p_output), r.id);
    RETURN jsonb_build_object('handled', true, 'next', nid);
  END IF;

  IF r.role = 'meta_strategist' THEN
    plan := p_output->'plan';
    probs := crm_private.ads_meta_plan_check(goal, plan);
    IF jsonb_array_length(probs) > 0 THEN
      UPDATE public.ads_agent_runs SET status = 'rejected', output = p_output, finished_at = now(),
        summary = left(format('Code checks found %s problem(s): %s', jsonb_array_length(probs), probs->>0), 500) WHERE id = r.id;
      IF r.attempt >= 3 THEN
        IF jsonb_typeof(plan) = 'object' THEN
          r.input := r.input || jsonb_build_object('strategist', p_output);
          v := crm_private.ads_meta_save_version(r, plan, jsonb_build_object('verdict', 'not_approved', 'by', 'code checks', 'problems', probs), 'needs_review');
          RETURN jsonb_build_object('handled', true, 'next', NULL, 'version', v);
        END IF;
        PERFORM crm_private.ads_meta_chain_stop(r, 'after 3 tries the plan still failed the checks: ' || left(probs::text, 300));
        RETURN jsonb_build_object('handled', true, 'next', NULL);
      END IF;
      nid := crm_private.ads_meta_queue(sid, 'meta_strategist', r.attempt + 1,
        (r.input - 'strategy_id') || jsonb_build_object('previous_answer', p_output, 'fix_these', probs, 'from', 'code checks'), r.id);
      RETURN jsonb_build_object('handled', true, 'next', nid);
    END IF;
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, finished_at = now(),
      summary = left(coalesce(p_summary, 'Plan written: ' || coalesce(plan->>'title', '')), 500) WHERE id = r.id;
    nid := crm_private.ads_meta_queue(sid, 'meta_reviewer', r.attempt,
      jsonb_build_object('request', r.input->>'request', 'base_version', r.input->'base_version', 'auto', r.input->'auto',
        'research', r.input->'research', 'strategist', p_output), r.id);
    RETURN jsonb_build_object('handled', true, 'next', nid);
  END IF;

  -- meta_reviewer
  verdict := lower(btrim(coalesce(p_output->>'verdict', '')));
  plan := r.input->'strategist'->'plan';
  IF verdict = 'approve' THEN
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, finished_at = now(),
      summary = left(coalesce(p_summary, 'Approved'), 500) WHERE id = r.id;
    v := crm_private.ads_meta_save_version(r, plan, jsonb_build_object('verdict', 'approve', 'by', 'reviewer',
           'notes', p_output->>'notes', 'problems', coalesce(p_output->'problems', '[]'), 'checked', coalesce(p_output->'checked', '[]')), 'ready');
    RETURN jsonb_build_object('handled', true, 'next', NULL, 'version', v);
  END IF;
  UPDATE public.ads_agent_runs SET status = 'rejected', output = p_output, finished_at = now(),
    summary = left(coalesce(p_summary, 'Rejected: ' || coalesce(p_output->'problems'->>0, 'no reason given')), 500) WHERE id = r.id;
  IF r.attempt >= 3 THEN
    v := crm_private.ads_meta_save_version(r, plan, jsonb_build_object('verdict', 'not_approved', 'by', 'reviewer',
           'notes', p_output->>'notes', 'problems', coalesce(p_output->'problems', '[]')), 'needs_review');
    RETURN jsonb_build_object('handled', true, 'next', NULL, 'version', v);
  END IF;
  nid := crm_private.ads_meta_queue(sid, 'meta_strategist', r.attempt + 1,
    jsonb_build_object('request', r.input->>'request', 'base_version', r.input->'base_version', 'auto', r.input->'auto',
      'research', r.input->'research', 'previous_answer', r.input->'strategist',
      'fix_these', coalesce(p_output->'problems', '[]'), 'from', 'reviewer'), r.id);
  RETURN jsonb_build_object('handled', true, 'next', nid);
END $$;

-- ------------------------------------------------------------------------------------------- owner actions
CREATE OR REPLACE FUNCTION crm_private.ads_meta_runs_left() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT greatest(0, coalesce(nullif(crm_private.ads_cfg('meta_strategy_per_day'), '')::int, 8)
    - (SELECT count(*)::int FROM public.ads_agent_runs WHERE role LIKE 'meta\_%' AND parent_id IS NULL
         AND created_at > now() - interval '24 hours' AND coalesce((input->>'auto')::boolean, false) = false)) $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_create(p_goal jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE g jsonb; sid bigint; t text;
BEGIN
  PERFORM crm_private.ads_require_admin();
  g := crm_private.ads_meta_goal_clean(p_goal);
  IF crm_private.ads_meta_runs_left() <= 0 THEN
    RAISE EXCEPTION 'The agents already started % strategies or changes in the last 24 hours. Try again later.', crm_private.ads_cfg('meta_strategy_per_day') USING ERRCODE = 'PT429';
  END IF;
  t := left(concat_ws(' · ', CASE g->>'objective' WHEN 'admissions' THEN 'Admissions' WHEN 'qualified' THEN 'Qualified leads' ELSE 'Leads' END,
         (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(g->'courses') x),
         to_char((g->>'start_date')::date, 'Mon YYYY')), 120);
  INSERT INTO public.ads_meta_strategy (title, status, goal, created_by, working_note)
  VALUES (t, 'working', g, crm_private.current_employee_id(), 'Waiting for the agents') RETURNING id INTO sid;
  PERFORM crm_private.ads_meta_queue(sid, 'meta_researcher', 1, jsonb_build_object('request', ''));
  INSERT INTO public.ads_activity_log (actor_type, actor, action, entity, entity_id, details)
  VALUES ('user', crm_private.current_employee_id(), 'meta_strategy_create', 'meta_strategy', sid::text, g);
  RETURN jsonb_build_object('id', sid);
END $$;

-- A change request: the Strategist revises the latest version (with a fresh research step when asked).
CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_change(p_id bigint, p_request text, p_research boolean DEFAULT false,
  p_goal jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; req text := left(btrim(coalesce(p_request, '')), 2000);
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  IF s.status = 'working' THEN RAISE EXCEPTION 'The agents are still working on this strategy' USING ERRCODE = 'PT409'; END IF;
  IF s.status = 'archived' THEN RAISE EXCEPTION 'This strategy is archived' USING ERRCODE = 'PT409'; END IF;
  IF length(req) < 3 AND p_goal IS NULL THEN RAISE EXCEPTION 'Say what to change' USING ERRCODE = 'PT422'; END IF;
  IF crm_private.ads_meta_runs_left() <= 0 THEN
    RAISE EXCEPTION 'The agents already started % strategies or changes in the last 24 hours. Try again later.', crm_private.ads_cfg('meta_strategy_per_day') USING ERRCODE = 'PT429';
  END IF;
  IF p_goal IS NOT NULL THEN
    UPDATE public.ads_meta_strategy SET goal = crm_private.ads_meta_goal_clean(p_goal) WHERE id = s.id;
    req := concat_ws(' ', nullif(req, ''), 'The owner changed the goal; see CONTEXT.goal.');
  END IF;
  UPDATE public.ads_meta_strategy SET resume_status = CASE WHEN s.version = 0 THEN NULL ELSE s.status END, status = 'working',
    working_note = 'Waiting for the agents', updated_at = now() WHERE id = s.id;
  IF coalesce(p_research, false) OR s.version = 0 THEN
    PERFORM crm_private.ads_meta_queue(s.id, 'meta_researcher', 1, jsonb_build_object('request', req, 'base_version', nullif(s.version, 0)));
  ELSE
    PERFORM crm_private.ads_meta_queue(s.id, 'meta_strategist', 1, jsonb_build_object('request', req, 'base_version', s.version,
      'research', (SELECT v.research FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.version)));
  END IF;
  INSERT INTO public.ads_activity_log (actor_type, actor, action, entity, entity_id, details)
  VALUES ('user', crm_private.current_employee_id(), 'meta_strategy_change', 'meta_strategy', s.id::text,
          jsonb_build_object('request', req, 'research', coalesce(p_research, false)));
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_approve(p_id bigint, p_version int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy;
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  IF s.status IN ('working', 'archived') THEN RAISE EXCEPTION 'This strategy cannot be approved right now' USING ERRCODE = 'PT409'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ads_meta_strategy_version WHERE strategy_id = p_id AND version = p_version) THEN
    RAISE EXCEPTION 'Version not found' USING ERRCODE = 'PT404';
  END IF;
  UPDATE public.ads_meta_strategy SET approved_version = p_version, status = 'approved', approved_by = crm_private.current_employee_id(),
    approved_at = now(), updated_at = now() WHERE id = p_id;
  INSERT INTO public.ads_activity_log (actor_type, actor, action, entity, entity_id, details)
  VALUES ('user', crm_private.current_employee_id(), 'meta_strategy_approve', 'meta_strategy', p_id::text, jsonb_build_object('version', p_version));
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_archive(p_id bigint, p_archive boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy;
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  IF s.status = 'working' THEN RAISE EXCEPTION 'Wait for the agents to finish first' USING ERRCODE = 'PT409'; END IF;
  UPDATE public.ads_meta_strategy SET status = CASE WHEN p_archive THEN 'archived'
      WHEN s.approved_version IS NOT NULL THEN 'approved' WHEN s.version = 0 THEN 'failed' ELSE 'ready' END, updated_at = now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Links plan campaigns to Meta campaigns (when the owner built them by hand), for plan vs actual.
CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_link(p_id bigint, p_links jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text; v text; clean jsonb := '{}';
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF NOT EXISTS (SELECT 1 FROM public.ads_meta_strategy WHERE id = p_id) THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  IF jsonb_typeof(p_links) <> 'object' THEN RAISE EXCEPTION 'Links must be an object' USING ERRCODE = 'PT422'; END IF;
  FOR k, v IN SELECT key, value #>> '{}' FROM jsonb_each(p_links) LOOP
    CONTINUE WHEN coalesce(v, '') = '';
    IF v !~ '^\d{1,25}$' THEN RAISE EXCEPTION 'Not a Meta campaign id: %', left(v, 30) USING ERRCODE = 'PT422'; END IF;
    clean := clean || jsonb_build_object(left(k, 60), v);
  END LOOP;
  UPDATE public.ads_meta_strategy SET links = clean, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'links', clean);
END $$;

-- Campaign ids that belong to a strategy: linked by hand, or made by Create in Meta.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_strategy_campaigns(s public.ads_meta_strategy) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT x), '{}') FROM (
    SELECT value #>> '{}' x FROM jsonb_each(s.links)
    UNION SELECT st->>'id' FROM jsonb_each(coalesce(s.build->'steps', '{}')) e(k, st) WHERE k LIKE 'campaign:%' AND st->>'id' IS NOT NULL) z
   WHERE x ~ '^\d{1,25}$' $$;

-- Actual results of a strategy's campaigns in a period.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_strategy_actual(s public.ads_meta_strategy, p_from date, p_to date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH c AS (SELECT unnest(crm_private.ads_meta_strategy_campaigns(s)) ext),
  d AS (SELECT coalesce(sum(spend), 0) spend, coalesce(sum(leads), 0) leads FROM public.ads_meta_ad_day
         WHERE day BETWEEN p_from AND p_to AND campaign_ext IN (SELECT ext FROM c)),
  r AS (SELECT count(*) crm, count(*) FILTER (WHERE qualified) q, count(*) FILTER (WHERE customer) cu
          FROM crm_private.ads_meta_crm(p_from, p_to, NULL, NULL, NULL) WHERE campaign_ext IN (SELECT ext FROM c))
  SELECT jsonb_build_object('campaigns', (SELECT count(*) FROM c), 'spend', round(d.spend, 2), 'meta_leads', d.leads,
    'crm_leads', r.crm, 'qualified', r.q, 'customers', r.cu, 'cpl', CASE WHEN d.leads > 0 THEN round(d.spend / d.leads) END)
  FROM d, r $$;

-- The plan's "likely" numbers per day (for pro-rating).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_daily(p_plan jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'spend', round(coalesce((p_plan#>>'{forecast,scenarios,likely,spend}')::numeric, 0) / greatest(coalesce(nullif(p_plan#>>'{forecast,horizon_days}', '')::numeric, 30), 1), 2),
    'leads', round(coalesce((p_plan#>>'{forecast,scenarios,likely,leads}')::numeric, 0) / greatest(coalesce(nullif(p_plan#>>'{forecast,horizon_days}', '')::numeric, 30), 1), 3),
    'cpl', (p_plan#>>'{forecast,scenarios,likely,cpl}')::numeric) $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategies() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'status', s.status, 'version', s.version,
        'approved_version', s.approved_version, 'working_note', s.working_note, 'goal', s.goal, 'created_at', s.created_at, 'updated_at', s.updated_at,
        'build', s.build->>'status',
        'likely', (SELECT v.plan#>'{forecast,scenarios,likely}' FROM public.ads_meta_strategy_version v
                    WHERE v.strategy_id = s.id AND v.version = coalesce(s.approved_version, s.version)),
        'monthly', (SELECT v.plan#>'{budget,monthly_total}' FROM public.ads_meta_strategy_version v
                    WHERE v.strategy_id = s.id AND v.version = coalesce(s.approved_version, s.version)),
        'last_check', (SELECT jsonb_build_object('week', k.week_start, 'verdict', k.verdict) FROM public.ads_meta_strategy_check k
                        WHERE k.strategy_id = s.id ORDER BY k.week_start DESC LIMIT 1))
        ORDER BY (s.status = 'archived'), s.updated_at DESC), '[]') FROM public.ads_meta_strategy s),
    'runs_left', crm_private.ads_meta_runs_left(),
    'agents', jsonb_build_object('last_seen', nullif(crm_private.ads_cfg('agents_last_seen'), ''),
      'paused', crm_private.ads_cfg('execution_paused') = 'true'),
    'meta_leads_last_30d', crm_private.ads_meta_leads_30d());
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy(p_id bigint, p_version int DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; v public.ads_meta_strategy_version; ver int; since date; daily jsonb; days int;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  ver := coalesce(p_version, s.version);
  SELECT * INTO v FROM public.ads_meta_strategy_version WHERE strategy_id = s.id AND version = ver;
  since := greatest((s.goal->>'start_date')::date, coalesce((s.approved_at AT TIME ZONE 'Asia/Kolkata')::date, (s.goal->>'start_date')::date));
  days := greatest(0, crm_private.ads_meta_today() - since + 1);
  daily := (SELECT crm_private.ads_meta_plan_daily(x.plan) FROM public.ads_meta_strategy_version x
             WHERE x.strategy_id = s.id AND x.version = s.approved_version);
  RETURN jsonb_build_object(
    'strategy', jsonb_build_object('id', s.id, 'title', s.title, 'status', s.status, 'goal', s.goal, 'version', s.version,
      'approved_version', s.approved_version, 'approved_at', s.approved_at, 'working_note', s.working_note, 'links', s.links,
      'build', s.build, 'created_at', s.created_at, 'updated_at', s.updated_at),
    'versions', (SELECT coalesce(jsonb_agg(jsonb_build_object('version', x.version, 'created_at', x.created_at, 'request', x.request,
        'auto', x.auto, 'verdict', x.review->>'verdict', 'title', x.plan->>'title') ORDER BY x.version DESC), '[]')
        FROM public.ads_meta_strategy_version x WHERE x.strategy_id = s.id),
    'current', CASE WHEN v.version IS NOT NULL THEN jsonb_build_object('version', v.version, 'plan', v.plan, 'changes', v.changes,
        'answer', v.answer, 'review', v.review, 'research', v.research, 'request', v.request, 'auto', v.auto, 'created_at', v.created_at) END,
    'chain', (SELECT coalesce(jsonb_agg(jsonb_build_object('role', r.role, 'status', r.status, 'attempt', r.attempt, 'summary', r.summary,
        'error', r.error, 'at', coalesce(r.finished_at, r.claimed_at, r.created_at)) ORDER BY r.id), '[]')
        FROM (SELECT * FROM public.ads_agent_runs r2 WHERE r2.role LIKE 'meta\_%' AND (r2.input->>'strategy_id')::bigint = s.id
               ORDER BY r2.id DESC LIMIT 12) r),
    'checks', (SELECT coalesce(jsonb_agg(jsonb_build_object('week', k.week_start, 'verdict', k.verdict, 'data', k.data) ORDER BY k.week_start DESC), '[]')
        FROM public.ads_meta_strategy_check k WHERE k.strategy_id = s.id),
    'since_start', CASE WHEN s.approved_version IS NOT NULL THEN jsonb_build_object('from', since, 'days', days,
        'actual', crm_private.ads_meta_strategy_actual(s, since, crm_private.ads_meta_today()),
        'planned', jsonb_build_object('spend', round((daily->>'spend')::numeric * days), 'leads', round((daily->>'leads')::numeric * days),
                                      'cpl', daily->'cpl')) END,
    'campaign_options', (SELECT coalesce(jsonb_agg(jsonb_build_object('ext', o.external_id, 'name', o.name, 'status', o.status) ORDER BY o.created_time DESC NULLS LAST), '[]')
        FROM public.ads_meta_object o WHERE o.level = 'campaign'),
    'can_build', (crm_private.ads_meta_acct()).id IS NOT NULL AND nullif(crm_private.ads_cfg('meta_page_id'), '') IS NOT NULL);
END $$;

-- ------------------------------------------------------------------------------------------- Create in Meta (paused)
CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_build(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy;
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Strategy not found' USING ERRCODE = 'PT404'; END IF;
  IF s.approved_version IS NULL OR s.status <> 'approved' THEN RAISE EXCEPTION 'Approve a version first' USING ERRCODE = 'PT409'; END IF;
  IF (crm_private.ads_meta_acct()).id IS NULL THEN RAISE EXCEPTION 'Connect the Meta ad account first' USING ERRCODE = 'PT409'; END IF;
  IF nullif(crm_private.ads_cfg('meta_page_id'), '') IS NULL THEN RAISE EXCEPTION 'Add the Facebook Page ID in Meta Ads > Settings first' USING ERRCODE = 'PT409'; END IF;
  IF s.build->>'status' = 'running' AND (s.build->>'at')::timestamptz > now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'Already creating it' USING ERRCODE = 'PT409';
  END IF;
  IF (s.build->>'version')::int IS DISTINCT FROM s.approved_version AND s.build ? 'version' AND jsonb_typeof(s.build->'steps') = 'object'
     AND EXISTS (SELECT 1 FROM jsonb_each(s.build->'steps') e WHERE e.value->>'id' IS NOT NULL) THEN
    RAISE EXCEPTION 'Version % was already created in Meta. Change it there, or start a new strategy for a different plan.', s.build->>'version' USING ERRCODE = 'PT409';
  END IF;
  UPDATE public.ads_meta_strategy SET build = coalesce(build, '{}') || jsonb_build_object('status', 'queued', 'version', s.approved_version,
      'at', now(), 'by', crm_private.current_employee_id()), updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- What ads-sync needs to build (service role).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; acc public.ads_accounts := crm_private.ads_meta_acct();
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL OR coalesce(s.build->>'status', '') NOT IN ('queued', 'running', 'error', 'partial') OR s.approved_version IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('status', 'running', 'at', now()) WHERE id = p_id;
  RETURN jsonb_build_object('strategy_id', s.id, 'version', s.approved_version, 'account_id', acc.external_id, 'currency', acc.currency,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''), 'goal', s.goal,
    'plan', (SELECT v.plan FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.approved_version),
    'steps', coalesce(s.build->'steps', '{}'), 'images', coalesce(s.build->'images', '{}'));
END $$;

-- The ad account a strategy builds in (for picture uploads; changes nothing).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work_peek(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.ads_meta_strategy WHERE id = p_id)
    THEN jsonb_build_object('account_id', (crm_private.ads_meta_acct()).external_id) END $$;

-- One finished step (saved at once, so a retry never makes a second copy).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_step(p_id bigint, p_key text, p_step jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_strategy SET build = jsonb_set(coalesce(build, '{}') || jsonb_build_object('steps', coalesce(build->'steps', '{}')),
      ARRAY['steps', left(p_key, 120)], p_step || jsonb_build_object('at', now())), updated_at = now() WHERE id = p_id $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_end(p_id bigint, p_status text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('status', CASE WHEN p_status IN ('done', 'partial', 'error') THEN p_status ELSE 'error' END,
      'detail', left(p_detail, 1500), 'ended_at', now()), updated_at = now() WHERE id = p_id $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_image(p_id bigint, p_key text, p_hash text, p_name text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_strategy SET build = jsonb_set(coalesce(build, '{}') || jsonb_build_object('images', coalesce(build->'images', '{}')),
      ARRAY['images', left(p_key, 60)], jsonb_build_object('hash', p_hash, 'name', left(p_name, 120), 'at', now())), updated_at = now() WHERE id = p_id $$;

-- ------------------------------------------------------------------------------------------- plan vs actual (weekly)
CREATE OR REPLACE FUNCTION public.svc_ads_meta_strategy_track() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; wk date := date_trunc('week', crm_private.ads_meta_today() - 7)::date; v jsonb; act jsonb;
        pl jsonb; d int; verdict text; n int := 0; queued int := 0; pspend numeric; pleads numeric; dfrom date;
BEGIN
  FOR s IN SELECT * FROM public.ads_meta_strategy WHERE status = 'approved' AND approved_version IS NOT NULL LOOP
    CONTINUE WHEN cardinality(crm_private.ads_meta_strategy_campaigns(s)) = 0;
    dfrom := greatest(wk, (s.goal->>'start_date')::date);
    CONTINUE WHEN dfrom > wk + 6;
    d := wk + 6 - dfrom + 1;
    SELECT x.plan INTO v FROM public.ads_meta_strategy_version x WHERE x.strategy_id = s.id AND x.version = s.approved_version;
    pl := crm_private.ads_meta_plan_daily(v);
    pspend := (pl->>'spend')::numeric * d; pleads := (pl->>'leads')::numeric * d;
    act := crm_private.ads_meta_strategy_actual(s, dfrom, wk + 6);
    verdict := CASE
      WHEN (act->>'spend')::numeric = 0 THEN 'no_data'
      WHEN (act->>'meta_leads')::numeric < pleads * 0.7 * least(1, (act->>'spend')::numeric / greatest(pspend, 1))
           OR ((act->>'cpl') IS NOT NULL AND (pl->>'cpl') IS NOT NULL AND (act->>'cpl')::numeric > (pl->>'cpl')::numeric * 1.3)
           OR ((act->>'meta_leads')::numeric = 0 AND (act->>'spend')::numeric >= coalesce((pl->>'cpl')::numeric, 0) * 2) THEN 'behind'
      WHEN (act->>'meta_leads')::numeric >= pleads * 1.2 AND ((act->>'cpl') IS NULL OR (pl->>'cpl') IS NULL OR (act->>'cpl')::numeric <= (pl->>'cpl')::numeric) THEN 'ahead'
      ELSE 'on_track' END;
    INSERT INTO public.ads_meta_strategy_check (strategy_id, week_start, data, verdict)
    VALUES (s.id, wk, jsonb_build_object('days', d, 'planned', jsonb_build_object('spend', round(pspend), 'leads', round(pleads, 1), 'cpl', pl->'cpl'),
            'actual', act), verdict)
    ON CONFLICT (strategy_id, week_start) DO UPDATE SET data = EXCLUDED.data, verdict = EXCLUDED.verdict, created_at = now();
    n := n + 1;
    -- falling behind: the Strategist drafts a revision for the owner (never applied without approval)
    IF verdict = 'behind' AND (s.last_auto_at IS NULL OR s.last_auto_at < now() - interval '14 days')
       AND crm_private.ads_cfg('execution_paused') IS DISTINCT FROM 'true' THEN
      UPDATE public.ads_meta_strategy SET status = 'working', resume_status = 'approved', last_auto_at = now(),
        working_note = 'Plan vs actual: behind plan, the Strategist is drafting a revision', updated_at = now() WHERE id = s.id;
      PERFORM crm_private.ads_meta_queue(s.id, 'meta_strategist', 1, jsonb_build_object('auto', true, 'base_version', s.approved_version,
        'request', format('Plan vs actual for the week of %s: planned about ₹%s and %s leads (₹%s per lead); actual ₹%s, %s Meta leads, %s in the CRM, %s qualified. Propose a revision that fixes this, using CONTEXT.this_strategy_checks and the insights. Keep the owner''s goal and budget limit.',
          wk, round(pspend), round(pleads), pl->>'cpl', act->>'spend', act->>'meta_leads', act->>'crm_leads', act->>'qualified'),
        'research', (SELECT x.research FROM public.ads_meta_strategy_version x WHERE x.strategy_id = s.id AND x.version = s.approved_version)));
      queued := queued + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('checked', n, 'revisions', queued, 'week', wk);
END $$;

-- ------------------------------------------------------------------------------------------- lead archive
-- Copies a Meta lead into the archive when the CRM files it (ad leads and leads without an ad).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_archive_raw(r public.ads_meta_lead_raw) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE al public.ads_lead; cl public.lead; ad public.ads_meta_object; aset public.ads_meta_object; cmp public.ads_meta_object;
BEGIN
  IF r.source <> 'instant_form' OR r.status NOT IN ('ingested', 'organic') THEN RETURN; END IF;
  IF r.lead_id IS NOT NULL THEN SELECT * INTO al FROM public.ads_lead WHERE id = r.lead_id; END IF;
  SELECT * INTO cl FROM public.lead WHERE id = coalesce(r.organic_lead_id, al.organic_lead_id);
  SELECT * INTO ad FROM public.ads_meta_object WHERE level = 'ad' AND external_id = r.ad_id;
  SELECT * INTO aset FROM public.ads_meta_object WHERE level = 'adset' AND external_id = coalesce(r.adgroup_id, ad.adset_ext);
  SELECT * INTO cmp FROM public.ads_meta_object WHERE level = 'campaign' AND external_id = coalesce(ad.campaign_ext, aset.campaign_ext);
  INSERT INTO public.ads_meta_lead_archive (external_id, source, created_time, ad_id, ad_name, adset_id, adset_name, campaign_id, campaign_name,
    form_id, form_name, platform, is_organic, name, phone_e164, email, answers, crm_lead_id, ads_lead_id)
  VALUES (r.external_id, 'crm', coalesce(r.created_time, r.received_at), r.ad_id, ad.name, coalesce(r.adgroup_id, ad.adset_ext), aset.name,
    cmp.external_id, cmp.name, r.form_id, (SELECT f.name FROM public.ads_meta_forms f WHERE f.form_id = r.form_id), NULL, r.status = 'organic',
    coalesce(al.name, cl.name), coalesce(al.phone_e164, CASE WHEN cl.phone IS NOT NULL THEN crm_private.norm_phone(cl.phone) END),
    coalesce(al.email, cl.email), coalesce(r.payload->'answers', '{}'), cl.id, al.id)
  ON CONFLICT (external_id) DO UPDATE SET
    name = coalesce(public.ads_meta_lead_archive.name, EXCLUDED.name), phone_e164 = coalesce(public.ads_meta_lead_archive.phone_e164, EXCLUDED.phone_e164),
    email = coalesce(public.ads_meta_lead_archive.email, EXCLUDED.email),
    answers = public.ads_meta_lead_archive.answers || EXCLUDED.answers,
    crm_lead_id = coalesce(public.ads_meta_lead_archive.crm_lead_id, EXCLUDED.crm_lead_id),
    ads_lead_id = coalesce(public.ads_meta_lead_archive.ads_lead_id, EXCLUDED.ads_lead_id),
    ad_name = coalesce(public.ads_meta_lead_archive.ad_name, EXCLUDED.ad_name),
    campaign_id = coalesce(public.ads_meta_lead_archive.campaign_id, EXCLUDED.campaign_id),
    campaign_name = coalesce(public.ads_meta_lead_archive.campaign_name, EXCLUDED.campaign_name), updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_archive_trg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.status IN ('ingested', 'organic') AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status
       OR OLD.lead_id IS DISTINCT FROM NEW.lead_id OR OLD.organic_lead_id IS DISTINCT FROM NEW.organic_lead_id) THEN
    BEGIN
      PERFORM crm_private.ads_meta_archive_raw(NEW);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'ads_meta_archive_raw: %', SQLERRM;   -- never block filing a lead
    END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_meta_archive ON public.ads_meta_lead_raw;
CREATE TRIGGER trg_ads_meta_archive AFTER INSERT OR UPDATE ON public.ads_meta_lead_raw
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_meta_archive_trg();

-- leads filed before this migration
DO $$
DECLARE r public.ads_meta_lead_raw;
BEGIN
  FOR r IN SELECT * FROM public.ads_meta_lead_raw WHERE status IN ('ingested', 'organic') AND source = 'instant_form' LOOP
    PERFORM crm_private.ads_meta_archive_raw(r);
  END LOOP;
END $$;

-- Import rows from Meta's CSV download (parsed in the browser). Up to 2000 rows per call.
CREATE OR REPLACE FUNCTION public.api_ads_meta_leads_import(p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x jsonb; id text; ph text; added int := 0; updated int := 0; skipped int := 0; matched int := 0; cid uuid; t timestamptz; ins boolean;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Rows must be a list' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_array_length(p_rows) > 2000 THEN RAISE EXCEPTION 'Send at most 2000 rows at a time' USING ERRCODE = 'PT422'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    id := regexp_replace(coalesce(x->>'id', ''), '^l:', '');
    IF id !~ '^\d{5,25}$' THEN skipped := skipped + 1; CONTINUE; END IF;
    ph := nullif(regexp_replace(coalesce(x->>'phone', ''), '[^0-9+]', '', 'g'), '');
    ph := CASE WHEN ph IS NOT NULL AND length(regexp_replace(ph, '\D', '', 'g')) BETWEEN 10 AND 15 THEN crm_private.norm_phone(ph) END;
    BEGIN t := nullif(x->>'created_time', '')::timestamptz; EXCEPTION WHEN OTHERS THEN t := NULL; END;
    cid := NULL;
    IF ph IS NOT NULL THEN
      SELECT l.id INTO cid FROM public.lead l WHERE crm_private.normalize_phone(l.phone) = crm_private.normalize_phone(ph)
       ORDER BY l.created_at LIMIT 1;
    END IF;
    INSERT INTO public.ads_meta_lead_archive AS a (external_id, source, created_time, ad_id, ad_name, adset_id, adset_name, campaign_id, campaign_name,
      form_id, form_name, platform, is_organic, name, phone_e164, email, answers, crm_lead_id, imported_by)
    VALUES (id, 'csv', t,
      nullif(regexp_replace(coalesce(x->>'ad_id', ''), '^ag:', ''), ''), left(nullif(x->>'ad_name', ''), 200),
      nullif(regexp_replace(coalesce(x->>'adset_id', ''), '^as:', ''), ''), left(nullif(x->>'adset_name', ''), 200),
      nullif(regexp_replace(coalesce(x->>'campaign_id', ''), '^c:', ''), ''), left(nullif(x->>'campaign_name', ''), 200),
      nullif(regexp_replace(coalesce(x->>'form_id', ''), '^f:', ''), ''), left(nullif(x->>'form_name', ''), 200),
      left(nullif(x->>'platform', ''), 20), CASE WHEN lower(coalesce(x->>'is_organic', '')) IN ('true', '1', 'yes') THEN true
        WHEN lower(coalesce(x->>'is_organic', '')) IN ('false', '0', 'no') THEN false END,
      left(nullif(btrim(x->>'name'), ''), 200), ph, left(nullif(lower(btrim(x->>'email')), ''), 200),
      CASE WHEN jsonb_typeof(x->'answers') = 'object' THEN x->'answers' ELSE '{}' END, cid, crm_private.current_employee_id())
    ON CONFLICT (external_id) DO UPDATE SET
      ad_name = coalesce(a.ad_name, EXCLUDED.ad_name), adset_name = coalesce(a.adset_name, EXCLUDED.adset_name),
      campaign_id = coalesce(a.campaign_id, EXCLUDED.campaign_id), campaign_name = coalesce(a.campaign_name, EXCLUDED.campaign_name),
      form_name = coalesce(a.form_name, EXCLUDED.form_name), platform = coalesce(a.platform, EXCLUDED.platform),
      name = coalesce(a.name, EXCLUDED.name), phone_e164 = coalesce(a.phone_e164, EXCLUDED.phone_e164), email = coalesce(a.email, EXCLUDED.email),
      answers = EXCLUDED.answers || a.answers, crm_lead_id = coalesce(a.crm_lead_id, EXCLUDED.crm_lead_id), updated_at = now()
    RETURNING (xmax = 0) INTO ins;
    IF ins THEN added := added + 1; ELSE updated := updated + 1; END IF;
    IF cid IS NOT NULL THEN matched := matched + 1; END IF;
  END LOOP;
  INSERT INTO public.ads_activity_log (actor_type, actor, action, entity, entity_id, details)
  VALUES ('user', crm_private.current_employee_id(), 'meta_leads_import', 'meta_lead_archive', NULL,
          jsonb_build_object('added', added, 'updated', updated, 'skipped', skipped));
  RETURN jsonb_build_object('added', added, 'updated', updated, 'skipped', skipped, 'matched', matched);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_archive() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object('total', (SELECT count(*) FROM public.ads_meta_lead_archive),
    'from_crm', (SELECT count(*) FROM public.ads_meta_lead_archive WHERE source = 'crm'),
    'imported', (SELECT count(*) FROM public.ads_meta_lead_archive WHERE source = 'csv'),
    'in_leads', (SELECT count(*) FROM public.ads_meta_lead_archive WHERE crm_lead_id IS NOT NULL OR ads_lead_id IS NOT NULL),
    'first', (SELECT min(created_time) FROM public.ads_meta_lead_archive), 'last', (SELECT max(created_time) FROM public.ads_meta_lead_archive),
    'forms_swept', (SELECT count(*) FROM public.ads_meta_forms WHERE full_swept_at IS NOT NULL),
    'forms', (SELECT count(*) FROM public.ads_meta_forms WHERE active));
END $$;

-- Everything in the archive, for the owner's own copy (Admin only; contains contact details).
CREATE OR REPLACE FUNCTION public.api_ads_meta_archive_export() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.external_id, 'created_time', a.created_time, 'source', a.source,
      'campaign_name', a.campaign_name, 'campaign_id', a.campaign_id, 'adset_name', a.adset_name, 'adset_id', a.adset_id,
      'ad_name', a.ad_name, 'ad_id', a.ad_id, 'form_name', a.form_name, 'form_id', a.form_id, 'platform', a.platform,
      'is_organic', a.is_organic, 'name', a.name, 'phone', a.phone_e164, 'email', a.email, 'answers', a.answers,
      'in_leads', a.crm_lead_id IS NOT NULL OR a.ads_lead_id IS NOT NULL) ORDER BY a.created_time DESC NULLS LAST), '[]')
    FROM (SELECT * FROM public.ads_meta_lead_archive ORDER BY created_time DESC NULLS LAST LIMIT 50000) a);
END $$;

-- Reconcile: a form never read in full is read for the 89 days Meta still holds, once; after that the usual 48 hours.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconcile_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'enabled', (crm_private.ads_meta_set('instant_form')).intake_enabled,
    'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('form_id', f.form_id,
                'since', floor(extract(epoch FROM CASE WHEN f.full_swept_at IS NULL THEN now() - interval '89 days'
                  ELSE least(now() - interval '48 hours', coalesce(f.last_reconciled_at - interval '1 hour', now() - interval '48 hours')) END)))
                ORDER BY f.form_id), '[]') FROM public.ads_meta_forms f WHERE f.active)) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_reconciled(p_form text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_forms SET last_reconciled_at = now(), full_swept_at = coalesce(full_swept_at, now()) WHERE form_id = p_form;
  INSERT INTO public.ads_config (key, value) VALUES ('meta_reconcile_last_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
$$;

-- ------------------------------------------------------------------------------------------- speed-to-lead alerts
CREATE OR REPLACE FUNCTION crm_private.ads_lead_alert_start(p_created timestamptz) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE f time; t time; loc timestamp := p_created AT TIME ZONE 'Asia/Kolkata'; st timestamp;
BEGIN
  f := CASE WHEN crm_private.ads_cfg('lead_alert_from') ~ '^\d{2}:\d{2}$' THEN crm_private.ads_cfg('lead_alert_from')::time ELSE '09:00' END;
  t := CASE WHEN crm_private.ads_cfg('lead_alert_to') ~ '^\d{2}:\d{2}$' THEN crm_private.ads_cfg('lead_alert_to')::time ELSE '20:00' END;
  IF loc::time < f THEN st := loc::date + f;
  ELSIF loc::time >= t THEN st := (loc::date + 1) + f;
  ELSE st := loc; END IF;
  RETURN st AT TIME ZONE 'Asia/Kolkata';
END $$;

-- Ad leads still waiting for a first call, with how long they have waited (working-hours clock).
CREATE OR REPLACE FUNCTION crm_private.ads_lead_waiting() RETURNS TABLE (lead_id uuid, waited_min int, owner uuid, crm_owner uuid, name text,
  course text, platform text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.id, greatest(0, floor(extract(epoch FROM now() - crm_private.ads_lead_alert_start(l.created_at)) / 60))::int,
         l.owner_employee_id, cl.assigned_to, l.name, l.course_interest,
         coalesce((SELECT x.platform FROM crm_private.ads_ad_leads() x WHERE x.lead_id = l.id LIMIT 1), 'unknown'), l.created_at
    FROM public.ads_lead l LEFT JOIN public.lead cl ON cl.id = l.organic_lead_id
   WHERE l.deleted_at IS NULL AND NOT l.quarantined AND l.stage = 'lead_created' AND l.first_response_at IS NULL
     AND cl.first_contacted_at IS NULL AND l.created_at > now() - interval '3 days'
     AND l.created_at >= coalesce(nullif(crm_private.ads_cfg('lead_alert_since'), '')::timestamptz, now() - interval '3 days')
     AND crm_private.ads_lead_alert_start(l.created_at) <= now() $$;

CREATE OR REPLACE FUNCTION crm_private.ads_lead_alerts_due() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_cfg('lead_alert_on') = 'on' AND EXISTS (
    SELECT 1 FROM crm_private.ads_lead_waiting() w
     WHERE (w.waited_min >= coalesce(nullif(crm_private.ads_cfg('lead_alert_minutes'), '')::int, 5)
            AND NOT EXISTS (SELECT 1 FROM public.ads_lead_alert a WHERE a.lead_id = w.lead_id AND a.level = 1))
        OR (w.waited_min >= coalesce(nullif(crm_private.ads_cfg('lead_alert_escalate_minutes'), '')::int, 15)
            AND NOT EXISTS (SELECT 1 FROM public.ads_lead_alert a WHERE a.lead_id = w.lead_id AND a.level = 2))) $$;

-- Claims due alerts with recipients, their devices and the email settings (service role, ads-sync).
CREATE OR REPLACE FUNCTION public.svc_ads_lead_alerts_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w record; lvl int; rcp uuid[]; out jsonb := '[]'; m1 int; m2 int; team uuid[]; admins uuid[];
BEGIN
  IF crm_private.ads_cfg('lead_alert_on') IS DISTINCT FROM 'on' THEN RETURN jsonb_build_object('alerts', '[]'); END IF;
  m1 := coalesce(nullif(crm_private.ads_cfg('lead_alert_minutes'), '')::int, 5);
  m2 := coalesce(nullif(crm_private.ads_cfg('lead_alert_escalate_minutes'), '')::int, 15);
  SELECT coalesce(array_agg(e.id), '{}') INTO admins FROM public.employee e WHERE e.active AND e.department::text = 'Admin';
  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO team FROM (
    SELECT a.employee_id x FROM public.ads_access a JOIN public.employee e ON e.id = a.employee_id AND e.active
    UNION SELECT unnest(admins)) z;
  FOR w IN SELECT * FROM crm_private.ads_lead_waiting() ORDER BY created_at LIMIT 50 LOOP
    lvl := CASE WHEN w.waited_min >= m2 AND NOT EXISTS (SELECT 1 FROM public.ads_lead_alert a WHERE a.lead_id = w.lead_id AND a.level = 2) THEN 2
                WHEN w.waited_min >= m1 AND NOT EXISTS (SELECT 1 FROM public.ads_lead_alert a WHERE a.lead_id = w.lead_id AND a.level = 1) THEN 1 END;
    CONTINUE WHEN lvl IS NULL;
    rcp := CASE WHEN lvl = 2 THEN admins || array_remove(ARRAY[w.owner, w.crm_owner], NULL)
                WHEN coalesce(w.owner, w.crm_owner) IS NOT NULL THEN ARRAY[coalesce(w.owner, w.crm_owner)]
                ELSE team END;
    INSERT INTO public.ads_lead_alert (lead_id, level, recipients) VALUES (w.lead_id, lvl, to_jsonb(rcp))
    ON CONFLICT DO NOTHING;
    IF lvl = 2 THEN   -- the first alert is skipped once the escalation is due
      INSERT INTO public.ads_lead_alert (lead_id, level, recipients, done_at, sent) VALUES (w.lead_id, 1, '[]', now(), '{"skipped": true}')
      ON CONFLICT DO NOTHING;
    END IF;
    out := out || jsonb_build_object('lead_id', w.lead_id, 'level', lvl, 'waited_min', w.waited_min,
      'first_name', split_part(coalesce(btrim(w.name), 'New lead'), ' ', 1), 'course', w.course, 'platform', w.platform,
      'emails', (SELECT coalesce(jsonb_agg(DISTINCT e.email), '[]') FROM public.employee e WHERE e.id = ANY (rcp) AND e.active AND e.email ~ '@'),
      'subs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))), '[]')
                 FROM public.amazon_push_subs s WHERE s.employee_id = ANY (rcp)));
  END LOOP;
  RETURN jsonb_build_object('alerts', out,
    'vapid_keys', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_vapid_keys'),
    'mail', public.svc_ads_meta_mail_config() - 'to');
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_lead_alerts_done(p_results jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x jsonb;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_results, '[]')) LOOP
    UPDATE public.ads_lead_alert SET sent = coalesce(x->'sent', '{}'), done_at = now()
     WHERE lead_id = (x->>'lead_id')::uuid AND level = (x->>'level')::int;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_alerts() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'settings', jsonb_build_object('on', crm_private.ads_cfg('lead_alert_on') = 'on',
      'minutes', coalesce(nullif(crm_private.ads_cfg('lead_alert_minutes'), '')::int, 5),
      'escalate_minutes', coalesce(nullif(crm_private.ads_cfg('lead_alert_escalate_minutes'), '')::int, 15),
      'from', crm_private.ads_cfg('lead_alert_from'), 'to', crm_private.ads_cfg('lead_alert_to'),
      'email_ready', crm_private.ads_meta_mail_ready(),
      'phones', (SELECT count(DISTINCT s.employee_id) FROM public.amazon_push_subs s)),
    'waiting', (SELECT coalesce(jsonb_agg(jsonb_build_object('lead_id', w.lead_id, 'name', w.name, 'course', w.course, 'platform', w.platform,
        'waited_min', w.waited_min, 'created_at', w.created_at,
        'alerted', (SELECT jsonb_agg(a.level ORDER BY a.level) FROM public.ads_lead_alert a WHERE a.lead_id = w.lead_id AND a.done_at IS NOT NULL
                      AND NOT coalesce((a.sent->>'skipped')::boolean, false))) ORDER BY w.created_at), '[]')
        FROM crm_private.ads_lead_waiting() w),
    'last_7d', (SELECT jsonb_build_object('alerts', count(*), 'escalated', count(*) FILTER (WHERE level = 2))
                  FROM public.ads_lead_alert WHERE created_at > now() - interval '7 days' AND NOT coalesce((sent->>'skipped')::boolean, false)),
    'median_first_call_min_30d', (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM l.first_response_at - l.created_at) / 60)::numeric)
        FROM public.ads_lead l WHERE l.first_response_at IS NOT NULL AND l.created_at > now() - interval '30 days'));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_alerts_save(p_cfg jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE m1 int; m2 int;
BEGIN
  PERFORM crm_private.ads_require_admin();
  m1 := CASE WHEN coalesce(p_cfg->>'minutes', '') ~ '^\d{1,3}$' THEN (p_cfg->>'minutes')::int END;
  m2 := CASE WHEN coalesce(p_cfg->>'escalate_minutes', '') ~ '^\d{1,3}$' THEN (p_cfg->>'escalate_minutes')::int END;
  IF m1 IS NULL OR m1 NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'First alert after 1 to 240 minutes' USING ERRCODE = 'PT422'; END IF;
  IF m2 IS NULL OR m2 <= m1 OR m2 > 480 THEN RAISE EXCEPTION 'Admin alert must come after the first alert (up to 480 minutes)' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p_cfg->>'from', '') !~ '^([01]\d|2[0-3]):[0-5]\d$' OR coalesce(p_cfg->>'to', '') !~ '^([01]\d|2[0-3]):[0-5]\d$'
     OR (p_cfg->>'to')::time <= (p_cfg->>'from')::time THEN
    RAISE EXCEPTION 'Working hours must be like 09:00 to 20:00' USING ERRCODE = 'PT422';
  END IF;
  PERFORM crm_private.ads_meta_set_cfg('lead_alert_on', CASE WHEN coalesce((p_cfg->>'on')::boolean, false) THEN 'on' ELSE 'off' END);
  PERFORM crm_private.ads_meta_set_cfg('lead_alert_minutes', m1::text);
  PERFORM crm_private.ads_meta_set_cfg('lead_alert_escalate_minutes', m2::text);
  PERFORM crm_private.ads_meta_set_cfg('lead_alert_from', p_cfg->>'from');
  PERFORM crm_private.ads_meta_set_cfg('lead_alert_to', p_cfg->>'to');
  RETURN public.api_ads_lead_alerts();
END $$;

-- ------------------------------------------------------------------------------------------- grants
REVOKE ALL ON FUNCTION crm_private.ads_meta_acct(), crm_private.ads_meta_goal_clean(jsonb), crm_private.ads_meta_leads_30d(),
  crm_private.ads_meta_plan_check(jsonb, jsonb), crm_private.ads_meta_agent_ctx(public.ads_agent_runs),
  crm_private.ads_meta_queue(bigint, text, int, jsonb, bigint), crm_private.ads_meta_save_version(public.ads_agent_runs, jsonb, jsonb, text),
  crm_private.ads_meta_chain_stop(public.ads_agent_runs, text), crm_private.ads_meta_runs_left(),
  crm_private.ads_meta_strategy_campaigns(public.ads_meta_strategy), crm_private.ads_meta_strategy_actual(public.ads_meta_strategy, date, date),
  crm_private.ads_meta_archive_raw(public.ads_meta_lead_raw), crm_private.ads_meta_archive_trg(),
  crm_private.ads_lead_alert_start(timestamptz), crm_private.ads_lead_waiting(), crm_private.ads_lead_alerts_due() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_strategy_create(jsonb), public.api_ads_meta_strategy_change(bigint, text, boolean, jsonb),
  public.api_ads_meta_strategy_approve(bigint, int), public.api_ads_meta_strategy_archive(bigint, boolean),
  public.api_ads_meta_strategy_link(bigint, jsonb), public.api_ads_meta_strategies(), public.api_ads_meta_strategy(bigint, int),
  public.api_ads_meta_strategy_build(bigint), public.api_ads_meta_leads_import(jsonb), public.api_ads_meta_archive(),
  public.api_ads_meta_archive_export(), public.api_ads_lead_alerts(), public.api_ads_lead_alerts_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_strategy_create(jsonb), public.api_ads_meta_strategy_change(bigint, text, boolean, jsonb),
  public.api_ads_meta_strategy_approve(bigint, int), public.api_ads_meta_strategy_archive(bigint, boolean),
  public.api_ads_meta_strategy_link(bigint, jsonb), public.api_ads_meta_strategies(), public.api_ads_meta_strategy(bigint, int),
  public.api_ads_meta_strategy_build(bigint), public.api_ads_meta_leads_import(jsonb), public.api_ads_meta_archive(),
  public.api_ads_meta_archive_export(), public.api_ads_lead_alerts(), public.api_ads_lead_alerts_save(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_ads_agent_next2(boolean), public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text),
  public.svc_ads_meta_build_work(bigint), public.svc_ads_meta_build_work_peek(bigint), public.svc_ads_meta_build_step(bigint, text, jsonb), public.svc_ads_meta_build_end(bigint, text, text),
  public.svc_ads_meta_build_image(bigint, text, text, text), public.svc_ads_meta_strategy_track(),
  public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text),
  public.svc_ads_lead_alerts_claim(), public.svc_ads_lead_alerts_done(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_agent_next2(boolean), public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text),
  public.svc_ads_meta_build_work(bigint), public.svc_ads_meta_build_work_peek(bigint), public.svc_ads_meta_build_step(bigint, text, jsonb), public.svc_ads_meta_build_end(bigint, text, text),
  public.svc_ads_meta_build_image(bigint, text, text, text), public.svc_ads_meta_strategy_track(),
  public.svc_ads_meta_reconcile_work(), public.svc_ads_meta_reconciled(text),
  public.svc_ads_lead_alerts_claim(), public.svc_ads_lead_alerts_done(jsonb) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '104')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- ------------------------------------------------------------------------------------------- schedules
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Mondays 06:05 India time: plan vs actual for last week
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-track';
    PERFORM cron.schedule('crm-ads-meta-track', '35 0 * * 1', $job$ SELECT public.svc_ads_meta_strategy_track() $job$);
    -- every 2 minutes: speed-to-lead alerts (wakes ads-sync only when one is due)
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-lead-alerts';
    PERFORM cron.schedule('crm-ads-lead-alerts', '*/2 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["lead_alerts"]}'::jsonb, timeout_milliseconds := 60000)
      WHERE crm_private.ads_lead_alerts_due()
    $job$);
  END IF;
END $$;
