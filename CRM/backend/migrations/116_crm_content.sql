-- 116: Growth > Content. Run after 115 (and 112 for search data). Re-runnable. Rollback: 116_crm_content_down.sql.
--  * Two new agents on the existing ADS agents helper (same queue, same Claude plan, no extra cost):
--      meta_content_analyst -> what people want, from data Reel Studio cannot see: Google searches (Website), lead-form answers,
--                          course interest and lost reasons, competitor gaps, personas, past content results
--      meta_content_planner -> the week's calendar of reels and carousels, each with its evidence; checked in code
--    Ad creatives come from approved Meta strategies (Content > Ad creatives).
--  * Reel Studio makes everything on the Mac. It talks to the CRM only outbound (Edge Function crm-content, token in the
--    Vault as "Reel Studio"): takes the next planned item, reports progress, the post link and results, and sends ad
--    pictures back. Organic posts keep Reel Studio's 5-minute rule; ads stay paused until the owner creates them in Meta.
--  * Leads per item: every item has its own link tag (utm_campaign = content_<id>); website enquiries carry it.

CREATE TABLE IF NOT EXISTS public.content_plan (
  id bigserial PRIMARY KEY,
  week_start date NOT NULL UNIQUE,                 -- a Monday
  status text NOT NULL DEFAULT 'working' CHECK (status IN ('working', 'ready', 'failed')),
  working_note text,
  note text,                                       -- what the owner asked for this week
  demand jsonb,                                    -- the Demand Analyst's brief
  summary text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.content_item (
  id bigserial PRIMARY KEY,
  plan_id bigint REFERENCES public.content_plan(id) ON DELETE SET NULL,
  kind text NOT NULL CHECK (kind IN ('reel', 'carousel', 'ad_image', 'ad_video')),
  source text NOT NULL DEFAULT 'planner' CHECK (source IN ('planner', 'manual', 'strategy')),
  title text NOT NULL,
  brief jsonb NOT NULL DEFAULT '{}',
  slot timestamptz,
  status text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'queued', 'producing', 'ready', 'posted', 'held', 'skipped', 'failed')),
  strategy_id bigint, creative_key text,
  studio_job text,
  media jsonb NOT NULL DEFAULT '{}',               -- permalink, thumbnail, storage path of ad pictures
  stats jsonb NOT NULL DEFAULT '{}',               -- views, reach, likes, shares, saves, comments, link clicks
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_content_item_slot ON public.content_item (status, slot);
CREATE UNIQUE INDEX IF NOT EXISTS ux_content_item_creative ON public.content_item (strategy_id, creative_key, kind) WHERE strategy_id IS NOT NULL;

ALTER TABLE public.content_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_item ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.content_plan, public.content_item FROM PUBLIC, anon, authenticated;

-- agent roles on the existing queue
ALTER TABLE public.ads_agent_runs DROP CONSTRAINT IF EXISTS ads_agent_runs_role_check;
ALTER TABLE public.ads_agent_runs ADD CONSTRAINT ads_agent_runs_role_check
  CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor', 'team_lead', 'tracking',
                  'meta_researcher', 'meta_strategist', 'meta_reviewer', 'meta_content_analyst', 'meta_content_planner'));

-- the Reel Studio token (Vault, shown and rotated like the other inbound tokens)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_reelstudio_token') THEN
    PERFORM vault.create_secret(translate(encode(extensions.gen_random_bytes(36), 'base64'), '+/', '-_'), 'crm_reelstudio_token', 'Reel Studio -> CRM content link');
  END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.connection_secret(p_id text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_id WHEN 'charter' THEN 'crm_charter_ingest_token'
                   WHEN 'hikvision' THEN 'crm_attendance_ingest_token'
                   WHEN 'partner' THEN 'crm_partner_api_token'
                   WHEN 'reelstudio' THEN 'crm_reelstudio_token' END $$;
CREATE OR REPLACE FUNCTION public.api_connections() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can view connections' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT json_object_agg(c.id, json_build_object('last4', right(s.decrypted_secret, 4), 'updated_at', s.updated_at))
    FROM (VALUES ('charter'), ('hikvision'), ('partner'), ('reelstudio')) c(id)
    JOIN vault.decrypted_secrets s ON s.name = crm_private.connection_secret(c.id)), '{}');
END $$;
DO $$
BEGIN
  IF to_regprocedure('public.api_vault_overview_v111()') IS NULL AND to_regprocedure('public.api_vault_overview()') IS NOT NULL THEN
    ALTER FUNCTION public.api_vault_overview() RENAME TO api_vault_overview_v111;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_vault_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_vault_overview_v111();
BEGIN
  RETURN o || jsonb_build_object('inbound', coalesce(o->'inbound', '{}') || jsonb_build_object('reelstudio', crm_private.vault_meta('crm_reelstudio_token')));
END $$;

