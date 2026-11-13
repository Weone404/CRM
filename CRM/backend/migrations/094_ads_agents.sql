-- 094: ADS only, Google Ads only. The agents' work queue: Researcher -> Builder -> (code checks) -> Reviewer -> live.
-- The ADS agents run on the owner's Mac (tools/ads-agents, Claude Max plan) and talk only to the ads-agents Edge Function
-- with their own token (093). Separate from Amazon (amazon-bridge, Nitaniya token) and from Meta.
--
--   svc_ads_agent_next()      claims the next queued step and returns it with the account context
--   svc_ads_agent_finish()    stores a step's result and queues the next one:
--                               researcher -> builder
--                               builder    -> code checks (092 gate) -> reviewer, or back to builder with the problems
--                               reviewer   -> approve: operations (auto-approved when Autopilot is 'auto') + suggestions
--                                             reject: back to builder with the problems; after 3 builder tries -> escalated
--   svc_ads_agent_release()   puts a step back (Claude usage limit, Mac restart)
--   svc_ads_agents_tick()     every 5 minutes (pg_cron): starts work for new instructions, one daily review, frees stuck steps
--
-- Location changes from agents always become suggestions (the user picks cities). Nothing here talks to Google:
-- approved operations are sent by ads-sync (execute), which runs Google's own pre-check first and reads every change back.
-- Re-runnable. Rollback: 094_ads_agents_down.sql.

ALTER TABLE public.ads_agent_runs ADD COLUMN IF NOT EXISTS claims int NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_ads_agent_runs_instr ON public.ads_agent_runs (instruction_id) WHERE instruction_id IS NOT NULL;

INSERT INTO public.ads_config (key, value) VALUES
  ('google_brand_facts', 'We One Aviation, pilot training institute in Dwarka, New Delhi. Website: https://weoneaviation.in. '
    || 'Courses include DGCA ground classes for CPL/ATPL subjects and pilot training guidance. Only state facts that appear on the website; '
    || 'never claim guarantees, success rates, placements, rankings or airline partnerships.'),
  ('agents_daily_review', 'on')
ON CONFLICT (key) DO NOTHING;

