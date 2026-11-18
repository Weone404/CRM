-- 109: Meta Ads > Funnel (batch B): lookalikes from the best leads, personas, the funnel plan, and creative-diversity
-- and funnel checks on every Strategy plan. Run after 108. Re-runnable. Rollback: 109_ads_meta_funnel_plan_down.sql.
--
--  * Lookalikes (kind 'lookalike'): made in Meta from CRM seeds (admissions, qualified, hot-scored) once a seed has the
--    100 people Meta requires (1,000+ gives steadier results), India, 1% and 1-3%. In 2026 they are hints to Advantage+
--    audience, not limits, so they go into new-people ad sets as suggestions only.
--  * Personas (ads_meta_persona, editable by Admin): who the ads speak to, what they ask (Search Console topics), their
--    objections, the proof they need, angles and the best funnel stage. Seeded with six, from public facts only.
--  * Funnel plan (api_ads_meta_funnel_blueprint): a monthly budget split into new people / retarget / re-engage, capped by
--    the real pool sizes and the account's own CPM, with expected leads a week and a learning-phase check (Meta needs about
--    50 optimisation events per ad set in 7 days). "Send to Strategy" puts the split and personas into the goal.
--  * Plan checks added to the Strategy (sent back to the Strategist if they fail): near-copy creatives (70%+ the same
--    words), too few distinct angles, unknown personas or audience keys, retarget / re-engage ad sets without an audience,
--    seed audiences used as hard limits on new-people ad sets, and the funnel split straying more than 10 points.

-- ------------------------------------------------------------------------------------------- lookalikes
ALTER TABLE public.ads_meta_audience DROP CONSTRAINT IF EXISTS ads_meta_audience_use_as_check;
ALTER TABLE public.ads_meta_audience ADD CONSTRAINT ads_meta_audience_use_as_check CHECK (use_as IN ('retarget', 'exclude', 'seed', 'reengage', 'prospect'));
ALTER TABLE public.ads_meta_audience DROP CONSTRAINT IF EXISTS ads_meta_audience_stage_check;
ALTER TABLE public.ads_meta_audience ADD CONSTRAINT ads_meta_audience_stage_check CHECK (stage IN ('cold', 'engaged', 'hot', 'lead', 'qualified', 'customer'));

