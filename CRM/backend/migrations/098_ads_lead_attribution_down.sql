-- Rollback of 098: the previous definitions (076 / 091 / 094 / 096), then the new helpers are dropped.
CREATE OR REPLACE FUNCTION crm_private.ads_client_summary(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cl public.ads_clients; plat jsonb; crm jsonb := NULL; ids uuid[]; rev numeric; refunds numeric;
        spend numeric; one jsonb; mixed boolean;
BEGIN
  SELECT * INTO cl FROM public.ads_clients WHERE id = p_client;
  IF cl.id IS NULL THEN RETURN NULL; END IF;
  plat := crm_private.ads_platform_totals(p_client, p_from, p_to);
  mixed := jsonb_array_length(plat) > 1;
  one := CASE WHEN jsonb_array_length(plat) = 1 THEN plat->0 ELSE NULL END;
  spend := CASE WHEN one IS NOT NULL AND one->>'currency' = cl.currency THEN (one->>'spend')::numeric END;
  IF cl.crm_segment IS NOT NULL THEN
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
    'crm_linked', cl.crm_segment IS NOT NULL, 'crm', crm,
    'targets', jsonb_build_object('cpl', cl.target_cpl, 'qualified_cpl', cl.target_qualified_cpl, 'cac', cl.target_cac,
      'roas', cl.target_roas, 'monthly_budget', cl.monthly_budget));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_campaigns(p_client uuid, p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  WITH m AS (
    SELECT d.campaign_id, sum(d.spend) spend, sum(d.impressions) impressions, sum(d.clicks) clicks,
           sum(d.conversions) conversions, sum(d.conversion_value) conversion_value
      FROM public.ads_metrics_daily d WHERE d.day BETWEEN p_from AND p_to GROUP BY 1),
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
      'crm_linked', cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL,
      'crm', CASE WHEN cl.crm_segment IS NOT NULL AND c.utm_campaign IS NOT NULL
                  THEN crm_private.ads_lead_outcomes(coalesce(l.ids, '{}')) END)
    ORDER BY m.spend DESC NULLS LAST, c.name), '[]')
  INTO out
  FROM public.ads_campaigns c JOIN public.ads_accounts a ON a.id = c.account_id JOIN public.ads_clients cl ON cl.id = a.client_id
  LEFT JOIN m ON m.campaign_id = c.id LEFT JOIN l ON l.campaign_id = c.id
  WHERE (p_client IS NULL OR cl.id = p_client) AND coalesce(c.status, '') <> 'REMOVED';
  -- per-campaign CPL / qualified CPL / CAC (only where currency matches and CRM is linked)
  RETURN (SELECT coalesce(jsonb_agg(e || CASE WHEN e->'crm' IS NULL OR jsonb_typeof(e->'crm') = 'null' THEN '{}'::jsonb ELSE jsonb_build_object(
            'cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'valid')::numeric),
            'qualified_cpl', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'qualified')::numeric),
            'cac', crm_private.ads_div((e->>'spend')::numeric, (e->'crm'->>'customers')::numeric)) END), '[]')
          FROM jsonb_array_elements(out) e);
END $$;

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

CREATE OR REPLACE FUNCTION public.svc_ads_allocate() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE capd numeric := nullif(crm_private.ads_cfg('google_cap_daily'), '')::numeric; c record; d date := crm_private.ads_google_today();
        spend numeric; leads int; cpl numeric; tgt numeric; tot numeric; nb numeric; why text; acts jsonb := '[]';
BEGIN
  IF crm_private.ads_cfg('autopilot_google') <> 'auto' OR crm_private.ads_cfg('agents_allocator') <> 'on' THEN
    RETURN jsonb_build_object('skipped', 'Autopilot is not Automatic');
  END IF;
  FOR c IN SELECT x.*, cl.target_cpl FROM public.ads_campaigns x JOIN public.ads_accounts a ON a.id = x.account_id
             JOIN public.ads_clients cl ON cl.id = a.client_id
            WHERE a.platform = 'google' AND x.status = 'ENABLED' AND x.budget_ref IS NOT NULL AND x.daily_budget > 0 LOOP
    tgt := c.target_cpl;
    IF tgt IS NULL OR tgt <= 0 OR c.utm_campaign IS NULL THEN CONTINUE; END IF;   -- no target or no way to count leads: do nothing
    SELECT coalesce(sum(m.spend), 0) INTO spend FROM public.ads_metrics_daily m WHERE m.campaign_id = c.id AND m.day BETWEEN d - 14 AND d - 1;
    SELECT count(*) INTO leads FROM public.lead l WHERE lower(l.utm_campaign) = lower(c.utm_campaign)
       AND l.created_at >= (d - 14)::timestamptz AND l.created_at < d::timestamptz;
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
        AND l.created_at >= p_day::timestamptz AND l.created_at < (p_day + 1)::timestamptz),
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
$$;

CREATE OR REPLACE FUNCTION crm_private.ads_lead_outcomes(p_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH x AS (
    SELECT l.id,
           NOT EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Wrong number') AS valid,
           (EXISTS (SELECT 1 FROM public.contact_attempt ca WHERE ca.lead_id = l.id AND ca.disposition = 'Interested')
             OR coalesce(l.is_eligible, false)) AS interested,
           coalesce(l.closure_outcome::text IN ('admission_completed', 'booking_confirmed'), false) AS customer
      FROM public.lead l WHERE l.id = ANY (p_ids))
  SELECT jsonb_build_object('leads', count(*), 'valid', count(*) FILTER (WHERE valid),
    'qualified', count(*) FILTER (WHERE valid AND interested), 'customers', count(*) FILTER (WHERE customer))
  FROM x
$$;

DROP FUNCTION IF EXISTS crm_private.ads_client_ad_linked(uuid);
DROP FUNCTION IF EXISTS crm_private.ads_ad_leads();
DROP FUNCTION IF EXISTS crm_private.ads_touch_platform(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_touch_num(jsonb, text[]);
DROP FUNCTION IF EXISTS crm_private.ads_google_tz();
