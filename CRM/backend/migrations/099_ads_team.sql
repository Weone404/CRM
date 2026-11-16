-- 099: ADS only (Google). The specialist team: a Team Lead that plans the work, one desk per job, the 24-hour rule for
-- unanswered suggestions, bids and budget inside the owner's limits, and the CRM reporting its own enquiries to Google.
--
--   Team Lead (code, every 5 min)   one desk works at a time; a desk runs when it is due AND there is new spend to look at;
--                                   at most `agents_chains_per_day` runs a day (protects the Claude subscription).
--   Desks (AI: Researcher -> Builder -> code checks -> Reviewer, as before): Search Terms, Keywords, Ad Writer, Extensions,
--                                   Bids & Budget, Locations & Timing, Landing Page & Quality Score. Each has its own brief.
--   24-hour rule (code)             a suggestion the Reviewer approved and the owner has not answered is applied after
--                                   `suggest_auto_hours` with the agents' recommended option. Never: proposals the Reviewer
--                                   rejected, suggestions with nothing to apply, or anything while the emergency stop is on.
--   Bids & budget (new operations)  cpc_cap (Maximize Clicks max CPC) and budget (daily budget). The gate refuses anything
--                                   above the owner's daily / monthly limits, more than one step a day, or too big a step.
--   Lead Quality (code)             ad enquiries are reported to Google as click conversions (the website has no Google tag),
--                                   only for people who allowed ad data sharing, each exactly once.
--   Tracking (code, daily)          warns when clicks arrive but no enquiry does, or when reporting to Google fails.
-- Re-runnable. Rollback: 099_ads_team_down.sql.

-- ------------------------------------------------------------------------------------------- schema
ALTER TABLE public.ads_agent_runs DROP CONSTRAINT IF EXISTS ads_agent_runs_role_check;
ALTER TABLE public.ads_agent_runs ADD CONSTRAINT ads_agent_runs_role_check
  CHECK (role IN ('researcher', 'builder', 'reviewer', 'allocator', 'learner', 'supervisor', 'team_lead', 'tracking'));
ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget'));

INSERT INTO public.ads_config (key, value) VALUES
  ('suggest_auto_hours', '24'),                  -- hours an approved suggestion waits for the owner; '' or 0 = wait for ever
  ('suggest_auto_since', now()::text),           -- suggestions older than this start their wait here, not when they were written
  ('agents_chains_per_day', '3'),                -- desk runs the Team Lead starts in 24 hours
  ('google_conv_upload', 'on'),                  -- report CRM enquiries to Google
  ('google_conv_actions', '{}')                  -- {"enquiry": "<conversion action id>", ...}, filled in when Google creates them
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_rules (code, label, severity, value) VALUES
  ('g_cpc_cap_min', 'Lowest max CPC an agent may set (account currency)', 'blocker', '{"min": 3}'),
  ('g_cpc_cap_step', 'Largest change of the max CPC in one step (percent)', 'blocker', '{"pct": 30}'),
  ('g_budget_step', 'Largest daily budget change by an agent in one step (percent)', 'blocker', '{"pct": 30}')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.ads_agent_desks (
  key text PRIMARY KEY CHECK (key ~ '^[a-z_]{3,30}$'),
  title text NOT NULL,
  kind text NOT NULL DEFAULT 'agent' CHECK (kind IN ('agent', 'system')),   -- agent = AI desk the Team Lead schedules; system = code
  does text NOT NULL,                             -- one line for the Team list in the CRM
  goal text,                                      -- the desk's brief (agent desks)
  every_hours int NOT NULL DEFAULT 24 CHECK (every_hours BETWEEN 1 AND 2160),
  min_spend numeric(14,2) NOT NULL DEFAULT 0,     -- new spend needed since its last run before it runs again
  run_role text,                                  -- system members: the role their notes are written under
  enabled boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 100);
ALTER TABLE public.ads_agent_desks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_agent_desks FROM anon, authenticated;

