-- 108: Meta Ads > Funnel > Website signals, website audiences, and funnel context for the Strategy agents. Run after 107.
-- Re-runnable. Rollback: 108_ads_site_signals_down.sql.
--
--  * Search Console (what people search on Google before reaching the site) and GA4 (what visitors do on it), read with
--    their official APIs by ads-sync job site_signals (nightly, or "Check now"). Both give totals only: no visitor can be
--    identified, and Google withholds rare (anonymised) queries. Stored as 28-day totals, this window and the one before.
--    Sign-in: a Google refresh token with webmasters.readonly + analytics.readonly (Vault secret GOOGLE_SITE_REFRESH_TOKEN),
--    using the same OAuth client as Google Ads.
--  * Search intent topics (customisable table ads_site_topic): fees, after 12th, eligibility, DGCA exams, CPL, cadet
--    programmes, salary / jobs, loans, medical, near me / Delhi; with change against the window before and rising queries.
--  * Website audiences (Meta Pixel): visitors 30 days, fees / course page viewers, Lead event (excluded from new-people
--    ads). The job finds the Pixel on the ad account and records whether it fires.
--  * Strategy agents now also get the funnel (90 days), the audience library, location verdicts and website signals.

CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN',
               'META_WEBHOOK_VERIFY_TOKEN','META_PAGE_TOKEN','GOOGLE_SITE_REFRESH_TOKEN']
$$;

CREATE TABLE IF NOT EXISTS public.ads_site_row (
  src text NOT NULL CHECK (src IN ('gsc', 'ga')),
  kind text NOT NULL CHECK (kind IN ('query', 'page', 'landing', 'channel', 'source', 'city', 'event')),
  k1 text NOT NULL, k2 text NOT NULL DEFAULT '',
  win text NOT NULL CHECK (win IN ('cur', 'prev')),
  m jsonb NOT NULL DEFAULT '{}',
  fetched_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (src, kind, k1, k2, win));
ALTER TABLE public.ads_site_row ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_site_row FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_site_topic (
  key text PRIMARY KEY CHECK (key ~ '^[a-z0-9_]{2,30}$'),
  label text NOT NULL, pattern text NOT NULL, ord int NOT NULL DEFAULT 100);
ALTER TABLE public.ads_site_topic ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_site_topic FROM anon, authenticated;
INSERT INTO public.ads_site_topic (key, label, pattern, ord) VALUES
  ('fees', 'Fees and cost', 'fee|cost|price|kitna|kharcha|budget|lakh', 10),
  ('after12', 'After 12th / how to become a pilot', 'after 12|12th|how to become|kaise bane|career', 20),
  ('eligibility', 'Eligibility and age', 'eligib|qualification|age limit|requirement|maths|physics|pcm', 30),
  ('dgca', 'DGCA exams and ground classes', 'dgca|ground (class|school)|navigation|meteorology|regulation|air law|rtr|technical general', 40),
  ('cpl', 'CPL / commercial pilot licence', 'cpl|commercial pilot|pilot licen', 50),
  ('cadet', 'Cadet programmes and airlines', 'cadet|indigo|air india|akasa|spicejet|airline', 60),
  ('salary', 'Salary and jobs', 'salary|job|placement|income|package', 70),
  ('loan', 'Loans and scholarships', 'loan|scholarship|emi|finance', 80),
  ('medical', 'Class 2 / Class 1 medical', 'medical|class 2|class 1|class ii|class i\b', 90),
  ('local', 'Near me / Delhi', 'near me|delhi|ncr|noida|gurgaon|gurugram', 100),
  ('brand', 'Brand (We One)', 'we ?one|weone', 5)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_config (key, value) VALUES ('site_gsc_url', ''), ('site_ga4_property', ''), ('site_signals_last', ''),
  ('meta_pixel', '')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_meta_audience (key, name, kind, stage, use_as, spec, why, exclude_default) VALUES
  ('web_fees_30', 'Website: viewed fees or cost pages (30 days)', 'website', 'hot', 'retarget',
     '{"source": "pixel", "url_any": ["fee", "cost", "price"], "days": 30}', 'Checked the price: answer the cost question (fees, loans, total) in the ad.', false),
  ('web_course_60', 'Website: viewed course pages (60 days)', 'website', 'engaged', 'retarget',
     '{"source": "pixel", "url_any": ["course", "cpl", "pilot-training", "ground"], "days": 60}', 'Read about a course but did not enquire.', false),
  ('web_visit_30', 'Website: any visit (30 days)', 'website', 'engaged', 'retarget',
     '{"source": "pixel", "days": 30}', 'Recent website visitors.', false),
  ('web_lead_180', 'Website: sent an enquiry (180 days)', 'website', 'lead', 'exclude',
     '{"source": "pixel", "event": "Lead", "days": 180}', 'Already enquired on the site: keep out of new-people ads.', true)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------------------------------- website signals
