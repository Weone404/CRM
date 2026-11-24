-- 139: CRM > Google > Google My Business. Insights for any number of Google Business Profiles, from Google's own APIs only:
-- how many people saw each profile (Search / Maps, phone / computer), what they did (calls, website, directions, messages,
-- bookings), the words they searched, and the reviews. Collected by the crm-google-business Edge Function (nightly and on
-- "Refresh"). Also the small summary behind the three cards of CRM > Google (Website, Google My Business, Google Ads).
--
-- Many profiles, many Google logins: each login ("connection") is a Google refresh token with the business.manage scope,
-- kept in Vault (never returned to the browser). Every profile that login manages is listed; the ones marked "tracked" are
-- collected. The OAuth client is the one already saved for Google (Vault: ads_google_ads_client_id / _secret).
-- Google keeps these APIs at quota 0 until it approves the Cloud project; that state is shown as "Waiting for Google".
-- Nothing outside the gbp_* tables is changed; other modules are only read (for the hub cards), and only if installed.
-- Re-runnable. Rollback: 139_crm_google_business_down.sql.

-- ---------------------------------------------------------------- tables (read only through the functions below)
CREATE TABLE IF NOT EXISTS public.gbp_connection (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL CHECK (length(btrim(label)) BETWEEN 2 AND 60),
  email text,                                     -- the Google user, filled in when the sign-in is tested (not a secret)
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'connected', 'waiting_google', 'needs_signin', 'api_off', 'no_access', 'error')),
  error text, last_ok_at timestamptz, checked_at timestamptz,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.gbp_location (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id uuid NOT NULL REFERENCES public.gbp_connection(id) ON DELETE CASCADE,
  account text NOT NULL CHECK (account ~ '^accounts/[0-9]+$'),
  name text NOT NULL CHECK (name ~ '^locations/[0-9]+$'),
  title text, address text, phone text, website text, category text, maps_uri text, place_id text, verified boolean,
  tracked boolean NOT NULL DEFAULT false,
  rating numeric(3,2), reviews_total int, synced_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connection_id, name));
CREATE TABLE IF NOT EXISTS public.gbp_metric_daily (
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE,
  day date NOT NULL, metric text NOT NULL CHECK (metric ~ '^[A-Z_]{3,60}$'), value bigint NOT NULL DEFAULT 0 CHECK (value >= 0),
  PRIMARY KEY (location_id, day, metric));
CREATE TABLE IF NOT EXISTS public.gbp_keyword_monthly (
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE,
  month date NOT NULL CHECK (extract(day FROM month) = 1), keyword text NOT NULL,
  impressions bigint, below bigint,               -- Google gives a count, or only "fewer than <below>" for rare words
  PRIMARY KEY (location_id, month, keyword));
CREATE TABLE IF NOT EXISTS public.gbp_review (
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE,
  review_id text NOT NULL, reviewer text, stars int CHECK (stars BETWEEN 1 AND 5), comment text,
  created_at timestamptz, updated_at timestamptz, reply text, reply_at timestamptz, seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (location_id, review_id));