-- -------------------------------------------------------------------------------------------
-- Context given to every agent step (Google only). Snapshot rows are trimmed by the Edge Function.
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.ads_agent_context(p_run public.ads_agent_runs) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH a AS (SELECT * FROM crm_private.ads_google_account()),
       d AS (SELECT crm_private.ads_google_today() AS today)
  SELECT jsonb_build_object(
    'today', (SELECT today FROM d),
    'account', (SELECT jsonb_build_object('customer_id', a.external_id, 'name', a.name, 'currency', a.currency, 'timezone', a.timezone,
      'status', a.status, 'last_ok_at', a.last_ok_at) FROM a),
    'instruction', (SELECT jsonb_build_object('id', i.id, 'text', i.body, 'via', i.via) FROM public.ads_agent_instructions i WHERE i.id = p_run.instruction_id),
    'brand_facts', crm_private.ads_cfg('google_brand_facts'),
    'autopilot', jsonb_build_object('mode', crm_private.ads_cfg('autopilot_google'),
      'daily_limit', nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric,
      'monthly_limit', nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric,
      'month_spend', crm_private.ads_google_month_spend(), 'days_left_in_month', crm_private.ads_google_days_left()),
    'rules', jsonb_build_object(
      'allowed_url_hosts', crm_private.ads_cfg('google_allowed_domains'),
      'banned_claims', crm_private.ads_rule('g_claim_phrases')->'phrases',
      'protected_searches', crm_private.ads_rule('g_protected_terms')->'terms',
      'max_cpc_bid', crm_private.ads_rule('g_cpc_max')->'max',
      'ops_per_day', crm_private.ads_rule('g_ops_per_day')->'max'),
    'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.external_id, 'name', c.name, 'status', c.status,
        'daily_budget', c.daily_budget, 'primary_status', c.raw->>'primary_status', 'reasons', c.raw->'primary_status_reasons',
        'last_30d', (SELECT jsonb_build_object('spend', sum(m.spend), 'clicks', sum(m.clicks), 'impressions', sum(m.impressions),
            'platform_conversions', sum(m.conversions)) FROM public.ads_metrics_daily m
            WHERE m.campaign_id = c.id AND m.day > (SELECT today FROM d) - 30),
        'crm_leads_30d', (SELECT count(*) FROM public.lead l WHERE c.utm_campaign IS NOT NULL
            AND lower(l.utm_campaign) = lower(c.utm_campaign) AND l.created_at > now() - interval '30 days'))
        ORDER BY (c.status = 'ENABLED') DESC, c.name), '[]')
      FROM public.ads_campaigns c JOIN a ON a.id = c.account_id WHERE c.status <> 'REMOVED'),
    'snapshot', (SELECT coalesce(jsonb_object_agg(s.kind, s.data), '{}') FROM public.ads_google_snapshot s JOIN a ON a.id = s.account_id),
    'snapshot_at', (SELECT max(s.synced_at) FROM public.ads_google_snapshot s JOIN a ON a.id = s.account_id),
    'recent_changes', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', o.kind, 'summary', o.summary, 'status', o.status,
        'error', left(o.error, 200), 'at', o.created_at) ORDER BY o.created_at DESC), '[]')
      FROM (SELECT * FROM public.ads_google_ops ORDER BY created_at DESC LIMIT 40) o),
    'open_suggestions', (SELECT coalesce(jsonb_agg(jsonb_build_object('title', s.title, 'kind', s.kind)), '[]')
      FROM public.ads_autopilot_suggestions s WHERE s.status = 'open'),
    'recent_decisions', (SELECT coalesce(jsonb_agg(jsonb_build_object('title', s.title, 'decision', s.status, 'note', s.user_note)
        ORDER BY s.decided_at DESC), '[]')
      FROM (SELECT * FROM public.ads_autopilot_suggestions WHERE status <> 'open' ORDER BY decided_at DESC NULLS LAST LIMIT 15) s),
    'recent_instructions', (SELECT coalesce(jsonb_agg(jsonb_build_object('text', i.body, 'status', i.status, 'answer', left(i.answer, 300))
        ORDER BY i.created_at DESC), '[]')
      FROM (SELECT * FROM public.ads_agent_instructions ORDER BY created_at DESC LIMIT 10) i))
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_agent_next() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs;
BEGIN
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.ads_agent_runs WHERE status = 'queued' ORDER BY created_at, id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_agent_runs SET status = 'running', claimed_at = now(), claims = claims + 1 WHERE id = r.id RETURNING * INTO r;
  IF r.instruction_id IS NOT NULL THEN
    UPDATE public.ads_agent_instructions SET status = 'working' WHERE id = r.instruction_id AND status = 'new';
  END IF;
  RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'attempt', r.attempt, 'input', r.input),
    'context', crm_private.ads_agent_context(r));
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_agent_release(p_id bigint, p_reason text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_agent_runs SET status = 'queued', claimed_at = NULL, error = left(p_reason, 300) WHERE id = p_id AND status = 'running'
$$;

-- Ends a chain: answers the instruction (if any) and logs.
CREATE OR REPLACE FUNCTION crm_private.ads_agent_close(p_run public.ads_agent_runs, p_ok boolean, p_answer text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_run.instruction_id IS NOT NULL THEN
    UPDATE public.ads_agent_instructions SET status = CASE WHEN p_ok THEN 'answered' ELSE 'failed' END,
      answer = left(coalesce(p_answer, ''), 4000), answered_at = now() WHERE id = p_run.instruction_id;
  END IF;
  INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('agent', CASE WHEN p_ok THEN 'agents_done' ELSE 'agents_stopped' END, 'agent_run', p_run.id::text,
          jsonb_build_object('job', p_run.job, 'answer', left(p_answer, 300)));
END $$;

-- The builder's proposal, cleaned: location changes become a suggestion; ops/suggestions capped; each op gated.
CREATE OR REPLACE FUNCTION crm_private.ads_agent_check(p_out jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc uuid := (crm_private.ads_google_account()).id; ops jsonb := '[]'; sugg jsonb := '[]'; geo jsonb := '[]';
        problems jsonb := '[]'; x jsonb; g jsonb; i int := 0; so jsonb; j int;
BEGIN
  FOR x IN SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_out->'ops') = 'array' THEN p_out->'ops' ELSE '[]' END) v LOOP
    i := i + 1;
    IF i > 25 THEN problems := problems || to_jsonb('More than 25 operations; send the most important 25.'::text); EXIT; END IF;
    IF x->>'kind' = 'campaign_geo' THEN geo := geo || x; CONTINUE; END IF;
    g := crm_private.ads_google_gate(acc, coalesce(x->>'kind', ''), coalesce(x->'payload', '{}'));
    FOR j IN 0 .. jsonb_array_length(g->'blockers') - 1 LOOP
      problems := problems || to_jsonb(format('Operation %s (%s, "%s"): %s', i, x->>'kind', left(coalesce(x->>'summary', ''), 60), g->'blockers'->>j));
    END LOOP;
    ops := ops || x;
  END LOOP;
  FOR x IN SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_out->'suggestions') = 'array' THEN p_out->'suggestions' ELSE '[]' END) v LOOP
    IF coalesce(x->>'title', '') = '' THEN problems := problems || to_jsonb('A suggestion has no title.'::text); CONTINUE; END IF;
    FOR so IN SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(x->'proposal'->'ops') = 'array' THEN x->'proposal'->'ops' ELSE '[]' END) v LOOP
      g := crm_private.ads_google_gate(acc, coalesce(so->>'kind', ''), coalesce(so->'payload', '{}'));
      FOR j IN 0 .. jsonb_array_length(g->'blockers') - 1 LOOP
        IF g->'blockers'->>j NOT LIKE '%operations already ran%' THEN
          problems := problems || to_jsonb(format('Suggestion "%s": %s', left(x->>'title', 60), g->'blockers'->>j));
        END IF;
      END LOOP;
    END LOOP;
    sugg := sugg || jsonb_build_object('kind', CASE WHEN x->>'kind' IN ('geo', 'keywords', 'negatives', 'ads', 'assets', 'budget', 'tracking')
      THEN x->>'kind' ELSE 'other' END, 'title', left(x->>'title', 200), 'reason', left(coalesce(x->>'reason', ''), 2000),
      'proposal', coalesce(x->'proposal', '{"ops": []}'));
  END LOOP;
  IF jsonb_array_length(geo) > 0 THEN
    sugg := sugg || jsonb_build_object('kind', 'geo', 'title', 'Location changes', 'reason',
      'The agents want to change where ads show. Pick what you agree with.', 'proposal', jsonb_build_object('ops',
      (SELECT jsonb_agg(v || jsonb_build_object('option', 'g' || n)) FROM jsonb_array_elements(geo) WITH ORDINALITY t(v, n)),
      'options', (SELECT jsonb_agg(jsonb_build_object('id', 'g' || n, 'label', coalesce(v->>'summary', 'Location change'), 'reason', v->>'reason'))
                    FROM jsonb_array_elements(geo) WITH ORDINALITY t(v, n))));
  END IF;
  RETURN jsonb_build_object('ops', ops, 'suggestions', sugg, 'problems', problems);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_agent_finish(p_id bigint, p_ok boolean, p_output jsonb, p_summary text DEFAULT NULL,
  p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.ads_agent_runs; b public.ads_agent_runs; chk jsonb; x jsonb; nid bigint; acc uuid; nops int := 0; nsug int := 0;
        verdict text; problems jsonb; o public.ads_google_ops; blocked int := 0;
BEGIN
  SELECT * INTO r FROM public.ads_agent_runs WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status <> 'running' THEN RETURN jsonb_build_object('ignored', true); END IF;
  acc := coalesce(r.account_id, (crm_private.ads_google_account()).id);

  IF NOT coalesce(p_ok, false) OR p_output IS NULL OR jsonb_typeof(p_output) <> 'object' THEN
    UPDATE public.ads_agent_runs SET status = 'failed', error = left(coalesce(p_error, 'No usable answer'), 900), finished_at = now() WHERE id = r.id;
    PERFORM crm_private.ads_agent_close(r, false, 'The agents could not finish: ' || left(coalesce(p_error, 'no usable answer'), 300));
    RETURN jsonb_build_object('next', NULL);
  END IF;

  IF r.role = 'researcher' THEN
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, summary = left(coalesce(p_summary, p_output->>'summary'), 500),
      finished_at = now() WHERE id = r.id;
    INSERT INTO public.ads_agent_runs (account_id, role, job, parent_id, instruction_id, input)
    VALUES (acc, 'builder', r.job, r.id, r.instruction_id, jsonb_build_object('task', r.input, 'research', p_output)) RETURNING id INTO nid;
    RETURN jsonb_build_object('next', nid);
  END IF;

  IF r.role = 'builder' THEN
    chk := crm_private.ads_agent_check(p_output);
    IF jsonb_array_length(chk->'problems') > 0 THEN
      UPDATE public.ads_agent_runs SET status = 'rejected', output = p_output, finished_at = now(),
        summary = left(format('Code checks stopped %s problem(s): %s', jsonb_array_length(chk->'problems'), chk->'problems'->>0), 500) WHERE id = r.id;
      IF r.attempt >= 3 THEN
        UPDATE public.ads_agent_runs SET status = 'escalated' WHERE id = r.id;
        PERFORM crm_private.ads_agent_close(r, false, 'After 3 tries the proposal still failed the safety checks: ' || left((chk->'problems')::text, 600));
        RETURN jsonb_build_object('next', NULL);
      END IF;
      INSERT INTO public.ads_agent_runs (account_id, role, job, parent_id, instruction_id, attempt, input)
      VALUES (acc, 'builder', r.job, r.parent_id, r.instruction_id, r.attempt + 1,
              r.input || jsonb_build_object('previous_proposal', p_output, 'fix_these', chk->'problems', 'from', 'code checks')) RETURNING id INTO nid;
      RETURN jsonb_build_object('next', nid);
    END IF;
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output || jsonb_build_object('checked', chk), finished_at = now(),
      summary = left(coalesce(p_summary, format('Proposed %s change(s) and %s suggestion(s)', jsonb_array_length(chk->'ops'),
        jsonb_array_length(chk->'suggestions'))), 500) WHERE id = r.id;
    IF jsonb_array_length(chk->'ops') = 0 AND jsonb_array_length(chk->'suggestions') = 0 THEN
      PERFORM crm_private.ads_agent_close(r, true, coalesce(p_output->>'answer', 'Nothing needs changing right now.'));
      RETURN jsonb_build_object('next', NULL);
    END IF;
    INSERT INTO public.ads_agent_runs (account_id, role, job, parent_id, instruction_id, attempt, input)
    VALUES (acc, 'reviewer', r.job, r.id, r.instruction_id, r.attempt,
            jsonb_build_object('task', r.input->'task', 'research_summary', r.input->'research'->'summary',
              'proposal', jsonb_build_object('answer', p_output->>'answer', 'ops', chk->'ops', 'suggestions', chk->'suggestions'))) RETURNING id INTO nid;
    RETURN jsonb_build_object('next', nid);
  END IF;

  IF r.role = 'reviewer' THEN
    SELECT * INTO b FROM public.ads_agent_runs WHERE id = r.parent_id;
    verdict := lower(coalesce(p_output->>'verdict', ''));
    problems := CASE WHEN jsonb_typeof(p_output->'problems') = 'array' THEN p_output->'problems' ELSE '[]' END;
    IF verdict <> 'approve' THEN
      UPDATE public.ads_agent_runs SET status = 'rejected', output = p_output, finished_at = now(),
        summary = left(coalesce(p_summary, 'Rejected: ' || coalesce(problems->>0, 'no reason given')), 500) WHERE id = r.id;
      IF b.attempt >= 3 THEN
        UPDATE public.ads_agent_runs SET status = 'escalated' WHERE id = r.id;
        -- a human decides: the last proposal is shown as suggestions with the Reviewer's objections
        INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal, agent_run_id)
        SELECT acc, 'other', left('Needs your decision: ' || coalesce(b.input->'task'->>'title', b.job), 200),
               left('The Reviewer did not approve after 3 tries. Its objections: ' || array_to_string(ARRAY(SELECT jsonb_array_elements_text(problems)), '; '), 2000),
               jsonb_build_object('ops', r.input->'proposal'->'ops'), b.id
         WHERE jsonb_array_length(coalesce(r.input->'proposal'->'ops', '[]')) > 0;
        PERFORM crm_private.ads_agent_close(r, false, 'The Reviewer did not approve after 3 tries; the proposal is in Suggestions for you to decide.');
        RETURN jsonb_build_object('next', NULL);
      END IF;
      INSERT INTO public.ads_agent_runs (account_id, role, job, parent_id, instruction_id, attempt, input)
      VALUES (acc, 'builder', b.job, b.parent_id, b.instruction_id, b.attempt + 1,
              b.input || jsonb_build_object('previous_proposal', r.input->'proposal', 'fix_these', problems, 'from', 'reviewer')) RETURNING id INTO nid;
      RETURN jsonb_build_object('next', nid);
    END IF;

    -- approved: re-check (things may have changed), then make it real
    chk := crm_private.ads_agent_check(r.input->'proposal');
    FOR x IN SELECT v FROM jsonb_array_elements(chk->'ops') v LOOP
      INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, created_by_type, agent_run_id)
      VALUES (acc, x->>'kind', coalesce(x->'payload', '{}'), left(coalesce(x->>'summary', x->>'kind'), 300), left(x->>'reason', 1000), 'agent', b.id)
      RETURNING * INTO o;
      nops := nops + 1;
      IF o.status = 'blocked' THEN blocked := blocked + 1; END IF;
    END LOOP;
    FOR x IN SELECT v FROM jsonb_array_elements(chk->'suggestions') v LOOP
      INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal, agent_run_id)
      VALUES (acc, x->>'kind', x->>'title', x->>'reason', x->'proposal', b.id);
      nsug := nsug + 1;
    END LOOP;
    UPDATE public.ads_agent_runs SET status = 'done', output = p_output, finished_at = now(),
      summary = left(coalesce(p_summary, format('Approved %s change(s) and %s suggestion(s)', nops, nsug)), 500) WHERE id = r.id;
    PERFORM crm_private.ads_agent_close(r, true, concat_ws(' ', r.input->'proposal'->>'answer',
      format('(%s change(s) %s, %s suggestion(s) for you%s)', nops,
        CASE WHEN crm_private.ads_cfg('autopilot_google') = 'auto' THEN 'going live' ELSE 'waiting in Approvals' END, nsug,
        CASE WHEN blocked > 0 THEN format('; %s blocked by checks', blocked) ELSE '' END)));
    RETURN jsonb_build_object('next', NULL, 'ops', nops, 'suggestions', nsug);
  END IF;

  -- allocator / learner / supervisor (stage 4): store the result
  UPDATE public.ads_agent_runs SET status = 'done', output = p_output, summary = left(p_summary, 500), finished_at = now() WHERE id = r.id;
  PERFORM crm_private.ads_agent_close(r, true, p_output->>'answer');
  RETURN jsonb_build_object('next', NULL);
