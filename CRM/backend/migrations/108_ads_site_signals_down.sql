-- Rollback of 108_ads_site_signals.sql. Puts 107 back (website rows, topics and website audiences are dropped; audiences already in Meta stay).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-site-signals';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.api_ads_site_signals(), public.api_ads_site_settings_save(text, text), public.svc_ads_site_work(),
  public.svc_ads_site_save(text, jsonb), public.svc_ads_site_done(jsonb, jsonb), public.svc_ads_meta_strategy_extra(), crm_private.ads_site_signals();
DROP TABLE IF EXISTS public.ads_site_row, public.ads_site_topic;
DELETE FROM public.ads_meta_audience WHERE kind = 'website';
DELETE FROM public.ads_config WHERE key IN ('site_gsc_url', 'site_ga4_property', 'site_signals_last', 'meta_pixel');
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN',
               'META_WEBHOOK_VERIFY_TOKEN','META_PAGE_TOKEN']
$$;
CREATE OR REPLACE FUNCTION public.api_ads_meta_funnel(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); m record; c record; t record; st jsonb; aud jsonb;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 400 THEN RAISE EXCEPTION 'Pick a period of up to 400 days' USING ERRCODE = 'PT422'; END IF;
  SELECT coalesce(sum(d.spend), 0) spend, coalesce(sum(d.impressions), 0) views, coalesce(sum(coalesce(d.link_clicks, d.clicks)), 0) clicks,
         coalesce(sum(d.leads), 0) meta_leads
    INTO m FROM public.ads_meta_ad_day d WHERE d.account_id = acc.id AND d.day BETWEEN p_from AND p_to;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.fn_leads (id uuid, created_at timestamptz, first_response_at timestamptz, qualified boolean, customer boolean, q_at timestamptz) ON COMMIT DROP;
  TRUNCATE pg_temp.fn_leads;
  INSERT INTO pg_temp.fn_leads
  SELECT l.id, l.created_at, l.first_response_at, x.qualified, x.customer,
         (SELECT min(se.at) FROM public.ads_lead_stage_event se JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = se.to_stage
           WHERE se.lead_id = l.id AND sd.ord >= 40 AND se.to_stage <> 'lost')
    FROM (SELECT DISTINCT ON (y.lead_id) y.* FROM crm_private.ads_ad_leads() y WHERE y.platform = 'meta' ORDER BY y.lead_id, y.created_at) x
    JOIN public.ads_lead l ON l.id = x.lead_id
   WHERE (l.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN p_from AND p_to;
  SELECT count(*) leads, count(*) FILTER (WHERE first_response_at IS NOT NULL) contacted, count(*) FILTER (WHERE qualified) qualified,
         count(*) FILTER (WHERE customer) customers,
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM first_response_at - created_at) / 60))::numeric) first_call_min,
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM q_at - created_at) / 86400))::numeric, 1) qualify_days,
         count(*) FILTER (WHERE first_response_at IS NULL AND created_at < now() - interval '1 day') not_called
    INTO c FROM pg_temp.fn_leads;
  st := jsonb_build_array(
    jsonb_build_object('key', 'views', 'label', 'Saw an ad', 'n', m.views),
    jsonb_build_object('key', 'clicks', 'label', 'Clicked', 'n', m.clicks),
    jsonb_build_object('key', 'leads', 'label', 'Became a lead', 'n', c.leads, 'meta_count', m.meta_leads),
    jsonb_build_object('key', 'contacted', 'label', 'Called', 'n', c.contacted),
    jsonb_build_object('key', 'qualified', 'label', 'Qualified', 'n', c.qualified),
    jsonb_build_object('key', 'customers', 'label', 'Admission', 'n', c.customers));
  SELECT coalesce(jsonb_agg(z.s || jsonb_build_object(
      'cost', CASE WHEN (z.s->>'n')::numeric > 0 AND m.spend > 0 THEN round(m.spend / (z.s->>'n')::numeric, 2) END,
      'from_prev', CASE WHEN z.i > 1 AND (st->(z.i::int - 2)->>'n')::numeric > 0 THEN round(100 * (z.s->>'n')::numeric / (st->(z.i::int - 2)->>'n')::numeric, 2) END)
      ORDER BY z.i), '[]') INTO st
    FROM jsonb_array_elements(st) WITH ORDINALITY z(s, i);
  SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'stage', a.stage, 'size_low', a.size_low, 'size_high', a.size_high, 'status', a.status)
      ORDER BY a.stage, a.key), '[]') INTO aud
    FROM public.ads_meta_audience a WHERE a.kind = 'engagement' AND a.enabled;
  RETURN jsonb_build_object('from', p_from, 'to', p_to, 'spend', m.spend, 'stages', st, 'warm', aud,
    'first_call_min', c.first_call_min, 'qualify_days', c.qualify_days, 'not_called', c.not_called,
    'notes', (SELECT coalesce(jsonb_agg(n), '[]') FROM unnest(ARRAY[
        CASE WHEN c.not_called > 0 THEN format('%s lead(s) older than a day were never called: speed is the cheapest fix in the funnel.', c.not_called) END,
        CASE WHEN c.leads >= 20 AND c.qualified::numeric / c.leads < 0.1 THEN 'Fewer than 1 in 10 leads qualify: check Lead quality to see which forms, ads and answers bring the wrong people, and add qualifying questions to the form.' END,
        CASE WHEN m.meta_leads > 0 AND c.leads < m.meta_leads * 0.8 THEN format('Meta counted %s leads but only %s reached the CRM: check Setup > lead intake.', m.meta_leads, c.leads) END,
        CASE WHEN c.leads > 0 AND m.spend = 0 THEN 'No Meta spend is recorded for this period yet (history sync runs nightly).' END]) n WHERE n IS NOT NULL));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_geo(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); avg_q numeric;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 1200 THEN RAISE EXCEPTION 'Pick a period of up to 1,200 days' USING ERRCODE = 'PT422'; END IF;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.geo_l (city text, state text, known boolean, qualified boolean, customer boolean) ON COMMIT DROP;
  TRUNCATE pg_temp.geo_l;
  INSERT INTO pg_temp.geo_l
  SELECT nullif(initcap(lower(btrim(ct.v))), ''), coalesce(nullif(initcap(lower(btrim(sv.v))), ''), g.state), x.known, x.qualified, x.customer
    FROM crm_private.ads_meta_lead_facts(p_from, p_to) x
    LEFT JOIN LATERAL (SELECT e.value #>> '{}' v FROM jsonb_each(coalesce(x.answers, '{}')) e WHERE e.key ~* 'city|town|district' LIMIT 1) ct ON true
    LEFT JOIN LATERAL (SELECT e.value #>> '{}' v FROM jsonb_each(coalesce(x.answers, '{}')) e WHERE e.key ~* '(^|_)state($|_)|province' LIMIT 1) sv ON true
    LEFT JOIN public.ads_geo_in g ON g.city = lower(btrim(ct.v));
  SELECT CASE WHEN count(*) FILTER (WHERE known) > 0 THEN count(*) FILTER (WHERE qualified)::numeric / count(*) FILTER (WHERE known) END INTO avg_q FROM pg_temp.geo_l;
  RETURN jsonb_build_object('avg_q_rate', round(100 * avg_q, 1),
    'regions', (SELECT coalesce(jsonb_agg(r ORDER BY (r->>'qualified')::int DESC, (r->>'spend')::numeric DESC NULLS LAST), '[]') FROM (
      SELECT jsonb_build_object('region', coalesce(mr.region, cr.state), 'spend', mr.spend, 'meta_leads', mr.leads,
        'cpl', CASE WHEN mr.leads > 0 THEN round(mr.spend / mr.leads, 2) END,
        'crm_leads', coalesce(cr.n, 0), 'known', coalesce(cr.kn, 0), 'qualified', coalesce(cr.q, 0), 'customers', coalesce(cr.cu, 0),
        'q_rate', CASE WHEN cr.kn > 0 THEN round(100.0 * cr.q / cr.kn, 1) END,
        'cost_per_qualified', CASE WHEN cr.q > 0 AND mr.spend > 0 THEN round(mr.spend / cr.q, 2) END,
        'verdict', CASE WHEN coalesce(cr.kn, 0) < 10 THEN 'too few leads'
                        WHEN avg_q > 0 AND cr.q::numeric / cr.kn >= 1.25 * avg_q THEN 'focus'
                        WHEN cr.q = 0 AND cr.kn >= 15 THEN 'cut'
                        WHEN avg_q > 0 AND cr.q::numeric / cr.kn <= 0.5 * avg_q THEN 'reduce' ELSE 'keep' END) r
        FROM (SELECT b.k1 region, sum(b.spend) spend, sum(b.leads) leads FROM public.ads_meta_breakdown b
               WHERE b.account_id = acc.id AND b.kind = 'region' AND b.month BETWEEN date_trunc('month', p_from)::date AND p_to GROUP BY b.k1) mr
        FULL JOIN (SELECT state, count(*) n, count(*) FILTER (WHERE known) kn, count(*) FILTER (WHERE qualified) q, count(*) FILTER (WHERE customer) cu
                     FROM pg_temp.geo_l WHERE state IS NOT NULL GROUP BY state) cr ON lower(cr.state) = lower(mr.region)) z),
    'cities', (SELECT coalesce(jsonb_agg(jsonb_build_object('city', city, 'state', state, 'leads', n, 'known', kn, 'qualified', q, 'customers', cu,
        'q_rate', CASE WHEN kn > 0 THEN round(100.0 * q / kn, 1) END, 'small', kn < 10) ORDER BY q DESC, n DESC), '[]') FROM (
      SELECT city, max(state) state, count(*) n, count(*) FILTER (WHERE known) kn, count(*) FILTER (WHERE qualified) q, count(*) FILTER (WHERE customer) cu
        FROM pg_temp.geo_l WHERE city IS NOT NULL GROUP BY city ORDER BY count(*) DESC LIMIT 40) z),
    'unknown_location', (SELECT count(*) FROM pg_temp.geo_l WHERE city IS NULL AND state IS NULL),
    'tip', 'Location is one of the few settings Meta treats as a hard limit in 2026: aim budget at the states that turn leads into students, not the ones with the cheapest leads.');
END $$;

DROP FUNCTION IF EXISTS crm_private.ads_meta_funnel_data(date, date), crm_private.ads_meta_geo_data(date, date);

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('on', crm_private.ads_cfg('meta_audiences_on') = 'true',
    'account_id', (crm_private.ads_meta_acct()).external_id,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'forms', (SELECT coalesce(jsonb_agg(f.form_id ORDER BY f.updated_at DESC), '[]') FROM (SELECT * FROM public.ads_meta_forms ORDER BY updated_at DESC LIMIT 50) f),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'spec', a.spec, 'meta_id', a.meta_id, 'why', a.why,
        'people', CASE WHEN a.kind = 'crm' THEN (SELECT coalesce(jsonb_agg(jsonb_build_array(p.ph, p.em)), '[]')
                                                  FROM (SELECT * FROM crm_private.ads_meta_audience_people(a.spec) LIMIT 50000) p) END) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled AND a.kind IN ('engagement', 'crm'))) $$;
REVOKE ALL ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.svc_ads_meta_audience_work() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_audience_work() TO service_role;
UPDATE public.ads_config SET value = '107', updated_at = now() WHERE key = 'ads_schema';
