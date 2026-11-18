-- 114: Meta Ads > premium audience. Run after 109 (and 111-113). Re-runnable. Rollback: 114_ads_meta_premium_down.sql.
--  * Premium filter (goal.premium, on unless switched off): every form asks how training will be funded, one creative states
--    the published fee range, parents are spoken to (parent-only ad sets 35+); under-18s never targeted.
--  * Budget fold: a funnel share under ₹100 a day (Meta's minimum per ad set) goes to finding new people instead of failing the plan.
--  * Locations: metro preset; PIN codes (type zip) and household income only when Meta confirms them for this account
--    (ads-sync saves what Meta's targeting search answers to meta_targeting_support).

-- base check (from 104): locations may also be 6-digit PIN codes (type zip)
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_check_base(p_goal jsonb, p jsonb) RETURNS jsonb
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
                         WHERE coalesce(l->>'type', '') NOT IN ('country', 'region', 'city', 'zip') OR coalesce(l->>'name', '') = ''
                            OR (l->>'type' = 'zip' AND l->>'name' !~ '^[1-9][0-9]{5}$')) THEN
            pr := pr || format('Ad set %s: locations need a name and a type (country, region, city, or zip with a 6-digit PIN code).', t);
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
-- ------------------------------------------------------------------------------------------- settings
INSERT INTO public.ads_config (key, value) VALUES
  ('meta_metro_preset', '[{"name": "Delhi", "type": "city"}, {"name": "Gurgaon", "type": "city"}, {"name": "Noida", "type": "city"},
     {"name": "Mumbai", "type": "city"}, {"name": "Bangalore", "type": "city"}, {"name": "Hyderabad", "type": "city"}, {"name": "Chennai", "type": "city"},
     {"name": "Kolkata", "type": "city"}, {"name": "Pune", "type": "city"}, {"name": "Ahmedabad", "type": "city"}]'),
  ('meta_targeting_support', '{}')
ON CONFLICT (key) DO NOTHING;

-- personas: MBA graduates in the switcher; parents are decision makers from the first ad, not only in retargeting
UPDATE public.ads_meta_persona SET name = 'Graduate, MBA or working professional switching career',
  who = 'Finished a degree (often an MBA or engineering) or working, in their 20s or early 30s, wants a career change into flying; time and money are the main worries.'
 WHERE key = 'career_switcher' AND name = 'Graduate or working professional switching career';
UPDATE public.ads_meta_persona SET stages = '["prospecting", "retarget", "reengage"]'
 WHERE key = 'parent' AND stages = '["retarget", "reengage"]'::jsonb;

-- ------------------------------------------------------------------------------------------- goal: premium audience (on unless switched off)
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_meta_goal_clean_v109(jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_goal_clean(jsonb) RENAME TO ads_meta_goal_clean_v109;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_plan_check_v109(jsonb,jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_plan_check(jsonb, jsonb) RENAME TO ads_meta_plan_check_v109;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_funnel_blueprint_v109(numeric,jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_funnel_blueprint(numeric, jsonb) RENAME TO ads_meta_funnel_blueprint_v109;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_strategy_extra_v109()') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_strategy_extra() RENAME TO svc_ads_meta_strategy_extra_v109;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_goal_clean(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  RETURN crm_private.ads_meta_goal_clean_v109(p)
    || jsonb_build_object('premium', CASE WHEN jsonb_typeof(p->'premium') = 'boolean' THEN (p->>'premium')::boolean ELSE true END);
END $$;

-- ------------------------------------------------------------------------------------------- budget: shares below ₹100 a day fold into new people
CREATE OR REPLACE FUNCTION crm_private.ads_meta_funnel_blueprint(p_monthly numeric, p_split jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE b jsonb := crm_private.ads_meta_funnel_blueprint_v109(p_monthly, p_split); st jsonb; keep jsonb := '[]'; moved numeric := 0;
        folded text[] := '{}'; pros jsonb; d numeric; need numeric; cpl numeric := nullif(b->>'cpl', '')::numeric; daily numeric := (b->>'daily')::numeric; lw numeric;
BEGIN
  FOR st IN SELECT * FROM jsonb_array_elements(b->'stages') LOOP
    IF st->>'stage' <> 'prospecting' AND (st->>'daily')::numeric < 100 THEN
      moved := moved + (st->>'daily')::numeric; folded := folded || (st->>'label');
    ELSE keep := keep || st; END IF;
  END LOOP;
  IF moved = 0 THEN RETURN b; END IF;
  SELECT x INTO pros FROM jsonb_array_elements(keep) x WHERE x->>'stage' = 'prospecting';
  d := round(coalesce((pros->>'daily')::numeric, 0) + moved, 2);
  lw := CASE WHEN cpl IS NOT NULL THEN round(d * 7 / cpl, 1) END;
  pros := coalesce(pros, '{"stage": "prospecting", "label": "Find new people"}') || jsonb_build_object('daily', d, 'monthly', round(d * 30.4),
    'share', round(100 * d / daily, 1), 'leads_per_week', lw,
    'learning', CASE WHEN lw IS NULL THEN 'unknown: no cost-per-lead history yet'
                     WHEN lw >= 50 THEN 'enough for about ' || floor(lw / 50) || ' ad set(s) to exit learning'
                     ELSE format('about %s leads a week: keep it to ONE ad set (Meta needs about 50 a week per ad set to exit learning)', lw) END);
  keep := (SELECT coalesce(jsonb_agg(x), '[]') FROM jsonb_array_elements(keep) x WHERE x->>'stage' <> 'prospecting');
  need := ceil(100 / nullif(least(coalesce((b->'split_asked'->>'retarget')::numeric, 20), coalesce((b->'split_asked'->>'reengage')::numeric, 10)), 0) * 30.4) * 100;
  RETURN b || jsonb_build_object('stages', jsonb_build_array(pros) || keep, 'folded', to_jsonb(folded),
    'notes', coalesce(b->'notes', '[]') || to_jsonb(CASE WHEN p_monthly < need
      THEN format('%s would get under ₹100 a day, Meta''s minimum per ad set: folded into finding new people. A full funnel needs about ₹%s a month at this split.',
             array_to_string(folded, ' and '), to_char(need, 'FM99,99,99,999'))
      ELSE format('%s: its audience is still too small to spend ₹100 a day (Meta''s minimum per ad set), so it is folded into finding new people until the pool grows.',
             array_to_string(folded, ' and ')) END));
END $$;

-- ------------------------------------------------------------------------------------------- plan checks: premium filter, parents, PIN codes, small budgets
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_check(p_goal jsonb, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE g jsonb := coalesce(p_goal, '{}'); pr text[] := '{}'; base jsonb; c jsonb; a jsonb; f jsonb; k text; tot numeric := 0; n int; d numeric;
        sup jsonb := coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_targeting_support'), '')::jsonb, '{}'); fold numeric := 0;
        parent_ads text[]; ad_personas text[];
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN crm_private.ads_meta_plan_check_v109(g, p); END IF;
  -- a split share that would be under ₹100 a day cannot be its own ad set: judge the plan against the folded split
  IF jsonb_typeof(p->'campaigns') = 'array' THEN
    FOR c IN SELECT * FROM jsonb_array_elements(p->'campaigns') LOOP
      CONTINUE WHEN jsonb_typeof(c->'adsets') <> 'array';
      n := jsonb_array_length(c->'adsets');
      FOR a IN SELECT * FROM jsonb_array_elements(c->'adsets') LOOP
        tot := tot + coalesce(nullif(a->>'daily_budget', '')::numeric, CASE WHEN n > 0 THEN nullif(c->>'daily_budget', '')::numeric / n END, 0);
      END LOOP;
    END LOOP;
  END IF;
  IF jsonb_typeof(g->'funnel'->'split') = 'object' AND tot > 0 THEN
    FOR k IN SELECT x FROM jsonb_object_keys(g->'funnel'->'split') x WHERE x <> 'prospecting' LOOP
      d := (g->'funnel'->'split'->>k)::numeric;
      IF d > 0 AND tot * d / 100 < 100 THEN
        fold := fold + d;
        g := jsonb_set(g, ARRAY['funnel', 'split', k], '0'::jsonb);
      END IF;
    END LOOP;
    IF fold > 0 THEN g := jsonb_set(g, '{funnel,split,prospecting}', to_jsonb(coalesce((g->'funnel'->'split'->>'prospecting')::numeric, 0) + fold)); END IF;
  END IF;
  base := crm_private.ads_meta_plan_check_v109(g, p);

  -- premium audience (goal.premium, on by default): the forms and ads do the filtering Meta's targeting no longer can
  IF coalesce((g->>'premium')::boolean, true) THEN
    IF jsonb_typeof(p->'forms') = 'array' THEN
      FOR f IN SELECT * FROM jsonb_array_elements(p->'forms') LOOP
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(f->'questions', '[]')) q
                        WHERE q->>'type' = 'CUSTOM' AND lower(q->>'label') ~ '(fund|financ|budget|loan|invest|afford|sponsor)') THEN
          pr := pr || format('Form %s: add a question on how training will be funded (for example "How do you plan to fund the training?" with options such as family funded / education loan / still exploring): it is the premium filter.', coalesce(f->>'key', '?'));
        END IF;
      END LOOP;
    END IF;
    IF jsonb_typeof(p->'creatives') = 'array' AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p->'creatives') x
         WHERE concat_ws(' ', x->>'primary_text', x->>'description') ~* '(₹|rs\.?\s?[0-9]|lakh|lac\y)') THEN
      pr := pr || 'State the training investment (the fee range published on the website, in ₹ lakh) in at least one creative: people who cannot afford it skip the ad, which no targeting setting can do.'::text;
    END IF;
    SELECT coalesce(array_agg(x->>'key'), '{}') INTO parent_ads FROM jsonb_array_elements(coalesce(p->'creatives', '[]')) x WHERE x->>'persona' = 'parent';
    IF cardinality(parent_ads) = 0 THEN
      pr := pr || 'Speak to parents too: at least one creative with persona "parent" (they decide and fund the training; under-18 students are reached only through them).'::text;
    END IF;
    -- an ad set showing only parent ads keeps a hard minimum age of 35
    IF jsonb_typeof(p->'campaigns') = 'array' THEN
      FOR c IN SELECT * FROM jsonb_array_elements(p->'campaigns') LOOP
        CONTINUE WHEN jsonb_typeof(c->'adsets') <> 'array';
        FOR a IN SELECT * FROM jsonb_array_elements(c->'adsets') LOOP
          SELECT coalesce(array_agg(DISTINCT coalesce(x->>'persona', '')), '{}') INTO ad_personas FROM jsonb_array_elements(coalesce(p->'creatives', '[]')) x
           WHERE x->>'key' IN (SELECT jsonb_array_elements_text(coalesce(a->'ads', '[]')));
          IF ad_personas = ARRAY['parent'] AND coalesce(nullif(a->'audience'->>'age_min', '')::int, 18) < 35 THEN
            pr := pr || format('Ad set %s shows only parent ads: set its minimum age to 35 or more.', a->>'key');
          END IF;
        END LOOP;
      END LOOP;
    END IF;
  END IF;

  -- PIN codes and household income only where Meta answered that they exist for India (Meta Ads > Setup checks it)
  IF jsonb_typeof(p->'campaigns') = 'array' THEN
    FOR c IN SELECT * FROM jsonb_array_elements(p->'campaigns') LOOP
      CONTINUE WHEN jsonb_typeof(c->'adsets') <> 'array';
      FOR a IN SELECT * FROM jsonb_array_elements(c->'adsets') LOOP
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(a->'audience'->'locations', '[]')) l WHERE l->>'type' = 'zip') THEN
          IF coalesce((sup->'zip'->>'ok')::boolean, false) IS NOT TRUE THEN
            pr := pr || format('Ad set %s uses PIN codes, but Meta has not confirmed PIN-code targeting for India on this account (CONTEXT.premium.targeting_support): use cities.', a->>'key');
          ELSIF (SELECT count(*) FROM jsonb_array_elements(a->'audience'->'locations') l WHERE l->>'type' = 'zip') > 200 THEN
            pr := pr || format('Ad set %s: up to 200 PIN codes.', a->>'key');
          ELSIF tot < 300 THEN
            pr := pr || format('Ad set %s: PIN-code ad sets are a test for budgets of ₹300 a day or more; below that keep the metro cities so Meta can learn.', a->>'key');
          END IF;
        END IF;
        IF jsonb_typeof(a->'audience'->'income') = 'array' AND jsonb_array_length(a->'audience'->'income') > 0 THEN
          FOR k IN SELECT * FROM jsonb_array_elements_text(a->'audience'->'income') LOOP
            IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(sup->'income'->'options', '[]')) o WHERE o->>'id' = k) THEN
              pr := pr || format('Ad set %s: income option "%s" is not one Meta offers this account (CONTEXT.premium.targeting_support.income.options).', a->>'key', left(k, 30));
            END IF;
          END LOOP;
        END IF;
      END LOOP;
    END LOOP;
  END IF;
  RETURN to_jsonb((pr[1:12] || ARRAY(SELECT jsonb_array_elements_text(base)))[1:40]);