CREATE OR REPLACE FUNCTION crm_private.ads_site_signals() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH q AS (SELECT r.k1, r.win, (r.m->>'clicks')::numeric clicks, (r.m->>'impressions')::numeric impr, (r.m->>'position')::numeric pos
               FROM public.ads_site_row r WHERE r.src = 'gsc' AND r.kind = 'query'),
       tq AS (SELECT t.key, t.label, t.ord, q.* FROM public.ads_site_topic t JOIN q ON q.k1 ~* t.pattern),
       lp AS (SELECT regexp_replace(r.k1, '^https?://[^/]+', '') path, r.win, r.m FROM public.ads_site_row r WHERE r.kind IN ('page', 'landing'))
  SELECT jsonb_build_object(
    'configured', jsonb_build_object('gsc', nullif(crm_private.ads_cfg('site_gsc_url'), '') IS NOT NULL,
                                     'ga4', nullif(crm_private.ads_cfg('site_ga4_property'), '') IS NOT NULL),
    'last', nullif(crm_private.ads_cfg('site_signals_last'), '')::jsonb,
    'pixel', nullif(crm_private.ads_cfg('meta_pixel'), '')::jsonb,
    'totals', (SELECT jsonb_build_object('clicks', sum(clicks) FILTER (WHERE win = 'cur'), 'impressions', sum(impr) FILTER (WHERE win = 'cur'),
                 'clicks_prev', sum(clicks) FILTER (WHERE win = 'prev'), 'queries', count(*) FILTER (WHERE win = 'cur')) FROM q),
    'topics', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', key, 'label', label, 'clicks', c, 'impressions', i, 'clicks_prev', cp,
          'change', CASE WHEN cp > 0 THEN round(100 * (c - cp) / cp) END, 'top', top) ORDER BY i DESC NULLS LAST), '[]') FROM (
        SELECT key, label, sum(clicks) FILTER (WHERE win = 'cur') c, sum(impr) FILTER (WHERE win = 'cur') i, sum(clicks) FILTER (WHERE win = 'prev') cp,
               (SELECT jsonb_agg(x.k1) FROM (SELECT t2.k1 FROM tq t2 WHERE t2.key = tq.key AND t2.win = 'cur' ORDER BY t2.impr DESC LIMIT 5) x) top
          FROM tq GROUP BY key, label) z WHERE i > 0),
    'rising', (SELECT coalesce(jsonb_agg(jsonb_build_object('query', k1, 'impressions', ic, 'impressions_prev', ip, 'clicks', cc, 'position', round(pos, 1))
          ORDER BY ic - coalesce(ip, 0) DESC), '[]') FROM (
        SELECT c.k1, c.impr ic, p.impr ip, c.clicks cc, c.pos FROM q c LEFT JOIN q p ON p.k1 = c.k1 AND p.win = 'prev'
         WHERE c.win = 'cur' AND c.impr >= 20 AND c.impr >= 1.5 * coalesce(p.impr, 0) ORDER BY c.impr - coalesce(p.impr, 0) DESC LIMIT 15) z),
    'pages', (SELECT coalesce(jsonb_agg(jsonb_build_object('page', path, 'google_clicks', gc, 'sessions', s, 'engaged', e, 'key_events', k,
          'engaged_rate', CASE WHEN s > 0 THEN round(100.0 * e / s, 1) END, 'key_rate', CASE WHEN s > 0 THEN round(100.0 * k / s, 2) END)
          ORDER BY coalesce(s, 0) + coalesce(gc, 0) DESC), '[]') FROM (
        SELECT path, sum((m->>'clicks')::numeric) gc, sum((m->>'sessions')::numeric) s, sum((m->>'engagedSessions')::numeric) e, sum((m->>'keyEvents')::numeric) k
          FROM lp WHERE win = 'cur' GROUP BY path ORDER BY coalesce(sum((m->>'sessions')::numeric), 0) + coalesce(sum((m->>'clicks')::numeric), 0) DESC LIMIT 20) z),
    'channels', (SELECT coalesce(jsonb_agg(jsonb_build_object('channel', r.k1, 'sessions', (r.m->>'sessions')::numeric, 'key_events', (r.m->>'keyEvents')::numeric,
          'engaged_rate', CASE WHEN (r.m->>'sessions')::numeric > 0 THEN round(100 * (r.m->>'engagedSessions')::numeric / (r.m->>'sessions')::numeric, 1) END)
          ORDER BY (r.m->>'sessions')::numeric DESC), '[]') FROM public.ads_site_row r WHERE r.src = 'ga' AND r.kind = 'channel' AND r.win = 'cur'),
    'cities', (SELECT coalesce(jsonb_agg(jsonb_build_object('city', r.k1, 'region', r.k2, 'users', (r.m->>'activeUsers')::numeric, 'key_events', (r.m->>'keyEvents')::numeric)
          ORDER BY (r.m->>'activeUsers')::numeric DESC), '[]') FROM (SELECT * FROM public.ads_site_row r WHERE r.src = 'ga' AND r.kind = 'city' AND r.win = 'cur'
          ORDER BY (r.m->>'activeUsers')::numeric DESC LIMIT 15) r),
    'web_funnel', (SELECT jsonb_build_object(
          'sessions', (SELECT sum((m->>'sessions')::numeric) FROM public.ads_site_row WHERE src = 'ga' AND kind = 'channel' AND win = 'cur'),
          'engaged', (SELECT sum((m->>'engagedSessions')::numeric) FROM public.ads_site_row WHERE src = 'ga' AND kind = 'channel' AND win = 'cur'),
          'form_start', (SELECT sum((m->>'eventCount')::numeric) FROM public.ads_site_row WHERE src = 'ga' AND kind = 'event' AND win = 'cur' AND k1 = 'form_start'),
          'form_submit', (SELECT sum((m->>'eventCount')::numeric) FROM public.ads_site_row WHERE src = 'ga' AND kind = 'event' AND win = 'cur' AND k1 IN ('form_submit', 'generate_lead')),
          'key_events', (SELECT sum((m->>'keyEvents')::numeric) FROM public.ads_site_row WHERE src = 'ga' AND kind = 'channel' AND win = 'cur'),
          'crm_web_leads', (SELECT count(*) FROM public.ads_lead l WHERE l.deleted_at IS NULL AND l.created_at > now() - interval '28 days'
                               AND coalesce(l.first_touch->>'meta_source', '') NOT IN ('instant_form', 'ctwa'))))) $$;