-- ------------------------------------------------------------------------------------------- what people want (data for the analyst)
CREATE OR REPLACE FUNCTION crm_private.content_demand() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE q jsonb := '[]'; s jsonb := '{}';
BEGIN
  IF to_regprocedure('crm_private.web_queries()') IS NOT NULL THEN
    EXECUTE $x$
      SELECT jsonb_build_object(
        'top', (SELECT coalesce(jsonb_agg(z), '[]') FROM (SELECT query, clicks, impressions, pos, prev_pos FROM crm_private.web_queries() ORDER BY impressions DESC LIMIT 40) z),
        'questions', (SELECT coalesce(jsonb_agg(z), '[]') FROM (SELECT query, impressions, pos FROM crm_private.web_queries() WHERE question ORDER BY impressions DESC LIMIT 25) z),
        'almost_page1', (SELECT coalesce(jsonb_agg(z), '[]') FROM (SELECT query, impressions, pos FROM crm_private.web_queries() WHERE almost ORDER BY impressions DESC LIMIT 15) z),
        'new', (SELECT coalesce(jsonb_agg(z), '[]') FROM (SELECT query, impressions, pos FROM crm_private.web_queries() WHERE is_new ORDER BY impressions DESC LIMIT 15) z),
        'rising', (SELECT coalesce(jsonb_agg(z), '[]') FROM (SELECT query, impressions, pos, prev_pos FROM crm_private.web_queries()
                     WHERE prev_pos IS NOT NULL AND pos < prev_pos - 2 ORDER BY impressions DESC LIMIT 15) z)) $x$ INTO s;
  END IF;
  RETURN jsonb_build_object(
    'google_searches', s,
    'lead_form_answers', (SELECT coalesce(jsonb_agg(jsonb_build_object('question', k, 'answers', v)), '[]') FROM (
        SELECT k, jsonb_agg(jsonb_build_object('answer', a, 'n', n) ORDER BY n DESC) v FROM (
          SELECT e.key k, left(e.value #>> '{}', 80) a, count(*) n
            FROM public.ads_meta_lead_archive l, jsonb_each(l.answers) e
           WHERE l.created_time > now() - interval '180 days' AND jsonb_typeof(e.value) IN ('string', 'array')
             AND e.key !~* '(name|phone|email|mobile|number)'
           GROUP BY 1, 2) x WHERE n >= 2 GROUP BY k LIMIT 12) y),
    'course_interest_90d', (SELECT coalesce(jsonb_object_agg(coalesce(nullif(course_interest, ''), 'not said'), n), '{}') FROM (
        SELECT course_interest, count(*) n FROM public.lead WHERE created_at > now() - interval '90 days' GROUP BY 1 ORDER BY 2 DESC LIMIT 12) c),
    'lost_reasons_180d', (SELECT coalesce(jsonb_object_agg(closure_outcome, n), '{}') FROM (
        SELECT closure_outcome, count(*) n FROM public.lead WHERE closed AND closure_outcome IS NOT NULL AND created_at > now() - interval '180 days'
         GROUP BY 1 ORDER BY 2 DESC LIMIT 10) c),
    'personas', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', p.key, 'name', p.name, 'who', p.who, 'asks', p.asks, 'objections', p.objections, 'angles', p.angles) ORDER BY p.key), '[]')
       FROM public.ads_meta_persona p WHERE p.enabled),
    'competitors', CASE WHEN to_regprocedure('crm_private.ads_competitors_data(integer)') IS NOT NULL
       THEN (SELECT coalesce(jsonb_agg(x - 'id' - 'enabled' - 'facebook_page' - 'instagram'), '[]') FROM jsonb_array_elements(crm_private.ads_competitors_data(5)) x WHERE (x->>'enabled')::boolean)
       ELSE '[]' END,
    'brand_facts', crm_private.ads_cfg('google_brand_facts'),
    'banned_claims', coalesce(crm_private.ads_rule('g_claim_phrases')->'phrases', '[]'),
    'past_content', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', i.kind, 'title', i.title, 'posted', i.slot::date, 'stats', i.stats,
        'leads', crm_private.content_leads(i.id), 'angle', i.brief->>'angle', 'persona', i.brief->>'persona') ORDER BY i.slot DESC), '[]')
       FROM (SELECT * FROM public.content_item WHERE status = 'posted' AND kind IN ('reel', 'carousel') ORDER BY slot DESC LIMIT 40) i));
END $$;

-- enquiries that came through an item's own link (website forms keep utm_campaign; ad leads keep it in first_touch)
CREATE OR REPLACE FUNCTION crm_private.content_leads(p_id bigint) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT (SELECT count(*) FROM public.lead WHERE utm_campaign = 'content_' || p_id)::int
       + (SELECT count(*) FROM public.ads_lead WHERE first_touch->>'utm_campaign' = 'content_' || p_id AND deleted_at IS NULL)::int $$;