INSERT INTO public.ads_agent_desks (key, title, kind, does, every_hours, min_spend, run_role, sort, goal) VALUES
('team_lead', 'Team Lead', 'system', 'Plans the work: decides which specialist runs next, and applies suggestions you have not answered in 24 hours.', 1, 0, 'team_lead', 1, NULL),
('search_terms', 'Search Terms', 'agent', 'Blocks searches that waste money and adds the searches that bring students.', 24, 100, NULL, 10,
'You are the Search Terms desk. Job: stop paying for searches that cannot become students, and catch the searches that do.
1. From search_terms_30d (365d for history) list the terms that cost money. Judge results by CONTEXT.ad_leads_30d first (real CRM enquiries), Google conversions second.
2. Group the waste by intent (other courses, jobs and salary, competitor names, other cities, free or scholarship, airline cadet programmes). Add negatives at the smallest scope that works: PHRASE in the shared list for a whole theme, EXACT for one odd term. Never block a protected search.
3. A search that brought an enquiry, or is clearly a student search, and is not a keyword yet: add it as PHRASE or EXACT in the ad group whose ads match.
4. Leave terms with under 2 clicks alone unless they are clearly off-topic. If a term could be people looking for We One Aviation, make it a suggestion with a recommended option instead of a change.
Stay inside this job. Operations you may use: negative_add, keyword_add.'),
('keywords', 'Keywords', 'agent', 'Keeps the right keywords in the right ad groups, and pauses the ones that only cost money.', 72, 300, NULL, 20,
'You are the Keywords desk. Job: the right keywords, in the right ad groups, with the right match type.
1. Check every enabled keyword: match type, Quality Score and its three parts, duplicates across ad groups, and keywords with spend but no CRM enquiry over a fair sample (at least 30 clicks, or 3 times the usual cost per enquiry).
2. Pause only on evidence. Never pause a keyword that brought a CRM enquiry in the last 30 days (CONTEXT.ad_leads_30d).
3. Add keyword ideas that match what We One Aviation really teaches (research facts and pages), PHRASE or EXACT only, in the ad group whose ads and landing page fit.
4. If one ad group mixes themes, propose a separate ad group as a suggestion with a recommended option.
Stay inside this job. Operations you may use: keyword_add, keyword_status, and ad_group_create inside a suggestion.'),
('ads', 'Ad Writer', 'agent', 'Writes and tests the ads, using only facts from your website.', 168, 300, NULL, 30,
'You are the Ad Writer desk. Job: every running ad group has 2 strong responsive search ads that are true and specific.
1. For each ad group: how many ads run, their ad strength and approval status. Disapproved and POOR ads come first.
2. Write only from research facts (each with its URL) and the brand facts: 10-15 different headlines (the keyword, the course, Dwarka / Delhi, one concrete benefit, a call to action), 4 descriptions, and the final URL of the page that matches the ad group.
3. Test one idea at a time. When 2 ads already run, replace the weaker one (lower click rate over at least 300 impressions each), never both.
4. No banned claims. Never invent numbers, years, rankings, approvals or guarantees.
Stay inside this job. Operations you may use: rsa_create, ad_status.'),
('extensions', 'Extensions', 'agent', 'Keeps sitelinks and callouts complete, true and pointing to real pages.', 336, 0, NULL, 40,
'You are the Extensions desk. Job: sitelinks and callouts are complete, true and point to real pages.
1. Aim for at least 4 sitelinks on the running campaign (each to a different real page, with both description lines) and 4 to 8 callouts.
2. Remove links to wrong or dead pages, and callouts whose claim the website does not state.
3. Do not repeat what the headlines already say.
Stay inside this job. Operations you may use: sitelink_add, callout_add, asset_unlink.'),
('bids_budget', 'Bids & Budget', 'agent', 'Sets the price paid per click and the daily budget, always inside your spend limits.', 72, 300, NULL, 50,
'You are the Bids & Budget desk. Job: the owner''s money buys as many real enquiries as possible, never above the owner''s limits (CONTEXT.autopilot daily_limit and monthly_limit).
1. Work out the cost per click and the cost per CRM enquiry (CONTEXT.ad_leads_30d) of each running campaign, and read by_hour_30d, by_weekday_30d and by_device_30d.
2. Maximize Clicks campaigns (bidding strategy TARGET_SPEND): set or move the max CPC cap (cpc_cap) when clicks cost far more than the top-of-page range in keyword_ideas, or when the campaign cannot spend its budget because the cap is too low. Move at most 25% in one step.
3. Daily budget (budget): raise only when Google says the campaign is limited by budget AND its cost per CRM enquiry is acceptable AND the limits leave room. Lower when 14 days of spend brought no enquiry. At most 30% in one step. The code refuses anything above the limits.
4. With under 100 clicks or under 3 enquiries in 30 days, prefer no change and say which data is still missing.
5. A change of bidding strategy is always a suggestion with a recommended option, never an operation.
Stay inside this job. Operations you may use: cpc_cap, budget.'),
('geo_time', 'Locations & Timing', 'agent', 'Checks where and when the ads show, and narrows them to where students are.', 168, 500, NULL, 60,
'You are the Locations & Timing desk. Job: the ads show where and when future students are.
1. Compare by_city_30d (where the clicks came from; "place" is the name) with locations (what the campaign targets). People far from Delhi NCR rarely join a classroom course in Dwarka: check the website facts for online or hostel options before judging.
2. Propose location changes (campaign_geo), one place per operation, and "presence only" targeting when "presence or interest" brings clicks from outside.
3. From by_hour_30d, by_weekday_30d and by_device_30d report hours, days or devices that take a large share of the spend and bring no enquiry. You cannot change the schedule yourself yet: put it in a suggestion.
Stay inside this job. Operations you may use: campaign_geo.'),
('quality', 'Landing Page & Quality Score', 'agent', 'Finds why Quality Scores are low, fixes what it can in Google Ads, and lists website fixes.', 336, 0, NULL, 70,
'You are the Landing Page & Quality Score desk. Job: find why Quality Scores are low and fix what can be fixed inside Google Ads.
1. For each keyword scoring under 6, name the weak part: expected click rate (the ad does not pull), ad relevance (the keyword is not in the ad, or sits in the wrong ad group) or landing page experience (the page does not match).
2. Fetch the landing pages. Does the page talk about the keyword''s topic, load, and show a form and a phone number? Is there a better existing page on the site for this ad group?
3. What you can fix: move a keyword to the right ad group (add it there, pause it here), and point a new ad at a better existing page.
4. Website problems cannot be fixed from here. List them exactly (page, what is missing) in ONE suggestion titled "Website fixes that would raise Quality Score".
Stay inside this job. Operations you may use: keyword_add, keyword_status, rsa_create, ad_status.'),
('tracking', 'Tracking', 'system', 'Checks every day that ad clicks turn into enquiries in the CRM, and that Google is told about them.', 24, 0, 'tracking', 80, NULL),
('lead_quality', 'Lead Quality', 'system', 'Tells Google which ad clicks became real enquiries and admissions, so Google looks for more people like them.', 1, 0, NULL, 85, NULL),
('reviewer', 'Compliance Reviewer', 'system', 'Checks every proposed change for truth, Google policy and waste. Nothing goes live without its approval.', 1, 0, 'reviewer', 90, NULL),
('supervisor', 'Spend Guard', 'system', 'Watches your daily and monthly limits every 15 minutes and pulls spending back if anything goes over.', 1, 0, 'supervisor', 92, NULL),
('allocator', 'Budget Allocator', 'system', 'Moves the daily budget toward campaigns that bring enquiries at your target cost.', 24, 0, 'allocator', 94, NULL),
('learner', 'Learner', 'system', 'Turns each week into lessons that every agent reads before it works.', 168, 0, 'learner', 96, NULL)
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.ads_conversion_uploads (
  id bigserial PRIMARY KEY,
  lead_id uuid NOT NULL REFERENCES public.ads_lead(id) ON DELETE CASCADE,
  event text NOT NULL CHECK (event IN ('enquiry', 'qualified', 'customer')),
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  happened_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  attempts int NOT NULL DEFAULT 0, last_try_at timestamptz, error text, sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lead_id, event));                       -- each event of a lead is reported once; the click id is never copied here
CREATE INDEX IF NOT EXISTS idx_ads_conv_status ON public.ads_conversion_uploads (status, last_try_at);
ALTER TABLE public.ads_conversion_uploads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_conversion_uploads FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_conversion_uploads_id_seq FROM anon, authenticated;

-- ------------------------------------------------------------------------------------------- bids and budget
-- The executor needs the budget's own resource name; the CRM knows it from the sync.
CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind,
      'payload', CASE WHEN o.kind = 'budget' THEN o.payload || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->>'campaign_id'))
        ELSE o.payload END,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes')) END
$$;

-- A verified budget change is the CRM's truth at once (the Spend Guard and the limits read it), not only after the next sync.
CREATE OR REPLACE FUNCTION crm_private.ads_google_op_applied() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.kind = 'budget' AND NEW.status = 'verified' AND OLD.status IS DISTINCT FROM 'verified' THEN
    UPDATE public.ads_campaigns SET daily_budget = (NEW.payload->>'daily_budget')::numeric
     WHERE account_id = NEW.account_id AND external_id = NEW.payload->>'campaign_id';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_ads_google_op_applied ON public.ads_google_ops;
CREATE TRIGGER trg_ads_google_op_applied AFTER UPDATE ON public.ads_google_ops
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_google_op_applied();

-- ------------------------------------------------------------------------------------------- the 24-hour rule
-- The options the agents recommend. NULL = the suggestion has no options (everything applies); '{}' = options, none recommended.
CREATE OR REPLACE FUNCTION crm_private.ads_suggestion_pick(p_proposal jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN jsonb_typeof(p_proposal->'options') = 'array' AND jsonb_array_length(p_proposal->'options') > 0
    THEN coalesce((SELECT array_agg(o->>'id') FROM jsonb_array_elements(p_proposal->'options') o
                    WHERE jsonb_typeof(o) = 'object' AND o->'selected' = 'true'::jsonb AND o->>'id' IS NOT NULL), '{}') END $$;

-- When an open suggestion will be applied by itself; NULL = never (it needs the owner).
CREATE OR REPLACE FUNCTION crm_private.ads_suggestion_auto_at(p_id bigint) RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_autopilot_suggestions; h text := btrim(coalesce(crm_private.ads_cfg('suggest_auto_hours'), '')); since timestamptz; pick text[];
BEGIN
  SELECT * INTO s FROM public.ads_autopilot_suggestions WHERE id = p_id;
  IF s.id IS NULL OR s.status <> 'open' OR h !~ '^\d{1,4}(\.\d+)?$' THEN RETURN NULL; END IF;
  IF h::numeric <= 0 THEN RETURN NULL; END IF;
  IF crm_private.ads_cfg('autopilot_google') IS DISTINCT FROM 'auto' THEN RETURN NULL; END IF;             -- "Ask me" mode: never by itself
  IF s.result ? 'auto_error' THEN RETURN NULL; END IF;                                                        -- it was tried and could not be applied
  -- only what the Reviewer approved (a proposal it rejected 3 times is shown for the owner to decide, and stays that way)
  IF NOT EXISTS (SELECT 1 FROM public.ads_agent_runs rv WHERE rv.parent_id = s.agent_run_id AND rv.role = 'reviewer' AND rv.status = 'done') THEN RETURN NULL; END IF;
  -- something to apply
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.proposal->'ops') = 'array' THEN s.proposal->'ops' ELSE '[]' END) o
                  WHERE jsonb_typeof(o) = 'object') THEN RETURN NULL; END IF;
  pick := crm_private.ads_suggestion_pick(s.proposal);
  IF pick IS NOT NULL AND cardinality(pick) = 0 THEN RETURN NULL; END IF;                                     -- the agents recommended nothing
  BEGIN since := nullif(crm_private.ads_cfg('suggest_auto_since'), '')::timestamptz; EXCEPTION WHEN others THEN since := NULL; END;
  RETURN greatest(s.created_at, coalesce(since, s.created_at)) + make_interval(secs => h::numeric * 3600);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_suggestions_auto() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_autopilot_suggestions; op jsonb; o public.ads_google_ops; pick text[]; res jsonb; acc uuid; done jsonb := '[]'; n int; blocked int;
BEGIN
  IF crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN jsonb_build_object('skipped', 'Emergency stop is on'); END IF;
  FOR s IN SELECT x.* FROM public.ads_autopilot_suggestions x WHERE x.status = 'open'
            AND crm_private.ads_suggestion_auto_at(x.id) <= now() ORDER BY x.created_at, x.id LIMIT 10 FOR UPDATE SKIP LOCKED LOOP
    acc := coalesce(s.account_id, (crm_private.ads_google_account()).id);
    pick := crm_private.ads_suggestion_pick(s.proposal);
    res := '[]'; n := 0; blocked := 0;
    BEGIN
      FOR op IN SELECT v FROM jsonb_array_elements(s.proposal->'ops') v LOOP
        IF jsonb_typeof(op) <> 'object' THEN CONTINUE; END IF;
        IF op ? 'option' AND pick IS NOT NULL AND NOT (op->>'option' = ANY (pick)) THEN CONTINUE; END IF;
        INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, created_by_type, agent_run_id)
        VALUES (acc, op->>'kind', coalesce(op->'payload', '{}'), left(coalesce(op->>'summary', s.title), 300), left(s.reason, 1000), 'agent', s.agent_run_id)
        RETURNING * INTO o;
        n := n + 1;
        IF o.status = 'blocked' THEN blocked := blocked + 1; END IF;
        res := res || jsonb_build_object('id', o.id, 'kind', o.kind, 'status', o.status, 'blockers', o.gate_result->'blockers');
      END LOOP;
      UPDATE public.ads_autopilot_suggestions SET status = 'accepted', decided_at = now(), decided_by = NULL,
        user_note = CASE WHEN n = 0 THEN 'No answer in time: the agents'' recommendation was to change nothing, so nothing was changed.'
                         ELSE 'No answer in time: the agents'' recommended option was applied.' END,
        result = jsonb_build_object('ops', res, 'auto', true) WHERE id = s.id;
      PERFORM crm_private.ads_agent_note('team_lead', 'auto_apply', format('No answer in %s hours on "%s": %s.', crm_private.ads_cfg('suggest_auto_hours'), left(s.title, 120),
        CASE WHEN n = 0 THEN 'the recommendation was to change nothing, so nothing was changed'
             ELSE format('applied the recommended option (%s change(s)%s)', n, CASE WHEN blocked > 0 THEN format(', %s stopped by the safety checks', blocked) ELSE '' END) END),
        jsonb_build_object('suggestion_id', s.id, 'ops', res));
      done := done || jsonb_build_object('id', s.id, 'ops', n, 'blocked', blocked);
    EXCEPTION WHEN others THEN
      -- e.g. an operation type that no longer exists: leave it for the owner and do not try again
      UPDATE public.ads_autopilot_suggestions SET result = jsonb_build_object('auto_error', left(SQLERRM, 300)) WHERE id = s.id;
      done := done || jsonb_build_object('id', s.id, 'error', left(SQLERRM, 300));
    END;
  END LOOP;
  RETURN jsonb_build_object('applied', done);
END $$;

-- ------------------------------------------------------------------------------------------- Team Lead
-- When a desk last started and how much has been spent since (new spend = something new to look at).
CREATE OR REPLACE FUNCTION crm_private.ads_desk_state()
RETURNS TABLE (key text, last_at timestamptz, spend_since numeric, due boolean, next_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT d.key, l.created_at,
         s.spend,
         d.enabled AND (l.created_at IS NULL OR l.created_at < now() - make_interval(hours => d.every_hours)) AND s.spend >= d.min_spend,
         CASE WHEN d.enabled THEN coalesce(l.created_at + make_interval(hours => d.every_hours), now()) END
    FROM public.ads_agent_desks d
    LEFT JOIN LATERAL (SELECT r.created_at FROM public.ads_agent_runs r WHERE r.job = 'desk_' || d.key AND r.parent_id IS NULL
                        ORDER BY r.created_at DESC LIMIT 1) l ON true
    CROSS JOIN LATERAL (SELECT coalesce(sum(m.spend), 0) AS spend FROM public.ads_metrics_daily m
                         JOIN public.ads_campaigns c ON c.id = m.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
                        WHERE a.platform = 'google' AND m.day >= coalesce((l.created_at AT TIME ZONE crm_private.ads_google_tz())::date,
                                                                          crm_private.ads_google_today() - 30)) s
   WHERE d.kind = 'agent'
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_agents_tick() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.ads_agent_instructions; acc uuid := (crm_private.ads_google_account()).id; started int := 0; freed int := 0;
        dk public.ads_agent_desks; auto jsonb; per_day int;
BEGIN
  IF acc IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  -- stuck steps (Mac asleep, crashed): back to the queue, or failed after 3 claims
  WITH s AS (UPDATE public.ads_agent_runs SET status = CASE WHEN claims >= 3 THEN 'failed' ELSE 'queued' END, claimed_at = NULL,
               error = CASE WHEN claims >= 3 THEN 'Stopped responding 3 times' ELSE error END,
               finished_at = CASE WHEN claims >= 3 THEN now() END
              WHERE status = 'running' AND claimed_at < now() - interval '30 minutes' RETURNING 1)
  SELECT count(*) INTO freed FROM s;
  -- new instructions from the owner: one chain each, oldest first (always before the desks)
  FOR i IN SELECT * FROM public.ads_agent_instructions ins WHERE ins.status = 'new'
             AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs r WHERE r.instruction_id = ins.id) ORDER BY ins.created_at LIMIT 5 LOOP
    INSERT INTO public.ads_agent_runs (account_id, role, job, instruction_id, input)
    VALUES (acc, 'researcher', 'instruction', i.id, jsonb_build_object('title', left(i.body, 120), 'goal', i.body));
    started := started + 1;
  END LOOP;
  -- suggestions the owner has not answered in time
  auto := public.svc_ads_suggestions_auto();
  -- Team Lead: one desk at a time, the most overdue first, only when it has something new to look at
  per_day := CASE WHEN crm_private.ads_cfg('agents_chains_per_day') ~ '^\d{1,2}$' THEN crm_private.ads_cfg('agents_chains_per_day')::int ELSE 3 END;
  IF crm_private.ads_cfg('agents_daily_review') = 'on' AND crm_private.ads_cfg('execution_paused') IS DISTINCT FROM 'true'
     AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE status IN ('queued', 'running'))
     AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'researcher' AND parent_id IS NULL AND instruction_id IS NULL
                       AND created_at > now() - interval '2 hours')
     AND (SELECT count(*) FROM public.ads_agent_runs WHERE role = 'researcher' AND parent_id IS NULL AND instruction_id IS NULL
            AND created_at > now() - interval '24 hours') < per_day THEN
    SELECT d.* INTO dk FROM public.ads_agent_desks d JOIN crm_private.ads_desk_state() st ON st.key = d.key
     WHERE st.due
     ORDER BY (st.last_at IS NULL) DESC, extract(epoch FROM now() - coalesce(st.last_at, now())) / (d.every_hours * 3600.0) DESC, d.sort LIMIT 1;
    IF FOUND THEN
      INSERT INTO public.ads_agent_runs (account_id, role, job, input)
      VALUES (acc, 'researcher', 'desk_' || dk.key, jsonb_build_object('title', dk.title, 'desk', dk.key, 'goal', dk.goal));
      started := started + 1;
    END IF;
  END IF;
  RETURN jsonb_build_object('started', started, 'freed', freed, 'auto', auto);
