-- 107: Meta Ads > Funnel (batch A of funnel targeting). Run after 106. Re-runnable. Rollback: 107_ads_meta_funnel_down.sql.
--
--  * Funnel map: ad views -> clicks -> leads -> contacted -> qualified -> admissions for a period, with the cost of each
--    stage, how many move on, how long it takes, and the warm / hot audiences waiting on Meta.
--  * Audience library kept in Meta (when Admin turns it on): people who engaged on Instagram / the Page, messaged, or
--    opened a lead form without sending it (Meta-side, no personal data leaves), and lists from the CRM (leads of the last
--    30 days, open leads, qualified, admissions, lost, hot-scored) sent SHA-256 hashed and only for people whose consent
--    rule allows it (the same rule as the Conversions API, migration 100). Lists are replaced daily (does not restart
--    learning). In 2026 Meta treats only location, minimum age, languages and custom audience EXCLUSIONS as hard limits,
--    so "exclude from new-people campaigns" is the main targeting control: by default admissions and leads of the last
--    30 days are kept out of every new ad set the Strategy builds.
--  * Location focus: Meta spend and leads by state next to CRM quality (qualified / admissions) by state and city, with a
--    plain verdict (focus / keep / cut / too few leads).

CREATE TABLE IF NOT EXISTS public.ads_meta_audience (
  key text PRIMARY KEY CHECK (key ~ '^[a-z0-9_]{3,40}$'),
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('engagement', 'crm', 'website', 'lookalike')),
  stage text NOT NULL CHECK (stage IN ('engaged', 'hot', 'lead', 'qualified', 'customer')),
  use_as text NOT NULL CHECK (use_as IN ('retarget', 'exclude', 'seed', 'reengage')),
  spec jsonb NOT NULL DEFAULT '{}',
  why text,
  enabled boolean NOT NULL DEFAULT true,
  exclude_default boolean NOT NULL DEFAULT false,
  meta_id text CHECK (meta_id ~ '^[0-9]{5,25}$'),
  status text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'ready', 'error', 'off')),
  size_low bigint, size_high bigint, members int, detail text,
  synced_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_audience ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_audience FROM anon, authenticated;

INSERT INTO public.ads_meta_audience (key, name, kind, stage, use_as, spec, why, exclude_default) VALUES
  ('form_dropoff_30', 'Opened a lead form, did not send it (30 days)', 'engagement', 'hot', 'retarget',
     '{"source": "lead", "event": "lead_generation_dropoff", "days": 30}', 'The warmest people who are not leads yet: a short reminder or a WhatsApp chat usually wins them back.', false),
  ('form_open_90', 'Opened a lead form (90 days)', 'engagement', 'hot', 'retarget',
     '{"source": "lead", "event": "lead_generation_opened", "days": 90}', 'Showed intent; Meta keeps lead-form audiences for up to 90 days.', false),
  ('messaged_365', 'Messaged the Page or Instagram (365 days)', 'engagement', 'hot', 'retarget',
     '{"source": "page+ig", "event": "messaged", "days": 365}', 'Asked a question once; a proof-led ad brings them back.', false),
  ('ig_visit_30', 'Visited the Instagram profile (30 days)', 'engagement', 'engaged', 'retarget',
     '{"source": "ig", "event": "ig_business_profile_visit", "days": 30}', 'Checked you out recently.', false),
  ('ig_engaged_90', 'Engaged on Instagram (90 days)', 'engagement', 'engaged', 'retarget',
     '{"source": "ig", "event": "ig_business_profile_engaged", "days": 90}', 'Liked, commented, saved, shared or tapped a call to action.', false),
  ('page_engaged_365', 'Engaged with the Facebook Page (365 days)', 'engagement', 'engaged', 'retarget',
     '{"source": "page", "event": "page_engaged", "days": 365}', 'The widest warm pool on Facebook.', false),
  ('crm_leads_30', 'CRM: leads of the last 30 days', 'crm', 'lead', 'exclude',
     '{"segment": "leads", "days": 30}', 'Already in the pipeline: keep them out of new-people campaigns so budget finds new people.', true),
  ('crm_open_180', 'CRM: open leads, 30-180 days old', 'crm', 'lead', 'reengage',
     '{"segment": "open", "days": 180, "min_days": 30}', 'Never moved on: a new offer (webinar, campus visit, demo flight) re-opens the talk.', false),
  ('crm_lost_365', 'CRM: lost leads (365 days)', 'crm', 'lead', 'reengage',
     '{"segment": "lost", "days": 365}', 'Said no once; a later batch or a new reason can bring them back.', false),
  ('crm_qualified_365', 'CRM: qualified leads (365 days)', 'crm', 'qualified', 'seed',
     '{"segment": "qualified", "days": 365}', 'The people you want more of: a lookalike seed and a hint for Advantage+ audience.', false),
  ('crm_hot_90', 'CRM: hot-scored leads (90 days)', 'crm', 'lead', 'seed',
     '{"segment": "hot", "days": 90}', 'Leads the score rates highest.', false),
  ('crm_customers', 'CRM: admissions (all time)', 'crm', 'customer', 'exclude',
     '{"segment": "customers"}', 'Already students: never pay to find them again; also the best lookalike seed.', true)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.ads_config (key, value) VALUES ('meta_audiences_on', 'false'), ('meta_audiences_last', '')