CREATE OR REPLACE FUNCTION crm_private.content_link(p_id bigint, p_kind text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT 'https://weoneaviation.in/?utm_source=instagram&utm_medium=' || CASE p_kind WHEN 'carousel' THEN 'carousel' ELSE 'reel' END
       || '&utm_campaign=content_' || p_id $$;

-- ------------------------------------------------------------------------------------------- planning (agents on the ADS queue)
CREATE OR REPLACE FUNCTION crm_private.content_plan_queue(p_week date, p_note text, p_by uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE wk date := date_trunc('week', p_week)::date; pid bigint;
BEGIN
  INSERT INTO public.content_plan (week_start, status, working_note, note, created_by)
  VALUES (wk, 'working', 'Demand Analyst is reading searches, lead answers and competitors', nullif(left(btrim(coalesce(p_note, '')), 1000), ''), p_by)
  ON CONFLICT (week_start) DO UPDATE SET status = 'working', working_note = EXCLUDED.working_note, note = coalesce(EXCLUDED.note, public.content_plan.note), updated_at = now()
  RETURNING id INTO pid;
  -- a re-plan replaces the week's planned items that have not started; anything already made stays
  DELETE FROM public.content_item WHERE plan_id = pid AND source = 'planner' AND status = 'planned';
  UPDATE public.ads_agent_runs SET status = 'failed', error = 'Replaced by a new plan', finished_at = now()
   WHERE role IN ('meta_content_analyst', 'meta_content_planner') AND status IN ('queued', 'running') AND (input->>'plan_id')::bigint = pid;
  INSERT INTO public.ads_agent_runs (role, job, status, input) VALUES ('meta_content_analyst', 'content', 'queued', jsonb_build_object('plan_id', pid, 'week_start', wk));
  RETURN pid;
END $$;

-- the weekly clock (pg_cron, Sunday evening India time): next week's plan, once
CREATE OR REPLACE FUNCTION crm_private.content_week_tick() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE wk date := (date_trunc('week', (now() AT TIME ZONE 'Asia/Kolkata')::date) + interval '7 days')::date;
BEGIN
  IF coalesce(crm_private.ads_cfg('content_autoplan'), 'on') <> 'on' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.content_plan WHERE week_start = wk) THEN RETURN NULL; END IF;
  RETURN crm_private.content_plan_queue(wk, NULL, NULL);
END $$;

CREATE OR REPLACE FUNCTION crm_private.content_agent_ctx(r public.ads_agent_runs) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.content_plan;
BEGIN
  SELECT * INTO p FROM public.content_plan WHERE id = (r.input->>'plan_id')::bigint;
  RETURN jsonb_build_object('week_start', p.week_start, 'owner_note', p.note, 'demand_data', crm_private.content_demand(),
    'analyst', CASE WHEN r.role = 'meta_content_planner' THEN p.demand END,
    'posting', jsonb_build_object('timezone', 'Asia/Kolkata', 'default_time', coalesce(crm_private.ads_cfg('content_post_time'), '13:30'),
      'reels_per_week', coalesce(nullif(crm_private.ads_cfg('content_reels_per_week'), '')::int, 7),
      'carousels_per_week', coalesce(nullif(crm_private.ads_cfg('content_carousels_per_week'), '')::int, 3)),
    'already_this_week', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'title', title, 'slot', slot, 'status', status)), '[]')
       FROM public.content_item WHERE slot >= p.week_start AND slot < p.week_start + 7 AND status <> 'skipped'));
END $$;

