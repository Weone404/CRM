-- 098: ADS only. CRM leads that came from ads are counted by the campaign id the ad click itself carries.
--
-- Why: ad enquiries arrive through ads-intake into ads_lead / ads_enquiry (089), but the report, the budget allocator,
-- the agents' context and the overview only counted rows of the organic `lead` table whose utm_campaign text equals
-- ads_campaigns.utm_campaign. Google ad links here carry no utm_campaign text, so every screen said "0 leads".
-- Google adds gad_campaignid to every ad click by itself (and the tracking template adds utm_campaignid), so a lead is
-- matched to its campaign by that id = ads_campaigns.external_id. No UTM setup is needed. If there is no campaign id,
-- the click id (gclid / gbraid / wbraid, fbclid) still says which platform's account it belongs to.
-- Not counted: quarantined (spam / test) and deleted leads. Nothing outside ADS is changed; `lead` is only read, as before.
-- Rollback: 098_ads_lead_attribution_down.sql

-- The first id found under the given names: as a key of the touch, else as a query parameter of its landing / page URL.
CREATE OR REPLACE FUNCTION crm_private.ads_touch_num(t jsonb, VARIADIC names text[]) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE n text; u text; v text;
BEGIN
  IF jsonb_typeof(t) IS DISTINCT FROM 'object' THEN RETURN NULL; END IF;
  FOREACH n IN ARRAY names LOOP
    v := substring(t->>n FROM '^[0-9]{3,20}$');
    IF v IS NOT NULL THEN RETURN v; END IF;
  END LOOP;
  FOREACH u IN ARRAY ARRAY[t->>'landing_page', t->>'page_url'] LOOP
    CONTINUE WHEN u IS NULL;
    FOREACH n IN ARRAY names LOOP
      v := substring(u FROM '[?&]' || n || '=([0-9]{3,20})(?:[&#]|$)');
      IF v IS NOT NULL THEN RETURN v; END IF;
    END LOOP;
  END LOOP;
  RETURN NULL;
END $$;

-- Which ad platform a touch came from (NULL = not an ad click we can place).
CREATE OR REPLACE FUNCTION crm_private.ads_touch_platform(t jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN jsonb_typeof(t) IS DISTINCT FROM 'object' THEN NULL
              WHEN t ?| ARRAY['gclid', 'gbraid', 'wbraid'] THEN 'google'
              WHEN t ?| ARRAY['fbclid', 'fbc'] THEN 'meta'
              WHEN NOT crm_private.ads_touch_is_ads(t) THEN NULL
              WHEN lower(t->>'utm_source') IN ('google', 'adwords', 'googleads', 'google_ads') THEN 'google'
              WHEN lower(t->>'utm_source') IN ('facebook', 'fb', 'instagram', 'ig', 'meta') THEN 'meta' END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_tz() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT a.timezone FROM public.ads_accounts a WHERE a.platform = 'google' AND a.timezone IS NOT NULL
                    ORDER BY a.created_at LIMIT 1), 'Asia/Kolkata') $$;