CREATE INDEX IF NOT EXISTS idx_gbp_review_time ON public.gbp_review (location_id, created_at DESC);
CREATE TABLE IF NOT EXISTS public.gbp_run (
  id bigserial PRIMARY KEY, job text NOT NULL, status text NOT NULL DEFAULT 'running', detail text,
  started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_gbp_run_job ON public.gbp_run (job, started_at DESC);
ALTER TABLE public.gbp_connection ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_metric_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_keyword_monthly ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_run ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gbp_connection, public.gbp_location, public.gbp_metric_daily, public.gbp_keyword_monthly, public.gbp_review, public.gbp_run FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.gbp_run_id_seq FROM anon, authenticated;

-- ---------------------------------------------------------------- helpers
-- Who may look: Admin, and anyone with access to the ADS sections. Who may refresh or pick profiles: Admin and ADS approvers.
CREATE OR REPLACE FUNCTION crm_private.gbp_can_view() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE ok boolean := false;
BEGIN
  IF crm_private.is_admin() THEN RETURN true; END IF;
  IF to_regprocedure('crm_private.ads_can_view()') IS NOT NULL THEN EXECUTE 'SELECT crm_private.ads_can_view()' INTO ok; END IF;
  RETURN coalesce(ok, false);
END $$;
CREATE OR REPLACE FUNCTION crm_private.gbp_can_run() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE ok boolean := false;
BEGIN
  IF crm_private.is_admin() THEN RETURN true; END IF;
  IF to_regprocedure('crm_private.ads_can_approve()') IS NOT NULL THEN EXECUTE 'SELECT crm_private.ads_can_approve()' INTO ok; END IF;
  RETURN coalesce(ok, false);
END $$;
CREATE OR REPLACE FUNCTION crm_private.gbp_secret_name(p_connection uuid) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT 'crm_gbp_refresh_' || replace(p_connection::text, '-', '') $$;

-- Sums for a set of profiles over a date range. "views" = people who saw the profile (Google counts a person once a day per surface).
CREATE OR REPLACE FUNCTION crm_private.gbp_totals(p_ids uuid[], p_from date, p_to date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH t AS (
    SELECT coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_IMPRESSIONS_MOBILE_SEARCH'), 0) sm,
           coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_IMPRESSIONS_DESKTOP_SEARCH'), 0) sd,
           coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_IMPRESSIONS_MOBILE_MAPS'), 0) mm,
           coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_IMPRESSIONS_DESKTOP_MAPS'), 0) md,
           coalesce(sum(value) FILTER (WHERE metric = 'CALL_CLICKS'), 0) calls,
           coalesce(sum(value) FILTER (WHERE metric = 'WEBSITE_CLICKS'), 0) website,
           coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_DIRECTION_REQUESTS'), 0) directions,
           coalesce(sum(value) FILTER (WHERE metric IN ('MESSAGING_CLICKS', 'BUSINESS_CONVERSATIONS')), 0) messages,
           coalesce(sum(value) FILTER (WHERE metric = 'BUSINESS_BOOKINGS'), 0) bookings,
           count(DISTINCT day) days
      FROM public.gbp_metric_daily WHERE location_id = ANY (p_ids) AND day BETWEEN p_from AND p_to)
  SELECT jsonb_build_object('views', sm + sd + mm + md, 'search', sm + sd, 'maps', mm + md, 'mobile', sm + mm, 'desktop', sd + md,
    'search_mobile', sm, 'search_desktop', sd, 'maps_mobile', mm, 'maps_desktop', md,
    'calls', calls, 'website', website, 'directions', directions, 'messages', messages, 'bookings', bookings,
    'actions', calls + website + directions + messages + bookings, 'days', days) FROM t
$$;

-- One row per day of the range (days without data are 0, so the chart has no gaps).
CREATE OR REPLACE FUNCTION crm_private.gbp_days(p_ids uuid[], p_from date, p_to date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('d', g.d::date,
      'views', coalesce(x.views, 0), 'search', coalesce(x.search, 0), 'maps', coalesce(x.maps, 0),
      'calls', coalesce(x.calls, 0), 'website', coalesce(x.website, 0), 'directions', coalesce(x.directions, 0),
      'messages', coalesce(x.messages, 0), 'actions', coalesce(x.actions, 0)) ORDER BY g.d), '[]')
    FROM generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g(d)
    LEFT JOIN (
      SELECT day,
             sum(value) FILTER (WHERE metric LIKE 'BUSINESS\_IMPRESSIONS\_%') views,
             sum(value) FILTER (WHERE metric LIKE 'BUSINESS\_IMPRESSIONS\_%\_SEARCH') search,
             sum(value) FILTER (WHERE metric LIKE 'BUSINESS\_IMPRESSIONS\_%\_MAPS') maps,
             sum(value) FILTER (WHERE metric = 'CALL_CLICKS') calls,
             sum(value) FILTER (WHERE metric = 'WEBSITE_CLICKS') website,
             sum(value) FILTER (WHERE metric = 'BUSINESS_DIRECTION_REQUESTS') directions,
             sum(value) FILTER (WHERE metric IN ('MESSAGING_CLICKS', 'BUSINESS_CONVERSATIONS')) messages,
             sum(value) FILTER (WHERE metric IN ('CALL_CLICKS', 'WEBSITE_CLICKS', 'BUSINESS_DIRECTION_REQUESTS', 'MESSAGING_CLICKS', 'BUSINESS_CONVERSATIONS', 'BUSINESS_BOOKINGS')) actions
        FROM public.gbp_metric_daily WHERE location_id = ANY (p_ids) AND day BETWEEN p_from AND p_to GROUP BY day) x ON x.day = g.d::date
   WHERE p_from <= p_to
$$;

-- ---------------------------------------------------------------- browser API
CREATE OR REPLACE FUNCTION public.api_gbp_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.gbp_can_view(), 'can_run', crm_private.gbp_can_run(), 'is_admin', crm_private.is_admin()) $$;

