-- 121 Meta Ads > Overview: money and live campaigns in one simple view.
--  * api_ads_meta_live(): the money left to spend (the lower of the prepaid balance and the account spending limit, from
--    the health check; GST is added on top of ad spend in India, so days left uses 1.18 x the daily budget), and for each
--    campaign the CRM created from a strategy: budget used against the strategy's total budget, spent today, Meta leads,
--    CRM-qualified leads, one row per ad, and the latest form answers with whether the lead has been called yet.
--  * While any Meta campaign is live, ads-sync meta_health and meta_history run every 15 minutes (cron crm-ads-meta-live)
--    instead of every 3 hours / once a day, so spend, leads and money left stay fresh. Nothing runs when nothing is live.

CREATE OR REPLACE FUNCTION crm_private.ads_meta_is_live() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.ads_meta_object WHERE level = 'campaign' AND upper(coalesce(status, '')) = 'ACTIVE')
      OR coalesce((SELECT (h.data->'delivery'->>'campaigns')::int FROM public.ads_meta_health h ORDER BY h.taken_at DESC LIMIT 1), 0) > 0
      OR EXISTS (SELECT 1 FROM public.ads_meta_action a WHERE a.kind = 'activate'
                   AND (a.status IN ('approved', 'executing') OR (a.status = 'done' AND a.executed_at > now() - interval '1 hour'))) $$;