END $$;

-- Every 5 minutes. Pure SQL (no network).
CREATE OR REPLACE FUNCTION public.svc_ads_agents_tick() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.ads_agent_instructions; acc uuid := (crm_private.ads_google_account()).id; started int := 0; freed int := 0;
BEGIN
  IF acc IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  -- stuck steps (Mac asleep, crashed): back to the queue, or failed after 3 claims
  WITH s AS (UPDATE public.ads_agent_runs SET status = CASE WHEN claims >= 3 THEN 'failed' ELSE 'queued' END, claimed_at = NULL,
               error = CASE WHEN claims >= 3 THEN 'Stopped responding 3 times' ELSE error END,
               finished_at = CASE WHEN claims >= 3 THEN now() END
              WHERE status = 'running' AND claimed_at < now() - interval '30 minutes' RETURNING 1)
  SELECT count(*) INTO freed FROM s;
  -- new instructions: one chain each, oldest first
  FOR i IN SELECT * FROM public.ads_agent_instructions ins WHERE ins.status = 'new'
             AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs r WHERE r.instruction_id = ins.id) ORDER BY ins.created_at LIMIT 5 LOOP
    INSERT INTO public.ads_agent_runs (account_id, role, job, instruction_id, input)
    VALUES (acc, 'researcher', 'instruction', i.id, jsonb_build_object('title', left(i.body, 120), 'goal', i.body));
    started := started + 1;
  END LOOP;
  -- one daily review when nothing else is waiting
  IF crm_private.ads_cfg('agents_daily_review') = 'on'
     AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE status IN ('queued', 'running'))
     AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE job IN ('daily_review', 'audit_fix') AND parent_id IS NULL
                       AND created_at > now() - interval '20 hours') THEN
    INSERT INTO public.ads_agent_runs (account_id, role, job, input)
    VALUES (acc, 'researcher', 'daily_review', jsonb_build_object('title', 'Daily review',
      'goal', 'Review yesterday and the last 30 days: wasted search terms (add negatives), keywords and ads to improve, '
        || 'assets missing or weak, and anything blocking delivery. Propose only changes the data supports.'));
    started := started + 1;
  END IF;
  RETURN jsonb_build_object('started', started, 'freed', freed);