-- Everything the Google My Business screen shows. p_location NULL = all tracked profiles together. p_days 7-180.
CREATE OR REPLACE FUNCTION public.api_gbp_overview(p_location uuid DEFAULT NULL, p_days int DEFAULT 28) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := least(180, greatest(7, coalesce(p_days, 28))); ids uuid[]; last_day date; d1 date; d0 date; p1 date; p0 date;
        km date; kp date; sel uuid;
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  SELECT l.id INTO sel FROM public.gbp_location l WHERE l.id = p_location AND l.tracked;          -- an unknown or untracked id means "all"
  SELECT coalesce(array_agg(l.id), '{}') INTO ids FROM public.gbp_location l WHERE l.tracked AND (sel IS NULL OR l.id = sel);
  SELECT max(day) INTO last_day FROM public.gbp_metric_daily WHERE location_id = ANY (ids);
  d1 := coalesce(last_day, current_date - 3); d0 := d1 - (n - 1); p1 := d0 - 1; p0 := p1 - (n - 1);
  SELECT max(month) INTO km FROM public.gbp_keyword_monthly WHERE location_id = ANY (ids);
  kp := (km - interval '1 month')::date;
  RETURN jsonb_build_object(
    'access', public.api_gbp_access(),
    'setup', jsonb_build_object(
      'client', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'ads_google_ads_client_id') AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'ads_google_ads_client_secret'),
      'connections', (SELECT count(*) FROM public.gbp_connection),
      'connected', (SELECT count(*) FROM public.gbp_connection WHERE status = 'connected'),
      'waiting_google', EXISTS (SELECT 1 FROM public.gbp_connection WHERE status = 'waiting_google'),
      'locations', (SELECT count(*) FROM public.gbp_location),
      'tracked', (SELECT count(*) FROM public.gbp_location WHERE tracked),
      'has_data', last_day IS NOT NULL),
    'connections', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'label', c.label, 'email', c.email, 'status', c.status, 'error', c.error,
        'last_ok_at', c.last_ok_at, 'checked_at', c.checked_at,
        'locations', (SELECT count(*) FROM public.gbp_location l WHERE l.connection_id = c.id),
        'tracked', (SELECT count(*) FROM public.gbp_location l WHERE l.connection_id = c.id AND l.tracked)) ORDER BY c.created_at), '[]')
      FROM public.gbp_connection c),
    'locations', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'connection_id', l.connection_id, 'title', coalesce(l.title, l.name), 'address', l.address,
        'category', l.category, 'phone', l.phone, 'website', l.website, 'maps_uri', l.maps_uri, 'verified', l.verified, 'tracked', l.tracked,
        'rating', l.rating, 'reviews_total', l.reviews_total, 'synced_at', l.synced_at) ORDER BY l.tracked DESC, l.title), '[]')
      FROM public.gbp_location l),
    'selected', sel,
    'period', jsonb_build_object('days', n, 'from', d0, 'to', d1, 'prev_from', p0, 'prev_to', p1, 'last_day', last_day),
    'totals', crm_private.gbp_totals(ids, d0, d1),
    'prev', crm_private.gbp_totals(ids, p0, p1),
    'days', crm_private.gbp_days(ids, d0, d1),
    'prev_days', crm_private.gbp_days(ids, p0, p1),
    'weekdays', (SELECT coalesce(jsonb_agg(jsonb_build_object('dow', w.dow, 'views', w.views, 'actions', w.actions) ORDER BY w.dow), '[]') FROM (
        SELECT extract(dow FROM day)::int dow,
               coalesce(sum(value) FILTER (WHERE metric LIKE 'BUSINESS\_IMPRESSIONS\_%'), 0) views,
               coalesce(sum(value) FILTER (WHERE metric NOT LIKE 'BUSINESS\_IMPRESSIONS\_%'), 0) actions
          FROM public.gbp_metric_daily WHERE location_id = ANY (ids) AND day BETWEEN d0 AND d1 GROUP BY 1) w),
    'keywords', jsonb_build_object('month', km, 'prev_month', CASE WHEN km IS NOT NULL THEN kp END,
      'count', (SELECT count(DISTINCT keyword) FROM public.gbp_keyword_monthly WHERE location_id = ANY (ids) AND month = km),
      'rows', (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.v DESC NULLS LAST, q.below DESC NULLS LAST, q.k), '[]') FROM (
          SELECT c.keyword k, sum(c.impressions) v, max(c.below) FILTER (WHERE c.impressions IS NULL) below,
                 (SELECT sum(p.impressions) FROM public.gbp_keyword_monthly p WHERE p.location_id = ANY (ids) AND p.month = kp AND p.keyword = c.keyword) pv
            FROM public.gbp_keyword_monthly c WHERE c.location_id = ANY (ids) AND c.month = km
           GROUP BY c.keyword ORDER BY sum(c.impressions) DESC NULLS LAST, c.keyword LIMIT 60) q)),
    'reviews', jsonb_build_object(
      'total', (SELECT coalesce(sum(coalesce(l.reviews_total, 0)), 0) FROM public.gbp_location l WHERE l.id = ANY (ids)),
      'rating', (SELECT round(sum(l.rating * l.reviews_total) / nullif(sum(l.reviews_total), 0), 2) FROM public.gbp_location l
                  WHERE l.id = ANY (ids) AND l.rating IS NOT NULL AND coalesce(l.reviews_total, 0) > 0),
      'stored', (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = ANY (ids)),
      'by_star', (SELECT coalesce(jsonb_object_agg(s.n, (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = ANY (ids) AND r.stars = s.n)), '{}')
                    FROM generate_series(1, 5) s(n)),
      'unreplied', (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = ANY (ids) AND r.reply IS NULL),
      'new', (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = ANY (ids) AND r.created_at::date BETWEEN d0 AND d1),
      'new_prev', (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = ANY (ids) AND r.created_at::date BETWEEN p0 AND p1),
      'latest', (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
          SELECT r.review_id, coalesce(l.title, l.name) AS profile, r.reviewer, r.stars, left(r.comment, 600) AS comment, r.created_at, left(r.reply, 600) AS reply, r.reply_at
            FROM public.gbp_review r JOIN public.gbp_location l ON l.id = r.location_id
           WHERE r.location_id = ANY (ids) ORDER BY r.created_at DESC NULLS LAST LIMIT 8) z)),
    'runs', (SELECT coalesce(jsonb_object_agg(x.job, jsonb_build_object('status', x.status, 'detail', x.detail, 'at', coalesce(x.finished_at, x.started_at))), '{}')
               FROM (SELECT DISTINCT ON (job) job, status, detail, started_at, finished_at FROM public.gbp_run ORDER BY job, started_at DESC) x));