ON CONFLICT (key) DO NOTHING;

-- Indian cities to their state (Meta reports location by state); used only to match form answers to Meta regions.
CREATE TABLE IF NOT EXISTS public.ads_geo_in (city text PRIMARY KEY, state text NOT NULL);
ALTER TABLE public.ads_geo_in ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_geo_in FROM anon, authenticated;
INSERT INTO public.ads_geo_in (city, state) VALUES
  ('delhi', 'Delhi'), ('new delhi', 'Delhi'), ('noida', 'Uttar Pradesh'), ('greater noida', 'Uttar Pradesh'), ('ghaziabad', 'Uttar Pradesh'),
  ('gurgaon', 'Haryana'), ('gurugram', 'Haryana'), ('faridabad', 'Haryana'), ('sonipat', 'Haryana'), ('panipat', 'Haryana'), ('karnal', 'Haryana'),
  ('ambala', 'Haryana'), ('rohtak', 'Haryana'), ('hisar', 'Haryana'), ('chandigarh', 'Chandigarh'), ('mohali', 'Punjab'), ('ludhiana', 'Punjab'),
  ('amritsar', 'Punjab'), ('jalandhar', 'Punjab'), ('patiala', 'Punjab'), ('jaipur', 'Rajasthan'), ('jodhpur', 'Rajasthan'), ('udaipur', 'Rajasthan'),
  ('kota', 'Rajasthan'), ('ajmer', 'Rajasthan'), ('bikaner', 'Rajasthan'), ('lucknow', 'Uttar Pradesh'), ('kanpur', 'Uttar Pradesh'),
  ('agra', 'Uttar Pradesh'), ('meerut', 'Uttar Pradesh'), ('varanasi', 'Uttar Pradesh'), ('prayagraj', 'Uttar Pradesh'), ('allahabad', 'Uttar Pradesh'),
  ('bareilly', 'Uttar Pradesh'), ('aligarh', 'Uttar Pradesh'), ('gorakhpur', 'Uttar Pradesh'), ('dehradun', 'Uttarakhand'), ('haridwar', 'Uttarakhand'),
  ('haldwani', 'Uttarakhand'), ('shimla', 'Himachal Pradesh'), ('jammu', 'Jammu and Kashmir'), ('srinagar', 'Jammu and Kashmir'),
  ('mumbai', 'Maharashtra'), ('pune', 'Maharashtra'), ('nagpur', 'Maharashtra'), ('nashik', 'Maharashtra'), ('thane', 'Maharashtra'),
  ('navi mumbai', 'Maharashtra'), ('aurangabad', 'Maharashtra'), ('ahmedabad', 'Gujarat'), ('surat', 'Gujarat'), ('vadodara', 'Gujarat'),
  ('rajkot', 'Gujarat'), ('bhopal', 'Madhya Pradesh'), ('indore', 'Madhya Pradesh'), ('gwalior', 'Madhya Pradesh'), ('jabalpur', 'Madhya Pradesh'),
  ('raipur', 'Chhattisgarh'), ('patna', 'Bihar'), ('gaya', 'Bihar'), ('ranchi', 'Jharkhand'), ('jamshedpur', 'Jharkhand'), ('dhanbad', 'Jharkhand'),
  ('kolkata', 'West Bengal'), ('siliguri', 'West Bengal'), ('bhubaneswar', 'Odisha'), ('cuttack', 'Odisha'), ('guwahati', 'Assam'),
  ('bengaluru', 'Karnataka'), ('bangalore', 'Karnataka'), ('mysuru', 'Karnataka'), ('mysore', 'Karnataka'), ('mangaluru', 'Karnataka'),
  ('hyderabad', 'Telangana'), ('secunderabad', 'Telangana'), ('warangal', 'Telangana'), ('visakhapatnam', 'Andhra Pradesh'), ('vijayawada', 'Andhra Pradesh'),
  ('chennai', 'Tamil Nadu'), ('coimbatore', 'Tamil Nadu'), ('madurai', 'Tamil Nadu'), ('kochi', 'Kerala'), ('thiruvananthapuram', 'Kerala'),
  ('kozhikode', 'Kerala'), ('goa', 'Goa'), ('panaji', 'Goa')