END $$;

-- The team as the CRM shows it: who does what, when each last worked and when it works next.
CREATE OR REPLACE FUNCTION crm_private.ads_team() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('key', d.key, 'title', d.title, 'kind', d.kind, 'does', d.does, 'enabled', d.enabled,
      'every_hours', d.every_hours,
      'last', CASE WHEN d.key = 'lead_quality'
        THEN (SELECT jsonb_build_object('at', max(u.sent_at), 'status', 'done', 'summary', format('%s enquiry event(s) reported to Google so far', count(*)))
                FROM public.ads_conversion_uploads u WHERE u.status = 'sent' HAVING count(*) > 0)
        ELSE (SELECT jsonb_build_object('at', coalesce(r.finished_at, r.created_at), 'status', r.status, 'summary', left(r.summary, 200))
                FROM public.ads_agent_runs r
               WHERE CASE WHEN d.kind = 'agent' THEN r.job = 'desk_' || d.key ELSE r.role = d.run_role END
               ORDER BY r.id DESC LIMIT 1) END,
      'next_at', st.next_at,
      'waiting_for_spend', CASE WHEN d.kind = 'agent' AND st.spend_since < d.min_spend THEN round(d.min_spend - st.spend_since, 2) END)
    ORDER BY d.sort), '[]')
    FROM public.ads_agent_desks d LEFT JOIN crm_private.ads_desk_state() st ON st.key = d.key