-- planner answer -> problems (empty = fine)
CREATE OR REPLACE FUNCTION crm_private.content_plan_check(p_week date, o jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pr text[] := '{}'; it jsonb; i int := 0; d date; reels int := 0; cars int := 0; claims text[]; ph text; txt text;
BEGIN
  IF jsonb_typeof(o->'items') <> 'array' OR jsonb_array_length(o->'items') NOT BETWEEN 3 AND 14 THEN RETURN '["Give 3 to 14 items."]'; END IF;
  SELECT coalesce(array_agg(lower(x)), '{}') INTO claims FROM jsonb_array_elements_text(coalesce(crm_private.ads_rule('g_claim_phrases')->'phrases', '[]')) x;
  FOR it IN SELECT * FROM jsonb_array_elements(o->'items') LOOP
    i := i + 1;
    IF coalesce(it->>'kind', '') NOT IN ('reel', 'carousel') THEN pr := pr || format('Item %s: kind must be reel or carousel.', i); END IF;
    IF it->>'kind' = 'reel' THEN reels := reels + 1; ELSIF it->>'kind' = 'carousel' THEN cars := cars + 1; END IF;
    BEGIN d := (it->>'day')::date; EXCEPTION WHEN others THEN d := NULL; END;
    IF d IS NULL OR d < p_week OR d > p_week + 6 THEN pr := pr || format('Item %s: day must be a date in the week of %s.', i, p_week); END IF;
    IF coalesce(it->>'time', '13:30') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN pr := pr || format('Item %s: time as HH:MM (India).', i); END IF;
    IF length(coalesce(it->>'title', '')) NOT BETWEEN 5 AND 120 THEN pr := pr || format('Item %s: title of 5-120 characters.', i); END IF;
    IF length(coalesce(it->>'hook', '')) < 10 THEN pr := pr || format('Item %s: write the opening hook (the first 2 seconds / first slide).', i); END IF;
    IF jsonb_typeof(it->'evidence') <> 'array' OR jsonb_array_length(it->'evidence') = 0 THEN
      pr := pr || format('Item %s: give the evidence (which search, lead answer, gap or result it comes from).', i); END IF;
    IF coalesce(it->>'persona', '') <> '' AND NOT EXISTS (SELECT 1 FROM public.ads_meta_persona p WHERE p.key = it->>'persona' AND p.enabled) THEN
      pr := pr || format('Item %s: persona "%s" is not one of the personas.', i, left(it->>'persona', 30)); END IF;
    txt := lower(concat_ws(' ', it->>'title', it->>'hook', it->>'cta', it->>'angle'));
    FOREACH ph IN ARRAY claims LOOP
      IF position(ph IN txt) > 0 THEN pr := pr || format('Item %s uses a banned claim ("%s").', i, ph); END IF;
    END LOOP;
  END LOOP;
  IF reels > coalesce(nullif(crm_private.ads_cfg('content_reels_per_week'), '')::int, 7) THEN pr := pr || format('%s reels: at most %s a week (Reel Studio''s daily cap).', reels, coalesce(nullif(crm_private.ads_cfg('content_reels_per_week'), '')::int, 7)); END IF;
  IF cars > coalesce(nullif(crm_private.ads_cfg('content_carousels_per_week'), '')::int, 3) THEN pr := pr || format('%s carousels: at most %s a week.', cars, coalesce(nullif(crm_private.ads_cfg('content_carousels_per_week'), '')::int, 3)); END IF;
  IF (SELECT count(*) FROM (SELECT it2->>'day', it2->>'kind' FROM jsonb_array_elements(o->'items') it2 GROUP BY 1, 2 HAVING count(*) > 1) z) > 0 THEN
    pr := pr || 'At most one reel and one carousel a day.'::text; END IF;
  RETURN to_jsonb(pr[1:20]);
END $$;

-- claim: the helper asks for work; content steps go first (rare, weekly). Only helpers that know the newer roles (meta) get them.
DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_agent_next2_v104(boolean)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_agent_next2(boolean) RENAME TO svc_ads_agent_next2_v104;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_agent_finish_v104(bigint,boolean,jsonb,text,text)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text) RENAME TO svc_ads_meta_agent_finish_v104;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.svc_ads_agent_next2(p_meta boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs;
BEGIN
  IF coalesce(p_meta, false) AND coalesce(crm_private.ads_cfg('execution_paused'), '') <> 'true' THEN
    SELECT * INTO r FROM public.ads_agent_runs WHERE status = 'queued' AND role IN ('meta_content_analyst', 'meta_content_planner')
     ORDER BY created_at, id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF r.id IS NOT NULL THEN
      UPDATE public.ads_agent_runs SET status = 'running', claimed_at = now(), claims = claims + 1 WHERE id = r.id RETURNING * INTO r;
      UPDATE public.content_plan SET working_note = CASE r.role WHEN 'meta_content_analyst' THEN 'Demand Analyst is reading searches, lead answers and competitors'
        ELSE 'Content Planner is writing the week' END, updated_at = now() WHERE id = (r.input->>'plan_id')::bigint;
      RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'attempt', r.attempt, 'input', r.input),
        'context', crm_private.content_agent_ctx(r));
    END IF;
  END IF;
  RETURN public.svc_ads_agent_next2_v104(p_meta);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_agent_finish(p_id bigint, p_ok boolean, p_output jsonb, p_summary text DEFAULT NULL,
  p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs; p public.content_plan; probs jsonb; it jsonb; tz text := 'Asia/Kolkata'; n int := 0;
BEGIN
  SELECT * INTO r FROM public.ads_agent_runs WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.role NOT IN ('meta_content_analyst', 'meta_content_planner') THEN
    RETURN public.svc_ads_meta_agent_finish_v104(p_id, p_ok, p_output, p_summary, p_error);
  END IF;
  IF r.status <> 'running' THEN RETURN jsonb_build_object('handled', true, 'ignored', true); END IF;
  SELECT * INTO p FROM public.content_plan WHERE id = (r.input->>'plan_id')::bigint FOR UPDATE;
  IF p.id IS NULL THEN
    UPDATE public.ads_agent_runs SET status = 'failed', error = 'Plan was deleted', finished_at = now() WHERE id = r.id;
    RETURN jsonb_build_object('handled', true);
  END IF;
  IF NOT coalesce(p_ok, false) OR p_output IS NULL THEN
    UPDATE public.ads_agent_runs SET status = 'failed', error = left(coalesce(p_error, 'no answer'), 900), finished_at = now() WHERE id = r.id;
    IF r.attempt < 3 THEN
      INSERT INTO public.ads_agent_runs (role, job, status, attempt, parent_id, input) VALUES (r.role, 'content', 'queued', r.attempt + 1, r.id, r.input);
    ELSE
      UPDATE public.content_plan SET status = 'failed', working_note = left('Stopped: ' || coalesce(p_error, 'the agent gave no answer'), 300), updated_at = now() WHERE id = p.id;
    END IF;
    RETURN jsonb_build_object('handled', true);
  END IF;

  IF r.role = 'meta_content_analyst' THEN
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, summary = left(coalesce(p_summary, p_output->>'summary'), 500), finished_at = now() WHERE id = r.id;
    UPDATE public.content_plan SET demand = p_output, working_note = 'Content Planner is writing the week', updated_at = now() WHERE id = p.id;
    INSERT INTO public.ads_agent_runs (role, job, status, parent_id, input) VALUES ('meta_content_planner', 'content', 'queued', r.id, jsonb_build_object('plan_id', p.id, 'week_start', p.week_start));
    RETURN jsonb_build_object('handled', true, 'next', 'meta_content_planner');
  END IF;

  probs := crm_private.content_plan_check(p.week_start, p_output);
  IF jsonb_array_length(probs) > 0 THEN
    UPDATE public.ads_agent_runs SET status = 'rejected', output = p_output, error = left(probs::text, 900), finished_at = now() WHERE id = r.id;
    IF r.attempt < 3 THEN
      INSERT INTO public.ads_agent_runs (role, job, status, attempt, parent_id, input)
      VALUES ('meta_content_planner', 'content', 'queued', r.attempt + 1, r.id, r.input || jsonb_build_object('fix_these', probs, 'previous_answer', p_output));
    ELSE
      UPDATE public.content_plan SET status = 'failed', working_note = left('The plan kept failing the checks: ' || (probs->>0), 300), updated_at = now() WHERE id = p.id;
    END IF;
    RETURN jsonb_build_object('handled', true, 'problems', probs);
  END IF;
  DELETE FROM public.content_item WHERE plan_id = p.id AND source = 'planner' AND status = 'planned';
  FOR it IN SELECT * FROM jsonb_array_elements(p_output->'items') LOOP
    INSERT INTO public.content_item (plan_id, kind, source, title, brief, slot)
    VALUES (p.id, it->>'kind', 'planner', left(it->>'title', 120), it - 'kind' - 'title' - 'day' - 'time',
            (((it->>'day') || ' ' || coalesce(nullif(it->>'time', ''), '13:30'))::timestamp AT TIME ZONE tz));
    n := n + 1;
  END LOOP;
  UPDATE public.ads_agent_runs SET status = 'done', output = p_output, summary = left(coalesce(p_summary, p_output->>'answer'), 500), finished_at = now() WHERE id = r.id;
  UPDATE public.content_plan SET status = 'ready', working_note = NULL, summary = left(p_output->>'answer', 1000), updated_at = now() WHERE id = p.id;
  RETURN jsonb_build_object('handled', true, 'items', n);
END $$;

-- ------------------------------------------------------------------------------------------- the screen
CREATE OR REPLACE FUNCTION public.api_content_overview(p_week date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE wk date := date_trunc('week', coalesce(p_week, (now() AT TIME ZONE 'Asia/Kolkata')::date))::date; p public.content_plan;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO p FROM public.content_plan WHERE week_start = wk;
  RETURN jsonb_build_object('week_start', wk, 'can_edit', crm_private.ads_can_approve(),
    'plan', CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object('id', p.id, 'status', p.status, 'working_note', p.working_note, 'note', p.note,
      'summary', p.summary, 'demand', p.demand, 'updated_at', p.updated_at) END,
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'source', i.source, 'title', i.title, 'brief', i.brief, 'slot', i.slot,
        'status', i.status, 'media', i.media - 'path', 'has_picture', i.media ? 'path', 'stats', i.stats, 'note', i.note, 'link', crm_private.content_link(i.id, i.kind),
        'leads', crm_private.content_leads(i.id)) ORDER BY i.slot NULLS LAST, i.id), '[]')
      FROM public.content_item i WHERE i.kind IN ('reel', 'carousel') AND i.slot >= wk AND i.slot < wk + 7),
    'ad_creatives', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'title', i.title, 'brief', i.brief, 'status', i.status,
        'strategy_id', i.strategy_id, 'creative_key', i.creative_key, 'has_picture', i.media ? 'path', 'paths', coalesce(i.media->'paths', '{}'), 'video', i.media->>'video',
        'note', i.note, 'updated_at', i.updated_at) ORDER BY i.id DESC), '[]')
      FROM (SELECT * FROM public.content_item WHERE kind IN ('ad_image', 'ad_video') ORDER BY id DESC LIMIT 40) i),
    'strategies', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'approved_version', s.approved_version) ORDER BY s.id DESC), '[]')
      FROM public.ads_meta_strategy s WHERE s.approved_version IS NOT NULL AND s.status <> 'archived'),
    'results', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'title', i.title, 'slot', i.slot, 'stats', i.stats, 'permalink', i.media->>'permalink',
        'leads', crm_private.content_leads(i.id)) ORDER BY i.slot DESC), '[]')
      FROM (SELECT * FROM public.content_item WHERE status = 'posted' ORDER BY slot DESC LIMIT 30) i),
    'studio', jsonb_build_object('last_seen', crm_private.ads_cfg('content_studio_seen'), 'autoplan', coalesce(crm_private.ads_cfg('content_autoplan'), 'on')));