-- Every ad enquiry in the CRM with the campaign / account it belongs to and how far it got.
--   valid     = the phone number is not marked wrong
--   qualified = valid AND reached "Qualified Lead" or later (not lost)
--   customer  = admission completed / booking confirmed
-- The ad touch is the first touch if that was an ad click, else the last non-direct touch, else the last touch.
CREATE OR REPLACE FUNCTION crm_private.ads_ad_leads()
RETURNS TABLE (lead_id uuid, campaign_id uuid, account_id uuid, client_id uuid, platform text, created_at timestamptz,
               stage text, valid boolean, qualified boolean, customer boolean, touch jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.id, c.id, coalesce(c.account_id, a2.id), coalesce(c.client_id, a2.client_id), coalesce(c.platform, a2.platform),
         l.created_at, l.stage,
         l.contact_status <> 'wrong_number',
         l.contact_status <> 'wrong_number' AND sd.ord >= 40 AND l.stage <> 'lost',
         sd.is_customer, tt.t
    FROM public.ads_lead l
    JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = l.stage
    CROSS JOIN LATERAL (SELECT CASE
        WHEN crm_private.ads_touch_platform(l.first_touch) IS NOT NULL THEN l.first_touch
        WHEN crm_private.ads_touch_platform(l.last_non_direct) IS NOT NULL THEN l.last_non_direct
        WHEN crm_private.ads_touch_platform(l.last_touch) IS NOT NULL THEN l.last_touch END AS t) tt
    LEFT JOIN LATERAL (
      SELECT c0.id, c0.account_id, a0.client_id, a0.platform
        FROM public.ads_campaigns c0 JOIN public.ads_accounts a0 ON a0.id = c0.account_id
       WHERE c0.external_id = crm_private.ads_touch_num(tt.t, 'gad_campaignid', 'utm_campaignid', 'campaignid')
         AND a0.platform = crm_private.ads_touch_platform(tt.t)
       ORDER BY c0.created_at LIMIT 1) c ON true
    LEFT JOIN LATERAL (
      SELECT a0.id, a0.client_id, a0.platform
        FROM public.ads_accounts a0 JOIN public.ads_clients cl0 ON cl0.id = a0.client_id
       WHERE c.id IS NULL AND a0.platform = crm_private.ads_touch_platform(tt.t)
       ORDER BY coalesce(position(tt.t->>'site' IN lower(cl0.website)) > 0, false) DESC, a0.created_at LIMIT 1) a2 ON true
   WHERE l.deleted_at IS NULL AND NOT l.quarantined AND tt.t IS NOT NULL AND (c.id IS NOT NULL OR a2.id IS NOT NULL)
$$;

-- True once at least one ad enquiry of this client has been matched: proof that its ad leads are being counted.
CREATE OR REPLACE FUNCTION crm_private.ads_client_ad_linked(p_client uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM crm_private.ads_ad_leads() x WHERE x.client_id = p_client) $$;

-- CRM leads attributed to ads for a client (076 definition + ad enquiries matched by campaign id).
-- A person who is in both lists is counted once, as the ad enquiry.
CREATE OR REPLACE FUNCTION crm_private.ads_client_leads(p_client uuid, p_from date, p_to date)
RETURNS TABLE (lead_id uuid, campaign_id uuid, account_id uuid, platform text, created_day date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.id,
         c.id,
         coalesce(c.account_id, a2.id),
         coalesce(a1.platform, a2.platform),
         (l.created_at AT TIME ZONE cl.timezone)::date
    FROM public.ads_clients cl
    JOIN public.lead l ON l.segment = cl.crm_segment
    LEFT JOIN LATERAL (
      SELECT c0.id, c0.account_id FROM public.ads_campaigns c0 JOIN public.ads_accounts a0 ON a0.id = c0.account_id
       WHERE a0.client_id = cl.id AND c0.utm_campaign IS NOT NULL AND lower(c0.utm_campaign) = lower(l.utm_campaign)
       ORDER BY c0.created_at LIMIT 1) c ON true
    LEFT JOIN public.ads_accounts a1 ON a1.id = c.account_id
    LEFT JOIN LATERAL (
      SELECT a0.id, a0.platform FROM public.ads_accounts a0
       WHERE c.id IS NULL AND a0.client_id = cl.id AND a0.utm_source IS NOT NULL AND lower(a0.utm_source) = lower(l.utm_source)
       ORDER BY a0.created_at LIMIT 1) a2 ON true
   WHERE cl.id = p_client AND cl.crm_segment IS NOT NULL
     AND (l.created_at AT TIME ZONE cl.timezone)::date BETWEEN p_from AND p_to
     AND (c.id IS NOT NULL OR a2.id IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM public.ads_lead al WHERE al.organic_lead_id = l.id AND al.deleted_at IS NULL)
  UNION ALL
  SELECT x.lead_id, x.campaign_id, x.account_id, x.platform, (x.created_at AT TIME ZONE cl.timezone)::date
    FROM public.ads_clients cl JOIN crm_private.ads_ad_leads() x ON x.client_id = cl.id
   WHERE cl.id = p_client AND (x.created_at AT TIME ZONE cl.timezone)::date BETWEEN p_from AND p_to
$$;

-- CRM outcome counts for a set of lead ids: organic `lead` rows (076 rules) and ad enquiries (rules above).
CREATE OR REPLACE FUNCTION crm_private.ads_lead_outcomes(p_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH x AS (
    SELECT l.id,
           NOT EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Wrong number') AS valid,
           (EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Interested')
             OR coalesce(l.is_eligible, false)) AS interested,
           coalesce(l.closure_outcome::text IN ('admission_completed', 'booking_confirmed'), false) AS customer
      FROM public.lead l WHERE l.id = ANY (p_ids)
    UNION ALL
    SELECT l.id, l.contact_status <> 'wrong_number', sd.ord >= 40 AND l.stage <> 'lost', sd.is_customer
      FROM public.ads_lead l JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = l.stage
     WHERE l.id = ANY (p_ids) AND l.deleted_at IS NULL)
  SELECT jsonb_build_object('leads', count(*), 'valid', count(*) FILTER (WHERE valid),
    'qualified', count(*) FILTER (WHERE valid AND interested), 'customers', count(*) FILTER (WHERE customer))
  FROM x
$$;

-- One client's full picture (076 definition; CRM numbers now also appear when ad enquiries are being counted).
CREATE OR REPLACE FUNCTION crm_private.ads_client_summary(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cl public.ads_clients; linked boolean; plat jsonb; crm jsonb := NULL; ids uuid[]; rev numeric; refunds numeric;
        spend numeric; one jsonb; mixed boolean;
BEGIN
  SELECT * INTO cl FROM public.ads_clients WHERE id = p_client;
  IF cl.id IS NULL THEN RETURN NULL; END IF;
  plat := crm_private.ads_platform_totals(p_client, p_from, p_to);
  mixed := jsonb_array_length(plat) > 1;
  one := CASE WHEN jsonb_array_length(plat) = 1 THEN plat->0 ELSE NULL END;
  spend := CASE WHEN one IS NOT NULL AND one->>'currency' = cl.currency THEN (one->>'spend')::numeric END;
  linked := cl.crm_segment IS NOT NULL OR crm_private.ads_client_ad_linked(cl.id);
  IF linked THEN
    SELECT coalesce(array_agg(lead_id), '{}') INTO ids FROM crm_private.ads_client_leads(p_client, p_from, p_to);
    crm := crm_private.ads_lead_outcomes(ids);
    SELECT sum(amount) FILTER (WHERE kind = 'sale'), sum(amount) FILTER (WHERE kind = 'refund') INTO rev, refunds
      FROM public.ads_revenue WHERE client_id = p_client AND currency = cl.currency AND occurred_on BETWEEN p_from AND p_to;
    crm := crm || jsonb_build_object(
      'revenue', coalesce(rev, 0) - coalesce(refunds, 0), 'refunds', coalesce(refunds, 0),
      'cpl', crm_private.ads_div(spend, (crm->>'valid')::numeric),
      'qualified_cpl', crm_private.ads_div(spend, (crm->>'qualified')::numeric),
      'cac', crm_private.ads_div(spend, (crm->>'customers')::numeric),
      'lead_to_customer_pct', crm_private.ads_div((crm->>'customers')::numeric, (crm->>'valid')::numeric, 100),
      'crm_roas', crm_private.ads_div(coalesce(rev, 0) - coalesce(refunds, 0), spend),
      'contribution', CASE WHEN spend IS NULL OR cl.gross_margin_pct IS NULL THEN NULL
                           ELSE round((coalesce(rev, 0) - coalesce(refunds, 0)) * cl.gross_margin_pct / 100 - spend, 2) END);
  END IF;
  RETURN jsonb_build_object(
    'client_id', cl.id, 'name', cl.name, 'currency', cl.currency,
    'platform', plat, 'mixed_currency', mixed, 'spend', spend,
    'crm_linked', linked, 'crm', crm,
    'targets', jsonb_build_object('cpl', cl.target_cpl, 'qualified_cpl', cl.target_qualified_cpl, 'cac', cl.target_cac,
      'roas', cl.target_roas, 'monthly_budget', cl.monthly_budget));
END $$;

-- Campaign list (091 definition; a campaign is linked to the CRM by its campaign id, no UTM setup needed).
CREATE OR REPLACE FUNCTION public.api_ads_campaigns(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  WITH m AS (
    SELECT d.campaign_id, sum(d.spend) spend, sum(d.impressions) impressions, sum(d.clicks) clicks,
           sum(d.conversions) conversions, sum(d.conversion_value) conversion_value
      FROM public.ads_metrics_daily d WHERE d.day BETWEEN p_from AND p_to GROUP BY 1),
  al AS (SELECT c0.id, crm_private.ads_client_ad_linked(c0.id) v FROM public.ads_clients c0 WHERE p_client IS NULL OR c0.id = p_client),
  l AS (
    SELECT x.campaign_id, array_agg(x.lead_id) ids
      FROM public.ads_clients c, LATERAL crm_private.ads_client_leads(c.id, p_from, p_to) x
     WHERE (p_client IS NULL OR c.id = p_client) AND x.campaign_id IS NOT NULL GROUP BY 1)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'status', c.status, 'platform', a.platform, 'account', coalesce(a.name, a.external_id),
      'account_status', a.status, 'client', cl.name, 'client_id', cl.id, 'currency', coalesce(a.currency, cl.currency),
      'objective', c.objective, 'channel', c.channel, 'daily_budget', c.daily_budget, 'budget_editable', c.budget_ref IS NOT NULL,
      'utm_campaign', c.utm_campaign, 'synced_at', c.synced_at,
      -- Google's own verdict on delivery (stored by ads-sync in raw; null for Meta / before the first sync).
      'delivery', CASE WHEN c.raw ? 'primary_status' THEN jsonb_build_object('primary_status', c.raw->>'primary_status',
                  'reasons', coalesce(c.raw->'primary_status_reasons', '[]'::jsonb), 'serving_status', c.raw->>'serving_status') END,
      'spend', m.spend, 'impressions', m.impressions, 'clicks', m.clicks, 'conversions', m.conversions,
      'conversion_value', m.conversion_value,
      'ctr', crm_private.ads_div(m.clicks, m.impressions, 100), 'cpc', crm_private.ads_div(m.spend, m.clicks),
      'cpm', crm_private.ads_div(m.spend, m.impressions, 1000), 'platform_roas', crm_private.ads_div(m.conversion_value, m.spend),
      'crm_linked', (cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL) OR al.v,
      'crm', CASE WHEN (cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL) OR al.v
                  THEN crm_private.ads_lead_outcomes(coalesce(l.ids, '{}')) END)
    ORDER BY m.spend DESC NULLS LAST, c.name), '[]')
  INTO out
  FROM public.ads_campaigns c JOIN public.ads_accounts a ON a.id = c.account_id JOIN public.ads_clients cl ON cl.id = a.client_id
  JOIN al ON al.id = cl.id
  LEFT JOIN m ON m.campaign_id = c.id LEFT JOIN l ON l.campaign_id = c.id
  WHERE (p_client IS NULL OR cl.id = p_client) AND coalesce(c.status, '') <> 'REMOVED';
  -- per-campaign CPL / qualified CPL / CAC (only where currency matches and CRM is linked)
  RETURN (SELECT coalesce(jsonb_agg(e || CASE WHEN e->'crm' IS NULL OR jsonb_typeof(e->'crm') = 'null' THEN '{}'::jsonb ELSE jsonb_build_object(
            'cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'valid')::numeric),
            'qualified_cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'qualified')::numeric),
            'cac', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'customers')::numeric)) END), '[]')
          FROM jsonb_array_elements(out) e);
