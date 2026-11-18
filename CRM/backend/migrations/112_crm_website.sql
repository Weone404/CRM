-- 112: CRM > Website (Growth > Website). Everything about weoneaviation.in in one calm screen: Google Search performance,
-- visitors (GA4), AI assistants, speed, Google indexing, on-page health, leads from the website, and a ranked fix list.
-- Data comes only from official free APIs and the site itself, collected by the crm-website Edge Function (nightly and on
-- "Refresh"). Google sign-in and property settings are reused from Connections & keys (ads_* Vault entries, ads_config),
-- so nothing new has to be connected. Re-runnable. Undo: 112_crm_website_down.sql.

-- ---------------------------------------------------------------- tables (read only through the functions below)
CREATE TABLE IF NOT EXISTS public.web_row (
  src text NOT NULL CHECK (src IN ('gsc', 'ga')), kind text NOT NULL, k1 text NOT NULL, k2 text NOT NULL DEFAULT '',
  win text NOT NULL CHECK (win IN ('cur', 'prev')), m jsonb NOT NULL DEFAULT '{}', at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (src, kind, k1, k2, win));
CREATE TABLE IF NOT EXISTS public.web_page (
  url text PRIMARY KEY, status int, ms int, title text, title_len int, description_len int, h1_count int, canonical text,
  noindex boolean, schema text[] NOT NULL DEFAULT '{}', issues text[] NOT NULL DEFAULT '{}', links int NOT NULL DEFAULT 0,
  broken jsonb NOT NULL DEFAULT '[]', scanned_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.web_check (key text PRIMARY KEY, data jsonb NOT NULL DEFAULT '{}', at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.web_copilot (
  kind text NOT NULL CHECK (kind IN ('query', 'page')), k text NOT NULL, citations numeric NOT NULL DEFAULT 0,
  uploaded_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (kind, k));
CREATE TABLE IF NOT EXISTS public.web_run (
  id bigserial PRIMARY KEY, job text NOT NULL, status text NOT NULL DEFAULT 'running', detail text,
  started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_web_run_job ON public.web_run (job, started_at DESC);
CREATE TABLE IF NOT EXISTS public.web_config (key text PRIMARY KEY, value text NOT NULL DEFAULT '', updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.web_row ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_page ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_check ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_copilot ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.web_row, public.web_page, public.web_check, public.web_copilot, public.web_run, public.web_config FROM anon, authenticated;
INSERT INTO public.web_config (key, value) VALUES ('site_url', 'https://weoneaviation.in/'), ('key_pages', '') ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION crm_private.web_cfg(p_key text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT c.value FROM public.web_config c WHERE c.key = p_key $$;

-- Website setting that lives with the Google sign-in (Search Console site, GA4 property), when the ADS module is installed.
CREATE OR REPLACE FUNCTION crm_private.web_google_cfg(p_key text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF to_regclass('public.ads_config') IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT nullif(value, '''') FROM public.ads_config WHERE key = $1' INTO v USING p_key;
  RETURN v;
END $$;

-- Who may look: Admin, and anyone with access to the ADS sections. Who may refresh: Admin and ADS approvers.
CREATE OR REPLACE FUNCTION crm_private.web_can_view() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE ok boolean := false;
BEGIN
  IF crm_private.is_admin() THEN RETURN true; END IF;
  IF to_regprocedure('crm_private.ads_can_view()') IS NOT NULL THEN EXECUTE 'SELECT crm_private.ads_can_view()' INTO ok; END IF;
  RETURN coalesce(ok, false);
END $$;
CREATE OR REPLACE FUNCTION crm_private.web_can_run() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE ok boolean := false;
BEGIN
  IF crm_private.is_admin() THEN RETURN true; END IF;
  IF to_regprocedure('crm_private.ads_can_approve()') IS NOT NULL THEN EXECUTE 'SELECT crm_private.ads_can_approve()' INTO ok; END IF;
  RETURN coalesce(ok, false);
END $$;

-- Which AI assistant a GA4 session source is (same list as _shared/website.ts aiTool).
CREATE OR REPLACE FUNCTION crm_private.web_ai_tool(p_source text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN s ~ '(^|\.)chatgpt\.com$|(^|\.)chat\.openai\.com$|^openai$|^chatgpt$' THEN 'ChatGPT'
    WHEN s ~ '(^|\.)perplexity\.ai$|^perplexity$' THEN 'Perplexity'
    WHEN s ~ '(^|\.)gemini\.google\.com$|(^|\.)bard\.google\.com$|^gemini$' THEN 'Gemini'
    WHEN s ~ '(^|\.)copilot\.microsoft\.com$|(^|\.)copilot\.cloud\.microsoft$|^copilot$' THEN 'Copilot'
    WHEN s ~ '(^|\.)claude\.ai$|^claude$' THEN 'Claude'
    WHEN s ~ '(^|\.)chat\.deepseek\.com$|^deepseek$' THEN 'DeepSeek'
    WHEN s ~ '(^|\.)meta\.ai$' THEN 'Meta AI'
    WHEN s ~ '(^|\.)grok\.com$|(^|\.)x\.ai$' THEN 'Grok'
    WHEN s ~ '(^|\.)you\.com$' THEN 'You.com'
  END
  FROM (SELECT regexp_replace(regexp_replace(lower(trim(coalesce(p_source, ''))), '^https?://', ''), '/.*$', '') AS s) z
$$;

-- Brand searches (people who already know the name) are kept apart from the searches that bring new people.
CREATE OR REPLACE FUNCTION crm_private.web_is_brand(p_q text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(p_q ~* '(we\s*one|weone|we1)\s*(aviation|academy|flying)?|weoneaviation', false) $$;
CREATE OR REPLACE FUNCTION crm_private.web_is_question(p_q text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(p_q ~* '^(how|what|why|which|when|where|who|can|is|are|does|do|should|kya|kaise|kitna|kitni|kab|kaun)\y|\?|\y(cost|fees?|salary|eligibility|age limit|syllabus|duration)\y', false) $$;

-- Search queries this period with their previous numbers and flags (shared by the overview and the Searches list).
CREATE OR REPLACE FUNCTION crm_private.web_queries() RETURNS TABLE (
  query text, clicks numeric, impressions numeric, ctr numeric, pos numeric, prev_clicks numeric, prev_impressions numeric, prev_pos numeric,
  almost boolean, low_ctr boolean, dropping boolean, is_new boolean, question boolean, brand boolean, pages int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH c AS (SELECT r.k1, (r.m->>'clicks')::numeric cl, (r.m->>'impressions')::numeric im, (r.m->>'ctr')::numeric ct, (r.m->>'position')::numeric po
               FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'query' AND r.win = 'cur'),
       p AS (SELECT r.k1, (r.m->>'clicks')::numeric cl, (r.m->>'impressions')::numeric im, (r.m->>'position')::numeric po
               FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'query' AND r.win = 'prev'),
       qp AS (SELECT r.k1, count(*)::int n FROM public.web_row r
               WHERE r.src = 'gsc' AND r.kind = 'query_page' AND r.win = 'cur' AND (r.m->>'impressions')::numeric >= 20 GROUP BY r.k1)
  SELECT c.k1, c.cl, c.im, round(c.ct, 4), c.po, p.cl, p.im, p.po,
         c.po BETWEEN 8 AND 20 AND c.im >= 50,
         c.po <= 10 AND c.im >= 300 AND c.ct < 0.02,
         p.po IS NOT NULL AND c.po - p.po >= 3 AND c.im >= 30,
         p.k1 IS NULL AND c.im >= 20,
         crm_private.web_is_question(c.k1), crm_private.web_is_brand(c.k1), coalesce(qp.n, 0)
    FROM c LEFT JOIN p ON p.k1 = c.k1 LEFT JOIN qp ON qp.k1 = c.k1
$$;

-- ---------------------------------------------------------------- browser API
CREATE OR REPLACE FUNCTION public.api_web_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.web_can_view(), 'can_run', crm_private.web_can_run(), 'is_admin', crm_private.is_admin()) $$;

CREATE OR REPLACE FUNCTION public.api_web_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  out jsonb; s_cur jsonb; s_prev jsonb; g_cur jsonb; g_prev jsonb; site text := crm_private.web_cfg('site_url');
  leads jsonb := NULL; actions jsonb := '[]'; a jsonb; mob jsonb; v_n int;
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;

  -- Search totals come from the per-day report: whole-site numbers, not cut by any row limit.
  SELECT jsonb_build_object('clicks', coalesce(sum((m->>'clicks')::numeric), 0), 'impressions', coalesce(sum((m->>'impressions')::numeric), 0),
           'ctr', CASE WHEN sum((m->>'impressions')::numeric) > 0 THEN round(sum((m->>'clicks')::numeric) / sum((m->>'impressions')::numeric), 4) END,
           'position', CASE WHEN sum((m->>'impressions')::numeric) > 0 THEN round(sum((m->>'position')::numeric * (m->>'impressions')::numeric) / sum((m->>'impressions')::numeric), 1) END,
           'days', count(*))
    INTO s_cur FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'cur';
  SELECT jsonb_build_object('clicks', coalesce(sum((m->>'clicks')::numeric), 0), 'impressions', coalesce(sum((m->>'impressions')::numeric), 0),
           'ctr', CASE WHEN sum((m->>'impressions')::numeric) > 0 THEN round(sum((m->>'clicks')::numeric) / sum((m->>'impressions')::numeric), 4) END,
           'position', CASE WHEN sum((m->>'impressions')::numeric) > 0 THEN round(sum((m->>'position')::numeric * (m->>'impressions')::numeric) / sum((m->>'impressions')::numeric), 1) END,
           'days', count(*))
    INTO s_prev FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'prev';
  SELECT jsonb_build_object('users', sum((m->>'activeUsers')::numeric), 'new_users', sum((m->>'newUsers')::numeric), 'sessions', sum((m->>'sessions')::numeric),
           'engaged_rate', CASE WHEN sum((m->>'sessions')::numeric) > 0 THEN round(100 * sum((m->>'engagedSessions')::numeric) / sum((m->>'sessions')::numeric), 1) END,
           'avg_engagement_s', CASE WHEN sum((m->>'activeUsers')::numeric) > 0 THEN round(sum((m->>'userEngagementDuration')::numeric) / sum((m->>'activeUsers')::numeric)) END,
           'key_events', sum((m->>'keyEvents')::numeric), 'views', sum((m->>'screenPageViews')::numeric), 'days', count(*))
    INTO g_cur FROM public.web_row WHERE src = 'ga' AND kind = 'date' AND win = 'cur';
  SELECT jsonb_build_object('users', sum((m->>'activeUsers')::numeric), 'sessions', sum((m->>'sessions')::numeric),
           'engaged_rate', CASE WHEN sum((m->>'sessions')::numeric) > 0 THEN round(100 * sum((m->>'engagedSessions')::numeric) / sum((m->>'sessions')::numeric), 1) END,
           'key_events', sum((m->>'keyEvents')::numeric), 'days', count(*))
    INTO g_prev FROM public.web_row WHERE src = 'ga' AND kind = 'date' AND win = 'prev';

  -- Leads the CRM received from website forms (organic Leads), when the Leads module is installed.
  IF to_regclass('public.lead') IS NOT NULL THEN
    EXECUTE $q$
      WITH w AS (SELECT l.created_at, coalesce(nullif(trim(l.utm_source), ''), 'Not recorded') src, l.closure_outcome::text outcome
                   FROM public.lead l WHERE l.created_at > now() - interval '56 days')
      SELECT jsonb_build_object(
        'cur', count(*) FILTER (WHERE created_at > now() - interval '28 days'),
        'prev', count(*) FILTER (WHERE created_at <= now() - interval '28 days'),
        'admissions', count(*) FILTER (WHERE created_at > now() - interval '28 days' AND outcome IN ('admission_completed', 'booking_confirmed')),
        'by_source', (SELECT coalesce(jsonb_agg(jsonb_build_object('source', src, 'n', n) ORDER BY n DESC), '[]')
                        FROM (SELECT src, count(*) n FROM w WHERE created_at > now() - interval '28 days' GROUP BY src) z),
        'weekly', (SELECT coalesce(jsonb_agg(jsonb_build_object('week', wk, 'n', n) ORDER BY wk), '[]')
                     FROM (SELECT date_trunc('week', created_at)::date wk, count(*) n FROM w GROUP BY 1) z))
      FROM w $q$ INTO leads;
  END IF;

  out := jsonb_build_object(
    'site', site,
    'configured', jsonb_build_object('gsc', crm_private.web_google_cfg('site_gsc_url') IS NOT NULL, 'ga4', crm_private.web_google_cfg('site_ga4_property') IS NOT NULL),
    'runs', (SELECT coalesce(jsonb_object_agg(job, jsonb_build_object('status', status, 'detail', detail, 'at', coalesce(finished_at, started_at))), '{}')
               FROM (SELECT DISTINCT ON (job) job, status, detail, started_at, finished_at FROM public.web_run ORDER BY job, started_at DESC) r),
    'search', jsonb_build_object('cur', s_cur, 'prev', s_prev,
      'daily', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', k1, 'clicks', (m->>'clicks')::numeric, 'impressions', (m->>'impressions')::numeric) ORDER BY k1), '[]')
                  FROM public.web_row WHERE src = 'gsc' AND kind = 'date' AND win = 'cur'),
      'devices', (SELECT coalesce(jsonb_agg(jsonb_build_object('k', k1, 'clicks', (m->>'clicks')::numeric, 'impressions', (m->>'impressions')::numeric, 'position', (m->>'position')::numeric)
                    ORDER BY (m->>'clicks')::numeric DESC), '[]') FROM public.web_row WHERE src = 'gsc' AND kind = 'device' AND win = 'cur'),
      'countries', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1 AS k, (m->>'clicks')::numeric clicks, (m->>'impressions')::numeric impressions
                    FROM public.web_row WHERE src = 'gsc' AND kind = 'country' AND win = 'cur' ORDER BY (m->>'clicks')::numeric DESC LIMIT 8) x),
      'appearance', (SELECT coalesce(jsonb_agg(jsonb_build_object('k', k1, 'clicks', (m->>'clicks')::numeric, 'impressions', (m->>'impressions')::numeric)
                    ORDER BY (m->>'impressions')::numeric DESC), '[]') FROM public.web_row WHERE src = 'gsc' AND kind = 'appearance' AND win = 'cur'),
      'counts', (SELECT jsonb_build_object('queries', count(*), 'almost', count(*) FILTER (WHERE almost), 'low_ctr', count(*) FILTER (WHERE low_ctr),
                    'dropping', count(*) FILTER (WHERE dropping), 'new', count(*) FILTER (WHERE is_new), 'questions', count(*) FILTER (WHERE question),
                    'brand_clicks', coalesce(sum(clicks) FILTER (WHERE brand), 0), 'nonbrand_clicks', coalesce(sum(clicks) FILTER (WHERE NOT brand), 0),
                    'cannibal', count(*) FILTER (WHERE pages >= 2)) FROM crm_private.web_queries()),
      'examples', jsonb_build_object(
        'almost', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT query, impressions, pos FROM crm_private.web_queries() WHERE almost ORDER BY impressions DESC LIMIT 5) x),
        'low_ctr', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT query, impressions, clicks, pos FROM crm_private.web_queries() WHERE low_ctr ORDER BY impressions DESC LIMIT 5) x),
        'dropping', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT query, impressions, pos, prev_pos FROM crm_private.web_queries() WHERE dropping ORDER BY impressions DESC LIMIT 5) x),
        'new', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT query, impressions, pos FROM crm_private.web_queries() WHERE is_new ORDER BY impressions DESC LIMIT 5) x),
        'cannibal', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
                      SELECT q.k1 AS query, jsonb_agg(jsonb_build_object('page', q.k2, 'impressions', (q.m->>'impressions')::numeric, 'position', (q.m->>'position')::numeric)
                               ORDER BY (q.m->>'impressions')::numeric DESC) pages, sum((q.m->>'impressions')::numeric) impressions
                        FROM public.web_row q WHERE q.src = 'gsc' AND q.kind = 'query_page' AND q.win = 'cur' AND (q.m->>'impressions')::numeric >= 20
                       GROUP BY q.k1 HAVING count(*) >= 2 ORDER BY sum((q.m->>'impressions')::numeric) DESC LIMIT 5) x)),
      'top_queries', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT query, clicks, impressions, ctr, pos, prev_clicks, prev_pos, brand
                        FROM crm_private.web_queries() ORDER BY clicks DESC, impressions DESC LIMIT 10) x),
      'top_pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
                      SELECT c.k1 AS page, (c.m->>'clicks')::numeric clicks, (c.m->>'impressions')::numeric impressions, (c.m->>'position')::numeric pos,
                             (p.m->>'clicks')::numeric prev_clicks, (p.m->>'position')::numeric prev_pos
                        FROM public.web_row c LEFT JOIN public.web_row p ON p.src = 'gsc' AND p.kind = 'page' AND p.win = 'prev' AND p.k1 = c.k1
                       WHERE c.src = 'gsc' AND c.kind = 'page' AND c.win = 'cur' ORDER BY (c.m->>'clicks')::numeric DESC LIMIT 15) x)),
    'visitors', jsonb_build_object('cur', g_cur, 'prev', g_prev,
      'daily', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', k1, 'users', (m->>'activeUsers')::numeric, 'sessions', (m->>'sessions')::numeric) ORDER BY k1), '[]')
                  FROM public.web_row WHERE src = 'ga' AND kind = 'date' AND win = 'cur'),
      'channels', (SELECT coalesce(jsonb_agg(jsonb_build_object('k', c.k1, 'sessions', (c.m->>'sessions')::numeric, 'key_events', (c.m->>'keyEvents')::numeric,
                     'prev_sessions', (p.m->>'sessions')::numeric) ORDER BY (c.m->>'sessions')::numeric DESC), '[]')
                     FROM public.web_row c LEFT JOIN public.web_row p ON p.src = 'ga' AND p.kind = 'channel' AND p.win = 'prev' AND p.k1 = c.k1
                    WHERE c.src = 'ga' AND c.kind = 'channel' AND c.win = 'cur'),
      'sources', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1 AS source, k2 AS medium, (m->>'sessions')::numeric sessions, (m->>'keyEvents')::numeric key_events
                    FROM public.web_row WHERE src = 'ga' AND kind = 'source' AND win = 'cur' ORDER BY (m->>'sessions')::numeric DESC LIMIT 12) x),
      'devices', (SELECT coalesce(jsonb_agg(jsonb_build_object('k', k1, 'users', (m->>'activeUsers')::numeric, 'sessions', (m->>'sessions')::numeric) ORDER BY (m->>'activeUsers')::numeric DESC), '[]')
                    FROM public.web_row WHERE src = 'ga' AND kind = 'device' AND win = 'cur'),
      'newret', (SELECT coalesce(jsonb_object_agg(k1, (m->>'activeUsers')::numeric), '{}') FROM public.web_row WHERE src = 'ga' AND kind = 'newret' AND win = 'cur'),
      'cities', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1 AS city, k2 AS region, (m->>'activeUsers')::numeric users, (m->>'keyEvents')::numeric key_events
                    FROM public.web_row WHERE src = 'ga' AND kind = 'city' AND win = 'cur' ORDER BY (m->>'activeUsers')::numeric DESC LIMIT 10) x),
      'busiest', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1::int AS dow, k2::int AS hour, (m->>'sessions')::numeric sessions
                    FROM public.web_row WHERE src = 'ga' AND kind = 'hour' AND win = 'cur' AND k1 ~ '^\d+$' AND k2 ~ '^\d+$'
                    ORDER BY (m->>'sessions')::numeric DESC LIMIT 3) x),
      'landing', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1 AS page, (m->>'sessions')::numeric sessions, (m->>'keyEvents')::numeric key_events,
                     CASE WHEN (m->>'sessions')::numeric > 0 THEN round(100 * (m->>'engagedSessions')::numeric / (m->>'sessions')::numeric, 1) END engaged_rate
                    FROM public.web_row WHERE src = 'ga' AND kind = 'landing' AND win = 'cur' ORDER BY (m->>'sessions')::numeric DESC LIMIT 15) x),
      'events', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k1 AS event, (m->>'eventCount')::numeric count, (m->>'keyEvents')::numeric key_events
                    FROM public.web_row WHERE src = 'ga' AND kind = 'event' AND win = 'cur'
                     AND k1 !~ '^(page_view|session_start|first_visit|user_engagement|scroll)$' ORDER BY (m->>'eventCount')::numeric DESC LIMIT 12) x)),
    'ai', jsonb_build_object(
      'tools', (SELECT coalesce(jsonb_agg(x ORDER BY sessions DESC), '[]') FROM (
                  SELECT crm_private.web_ai_tool(k1) AS tool, sum((m->>'sessions')::numeric) FILTER (WHERE win = 'cur') sessions,
                         coalesce(sum((m->>'sessions')::numeric) FILTER (WHERE win = 'prev'), 0) prev_sessions,
                         coalesce(sum((m->>'keyEvents')::numeric) FILTER (WHERE win = 'cur'), 0) key_events
                    FROM public.web_row WHERE src = 'ga' AND kind = 'source' AND crm_private.web_ai_tool(k1) IS NOT NULL
                   GROUP BY 1 HAVING sum((m->>'sessions')::numeric) FILTER (WHERE win = 'cur') > 0) x),
      'pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
                  SELECT k2 AS page, sum((m->>'sessions')::numeric) sessions, string_agg(DISTINCT crm_private.web_ai_tool(k1), ', ') tools
                    FROM public.web_row WHERE src = 'ga' AND kind = 'ai_landing' AND win = 'cur' AND crm_private.web_ai_tool(k1) IS NOT NULL
                   GROUP BY k2 ORDER BY sum((m->>'sessions')::numeric) DESC LIMIT 10) x),
      'copilot', jsonb_build_object(
        'queries', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k, citations FROM public.web_copilot WHERE kind = 'query' ORDER BY citations DESC LIMIT 15) x),
        'pages', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT k, citations FROM public.web_copilot WHERE kind = 'page' ORDER BY citations DESC LIMIT 10) x),
        'uploaded_at', (SELECT max(uploaded_at) FROM public.web_copilot), 'total', (SELECT coalesce(sum(citations), 0) FROM public.web_copilot WHERE kind = 'query')),
      'robots', (SELECT data FROM public.web_check WHERE key = 'robots'),
      'llms', (SELECT data FROM public.web_check WHERE key = 'llms'),
      'schema', (SELECT jsonb_build_object('pages', count(*), 'with_schema', count(*) FILTER (WHERE cardinality(schema) > 0),
                   'types', (SELECT coalesce(jsonb_agg(DISTINCT t), '[]') FROM public.web_page, unnest(schema) t WHERE t <> '(invalid JSON-LD)'))
                 FROM public.web_page)),
    'speed', (SELECT coalesce(jsonb_agg(jsonb_build_object('url', split_part(substr(key, 5), '|', 1), 'strategy', split_part(key, '|', 2), 'at', at) || data
                ORDER BY split_part(substr(key, 5), '|', 1), split_part(key, '|', 2) DESC), '[]') FROM public.web_check WHERE key LIKE 'psi:%'),
    'health', jsonb_build_object(
      'home', (SELECT data || jsonb_build_object('at', at) FROM public.web_check WHERE key = 'home'),
      'sitemaps', (SELECT data || jsonb_build_object('at', at) FROM public.web_check WHERE key = 'sitemaps'),
      'index', (SELECT coalesce(jsonb_agg(jsonb_build_object('url', substr(key, 9), 'at', at) || data ORDER BY key), '[]') FROM public.web_check WHERE key LIKE 'inspect:%'),
      'scan', (SELECT jsonb_build_object('pages', count(*), 'ok', count(*) FILTER (WHERE status BETWEEN 200 AND 299),
                 'errors', count(*) FILTER (WHERE status IS NULL OR status >= 400), 'slow', count(*) FILTER (WHERE ms > 2000),
                 'avg_ms', round(avg(ms)), 'scanned_at', max(scanned_at),
                 'issues', (SELECT coalesce(jsonb_object_agg(i, n), '{}') FROM (SELECT i, count(*) n FROM public.web_page, unnest(issues) i GROUP BY i) z),
                 'broken', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT b->>'url' AS url, (b->>'status')::int status, count(*) on_pages, min(p.url) example
                              FROM public.web_page p, jsonb_array_elements(p.broken) b GROUP BY 1, 2 ORDER BY count(*) DESC LIMIT 20) x),
                 'pages_with_issues', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT url, status, ms, title, issues FROM public.web_page
                              WHERE cardinality(issues) > 0 OR status >= 400 ORDER BY cardinality(issues) DESC, url LIMIT 40) x))
                 FROM public.web_page)),
    'leads', leads,
    'checked_at', now());

  -- Ranked fix list: the most valuable things to do next, each pointing at the exact search, page or setting.
  IF (out->'configured'->>'ga4')::boolean AND coalesce((g_cur->>'days')::int, 0) = 0 AND (out->'runs' ? 'visitors') THEN
    actions := actions || jsonb_build_object('p', 100, 'area', 'setup', 'title', 'GA4 sends no visitor data',
      'detail', 'The GA4 property answers but has no visits. Check it is the property whose data stream is weoneaviation.in.', 'go', 'connections');
  END IF;
  SELECT count(*) INTO v_n FROM public.web_page WHERE noindex;
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 95, 'area', 'health', 'title', format('%s page(s) tell Google not to index them', v_n),
    'detail', 'They carry a noindex tag, so they can never appear in search. Remove it unless that is intended.', 'go', 'health'); END IF;
  SELECT count(*) INTO v_n FROM public.web_check WHERE key LIKE 'inspect:%' AND coalesce(data->>'verdict', '') NOT IN ('PASS', '');
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 92, 'area', 'health', 'title', format('%s key page(s) are not indexed by Google', v_n),
    'detail', 'Google''s URL Inspection says these pages are not in its index. Open each to see why.', 'go', 'health'); END IF;
  SELECT count(DISTINCT b->>'url') INTO v_n FROM public.web_page p, jsonb_array_elements(p.broken) b;
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 85, 'area', 'health', 'title', format('Fix %s broken link(s) on the site', v_n),
    'detail', 'Links to pages that answer with an error waste visitors and crawl budget.', 'go', 'health'); END IF;
  SELECT jsonb_agg(x) INTO mob FROM (SELECT split_part(substr(key, 5), '|', 1) url FROM public.web_check
    WHERE key LIKE 'psi:%|mobile' AND (data->>'overall' = 'slow' OR coalesce((data->'scores'->>'performance')::int, 100) < 50)) x;
  IF mob IS NOT NULL THEN actions := actions || jsonb_build_object('p', 80, 'area', 'speed', 'title', format('Speed up %s page(s) on mobile', jsonb_array_length(mob)),
    'detail', 'Real-user speed or the lab score is poor on phones, where most visitors are. See the top fixes per page.', 'go', 'speed'); END IF;
  FOR a IN SELECT jsonb_build_object('p', 75 - row_number() OVER (ORDER BY impressions DESC), 'area', 'search',
             'title', format('Push "%s" onto page 1', query), 'detail', format('%s views at position %s. A better section on its page could move it up.', impressions, pos),
             'go', 'searches', 'q', query) FROM crm_private.web_queries() WHERE almost ORDER BY impressions DESC LIMIT 3 LOOP
    actions := actions || a; END LOOP;
  FOR a IN SELECT jsonb_build_object('p', 70 - row_number() OVER (ORDER BY impressions DESC), 'area', 'search',
             'title', format('Rewrite the title for "%s"', query), 'detail', format('Seen %s times at position %s but clicked %s times. A clearer title and description should win more clicks.', impressions, pos, clicks),
             'go', 'searches', 'q', query) FROM crm_private.web_queries() WHERE low_ctr ORDER BY impressions DESC LIMIT 2 LOOP
    actions := actions || a; END LOOP;
  SELECT count(*) INTO v_n FROM crm_private.web_queries() WHERE pages >= 2;
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 60, 'area', 'search', 'title', format('%s search(es) split between two of your pages', v_n),
    'detail', 'Two pages competing for the same search usually both rank lower. Merge them or make one clearly the main page.', 'go', 'searches'); END IF;
  SELECT count(*) INTO v_n FROM public.web_page WHERE 'no_description' = ANY (issues) OR 'no_title' = ANY (issues);
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 55, 'area', 'health', 'title', format('%s page(s) miss a title or description', v_n),
    'detail', 'Google shows these in results; without them it writes its own.', 'go', 'health'); END IF;
  SELECT count(*) INTO v_n FROM jsonb_each_text(coalesce((SELECT data->'bots' FROM public.web_check WHERE key = 'robots'), '{}')) b
   WHERE b.value = 'blocked' AND b.key IN ('OAI-SearchBot', 'ChatGPT-User', 'Claude-SearchBot', 'PerplexityBot', 'Bingbot', 'Googlebot');
  IF v_n > 0 THEN actions := actions || jsonb_build_object('p', 90, 'area', 'ai', 'title', format('robots.txt blocks %s search or AI answer crawler(s)', v_n),
    'detail', 'Blocked crawlers cannot show or cite the site in their answers.', 'go', 'ai'); END IF;
  IF (SELECT data->>'status' FROM public.web_check WHERE key = 'llms') IN ('missing', '404') THEN
    actions := actions || jsonb_build_object('p', 30, 'area', 'ai', 'title', 'Add an llms.txt file',
      'detail', 'An optional plain-text summary of the site for AI tools. Low effort; no search engine requires it.', 'go', 'ai');
  END IF;
  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'p')::int DESC), '[]') INTO actions FROM (SELECT x FROM jsonb_array_elements(actions) x ORDER BY (x->>'p')::int DESC LIMIT 10) z;
  RETURN out || jsonb_build_object('actions', actions);
END $$;

-- The Searches list: every query with its change and flags, filtered and searched on the server.
CREATE OR REPLACE FUNCTION public.api_web_queries(p_filter text DEFAULT 'all', p_q text DEFAULT NULL, p_limit int DEFAULT 200) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE f text := coalesce(nullif(p_filter, ''), 'all'); lim int := least(greatest(coalesce(p_limit, 200), 1), 1000);
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  IF f NOT IN ('all', 'almost', 'low_ctr', 'dropping', 'new', 'questions', 'brand', 'nonbrand', 'cannibal') THEN
    RAISE EXCEPTION 'Unknown filter' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('rows', coalesce((SELECT jsonb_agg(x) FROM (
      SELECT q.*, (SELECT jsonb_agg(jsonb_build_object('page', r.k2, 'clicks', (r.m->>'clicks')::numeric, 'impressions', (r.m->>'impressions')::numeric, 'position', (r.m->>'position')::numeric)
                           ORDER BY (r.m->>'impressions')::numeric DESC)
                     FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'query_page' AND r.win = 'cur' AND r.k1 = q.query) AS page_list
        FROM crm_private.web_queries() q
       WHERE (p_q IS NULL OR q.query ILIKE '%' || p_q || '%')
         AND CASE f WHEN 'almost' THEN q.almost WHEN 'low_ctr' THEN q.low_ctr WHEN 'dropping' THEN q.dropping WHEN 'new' THEN q.is_new
                    WHEN 'questions' THEN q.question WHEN 'brand' THEN q.brand WHEN 'nonbrand' THEN NOT q.brand WHEN 'cannibal' THEN q.pages >= 2 ELSE true END
       ORDER BY q.clicks DESC, q.impressions DESC LIMIT lim) x), '[]'),
      'total', (SELECT count(*) FROM crm_private.web_queries() q WHERE (p_q IS NULL OR q.query ILIKE '%' || p_q || '%')
         AND CASE f WHEN 'almost' THEN q.almost WHEN 'low_ctr' THEN q.low_ctr WHEN 'dropping' THEN q.dropping WHEN 'new' THEN q.is_new
                    WHEN 'questions' THEN q.question WHEN 'brand' THEN q.brand WHEN 'nonbrand' THEN NOT q.brand WHEN 'cannibal' THEN q.pages >= 2 ELSE true END));
END $$;

CREATE OR REPLACE FUNCTION public.api_web_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  RETURN jsonb_build_object('site_url', crm_private.web_cfg('site_url'),
    'key_pages', coalesce(nullif(crm_private.web_cfg('key_pages'), ''), ''),
    'gsc_url', crm_private.web_google_cfg('site_gsc_url'), 'ga4_property', crm_private.web_google_cfg('site_ga4_property'),
    'psi_key', CASE WHEN crm_private.is_admin() THEN (SELECT jsonb_build_object('set', true, 'last4', right(d.decrypted_secret, 4), 'updated_at', d.updated_at)
                 FROM vault.decrypted_secrets d WHERE d.name = 'crm_web_psi_api_key') END,
    'google_signin', EXISTS (SELECT 1 FROM vault.secrets s WHERE s.name = 'ads_google_site_refresh_token'));
END $$;

-- p_psi_key: NULL keeps the saved key, '' removes it, anything else replaces it (write-only).
CREATE OR REPLACE FUNCTION public.api_web_settings_save(p_site_url text, p_key_pages text, p_psi_key text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE u text := lower(trim(coalesce(p_site_url, ''))); pages text := trim(coalesce(p_key_pages, '')); k text := trim(coalesce(p_psi_key, '')); sid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change Website settings' USING ERRCODE = 'PT403'; END IF;
  IF u !~ '^https://[a-z0-9.-]+\.[a-z]{2,}/?$' THEN RAISE EXCEPTION 'Site address looks like https://weoneaviation.in/' USING ERRCODE = 'PT422'; END IF;
  IF right(u, 1) <> '/' THEN u := u || '/'; END IF;
  IF pages <> '' AND (array_length(regexp_split_to_array(pages, '\s*\n\s*'), 1) > 10 OR pages ~ '[<>"'' ]') THEN
    RAISE EXCEPTION 'Key pages: up to 10 paths, one per line (e.g. /cpl-course)' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.web_config (key, value) VALUES ('site_url', u), ('key_pages', pages)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  IF p_psi_key IS NOT NULL THEN
    SELECT id INTO sid FROM vault.secrets WHERE name = 'crm_web_psi_api_key';
    IF k = '' THEN DELETE FROM vault.secrets WHERE name = 'crm_web_psi_api_key';
    ELSIF k !~ '^[A-Za-z0-9_-]{30,60}$' THEN RAISE EXCEPTION 'A Google API key is about 39 letters and digits (starts with AIza)' USING ERRCODE = 'PT422';
    ELSIF sid IS NULL THEN PERFORM vault.create_secret(k, 'crm_web_psi_api_key', 'CRM Website: PageSpeed Insights API key');
    ELSE PERFORM vault.update_secret(sid, k); END IF;
  END IF;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, ''web_settings_saved'', ''website'', $2)'
      USING crm_private.current_employee_id(), jsonb_build_object('site_url', u, 'psi_key', CASE WHEN p_psi_key IS NULL THEN 'kept' WHEN k = '' THEN 'removed' ELSE 'replaced' END);
  END IF;
  RETURN jsonb_build_object('saved', true);
END $$;

-- Bing Webmaster Tools > AI Performance CSV (no API yet): replaces the previous upload of the same kind.
CREATE OR REPLACE FUNCTION public.api_web_copilot_upload(p_kind text, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF NOT crm_private.web_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can upload' USING ERRCODE = 'PT403'; END IF;
  IF p_kind NOT IN ('query', 'page') OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Send the CSV rows' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN RAISE EXCEPTION 'Up to 5,000 rows' USING ERRCODE = 'PT422'; END IF;
  DELETE FROM public.web_copilot WHERE kind = p_kind;
  INSERT INTO public.web_copilot (kind, k, citations)
  SELECT p_kind, left(r->>'k', 400), max(greatest(coalesce((r->>'citations')::numeric, 0), 0))
    FROM jsonb_array_elements(p_rows) r WHERE coalesce(r->>'k', '') <> '' GROUP BY left(r->>'k', 400);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('saved', n);
END $$;

-- ---------------------------------------------------------------- service API (crm-website Edge Function only)
CREATE OR REPLACE FUNCTION public.svc_web_work() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE site text := crm_private.web_cfg('site_url'); pages text[];
BEGIN
  pages := ARRAY(SELECT DISTINCT p FROM (
    SELECT site AS p
    UNION ALL SELECT rtrim(site, '/') || CASE WHEN x LIKE '/%' THEN x ELSE '/' || x END
      FROM unnest(regexp_split_to_array(coalesce(crm_private.web_cfg('key_pages'), ''), '\s*\n\s*')) x WHERE x <> ''
    UNION ALL SELECT k1 FROM (SELECT r.k1 FROM public.web_row r WHERE r.src = 'gsc' AND r.kind = 'page' AND r.win = 'cur'
                               ORDER BY (r.m->>'clicks')::numeric DESC LIMIT 5) t
      WHERE coalesce(crm_private.web_cfg('key_pages'), '') = '') z LIMIT 8);
  RETURN jsonb_build_object('site_url', site, 'key_pages', to_jsonb(pages),
    'gsc_url', crm_private.web_google_cfg('site_gsc_url'), 'ga4_property', crm_private.web_google_cfg('site_ga4_property'),
    'client_id', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_id'),
    'client_secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_secret'),
    'refresh_token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_site_refresh_token'),
    'psi_key', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_web_psi_api_key'));
END $$;

-- Replaces every row of the given kinds for one source (a run always sends complete reports).
CREATE OR REPLACE FUNCTION public.svc_web_save(p_src text, p_kinds text[], p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF p_src NOT IN ('gsc', 'ga') OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'bad rows'; END IF;
  DELETE FROM public.web_row WHERE src = p_src AND kind = ANY (p_kinds);
  INSERT INTO public.web_row (src, kind, k1, k2, win, m)
  SELECT p_src, r->>'kind', left(r->>'k1', 400), left(coalesce(r->>'k2', ''), 400), r->>'win', coalesce(r->'m', '{}')
    FROM jsonb_array_elements(p_rows) r
   WHERE r->>'kind' = ANY (p_kinds) AND r->>'win' IN ('cur', 'prev') AND coalesce(r->>'k1', '') <> ''
  ON CONFLICT (src, kind, k1, k2, win) DO UPDATE SET m = EXCLUDED.m, at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.svc_web_pages_save(p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'bad rows'; END IF;
  DELETE FROM public.web_page WHERE true;
  INSERT INTO public.web_page (url, status, ms, title, title_len, description_len, h1_count, canonical, noindex, schema, issues, links, broken)
  SELECT DISTINCT ON (r->>'url') left(r->>'url', 600), (r->>'status')::int, (r->>'ms')::int, left(r->>'title', 300), (r->>'title_len')::int,
         (r->>'description_len')::int, (r->>'h1_count')::int, left(r->>'canonical', 600), coalesce((r->>'noindex')::boolean, false),
         coalesce(ARRAY(SELECT left(x, 80) FROM jsonb_array_elements_text(coalesce(r->'schema', '[]')) x), '{}'),
         coalesce(ARRAY(SELECT left(x, 40) FROM jsonb_array_elements_text(coalesce(r->'issues', '[]')) x), '{}'),
         coalesce((r->>'links')::int, 0), coalesce(r->'broken', '[]')
    FROM jsonb_array_elements(p_rows) r WHERE coalesce(r->>'url', '') <> '';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.svc_web_check_save(p_key text, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.web_check (key, data, at) VALUES (left(p_key, 700), coalesce(p_data, '{}'), now())
  ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, at = now() $$;
-- Drops checks for pages that are no longer key pages (speed and indexing lists stay current).
CREATE OR REPLACE FUNCTION public.svc_web_checks_prune(p_prefix text, p_keep text[]) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM public.web_check WHERE key LIKE p_prefix || '%' AND NOT (key = ANY (p_keep)) $$;

CREATE OR REPLACE FUNCTION public.svc_web_run_begin(p_job text) RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH old AS (DELETE FROM public.web_run WHERE started_at < now() - interval '60 days')
  INSERT INTO public.web_run (job) VALUES (p_job) RETURNING id $$;
CREATE OR REPLACE FUNCTION public.svc_web_run_end(p_id bigint, p_status text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.web_run SET status = p_status, detail = left(p_detail, 1000), finished_at = now() WHERE id = p_id $$;

-- ---------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION crm_private.web_cfg(text), crm_private.web_google_cfg(text), crm_private.web_can_view(), crm_private.web_can_run(),
  crm_private.web_queries() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_web_access(), public.api_web_overview(), public.api_web_queries(text, text, int), public.api_web_settings(),
  public.api_web_settings_save(text, text, text), public.api_web_copilot_upload(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_web_access(), public.api_web_overview(), public.api_web_queries(text, text, int), public.api_web_settings(),
  public.api_web_settings_save(text, text, text), public.api_web_copilot_upload(text, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_web_work(), public.svc_web_save(text, text[], jsonb), public.svc_web_pages_save(jsonb), public.svc_web_check_save(text, jsonb),
  public.svc_web_checks_prune(text, text[]), public.svc_web_run_begin(text), public.svc_web_run_end(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_web_work(), public.svc_web_save(text, text[], jsonb), public.svc_web_pages_save(jsonb), public.svc_web_check_save(text, jsonb),
  public.svc_web_checks_prune(text, text[]), public.svc_web_run_begin(text), public.svc_web_run_end(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------- nightly collection (IST 04:10 search+visitors, 04:25 site scan, 04:40 speed+index)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-web-data', 'crm-web-scan', 'crm-web-speed');
    PERFORM cron.schedule('crm-web-data', '40 22 * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["search", "visitors"]}'::jsonb, timeout_milliseconds := 150000) $job$);
    PERFORM cron.schedule('crm-web-scan', '55 22 * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["scan"]}'::jsonb, timeout_milliseconds := 150000) $job$);
    PERFORM cron.schedule('crm-web-speed', '10 23 * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["speed", "index"]}'::jsonb, timeout_milliseconds := 150000) $job$);
  END IF;
END $$;