$$;

-- ------------------------------------------------------------------------------------------- Lead Quality: tell Google
-- Queues what is ready to report and returns how many reports are due now.
-- Reported: a valid Google ad enquiry with a click id, whose person allowed ad data sharing (latest answer wins), not older than
-- Google's 90-day window, and at least 30 minutes old (spam checks first). Qualified and admission follow when the lead gets there.
CREATE OR REPLACE FUNCTION crm_private.ads_conversions_queue() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF crm_private.ads_cfg('google_conv_upload') IS DISTINCT FROM 'on' THEN RETURN 0; END IF;
  INSERT INTO public.ads_conversion_uploads (lead_id, event, account_id, happened_at)
  SELECT x.lead_id, ev.event, x.account_id, greatest(coalesce(ev.at, now()), x.created_at)
    FROM crm_private.ads_ad_leads() x
    JOIN public.ads_lead l ON l.id = x.lead_id
    CROSS JOIN LATERAL (VALUES
      ('enquiry', x.created_at, true),
      ('qualified', (SELECT min(se.at) FROM public.ads_lead_stage_event se JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = se.to_stage
                      WHERE se.lead_id = l.id AND sd.ord >= 40 AND se.to_stage <> 'lost'), x.qualified),
      ('customer', (SELECT min(se.at) FROM public.ads_lead_stage_event se JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = se.to_stage
                     WHERE se.lead_id = l.id AND sd.is_customer), x.customer)) ev(event, at, ok)
   WHERE x.platform = 'google' AND x.valid AND ev.ok
     AND x.touch ?| ARRAY['gclid', 'gbraid', 'wbraid']
     AND x.created_at > now() - interval '85 days' AND x.created_at < now() - interval '30 minutes'
     AND (SELECT ce.status FROM public.ads_consent_event ce WHERE ce.purpose = 'ad_data_sharing' AND ce.subject_phone = l.phone_e164
           ORDER BY ce.at DESC, ce.id DESC LIMIT 1) = 'granted'
  ON CONFLICT (lead_id, event) DO NOTHING;
  RETURN (SELECT count(*) FROM public.ads_conversion_uploads u WHERE u.status = 'pending'
            AND (u.last_try_at IS NULL OR u.last_try_at < now() - interval '3 hours'));
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_conversion_defs() RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT '[{"event": "enquiry", "name": "CRM - Enquiry", "category": "SUBMIT_LEAD_FORM", "primary": true},
           {"event": "qualified", "name": "CRM - Qualified lead", "category": "QUALIFIED_LEAD", "primary": false},
           {"event": "customer", "name": "CRM - Admission", "category": "CONVERTED_LEAD", "primary": false}]'::jsonb $$;