END $$;

-- The reviews list. p_filter: all | unreplied | low (1-3 stars).
CREATE OR REPLACE FUNCTION public.api_gbp_reviews(p_location uuid DEFAULT NULL, p_filter text DEFAULT 'all', p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
    SELECT r.review_id, r.location_id, coalesce(l.title, l.name) AS profile, r.reviewer, r.stars, r.comment, r.created_at, r.updated_at, r.reply, r.reply_at
      FROM public.gbp_review r JOIN public.gbp_location l ON l.id = r.location_id
     WHERE l.tracked AND (p_location IS NULL OR r.location_id = p_location)
       AND CASE coalesce(p_filter, 'all') WHEN 'unreplied' THEN r.reply IS NULL WHEN 'low' THEN r.stars <= 3 ELSE true END
     ORDER BY r.created_at DESC NULLS LAST LIMIT least(500, greatest(1, coalesce(p_limit, 100)))) z);
END $$;

-- Add a Google login. The refresh token goes straight into Vault and is never returned.
CREATE OR REPLACE FUNCTION public.api_gbp_connection_add(p_label text, p_refresh_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE lab text := btrim(coalesce(p_label, '')); tok text := btrim(coalesce(p_refresh_token, '')); cid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can add a Google login' USING ERRCODE = 'PT403'; END IF;
  IF length(lab) NOT BETWEEN 2 AND 60 OR lab ~ '[<>]' THEN RAISE EXCEPTION 'Give this login a name of 2 to 60 characters (for example "We One Aviation")' USING ERRCODE = 'PT422'; END IF;
  IF tok !~ '^1//[A-Za-z0-9_-]+$' OR length(tok) NOT BETWEEN 33 AND 512 THEN RAISE EXCEPTION 'That is not a Google refresh token (it starts with 1// and has no spaces)' USING ERRCODE = 'PT422'; END IF;
  IF (SELECT count(*) FROM public.gbp_connection) >= 20 THEN RAISE EXCEPTION 'At most 20 Google logins; remove one first' USING ERRCODE = 'PT422'; END IF;
  IF EXISTS (SELECT 1 FROM public.gbp_connection WHERE lower(label) = lower(lab)) THEN RAISE EXCEPTION 'A login named "%" already exists', lab USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.gbp_connection (label, created_by) VALUES (lab, crm_private.current_employee_id()) RETURNING id INTO cid;
  PERFORM vault.create_secret(tok, crm_private.gbp_secret_name(cid), 'CRM Google My Business: refresh token for "' || lab || '"');
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, ''gbp_connection_added'', ''google_business'', $2)'
      USING crm_private.current_employee_id(), jsonb_build_object('id', cid, 'label', lab);
  END IF;
  RETURN jsonb_build_object('id', cid);