ON CONFLICT (city) DO NOTHING;

-- ------------------------------------------------------------------------------------------- funnel map
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

-- ------------------------------------------------------------------------------------------- location focus
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

-- ------------------------------------------------------------------------------------------- audience library
-- People in a CRM list, hashed as Meta asks (phone digits with country code; email lower-case). Only people whose consent
-- rule allows sharing (the Conversions API rule of their Meta source; anyone else needs ad-data-sharing consent granted).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_audience_people(p_spec jsonb)
RETURNS TABLE (ph text, em text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT DISTINCT crm_private.ads_sha256(regexp_replace(l.phone_e164, '\D', '', 'g')),
         CASE WHEN l.email ~ '@' THEN crm_private.ads_sha256(lower(btrim(l.email))) END
    FROM public.ads_lead l
    JOIN public.ads_stage_def sd ON sd.pipeline = l.pipeline AND sd.stage = l.stage
    LEFT JOIN LATERAL crm_private.ads_meta_lead_source(l) src ON true
    LEFT JOIN public.ads_meta_settings ms ON ms.source = src.source
    LEFT JOIN public.ads_lead_score sc ON sc.ads_lead_id = l.id
   WHERE l.deleted_at IS NULL AND l.anonymised_at IS NULL AND NOT l.quarantined AND l.contact_status <> 'wrong_number'
     AND crm_private.ads_meta_consent_ok(coalesce(ms.consent_mode, 'required'), coalesce(ms.consent_purpose, 'ad_data_sharing'), l.phone_e164)
     AND CASE p_spec->>'segment'
       WHEN 'leads' THEN l.created_at > now() - make_interval(days => coalesce((p_spec->>'days')::int, 30))
       WHEN 'open' THEN l.created_at > now() - make_interval(days => coalesce((p_spec->>'days')::int, 180))
                    AND l.created_at < now() - make_interval(days => coalesce((p_spec->>'min_days')::int, 0))
                    AND sd.ord < 40 AND l.stage <> 'lost' AND NOT sd.is_customer
       WHEN 'lost' THEN l.stage = 'lost' AND l.created_at > now() - make_interval(days => coalesce((p_spec->>'days')::int, 365))
       WHEN 'qualified' THEN sd.ord >= 40 AND l.stage <> 'lost' AND l.created_at > now() - make_interval(days => coalesce((p_spec->>'days')::int, 365))
       WHEN 'hot' THEN sc.band = 'hot' AND l.created_at > now() - make_interval(days => coalesce((p_spec->>'days')::int, 90))
       WHEN 'customers' THEN sd.is_customer
       ELSE false END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_audiences() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object('on', crm_private.ads_cfg('meta_audiences_on') = 'true',
    'last', nullif(crm_private.ads_cfg('meta_audiences_last'), '')::jsonb,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'account_id', (crm_private.ads_meta_acct()).external_id,
    'audiences', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', a.key, 'name', a.name, 'kind', a.kind, 'stage', a.stage, 'use_as', a.use_as,
        'why', a.why, 'enabled', a.enabled, 'exclude_default', a.exclude_default, 'meta_id', a.meta_id, 'status', a.status,
        'size_low', a.size_low, 'size_high', a.size_high, 'members', a.members, 'detail', a.detail, 'synced_at', a.synced_at,
        'eligible', CASE WHEN a.kind = 'crm' THEN (SELECT count(*) FROM crm_private.ads_meta_audience_people(a.spec)) END)
        ORDER BY array_position(ARRAY['hot', 'engaged', 'lead', 'qualified', 'customer'], a.stage), a.key), '[]')
      FROM public.ads_meta_audience a));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_audience_save(p_key text, p_enabled boolean, p_exclude_default boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  UPDATE public.ads_meta_audience SET enabled = coalesce(p_enabled, enabled), exclude_default = coalesce(p_exclude_default, exclude_default),
    status = CASE WHEN coalesce(p_enabled, enabled) THEN CASE WHEN status = 'off' THEN 'planned' ELSE status END ELSE 'off' END, updated_at = now()
   WHERE key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown audience' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.ads_log('meta_audience_saved', 'meta_audience', p_key, jsonb_build_object('enabled', p_enabled, 'exclude_default', p_exclude_default));
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_audiences_on(p_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  PERFORM crm_private.ads_meta_set_cfg('meta_audiences_on', CASE WHEN p_on THEN 'true' ELSE 'false' END);
  PERFORM crm_private.ads_log(CASE WHEN p_on THEN 'meta_audiences_on' ELSE 'meta_audiences_off' END, 'meta_audience', 'all', '{}');
  RETURN jsonb_build_object('ok', true, 'on', p_on);
END $$;

-- What the daily audience job needs (service role). Contact details are already hashed here.
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

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audience_saved(p_key text, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_audience SET
    meta_id = coalesce(substring(p_data->>'meta_id' FROM '^[0-9]{5,25}$'), meta_id),
    status = CASE WHEN p_data->>'status' IN ('ready', 'error') THEN p_data->>'status' ELSE status END,
    size_low = CASE WHEN p_data ? 'size_low' THEN nullif(p_data->>'size_low', '')::bigint ELSE size_low END,
    size_high = CASE WHEN p_data ? 'size_high' THEN nullif(p_data->>'size_high', '')::bigint ELSE size_high END,
    members = CASE WHEN p_data ? 'members' THEN (p_data->>'members')::int ELSE members END,
    detail = left(p_data->>'detail', 600), synced_at = now(), updated_at = now()
   WHERE key = p_key $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_audiences_done(p_summary jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_meta_set_cfg('meta_audiences_last', (p_summary || jsonb_build_object('at', now()))::text) $$;

-- The Strategy's "Create in Meta" now gets the ready audiences (by key) and the default exclusions.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; acc public.ads_accounts := crm_private.ads_meta_acct();
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL OR coalesce(s.build->>'status', '') NOT IN ('queued', 'running', 'error', 'partial') OR s.approved_version IS NULL THEN RETURN NULL; END IF;
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('status', 'running', 'at', now()) WHERE id = p_id;
  RETURN jsonb_build_object('strategy_id', s.id, 'version', s.approved_version, 'account_id', acc.external_id, 'currency', acc.currency,
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''), 'goal', s.goal,
    'plan', (SELECT v.plan FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.approved_version),
    'steps', coalesce(s.build->'steps', '{}'), 'images', coalesce(s.build->'images', '{}'),
    'audiences', (SELECT coalesce(jsonb_object_agg(a.key, a.meta_id), '{}') FROM public.ads_meta_audience a WHERE a.enabled AND a.status = 'ready' AND a.meta_id IS NOT NULL),
    'default_excludes', (SELECT coalesce(jsonb_agg(a.meta_id), '[]') FROM public.ads_meta_audience a
                          WHERE a.enabled AND a.exclude_default AND a.status = 'ready' AND a.meta_id IS NOT NULL));
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_audience_people(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.api_ads_meta_audiences(),
  public.api_ads_meta_audience_save(text, boolean, boolean), public.api_ads_meta_audiences_on(boolean),
  public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_audiences_done(jsonb),
  public.svc_ads_meta_build_work(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_funnel(date, date), public.api_ads_meta_geo(date, date), public.api_ads_meta_audiences(),
  public.api_ads_meta_audience_save(text, boolean, boolean), public.api_ads_meta_audiences_on(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_audience_work(), public.svc_ads_meta_audience_saved(text, jsonb), public.svc_ads_meta_audiences_done(jsonb),
  public.svc_ads_meta_build_work(bigint) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '107')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- Daily at 02:50 IST, only when Admin turned audiences on.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-audiences';
    PERFORM cron.schedule('crm-ads-meta-audiences', '20 21 * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_audiences"]}'::jsonb, timeout_milliseconds := 120000)
      WHERE crm_private.ads_cfg('meta_audiences_on') = 'true' AND (crm_private.ads_meta_acct()).id IS NOT NULL
    $job$);
  END IF;
END $$;