END $$;

CREATE OR REPLACE FUNCTION public.api_content_plan(p_week date, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE wk date := date_trunc('week', p_week)::date;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can plan content' USING ERRCODE = 'PT403'; END IF;
  IF wk < date_trunc('week', (now() AT TIME ZONE 'Asia/Kolkata')::date)::date THEN RAISE EXCEPTION 'That week is over' USING ERRCODE = 'PT422'; END IF;
  IF wk > (now() AT TIME ZONE 'Asia/Kolkata')::date + 35 THEN RAISE EXCEPTION 'Plan up to 5 weeks ahead' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('plan_id', crm_private.content_plan_queue(wk, p_note, crm_private.current_employee_id()));
END $$;

-- change one item: skip, restore, move, rename, or add your own idea
CREATE OR REPLACE FUNCTION public.api_content_item_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item; st timestamptz; act text := coalesce(p->>'action', 'edit'); rid bigint;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can change content' USING ERRCODE = 'PT403'; END IF;
  IF p->>'slot' IS NOT NULL THEN
    BEGIN st := (p->>'slot')::timestamptz; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Time looks like 2026-11-24T13:30+05:30' USING ERRCODE = 'PT422'; END;
  END IF;
  IF act = 'add' THEN
    IF coalesce(p->>'kind', '') NOT IN ('reel', 'carousel') THEN RAISE EXCEPTION 'Pick reel or carousel' USING ERRCODE = 'PT422'; END IF;
    IF length(btrim(coalesce(p->>'title', ''))) NOT BETWEEN 5 AND 120 THEN RAISE EXCEPTION 'Topic of 5-120 characters' USING ERRCODE = 'PT422'; END IF;
    IF st IS NULL OR st < now() THEN RAISE EXCEPTION 'Pick a time in the future' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.content_item (kind, source, title, brief, slot, created_by)
    VALUES (p->>'kind', 'manual', btrim(p->>'title'), jsonb_build_object('hook', left(coalesce(p->>'hook', ''), 300), 'evidence', '[{"signal": "owner", "detail": "Added by hand"}]'::jsonb), st,
            crm_private.current_employee_id()) RETURNING id INTO rid;
    RETURN jsonb_build_object('id', rid);
  END IF;
  SELECT * INTO i FROM public.content_item WHERE id = (p->>'id')::bigint FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'Item not found' USING ERRCODE = 'PT404'; END IF;
  IF act = 'skip' THEN
    IF i.status NOT IN ('planned', 'queued', 'held', 'failed') THEN RAISE EXCEPTION 'It is already being made or posted' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET status = 'skipped', updated_at = now() WHERE id = i.id;
  ELSIF act = 'restore' THEN
    IF i.status NOT IN ('skipped', 'failed', 'held') THEN RAISE EXCEPTION 'Only skipped, held or failed items come back' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET status = 'planned', note = NULL, updated_at = now() WHERE id = i.id;
  ELSE
    IF i.status NOT IN ('planned', 'held') THEN RAISE EXCEPTION 'Only planned items can be changed' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET title = coalesce(nullif(left(btrim(p->>'title'), 120), ''), title), slot = coalesce(st, slot),
      brief = CASE WHEN p ? 'hook' THEN jsonb_set(brief, '{hook}', to_jsonb(left(p->>'hook', 300))) ELSE brief END, updated_at = now() WHERE id = i.id;
  END IF;
  RETURN jsonb_build_object('id', i.id);
END $$;

-- ad creatives from an approved Meta strategy: one item per image / video ad (carousels are made in Ads Manager)
CREATE OR REPLACE FUNCTION public.api_content_from_strategy(p_strategy_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; plan jsonb; c jsonb; n int := 0;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can order ad creatives' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_strategy_id;
  IF s.id IS NULL OR s.approved_version IS NULL THEN RAISE EXCEPTION 'Approve a version of the strategy first' USING ERRCODE = 'PT409'; END IF;
  SELECT v.plan INTO plan FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.approved_version;
  FOR c IN SELECT * FROM jsonb_array_elements(coalesce(plan->'creatives', '[]')) LOOP
    CONTINUE WHEN c->>'format' NOT IN ('image', 'video');
    INSERT INTO public.content_item (kind, source, title, brief, strategy_id, creative_key, slot, created_by)
    VALUES (CASE c->>'format' WHEN 'video' THEN 'ad_video' ELSE 'ad_image' END, 'strategy', left(coalesce(c->>'name', c->>'headline', 'Ad'), 120),
            jsonb_build_object('headline', c->>'headline', 'primary_text', c->>'primary_text', 'visual_brief', c->>'visual_brief', 'persona', c->>'persona',
              'angle', c->>'angle', 'cta', c->>'cta', 'sizes', CASE c->>'format' WHEN 'video' THEN '["1080x1920"]'::jsonb ELSE '["1080x1350", "1080x1920"]'::jsonb END),
            s.id, c->>'key', now(), crm_private.current_employee_id())
    ON CONFLICT (strategy_id, creative_key, kind) WHERE strategy_id IS NOT NULL DO UPDATE SET brief = EXCLUDED.brief, title = EXCLUDED.title,
      status = CASE WHEN public.content_item.status IN ('failed', 'skipped') THEN 'planned' ELSE public.content_item.status END, updated_at = now();
    n := n + 1;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'The approved plan has no image or video ads' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('items', n);
END $$;

CREATE OR REPLACE FUNCTION public.api_content_settings_save(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change content settings' USING ERRCODE = 'PT403'; END IF;
  IF p ? 'autoplan' THEN
    INSERT INTO public.ads_config (key, value) VALUES ('content_autoplan', CASE WHEN (p->>'autoplan')::boolean THEN 'on' ELSE 'off' END)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  END IF;
END $$;

-- ------------------------------------------------------------------------------------------- Reel Studio link (Edge Function crm-content)
CREATE OR REPLACE FUNCTION public.svc_content_token_ok(p_token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(length(p_token) >= 32 AND p_token = (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_reelstudio_token'), false) $$;

-- the next thing to make: ad creatives straight away, posts from 36 hours before their slot (the Mac needs up to an hour a reel)
CREATE OR REPLACE FUNCTION public.svc_content_next() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item;
BEGIN
  INSERT INTO public.ads_config (key, value) VALUES ('content_studio_seen', now()::text) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  -- a claim that never reported back within 6 hours goes back to the queue
  UPDATE public.content_item SET status = 'planned', updated_at = now() WHERE status = 'queued' AND updated_at < now() - interval '6 hours';
  SELECT * INTO i FROM public.content_item
   WHERE status = 'planned' AND (kind IN ('ad_image', 'ad_video') OR (slot > now() - interval '2 hours' AND slot < now() + interval '36 hours'))
   ORDER BY CASE WHEN kind LIKE 'ad\_%' THEN 0 ELSE 1 END, slot NULLS FIRST, id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF i.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.content_item SET status = 'queued', updated_at = now() WHERE id = i.id;
  RETURN jsonb_build_object('id', i.id, 'kind', i.kind, 'title', i.title, 'brief', i.brief, 'slot', i.slot, 'link', crm_private.content_link(i.id, i.kind),
    'brand', 'weone', 'brand_facts', crm_private.ads_cfg('google_brand_facts'),
    'banned_claims', coalesce(crm_private.ads_rule('g_claim_phrases')->'phrases', '[]'),
    'persona', (SELECT jsonb_build_object('key', p.key, 'name', p.name, 'who', p.who, 'asks', p.asks, 'objections', p.objections)
                  FROM public.ads_meta_persona p WHERE p.key = i.brief->>'persona'));
END $$;

-- Reel Studio reports: producing / ready / posted / held / failed, its job id, the post link, results, an ad picture's storage path
CREATE OR REPLACE FUNCTION public.svc_content_update(p_id bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item; st text := p->>'status';
BEGIN
  SELECT * INTO i FROM public.content_item WHERE id = p_id FOR UPDATE;
  IF i.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'detail', 'unknown item'); END IF;
  IF st IS NOT NULL AND st NOT IN ('producing', 'ready', 'posted', 'held', 'failed', 'planned') THEN RETURN jsonb_build_object('ok', false, 'detail', 'bad status'); END IF;
  IF i.status = 'skipped' AND st IN ('producing', 'ready') THEN RETURN jsonb_build_object('ok', true, 'skipped', true); END IF;
  UPDATE public.content_item SET status = coalesce(st, status), studio_job = coalesce(left(p->>'studio_job', 80), studio_job),
    media = media || coalesce(CASE WHEN jsonb_typeof(p->'media') = 'object' THEN p->'media' END, '{}'),
    stats = stats || coalesce(CASE WHEN jsonb_typeof(p->'stats') = 'object' THEN p->'stats' END, '{}'),
    note = coalesce(left(p->>'note', 500), note),
    slot = CASE WHEN st = 'posted' AND p ? 'posted_at' THEN (p->>'posted_at')::timestamptz ELSE slot END, updated_at = now()
   WHERE id = i.id;
  RETURN jsonb_build_object('ok', true, 'skipped', i.status = 'skipped');
END $$;

-- an ad picture arrived (stored by crm-content in the private "content" bucket); ready when every asked size is there
CREATE OR REPLACE FUNCTION public.svc_content_picture(p_id bigint, p_size text, p_path text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item; paths jsonb; done boolean;
BEGIN
  SELECT * INTO i FROM public.content_item WHERE id = p_id FOR UPDATE;
  IF i.id IS NULL OR i.kind NOT IN ('ad_image', 'ad_video') THEN RETURN jsonb_build_object('ok', false, 'detail', 'not an ad creative'); END IF;
  IF p_path !~ ('^ad/' || p_id || '/[0-9x]+\.(png|jpg)$') THEN RETURN jsonb_build_object('ok', false, 'detail', 'bad path'); END IF;
  paths := coalesce(i.media->'paths', '{}') || jsonb_build_object(p_size, p_path);
  done := NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(i.brief->'sizes', '["1080x1350"]')) z WHERE NOT paths ? z);
  UPDATE public.content_item SET media = media || jsonb_build_object('paths', paths, 'path', coalesce(paths->>'1080x1350', p_path)),
    status = CASE WHEN done AND i.kind = 'ad_image' THEN 'ready' ELSE status END, updated_at = now() WHERE id = i.id;
  RETURN jsonb_build_object('ok', true, 'ready', done AND i.kind = 'ad_image');
END $$;

-- what Reel Studio's Strategist reads each week (the Demand Analyst's brief, the plan, results)
CREATE OR REPLACE FUNCTION public.svc_content_signals() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'demand', (SELECT demand FROM public.content_plan WHERE demand IS NOT NULL ORDER BY week_start DESC LIMIT 1),
    'this_week', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'title', title, 'slot', slot, 'status', status) ORDER BY slot), '[]')
                    FROM public.content_item WHERE kind IN ('reel', 'carousel') AND slot >= now() - interval '1 day' AND slot < now() + interval '7 days'),
    'best', (SELECT coalesce(jsonb_agg(jsonb_build_object('title', title, 'stats', stats, 'leads', crm_private.content_leads(id)) ORDER BY crm_private.content_leads(id) DESC, (stats->>'views')::numeric DESC NULLS LAST), '[]')
               FROM (SELECT * FROM public.content_item WHERE status = 'posted' ORDER BY slot DESC LIMIT 30) z)) $$;

