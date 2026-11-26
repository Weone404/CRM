-- 148: Website > many websites. Google > Website now holds a card per website (We One Aviation, Flying Star, Book My Charter,
-- Legal Group, Book My Chardham, and any added later). Each website keeps its own Search Console site, GA4 property, key
-- pages, brand words and lead sources; every Website number (searches, visitors, AI, speed, health, leads) is per website.
-- The Google sign-in and the PageSpeed key stay shared. Existing data becomes We One Aviation's (the primary website).
-- Old calls without a website keep working: they mean the primary website. Undo: 148_web_sites_down.sql.

-- ---------------------------------------------------------------- websites
CREATE TABLE IF NOT EXISTS public.web_site (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  url text CHECK (url IS NULL OR url ~ '^https://[a-z0-9.-]+\.[a-z]{2,}/$'),
  gsc_url text CHECK (gsc_url IS NULL OR gsc_url ~ '^(sc-domain:[a-z0-9.-]+\.[a-z]{2,}|https?://[^\s]+/)$'),
  ga4_property text CHECK (ga4_property IS NULL OR ga4_property ~ '^\d{5,15}$'),
  key_pages text NOT NULL DEFAULT '',
  brand_terms text NOT NULL DEFAULT '',
  lead_sources text[] NOT NULL DEFAULT '{}',
  color text NOT NULL DEFAULT '#0A63CE' CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  is_primary boolean NOT NULL DEFAULT false,
  sort int NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), created_by uuid);

-- Brand words ("we one, weone") as one case-insensitive pattern; searches matching it are brand searches.
CREATE OR REPLACE FUNCTION crm_private.web_brand_re(p_terms text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(string_agg(regexp_replace(regexp_replace(lower(btrim(t)), '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g'), '\s+', '\\s*', 'g'), '|'), '')
    FROM unnest(string_to_array(coalesce(p_terms, ''), ',')) t WHERE btrim(t) <> '' $$;
ALTER TABLE public.web_site ADD COLUMN IF NOT EXISTS brand_re text GENERATED ALWAYS AS (crm_private.web_brand_re(brand_terms)) STORED;
CREATE UNIQUE INDEX IF NOT EXISTS uq_web_site_primary ON public.web_site (is_primary) WHERE is_primary;
CREATE UNIQUE INDEX IF NOT EXISTS uq_web_site_url ON public.web_site (url) WHERE url IS NOT NULL;
ALTER TABLE public.web_site ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.web_site FROM anon, authenticated;

INSERT INTO public.web_site (name, url, key_pages, brand_terms, lead_sources, color, is_primary, sort)
SELECT v.name, v.url, v.key_pages, v.brand, v.leads, v.color, v.prim, v.sort FROM (VALUES
  ('We One Aviation', coalesce(nullif((SELECT c.value FROM public.web_config c WHERE c.key = 'site_url'), ''), 'https://weoneaviation.in/'),
     coalesce((SELECT c.value FROM public.web_config c WHERE c.key = 'key_pages'), ''), 'we one, weone, we1, weoneaviation', ARRAY['website']::text[], '#0A63CE', true, 1),
  ('Flying Star', 'https://www.flystar.co.in/', '', 'fly star, flying star, flystar', '{}'::text[], '#6E3FC9', false, 2),
  ('Book My Charter', 'https://bookmycharter.in/', '', 'book my charter, bookmycharter', ARRAY['book my charter website']::text[], '#0E7C6B', false, 3),
  ('Legal Group', NULL, '', 'legal group', '{}'::text[], '#8A5300', false, 4),
  ('Book My Chardham', 'https://www.bookmychardham.in/', '', 'book my chardham, bookmychardham, book my char dham', '{}'::text[], '#C2410C', false, 5)
) v(name, url, key_pages, brand, leads, color, prim, sort)
WHERE NOT EXISTS (SELECT 1 FROM public.web_site);

-- ---------------------------------------------------------------- every Website row belongs to one website
DO $$
DECLARE p uuid := (SELECT id FROM public.web_site WHERE is_primary);
BEGIN
  ALTER TABLE public.web_row ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES public.web_site(id) ON DELETE CASCADE;
  ALTER TABLE public.web_page ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES public.web_site(id) ON DELETE CASCADE;
  ALTER TABLE public.web_check ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES public.web_site(id) ON DELETE CASCADE;
  ALTER TABLE public.web_copilot ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES public.web_site(id) ON DELETE CASCADE;
  ALTER TABLE public.web_run ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES public.web_site(id) ON DELETE CASCADE;
  UPDATE public.web_row SET site_id = p WHERE site_id IS NULL;
  UPDATE public.web_page SET site_id = p WHERE site_id IS NULL;
  UPDATE public.web_check SET site_id = p WHERE site_id IS NULL;
  UPDATE public.web_copilot SET site_id = p WHERE site_id IS NULL;
  UPDATE public.web_run SET site_id = p WHERE site_id IS NULL;
  ALTER TABLE public.web_row ALTER COLUMN site_id SET NOT NULL;
  ALTER TABLE public.web_page ALTER COLUMN site_id SET NOT NULL;
  ALTER TABLE public.web_check ALTER COLUMN site_id SET NOT NULL;
  ALTER TABLE public.web_copilot ALTER COLUMN site_id SET NOT NULL;
  ALTER TABLE public.web_run ALTER COLUMN site_id SET NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                  WHERE i.indrelid = 'public.web_row'::regclass AND i.indisprimary AND a.attname = 'site_id') THEN
    ALTER TABLE public.web_row DROP CONSTRAINT web_row_pkey, ADD PRIMARY KEY (site_id, src, kind, k1, k2, win);
    ALTER TABLE public.web_page DROP CONSTRAINT web_page_pkey, ADD PRIMARY KEY (site_id, url);
    ALTER TABLE public.web_check DROP CONSTRAINT web_check_pkey, ADD PRIMARY KEY (site_id, key);
    ALTER TABLE public.web_copilot DROP CONSTRAINT web_copilot_pkey, ADD PRIMARY KEY (site_id, kind, k);
  END IF;