END $$;

-- What every agent sees (094 definition + real ad enquiries per campaign and the list of them).
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
            AND lower(l.utm_campaign) = lower(c.utm_campaign) AND l.created_at > now() - interval '30 days'
            AND NOT EXISTS (SELECT 1 FROM public.ads_lead al WHERE al.organic_lead_id = l.id AND al.deleted_at IS NULL))
          + (SELECT count(*) FROM crm_private.ads_ad_leads() x WHERE x.campaign_id = c.id AND x.created_at > now() - interval '30 days'),
        'crm_qualified_30d', (SELECT count(*) FROM crm_private.ads_ad_leads() x WHERE x.campaign_id = c.id AND x.qualified
            AND x.created_at > now() - interval '30 days'))
        ORDER BY (c.status = 'ENABLED') DESC, c.name), '[]')
      FROM public.ads_campaigns c JOIN a ON a.id = c.account_id WHERE c.status <> 'REMOVED'),
    -- Real enquiries in the CRM that came from an ad click (no personal data): which keyword and ad brought them, and how far they got.
    'ad_leads_30d', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'day', (x.created_at AT TIME ZONE crm_private.ads_google_tz())::date,
        'campaign_id', (SELECT c2.external_id FROM public.ads_campaigns c2 WHERE c2.id = x.campaign_id),
        'ad_group_id', crm_private.ads_touch_num(x.touch, 'utm_adgroupid', 'adgroupid'),
        'ad_id', crm_private.ads_touch_num(x.touch, 'utm_content', 'creative'),
        'keyword', left(x.touch->>'utm_term', 80), 'stage', x.stage, 'valid', x.valid, 'qualified', x.qualified,
        'customer', x.customer) ORDER BY x.created_at DESC), '[]')
      FROM (SELECT * FROM crm_private.ads_ad_leads() y WHERE y.platform = 'google' AND y.created_at > now() - interval '30 days'
             ORDER BY y.created_at DESC LIMIT 200) x),
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