END $$;

-- ------------------------------------------------------------------------------------------- what Meta offers this account (saved by ads-sync)
CREATE OR REPLACE FUNCTION public.svc_ads_meta_targeting_save(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value) VALUES ('meta_targeting_support', (coalesce(p, '{}') || jsonb_build_object('checked_at', now()))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_targeting_get() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_targeting_support'), '')::jsonb, '{}') $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_targeting() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'metros', coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_metro_preset'), '')::jsonb, '[]'),
    'support', coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_targeting_support'), '')::jsonb, '{}'));
END $$;

-- agents' context: + premium (metro preset, what Meta offers, the rules above)
-- (re-runnable after 115, which wraps this one as svc_ads_meta_strategy_extra_v114)
DO $do$
DECLARE fname text := CASE WHEN to_regprocedure('public.svc_ads_meta_strategy_extra_v114()') IS NULL THEN 'svc_ads_meta_strategy_extra' ELSE 'svc_ads_meta_strategy_extra_v114' END;
BEGIN
  EXECUTE format($f$CREATE OR REPLACE FUNCTION public.%I() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  RETURN public.svc_ads_meta_strategy_extra_v109() || jsonb_build_object('premium', jsonb_build_object(
    'metros', coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_metro_preset'), '')::jsonb, '[]'),
    'targeting_support', coalesce(nullif((SELECT value FROM public.ads_config WHERE key = 'meta_targeting_support'), '')::jsonb, '{}'),
    'rules', jsonb_build_array(
      'Students 18+ only; under-18s are reached through parents (Meta shows ads to teens by age and location only; India''s DPDP Rules need verifiable parental consent for under-18 data).',
      'Parent-only ad sets: minimum age 35.',
      'Every form asks how the training will be funded; at least one creative states the published fee range in ₹ lakh.',
      'Locations: the metro preset by default; PIN codes and household income only if targeting_support says Meta offers them, and only as a test when the daily budget is ₹300 or more.',
      'Never imply a person''s finances or other personal attributes in ad text (Meta policy); state facts about the course instead.')));
END $fn$$f$, fname);
END $do$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_plan_check_base(jsonb, jsonb), crm_private.ads_meta_goal_clean(jsonb), crm_private.ads_meta_plan_check(jsonb, jsonb),
  crm_private.ads_meta_funnel_blueprint(numeric, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.svc_ads_meta_targeting_save(jsonb), public.svc_ads_meta_targeting_get(), public.svc_ads_meta_strategy_extra(), public.api_ads_meta_targeting() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_targeting_save(jsonb), public.svc_ads_meta_targeting_get(), public.svc_ads_meta_strategy_extra() TO service_role;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_targeting() TO authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '114')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