END $$;

-- Replace the token of a login (after Google says "sign in again").
CREATE OR REPLACE FUNCTION public.api_gbp_connection_token(p_id uuid, p_refresh_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE tok text := btrim(coalesce(p_refresh_token, '')); sid uuid; nm text := crm_private.gbp_secret_name(p_id);
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change a Google login' USING ERRCODE = 'PT403'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gbp_connection WHERE id = p_id) THEN RAISE EXCEPTION 'That Google login no longer exists' USING ERRCODE = 'PT404'; END IF;
  IF tok !~ '^1//[A-Za-z0-9_-]+$' OR length(tok) NOT BETWEEN 33 AND 512 THEN RAISE EXCEPTION 'That is not a Google refresh token (it starts with 1// and has no spaces)' USING ERRCODE = 'PT422'; END IF;
  SELECT id INTO sid FROM vault.secrets WHERE name = nm;
  IF sid IS NULL THEN PERFORM vault.create_secret(tok, nm, 'CRM Google My Business: refresh token'); ELSE PERFORM vault.update_secret(sid, tok); END IF;
  UPDATE public.gbp_connection SET status = 'new', error = NULL WHERE id = p_id;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, ''gbp_connection_token_replaced'', ''google_business'', $2)'
      USING crm_private.current_employee_id(), jsonb_build_object('id', p_id);
  END IF;
  RETURN jsonb_build_object('saved', true);
END $$;

-- Remove a login with its token, its profiles and everything collected for them.
CREATE OR REPLACE FUNCTION public.api_gbp_connection_remove(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE lab text;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can remove a Google login' USING ERRCODE = 'PT403'; END IF;
  DELETE FROM public.gbp_connection WHERE id = p_id RETURNING label INTO lab;
  IF lab IS NULL THEN RETURN jsonb_build_object('removed', false); END IF;
  DELETE FROM vault.secrets WHERE name = crm_private.gbp_secret_name(p_id);
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, ''gbp_connection_removed'', ''google_business'', $2)'
      USING crm_private.current_employee_id(), jsonb_build_object('id', p_id, 'label', lab);
  END IF;
  RETURN jsonb_build_object('removed', true);
END $$;

