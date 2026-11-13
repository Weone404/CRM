-- 092: ADS only, Google Ads only. Structured Google Ads operations (keywords, negatives, ads, ad groups, locations,
-- shared negative lists, callouts, sitelinks, conversion goals) with a deterministic quality gate, plus account
-- snapshots the ADS agents read. Separate from the budget/status queue (ads_change_queue) and from Amazon and Meta.
--
--   ads_google_ops       one row per operation. pending -> approved -> executing -> verified | failed | outcome_unknown
--                        (or blocked / rejected / stale). Agent ops are approved automatically only when the gate passes
--                        and Autopilot is 'auto'; user ops wait for an approver.
--   ads_google_snapshot  latest read of the account's structure by kind (ad groups, keywords, ads, assets, ...).
--   crm_private.ads_google_gate(account, kind, payload)  -> {blockers, warnings}; runs on every insert/update.
--
-- Google's own policy check runs again at execution time (validateOnly) before anything is sent for real.
-- Re-runnable. Rollback: 092_ads_google_ops_down.sql.

CREATE TABLE IF NOT EXISTS public.ads_google_ops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status',
    'ad_group_create', 'campaign_geo', 'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal')),
  payload jsonb NOT NULL DEFAULT '{}',
  summary text NOT NULL DEFAULT '',
  reason text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'blocked', 'approved', 'executing', 'verified',
    'failed', 'outcome_unknown', 'rejected', 'stale')),
  gate_result jsonb NOT NULL DEFAULT '{}',
  created_by_type text NOT NULL DEFAULT 'user' CHECK (created_by_type IN ('user', 'agent', 'system')),
  created_by uuid, agent_run_id bigint,
  approved_by uuid, approved_at timestamptz, executed_at timestamptz,
  result jsonb, verify_result jsonb, error text, reject_reason text,
  idempotency_key uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_gops_status ON public.ads_google_ops (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ads_gops_account ON public.ads_google_ops (account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ads_google_snapshot (
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  kind text NOT NULL,
  data jsonb NOT NULL DEFAULT '[]',
  synced_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, kind));

ALTER TABLE public.ads_google_ops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_google_snapshot ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_google_ops, public.ads_google_snapshot FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES
  ('autopilot_google', 'off'),                       -- off | auto  (agent ops auto-approved only when 'auto' and the gate passes)
  ('google_allowed_domains', 'weoneaviation.in')     -- comma list; ad / sitelink URLs must be on these hosts
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_rules (code, label, severity, value) VALUES
  ('g_claim_phrases', 'Ad text may not contain these claims (Google unreliable-claims policy; unprovable)', 'blocker',
   '{"phrases": ["guarantee", "guaranteed", "100%", "#1", "no.1", "no. 1", "number one", "best", "success rate", "job placement",
     "placement assured", "assured job", "1st attempt", "first attempt", "partner airlines", "lowest fee", "cheapest", "free pilot"]}'),
  ('g_protected_terms', 'Negative keywords may not block these core searches', 'blocker',
   '{"terms": ["pilot training", "commercial pilot", "cpl", "dgca ground classes", "ground classes", "pilot course", "pilot academy", "flying school"]}'),
  ('g_no_broad', 'New keywords must be phrase or exact match (broad match wastes a small budget)', 'blocker', '{}'),
  ('g_ops_per_day', 'Google operations per account per day', 'blocker', '{"max": 40}'),
  ('g_cpc_max', 'Max CPC bid for a new ad group (account currency)', 'blocker', '{"max": 150}'),
  ('g_geo_ids_max', 'Locations added in one operation', 'blocker', '{"max": 25}')
ON CONFLICT (code) DO NOTHING;

