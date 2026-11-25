-- 144 ADS > Google Ads: premium targeting (owner decision, 25 Nov 2026).
-- Goal: counselling enquiries from people searching for pilot training, CPL and ground classes, in premium areas only.
-- Two new Google operations, both for the owner only (an agent may propose them, never run them on its own):
--   campaign_create   a new Search campaign: its own daily budget (inside the owner's limits), Maximize Clicks with a click limit,
--                     Google Search only, "people physically there" and its first locations (PIN codes or cities).
--   income_filter     Google's household-income groups: shut some out of a campaign (or an ad group), or let them back in.
-- While google_targeting_locked is "on", location changes made by an agent also wait for the owner.
-- The big gate is not copied: it is renamed to ads_google_gate_v143 and the new gate calls it for everything it already knew.
-- IMPORTANT for later migrations: do not CREATE OR REPLACE crm_private.ads_google_gate with a full body again; change
-- ads_google_gate_v143 (old kinds) or the wrapper below (new kinds).
-- The new kinds are run by their own small Edge Function (ads-google-ops), so the large ads-sync function is not redeployed:
-- svc_ads_google_op_work() no longer hands them out, svc_ads_google_build_work() does.
-- Run it twice safely. Rollback: 144_ads_google_premium_down.sql (refuses while operations of the new kinds exist).

-- ---------------------------------------------------------------- kinds, rules, settings
ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget',
    'campaign_create', 'income_filter'));