-- Start or stop collecting one profile. Stopping keeps what was collected.
CREATE OR REPLACE FUNCTION public.api_gbp_location_track(p_id uuid, p_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can choose which profiles are tracked' USING ERRCODE = 'PT403'; END IF;
  IF p_on IS NULL THEN RAISE EXCEPTION 'Say on or off' USING ERRCODE = 'PT422'; END IF;
  IF p_on AND (SELECT count(*) FROM public.gbp_location WHERE tracked AND id <> p_id) >= 50 THEN
    RAISE EXCEPTION 'At most 50 tracked profiles' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.gbp_location SET tracked = p_on WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That profile no longer exists' USING ERRCODE = 'PT404'; END IF;
  RETURN jsonb_build_object('tracked', p_on);
END $$;

-- The three cards of CRM > Google. Each part is NULL when that module is not installed.
CREATE OR REPLACE FUNCTION public.api_google_hub() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE web jsonb; ads jsonb; gbp jsonb; ids uuid[]; d1 date;
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to the Google section' USING ERRCODE = 'PT403'; END IF;
  IF to_regclass('public.web_row') IS NOT NULL THEN
    EXECUTE $q$ SELECT jsonb_build_object(
        'clicks', (SELECT sum((m->>'clicks')::numeric) FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'cur'),
        'clicks_prev', (SELECT sum((m->>'clicks')::numeric) FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'prev'),
        'impressions', (SELECT sum((m->>'impressions')::numeric) FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'cur'),
        'visitors', (SELECT sum((m->>'activeUsers')::numeric) FROM public.web_row WHERE src = 'ga' AND kind = 'date' AND win = 'cur'),
        'at', (SELECT max(at) FROM public.web_row)) $q$ INTO web;
  END IF;
  IF to_regclass('public.ads_metrics_daily') IS NOT NULL AND to_regclass('public.ads_accounts') IS NOT NULL THEN
    EXECUTE $q$ SELECT jsonb_build_object(
        'spend', coalesce(sum(m.spend), 0), 'clicks', coalesce(sum(m.clicks), 0), 'impressions', coalesce(sum(m.impressions), 0),
        'last_spend_day', max(m.day) FILTER (WHERE m.spend > 0),
        'account_status', (SELECT a.status FROM public.ads_accounts a WHERE a.platform = 'google' ORDER BY a.created_at LIMIT 1))
      FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
     WHERE a.platform = 'google' AND m.day > current_date - 28 $q$ INTO ads;
  END IF;
  SELECT coalesce(array_agg(id), '{}') INTO ids FROM public.gbp_location WHERE tracked;
  SELECT max(day) INTO d1 FROM public.gbp_metric_daily WHERE location_id = ANY (ids);
  gbp := jsonb_build_object('connections', (SELECT count(*) FROM public.gbp_connection), 'tracked', cardinality(ids),
    'waiting_google', EXISTS (SELECT 1 FROM public.gbp_connection WHERE status = 'waiting_google'),
    'last_day', d1,
    'totals', CASE WHEN d1 IS NOT NULL THEN crm_private.gbp_totals(ids, d1 - 27, d1) END,
    'prev', CASE WHEN d1 IS NOT NULL THEN crm_private.gbp_totals(ids, d1 - 55, d1 - 28) END,
    'rating', (SELECT round(sum(l.rating * l.reviews_total) / nullif(sum(l.reviews_total), 0), 2) FROM public.gbp_location l
                WHERE l.id = ANY (ids) AND l.rating IS NOT NULL AND coalesce(l.reviews_total, 0) > 0),
    'reviews', (SELECT coalesce(sum(coalesce(l.reviews_total, 0)), 0) FROM public.gbp_location l WHERE l.id = ANY (ids)));
  RETURN jsonb_build_object('website', web, 'ads', ads, 'gbp', gbp);
END $$;

-- ---------------------------------------------------------------- service API (crm-google-business Edge Function only)
-- Logins with their tokens, and the profiles to collect. p_connection limits it to one login.
CREATE OR REPLACE FUNCTION public.svc_gbp_work(p_connection uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'client_id', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_id'),
    'client_secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_secret'),
    'connections', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'label', c.label,
        'refresh_token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = crm_private.gbp_secret_name(c.id)),
        'locations', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'account', l.account, 'name', l.name,
              'first', NOT EXISTS (SELECT 1 FROM public.gbp_metric_daily m WHERE m.location_id = l.id),
              'reviews_stored', (SELECT count(*) FROM public.gbp_review r WHERE r.location_id = l.id),
              'keyword_months', (SELECT coalesce(jsonb_agg(DISTINCT k.month), '[]') FROM public.gbp_keyword_monthly k WHERE k.location_id = l.id))
            ORDER BY l.title), '[]') FROM public.gbp_location l WHERE l.connection_id = c.id AND l.tracked)) ORDER BY c.created_at), '[]')
      FROM public.gbp_connection c WHERE p_connection IS NULL OR c.id = p_connection))