END $$;
DROP INDEX IF EXISTS public.idx_web_run_job;
CREATE INDEX IF NOT EXISTS idx_web_run_site_job ON public.web_run (site_id, job, started_at DESC);

-- ---------------------------------------------------------------- helpers
-- Which website: the one asked for, or the primary website when none is given.
CREATE OR REPLACE FUNCTION crm_private.web_site_id(p_site uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  SELECT s.id INTO v FROM public.web_site s WHERE CASE WHEN p_site IS NULL THEN s.is_primary ELSE s.id = p_site END;
  IF v IS NULL THEN RAISE EXCEPTION 'This website is not in the CRM any more' USING ERRCODE = 'PT404'; END IF;
  RETURN v;
END $$;
CREATE OR REPLACE FUNCTION crm_private.web_site_url(p_site uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT s.url FROM public.web_site s WHERE s.id = p_site $$;
-- Search Console site and GA4 property: the website's own; the primary website falls back to the ones in Connections & keys.
CREATE OR REPLACE FUNCTION crm_private.web_site_gsc(p_site uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(nullif(s.gsc_url, ''), CASE WHEN s.is_primary THEN crm_private.web_google_cfg('site_gsc_url') END) FROM public.web_site s WHERE s.id = p_site $$;
CREATE OR REPLACE FUNCTION crm_private.web_site_ga4(p_site uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(nullif(s.ga4_property, ''), CASE WHEN s.is_primary THEN nullif(regexp_replace(coalesce(crm_private.web_google_cfg('site_ga4_property'), ''), '\D', '', 'g'), '') END)
    FROM public.web_site s WHERE s.id = p_site $$;
CREATE OR REPLACE FUNCTION crm_private.web_site_leads(p_site uuid) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(ARRAY(SELECT lower(btrim(x)) FROM unnest(s.lead_sources) x WHERE btrim(x) <> ''), '{}') FROM public.web_site s WHERE s.id = p_site $$;

-- ---------------------------------------------------------------- the existing reads, now per website
-- Each function is rewritten from its live definition: a website argument is added and every Website table is read
-- through "WHERE site_id = <that website>". Every edit is checked; the migration stops if one does not apply.
CREATE OR REPLACE FUNCTION pg_temp.web_rep(p_src text, p_old text, p_new text, p_min int DEFAULT 1) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE n int := (length(p_src) - length(replace(p_src, p_old, ''))) / greatest(length(p_old), 1);
BEGIN
  IF n < p_min THEN RAISE EXCEPTION 'migration 148: expected % x "%" , found %', p_min, left(p_old, 80), n; END IF;
  RETURN replace(p_src, p_old, p_new);
END $$;
CREATE OR REPLACE FUNCTION pg_temp.web_tables(p_src text, p_site text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(replace(p_src,
    'public.web_row', format('(SELECT * FROM public.web_row WHERE site_id = %s)', p_site)),
    'public.web_page', format('(SELECT * FROM public.web_page WHERE site_id = %s)', p_site)),
    'public.web_check', format('(SELECT * FROM public.web_check WHERE site_id = %s)', p_site)),
    'public.web_copilot', format('(SELECT * FROM public.web_copilot WHERE site_id = %s)', p_site)),
    'public.web_run', format('(SELECT * FROM public.web_run WHERE site_id = %s)', p_site)) $$;
CREATE OR REPLACE FUNCTION pg_temp.web_head(p_def text, p_fn regprocedure, p_add text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE a text := pg_get_function_arguments(p_fn); nm text := p_fn::text;
BEGIN
  nm := split_part(nm, '(', 1);
  IF nm NOT LIKE '%.%' THEN nm := 'public.' || nm; END IF;
  RETURN pg_temp.web_rep(p_def, format('%s(%s)', nm, a), format('%s(%s%s)', nm, CASE WHEN a = '' THEN '' ELSE a || ', ' END, p_add));
END $$;

DO $$
DECLARE d text;
BEGIN
  -- crm_private.web_queries(site): the searches of one website (the caller passes a resolved website id)
  IF to_regprocedure('crm_private.web_queries()') IS NOT NULL THEN
    d := pg_get_functiondef('crm_private.web_queries()'::regprocedure);
    d := pg_temp.web_head(d, 'crm_private.web_queries()'::regprocedure, 'p_site uuid');
    d := pg_temp.web_rep(d, 'public.web_row', 'public.web_row', 3);
    d := pg_temp.web_tables(d, 'p_site');
    d := pg_temp.web_rep(d, 'crm_private.web_is_brand(c.k1)',
           'coalesce(c.k1 ~* (SELECT nullif(s.brand_re, '''') FROM public.web_site s WHERE s.id = p_site), false)');
    EXECUTE d;
    DROP FUNCTION crm_private.web_queries();
  END IF;

  -- public.api_web_overview(site)
  IF to_regprocedure('public.api_web_overview()') IS NOT NULL THEN
    d := pg_get_functiondef('public.api_web_overview()'::regprocedure);
    d := pg_temp.web_head(d, 'public.api_web_overview()'::regprocedure, 'p_site uuid DEFAULT NULL');
    d := pg_temp.web_tables(d, 'v_site');
    d := pg_temp.web_rep(d, 'site text := crm_private.web_cfg(''site_url'');',
           'v_site uuid := crm_private.web_site_id(p_site); site text := crm_private.web_site_url(v_site); v_leads text[] := crm_private.web_site_leads(v_site);');
    d := pg_temp.web_rep(d, 'crm_private.web_queries()', 'crm_private.web_queries(v_site)', 9);
    d := pg_temp.web_rep(d, 'crm_private.web_google_cfg(''site_gsc_url'')', 'crm_private.web_site_gsc(v_site)');
    d := pg_temp.web_rep(d, 'crm_private.web_google_cfg(''site_ga4_property'')', 'crm_private.web_site_ga4(v_site)');
    d := pg_temp.web_rep(d, 'IF to_regclass(''public.lead'') IS NOT NULL THEN', 'IF to_regclass(''public.lead'') IS NOT NULL AND cardinality(v_leads) > 0 THEN');
    d := pg_temp.web_rep(d, 'FROM public.lead l WHERE l.created_at > now() - interval ''56 days'')',
           'FROM public.lead l WHERE l.created_at > now() - interval ''56 days'' AND lower(btrim(l.utm_source)) = ANY ($1))');
    d := pg_temp.web_rep(d, 'FROM w $q$ INTO leads;', 'FROM w $q$ INTO leads USING v_leads;');
    d := pg_temp.web_rep(d, '''site'', site,', '''site'', site, ''site_id'', v_site, ''site_name'', (SELECT s.name FROM public.web_site s WHERE s.id = v_site),');
    d := pg_temp.web_rep(d, 'whose data stream is weoneaviation.in.', 'whose data stream is this website.');
    EXECUTE d;
    DROP FUNCTION public.api_web_overview();
  END IF;

  -- public.api_web_queries(filter, q, limit, site)
  IF to_regprocedure('public.api_web_queries(text, text, int)') IS NOT NULL THEN
    d := pg_get_functiondef('public.api_web_queries(text, text, int)'::regprocedure);
    d := pg_temp.web_head(d, 'public.api_web_queries(text, text, int)'::regprocedure, 'p_site uuid DEFAULT NULL');
    d := pg_temp.web_tables(d, 'v_site');
    d := pg_temp.web_rep(d, 'DECLARE f text', 'DECLARE v_site uuid := crm_private.web_site_id(p_site); f text');
    d := pg_temp.web_rep(d, 'crm_private.web_queries()', 'crm_private.web_queries(v_site)', 2);
    EXECUTE d;
    DROP FUNCTION public.api_web_queries(text, text, int);
  END IF;

  -- public.api_web_trend(site)
  IF to_regprocedure('public.api_web_trend()') IS NOT NULL THEN
    d := pg_get_functiondef('public.api_web_trend()'::regprocedure);
    d := pg_temp.web_head(d, 'public.api_web_trend()'::regprocedure, 'p_site uuid DEFAULT NULL');
    d := pg_temp.web_rep(d, 'public.web_row', 'public.web_row', 3);
    d := pg_temp.web_tables(d, 'v_site');
    IF d !~ '\$function\$\s*BEGIN' THEN RAISE EXCEPTION 'migration 148: api_web_trend body changed'; END IF;
    d := regexp_replace(d, '\$function\$\s*BEGIN', '$function$ DECLARE v_site uuid := crm_private.web_site_id(p_site); BEGIN');
    EXECUTE d;
    DROP FUNCTION public.api_web_trend();
  END IF;
END $$;

-- ---------------------------------------------------------------- writes from the collector, per website
DROP FUNCTION IF EXISTS public.svc_web_work();
CREATE OR REPLACE FUNCTION public.svc_web_work(p_site uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid := crm_private.web_site_id(p_site); s public.web_site; pages text[];
BEGIN
  SELECT * INTO s FROM public.web_site WHERE id = v;
  IF s.url IS NOT NULL THEN
    pages := ARRAY(SELECT DISTINCT p FROM (
      SELECT s.url AS p
      UNION ALL SELECT rtrim(s.url, '/') || CASE WHEN x LIKE '/%' THEN x ELSE '/' || x END
        FROM unnest(regexp_split_to_array(s.key_pages, '\s*\n\s*')) x WHERE x <> ''
      UNION ALL SELECT k1 FROM (SELECT r.k1 FROM public.web_row r WHERE r.site_id = v AND r.src = 'gsc' AND r.kind = 'page' AND r.win = 'cur'
                                 ORDER BY (r.m->>'clicks')::numeric DESC LIMIT 5) t WHERE s.key_pages = '') z LIMIT 8);
  END IF;
  RETURN jsonb_build_object('site_id', v, 'name', s.name, 'site_url', s.url, 'key_pages', to_jsonb(coalesce(pages, '{}')),
    'gsc_url', crm_private.web_site_gsc(v), 'ga4_property', crm_private.web_site_ga4(v),
    'client_id', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_id'),
    'client_secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_ads_client_secret'),
    'refresh_token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'ads_google_site_refresh_token'),
    'psi_key', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_web_psi_api_key'));
END $$;

DROP FUNCTION IF EXISTS public.svc_web_save(text, text[], jsonb);
CREATE OR REPLACE FUNCTION public.svc_web_save(p_src text, p_kinds text[], p_rows jsonb, p_site uuid DEFAULT NULL) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; v uuid := crm_private.web_site_id(p_site);
BEGIN
  IF p_src NOT IN ('gsc', 'ga') OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'bad rows'; END IF;
  DELETE FROM public.web_row WHERE site_id = v AND src = p_src AND kind = ANY (p_kinds);
  INSERT INTO public.web_row (site_id, src, kind, k1, k2, win, m)
  SELECT v, p_src, r->>'kind', left(r->>'k1', 400), left(coalesce(r->>'k2', ''), 400), r->>'win', coalesce(r->'m', '{}')
    FROM jsonb_array_elements(p_rows) r
   WHERE r->>'kind' = ANY (p_kinds) AND r->>'win' IN ('cur', 'prev') AND coalesce(r->>'k1', '') <> ''
  ON CONFLICT (site_id, src, kind, k1, k2, win) DO UPDATE SET m = EXCLUDED.m, at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

DROP FUNCTION IF EXISTS public.svc_web_pages_save(jsonb);
CREATE OR REPLACE FUNCTION public.svc_web_pages_save(p_rows jsonb, p_site uuid DEFAULT NULL) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; v uuid := crm_private.web_site_id(p_site);
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'bad rows'; END IF;
  DELETE FROM public.web_page WHERE site_id = v;
  INSERT INTO public.web_page (site_id, url, status, ms, title, title_len, description_len, h1_count, canonical, noindex, schema, issues, links, broken)
  SELECT DISTINCT ON (r->>'url') v, left(r->>'url', 600), (r->>'status')::int, (r->>'ms')::int, left(r->>'title', 300), (r->>'title_len')::int,
         (r->>'description_len')::int, (r->>'h1_count')::int, left(r->>'canonical', 600), coalesce((r->>'noindex')::boolean, false),
         coalesce(ARRAY(SELECT left(x, 80) FROM jsonb_array_elements_text(coalesce(r->'schema', '[]')) x), '{}'),
         coalesce(ARRAY(SELECT left(x, 40) FROM jsonb_array_elements_text(coalesce(r->'issues', '[]')) x), '{}'),
         coalesce((r->>'links')::int, 0), coalesce(r->'broken', '[]')
    FROM jsonb_array_elements(p_rows) r WHERE coalesce(r->>'url', '') <> '';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

DROP FUNCTION IF EXISTS public.svc_web_check_save(text, jsonb);
CREATE OR REPLACE FUNCTION public.svc_web_check_save(p_key text, p_data jsonb, p_site uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.web_check (site_id, key, data, at) VALUES (crm_private.web_site_id(p_site), left(p_key, 700), coalesce(p_data, '{}'), now())
  ON CONFLICT (site_id, key) DO UPDATE SET data = EXCLUDED.data, at = now();
END $$;

DROP FUNCTION IF EXISTS public.svc_web_checks_prune(text, text[]);
CREATE OR REPLACE FUNCTION public.svc_web_checks_prune(p_prefix text, p_keep text[], p_site uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  DELETE FROM public.web_check WHERE site_id = crm_private.web_site_id(p_site) AND key LIKE p_prefix || '%' AND NOT (key = ANY (p_keep));
END $$;

DROP FUNCTION IF EXISTS public.svc_web_run_begin(text);
CREATE OR REPLACE FUNCTION public.svc_web_run_begin(p_job text, p_site uuid DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid := crm_private.web_site_id(p_site); v_id bigint;
BEGIN
  DELETE FROM public.web_run WHERE started_at < now() - interval '60 days';
  INSERT INTO public.web_run (site_id, job) VALUES (v, p_job) RETURNING web_run.id INTO v_id;
  RETURN v_id;
END $$;

-- Bing Copilot CSV, per website.
DROP FUNCTION IF EXISTS public.api_web_copilot_upload(text, jsonb);
CREATE OR REPLACE FUNCTION public.api_web_copilot_upload(p_kind text, p_rows jsonb, p_site uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; v uuid := crm_private.web_site_id(p_site);
BEGIN
  IF NOT crm_private.web_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can upload' USING ERRCODE = 'PT403'; END IF;
  IF p_kind NOT IN ('query', 'page') OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Send the CSV rows' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN RAISE EXCEPTION 'Up to 5,000 rows' USING ERRCODE = 'PT422'; END IF;
  DELETE FROM public.web_copilot WHERE site_id = v AND kind = p_kind;
  INSERT INTO public.web_copilot (site_id, kind, k, citations)
  SELECT v, p_kind, left(r->>'k', 400), max(greatest(coalesce((r->>'citations')::numeric, 0), 0))
    FROM jsonb_array_elements(p_rows) r WHERE coalesce(r->>'k', '') <> '' GROUP BY left(r->>'k', 400);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('saved', n);
END $$;

-- ---------------------------------------------------------------- websites: list, settings, add/edit, remove
-- Settings of one website (for its Edit sheet) plus the shared PageSpeed key and Google sign-in status.
DROP FUNCTION IF EXISTS public.api_web_settings();
CREATE OR REPLACE FUNCTION public.api_web_settings(p_site uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid := crm_private.web_site_id(p_site); s public.web_site;
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO s FROM public.web_site WHERE id = v;
  RETURN jsonb_build_object('id', s.id, 'name', s.name, 'site_url', s.url, 'key_pages', s.key_pages, 'brand_terms', s.brand_terms,
    'lead_sources', to_jsonb(s.lead_sources), 'color', s.color, 'is_primary', s.is_primary,
    'gsc_url', crm_private.web_site_gsc(v), 'ga4_property', crm_private.web_site_ga4(v),
    'psi_key', CASE WHEN crm_private.is_admin() THEN (SELECT jsonb_build_object('set', true, 'last4', right(d.decrypted_secret, 4), 'updated_at', d.updated_at)
                 FROM vault.decrypted_secrets d WHERE d.name = 'crm_web_psi_api_key') END,
    'google_signin', EXISTS (SELECT 1 FROM vault.secrets x WHERE x.name = 'ads_google_site_refresh_token'),
    'google_email', nullif((SELECT c.value FROM public.web_config c WHERE c.key = 'google_email'), ''));
END $$;

-- Add (p_id NULL) or change a website. Admin only. Address: just the domain (https:// and the last / are added).
DROP FUNCTION IF EXISTS public.api_web_settings_save(text, text, text);
CREATE OR REPLACE FUNCTION public.api_web_site_save(p_id uuid, p_name text, p_url text, p_gsc_url text DEFAULT NULL, p_ga4_property text DEFAULT NULL,
  p_key_pages text DEFAULT NULL, p_brand_terms text DEFAULT NULL, p_lead_sources text[] DEFAULT NULL, p_color text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  nm text := btrim(coalesce(p_name, '')); u text := lower(btrim(coalesce(p_url, ''))); g text := btrim(coalesce(p_gsc_url, ''));
  ga text := regexp_replace(regexp_replace(btrim(coalesce(p_ga4_property, '')), '^properties/', ''), '\s', '', 'g');
  pages text := btrim(coalesce(p_key_pages, '')); v uuid := p_id; o public.web_site; o_gsc text; o_ga text;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can add or change websites' USING ERRCODE = 'PT403'; END IF;
  IF nm = '' OR char_length(nm) > 60 THEN RAISE EXCEPTION 'Give the website a short name' USING ERRCODE = 'PT422'; END IF;
  IF u <> '' THEN
    u := regexp_replace(u, '^(https?://)?', 'https://');
    u := regexp_replace(u, '^(https://[^/?#]+).*$', '\1') || '/';
    IF u !~ '^https://[a-z0-9.-]+\.[a-z]{2,}/$' THEN RAISE EXCEPTION 'Web address looks like flystar.co.in' USING ERRCODE = 'PT422'; END IF;
  END IF;
  IF g <> '' AND g !~ '^(sc-domain:[a-z0-9.-]+\.[a-z]{2,}|https?://[^\s]+/)$' THEN
    RAISE EXCEPTION 'Search Console site looks like sc-domain:flystar.co.in or https://www.flystar.co.in/' USING ERRCODE = 'PT422'; END IF;
  IF ga <> '' AND ga !~ '^\d{5,15}$' THEN RAISE EXCEPTION 'GA4 property is the number in GA4 Admin > Property details (e.g. 430628737)' USING ERRCODE = 'PT422'; END IF;
  IF pages <> '' AND (array_length(regexp_split_to_array(pages, '\s*\n\s*'), 1) > 10 OR pages ~ '[<>"'' ]') THEN
    RAISE EXCEPTION 'Key pages: up to 10 paths, one per line (e.g. /cpl-course)' USING ERRCODE = 'PT422'; END IF;
  IF p_color IS NOT NULL AND p_color !~ '^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Colour looks like #0A63CE' USING ERRCODE = 'PT422'; END IF;
  IF u <> '' AND EXISTS (SELECT 1 FROM public.web_site s WHERE s.url = u AND s.id IS DISTINCT FROM p_id) THEN
    RAISE EXCEPTION 'This website is already in the list' USING ERRCODE = 'PT409'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.web_site (name, url, gsc_url, ga4_property, key_pages, brand_terms, lead_sources, color, sort, created_by)
    VALUES (nm, nullif(u, ''), nullif(g, ''), nullif(ga, ''), pages,
            coalesce(nullif(btrim(p_brand_terms), ''), lower(nm) || CASE WHEN u <> '' THEN ', ' || split_part(regexp_replace(u, '^https://(www\.)?', ''), '.', 1) ELSE '' END),
            coalesce(p_lead_sources, '{}'), coalesce(p_color, '#0A63CE'), coalesce((SELECT max(sort) + 1 FROM public.web_site), 1), crm_private.current_employee_id())
    RETURNING id INTO v;
  ELSE
    SELECT * INTO o FROM public.web_site WHERE id = p_id;
    IF o.id IS NULL THEN RAISE EXCEPTION 'This website is not in the CRM any more' USING ERRCODE = 'PT404'; END IF;
    o_gsc := crm_private.web_site_gsc(p_id); o_ga := crm_private.web_site_ga4(p_id);
    UPDATE public.web_site SET name = nm, url = nullif(u, ''), gsc_url = nullif(g, ''), ga4_property = nullif(ga, ''),
      key_pages = coalesce(CASE WHEN p_key_pages IS NULL THEN NULL ELSE pages END, key_pages),
      brand_terms = coalesce(p_brand_terms, brand_terms), lead_sources = coalesce(p_lead_sources, lead_sources),
      color = coalesce(p_color, color), updated_at = now()
     WHERE id = p_id;
    -- a new address means the old numbers belong to another site
    IF o.url IS DISTINCT FROM nullif(u, '') THEN
      DELETE FROM public.web_page WHERE site_id = p_id; DELETE FROM public.web_check WHERE site_id = p_id;
    END IF;
    IF o.url IS DISTINCT FROM nullif(u, '') OR coalesce(o_gsc, '') <> g THEN DELETE FROM public.web_row WHERE site_id = p_id AND src = 'gsc'; END IF;
    IF coalesce(o_ga, '') <> ga THEN DELETE FROM public.web_row WHERE site_id = p_id AND src = 'ga'; END IF;
  END IF;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, $2, ''website'', $3)'
      USING crm_private.current_employee_id(), CASE WHEN p_id IS NULL THEN 'web_site_added' ELSE 'web_site_saved' END,
            jsonb_build_object('id', v, 'name', nm, 'url', nullif(u, ''));
  END IF;
  RETURN jsonb_build_object('id', v, 'saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_web_site_remove(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.web_site;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can remove websites' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO s FROM public.web_site WHERE id = p_id;
  IF s.id IS NULL THEN RETURN jsonb_build_object('removed', false); END IF;
  IF s.is_primary THEN RAISE EXCEPTION '% is the main website and cannot be removed', s.name USING ERRCODE = 'PT422'; END IF;
  DELETE FROM public.web_site WHERE id = p_id;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, ''web_site_removed'', ''website'', $2)'
      USING crm_private.current_employee_id(), jsonb_build_object('id', s.id, 'name', s.name, 'url', s.url);
  END IF;
  RETURN jsonb_build_object('removed', true);
END $$;

-- Shared settings: PageSpeed key (NULL keeps, '' removes) and the e-mail of the connected Google account (shown in the add steps).
CREATE OR REPLACE FUNCTION public.api_web_prefs_save(p_psi_key text DEFAULT NULL, p_google_email text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text := btrim(coalesce(p_psi_key, '')); e text := lower(btrim(coalesce(p_google_email, ''))); sid uuid;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change Website settings' USING ERRCODE = 'PT403'; END IF;
  IF p_psi_key IS NOT NULL THEN
    SELECT id INTO sid FROM vault.secrets WHERE name = 'crm_web_psi_api_key';
    IF k = '' THEN DELETE FROM vault.secrets WHERE name = 'crm_web_psi_api_key';
    ELSIF k !~ '^[A-Za-z0-9_-]{30,60}$' THEN RAISE EXCEPTION 'A Google API key is about 39 letters and digits (starts with AIza)' USING ERRCODE = 'PT422';
    ELSIF sid IS NULL THEN PERFORM vault.create_secret(k, 'crm_web_psi_api_key', 'CRM Website: PageSpeed Insights API key');
    ELSE PERFORM vault.update_secret(sid, k); END IF;
  END IF;
  IF p_google_email IS NOT NULL THEN
    IF e <> '' AND e !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' THEN RAISE EXCEPTION 'That does not look like an e-mail address' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.web_config (key, value) VALUES ('google_email', e) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  END IF;
  RETURN jsonb_build_object('saved', true);
END $$;

-- The Website home: one card per website with its headline numbers, health and the one thing worth doing next.
CREATE OR REPLACE FUNCTION public.api_web_sites() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.web_site; out jsonb := '[]'; one jsonb; gsc text; ga4 text; q jsonb; v_leads text[]; leads jsonb;
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  FOR s IN SELECT * FROM public.web_site ORDER BY is_primary DESC, sort, created_at LOOP
    gsc := crm_private.web_site_gsc(s.id); ga4 := crm_private.web_site_ga4(s.id); v_leads := crm_private.web_site_leads(s.id); leads := NULL;
    SELECT jsonb_build_object('almost', count(*) FILTER (WHERE almost), 'dropping', count(*) FILTER (WHERE dropping), 'queries', count(*),
             'top', (SELECT x.query FROM crm_private.web_queries(s.id) x WHERE NOT x.brand ORDER BY x.clicks DESC, x.impressions DESC LIMIT 1))
      INTO q FROM crm_private.web_queries(s.id);
    IF to_regclass('public.lead') IS NOT NULL AND cardinality(v_leads) > 0 THEN
      EXECUTE $q$SELECT jsonb_build_object('cur', count(*) FILTER (WHERE l.created_at > now() - interval '28 days'),
                  'prev', count(*) FILTER (WHERE l.created_at <= now() - interval '28 days'))
                  FROM public.lead l WHERE l.created_at > now() - interval '56 days' AND lower(btrim(l.utm_source)) = ANY ($1)$q$ INTO leads USING v_leads;
    END IF;
    SELECT jsonb_build_object(
      'id', s.id, 'name', s.name, 'url', s.url, 'color', s.color, 'is_primary', s.is_primary,
      'gsc_url', gsc, 'ga4_property', ga4, 'lead_sources', to_jsonb(s.lead_sources),
      'search', (SELECT jsonb_build_object(
          'clicks', sum((r.m->>'clicks')::numeric) FILTER (WHERE r.win = 'cur'), 'clicks_prev', sum((r.m->>'clicks')::numeric) FILTER (WHERE r.win = 'prev'),
          'impressions', sum((r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'cur'), 'impressions_prev', sum((r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'prev'),
          'position', round(sum((r.m->>'position')::numeric * (r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'cur')
                            / nullif(sum((r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'cur'), 0), 1),
          'position_prev', round(sum((r.m->>'position')::numeric * (r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'prev')
                            / nullif(sum((r.m->>'impressions')::numeric) FILTER (WHERE r.win = 'prev'), 0), 1),
          'days', count(*) FILTER (WHERE r.win = 'cur'),
          'spark', coalesce(jsonb_agg((r.m->>'clicks')::numeric ORDER BY r.k1) FILTER (WHERE r.win = 'cur'), '[]'))
        FROM public.web_row r WHERE r.site_id = s.id AND r.src = 'gsc' AND r.kind = 'date'),
      'queries', q,
      'visitors', (SELECT jsonb_build_object(
          'users', sum((r.m->>'activeUsers')::numeric) FILTER (WHERE r.win = 'cur'), 'users_prev', sum((r.m->>'activeUsers')::numeric) FILTER (WHERE r.win = 'prev'),
          'key_events', sum((r.m->>'keyEvents')::numeric) FILTER (WHERE r.win = 'cur'), 'days', count(*) FILTER (WHERE r.win = 'cur'),
          'spark', coalesce(jsonb_agg((r.m->>'activeUsers')::numeric ORDER BY r.k1) FILTER (WHERE r.win = 'cur'), '[]'))
        FROM public.web_row r WHERE r.site_id = s.id AND r.src = 'ga' AND r.kind = 'date'),
      'ai_visits', (SELECT coalesce(sum((r.m->>'sessions')::numeric), 0) FROM public.web_row r
                     WHERE r.site_id = s.id AND r.src = 'ga' AND r.kind = 'source' AND r.win = 'cur' AND crm_private.web_ai_tool(r.k1) IS NOT NULL),
      'speed', (SELECT jsonb_build_object('score', (c.data->'scores'->>'performance')::numeric, 'overall', c.data->>'overall')
                  FROM public.web_check c WHERE c.site_id = s.id AND c.key = 'psi:' || s.url || '|mobile'),
      'health', jsonb_build_object(
          'pages', (SELECT count(*) FROM public.web_page p WHERE p.site_id = s.id),
          'errors', (SELECT count(*) FROM public.web_page p WHERE p.site_id = s.id AND (p.status IS NULL OR p.status >= 400)),
          'noindex', (SELECT count(*) FROM public.web_page p WHERE p.site_id = s.id AND p.noindex),
          'broken', (SELECT count(DISTINCT b->>'url') FROM public.web_page p, jsonb_array_elements(p.broken) b WHERE p.site_id = s.id),
          'not_indexed', (SELECT count(*) FROM public.web_check c WHERE c.site_id = s.id AND c.key LIKE 'inspect:%' AND coalesce(c.data->>'verdict', '') NOT IN ('PASS', '')),
          'home', (SELECT c.data FROM public.web_check c WHERE c.site_id = s.id AND c.key = 'home')),
      'leads', leads,
      'runs', (SELECT jsonb_build_object('at', max(coalesce(r.finished_at, r.started_at)),
                 'running', bool_or(r.status = 'running' AND r.started_at > now() - interval '10 minutes'),
                 'errors', coalesce(jsonb_agg(jsonb_build_object('job', r.job, 'detail', r.detail)) FILTER (WHERE r.status = 'error'), '[]'))
                 FROM (SELECT DISTINCT ON (x.job) x.* FROM public.web_run x WHERE x.site_id = s.id ORDER BY x.job, x.started_at DESC) r))
      INTO one;
    out := out || one;
  END LOOP;
  RETURN jsonb_build_object('sites', out, 'can_run', crm_private.web_can_run(), 'is_admin', crm_private.is_admin(),
    'google_signin', EXISTS (SELECT 1 FROM vault.secrets x WHERE x.name = 'ads_google_site_refresh_token'),
    'google_email', nullif((SELECT c.value FROM public.web_config c WHERE c.key = 'google_email'), ''),
    'checked_at', now());
END $$;

-- Research: searches where two or more of your websites show up in Google (they compete for the same people).
CREATE OR REPLACE FUNCTION public.api_web_shared(p_limit int DEFAULT 40) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.web_can_view() THEN RAISE EXCEPTION 'You do not have access to the Website section' USING ERRCODE = 'PT403'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY (x->>'impressions')::numeric DESC) FROM (
    SELECT jsonb_build_object('query', lower(r.k1), 'impressions', sum((r.m->>'impressions')::numeric), 'clicks', sum((r.m->>'clicks')::numeric),
             'sites', jsonb_agg(jsonb_build_object('id', r.site_id, 'name', s.name, 'color', s.color, 'clicks', (r.m->>'clicks')::numeric,
                       'impressions', (r.m->>'impressions')::numeric, 'position', (r.m->>'position')::numeric) ORDER BY (r.m->>'position')::numeric)) x
      FROM public.web_row r JOIN public.web_site s ON s.id = r.site_id
     WHERE r.src = 'gsc' AND r.kind = 'query' AND r.win = 'cur'
     GROUP BY lower(r.k1) HAVING count(DISTINCT r.site_id) >= 2
     ORDER BY sum((r.m->>'impressions')::numeric) DESC LIMIT least(greatest(coalesce(p_limit, 40), 1), 200)) z), '[]');
END $$;

-- ---------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION crm_private.web_site_id(uuid), crm_private.web_site_url(uuid), crm_private.web_site_gsc(uuid), crm_private.web_site_ga4(uuid),
  crm_private.web_site_leads(uuid), crm_private.web_queries(uuid), crm_private.web_brand_re(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_web_overview(uuid), public.api_web_queries(text, text, int, uuid), public.api_web_trend(uuid), public.api_web_settings(uuid),
  public.api_web_site_save(uuid, text, text, text, text, text, text, text[], text), public.api_web_site_remove(uuid), public.api_web_prefs_save(text, text),
  public.api_web_sites(), public.api_web_shared(int), public.api_web_copilot_upload(text, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_web_overview(uuid), public.api_web_queries(text, text, int, uuid), public.api_web_trend(uuid), public.api_web_settings(uuid),
  public.api_web_site_save(uuid, text, text, text, text, text, text, text[], text), public.api_web_site_remove(uuid), public.api_web_prefs_save(text, text),
  public.api_web_sites(), public.api_web_shared(int), public.api_web_copilot_upload(text, jsonb, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_web_work(uuid), public.svc_web_save(text, text[], jsonb, uuid), public.svc_web_pages_save(jsonb, uuid),
  public.svc_web_check_save(text, jsonb, uuid), public.svc_web_checks_prune(text, text[], uuid), public.svc_web_run_begin(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_web_work(uuid), public.svc_web_save(text, text[], jsonb, uuid), public.svc_web_pages_save(jsonb, uuid),
  public.svc_web_check_save(text, jsonb, uuid), public.svc_web_checks_prune(text, text[], uuid), public.svc_web_run_begin(text, uuid) TO service_role;

-- ---------------------------------------------------------------- nightly collection: every website with an address
DO $$
DECLARE hdr text := $h$jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token'))$h$;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-web-data', 'crm-web-scan', 'crm-web-speed');
    PERFORM cron.schedule('crm-web-data', '40 22 * * *', format($j$SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
      headers := %s, body := jsonb_build_object('jobs', jsonb_build_array('search', 'visitors'), 'site', s.id), timeout_milliseconds := 150000)
      FROM public.web_site s WHERE s.url IS NOT NULL$j$, hdr));
    PERFORM cron.schedule('crm-web-scan', '55 22 * * *', format($j$SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
      headers := %s, body := jsonb_build_object('jobs', jsonb_build_array('scan'), 'site', s.id), timeout_milliseconds := 150000)
      FROM public.web_site s WHERE s.url IS NOT NULL$j$, hdr));
    PERFORM cron.schedule('crm-web-speed', '10 23 * * *', format($j$SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-website',
      headers := %s, body := jsonb_build_object('jobs', jsonb_build_array('speed', 'index'), 'site', s.id), timeout_milliseconds := 150000)
      FROM public.web_site s WHERE s.url IS NOT NULL$j$, hdr));
  END IF;
END $$;