INSERT INTO public.ads_meta_audience (key, name, kind, stage, use_as, spec, why, exclude_default) VALUES
  ('lal_customers_1', 'Lookalike 1%: like our admissions (India)', 'lookalike', 'cold', 'prospect',
     '{"seed": "crm_customers", "ratio": 0.01, "country": "IN"}', 'People most like the students who joined: the strongest seed, once it has 100+ matched people.', false),
  ('lal_qualified_1', 'Lookalike 1%: like our qualified leads (India)', 'lookalike', 'cold', 'prospect',
     '{"seed": "crm_qualified_365", "ratio": 0.01, "country": "IN"}', 'A bigger seed than admissions, still about quality rather than form fills.', false),
  ('lal_qualified_1_3', 'Lookalike 1-3%: like our qualified leads (India)', 'lookalike', 'cold', 'prospect',
     '{"seed": "crm_qualified_365", "starting_ratio": 0.01, "ratio": 0.03, "country": "IN"}', 'The next band out, for scale once the 1% works.', false),
  ('lal_hot_1', 'Lookalike 1%: like our hot-scored leads (India)', 'lookalike', 'cold', 'prospect',
     '{"seed": "crm_hot_90", "ratio": 0.01, "country": "IN"}', 'Early signal while admissions are still few.', false)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('on', crm_private.ads_cfg('meta_audiences_on') = 'true',
    'account_id', (crm_private.ads_meta_acct()).external_id,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'pixel_id', nullif(crm_private.ads_cfg('meta_pixel'), '')::jsonb->>'id',
    'forms', (SELECT coalesce(jsonb_agg(f.form_id ORDER BY f.updated_at DESC), '[]') FROM (SELECT * FROM public.ads_meta_forms ORDER BY updated_at DESC LIMIT 50) f),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'spec', a.spec, 'meta_id', a.meta_id, 'why', a.why,
        'people', CASE WHEN a.kind = 'crm' THEN (SELECT coalesce(jsonb_agg(jsonb_build_array(p.ph, p.em)), '[]')
                                                  FROM (SELECT * FROM crm_private.ads_meta_audience_people(a.spec) LIMIT 50000) p) END,
        'seed', CASE WHEN a.kind = 'lookalike' THEN (SELECT jsonb_build_object('key', s.key, 'meta_id', s.meta_id, 'status', s.status, 'size_low', s.size_low,
                                                       'members', s.members, 'enabled', s.enabled) FROM public.ads_meta_audience s WHERE s.key = a.spec->>'seed') END)
        ORDER BY CASE a.kind WHEN 'lookalike' THEN 1 ELSE 0 END, a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled AND a.kind IN ('engagement', 'crm', 'website', 'lookalike'))) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_saved(p_key text, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_audience SET
    meta_id = coalesce(substring(p_data->>'meta_id' FROM '^[0-9]{5,25}$'), meta_id),
    status = CASE WHEN p_data->>'status' IN ('ready', 'error', 'planned') THEN p_data->>'status' ELSE status END,
    size_low = CASE WHEN p_data ? 'size_low' THEN nullif(p_data->>'size_low', '')::bigint ELSE size_low END,
    size_high = CASE WHEN p_data ? 'size_high' THEN nullif(p_data->>'size_high', '')::bigint ELSE size_high END,
    members = CASE WHEN p_data ? 'members' THEN (p_data->>'members')::int ELSE members END,
    detail = left(p_data->>'detail', 600), synced_at = now(), updated_at = now()
   WHERE key = p_key $$;

-- ------------------------------------------------------------------------------------------- personas
CREATE TABLE IF NOT EXISTS public.ads_meta_persona (
  key text PRIMARY KEY CHECK (key ~ '^[a-z0-9_]{2,30}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 80),
  who text NOT NULL DEFAULT '',
  asks jsonb NOT NULL DEFAULT '[]',        -- Search Console topic keys (ads_site_topic) this person searches
  objections jsonb NOT NULL DEFAULT '[]',
  proof jsonb NOT NULL DEFAULT '[]',
  angles jsonb NOT NULL DEFAULT '[]',
  stages jsonb NOT NULL DEFAULT '[]',      -- prospecting / retarget / reengage
  form_questions jsonb NOT NULL DEFAULT '[]',
  enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_persona ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_persona FROM anon, authenticated;

INSERT INTO public.ads_meta_persona (key, name, who, asks, objections, proof, angles, stages, form_questions) VALUES
  ('pcm_finisher', 'Class 12 PCM finisher (18+)', 'Has finished or is finishing class 12 with Physics and Maths, 18 or older, exploring flying as a career; often still deciding with family.',
   '["after12", "eligibility", "cpl", "dgca"]',
   '["Is it really possible for me?", "How long does it take?", "Where do I start: ground classes or flying?"]',
   '["The DGCA path step by step (ground subjects, medical, flying)", "Real students and instructors on camera", "Batch dates and class format"]',
   '["The CPL path in 5 steps", "A day in DGCA ground class", "What to do in the months after class 12"]',
   '["prospecting", "retarget"]', '["When do you want to start?", "Have you done your Class 2 medical?"]'),
  ('parent', 'Parent funding the decision', 'Mother or father of an aspiring pilot, weighing cost, safety, approvals and what the institute actually provides.',
   '["fees", "loan", "salary", "eligibility"]',
   '["Total cost and what is included", "Is the institute DGCA-related and genuine?", "What if my child does not clear the exams?"]',
   '["Clear fee breakdown from the website", "Address, faculty and visit-the-campus offer", "How loans for pilot training work (lender, not promise)"]',
   '["Everything a parent should ask before paying", "Visit the classroom before you decide", "Cost, step by step, with nothing hidden"]',
   '["retarget", "reengage"]', '["Who is the student to you?", "Would you like a call or a campus visit?"]'),
  ('career_switcher', 'Graduate or working professional switching career', 'Finished a degree or working, in their 20s, wants a career change into flying; time and money are the main worries.',
   '["eligibility", "cpl", "fees", "loan"]',
   '["Am I too late?", "Can I keep my job while studying?", "Do I need PCM if my degree was not science?"]',
   '["Batch timings (weekend / evening if offered)", "The NIOS route for Physics and Maths", "Stories of people who switched"]',
   '["Not too late: the path for graduates", "Study DGCA subjects around your job", "No PCM? The NIOS route explained"]',
   '["prospecting"]', '["What do you do now?", "Did you study Physics and Maths in class 12?"]'),
  ('non_pcm', 'Non-PCM student', 'Did class 12 without Physics or Maths and wants to fly; needs to know the open-schooling route before anything else.',
   '["eligibility", "after12"]',
   '["Can I become a pilot without PCM?", "How long does NIOS take?"]',
   '["The NIOS Physics and Maths route, from the official requirement", "Students who took that route"]',
   '["No PCM? Here is the route", "Two subjects stand between you and the cockpit"]',
   '["prospecting"]', '["Which stream did you study in class 12?"]'),
  ('dgca_exam_only', 'DGCA ground-class / exam seeker', 'Already decided (often flying abroad or at another school) and needs DGCA ground subjects and exam preparation only.',
   '["dgca", "cpl"]',
   '["Which subjects and which session?", "Online or classroom?", "How do you prepare for the exam pattern?"]',
   '["Subject list and session calendar", "Mock tests and study material", "Faculty background"]',
   '["Clear Air Navigation first time", "Next DGCA session: plan backwards", "Mock tests that match the exam"]',
   '["prospecting", "retarget"]', '["Which DGCA subjects do you still need?", "Which exam session are you aiming for?"]'),
  ('cadet_aspirant', 'Airline cadet-programme aspirant', 'Wants an airline cadet programme and needs selection preparation (aptitude, maths, English, interview).',
   '["cadet", "eligibility"]',
   '["How do airline selections work?", "What do they test?"]',
   '["Selection-preparation syllabus", "Mock selection tests", "No claims of airline tie-ups unless documented"]',
   '["Prepare for cadet selection", "What the aptitude test checks"]',
   '["prospecting", "retarget"]', '["Which cadet programme are you preparing for?"]')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.api_ads_meta_personas() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(p) - 'updated_at' || jsonb_build_object('updated_at', p.updated_at,
      'search', (SELECT coalesce(jsonb_agg(jsonb_build_object('topic', t->>'label', 'impressions', t->'impressions', 'change', t->'change')), '[]')
                   FROM jsonb_array_elements(crm_private.ads_site_signals()->'topics') t WHERE p.asks ? (t->>'key'))) ORDER BY p.enabled DESC, p.key), '[]')
    FROM public.ads_meta_persona p);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_persona_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text := lower(btrim(coalesce(p->>'key', ''))); f text;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF k !~ '^[a-z0-9_]{2,30}$' THEN RAISE EXCEPTION 'Key: 2-30 lower-case letters, digits or _' USING ERRCODE = 'PT422'; END IF;
  IF length(btrim(coalesce(p->>'name', ''))) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'Name: 2-80 characters' USING ERRCODE = 'PT422'; END IF;
  IF length(coalesce(p->>'who', '')) > 600 THEN RAISE EXCEPTION 'Who: up to 600 characters' USING ERRCODE = 'PT422'; END IF;
  FOREACH f IN ARRAY ARRAY['asks', 'objections', 'proof', 'angles', 'stages', 'form_questions'] LOOP
    IF p ? f AND (jsonb_typeof(p->f) <> 'array' OR jsonb_array_length(p->f) > 12
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(p->f) x WHERE jsonb_typeof(x) <> 'string' OR length(x #>> '{}') NOT BETWEEN 1 AND 200)) THEN
      RAISE EXCEPTION '%: up to 12 short lines', f USING ERRCODE = 'PT422';
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p->'stages', '[]')) x WHERE x NOT IN ('prospecting', 'retarget', 'reengage')) THEN
    RAISE EXCEPTION 'Stages are prospecting, retarget or reengage' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_meta_persona (key, name, who, asks, objections, proof, angles, stages, form_questions, enabled)
  VALUES (k, btrim(p->>'name'), coalesce(p->>'who', ''), coalesce(p->'asks', '[]'), coalesce(p->'objections', '[]'), coalesce(p->'proof', '[]'),
          coalesce(p->'angles', '[]'), coalesce(p->'stages', '[]'), coalesce(p->'form_questions', '[]'), coalesce((p->>'enabled')::boolean, true))
  ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name, who = EXCLUDED.who,
    asks = CASE WHEN p ? 'asks' THEN EXCLUDED.asks ELSE ads_meta_persona.asks END,
    objections = CASE WHEN p ? 'objections' THEN EXCLUDED.objections ELSE ads_meta_persona.objections END,
    proof = CASE WHEN p ? 'proof' THEN EXCLUDED.proof ELSE ads_meta_persona.proof END,
    angles = CASE WHEN p ? 'angles' THEN EXCLUDED.angles ELSE ads_meta_persona.angles END,
    stages = CASE WHEN p ? 'stages' THEN EXCLUDED.stages ELSE ads_meta_persona.stages END,
    form_questions = CASE WHEN p ? 'form_questions' THEN EXCLUDED.form_questions ELSE ads_meta_persona.form_questions END,
    enabled = EXCLUDED.enabled, updated_at = now();
  PERFORM crm_private.ads_log('meta_persona_saved', 'meta_persona', k, '{}');
  RETURN jsonb_build_object('ok', true, 'key', k);
