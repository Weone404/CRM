-- Rollback of 099: the previous definitions (092 / 093 / 094 / 095 / 096), then the new objects are dropped.
-- Operations of the new kinds and notes of the new roles are removed first so the old constraints fit again.
CREATE OR REPLACE FUNCTION crm_private.ads_google_gate(p_account uuid, p_kind text, p_payload jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; b jsonb := '[]'; w jsonb := '[]'; e text; x jsonb; s text; n int; i int; r jsonb;
        hs text[]; ds text[];
  -- small helper via local block below
BEGIN
  SELECT * INTO a FROM public.ads_accounts WHERE id = p_account;
  IF a.id IS NULL OR a.platform <> 'google' THEN
    RETURN jsonb_build_object('blockers', jsonb_build_array('Google Ads account not found.'), 'warnings', '[]'::jsonb);
  END IF;
  IF a.status <> 'connected' THEN b := b || to_jsonb(format('The Google Ads account is "%s", not connected.', a.status)); END IF;
  IF jsonb_typeof(p_payload) <> 'object' THEN b := b || to_jsonb('Payload must be an object.'::text); END IF;

  IF p_kind = 'keyword_add' THEN
    IF coalesce(p_payload->>'ad_group_id', '') !~ '^\d+$' THEN b := b || to_jsonb('ad_group_id is required.'::text); END IF;
    IF jsonb_typeof(p_payload->'keywords') <> 'array' OR jsonb_array_length(p_payload->'keywords') NOT BETWEEN 1 AND 50 THEN
      b := b || to_jsonb('Give 1-50 keywords.'::text);
    ELSE
      FOR x IN SELECT * FROM jsonb_array_elements(p_payload->'keywords') LOOP
        e := crm_private.ads_g_kw_err(x, false); IF e IS NOT NULL THEN b := b || to_jsonb(e); END IF;
      END LOOP;
    END IF;

  ELSIF p_kind = 'negative_add' THEN
    IF coalesce(p_payload->>'level', '') NOT IN ('campaign', 'shared_set') THEN
      b := b || to_jsonb('level must be campaign or shared_set.'::text);
    ELSIF coalesce(p_payload->>(CASE WHEN p_payload->>'level' = 'campaign' THEN 'campaign_id' ELSE 'shared_set_id' END), '') !~ '^\d+$' THEN
      b := b || to_jsonb('campaign_id or shared_set_id is required.'::text);
    END IF;
    IF jsonb_typeof(p_payload->'keywords') <> 'array' OR jsonb_array_length(p_payload->'keywords') NOT BETWEEN 1 AND 200 THEN
      b := b || to_jsonb('Give 1-200 negative keywords.'::text);
    ELSE
      FOR x IN SELECT * FROM jsonb_array_elements(p_payload->'keywords') LOOP
        e := crm_private.ads_g_kw_err(x, true); IF e IS NOT NULL THEN b := b || to_jsonb(e); CONTINUE; END IF;
        -- a negative must not block a protected core search
        SELECT t INTO s FROM jsonb_array_elements_text(coalesce(crm_private.ads_rule('g_protected_terms')->'terms', '[]')) t
         WHERE CASE upper(x->>'match')
                 WHEN 'EXACT' THEN lower(trim(x->>'text')) = lower(t)
                 WHEN 'PHRASE' THEN (' ' || lower(t) || ' ') LIKE ('% ' || lower(trim(x->>'text')) || ' %')
                 ELSE (SELECT bool_and((' ' || lower(t) || ' ') LIKE ('% ' || wd || ' %'))
                         FROM unnest(regexp_split_to_array(lower(trim(x->>'text')), '\s+')) wd) END
         LIMIT 1;
        IF s IS NOT NULL THEN b := b || to_jsonb(format('Negative "%s" would block the core search "%s".', x->>'text', s)); END IF;
      END LOOP;
    END IF;

  ELSIF p_kind IN ('keyword_status', 'ad_status') THEN
    IF coalesce(p_payload->>'resource_name', '') !~ ('^customers/' || a.external_id || '/(adGroupCriteria|adGroupAds)/\d+~\d+$') THEN
      b := b || to_jsonb('resource_name of this account''s keyword or ad is required.'::text);
    END IF;
    IF upper(coalesce(p_payload->>'status', '')) NOT IN ('ENABLED', 'PAUSED', 'REMOVED') THEN
      b := b || to_jsonb('status must be ENABLED, PAUSED or REMOVED.'::text);
    END IF;

  ELSIF p_kind = 'rsa_create' THEN
    IF coalesce(p_payload->>'ad_group_id', '') !~ '^\d+$' THEN b := b || to_jsonb('ad_group_id is required.'::text); END IF;
    IF NOT crm_private.ads_g_url_ok(p_payload->>'final_url') THEN
      b := b || to_jsonb(format('Final URL must be https and on: %s.', crm_private.ads_cfg('google_allowed_domains')));
    END IF;
    SELECT array_agg(trim(v)) INTO hs FROM jsonb_array_elements_text(coalesce(p_payload->'headlines', '[]')) v;
    SELECT array_agg(trim(v)) INTO ds FROM jsonb_array_elements_text(coalesce(p_payload->'descriptions', '[]')) v;
    IF coalesce(array_length(hs, 1), 0) NOT BETWEEN 3 AND 15 THEN b := b || to_jsonb('Give 3-15 headlines.'::text); END IF;
    IF coalesce(array_length(ds, 1), 0) NOT BETWEEN 2 AND 4 THEN b := b || to_jsonb('Give 2-4 descriptions.'::text); END IF;
    IF (SELECT count(DISTINCT lower(v)) FROM unnest(hs) v) <> coalesce(array_length(hs, 1), 0) THEN
      b := b || to_jsonb('Headlines must all be different.'::text);
    END IF;
    FOREACH s IN ARRAY coalesce(hs, '{}') LOOP
      IF length(s) NOT BETWEEN 1 AND 30 THEN b := b || to_jsonb(format('Headline "%s" is over 30 characters.', s)); END IF;
      IF s ~ '!' THEN b := b || to_jsonb(format('Headline "%s" has "!" (not allowed in headlines).', s)); END IF;
    END LOOP;
    FOREACH s IN ARRAY coalesce(ds, '{}') LOOP
      IF length(s) NOT BETWEEN 1 AND 90 THEN b := b || to_jsonb(format('Description "%s" is over 90 characters.', left(s, 95))); END IF;
      IF s ~ '!.*!' THEN b := b || to_jsonb(format('Description "%s" has more than one "!".', left(s, 95))); END IF;
    END LOOP;
    FOREACH s IN ARRAY coalesce(hs, '{}') || coalesce(ds, '{}') || ARRAY[coalesce(p_payload->>'path1', ''), coalesce(p_payload->>'path2', '')] LOOP
      e := crm_private.ads_g_claim(s);
      IF e IS NOT NULL THEN b := b || to_jsonb(format('"%s" contains the claim "%s", which needs proof Google can check.', s, e)); END IF;
      IF s ~ '\m[A-Z]{5,}\M' AND s !~ '\m(DGCA|ATPL|CPL|PPL|IGRUA|NCR)\M' THEN w := w || to_jsonb(format('"%s" has words in capitals.', s)); END IF;
    END LOOP;
    IF length(coalesce(p_payload->>'path1', '')) > 15 OR length(coalesce(p_payload->>'path2', '')) > 15 THEN
      b := b || to_jsonb('Display path parts are at most 15 characters.'::text);
    END IF;

  ELSIF p_kind = 'ad_group_create' THEN
    IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' THEN b := b || to_jsonb('campaign_id is required.'::text); END IF;
    IF length(trim(coalesce(p_payload->>'name', ''))) NOT BETWEEN 2 AND 255 THEN b := b || to_jsonb('Ad group name is required.'::text); END IF;
    r := crm_private.ads_rule('g_cpc_max');
    IF p_payload ? 'cpc_bid' AND (coalesce((p_payload->>'cpc_bid')::numeric, -1) <= 0
        OR (r IS NOT NULL AND (p_payload->>'cpc_bid')::numeric > (r->>'max')::numeric)) THEN
      b := b || to_jsonb(format('CPC bid must be above 0 and at most %s.', r->>'max'));
    END IF;

  ELSIF p_kind = 'campaign_geo' THEN
    IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' THEN b := b || to_jsonb('campaign_id is required.'::text); END IF;
    IF p_payload ? 'target_type' AND upper(p_payload->>'target_type') NOT IN ('PRESENCE', 'PRESENCE_OR_INTEREST') THEN
      b := b || to_jsonb('target_type must be PRESENCE or PRESENCE_OR_INTEREST.'::text);
    END IF;
    IF upper(coalesce(p_payload->>'target_type', '')) = 'PRESENCE_OR_INTEREST' THEN
      w := w || to_jsonb('"Presence or interest" also shows ads to people outside the area.'::text);
    END IF;
    r := crm_private.ads_rule('g_geo_ids_max');
    IF jsonb_array_length(coalesce(p_payload->'add', '[]')) > coalesce((r->>'max')::int, 25) THEN
      b := b || to_jsonb(format('At most %s locations per operation.', r->>'max'));
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_payload->'add', '[]')) g WHERE g !~ '^\d+$')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_payload->'remove', '[]')) g WHERE g !~ '^\d+$') THEN
      b := b || to_jsonb('Location ids must be numeric Google geo target ids.'::text);
    END IF;
    IF NOT (p_payload ? 'target_type' OR jsonb_array_length(coalesce(p_payload->'add', '[]')) > 0
            OR jsonb_array_length(coalesce(p_payload->'remove', '[]')) > 0) THEN
      b := b || to_jsonb('Nothing to change.'::text);
    END IF;

  ELSIF p_kind = 'shared_set_attach' THEN
    IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' OR coalesce(p_payload->>'shared_set_id', '') !~ '^\d+$' THEN
      b := b || to_jsonb('campaign_id and shared_set_id are required.'::text);
    END IF;

  ELSIF p_kind = 'callout_add' THEN
    s := trim(coalesce(p_payload->>'text', ''));
    IF length(s) NOT BETWEEN 1 AND 25 THEN b := b || to_jsonb('Callout must be 1-25 characters.'::text); END IF;
    e := crm_private.ads_g_claim(s);
    IF e IS NOT NULL THEN b := b || to_jsonb(format('Callout "%s" contains the claim "%s".', s, e)); END IF;
    IF s ~ '!' THEN b := b || to_jsonb('Callouts may not use "!".'::text); END IF;

  ELSIF p_kind = 'sitelink_add' THEN
    IF length(trim(coalesce(p_payload->>'text', ''))) NOT BETWEEN 1 AND 25 THEN b := b || to_jsonb('Sitelink text must be 1-25 characters.'::text); END IF;
    IF length(coalesce(p_payload->>'description1', '')) > 35 OR length(coalesce(p_payload->>'description2', '')) > 35 THEN
      b := b || to_jsonb('Sitelink descriptions are at most 35 characters.'::text);
    END IF;
    IF NOT crm_private.ads_g_url_ok(p_payload->>'final_url') THEN
      b := b || to_jsonb(format('Sitelink URL must be https and on: %s.', crm_private.ads_cfg('google_allowed_domains')));
    END IF;
    FOREACH s IN ARRAY ARRAY[coalesce(p_payload->>'text', ''), coalesce(p_payload->>'description1', ''), coalesce(p_payload->>'description2', '')] LOOP
      e := crm_private.ads_g_claim(s);
      IF e IS NOT NULL THEN b := b || to_jsonb(format('"%s" contains the claim "%s".', s, e)); END IF;
    END LOOP;
    IF p_payload ? 'campaign_id' AND coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' THEN b := b || to_jsonb('campaign_id must be numeric.'::text); END IF;

  ELSIF p_kind = 'asset_unlink' THEN
    IF coalesce(p_payload->>'resource_name', '') !~ ('^customers/' || a.external_id || '/(customerAssets|campaignAssets)/[\d~]+~[A-Z_]+$') THEN
      b := b || to_jsonb('resource_name of this account''s customer or campaign asset link is required.'::text);
    END IF;

  ELSIF p_kind = 'conversion_goal' THEN
    IF coalesce(p_payload->>'conversion_action_id', '') !~ '^\d+$' OR jsonb_typeof(p_payload->'primary') <> 'boolean' THEN
      b := b || to_jsonb('conversion_action_id and primary (true/false) are required.'::text);
    END IF;
  ELSE
    b := b || to_jsonb('Unknown operation type.'::text);
  END IF;

  r := crm_private.ads_rule('g_ops_per_day');
  IF r IS NOT NULL THEN
    SELECT count(*) INTO n FROM public.ads_google_ops o
     WHERE o.account_id = p_account AND o.id IS DISTINCT FROM p_exclude
       AND o.status IN ('approved', 'executing', 'verified', 'outcome_unknown') AND o.created_at > now() - interval '24 hours';
    IF n >= (r->>'max')::int THEN b := b || to_jsonb(format('%s operations already ran in the last 24 hours (limit %s).', n, r->>'max')); END IF;
  END IF;
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN w := w || to_jsonb('Emergency stop is on: nothing is sent until it is off.'::text); END IF;
  RETURN jsonb_build_object('blockers', b, 'warnings', w);
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