CREATE OR REPLACE FUNCTION crm_private.ads_conversion_actions() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE j jsonb;
BEGIN
  BEGIN j := nullif(crm_private.ads_cfg('google_conv_actions'), '')::jsonb; EXCEPTION WHEN others THEN j := NULL; END;
  RETURN CASE WHEN jsonb_typeof(j) = 'object' THEN j ELSE '{}'::jsonb END;
END $$;

-- True when the reporter has something to do (the scheduler only wakes the Edge Function then).
CREATE OR REPLACE FUNCTION crm_private.ads_conversions_wake() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF crm_private.ads_cfg('google_conv_upload') IS DISTINCT FROM 'on' OR crm_private.ads_cfg('execution_paused') = 'true'
     OR (crm_private.ads_google_account()).id IS NULL THEN RETURN false; END IF;
  RETURN crm_private.ads_conversions_queue() > 0
      OR EXISTS (SELECT 1 FROM jsonb_array_elements(crm_private.ads_conversion_defs()) d WHERE NOT crm_private.ads_conversion_actions() ? (d->>'event'));
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_conversions_work() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts := crm_private.ads_google_account(); acts jsonb := crm_private.ads_conversion_actions();
BEGIN
  IF a.id IS NULL OR crm_private.ads_cfg('google_conv_upload') IS DISTINCT FROM 'on' OR crm_private.ads_cfg('execution_paused') = 'true' THEN
    RETURN jsonb_build_object('account', NULL, 'actions', acts, 'missing', '[]'::jsonb, 'items', '[]'::jsonb);
  END IF;
  PERFORM crm_private.ads_conversions_queue();
  RETURN jsonb_build_object(
    'account', jsonb_build_object('external_id', a.external_id, 'login_customer_id', a.login_customer_id),
    'actions', acts,
    'missing', (SELECT coalesce(jsonb_agg(d), '[]') FROM jsonb_array_elements(crm_private.ads_conversion_defs()) d WHERE NOT acts ? (d->>'event')),
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'event', u.event, 'order_id', u.lead_id::text || ':' || u.event,
        'at', to_char(u.happened_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00:00',
        'gclid', x.touch->>'gclid', 'gbraid', x.touch->>'gbraid', 'wbraid', x.touch->>'wbraid') ORDER BY u.id), '[]')
      FROM (SELECT * FROM public.ads_conversion_uploads w WHERE w.status = 'pending' AND w.account_id = a.id
              AND (w.last_try_at IS NULL OR w.last_try_at < now() - interval '3 hours') ORDER BY w.id LIMIT 50) u
      JOIN crm_private.ads_ad_leads() x ON x.lead_id = u.lead_id));   -- a lead deleted or quarantined since is no longer sent
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_conversion_action_save(p_event text, p_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_id !~ '^\d{3,20}$' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(crm_private.ads_conversion_defs()) d WHERE d->>'event' = p_event) THEN RETURN; END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('google_conv_actions', jsonb_build_object(p_event, p_id)::text)
  ON CONFLICT (key) DO UPDATE SET value = (crm_private.ads_conversion_actions() || jsonb_build_object(p_event, p_id))::text;