-- Budget allocator (096 definition; counts ad enquiries by campaign id).
CREATE OR REPLACE FUNCTION public.svc_ads_allocate() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE capd numeric := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric; c record; d date := crm_private.ads_google_today();
        spend numeric; leads int; cpl numeric; tgt numeric; tot numeric; nb numeric; why text; acts jsonb := '[]';
BEGIN
  IF crm_private.ads_cfg('autopilot_google') <> 'auto' OR crm_private.ads_cfg('agents_allocator') <> 'on' THEN
    RETURN jsonb_build_object('skipped', 'Autopilot is not Automatic');
  END IF;
  FOR c IN SELECT x.*, cl.target_cpl, cl.id AS client_id FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
             JOIN public.ads_clients cl ON cl.id = a.client_id
            WHERE a.platform = 'google' AND x.status = 'ENABLED' AND x.budget_ref IS NOT NULL AND x.daily_budget > 0 LOOP
    tgt := c.target_cpl;
    -- no target, or no proven way to count this client's leads (no UTM link and no ad enquiry ever received): do nothing
    IF tgt IS NULL OR tgt <= 0 OR (c.utm_campaign IS NULL AND NOT crm_private.ads_client_ad_linked(c.client_id)) THEN CONTINUE; END IF;
    SELECT coalesce(sum(m.spend), 0) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d - 14 AND d - 1;
    SELECT (SELECT count(*) FROM public.lead l WHERE c.utm_campaign IS NOT NULL AND lower(l.utm_campaign) = lower(c.utm_campaign)
              AND l.created_at >= (d - 14)::timestamptz AND l.created_at < d::timestamptz
              AND NOT EXISTS (SELECT 1 FROM public.ads_lead al WHERE al.organic_lead_id = l.id AND al.deleted_at IS NULL))
         + (SELECT count(*) FROM crm_private.ads_ad_leads() x WHERE x.campaign_id = c.id AND x.valid
              AND (x.created_at AT TIME ZONE crm_private.ads_google_tz())::date BETWEEN d - 14 AND d - 1) INTO leads;
    cpl := CASE WHEN leads > 0 THEN round(spend / leads, 2) END;
    SELECT coalesce(sum(x.daily_budget), 0) INTO tot FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
     WHERE a.platform = 'google' AND x.status = 'ENABLED';
    IF leads >= 3 AND cpl <= tgt AND coalesce(c.raw->'primary_status_reasons', '[]') ? 'BUDGET_CONSTRAINED' THEN
      nb := round(c.daily_budget * 1.15, 2);
      IF capd IS NOT NULL THEN nb := least(nb, c.daily_budget + greatest(capd - tot, 0)); END IF;
      IF nb > c.daily_budget THEN
        why := crm_private.ads_system_change(c.id, 'budget', jsonb_build_object('daily_budget', nb),
          format('Allocator: "%s" brought %s CRM leads at %s each (target %s) and Google says the budget limits it; %s -> %s', c.name, leads, cpl, tgt, c.daily_budget, nb));
        acts := acts || jsonb_build_object('campaign', c.name, 'action', 'raise', 'from', c.daily_budget, 'to', nb, 'leads', leads, 'cpl', cpl, 'problem', why);
      END IF;
    ELSIF spend >= 3 * tgt AND (leads = 0 OR cpl > 1.5 * tgt) THEN
      nb := greatest(round(c.daily_budget * 0.8, 2), 1);
      why := crm_private.ads_system_change(c.id, 'budget', jsonb_build_object('daily_budget', nb),
        format('Allocator: "%s" spent %s in 14 days for %s CRM leads (target %s each); %s -> %s', c.name, spend, leads, tgt, c.daily_budget, nb));
      acts := acts || jsonb_build_object('campaign', c.name, 'action', 'lower', 'from', c.daily_budget, 'to', nb, 'leads', leads, 'spend', spend, 'problem', why);
    END IF;
  END LOOP;
  IF jsonb_array_length(acts) > 0 THEN
    PERFORM crm_private.ads_agent_note('allocator', 'daily', format('Budget allocator: %s',
      (SELECT string_agg((a->>'campaign') || ' ' || (a->>'from') || ' -> ' || (a->>'to') || coalesce(' (not done: ' || (a->>'problem') || ')', ''), '; ')
         FROM jsonb_array_elements(acts) a)), jsonb_build_object('actions', acts));
  END IF;
  RETURN jsonb_build_object('actions', acts);