CREATE OR REPLACE FUNCTION public.api_ads_autopilot() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; d date; capd numeric; capm numeric; f0 date; added numeric; spent numeric; avg7 numeric;
        est numeric; days numeric; mtd numeric; enabled_total numeric;
BEGIN
  PERFORM crm_private.ads_require_view();
  a := crm_private.ads_google_account();
  d := crm_private.ads_google_today();
  capd := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
  capm := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
  mtd := crm_private.ads_google_month_spend();
  avg7 := round(crm_private.ads_google_spend(d - 7, d - 1) / 7, 2);
  SELECT coalesce(sum(c.daily_budget), 0) INTO enabled_total FROM public.ads_campaigns c JOIN public.ads_accounts x ON x.id = c.account_id
   WHERE x.platform = 'google' AND c.status = 'ENABLED';
  SELECT min(added_on), sum(amount) INTO f0, added FROM public.ads_funds WHERE account_id = a.id;
  IF f0 IS NOT NULL THEN
    spent := crm_private.ads_google_spend(f0, d);
    est := added - spent;
    days := CASE WHEN greatest(avg7, coalesce(enabled_total, 0)) > 0 THEN round(est / greatest(avg7, enabled_total), 1) END;
  END IF;
  RETURN jsonb_build_object(
    'mode', coalesce(crm_private.ads_cfg('autopilot_google'), 'off'),
    'stopped', crm_private.ads_cfg('execution_paused') = 'true',
    'can_approve', crm_private.ads_can_approve(), 'is_admin', crm_private.is_admin(),
    'caps', jsonb_build_object('daily', capd, 'monthly', capm),
    'account', CASE WHEN a.id IS NOT NULL THEN jsonb_build_object('id', a.id, 'name', a.name, 'external_id', a.external_id,
      'currency', a.currency, 'status', a.status, 'last_ok_at', a.last_ok_at) END,
    'today', d, 'days_left', crm_private.ads_google_days_left(),
    'spend', jsonb_build_object('today', crm_private.ads_google_spend(d, d), 'yesterday', crm_private.ads_google_spend(d - 1, d - 1),
      'month', mtd, 'avg7', avg7),
    'budgets', jsonb_build_object('enabled_total', enabled_total, 'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'name', c.name, 'daily_budget', c.daily_budget) ORDER BY c.daily_budget DESC NULLS LAST), '[]')
        FROM public.ads_campaigns c JOIN public.ads_accounts x ON x.id = c.account_id WHERE x.platform = 'google' AND c.status = 'ENABLED')),
    'funds', jsonb_build_object('since', f0, 'added', added, 'spent_since', spent, 'estimate', est, 'days_left', days,
      'low', est IS NOT NULL AND (est <= 0 OR (days IS NOT NULL AND days < 3)),
      'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'added_on', added_on, 'note', note)
        ORDER BY added_on DESC, id DESC), '[]') FROM (SELECT * FROM public.ads_funds WHERE account_id = a.id
        ORDER BY added_on DESC, id DESC LIMIT 10) f)),
    'suggestions', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY (s.status = 'open') DESC, s.created_at DESC), '[]') FROM (
      SELECT * FROM public.ads_autopilot_suggestions ORDER BY (status = 'open') DESC, created_at DESC LIMIT 40) s),
    'instructions', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at DESC), '[]') FROM (
      SELECT id, body, via, status, answer, created_at, answered_at FROM public.ads_agent_instructions ORDER BY created_at DESC LIMIT 20) i),
    'runs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'role', r.role, 'job', r.job, 'status', r.status,
      'attempt', r.attempt, 'summary', r.summary, 'error', r.error, 'created_at', r.created_at, 'finished_at', r.finished_at)
      ORDER BY r.created_at DESC), '[]') FROM (SELECT * FROM public.ads_agent_runs ORDER BY created_at DESC LIMIT 40) r),
    'ops', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'summary', o.summary, 'status', o.status,
      'by', o.created_by_type, 'error', o.error, 'blockers', o.gate_result->'blockers', 'created_at', o.created_at)
      ORDER BY o.created_at DESC), '[]') FROM (SELECT * FROM public.ads_google_ops ORDER BY created_at DESC LIMIT 40) o));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_autopilot_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz := nullif(crm_private.ads_cfg('agents_last_seen'), '')::timestamptz; busy public.ads_agent_runs;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO busy FROM public.ads_agent_runs WHERE status = 'running' AND claimed_at > now() - interval '30 minutes' ORDER BY claimed_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'agents', jsonb_build_object('last_seen', seen,
      'online', busy.id IS NOT NULL OR (seen IS NOT NULL AND seen > now() - interval '3 minutes'),
      'working_on', CASE WHEN busy.id IS NOT NULL THEN jsonb_build_object('role', busy.role, 'job', busy.job, 'since', busy.claimed_at) END,
      'queued', (SELECT count(*) FROM public.ads_agent_runs WHERE status = 'queued')),
    'report', (SELECT jsonb_build_object('text', summary, 'data', output, 'at', created_at) FROM public.ads_agent_runs
                WHERE role = 'supervisor' AND job = 'daily_report' ORDER BY created_at DESC LIMIT 1),
    'playbook', (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', lesson, 'evidence', evidence) ORDER BY id), '[]') FROM public.ads_playbook WHERE active));
END $$;

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

CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', o.payload, 'account_external_id', a.external_id,
      'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes')) END