END $$;

-- First job: fix what the account audit found (13 Nov 2026). Queued once.
INSERT INTO public.ads_agent_runs (account_id, role, job, input)
SELECT a.id, 'researcher', 'audit_fix', jsonb_build_object('title', 'Fix the account audit findings', 'goal',
  'Fix these problems found in the account audit, in this order of importance. Check each against the current snapshot first; '
  || 'skip any that is already fixed.',
  'problems', jsonb_build_array(
    'The only enabled campaign has an ad group with 0 ads, so it cannot show at all. Write 2 responsive search ads for it (final URLs on weoneaviation.in, matching the keywords).',
    'Six account-level callouts make claims that cannot be proven and that the website itself removed (100% Job Assistance, Guaranteed DGCA Success!, Clear Exam in 1st Attempt, 25+ Partner Airlines, 98% Success Rate, Job Placement). Unlink them (asset_unlink) and add truthful callouts based on the website.',
    'Conversion counting is inflated: cheap off-product searches (cabin crew, BBA, air hostess) recorded most conversions. Only real enquiry actions (contact form, popup form, calls, WhatsApp click) should be primary; check the conversions in the snapshot and propose conversion_goal changes.',
    'About 44% of past spend went to competitor names, off-product searches (cabin crew, air hostess, BBA aviation, ground staff) and airline cadet programmes. Add negatives for these from the 365-day search terms, without blocking pilot training / CPL / DGCA ground class searches.',
    'The shared negative list "negative" (176 terms) is attached only to paused campaigns. Attach it to the enabled campaign (shared_set_attach).',
    'Locations use "presence or interest" across 9 regions, which shows ads to people outside them. Suggest switching to presence only, and which cities to keep, based on where past clicks and leads came from (as a suggestion with options).',
    'All sitelinks point to the home page, and one points to another domain. Add sitelinks to specific weoneaviation.in pages (fetch the site to find the real URLs) and unlink the wrong ones.',
    'One ad group holds 22 keywords and only one ground-classes keyword, although "ground classes for cpl" was the best past search. Propose a separate DGCA ground classes ad group with phrase/exact keywords and its own ads.'))
FROM (SELECT * FROM crm_private.ads_google_account()) a
WHERE a.id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE job = 'audit_fix');

REVOKE ALL ON FUNCTION public.svc_ads_agent_next(), public.svc_ads_agent_release(bigint, text),
  public.svc_ads_agent_finish(bigint, boolean, jsonb, text, text), public.svc_ads_agents_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_agent_next(), public.svc_ads_agent_release(bigint, text),
  public.svc_ads_agent_finish(bigint, boolean, jsonb, text, text), public.svc_ads_agents_tick() TO service_role;
REVOKE ALL ON FUNCTION crm_private.ads_agent_context(public.ads_agent_runs), crm_private.ads_agent_close(public.ads_agent_runs, boolean, text),
  crm_private.ads_agent_check(jsonb) FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-agents-tick';
    PERFORM cron.schedule('crm-ads-agents-tick', '*/5 * * * *', 'SELECT public.svc_ads_agents_tick()');
  END IF;
END $$;