END $$;

-- ------------------------------------------------------------------------------------------- funnel plan
-- p_split: {"prospecting": 70, "retarget": 20, "reengage": 10} (percent; any missing part uses these defaults).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_funnel_blueprint(p_monthly numeric, p_split jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); today date := crm_private.ads_meta_today();
        h record; cpm numeric; cpl numeric; qrate numeric; daily numeric; sp jsonb; want jsonb := '{}'; got jsonb := '{}';
        warm bigint; reeng bigint; cap numeric; cap_re numeric; notes text[] := '{}'; st text; d numeric; moved numeric := 0;
        stages jsonb := '[]'; lw numeric; ready_ex jsonb; lal jsonb;
BEGIN
  IF p_monthly IS NULL OR p_monthly < 3000 OR p_monthly > 100000000 THEN RAISE EXCEPTION 'Monthly budget of at least ₹3,000' USING ERRCODE = 'PT422'; END IF;
  daily := round(p_monthly / 30.4, 2);
  sp := jsonb_build_object('prospecting', 70, 'retarget', 20, 'reengage', 10) || coalesce(p_split, '{}');
  IF EXISTS (SELECT 1 FROM jsonb_each_text(sp) e WHERE e.key NOT IN ('prospecting', 'retarget', 'reengage') OR e.value !~ '^\d{1,3}(\.\d+)?$')
     OR (SELECT sum(e.value::numeric) FROM jsonb_each_text(sp) e) NOT BETWEEN 99.5 AND 100.5 THEN
    RAISE EXCEPTION 'The split is three percentages (new people, retarget, re-engage) that add up to 100' USING ERRCODE = 'PT422';
  END IF;
  SELECT sum(d.spend) spend, sum(d.impressions) imp, sum(d.leads) leads INTO h FROM public.ads_meta_ad_day d WHERE d.account_id = acc.id AND d.day > today - 90;
  cpm := CASE WHEN h.imp > 1000 THEN round(1000 * h.spend / h.imp, 2) END;
  cpl := CASE WHEN h.leads > 10 THEN round(h.spend / h.leads, 2) END;
  SELECT CASE WHEN count(*) FILTER (WHERE known) >= 20 THEN round(count(*) FILTER (WHERE qualified)::numeric / count(*) FILTER (WHERE known), 3) END INTO qrate
    FROM crm_private.ads_meta_lead_facts(today - 180, today);
  SELECT coalesce(sum(size_high), 0) INTO warm FROM public.ads_meta_audience WHERE enabled AND status = 'ready' AND stage IN ('hot', 'engaged') AND kind IN ('engagement', 'website');
  SELECT coalesce(sum(coalesce(size_high, members)), 0) INTO reeng FROM public.ads_meta_audience WHERE enabled AND status = 'ready' AND key IN ('crm_open_180', 'crm_lost_365');
  want := jsonb_build_object('prospecting', daily * (sp->>'prospecting')::numeric / 100, 'retarget', daily * (sp->>'retarget')::numeric / 100,
                             'reengage', daily * (sp->>'reengage')::numeric / 100);
  -- a small pool cannot absorb a big budget: about 3 ads a week per person at the account's CPM
  cap := CASE WHEN cpm IS NOT NULL THEN round(warm * 3 / 7.0 * cpm / 1000, 2) END;
  cap_re := CASE WHEN cpm IS NOT NULL THEN round(reeng * 3 / 7.0 * cpm / 1000, 2) END;
  got := want;
  IF warm = 0 AND (want->>'retarget')::numeric > 0 THEN
    moved := moved + (want->>'retarget')::numeric; got := got || '{"retarget": 0}';
    notes := notes || 'No warm or hot audience is ready in Meta yet: the retarget share goes to new people until the audience library fills.'::text;
  ELSIF cap IS NOT NULL AND (want->>'retarget')::numeric > cap THEN
    moved := moved + (want->>'retarget')::numeric - cap; got := got || jsonb_build_object('retarget', cap);
    notes := notes || format('Warm and hot pools (~%s people) can take about ₹%s a day at your CPM (₹%s): the rest goes to new people.', warm, cap, cpm);
  END IF;
  IF reeng = 0 AND (want->>'reengage')::numeric > 0 THEN
    moved := moved + (want->>'reengage')::numeric; got := got || '{"reengage": 0}';
    notes := notes || 'No re-engage list is ready in Meta yet (open / lost leads with consent): that share goes to new people.'::text;
  ELSIF cap_re IS NOT NULL AND (want->>'reengage')::numeric > cap_re THEN
    moved := moved + (want->>'reengage')::numeric - cap_re; got := got || jsonb_build_object('reengage', cap_re);
    notes := notes || format('The re-engage list (~%s people) can take about ₹%s a day: the rest goes to new people.', reeng, cap_re);
  END IF;
  got := got || jsonb_build_object('prospecting', round((got->>'prospecting')::numeric + moved, 2));
  SELECT coalesce(jsonb_agg(key), '[]') INTO ready_ex FROM public.ads_meta_audience WHERE enabled AND exclude_default;
  SELECT coalesce(jsonb_agg(key ORDER BY key), '[]') INTO lal FROM public.ads_meta_audience WHERE enabled AND kind = 'lookalike' AND status = 'ready';
  FOREACH st IN ARRAY ARRAY['prospecting', 'retarget', 'reengage'] LOOP
    d := round((got->>st)::numeric, 2);
    CONTINUE WHEN d <= 0;
    lw := CASE WHEN cpl IS NOT NULL THEN round(d * 7 / cpl, 1) END;
    stages := stages || jsonb_build_object('stage', st, 'daily', d, 'monthly', round(d * 30.4), 'share', round(100 * d / daily, 1),
      'label', CASE st WHEN 'prospecting' THEN 'Find new people' WHEN 'retarget' THEN 'Bring back warm and hot people' ELSE 'Re-engage old leads' END,
      'include', CASE st WHEN 'prospecting' THEN lal
                         WHEN 'retarget' THEN (SELECT coalesce(jsonb_agg(key ORDER BY key), '[]') FROM public.ads_meta_audience WHERE enabled AND stage IN ('hot', 'engaged') AND kind IN ('engagement', 'website'))
                         ELSE '["crm_open_180", "crm_lost_365"]'::jsonb END,
      'include_is', CASE st WHEN 'prospecting' THEN 'hints for Advantage+ audience (lookalikes and seeds); location and exclusions are the limits' ELSE 'the audience itself' END,
      'exclude', CASE st WHEN 'prospecting' THEN ready_ex ELSE '["crm_customers"]'::jsonb END,
      'form', CASE st WHEN 'prospecting' THEN 'higher intent, 1-2 qualifying questions (conditional logic can end the form for clearly unqualified answers)'
                      WHEN 'retarget' THEN 'higher intent, short; or a WhatsApp chat ad for people who dropped off'
                      ELSE 'short form tied to the new offer (webinar, campus visit, batch date)' END,
      'message', CASE st WHEN 'prospecting' THEN 'one persona and one problem per concept; 3+ distinct concepts'
                         WHEN 'retarget' THEN 'answer the question they stopped at: fees, eligibility, process, proof'
                         ELSE 'something new since they last spoke to us' END,
      'personas', (SELECT coalesce(jsonb_agg(p.key ORDER BY p.key), '[]') FROM public.ads_meta_persona p WHERE p.enabled AND p.stages ? st),
      'kpi', CASE st WHEN 'prospecting' THEN 'cost per qualified lead' WHEN 'retarget' THEN 'cost per lead and lead-to-qualified rate' ELSE 'qualified leads and admissions from old leads' END,
      'leads_per_week', lw,
      'learning', CASE WHEN lw IS NULL THEN 'unknown: no cost-per-lead history yet'
                       WHEN lw >= 50 THEN 'enough for about ' || floor(lw / 50) || ' ad set(s) to exit learning'
                       ELSE format('about %s leads a week: keep it to ONE ad set (Meta needs about 50 a week per ad set to exit learning)', lw) END);
  END LOOP;
  IF cpl IS NULL THEN notes := notes || 'No cost-per-lead history in the last 90 days: expected leads cannot be estimated yet.'::text; END IF;
  RETURN jsonb_build_object('monthly', p_monthly, 'daily', daily, 'split_asked', sp, 'cpm', cpm, 'cpl', cpl, 'q_rate', qrate,
    'warm_pool', warm, 'reengage_pool', reeng, 'stages', stages, 'notes', to_jsonb(notes),
    'qualified_per_month', CASE WHEN cpl IS NOT NULL AND qrate IS NOT NULL THEN round(p_monthly / cpl * qrate) END);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_funnel_blueprint(p_monthly numeric, p_split jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_meta_funnel_blueprint(p_monthly, p_split);
END $$;

-- ------------------------------------------------------------------------------------------- goal: funnel split and personas
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_meta_goal_clean_base(jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_goal_clean(jsonb) RENAME TO ads_meta_goal_clean_base;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_plan_check_base(jsonb,jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_plan_check(jsonb, jsonb) RENAME TO ads_meta_plan_check_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_goal_clean(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE o jsonb := crm_private.ads_meta_goal_clean_base(p); sp jsonb; ks jsonb;
BEGIN
  IF jsonb_typeof(p->'funnel') = 'object' AND jsonb_typeof(p->'funnel'->'split') = 'object' THEN
    sp := jsonb_build_object('prospecting', 70, 'retarget', 20, 'reengage', 10) || (p->'funnel'->'split');
    IF EXISTS (SELECT 1 FROM jsonb_each_text(sp) e WHERE e.key NOT IN ('prospecting', 'retarget', 'reengage') OR e.value !~ '^\d{1,3}(\.\d+)?$')
       OR (SELECT sum(e.value::numeric) FROM jsonb_each_text(sp) e) NOT BETWEEN 99.5 AND 100.5 THEN
      RAISE EXCEPTION 'The funnel split is three percentages that add up to 100' USING ERRCODE = 'PT422';
    END IF;
    o := o || jsonb_build_object('funnel', jsonb_build_object('split', sp));
  END IF;
  IF jsonb_typeof(p->'personas') = 'array' THEN
    SELECT coalesce(jsonb_agg(DISTINCT x), '[]') INTO ks FROM jsonb_array_elements_text(p->'personas') x
     WHERE EXISTS (SELECT 1 FROM public.ads_meta_persona pp WHERE pp.key = x AND pp.enabled);
    IF jsonb_array_length(ks) > 6 THEN RAISE EXCEPTION 'Pick up to 6 personas' USING ERRCODE = 'PT422'; END IF;
    IF jsonb_array_length(ks) > 0 THEN o := o || jsonb_build_object('personas', ks); END IF;
  END IF;
  RETURN o;
END $$;

-- word-set overlap of two texts (Jaccard), for near-copy creatives
CREATE OR REPLACE FUNCTION crm_private.ads_text_overlap(a text, b text) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH x AS (SELECT DISTINCT w FROM regexp_split_to_table(lower(coalesce(a, '')), '[^[:alnum:]]+') w WHERE length(w) > 2),
       y AS (SELECT DISTINCT w FROM regexp_split_to_table(lower(coalesce(b, '')), '[^[:alnum:]]+') w WHERE length(w) > 2)
  SELECT CASE WHEN (SELECT count(*) FROM (SELECT w FROM x UNION SELECT w FROM y) u) < 6 THEN 0
    ELSE round((SELECT count(*) FROM x JOIN y USING (w))::numeric / (SELECT count(*) FROM (SELECT w FROM x UNION SELECT w FROM y) u), 2) END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_check(p_goal jsonb, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE base jsonb := crm_private.ads_meta_plan_check_base(p_goal, p); pr text[] := '{}'; r record; c jsonb; a jsonb; k text; fn text;
        tot numeric := 0; byf jsonb := '{}'; d numeric; n int; angles int;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN base; END IF;
  -- creatives: near copies and distinct angles (Meta groups look-alike ads; distinct concepts reach different people)
  IF jsonb_typeof(p->'creatives') = 'array' THEN
    FOR r IN SELECT x->>'key' k1, y->>'key' k2, crm_private.ads_text_overlap(concat_ws(' ', x->>'primary_text', x->>'headline'), concat_ws(' ', y->>'primary_text', y->>'headline')) ov
               FROM jsonb_array_elements(p->'creatives') WITH ORDINALITY x(x, i) JOIN jsonb_array_elements(p->'creatives') WITH ORDINALITY y(y, j) ON j > i LOOP
      IF r.ov >= 0.7 THEN pr := pr || format('Creatives %s and %s are near copies (%s%% the same words): Meta treats look-alike ads as one, so make them different concepts (persona, problem, format).', r.k1, r.k2, round(100 * r.ov)); END IF;
    END LOOP;
    n := jsonb_array_length(p->'creatives');
    SELECT count(DISTINCT lower(btrim(x->>'angle'))) INTO angles FROM jsonb_array_elements(p->'creatives') x WHERE coalesce(btrim(x->>'angle'), '') <> '';
    IF n >= 4 AND angles < 3 THEN pr := pr || format('%s creatives but only %s distinct angles: give at least 3 different angles.', n, angles); END IF;
    FOR c IN SELECT * FROM jsonb_array_elements(p->'creatives') LOOP
      IF coalesce(c->>'persona', '') <> '' AND NOT EXISTS (SELECT 1 FROM public.ads_meta_persona pp WHERE pp.key = c->>'persona' AND pp.enabled) THEN
        pr := pr || format('Creative %s: persona "%s" is not one of CONTEXT.personas.', c->>'key', left(c->>'persona', 30));
      END IF;
    END LOOP;
    IF jsonb_typeof(p_goal->'personas') = 'array' THEN
      FOR k IN SELECT * FROM jsonb_array_elements_text(p_goal->'personas') LOOP
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p->'creatives') x WHERE x->>'persona' = k) THEN
          pr := pr || format('The goal asks for persona %s but no creative speaks to it (set "persona" on a creative).', k);
        END IF;
      END LOOP;
    END IF;
  END IF;
  -- ad sets: funnel stage, audience keys, seeds as hints only
  IF jsonb_typeof(p->'campaigns') = 'array' THEN
    FOR c IN SELECT * FROM jsonb_array_elements(p->'campaigns') LOOP
      CONTINUE WHEN jsonb_typeof(c->'adsets') <> 'array';
      n := jsonb_array_length(c->'adsets');
      FOR a IN SELECT * FROM jsonb_array_elements(c->'adsets') LOOP
        fn := coalesce(a->'audience'->>'funnel', 'prospecting');
        IF fn NOT IN ('prospecting', 'retarget', 'reengage') THEN pr := pr || format('Ad set %s: funnel must be prospecting, retarget or reengage.', a->>'key'); END IF;
        FOR k IN SELECT * FROM jsonb_array_elements_text(coalesce(a->'audience'->'include_audiences', '[]') || coalesce(a->'audience'->'exclude_audiences', '[]')) LOOP
          IF NOT EXISTS (SELECT 1 FROM public.ads_meta_audience x WHERE x.key = k AND x.enabled) THEN
            pr := pr || format('Ad set %s: audience "%s" is not in CONTEXT.audiences.', a->>'key', left(k, 40));
          END IF;
        END LOOP;
        IF fn IN ('retarget', 'reengage') AND jsonb_array_length(coalesce(a->'audience'->'include_audiences', '[]')) = 0 THEN
          pr := pr || format('Ad set %s is %s but names no audience to include.', a->>'key', fn);
        END IF;
        IF fn = 'prospecting' AND jsonb_array_length(coalesce(a->'audience'->'include_audiences', '[]')) > 0 AND coalesce((a->'audience'->>'advantage_audience')::boolean, false) IS NOT TRUE THEN
          pr := pr || format('Ad set %s finds new people but includes audiences without Advantage+ audience: that limits it to those lists. Turn advantage_audience on (they become hints) or remove them.', a->>'key');
        END IF;
        d := coalesce(nullif(a->>'daily_budget', '')::numeric, CASE WHEN n > 0 THEN nullif(c->>'daily_budget', '')::numeric / n END, 0);
        tot := tot + d;
        byf := byf || jsonb_build_object(fn, coalesce((byf->>fn)::numeric, 0) + d);
      END LOOP;
    END LOOP;
  END IF;
  -- the funnel split asked for in the goal (within 10 points)
  IF jsonb_typeof(p_goal->'funnel'->'split') = 'object' AND tot > 0 THEN
    FOR k IN SELECT * FROM jsonb_object_keys(p_goal->'funnel'->'split') LOOP
      d := round(100 * coalesce((byf->>k)::numeric, 0) / tot, 1);
      IF abs(d - (p_goal->'funnel'->'split'->>k)::numeric) > 10 AND NOT ((p_goal->'funnel'->'split'->>k)::numeric > 0 AND d = 0 AND k <> 'prospecting'
           AND NOT EXISTS (SELECT 1 FROM public.ads_meta_audience x WHERE x.enabled AND x.status = 'ready'
                             AND ((k = 'retarget' AND x.stage IN ('hot', 'engaged')) OR (k = 'reengage' AND x.key IN ('crm_open_180', 'crm_lost_365'))))) THEN
        pr := pr || format('The goal splits %s%% to %s but the plan gives it %s%% of the daily budget (allowed: within 10 points).', p_goal->'funnel'->'split'->>k, k, d);
      END IF;
    END LOOP;
  END IF;
  RETURN to_jsonb((pr[1:15] || ARRAY(SELECT jsonb_array_elements_text(base)))[1:40]);
END $$;

-- ------------------------------------------------------------------------------------------- agents' context: + personas
CREATE OR REPLACE FUNCTION public.svc_ads_meta_strategy_extra() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := crm_private.ads_meta_today(); f jsonb; g jsonb; s jsonb;
BEGIN
  f := crm_private.ads_meta_funnel_data(today - 90, today);
  g := crm_private.ads_meta_geo_data(today - 365, today);
  s := crm_private.ads_site_signals();
  RETURN jsonb_build_object(
    'funnel_90d', jsonb_build_object('stages', f->'stages', 'spend', f->'spend', 'first_call_min', f->'first_call_min', 'qualify_days', f->'qualify_days', 'notes', f->'notes'),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'stage', a.stage, 'use_as', a.use_as,
        'ready_in_meta', a.status = 'ready', 'size', a.size_high, 'excluded_by_default', a.exclude_default) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled),
    'personas', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', p.key, 'name', p.name, 'who', p.who, 'asks', p.asks, 'objections', p.objections,
        'proof', p.proof, 'angles', p.angles, 'stages', p.stages, 'form_questions', p.form_questions) ORDER BY p.key), '[]')
      FROM public.ads_meta_persona p WHERE p.enabled),
    'locations', jsonb_build_object('avg_q_rate', g->'avg_q_rate', 'regions', (SELECT coalesce(jsonb_agg(r), '[]') FROM (SELECT r FROM jsonb_array_elements(g->'regions') r LIMIT 15) z),
      'unknown_location', g->'unknown_location'),
    'website', jsonb_build_object('configured', s->'configured', 'totals', s->'totals', 'pixel', s->'pixel',
      'topics', s->'topics', 'rising', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'rising') x LIMIT 10) z),
      'pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'pages') x LIMIT 10) z),
      'cities', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'cities') x LIMIT 10) z),
      'web_funnel', s->'web_funnel'));
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_funnel_blueprint(numeric, jsonb), crm_private.ads_text_overlap(text, text),
  crm_private.ads_meta_goal_clean(jsonb), crm_private.ads_meta_plan_check(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_personas(), public.api_ads_meta_persona_save(jsonb), public.api_ads_meta_funnel_blueprint(numeric, jsonb),
  public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_strategy_extra() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_personas(), public.api_ads_meta_persona_save(jsonb), public.api_ads_meta_funnel_blueprint(numeric, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_strategy_extra() TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '109')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