END $$;

-- sent = Google has it; retry = try again in 3 hours (12 tries at most); failed = final.
CREATE OR REPLACE FUNCTION public.svc_ads_conversion_finish(p_id bigint, p_status text, p_error text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_conversion_uploads SET
    attempts = attempts + 1, last_try_at = now(),
    status = CASE WHEN p_status = 'sent' THEN 'sent' WHEN p_status = 'retry' AND attempts + 1 < 12 THEN 'pending' ELSE 'failed' END,
    sent_at = CASE WHEN p_status = 'sent' THEN now() END,
    error = CASE WHEN p_status = 'sent' THEN NULL ELSE left(coalesce(p_error, 'not accepted'), 400) END
   WHERE id = p_id AND status = 'pending'
$$;

-- ------------------------------------------------------------------------------------------- Tracking
CREATE OR REPLACE FUNCTION public.svc_ads_tracking_check() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d date := crm_private.ads_google_today(); tz text := crm_private.ads_google_tz(); clicks numeric; leads int; nocamp int; failed int; why text;
        told int; denied int; problems text[] := '{}'; out jsonb;
BEGIN
  IF (crm_private.ads_google_account()).id IS NULL THEN RETURN jsonb_build_object('skipped', 'no Google account'); END IF;
  SELECT coalesce(sum(m.clicks), 0) INTO clicks FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
    JOIN public.ads_accounts a ON a.id = c.account_id WHERE a.platform = 'google' AND m.day BETWEEN d - 7 AND d - 1;
  SELECT count(*), count(*) FILTER (WHERE x.campaign_id IS NULL) INTO leads, nocamp FROM crm_private.ads_ad_leads() x
   WHERE x.platform = 'google' AND (x.created_at AT TIME ZONE tz)::date BETWEEN d - 7 AND d - 1;
  SELECT count(*), max(u.error) INTO failed, why FROM public.ads_conversion_uploads u WHERE u.status = 'failed' AND u.last_try_at > now() - interval '7 days';
  SELECT count(*) INTO told FROM public.ads_conversion_uploads u WHERE u.status = 'sent' AND u.sent_at > now() - interval '7 days';
  SELECT count(*) INTO denied FROM crm_private.ads_ad_leads() x JOIN public.ads_lead l ON l.id = x.lead_id
   WHERE x.platform = 'google' AND (x.created_at AT TIME ZONE tz)::date BETWEEN d - 7 AND d - 1
     AND (SELECT ce.status FROM public.ads_consent_event ce WHERE ce.purpose = 'ad_data_sharing' AND ce.subject_phone = l.phone_e164
           ORDER BY ce.at DESC, ce.id DESC LIMIT 1) IS DISTINCT FROM 'granted';
  IF clicks >= 150 AND leads = 0 THEN
    problems := problems || format('%s ad clicks in the last 7 days and not one enquiry reached the CRM. Check that the website form still works.', clicks);
  END IF;
  IF failed > 0 THEN problems := problems || format('%s enquiry report(s) to Google were not accepted (last reason: %s).', failed, left(why, 160)); END IF;
  IF nocamp > 0 THEN problems := problems || format('%s ad enquiry(ies) carried no campaign id, so they count for the account but not for a campaign.', nocamp); END IF;
  out := jsonb_build_object('clicks_7d', clicks, 'enquiries_7d', leads, 'reported_to_google_7d', told, 'not_shared_7d', denied,
    'failed_7d', failed, 'no_campaign_7d', nocamp, 'problems', to_jsonb(problems));
  IF cardinality(problems) > 0 AND NOT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE role = 'tracking' AND created_at > now() - interval '20 hours') THEN
    PERFORM crm_private.ads_agent_note('tracking', 'daily', 'Tracking: ' || array_to_string(problems, ' '), out);
  END IF;
  RETURN out;
END $$;