END $$;

-- Daily report data (096 definition; counts ad enquiries by campaign id).
CREATE OR REPLACE FUNCTION crm_private.ads_report_data(p_day date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH g AS (SELECT x.* FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id WHERE a.platform = 'google'),
       m AS (SELECT sum(md.spend) spend, sum(md.clicks) clicks, sum(md.impressions) impressions, sum(md.conversions) conv
               FROM public.ads_metrics_daily md JOIN g ON g.id = md.campaign_id WHERE md.day = p_day)
  SELECT jsonb_build_object(
    'day', p_day,
    'spend', (SELECT spend FROM m), 'clicks', (SELECT clicks FROM m), 'impressions', (SELECT impressions FROM m),
    'platform_conversions', (SELECT conv FROM m),
    'crm_leads', (SELECT count(*) FROM public.lead l WHERE l.utm_campaign IS NOT NULL
        AND lower(l.utm_campaign) IN (SELECT lower(utm_campaign) FROM g WHERE utm_campaign IS NOT NULL)
        AND l.created_at >= p_day::timestamptz AND l.created_at < (p_day + 1)::timestamptz
        AND NOT EXISTS (SELECT 1 FROM public.ads_lead al WHERE al.organic_lead_id = l.id AND al.deleted_at IS NULL))
      + (SELECT count(*) FROM crm_private.ads_ad_leads() x WHERE x.platform = 'google'
          AND (x.created_at AT TIME ZONE crm_private.ads_google_tz())::date = p_day),
    'month_spend', crm_private.ads_google_month_spend(),
    'limits', jsonb_build_object('daily', nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric,
                                 'monthly', nullif(crm_private.ads_cfg('google_cap_monthly'), '')::numeric),
    'changes_live', (SELECT count(*) FROM public.ads_google_ops WHERE status = 'verified' AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz)
                  + (SELECT count(*) FROM public.ads_change_queue WHERE status = 'verified' AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz),
    'changes_failed', (SELECT count(*) FROM public.ads_google_ops WHERE status IN ('failed', 'outcome_unknown') AND updated_at >= p_day::timestamptz AND updated_at < (p_day + 1)::timestamptz),
    'reviewer_stopped', (SELECT count(*) FROM public.ads_agent_runs WHERE role = 'reviewer' AND status IN ('rejected', 'escalated')
                           AND created_at >= p_day::timestamptz AND created_at < (p_day + 1)::timestamptz),
    'open_suggestions', (SELECT count(*) FROM public.ads_autopilot_suggestions WHERE status = 'open'),
    'waiting_approval', (SELECT count(*) FROM public.ads_google_ops WHERE status = 'pending'),
    'not_serving', (SELECT coalesce(jsonb_agg(jsonb_build_object('campaign', name, 'status', raw->>'primary_status', 'reasons', raw->'primary_status_reasons')), '[]')
                      FROM g WHERE status = 'ENABLED' AND raw->>'primary_status' IN ('NOT_ELIGIBLE', 'LIMITED', 'MISCONFIGURED', 'PENDING')),
    'account_status', (crm_private.ads_google_account()).status,
    'agents_last_seen', crm_private.ads_cfg('agents_last_seen'))
$$;

REVOKE ALL ON FUNCTION crm_private.ads_touch_num(jsonb, text[]), crm_private.ads_touch_platform(jsonb), crm_private.ads_google_tz(),
  crm_private.ads_ad_leads(), crm_private.ads_client_ad_linked(uuid) FROM PUBLIC, anon, authenticated;