-- the 15-minute tick: only while something is live; makes the next meta_history run refresh the recent numbers
CREATE OR REPLACE FUNCTION crm_private.ads_meta_live_tick() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.ads_accounts WHERE platform = 'meta' AND status = 'connected') OR NOT crm_private.ads_meta_is_live() THEN
    RETURN false;
  END IF;
  UPDATE public.ads_config SET value = '', updated_at = now()
   WHERE key = 'meta_history_recent_at' AND coalesce(nullif(value, '')::timestamptz, 'epoch') < now() - interval '14 minutes';
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_live() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  h public.ads_meta_health; acct jsonb; tz text := 'Asia/Kolkata'; today date; camps jsonb := '[]'; daily numeric := 0;
  s record; v jsonb; cid text; ck text; ads jsonb; ad_ids text[]; form_ids text[]; c_obj public.ads_meta_object;
  used numeric; spent_today numeric; first_day date; meta_leads int; crm_leads int; qualified int; total numeric; horizon int;
  avail numeric; latest jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  SELECT * INTO h FROM public.ads_meta_health ORDER BY taken_at DESC LIMIT 1;
  SELECT coalesce(a.timezone, 'Asia/Kolkata') INTO tz FROM public.ads_accounts a WHERE a.platform = 'meta' AND a.status = 'connected' ORDER BY a.created_at LIMIT 1;
  today := (now() AT TIME ZONE coalesce(tz, 'Asia/Kolkata'))::date;
  acct := coalesce(h.data->'account', '{}');

  FOR s IN SELECT st.id, st.title AS name, st.build, st.approved_version, st.status FROM public.ads_meta_strategy st
            WHERE st.status <> 'archived' AND st.build ? 'steps' ORDER BY st.id LOOP
    SELECT ver.plan INTO v FROM public.ads_meta_strategy_version ver WHERE ver.strategy_id = s.id AND ver.version = coalesce((s.build->>'version')::int, s.approved_version);
    form_ids := ARRAY(SELECT e.value->>'id' FROM jsonb_each(s.build->'steps') e WHERE e.key LIKE 'form:%' AND e.value->>'id' IS NOT NULL);
    FOR ck, cid IN SELECT split_part(e.key, ':', 2), e.value->>'id' FROM jsonb_each(s.build->'steps') e
                    WHERE e.key LIKE 'campaign:%' AND e.value->>'id' IS NOT NULL LOOP
      SELECT * INTO c_obj FROM public.ads_meta_object o WHERE o.level = 'campaign' AND o.external_id = cid LIMIT 1;
      -- the ads of this campaign: those the CRM created (build steps) plus any Meta reports under it
      ad_ids := ARRAY(SELECT DISTINCT x FROM (
                  SELECT e.value->>'id' x FROM jsonb_each(s.build->'steps') e WHERE e.key LIKE 'ad:%' AND e.value->>'id' IS NOT NULL
                  UNION SELECT o.external_id FROM public.ads_meta_object o WHERE o.level = 'ad' AND o.campaign_ext = cid
                  UNION SELECT d.ad_ext FROM public.ads_meta_ad_day d WHERE d.campaign_ext = cid) q WHERE x IS NOT NULL);
      SELECT coalesce(sum(d.spend), 0), coalesce(sum(d.spend) FILTER (WHERE d.day = today), 0), min(d.day) FILTER (WHERE d.spend > 0)
        INTO used, spent_today, first_day FROM public.ads_meta_ad_day d WHERE d.campaign_ext = cid OR d.ad_ext = ANY (ad_ids);
      SELECT count(*), count(r.lead_id), count(*) FILTER (WHERE sd.ord >= 40 AND l.stage <> 'lost')
        INTO meta_leads, crm_leads, qualified
        FROM public.ads_meta_lead_raw r
        LEFT JOIN public.ads_lead l ON l.id = r.lead_id
        LEFT JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = l.stage
       WHERE coalesce(r.status, '') NOT IN ('test', 'organic')
         AND (r.ad_id = ANY (ad_ids) OR (r.ad_id IS NULL AND r.form_id = ANY (form_ids)));
      total := nullif(v->'budget'->>'monthly_total', '')::numeric;
      horizon := coalesce(nullif(v->'forecast'->>'horizon_days', '')::int, 30);
      IF upper(coalesce(c_obj.status, 'PAUSED')) = 'ACTIVE' THEN daily := daily + coalesce(nullif(v->'budget'->>'daily_total', '')::numeric, 0); END IF;
      SELECT coalesce(jsonb_agg(row ORDER BY row->>'key'), '[]') INTO ads FROM (
        SELECT jsonb_build_object(
                 'key', split_part(e.key, ':', 3), 'id', e.value->>'id',
                 'name', coalesce(cr->>'headline', cr->>'name', split_part(e.key, ':', 3)),
                 'status', coalesce((SELECT o.status FROM public.ads_meta_object o WHERE o.level = 'ad' AND o.external_id = e.value->>'id' LIMIT 1), 'PAUSED'),
                 'spend', coalesce(sum(d.spend), 0), 'impressions', coalesce(sum(d.impressions), 0), 'clicks', coalesce(sum(d.link_clicks), 0),
                 'meta_leads', coalesce(sum(d.leads), 0),
                 'leads', (SELECT count(*) FROM public.ads_meta_lead_raw r WHERE r.ad_id = e.value->>'id' AND coalesce(r.status, '') NOT IN ('test', 'organic')),
                 'post', s.build->'posts'->split_part(e.key, ':', 3)->>'permalink') row
          FROM jsonb_each(s.build->'steps') e
          LEFT JOIN LATERAL (SELECT c FROM jsonb_array_elements(coalesce(v->'creatives', '[]')) c WHERE c->>'key' = split_part(e.key, ':', 3) LIMIT 1) cc(cr) ON true
          LEFT JOIN public.ads_meta_ad_day d ON d.ad_ext = e.value->>'id'
         WHERE e.key LIKE 'ad:%'
         GROUP BY e.key, e.value, cr) z;
      SELECT coalesce(jsonb_agg(x ORDER BY x->>'at' DESC), '[]') INTO latest FROM (
        SELECT jsonb_build_object(
                 'at', coalesce(r.created_time, r.received_at), 'name', coalesce(nullif(l.name, ''), 'New lead'), 'lead_id', r.lead_id,
                 'answers', (SELECT coalesce(jsonb_agg(jsonb_build_object('q', k, 'a', a)), '[]') FROM jsonb_each_text(coalesce(r.payload->'answers', '{}')) t(k, a)
                              WHERE k !~* '(name|phone|email|mobile|number)'),
                 'stage', sd.label, 'called_at', l.first_response_at,
                 'wait_min', CASE WHEN l.first_response_at IS NULL THEN floor(extract(epoch FROM now() - coalesce(r.created_time, r.received_at)) / 60)
                                  ELSE round(extract(epoch FROM l.first_response_at - coalesce(r.created_time, r.received_at)) / 60) END) x
          FROM public.ads_meta_lead_raw r
          LEFT JOIN public.ads_lead l ON l.id = r.lead_id
          LEFT JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = l.stage
         WHERE coalesce(r.status, '') NOT IN ('test', 'organic')
           AND (r.ad_id = ANY (ad_ids) OR (r.ad_id IS NULL AND r.form_id = ANY (form_ids)))
         ORDER BY coalesce(r.created_time, r.received_at) DESC LIMIT 6) q;
      camps := camps || jsonb_build_object(
        'strategy_id', s.id, 'id', cid,
        'name', coalesce((SELECT c->>'name' FROM jsonb_array_elements(coalesce(v->'campaigns', '[]')) c WHERE c->>'key' = ck LIMIT 1), c_obj.name, s.name),
        'status', upper(coalesce(c_obj.status, 'PAUSED')),
        'budget_total', total, 'daily_budget', nullif(v->'budget'->>'daily_total', '')::numeric, 'horizon_days', horizon,
        'started', first_day, 'day', CASE WHEN first_day IS NULL THEN 0 ELSE today - first_day + 1 END,
        'used', used, 'today', spent_today, 'meta_leads', meta_leads, 'crm_leads', crm_leads, 'qualified', qualified,
        'cpl', CASE WHEN meta_leads > 0 THEN round(used / meta_leads) END,
        'ads', ads, 'latest', latest);
    END LOOP;
  END LOOP;

  daily := greatest(daily, coalesce((h.data->'pacing'->>'daily_budget')::numeric, 0));
  avail := coalesce((acct->>'available')::numeric,
                    CASE WHEN (acct->>'spend_cap')::numeric > 0 THEN greatest(0, (acct->>'spend_cap')::numeric - coalesce((acct->>'amount_spent')::numeric, 0)) END);
  RETURN jsonb_build_object(
    'wallet', jsonb_build_object(
      'available', avail, 'prepaid', acct->'prepaid', 'cap_left', coalesce(acct->'cap_left',
          CASE WHEN (acct->>'spend_cap')::numeric > 0 THEN to_jsonb(greatest(0, (acct->>'spend_cap')::numeric - coalesce((acct->>'amount_spent')::numeric, 0))) END),
      'spend_cap', acct->'spend_cap', 'amount_spent', acct->'amount_spent', 'funding_text', acct->'funding_text', 'status', acct->'status_text',
      'account', (SELECT a.external_id FROM public.ads_accounts a WHERE a.platform = 'meta' AND a.status = 'connected' ORDER BY a.created_at LIMIT 1),
      'daily_budget', nullif(daily, 0),
      'days_left', CASE WHEN daily > 0 AND avail IS NOT NULL THEN floor(avail / (daily * 1.18)) END,
      'low', daily > 0 AND avail IS NOT NULL AND avail < daily * 1.18 * 3,
      'checked_at', h.taken_at),
    'campaigns', camps,
    'numbers_at', (SELECT max(d.updated_at) FROM public.ads_meta_ad_day d),
    'live', crm_private.ads_meta_is_live());
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_is_live(), crm_private.ads_meta_live_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_live() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-live';
    PERFORM cron.schedule('crm-ads-meta-live', '7,22,37,52 * * * *', $c$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_health", "meta_history"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE crm_private.ads_meta_live_tick()
    $c$);
  END IF;
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '121') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