CREATE OR REPLACE FUNCTION public.api_ads_site_signals() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_site_signals() || jsonb_build_object('settings', jsonb_build_object(
    'gsc_url', crm_private.ads_cfg('site_gsc_url'), 'ga4_property', crm_private.ads_cfg('site_ga4_property'),
    'token_set', EXISTS (SELECT 1 FROM vault.secrets s WHERE s.name = 'ads_google_site_refresh_token'),
    'client_set', EXISTS (SELECT 1 FROM vault.secrets s WHERE s.name = 'ads_google_ads_client_id')));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_site_settings_save(p_gsc_url text, p_ga4_property text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE g text := btrim(coalesce(p_gsc_url, '')); p text := regexp_replace(btrim(coalesce(p_ga4_property, '')), '^properties/', '');
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF g <> '' AND g !~* '^(sc-domain:[a-z0-9.-]+\.[a-z]{2,}|https?://[a-z0-9.-]+\.[a-z]{2,}(/.*)?)$' THEN
    RAISE EXCEPTION 'Search Console site is sc-domain:example.com or https://example.com/' USING ERRCODE = 'PT422'; END IF;
  IF p <> '' AND p !~ '^[0-9]{6,15}$' THEN RAISE EXCEPTION 'GA4 property ID is digits only (Admin > Property details)' USING ERRCODE = 'PT422'; END IF;
  IF g ~* '^https?://' AND g !~ '/$' THEN g := g || '/'; END IF;
  PERFORM crm_private.ads_meta_set_cfg('site_gsc_url', lower(g));
  PERFORM crm_private.ads_meta_set_cfg('site_ga4_property', p);
  PERFORM crm_private.ads_log('site_settings_saved', 'config', 'site', jsonb_build_object('gsc', g, 'ga4', p));
  RETURN jsonb_build_object('ok', true);
END $$;

-- What the nightly job needs (service role), and where it saves.
CREATE OR REPLACE FUNCTION public.svc_ads_site_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('gsc_url', nullif(crm_private.ads_cfg('site_gsc_url'), ''), 'ga4_property', nullif(crm_private.ads_cfg('site_ga4_property'), ''),
    'account_id', (crm_private.ads_meta_acct()).external_id) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_site_save(p_src text, p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF p_src NOT IN ('gsc', 'ga') OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'bad rows'; END IF;
  DELETE FROM public.ads_site_row WHERE src = p_src;
  INSERT INTO public.ads_site_row (src, kind, k1, k2, win, m)
  SELECT p_src, r->>'kind', left(r->>'k1', 300), left(coalesce(r->>'k2', ''), 120), r->>'win', coalesce(r->'m', '{}')
    FROM jsonb_array_elements(p_rows) r
   WHERE r->>'kind' IN ('query', 'page', 'landing', 'channel', 'source', 'city', 'event') AND r->>'win' IN ('cur', 'prev') AND coalesce(r->>'k1', '') <> ''
  ON CONFLICT (src, kind, k1, k2, win) DO UPDATE SET m = EXCLUDED.m, fetched_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_site_done(p_summary jsonb, p_pixel jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_meta_set_cfg('site_signals_last', (p_summary || jsonb_build_object('at', now()))::text);
  IF p_pixel IS NOT NULL AND jsonb_typeof(p_pixel) = 'object' THEN
    PERFORM crm_private.ads_meta_set_cfg('meta_pixel', (p_pixel || jsonb_build_object('checked_at', now()))::text);
  END IF;
END $$;

-- ------------------------------------------------------------------------------------------- funnel and location, callable inside the CRM
CREATE OR REPLACE FUNCTION crm_private.ads_meta_funnel_data(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); m record; c record; t record; st jsonb; aud jsonb;
BEGIN
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

CREATE OR REPLACE FUNCTION public.api_ads_meta_funnel(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_meta_funnel_data(p_from, p_to);
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_geo_data(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); avg_q numeric;
BEGIN
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

CREATE OR REPLACE FUNCTION public.api_ads_meta_geo(p_from date, p_to date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_meta_geo_data(p_from, p_to);
END $$;

-- ------------------------------------------------------------------------------------------- audiences: website kind
CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('on', crm_private.ads_cfg('meta_audiences_on') = 'true',
    'account_id', (crm_private.ads_meta_acct()).external_id,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'pixel_id', nullif(crm_private.ads_cfg('meta_pixel'), '')::jsonb->>'id',
    'forms', (SELECT coalesce(jsonb_agg(f.form_id ORDER BY f.updated_at DESC), '[]') FROM (SELECT * FROM public.ads_meta_forms ORDER BY updated_at DESC LIMIT 50) f),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'spec', a.spec, 'meta_id', a.meta_id, 'why', a.why,
        'people', CASE WHEN a.kind = 'crm' THEN (SELECT coalesce(jsonb_agg(jsonb_build_array(p.ph, p.em)), '[]')
                                                  FROM (SELECT * FROM crm_private.ads_meta_audience_people(a.spec) LIMIT 50000) p) END) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled AND a.kind IN ('engagement', 'crm', 'website'))) $$;

-- ------------------------------------------------------------------------------------------- Strategy agents: funnel context
-- Added to the Meta agents' context by ads-agents (kept small): the 90-day funnel, the audience library with what is
-- ready in Meta, location verdicts and website signals (search topics, rising queries, landing pages, cities).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_strategy_extra() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := crm_private.ads_meta_today(); f jsonb; g jsonb; s jsonb;
BEGIN
  f := crm_private.ads_meta_funnel_data(today - 90, today);
  g := crm_private.ads_meta_geo_data(today - 365, today);
  s := crm_private.ads_site_signals();
  RETURN jsonb_build_object(
    'funnel_90d', jsonb_build_object('stages', f->'stages', 'spend', f->'spend', 'first_call_min', f->'first_call_min', 'qualify_days', f->'qualify_days', 'notes', f->'notes'),
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'stage', a.stage, 'use_as', a.use_as,
        'ready_in_meta', a.status = 'ready', 'size', a.size_high, 'excluded_by_default', a.exclude_default) ORDER BY a.key), '[]')
      FROM public.ads_meta_audience a WHERE a.enabled),
    'locations', jsonb_build_object('avg_q_rate', g->'avg_q_rate', 'regions', (SELECT coalesce(jsonb_agg(r), '[]') FROM (SELECT r FROM jsonb_array_elements(g->'regions') r LIMIT 15) z),
      'unknown_location', g->'unknown_location'),
    'website', jsonb_build_object('configured', s->'configured', 'totals', s->'totals', 'pixel', s->'pixel',
      'topics', s->'topics', 'rising', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'rising') x LIMIT 10) z),
      'pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'pages') x LIMIT 10) z),
      'cities', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT x FROM jsonb_array_elements(s->'cities') x LIMIT 10) z),
      'web_funnel', s->'web_funnel'));
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_funnel_data(date, date), crm_private.ads_meta_geo_data(date, date), crm_private.ads_site_signals() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.api_ads_site_signals(),
  public.api_ads_site_settings_save(text, text), public.svc_ads_site_work(), public.svc_ads_site_save(text, jsonb), public.svc_ads_site_done(jsonb, jsonb),
  public.svc_ads_meta_audience_work(), public.svc_ads_meta_strategy_extra() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.api_ads_site_signals(),
  public.api_ads_site_settings_save(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_site_work(), public.svc_ads_site_save(text, jsonb), public.svc_ads_site_done(jsonb, jsonb),
  public.svc_ads_meta_audience_work(), public.svc_ads_meta_strategy_extra() TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '108')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- Nightly at 03:20 IST, once a Search Console site or GA4 property is set (also checks the Meta Pixel).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-site-signals';
    PERFORM cron.schedule('crm-ads-site-signals', '50 21 * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["site_signals"]}'::jsonb, timeout_milliseconds := 120000)
      WHERE nullif(crm_private.ads_cfg('site_gsc_url'), '') IS NOT NULL OR nullif(crm_private.ads_cfg('site_ga4_property'), '') IS NOT NULL
         OR (crm_private.ads_meta_acct()).id IS NOT NULL
    $job$);
  END IF;
END $$;