-- ------------------------------------------------------------------------------------------- existing functions, extended
-- Gate (092 definition + cpc_cap and budget).
CREATE OR REPLACE FUNCTION crm_private.ads_google_gate(p_account uuid, p_kind text, p_payload jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; b jsonb := '[]'; w jsonb := '[]'; e text; x jsonb; s text; n int; i int; r jsonb;
        hs text[]; ds text[]; gc public.ads_campaigns; gnb numeric; gtot numeric; gmtd numeric; gcap numeric; gold numeric;
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
    IF EXISTS (SELECT 1 FROM jsonb_each_text(crm_private.ads_conversion_actions()) ca WHERE ca.value = p_payload->>'conversion_action_id') THEN
      b := b || to_jsonb('This conversion action is fed by the CRM itself; agents do not change it.'::text);
    END IF;

  ELSIF p_kind = 'cpc_cap' THEN        -- the most one click may cost on a Maximize Clicks campaign
    SELECT * INTO gc FROM public.ads_campaigns WHERE account_id = a.id AND external_id = p_payload->>'campaign_id' AND coalesce(status, '') <> 'REMOVED';
    BEGIN gnb := (p_payload->>'max_cpc')::numeric; EXCEPTION WHEN others THEN gnb := NULL; END;
    SELECT v INTO x FROM public.ads_google_snapshot sn, jsonb_array_elements(CASE WHEN jsonb_typeof(sn.data) = 'array' THEN sn.data ELSE '[]' END) v
     WHERE sn.account_id = a.id AND sn.kind = 'campaigns' AND v->>'campaign.id' = gc.external_id LIMIT 1;
    IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' OR gc.id IS NULL THEN
      b := b || to_jsonb('campaign_id of a campaign in this account is required.'::text);
    ELSIF x->>'campaign.biddingStrategyType' IS DISTINCT FROM 'TARGET_SPEND' THEN
      b := b || to_jsonb('A max CPC cap only applies to a Maximize Clicks campaign.'::text);
    END IF;
    IF gnb IS NULL OR gnb = 'NaN'::numeric OR gnb <> round(gnb, 2)
       OR gnb < coalesce((crm_private.ads_rule('g_cpc_cap_min')->>'min')::numeric, 1)
       OR gnb > coalesce((crm_private.ads_rule('g_cpc_max')->>'max')::numeric, 150) THEN
      b := b || to_jsonb(format('max_cpc must be a number from %s to %s (at most 2 decimals).',
        coalesce(crm_private.ads_rule('g_cpc_cap_min')->>'min', '1'), coalesce(crm_private.ads_rule('g_cpc_max')->>'max', '150')));
    ELSIF gc.id IS NOT NULL THEN
      gold := nullif(x->>'campaign.targetSpend.cpcBidCeilingMicros', '')::numeric / 1000000;
      r := crm_private.ads_rule('g_cpc_cap_step');
      IF r IS NOT NULL AND gold > 0 AND abs(gnb - gold) * 100 / gold > (r->>'pct')::numeric THEN
        b := b || to_jsonb(format('The max CPC is %s now; %s is a %s%% change, more than the %s%% allowed in one step.', gold, gnb, round(abs(gnb - gold) * 100 / gold), r->>'pct'));
      END IF;
      IF EXISTS (SELECT 1 FROM public.ads_google_ops o WHERE o.account_id = p_account AND o.kind = 'cpc_cap' AND o.id IS DISTINCT FROM p_exclude
                   AND o.payload->>'campaign_id' = gc.external_id AND o.status IN ('approved', 'executing', 'verified', 'outcome_unknown')
                   AND o.created_at > now() - interval '24 hours') THEN
        b := b || to_jsonb('The max CPC of this campaign was already changed in the last 24 hours.'::text);
      END IF;
    END IF;

  ELSIF p_kind = 'budget' THEN         -- daily budget; the owner's limits always win
    SELECT * INTO gc FROM public.ads_campaigns WHERE account_id = a.id AND external_id = p_payload->>'campaign_id' AND coalesce(status, '') <> 'REMOVED';
    BEGIN gnb := (p_payload->>'daily_budget')::numeric; EXCEPTION WHEN others THEN gnb := NULL; END;
    IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' OR gc.id IS NULL THEN
      b := b || to_jsonb('campaign_id of a campaign in this account is required.'::text);
    ELSIF gc.budget_ref IS NULL OR coalesce(gc.daily_budget, 0) <= 0 THEN
      b := b || to_jsonb('The current daily budget of this campaign is unknown (shared or not synced); it cannot be changed from here.'::text);
    ELSIF gnb IS NULL OR gnb = 'NaN'::numeric OR gnb <> round(gnb, 2) OR gnb > 100000000
          OR gnb < coalesce((crm_private.ads_rule('budget_min')->>'min')::numeric, 1) THEN
      b := b || to_jsonb(format('daily_budget must be a number of at least %s (at most 2 decimals).', coalesce(crm_private.ads_rule('budget_min')->>'min', '1')));
    ELSIF gnb = gc.daily_budget THEN
      b := b || to_jsonb(format('The daily budget is already %s.', gnb));
    ELSE
      r := crm_private.ads_rule('g_budget_step');
      IF r IS NOT NULL AND abs(gnb - gc.daily_budget) * 100 / gc.daily_budget > (r->>'pct')::numeric THEN
        b := b || to_jsonb(format('The daily budget is %s now; %s is a %s%% change, more than the %s%% allowed in one step.',
          gc.daily_budget, gnb, round(abs(gnb - gc.daily_budget) * 100 / gc.daily_budget), r->>'pct'));
      END IF;
      IF EXISTS (SELECT 1 FROM public.ads_google_ops o WHERE o.account_id = p_account AND o.kind = 'budget' AND o.id IS DISTINCT FROM p_exclude
                   AND o.payload->>'campaign_id' = gc.external_id AND o.status IN ('approved', 'executing', 'verified', 'outcome_unknown')
                   AND o.created_at > now() - interval '24 hours')
         OR EXISTS (SELECT 1 FROM public.ads_change_queue q WHERE q.campaign_id = gc.id AND q.kind = 'budget'
                   AND q.status IN ('approved', 'executing', 'verified', 'outcome_unknown') AND q.created_at > now() - interval '24 hours') THEN
        b := b || to_jsonb('The budget of this campaign was already changed in the last 24 hours.'::text);
      END IF;
      IF gnb > gc.daily_budget AND gc.status = 'ENABLED' THEN     -- a raise: the owner's daily and monthly limits (same sums as the Autopilot tab)
        SELECT coalesce(sum(c2.daily_budget), 0) + gnb INTO gtot FROM public.ads_campaigns c2 JOIN public.ads_accounts a2 ON a2.id = c2.account_id
         WHERE a2.platform = 'google' AND c2.status = 'ENABLED' AND c2.id <> gc.id;
        gcap := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
        IF gcap IS NOT NULL AND gtot > gcap THEN
          b := b || to_jsonb(format('All running Google campaigns would spend up to %s a day, above the daily limit of %s.', gtot, gcap));
        END IF;
        gcap := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
        IF gcap IS NOT NULL THEN
          gmtd := crm_private.ads_google_month_spend();
          IF gmtd >= gcap OR gmtd + gtot * crm_private.ads_google_days_left() > gcap THEN
            b := b || to_jsonb(format('At up to %s a day this month''s Google spend could reach %s, above the monthly limit of %s.',
              gtot, round(gmtd + gtot * crm_private.ads_google_days_left()), gcap));
          END IF;
        END IF;
        SELECT cl.max_daily_budget INTO gcap FROM public.ads_clients cl WHERE cl.id = a.client_id;
        IF gcap IS NOT NULL AND gnb > gcap THEN b := b || to_jsonb(format('%s is above the client''s max daily budget of %s.', gnb, gcap)); END IF;
      END IF;
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

-- Agent output check (095 definition; location options are marked as recommended).
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
      'options', (SELECT jsonb_agg(jsonb_build_object('id', 'g' || n, 'label', coalesce(v->>'summary', 'Location change'), 'reason', v->>'reason', 'selected', true))
                    FROM jsonb_array_elements(geo) WITH ORDINALITY t(v, n))));
  END IF;
  RETURN jsonb_build_object('ops', ops, 'suggestions', sugg, 'problems', problems,
    'left_for_next_run', greatest(0, jsonb_array_length(CASE WHEN jsonb_typeof(p_out->'ops') = 'array' THEN p_out->'ops' ELSE '[]' END) - 25));