$$;

DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-convert', 'crm-ads-tracking'); END IF; END $$;
DROP TRIGGER IF EXISTS trg_ads_google_op_applied ON public.ads_google_ops;
DELETE FROM public.ads_google_ops WHERE kind IN ('cpc_cap', 'budget');
DELETE FROM public.ads_agent_runs WHERE role IN ('team_lead', 'tracking');
ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status',
  'ad_group_create', 'campaign_geo', 'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal'));
ALTER TABLE public.ads_agent_runs DROP CONSTRAINT IF EXISTS ads_agent_runs_role_check;
ALTER TABLE public.ads_agent_runs ADD CONSTRAINT ads_agent_runs_role_check CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor'));
DROP FUNCTION IF EXISTS public.svc_ads_suggestions_auto(), public.svc_ads_conversions_work(), public.svc_ads_conversion_action_save(text, text),
  public.svc_ads_conversion_finish(bigint, text, text), public.svc_ads_tracking_check(), crm_private.ads_google_op_applied(),
  crm_private.ads_suggestion_pick(jsonb), crm_private.ads_suggestion_auto_at(bigint), crm_private.ads_team(), crm_private.ads_desk_state(),
  crm_private.ads_conversions_wake(), crm_private.ads_conversions_queue(), crm_private.ads_conversion_defs(), crm_private.ads_conversion_actions();
DROP TABLE IF EXISTS public.ads_conversion_uploads, public.ads_agent_desks;
DELETE FROM public.ads_config WHERE key IN ('suggest_auto_hours', 'suggest_auto_since', 'agents_chains_per_day', 'google_conv_upload', 'google_conv_actions');
DELETE FROM public.ads_rules WHERE code IN ('g_cpc_cap_min', 'g_cpc_cap_step', 'g_budget_step');