$$;

CREATE OR REPLACE FUNCTION public.svc_gbp_connection_status(p_id uuid, p_status text, p_error text DEFAULT NULL, p_email text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.gbp_connection SET status = p_status, error = CASE WHEN p_status = 'connected' THEN NULL ELSE left(p_error, 500) END,
    email = coalesce(nullif(left(p_email, 200), ''), email), checked_at = now(),
    last_ok_at = CASE WHEN p_status = 'connected' THEN now() ELSE last_ok_at END
   WHERE id = p_id $$;

-- The profiles a login manages. New ones are added (a login with a single profile gets it tracked at once); details are refreshed.
CREATE OR REPLACE FUNCTION public.svc_gbp_locations_save(p_connection uuid, p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; solo boolean;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' OR NOT EXISTS (SELECT 1 FROM public.gbp_connection WHERE id = p_connection) THEN RETURN 0; END IF;
  solo := jsonb_array_length(p_rows) = 1 AND NOT EXISTS (SELECT 1 FROM public.gbp_location WHERE connection_id = p_connection);
  INSERT INTO public.gbp_location (connection_id, account, name, title, address, phone, website, category, maps_uri, place_id, verified, tracked)
  SELECT p_connection, r->>'account', r->>'name', left(r->>'title', 200), left(r->>'address', 400), left(r->>'phone', 40), left(r->>'website', 300),
         left(r->>'category', 120), left(r->>'maps_uri', 400), left(r->>'place_id', 120), (r->>'verified')::boolean, solo
    FROM jsonb_array_elements(p_rows) r
   WHERE jsonb_typeof(r) = 'object' AND r->>'account' ~ '^accounts/[0-9]+$' AND r->>'name' ~ '^locations/[0-9]+$'
  ON CONFLICT (connection_id, name) DO UPDATE SET account = EXCLUDED.account, title = EXCLUDED.title, address = EXCLUDED.address, phone = EXCLUDED.phone,
    website = EXCLUDED.website, category = EXCLUDED.category, maps_uri = EXCLUDED.maps_uri, place_id = EXCLUDED.place_id, verified = EXCLUDED.verified;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Daily numbers: [{d, m, v}]. Later runs overwrite the same days (Google revises the last few days).
CREATE OR REPLACE FUNCTION public.svc_gbp_metrics_save(p_location uuid, p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' THEN RETURN 0; END IF;
  INSERT INTO public.gbp_metric_daily (location_id, day, metric, value)
  SELECT p_location, (r->>'d')::date, r->>'m', greatest(0, (r->>'v')::bigint)
    FROM jsonb_array_elements(p_rows) r
   WHERE r->>'d' ~ '^\d{4}-\d{2}-\d{2}$' AND r->>'m' ~ '^[A-Z_]{3,60}$' AND r->>'v' ~ '^\d{1,15}$'
  ON CONFLICT (location_id, day, metric) DO UPDATE SET value = EXCLUDED.value;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE public.gbp_location SET synced_at = now() WHERE id = p_location;
  RETURN n;
END $$;

-- One month of search words for one profile (replaces that month): [{k, v | below}].
CREATE OR REPLACE FUNCTION public.svc_gbp_keywords_save(p_location uuid, p_month date, p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; mo date := date_trunc('month', p_month)::date;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' THEN RETURN 0; END IF;
  DELETE FROM public.gbp_keyword_monthly WHERE location_id = p_location AND month = mo;
  INSERT INTO public.gbp_keyword_monthly (location_id, month, keyword, impressions, below)
  SELECT p_location, mo, k, max(v), max(b) FROM (
    SELECT left(lower(btrim(r->>'k')), 200) k, CASE WHEN r->>'v' ~ '^\d{1,15}$' THEN (r->>'v')::bigint END v,
           CASE WHEN r->>'below' ~ '^\d{1,15}$' THEN (r->>'below')::bigint END b
      FROM jsonb_array_elements(p_rows) r WHERE jsonb_typeof(r) = 'object') x
   WHERE k <> '' AND (v IS NOT NULL OR b IS NOT NULL) GROUP BY k;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Reviews: [{id, reviewer, stars, comment, created, updated, reply, reply_at}], and the profile's own totals from Google.
CREATE OR REPLACE FUNCTION public.svc_gbp_reviews_save(p_location uuid, p_rows jsonb, p_total int DEFAULT NULL, p_rating numeric DEFAULT NULL) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := 0;
BEGIN
  IF jsonb_typeof(p_rows) = 'array' THEN
    INSERT INTO public.gbp_review (location_id, review_id, reviewer, stars, comment, created_at, updated_at, reply, reply_at)
    SELECT p_location, left(r->>'id', 300), left(r->>'reviewer', 120), CASE WHEN r->>'stars' ~ '^[1-5]$' THEN (r->>'stars')::int END,
           left(r->>'comment', 6000), (r->>'created')::timestamptz, (r->>'updated')::timestamptz, left(nullif(r->>'reply', ''), 6000), (r->>'reply_at')::timestamptz
      FROM jsonb_array_elements(p_rows) r WHERE jsonb_typeof(r) = 'object' AND coalesce(r->>'id', '') <> ''
    ON CONFLICT (location_id, review_id) DO UPDATE SET reviewer = EXCLUDED.reviewer, stars = EXCLUDED.stars, comment = EXCLUDED.comment,
      created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at, reply = EXCLUDED.reply, reply_at = EXCLUDED.reply_at;
    GET DIAGNOSTICS n = ROW_COUNT;
  END IF;
  UPDATE public.gbp_location SET reviews_total = coalesce(p_total, reviews_total),
    rating = CASE WHEN p_rating BETWEEN 1 AND 5 THEN round(p_rating, 2) ELSE rating END WHERE id = p_location;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.svc_gbp_run_begin(p_job text) RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH old AS (DELETE FROM public.gbp_run WHERE started_at < now() - interval '60 days')
  INSERT INTO public.gbp_run (job) VALUES (p_job) RETURNING id $$;
CREATE OR REPLACE FUNCTION public.svc_gbp_run_end(p_id bigint, p_status text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.gbp_run SET status = p_status, detail = left(p_detail, 1000), finished_at = now() WHERE id = p_id $$;

-- ---------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION crm_private.gbp_can_view(), crm_private.gbp_can_run(), crm_private.gbp_secret_name(uuid),
  crm_private.gbp_totals(uuid[], date, date), crm_private.gbp_days(uuid[], date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_gbp_access(), public.api_gbp_overview(uuid, int), public.api_gbp_reviews(uuid, text, int),
  public.api_gbp_connection_add(text, text), public.api_gbp_connection_token(uuid, text), public.api_gbp_connection_remove(uuid),
  public.api_gbp_location_track(uuid, boolean), public.api_google_hub() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_gbp_access(), public.api_gbp_overview(uuid, int), public.api_gbp_reviews(uuid, text, int),
  public.api_gbp_connection_add(text, text), public.api_gbp_connection_token(uuid, text), public.api_gbp_connection_remove(uuid),
  public.api_gbp_location_track(uuid, boolean), public.api_google_hub() TO authenticated;
REVOKE ALL ON FUNCTION public.svc_gbp_work(uuid), public.svc_gbp_connection_status(uuid, text, text, text), public.svc_gbp_locations_save(uuid, jsonb),
  public.svc_gbp_metrics_save(uuid, jsonb), public.svc_gbp_keywords_save(uuid, date, jsonb), public.svc_gbp_reviews_save(uuid, jsonb, int, numeric),
  public.svc_gbp_run_begin(text), public.svc_gbp_run_end(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_gbp_work(uuid), public.svc_gbp_connection_status(uuid, text, text, text), public.svc_gbp_locations_save(uuid, jsonb),
  public.svc_gbp_metrics_save(uuid, jsonb), public.svc_gbp_keywords_save(uuid, date, jsonb), public.svc_gbp_reviews_save(uuid, jsonb, int, numeric),
  public.svc_gbp_run_begin(text), public.svc_gbp_run_end(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------- nightly collection (IST 05:05), only when a Google login exists
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-gbp-sync';
    PERFORM cron.schedule('crm-gbp-sync', '35 23 * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-google-business',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["discover", "sync"]}'::jsonb, timeout_milliseconds := 150000)
      WHERE EXISTS (SELECT 1 FROM public.gbp_connection) $job$);
  END IF;
END $$;