END $$;

-- Autopilot tab (093 definition; each suggestion says when it will be applied by itself).
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
    'suggestions', (SELECT coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('auto_at', crm_private.ads_suggestion_auto_at(s.id)) ORDER BY (s.status = 'open') DESC, s.created_at DESC), '[]') FROM (
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

-- Status (096 definition + the team).
CREATE OR REPLACE FUNCTION public.api_ads_autopilot_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz := nullif(crm_private.ads_cfg('agents_last_seen'), '')::timestamptz; busy public.ads_agent_runs;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO busy FROM public.ads_agent_runs WHERE status = 'running' AND claimed_at > now() - interval '30 minutes' ORDER BY claimed_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'agents', jsonb_build_object('last_seen', seen,
      'online', busy.id IS NOT NULL OR (seen IS NOT NULL AND seen > now() - interval '3 minutes'),
      -- the hourly cloud runner is not connected all the time: healthy = it checked in within 90 minutes
      'healthy', busy.id IS NOT NULL OR (seen IS NOT NULL AND seen > now() - interval '90 minutes'),
      'working_on', CASE WHEN busy.id IS NOT NULL THEN jsonb_build_object('role', busy.role, 'job', busy.job, 'since', busy.claimed_at) END,
      'queued', (SELECT count(*) FROM public.ads_agent_runs WHERE status = 'queued')),
    'report', (SELECT jsonb_build_object('text', summary, 'data', output, 'at', created_at) FROM public.ads_agent_runs
                WHERE role = 'supervisor' AND job = 'daily_report' ORDER BY created_at DESC LIMIT 1),
    'playbook', (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', lesson, 'evidence', evidence) ORDER BY id), '[]') FROM public.ads_playbook WHERE active),
    'team', crm_private.ads_team());
END $$;

-- ------------------------------------------------------------------------------------------- permissions and schedule
REVOKE ALL ON FUNCTION public.svc_ads_suggestions_auto(), public.svc_ads_conversions_work(), public.svc_ads_conversion_action_save(text, text),
  public.svc_ads_conversion_finish(bigint, text, text), public.svc_ads_tracking_check(), public.svc_ads_agents_tick(),
  public.svc_ads_google_op_work() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_suggestions_auto(), public.svc_ads_conversions_work(), public.svc_ads_conversion_action_save(text, text),
  public.svc_ads_conversion_finish(bigint, text, text), public.svc_ads_tracking_check(), public.svc_ads_agents_tick(),
  public.svc_ads_google_op_work() TO service_role;
REVOKE ALL ON FUNCTION crm_private.ads_google_op_applied(), crm_private.ads_suggestion_pick(jsonb), crm_private.ads_suggestion_auto_at(bigint),
  crm_private.ads_desk_state(), crm_private.ads_team(), crm_private.ads_conversions_queue(), crm_private.ads_conversion_defs(),
  crm_private.ads_conversion_actions(), crm_private.ads_conversions_wake() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-ads-convert', 'crm-ads-tracking');
    PERFORM cron.schedule('crm-ads-tracking', '25 3 * * *', 'SELECT public.svc_ads_tracking_check()');     -- 08:55 IST, before the daily report
    PERFORM cron.schedule('crm-ads-convert', '11,41 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["convert"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE crm_private.ads_conversions_wake()
    $job$);
  END IF;
END $$;