-- -------------------------------------------------------------------------------------------
-- Gate helpers
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crm_private.ads_g_url_ok(p_url text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_url ~* '^https://' AND EXISTS (
    SELECT 1 FROM unnest(string_to_array(coalesce(crm_private.ads_cfg('google_allowed_domains'), ''), ',')) d
     WHERE length(trim(d)) > 0 AND (
       lower(split_part(split_part(regexp_replace(p_url, '^https://', '', 'i'), '/', 1), '?', 1)) = lower(trim(d)) OR
       lower(split_part(split_part(regexp_replace(p_url, '^https://', '', 'i'), '/', 1), '?', 1)) LIKE '%.' || lower(trim(d))))
$$;

-- First banned claim found in a text, or NULL.
CREATE OR REPLACE FUNCTION crm_private.ads_g_claim(p_text text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p FROM jsonb_array_elements_text(coalesce(crm_private.ads_rule('g_claim_phrases')->'phrases', '[]')) p
   WHERE position(lower(p) IN lower(coalesce(p_text, ''))) > 0
     AND (p !~ '^[a-z]' OR lower(coalesce(p_text, '')) ~ ('(^|[^a-z])' || regexp_replace(lower(p), '([.#])', '\\\1', 'g') || '([^a-z]|$)'))
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_g_kw_err(p_kw jsonb, p_negative boolean) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := trim(coalesce(p_kw->>'text', '')); m text := upper(coalesce(p_kw->>'match', ''));
BEGIN
  IF t = '' OR length(t) > 80 THEN RETURN format('Keyword "%s" must be 1-80 characters.', left(t, 90)); END IF;
  IF array_length(regexp_split_to_array(t, '\s+'), 1) > 10 THEN RETURN format('Keyword "%s" has more than 10 words.', t); END IF;
  IF t ~ '[!@%^*=;<>{}\[\]\\|~`]' THEN RETURN format('Keyword "%s" has characters Google does not allow.', t); END IF;
  IF m NOT IN ('BROAD', 'PHRASE', 'EXACT') THEN RETURN format('Keyword "%s": match must be BROAD, PHRASE or EXACT.', t); END IF;
  IF NOT p_negative AND m = 'BROAD' AND crm_private.ads_rule('g_no_broad') IS NOT NULL THEN
    RETURN format('Keyword "%s" is broad match; use phrase or exact.', t);
  END IF;
  RETURN NULL;
END $$;

-- -------------------------------------------------------------------------------------------
-- The quality gate (deterministic). Blockers stop the operation; warnings are shown.
-- -------------------------------------------------------------------------------------------
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

CREATE OR REPLACE FUNCTION crm_private.ads_google_ops_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' OR (NEW.status IN ('pending', 'blocked', 'approved') AND
      (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.status IS DISTINCT FROM OLD.status)) THEN
    NEW.gate_result := crm_private.ads_google_gate(NEW.account_id, NEW.kind, NEW.payload, NEW.id);
    IF jsonb_array_length(NEW.gate_result->'blockers') > 0 AND NEW.status IN ('pending', 'approved') THEN
      NEW.status := 'blocked';
    ELSIF TG_OP = 'INSERT' AND NEW.created_by_type = 'agent' AND NEW.status = 'pending'
          AND crm_private.ads_cfg('autopilot_google') = 'auto' THEN
      NEW.status := 'approved'; NEW.approved_at := now();
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_google_ops_guard ON public.ads_google_ops;
CREATE TRIGGER trg_ads_google_ops_guard BEFORE INSERT OR UPDATE ON public.ads_google_ops
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_google_ops_guard();

-- -------------------------------------------------------------------------------------------
-- Browser API (ADS access checks)
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_ads_google_ops(p_status text DEFAULT NULL, p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(o) - 'idempotency_key' ORDER BY o.created_at DESC), '[]') FROM (
    SELECT * FROM public.ads_google_ops WHERE p_status IS NULL OR status = p_status
     ORDER BY created_at DESC LIMIT greatest(1, least(coalesce(p_limit, 100), 500))) o);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_google_op_check(p_account uuid, p_kind text, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_google_gate(p_account, p_kind, p_payload);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_google_op_create(p_account uuid, p_kind text, p_payload jsonb, p_summary text DEFAULT '',
  p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.ads_google_ops;
BEGIN
  PERFORM crm_private.ads_require_view();
  INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, reason, created_by_type, created_by)
  VALUES (p_account, p_kind, coalesce(p_payload, '{}'), left(coalesce(p_summary, ''), 300), left(p_reason, 1000), 'user',
          crm_private.current_employee_id()) RETURNING * INTO o;
  PERFORM crm_private.ads_log('google_op_drafted', 'google_op', o.id::text, jsonb_build_object('kind', p_kind, 'status', o.status));
  RETURN jsonb_build_object('id', o.id, 'status', o.status, 'gate_result', o.gate_result);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_google_op_decide(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.ads_google_ops;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'You cannot approve changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO o FROM public.ads_google_ops WHERE id = p_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Operation not found' USING ERRCODE = 'PT404'; END IF;
  IF o.status NOT IN ('pending', 'blocked') OR (p_approve AND o.status = 'blocked') THEN
    RAISE EXCEPTION 'This operation is %', o.status USING ERRCODE = 'PT409';
  END IF;
  UPDATE public.ads_google_ops SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    approved_by = CASE WHEN p_approve THEN crm_private.current_employee_id() END,
    approved_at = CASE WHEN p_approve THEN now() END, reject_reason = CASE WHEN NOT p_approve THEN left(p_reason, 500) END
   WHERE id = p_id RETURNING * INTO o;
  PERFORM crm_private.ads_log(CASE WHEN p_approve THEN 'google_op_approved' ELSE 'google_op_rejected' END, 'google_op', p_id::text,
    jsonb_build_object('reason', p_reason));
  RETURN jsonb_build_object('id', o.id, 'status', o.status);
END $$;

-- -------------------------------------------------------------------------------------------
-- Service side (ads-sync Edge Function only)
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.svc_ads_google_snapshot_save(p_account uuid, p_kind text, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_google_snapshot (account_id, kind, data, synced_at) VALUES (p_account, p_kind, coalesce(p_data, '[]'), now())
  ON CONFLICT (account_id, kind) DO UPDATE SET data = EXCLUDED.data, synced_at = now()
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', o.payload, 'account_external_id', a.external_id,
      'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes')) END
$$;

-- approved -> executing; re-runs the gate first (things may have changed since approval).
CREATE OR REPLACE FUNCTION public.svc_ads_google_op_claim(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.ads_google_ops; g jsonb;
BEGIN
  SELECT * INTO o FROM public.ads_google_ops WHERE id = p_id AND status = 'approved' FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL OR crm_private.ads_cfg('execution_paused') = 'true' THEN RETURN false; END IF;
  g := crm_private.ads_google_gate(o.account_id, o.kind, o.payload, o.id);
  IF jsonb_array_length(g->'blockers') > 0 THEN
    UPDATE public.ads_google_ops SET status = 'stale', gate_result = g, error = 'A check now blocks this operation.' WHERE id = p_id;
    RETURN false;
  END IF;
  UPDATE public.ads_google_ops SET status = 'executing', executed_at = now() WHERE id = p_id;
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_google_op_finish(p_id uuid, p_status text, p_error text, p_result jsonb, p_verify jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_status NOT IN ('verified', 'failed', 'outcome_unknown') THEN RAISE EXCEPTION 'bad status'; END IF;
  UPDATE public.ads_google_ops SET status = p_status, error = left(p_error, 900), result = p_result, verify_result = p_verify
   WHERE id = p_id AND status IN ('executing', 'outcome_unknown');
  IF FOUND THEN
    INSERT INTO public.ads_activity_log (actor_type, action, entity, entity_id, details)
    VALUES ('system', 'google_op_' || p_status, 'google_op', p_id::text, jsonb_build_object('error', left(p_error, 300)));
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.svc_ads_google_snapshot_save(uuid, text, jsonb), public.svc_ads_google_op_work(),
  public.svc_ads_google_op_claim(uuid), public.svc_ads_google_op_finish(uuid, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_snapshot_save(uuid, text, jsonb), public.svc_ads_google_op_work(),
  public.svc_ads_google_op_claim(uuid), public.svc_ads_google_op_finish(uuid, text, text, jsonb, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.api_ads_google_ops(text, int), public.api_ads_google_op_check(uuid, text, jsonb),
  public.api_ads_google_op_create(uuid, text, jsonb, text, text), public.api_ads_google_op_decide(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_google_ops(text, int), public.api_ads_google_op_check(uuid, text, jsonb),
  public.api_ads_google_op_create(uuid, text, jsonb, text, text), public.api_ads_google_op_decide(uuid, boolean, text) TO authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_g_url_ok(text), crm_private.ads_g_claim(text), crm_private.ads_g_kw_err(jsonb, boolean),
  crm_private.ads_google_gate(uuid, text, jsonb, uuid), crm_private.ads_google_ops_guard() FROM PUBLIC, anon, authenticated;