-- storage for ad pictures Reel Studio sends back (private; ADS viewers read them)
INSERT INTO storage.buckets (id, name, public) VALUES ('content', 'content', false) ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS content_read ON storage.objects;
CREATE POLICY content_read ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'content' AND crm_private.ads_can_view());

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-content-week';
    PERFORM cron.schedule('crm-content-week', '30 12 * * 0', 'SELECT crm_private.content_week_tick()');   -- Sunday 18:00 India time
  END IF;
END $$;

REVOKE ALL ON FUNCTION crm_private.content_demand(), crm_private.content_leads(bigint), crm_private.content_plan_queue(date, text, uuid), crm_private.content_week_tick(),
  crm_private.content_agent_ctx(public.ads_agent_runs), crm_private.content_plan_check(date, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_content_overview(date), public.api_content_plan(date, text), public.api_content_item_save(jsonb), public.api_content_from_strategy(bigint),
  public.api_content_settings_save(jsonb), public.api_connections(), public.api_vault_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_content_overview(date), public.api_content_plan(date, text), public.api_content_item_save(jsonb), public.api_content_from_strategy(bigint),
  public.api_content_settings_save(jsonb), public.api_connections(), public.api_vault_overview() TO authenticated;
REVOKE ALL ON FUNCTION public.svc_content_token_ok(text), public.svc_content_next(), public.svc_content_update(bigint, jsonb), public.svc_content_signals(), public.svc_content_picture(bigint, text, text),
  public.svc_ads_agent_next2(boolean), public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_content_token_ok(text), public.svc_content_next(), public.svc_content_update(bigint, jsonb), public.svc_content_signals(), public.svc_content_picture(bigint, text, text),
  public.svc_ads_agent_next2(boolean), public.svc_ads_meta_agent_finish(bigint, boolean, jsonb, text, text) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '116')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
