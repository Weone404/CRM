-- 091: ADS only. api_ads_campaigns also returns Google's delivery verdict per campaign
-- (campaign.primary_status, primary_status_reasons, serving_status, saved by ads-sync in ads_campaigns.raw).
-- Identical to the 076 definition apart from the added 'delivery' key. Rollback: re-run the 076 definition.
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