INSERT INTO public.ads_rules (code, label, severity, value) VALUES
  ('g_campaigns_per_day', 'New Google campaigns per day', 'blocker', '{"max": 1}')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.ads_config (key, value) VALUES ('google_targeting_locked', 'on') ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- gate
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_google_gate_v143(uuid,text,jsonb,uuid)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) RENAME TO ads_google_gate_v143;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_gate(p_account uuid, p_kind text, p_payload jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE g jsonb := crm_private.ads_google_gate_v143(p_account, p_kind, p_payload, p_exclude);
        a public.ads_accounts; b jsonb; w jsonb; r jsonb; v numeric; tot numeric; cap numeric; mtd numeric; n int; s text; lvl text;
        tiers CONSTANT text[] := ARRAY['INCOME_RANGE_0_50', 'INCOME_RANGE_50_60', 'INCOME_RANGE_60_70', 'INCOME_RANGE_70_80',
                                       'INCOME_RANGE_80_90', 'INCOME_RANGE_90_UP', 'INCOME_RANGE_UNDETERMINED'];
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('campaign_create', 'income_filter') THEN RETURN g; END IF;
  -- the old gate already checked the account, the emergency stop and the operations-per-day limit; only its "unknown type" line goes
  SELECT coalesce(jsonb_agg(x), '[]') INTO b FROM jsonb_array_elements(g->'blockers') x WHERE x #>> '{}' <> 'Unknown operation type.';
  w := coalesce(g->'warnings', '[]');
  SELECT * INTO a FROM public.ads_accounts WHERE id = p_account;
  IF a.id IS NULL OR a.platform <> 'google' OR jsonb_typeof(p_payload) <> 'object' THEN RETURN jsonb_build_object('blockers', b, 'warnings', w); END IF;

  IF p_kind = 'campaign_create' THEN
    s := trim(coalesce(p_payload->>'name', ''));
    IF length(s) NOT BETWEEN 3 AND 120 OR s ~ '[<>\n\r]' THEN
      b := b || to_jsonb('Campaign name must be 3-120 characters.'::text);
    ELSIF EXISTS (SELECT 1 FROM public.ads_campaigns c WHERE c.account_id = a.id AND lower(c.name) = lower(s) AND coalesce(c.status, '') <> 'REMOVED') THEN
      b := b || to_jsonb(format('A campaign named "%s" already exists.', s));
    END IF;
    IF p_payload ? 'status' AND upper(coalesce(p_payload->>'status', '')) NOT IN ('ENABLED', 'PAUSED') THEN
      b := b || to_jsonb('status must be ENABLED or PAUSED.'::text);
    END IF;
    -- click limit: same floor and ceiling as the rest of ADS
    BEGIN v := (p_payload->>'max_cpc')::numeric; EXCEPTION WHEN others THEN v := NULL; END;
    IF v IS NULL OR v = 'NaN'::numeric OR v <> round(v, 2)
       OR v < coalesce((crm_private.ads_rule('g_cpc_cap_min')->>'min')::numeric, 1)
       OR v > coalesce((crm_private.ads_rule('g_cpc_max')->>'max')::numeric, 150) THEN
      b := b || to_jsonb(format('max_cpc must be between %s and %s (at most 2 decimals).',
        coalesce(crm_private.ads_rule('g_cpc_cap_min')->>'min', '1'), coalesce(crm_private.ads_rule('g_cpc_max')->>'max', '150')));
    END IF;
    -- locations: a campaign with no location shows everywhere, so at least one is required
    r := crm_private.ads_rule('g_geo_ids_max');
    IF jsonb_typeof(p_payload->'locations') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'locations') = 0 THEN
      b := b || to_jsonb('Give at least one location; a campaign without one shows in every country.'::text);
    ELSIF jsonb_array_length(p_payload->'locations') > coalesce((r->>'max')::int, 25) THEN
      b := b || to_jsonb(format('At most %s locations per operation; add the rest with location changes.', coalesce(r->>'max', '25')));
    ELSIF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'locations') l WHERE jsonb_typeof(l) NOT IN ('string', 'number') OR (l #>> '{}') !~ '^\d+$') THEN
      b := b || to_jsonb('Location ids must be numeric Google geo target ids.'::text);
    ELSIF (SELECT count(DISTINCT l #>> '{}') FROM jsonb_array_elements(p_payload->'locations') l) <> jsonb_array_length(p_payload->'locations') THEN
      b := b || to_jsonb('A location is listed twice.'::text);
    END IF;
    -- daily budget: the owner's limits always win, whatever the first status (a paused campaign can be switched on later)
    BEGIN v := (p_payload->>'daily_budget')::numeric; EXCEPTION WHEN others THEN v := NULL; END;
    IF v IS NULL OR v = 'NaN'::numeric OR v <> round(v, 2) OR v > 100000000
       OR v < coalesce((crm_private.ads_rule('budget_min')->>'min')::numeric, 1) THEN
      b := b || to_jsonb(format('daily_budget must be a number of at least %s (at most 2 decimals).', coalesce(crm_private.ads_rule('budget_min')->>'min', '1')));
    ELSE
      SELECT coalesce(sum(c.daily_budget), 0) + v INTO tot FROM public.ads_campaigns c JOIN public.ads_accounts x ON x.id = c.account_id
       WHERE x.platform = 'google' AND c.status = 'ENABLED';
      cap := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric;
      IF cap IS NULL THEN
        b := b || to_jsonb('Set a daily spend limit first (Google Ads > Autopilot > Spend limits).'::text);
      ELSIF tot > cap THEN
        b := b || to_jsonb(format('All running Google campaigns would spend up to %s a day, above the daily limit of %s.', tot, cap));
      END IF;
      cap := nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric;
      IF cap IS NOT NULL THEN
        mtd := crm_private.ads_google_month_spend();
        IF mtd >= cap OR mtd + tot * crm_private.ads_google_days_left() > cap THEN
          b := b || to_jsonb(format('At up to %s a day this month''s Google spend could reach %s, above the monthly limit of %s.',
            tot, round(mtd + tot * crm_private.ads_google_days_left()), cap));
        END IF;
      END IF;
      SELECT cl.max_daily_budget INTO cap FROM public.ads_clients cl WHERE cl.id = a.client_id;
      IF cap IS NOT NULL AND v > cap THEN b := b || to_jsonb(format('%s is above the client''s max daily budget of %s.', v, cap)); END IF;
    END IF;
    r := crm_private.ads_rule('g_campaigns_per_day');
    IF r IS NOT NULL THEN
      SELECT count(*) INTO n FROM public.ads_google_ops o WHERE o.account_id = p_account AND o.kind = 'campaign_create' AND o.id IS DISTINCT FROM p_exclude
         AND o.status IN ('approved', 'executing', 'verified', 'outcome_unknown') AND o.created_at > now() - interval '24 hours';
      IF n >= (r->>'max')::int THEN b := b || to_jsonb(format('%s campaign(s) already created in the last 24 hours (limit %s).', n, r->>'max')); END IF;
    END IF;

  ELSE   -- income_filter
    IF (coalesce(p_payload->>'campaign_id', '') ~ '^\d+$') = (coalesce(p_payload->>'ad_group_id', '') ~ '^\d+$') THEN
      b := b || to_jsonb('Give campaign_id or ad_group_id (one of them).'::text);
    END IF;
    lvl := CASE WHEN coalesce(p_payload->>'campaign_id', '') ~ '^\d+$' THEN 'campaignCriteria' ELSE 'adGroupCriteria' END;
    IF (p_payload ? 'exclude' AND jsonb_typeof(p_payload->'exclude') <> 'array') OR (p_payload ? 'remove' AND jsonb_typeof(p_payload->'remove') <> 'array') THEN
      b := b || to_jsonb('exclude and remove must be lists.'::text);
    ELSE
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload->'exclude', '[]')) t
                  WHERE jsonb_typeof(t) <> 'string' OR NOT (upper(t #>> '{}') = ANY (tiers))) THEN
        b := b || to_jsonb(format('Income groups are: %s.', array_to_string(tiers, ', ')));
      ELSIF (SELECT count(DISTINCT upper(t #>> '{}')) FROM jsonb_array_elements(coalesce(p_payload->'exclude', '[]')) t)
              <> jsonb_array_length(coalesce(p_payload->'exclude', '[]')) THEN
        b := b || to_jsonb('An income group is listed twice.'::text);
      ELSIF jsonb_array_length(coalesce(p_payload->'exclude', '[]')) >= array_length(tiers, 1) THEN
        b := b || to_jsonb('At least one income group must stay; shutting all of them out stops the ads.'::text);
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload->'remove', '[]')) t
                  WHERE jsonb_typeof(t) <> 'string' OR (t #>> '{}') !~ ('^customers/' || a.external_id || '/' || lvl || '/\d+~\d+$')) THEN
        b := b || to_jsonb('remove takes this account''s own income rows (resource names) at the same level.'::text);
      END IF;
      IF jsonb_array_length(coalesce(p_payload->'exclude', '[]')) + jsonb_array_length(coalesce(p_payload->'remove', '[]')) = 0 THEN
        b := b || to_jsonb('Nothing to change.'::text);
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_payload->'exclude', '[]')) t WHERE upper(t) = 'INCOME_RANGE_UNDETERMINED') THEN
        w := w || to_jsonb('Google does not know the income of many people. Shutting out "unknown" can cut how often the ads show sharply.'::text);
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object('blockers', b, 'warnings', w);
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate_v143(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- owner only
-- Runs after trg_ads_google_ops_guard (trigger names fire in alphabetical order). An agent's new campaign or income change, and
-- (while the lock is on) an agent's location change, is put back to "waiting for the owner" even on Automatic.
CREATE OR REPLACE FUNCTION crm_private.ads_google_ops_owner_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.created_by_type = 'agent' AND NEW.status = 'approved' AND NEW.approved_by IS NULL
     AND (NEW.kind IN ('campaign_create', 'income_filter')
          OR (NEW.kind = 'campaign_geo' AND crm_private.ads_cfg('google_targeting_locked') = 'on')) THEN
    NEW.status := 'pending'; NEW.approved_at := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_ops_owner_only() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_ads_google_ops_owner_only ON public.ads_google_ops;
CREATE TRIGGER trg_ads_google_ops_owner_only BEFORE INSERT OR UPDATE ON public.ads_google_ops
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_google_ops_owner_only();

-- ---------------------------------------------------------------- who runs what
-- ads-sync (unchanged) keeps every kind it knows; the two new kinds go to ads-google-ops.
CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind,
      'payload', CASE WHEN o.kind = 'budget' THEN o.payload || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->>'campaign_id'))
        ELSE o.payload END,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind NOT IN ('campaign_create', 'income_filter')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
CREATE OR REPLACE FUNCTION public.svc_ads_google_build_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' OR crm_private.ads_cfg('google_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', o.payload,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind IN ('campaign_create', 'income_filter')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
REVOKE ALL ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work() TO service_role;

-- ---------------------------------------------------------------- what the AI team must know (owner decisions, 25 Nov 2026)
UPDATE public.ads_config SET value = value || E'\nOwner decisions (25 Nov 2026; source: owner):\n'
  '- Goal: counselling enquiries from people searching for pilot training, CPL, DGCA ground classes and related.\n'
  '- Target: students and parents in premium areas only. The owner approved the PIN codes and cities on 25 Nov 2026, and only Google''s top 10% and 11-20% household income groups see the ads. Never add, remove or widen locations or income groups in an operation; raise it as a suggestion with "change nothing" recommended.\n'
  '- Two campaigns: Delhi NCR (Dwarka classroom, online batches as well) and Other cities (online batches only). Never invite people to the Dwarka classroom in the Other cities campaign.\n'
  '- Offer in both: free career counselling.'
 WHERE key = 'google_brand_facts' AND value NOT LIKE '%Owner decisions (25 Nov 2026%';

UPDATE public.ads_playbook SET active = false
 WHERE active AND lesson LIKE 'Before saying a place will or will not get ads, check it against the campaign''s location list, which includes all of Punjab%';
-- No new lesson is written here: the weekly learner replaces the whole playbook. The lasting record is google_brand_facts above,
-- and the lock makes it hold whatever a lesson says.

-- ---------------------------------------------------------------- schedule
-- Approved operations of the new kinds go out within 5 minutes; the job does nothing when none is waiting.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-google-build';
    PERFORM cron.schedule('crm-ads-google-build', '*/5 * * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-google-ops',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{}'::jsonb, timeout_milliseconds := 140000)
      WHERE EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind IN ('campaign_create', 'income_filter') AND status IN ('approved', 'executing')) $job$);
  END IF;
END $$;
