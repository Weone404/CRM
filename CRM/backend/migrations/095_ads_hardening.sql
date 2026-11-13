-- 095: ADS only, Google only. Hardening found by the worst-case test pass (60_ads_hardening_tests.sql):
--   * missing (NULL) mode / input type / action now get a clear message instead of a database error
--   * accepting a suggestion with picked options that do not exist is refused (it used to accept nothing)
--   * agent output that is not shaped as expected (an op that is a string, a proposal that is text) is refused or
--     cleaned instead of slipping through
--   * more than 25 changes: the first 25 go ahead and the rest wait for the next run (a big job no longer fails)
--   * the Reviewer now sees the research facts with their website sources (it rejected true, sourced facts before)
--   * a Reviewer answer with spaces (" approve ") is read correctly; a review with no proposal behind it stops safely
-- Re-runnable. Rollback: re-run 093_ads_autopilot.sql and 094_ads_agents.sql (they define the previous versions).

CREATE OR REPLACE FUNCTION public.api_ads_autopilot_save(p_mode text, p_daily numeric, p_monthly numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only people who can approve ADS changes can change Autopilot' USING ERRCODE = 'PT403'; END IF;
  IF coalesce(p_mode, '') NOT IN ('auto', 'off') THEN RAISE EXCEPTION 'Mode is auto or off' USING ERRCODE = 'PT422'; END IF;
  IF p_daily IS NULL OR p_daily < 1 OR p_daily > 1000000 THEN RAISE EXCEPTION 'Enter a daily limit of at least 1' USING ERRCODE = 'PT422'; END IF;
  IF p_monthly IS NULL OR p_monthly < p_daily THEN RAISE EXCEPTION 'The monthly limit cannot be below the daily limit' USING ERRCODE = 'PT422'; END IF;
  IF p_monthly > p_daily * 31 THEN RAISE EXCEPTION 'The monthly limit is more than 31 days at the daily limit; lower it' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('autopilot_google', p_mode), ('google_cap_daily', round(p_daily, 2)::text),
    ('google_cap_monthly', round(p_monthly, 2)::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('autopilot_saved', 'config', 'autopilot_google',
    jsonb_build_object('mode', p_mode, 'daily', p_daily, 'monthly', p_monthly));
  RETURN jsonb_build_object('saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_agent_instruct(p_text text, p_via text DEFAULT 'typed') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')); n int; nid bigint;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF length(t) < 2 THEN RAISE EXCEPTION 'Write or say what the agents should do' USING ERRCODE = 'PT422'; END IF;
  IF length(t) > 2000 THEN RAISE EXCEPTION 'Keep it under 2000 characters' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p_via, '') NOT IN ('typed', 'voice') THEN RAISE EXCEPTION 'typed or voice' USING ERRCODE = 'PT422'; END IF;
  SELECT count(*) INTO n FROM public.ads_agent_instructions
   WHERE created_by IS NOT DISTINCT FROM crm_private.current_employee_id() AND created_at > now() - interval '24 hours';
  IF n >= 30 THEN RAISE EXCEPTION 'That is 30 instructions in 24 hours; wait for the agents to catch up' USING ERRCODE = 'PT429'; END IF;
  INSERT INTO public.ads_agent_instructions (account_id, body, via, created_by)
  VALUES ((crm_private.ads_google_account()).id, t, p_via, crm_private.current_employee_id()) RETURNING id INTO nid;
  PERFORM crm_private.ads_log('agent_instructed', 'instruction', nid::text, jsonb_build_object('via', p_via));
  RETURN jsonb_build_object('id', nid, 'status', 'new');
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_suggestion_decide(p_id bigint, p_action text, p_note text DEFAULT NULL,
  p_pick text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_autopilot_suggestions; op jsonb; o public.ads_google_ops; res jsonb := '[]'; me uuid := crm_private.current_employee_id();
        appr boolean := crm_private.ads_can_approve(); nid bigint; acc uuid;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF coalesce(p_action, '') NOT IN ('accept', 'change', 'dismiss') THEN RAISE EXCEPTION 'accept, change or dismiss' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO s FROM public.ads_autopilot_suggestions WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Suggestion not found' USING ERRCODE = 'PT404'; END IF;
  IF s.status <> 'open' THEN RAISE EXCEPTION 'This suggestion is already %', s.status USING ERRCODE = 'PT409'; END IF;

  IF p_action = 'change' THEN
    IF length(btrim(coalesce(p_note, ''))) < 2 THEN RAISE EXCEPTION 'Say what to change' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.ads_agent_instructions (account_id, body, via, suggestion_id, created_by)
    VALUES (s.account_id, left(format('Change suggestion "%s": %s', s.title, btrim(p_note)), 2000), 'suggestion', s.id, me) RETURNING id INTO nid;
    res := jsonb_build_object('instruction_id', nid);
  ELSIF p_action = 'accept' THEN
    acc := coalesce(s.account_id, (crm_private.ads_google_account()).id);
    IF acc IS NULL THEN RAISE EXCEPTION 'Connect the Google Ads account first' USING ERRCODE = 'PT409'; END IF;
    IF p_pick IS NOT NULL AND cardinality(p_pick) = 0 AND jsonb_array_length(CASE WHEN jsonb_typeof(s.proposal->'ops') = 'array' THEN s.proposal->'ops' ELSE '[]' END) > 0 THEN
      RAISE EXCEPTION 'Pick at least one option' USING ERRCODE = 'PT422';
    END IF;
    FOR op IN SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.proposal->'ops') = 'array' THEN s.proposal->'ops' ELSE '[]' END) x LOOP
      IF jsonb_typeof(op) <> 'object' THEN CONTINUE; END IF;
      IF op ? 'option' AND p_pick IS NOT NULL AND NOT (op->>'option' = ANY (p_pick)) THEN CONTINUE; END IF;
      INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, created_by_type, created_by, agent_run_id)
      VALUES (acc, op->>'kind', coalesce(op->'payload', '{}'), left(coalesce(op->>'summary', s.title), 300), left(s.reason, 1000),
              'agent', me, s.agent_run_id) RETURNING * INTO o;
      IF appr AND o.status = 'pending' THEN
        UPDATE public.ads_google_ops SET status = 'approved', approved_by = me, approved_at = now() WHERE id = o.id RETURNING * INTO o;
      END IF;
      res := res || jsonb_build_object('id', o.id, 'kind', o.kind, 'status', o.status, 'blockers', o.gate_result->'blockers');
    END LOOP;
    IF jsonb_array_length(res) = 0 AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.proposal->'ops') = 'array'
         THEN s.proposal->'ops' ELSE '[]' END) z WHERE jsonb_typeof(z) = 'object') THEN
      RAISE EXCEPTION 'None of the picked options belong to this suggestion; pick again' USING ERRCODE = 'PT422';
    END IF;
    res := jsonb_build_object('ops', res);
  END IF;
  UPDATE public.ads_autopilot_suggestions SET status = CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'change' THEN 'changed' ELSE 'dismissed' END,
    user_note = left(p_note, 1000), decided_by = me, decided_at = now(), result = res WHERE id = p_id;
  PERFORM crm_private.ads_log('suggestion_' || p_action, 'suggestion', p_id::text, res);
  RETURN res || jsonb_build_object('status', CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'change' THEN 'changed' ELSE 'dismissed' END);
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_agent_check(p_out jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc uuid := (crm_private.ads_google_account()).id; ops jsonb := '[]'; sugg jsonb := '[]'; geo jsonb := '[]';
        problems jsonb := '[]'; x jsonb; g jsonb; i int := 0; so jsonb; j int;
BEGIN
  FOR x IN SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_out->'ops') = 'array' THEN p_out->'ops' ELSE '[]' END) v LOOP
    i := i + 1;
    IF jsonb_typeof(x) <> 'object' THEN problems := problems || to_jsonb(format('Operation %s is not an object.', i)); CONTINUE; END IF;
    IF i > 25 THEN EXIT; END IF;   -- only the first 25 (most important first); the rest waits for the next run
    IF x->>'kind' = 'campaign_geo' THEN geo := geo || x; CONTINUE; END IF;
    g := crm_private.ads_google_gate(acc, coalesce(x->>'kind', ''), coalesce(x->'payload', '{}'));
    FOR j IN 0 .. jsonb_array_length(g->'blockers') - 1 LOOP
      problems := problems || to_jsonb(format('Operation %s (%s, "%s"): %s', i, x->>'kind', left(coalesce(x->>'summary', ''), 60), g->'blockers'->>j));
    END LOOP;
    ops := ops || x;
  END LOOP;
  FOR x IN SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_out->'suggestions') = 'array' THEN p_out->'suggestions' ELSE '[]' END) v LOOP
    IF jsonb_typeof(x) <> 'object' OR coalesce(x->>'title', '') = '' THEN problems := problems || to_jsonb('A suggestion has no title.'::text); CONTINUE; END IF;
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
      'proposal', CASE WHEN jsonb_typeof(x->'proposal') = 'object' AND jsonb_typeof(coalesce(x->'proposal'->'ops', '[]')) = 'array'
        THEN x->'proposal' ELSE '{"ops": []}'::jsonb END);
  END LOOP;
  IF jsonb_array_length(geo) > 0 THEN
    sugg := sugg || jsonb_build_object('kind', 'geo', 'title', 'Location changes', 'reason',
      'The agents want to change where ads show. Pick what you agree with.', 'proposal', jsonb_build_object('ops',
      (SELECT jsonb_agg(v || jsonb_build_object('option', 'g' || n)) FROM jsonb_array_elements(geo) WITH ORDINALITY t(v, n)),
      'options', (SELECT jsonb_agg(jsonb_build_object('id', 'g' || n, 'label', coalesce(v->>'summary', 'Location change'), 'reason', v->>'reason'))
                    FROM jsonb_array_elements(geo) WITH ORDINALITY t(v, n))));
  END IF;
  RETURN jsonb_build_object('ops', ops, 'suggestions', sugg, 'problems', problems,
    'left_for_next_run', greatest(0, jsonb_array_length(CASE WHEN jsonb_typeof(p_out->'ops') = 'array' THEN p_out->'ops' ELSE '[]' END) - 25));
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
              'research_facts', r.input->'research'->'facts', 'research_pages', r.input->'research'->'pages',
              'proposal', jsonb_build_object('answer', p_output->>'answer', 'ops', chk->'ops', 'suggestions', chk->'suggestions'))) RETURNING id INTO nid;
    RETURN jsonb_build_object('next', nid);
  END IF;

  IF r.role = 'reviewer' THEN
    SELECT * INTO b FROM public.ads_agent_runs WHERE id = r.parent_id;
    IF b.id IS NULL THEN   -- a review with no proposal behind it (should never happen): stop safely
      UPDATE public.ads_agent_runs SET status = 'failed', error = 'Review without a builder step', finished_at = now() WHERE id = r.id;
      PERFORM crm_private.ads_agent_close(r, false, 'The review had no proposal behind it; nothing was changed.');
      RETURN jsonb_build_object('next', NULL);
    END IF;
    verdict := lower(btrim(coalesce(p_output->>'verdict', '')));
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
