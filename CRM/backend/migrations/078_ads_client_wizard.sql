-- 078: ADS client wizard + import of existing Google Ads / Meta accounts. Additive only.
--   * ads_clients: platforms (google / meta / both), industry preset, country, per-platform settings, draft flag.
--   * ads_accounts: login_customer_id (the Google manager account an imported account is reached through).
--   * ads_options: the option lists the wizard shows, copied from the platforms' own docs (source_url per row).
--     Saving validates against this table, so the CRM only stores values Google / Meta accept.
--   * api_ads_options(), api_ads_client_save() (replaced: wizard fields + drafts), api_ads_import().
-- Re-runnable.

ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS platforms text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS preset text;
ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS country text;
ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS google_settings jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS meta_settings jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.ads_clients ADD COLUMN IF NOT EXISTS is_draft boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  ALTER TABLE public.ads_clients ADD CONSTRAINT ads_clients_platforms_chk CHECK (platforms <@ ARRAY['google','meta']::text[]);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.ads_clients ADD CONSTRAINT ads_clients_country_chk CHECK (country IS NULL OR country ~ '^[A-Z]{2}$');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Existing clients: platforms from the accounts they already have.
UPDATE public.ads_clients c SET platforms = sub.p
  FROM (SELECT client_id, array_agg(DISTINCT platform ORDER BY platform) p FROM public.ads_accounts GROUP BY 1) sub
 WHERE sub.client_id = c.id AND c.platforms = '{}';

ALTER TABLE public.ads_accounts ADD COLUMN IF NOT EXISTS login_customer_id text;
DO $$ BEGIN
  ALTER TABLE public.ads_accounts ADD CONSTRAINT ads_accounts_login_chk CHECK (login_customer_id IS NULL OR login_customer_id ~ '^[0-9]{10}$');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.ads_options (
  platform text NOT NULL CHECK (platform IN ('google', 'meta', 'any')),
  kind text NOT NULL,
  value text NOT NULL,
  label text NOT NULL,
  hint text,
  extra jsonb NOT NULL DEFAULT '{}',        -- e.g. campaign type -> objectives it supports; preset -> defaults
  sort int NOT NULL DEFAULT 0,
  source_url text,
  PRIMARY KEY (platform, kind, value));
ALTER TABLE public.ads_options ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_options FROM anon, authenticated;

-- Google Ads campaign objectives and campaign types (Google Ads Help, "About campaign objectives", checked 2026-11-10).
-- "YouTube reach, views, and engagements" is the objective Google previously called "Awareness and consideration".
INSERT INTO public.ads_options (platform, kind, value, label, sort, source_url, extra) VALUES
  ('google', 'objective', 'SALES', 'Sales', 1, 'https://support.google.com/google-ads/answer/7450050', '{}'),
  ('google', 'objective', 'LEADS', 'Leads', 2, 'https://support.google.com/google-ads/answer/7450050', '{}'),
  ('google', 'objective', 'WEBSITE_TRAFFIC', 'Website traffic', 3, 'https://support.google.com/google-ads/answer/7450050', '{}'),
  ('google', 'objective', 'YOUTUBE_REACH', 'YouTube reach, views, and engagements', 4, 'https://support.google.com/google-ads/answer/7450050', '{}'),
  ('google', 'objective', 'APP_PROMOTION', 'App promotion', 5, 'https://support.google.com/google-ads/answer/7450050', '{}'),
  ('google', 'campaign_type', 'PERFORMANCE_MAX', 'Performance Max', 1, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS"]}'),
  ('google', 'campaign_type', 'SEARCH', 'Search', 2, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS","WEBSITE_TRAFFIC"]}'),
  ('google', 'campaign_type', 'DISPLAY', 'Display', 3, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS","WEBSITE_TRAFFIC","YOUTUBE_REACH"]}'),
  ('google', 'campaign_type', 'DEMAND_GEN', 'Demand Gen', 4, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS","WEBSITE_TRAFFIC","YOUTUBE_REACH"]}'),
  ('google', 'campaign_type', 'SHOPPING', 'Shopping', 5, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS","WEBSITE_TRAFFIC"]}'),
  ('google', 'campaign_type', 'VIDEO', 'Video', 6, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["SALES","LEADS","WEBSITE_TRAFFIC","YOUTUBE_REACH"]}'),
  ('google', 'campaign_type', 'APP', 'App', 7, 'https://support.google.com/google-ads/answer/7450050', '{"objectives":["APP_PROMOTION"]}'),
  -- Smart Bidding focus as Google Ads shows it (API: BiddingStrategyType)
  ('google', 'bidding', 'MAXIMIZE_CONVERSIONS', 'Conversions', 1, 'https://support.google.com/google-ads/answer/2472725', '{}'),
  ('google', 'bidding', 'MAXIMIZE_CONVERSION_VALUE', 'Conversion value', 2, 'https://support.google.com/google-ads/answer/2472725', '{}'),
  ('google', 'bidding', 'TARGET_SPEND', 'Clicks', 3, 'https://support.google.com/google-ads/answer/2472725', '{}'),
  ('google', 'bidding', 'TARGET_IMPRESSION_SHARE', 'Impression share', 4, 'https://support.google.com/google-ads/answer/2472725', '{}'),
  ('google', 'bidding', 'MANUAL_CPC', 'Manual CPC', 5, 'https://support.google.com/google-ads/answer/2472725', '{}')
ON CONFLICT (platform, kind, value) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, source_url = EXCLUDED.source_url, extra = EXCLUDED.extra;

-- Meta: campaign objective (API enum OUTCOME_*, Ads Manager names), special ad categories, bid strategy
-- (Marketing API reference: ad account campaigns and special ad category, checked 2026-11-10).
INSERT INTO public.ads_options (platform, kind, value, label, hint, sort, source_url, extra) VALUES
  ('meta', 'objective', 'OUTCOME_AWARENESS', 'Awareness', NULL, 1, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'objective', 'OUTCOME_TRAFFIC', 'Traffic', NULL, 2, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'objective', 'OUTCOME_ENGAGEMENT', 'Engagement', NULL, 3, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'objective', 'OUTCOME_LEADS', 'Leads', NULL, 4, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'objective', 'OUTCOME_APP_PROMOTION', 'App promotion', NULL, 5, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'objective', 'OUTCOME_SALES', 'Sales', NULL, 6, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'special_ad_category', 'NONE', 'None', 'Most businesses', 0, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/audiences/special-ad-category', '{}'),
  ('meta', 'special_ad_category', 'FINANCIAL_PRODUCTS_SERVICES', 'Financial products and services', 'Credit, loans, insurance, investments. Targeting is restricted.', 1, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/audiences/special-ad-category', '{}'),
  ('meta', 'special_ad_category', 'EMPLOYMENT', 'Employment', 'Job offers, internships, recruiting. Targeting is restricted.', 2, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/audiences/special-ad-category', '{}'),
  ('meta', 'special_ad_category', 'HOUSING', 'Housing', 'Property sale or rental, home loans. Targeting is restricted.', 3, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/audiences/special-ad-category', '{}'),
  ('meta', 'special_ad_category', 'ISSUES_ELECTIONS_POLITICS', 'Social issues, elections or politics', 'Needs ad authorisation and a "Paid for by" disclaimer in that country.', 4, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/audiences/special-ad-category', '{}'),
  ('meta', 'bid_strategy', 'LOWEST_COST_WITHOUT_CAP', 'Highest volume', NULL, 1, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'bid_strategy', 'COST_CAP', 'Cost per result goal', NULL, 2, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'bid_strategy', 'LOWEST_COST_WITH_MIN_ROAS', 'ROAS goal', NULL, 3, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}'),
  ('meta', 'bid_strategy', 'LOWEST_COST_WITH_BID_CAP', 'Bid cap', NULL, 4, 'https://developers.facebook.com/documentation/ads-commerce/marketing-api/reference/ad-account/campaigns', '{}')
ON CONFLICT (platform, kind, value) DO UPDATE SET label = EXCLUDED.label, hint = EXCLUDED.hint, sort = EXCLUDED.sort, source_url = EXCLUDED.source_url;

-- Industry presets: starting points only (each can be changed in the wizard). kpi = the number the dashboard leads with.
INSERT INTO public.ads_options (platform, kind, value, label, sort, extra) VALUES
  ('any', 'preset', 'education', 'Education / training institute', 1, '{"google":{"objective":"LEADS","campaign_types":["SEARCH","PERFORMANCE_MAX"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"qualified_cpl"}'),
  ('any', 'preset', 'services', 'Service business', 2, '{"google":{"objective":"LEADS","campaign_types":["SEARCH"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"qualified_cpl"}'),
  ('any', 'preset', 'local', 'Local business', 3, '{"google":{"objective":"LEADS","campaign_types":["SEARCH","PERFORMANCE_MAX"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"cpl"}'),
  ('any', 'preset', 'professional', 'Professional services', 4, '{"google":{"objective":"LEADS","campaign_types":["SEARCH"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"qualified_cpl"}'),
  ('any', 'preset', 'b2b', 'B2B', 5, '{"google":{"objective":"LEADS","campaign_types":["SEARCH"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"COST_CAP"},"kpi":"qualified_cpl"}'),
  ('any', 'preset', 'ecommerce', 'E-commerce', 6, '{"google":{"objective":"SALES","campaign_types":["PERFORMANCE_MAX","SHOPPING"],"bidding":"MAXIMIZE_CONVERSION_VALUE"},"meta":{"objective":"OUTCOME_SALES","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"crm_roas"}'),
  ('any', 'preset', 'technology', 'Technology / SaaS', 7, '{"google":{"objective":"LEADS","campaign_types":["SEARCH"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_LEADS","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"cac"}'),
  ('any', 'preset', 'app', 'Mobile app', 8, '{"google":{"objective":"APP_PROMOTION","campaign_types":["APP"],"bidding":"MAXIMIZE_CONVERSIONS"},"meta":{"objective":"OUTCOME_APP_PROMOTION","bid_strategy":"LOWEST_COST_WITHOUT_CAP"},"kpi":"cac"}'),
  ('any', 'preset', 'other', 'Other', 9, '{"kpi":"cpl"}')
ON CONFLICT (platform, kind, value) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, extra = EXCLUDED.extra;

CREATE OR REPLACE FUNCTION public.api_ads_options() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM (
    SELECT o.platform || '.' || o.kind AS k,
           jsonb_agg(jsonb_build_object('value', o.value, 'label', o.label, 'hint', o.hint, 'extra', o.extra, 'source_url', o.source_url) ORDER BY o.sort) AS v
      FROM public.ads_options o GROUP BY 1) s);
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_opt_ok(p_platform text, p_kind text, p_value text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.ads_options o WHERE o.platform = p_platform AND o.kind = p_kind AND o.value = p_value)
$$;

-- Validates and normalises the per-platform settings. Drafts skip the "required" checks, never the "valid value" checks.
CREATE OR REPLACE FUNCTION crm_private.ads_platform_settings(p_platform text, p_in jsonb, p_draft boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s jsonb := coalesce(p_in, '{}'); obj text := nullif(s->>'objective', ''); t text; cats text[]; ctry text;
        types text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(s->'campaign_types', '[]')));
BEGIN
  IF p_platform = 'google' THEN
    IF obj IS NULL AND NOT p_draft THEN RAISE EXCEPTION 'Google: pick a campaign objective' USING ERRCODE = 'PT422'; END IF;
    IF obj IS NOT NULL AND NOT crm_private.ads_opt_ok('google', 'objective', obj) THEN RAISE EXCEPTION 'Google: unknown objective' USING ERRCODE = 'PT422'; END IF;
    FOREACH t IN ARRAY types LOOP
      IF NOT crm_private.ads_opt_ok('google', 'campaign_type', t) THEN RAISE EXCEPTION 'Google: unknown campaign type %', t USING ERRCODE = 'PT422'; END IF;
      IF obj IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.ads_options o WHERE o.platform = 'google' AND o.kind = 'campaign_type'
                                           AND o.value = t AND o.extra->'objectives' ? obj) THEN
        RAISE EXCEPTION 'Google: % campaigns do not support the % objective', t, obj USING ERRCODE = 'PT422';
      END IF;
    END LOOP;
    IF NOT p_draft AND cardinality(types) = 0 THEN RAISE EXCEPTION 'Google: pick at least one campaign type' USING ERRCODE = 'PT422'; END IF;
    IF nullif(s->>'bidding', '') IS NOT NULL AND NOT crm_private.ads_opt_ok('google', 'bidding', s->>'bidding') THEN
      RAISE EXCEPTION 'Google: unknown bidding focus' USING ERRCODE = 'PT422'; END IF;
    RETURN jsonb_strip_nulls(jsonb_build_object('objective', obj, 'campaign_types', to_jsonb(types), 'bidding', nullif(s->>'bidding', '')));
  END IF;
  -- meta
  cats := ARRAY(SELECT jsonb_array_elements_text(coalesce(s->'special_ad_categories', '[]')));
  ctry := upper(nullif(s->>'special_ad_category_country', ''));
  IF obj IS NULL AND NOT p_draft THEN RAISE EXCEPTION 'Meta: pick a campaign objective' USING ERRCODE = 'PT422'; END IF;
  IF obj IS NOT NULL AND NOT crm_private.ads_opt_ok('meta', 'objective', obj) THEN RAISE EXCEPTION 'Meta: unknown objective' USING ERRCODE = 'PT422'; END IF;
  FOREACH t IN ARRAY cats LOOP
    IF NOT crm_private.ads_opt_ok('meta', 'special_ad_category', t) THEN RAISE EXCEPTION 'Meta: unknown special ad category %', t USING ERRCODE = 'PT422'; END IF;
  END LOOP;
  IF 'NONE' = ANY (cats) AND cardinality(cats) > 1 THEN RAISE EXCEPTION 'Meta: "None" cannot be combined with a special ad category' USING ERRCODE = 'PT422'; END IF;
  IF NOT p_draft AND cardinality(cats) = 0 THEN RAISE EXCEPTION 'Meta: answer the special ad category question (choose None if it does not apply)' USING ERRCODE = 'PT422'; END IF;
  IF 'ISSUES_ELECTIONS_POLITICS' = ANY (cats) AND ctry IS NULL AND NOT p_draft THEN
    RAISE EXCEPTION 'Meta: social issues, elections or politics ads need the country they run in' USING ERRCODE = 'PT422'; END IF;
  IF ctry IS NOT NULL AND ctry !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'Meta: country is a 2-letter code' USING ERRCODE = 'PT422'; END IF;
  IF nullif(s->>'bid_strategy', '') IS NOT NULL AND NOT crm_private.ads_opt_ok('meta', 'bid_strategy', s->>'bid_strategy') THEN
    RAISE EXCEPTION 'Meta: unknown bid strategy' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_strip_nulls(jsonb_build_object('objective', obj, 'special_ad_categories', to_jsonb(cats),
    'special_ad_category_country', CASE WHEN cats && ARRAY['FINANCIAL_PRODUCTS_SERVICES','EMPLOYMENT','HOUSING','ISSUES_ELECTIONS_POLITICS'] THEN ctry END,
    'bid_strategy', nullif(s->>'bid_strategy', ''), 'business_id', nullif(s->>'business_id', ''), 'page_id', nullif(s->>'page_id', '')));
END $$;

-- Replaces 076's version: same checks, plus wizard fields and drafts.
CREATE OR REPLACE FUNCTION public.api_ads_client_save(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cid uuid := nullif(p_data->>'id', '')::uuid; num text; draft boolean := coalesce((p_data->>'is_draft')::boolean, false);
        plats text[] := ARRAY(SELECT DISTINCT x FROM jsonb_array_elements_text(coalesce(p_data->'platforms', '[]')) x ORDER BY 1);
        gs jsonb := '{}'; ms jsonb := '{}'; site text := nullif(trim(p_data->>'website'), '');
        nums text[] := ARRAY['avg_order_value','gross_margin_pct','target_cpl','target_qualified_cpl','target_cac','max_cac',
                             'target_roas','ltv','monthly_budget','max_daily_budget'];
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF length(trim(coalesce(p_data->>'name', ''))) < 2 THEN RAISE EXCEPTION 'Client name is required' USING ERRCODE = 'PT422'; END IF;
  IF NOT (plats <@ ARRAY['google','meta']) THEN RAISE EXCEPTION 'Platforms are Google and/or Meta' USING ERRCODE = 'PT422'; END IF;
  IF NOT draft AND cardinality(plats) = 0 THEN RAISE EXCEPTION 'Pick Google, Meta or both' USING ERRCODE = 'PT422'; END IF;
  IF site IS NOT NULL AND site !~* '^https?://[^\s/$.?#][^\s]*\.[a-z]{2,}' THEN
    RAISE EXCEPTION 'Website must be a full address, e.g. https://example.com' USING ERRCODE = 'PT422'; END IF;
  FOREACH num IN ARRAY nums LOOP
    IF nullif(p_data->>num, '') IS NOT NULL AND (p_data->>num) !~ '^[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION '% must be a positive number', replace(num, '_', ' ') USING ERRCODE = 'PT422';
    END IF;
  END LOOP;
  IF nullif(p_data->>'gross_margin_pct', '') IS NOT NULL AND (p_data->>'gross_margin_pct')::numeric > 100 THEN
    RAISE EXCEPTION 'Gross margin is a percentage (0–100)' USING ERRCODE = 'PT422'; END IF;
  IF nullif(p_data->>'crm_segment', '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.ads_clients c
      WHERE c.crm_segment = p_data->>'crm_segment' AND c.id IS DISTINCT FROM cid) THEN
    RAISE EXCEPTION 'Another client is already linked to the % leads', p_data->>'crm_segment' USING ERRCODE = 'PT409';
  END IF;
  IF nullif(p_data->>'timezone', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = p_data->>'timezone') THEN
    RAISE EXCEPTION 'Unknown time zone' USING ERRCODE = 'PT422'; END IF;
  IF nullif(p_data->>'currency', '') IS NOT NULL AND upper(p_data->>'currency') !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Currency is a 3-letter code, e.g. INR' USING ERRCODE = 'PT422'; END IF;
  IF nullif(p_data->>'country', '') IS NOT NULL AND upper(p_data->>'country') !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'Country is a 2-letter code, e.g. IN' USING ERRCODE = 'PT422'; END IF;
  IF nullif(p_data->>'preset', '') IS NOT NULL AND NOT crm_private.ads_opt_ok('any', 'preset', p_data->>'preset') THEN
    RAISE EXCEPTION 'Unknown industry' USING ERRCODE = 'PT422'; END IF;
  IF 'google' = ANY (plats) THEN gs := crm_private.ads_platform_settings('google', p_data->'google_settings', draft); END IF;
  IF 'meta' = ANY (plats) THEN ms := crm_private.ads_platform_settings('meta', p_data->'meta_settings', draft); END IF;
  IF cid IS NULL THEN
    INSERT INTO public.ads_clients (name, created_by) VALUES (trim(p_data->>'name'), crm_private.current_employee_id()) RETURNING id INTO cid;
  ELSIF NOT EXISTS (SELECT 1 FROM public.ads_clients WHERE id = cid) THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = 'PT404';
  END IF;
  UPDATE public.ads_clients SET
    name = trim(p_data->>'name'), website = site,
    industry = coalesce(nullif(trim(p_data->>'industry'), ''), (SELECT o.label FROM public.ads_options o WHERE o.platform = 'any' AND o.kind = 'preset' AND o.value = p_data->>'preset')),
    preset = nullif(p_data->>'preset', ''), country = upper(nullif(p_data->>'country', '')),
    platforms = plats, google_settings = gs, meta_settings = ms, is_draft = draft,
    business_model = nullif(trim(p_data->>'business_model'), ''), products = nullif(trim(p_data->>'products'), ''),
    geography = nullif(trim(p_data->>'geography'), ''), audience = nullif(trim(p_data->>'audience'), ''),
    competitors = nullif(trim(p_data->>'competitors'), ''), objectives = nullif(trim(p_data->>'objectives'), ''),
    brand_notes = nullif(trim(p_data->>'brand_notes'), ''), restrictions = nullif(trim(p_data->>'restrictions'), ''),
    currency = coalesce(nullif(upper(trim(p_data->>'currency')), ''), 'INR'),
    timezone = coalesce(nullif(p_data->>'timezone', ''), 'Asia/Kolkata'),
    crm_segment = nullif(p_data->>'crm_segment', ''),
    avg_order_value = nullif(p_data->>'avg_order_value', '')::numeric, gross_margin_pct = nullif(p_data->>'gross_margin_pct', '')::numeric,
    target_cpl = nullif(p_data->>'target_cpl', '')::numeric, target_qualified_cpl = nullif(p_data->>'target_qualified_cpl', '')::numeric,
    target_cac = nullif(p_data->>'target_cac', '')::numeric, max_cac = nullif(p_data->>'max_cac', '')::numeric,
    target_roas = nullif(p_data->>'target_roas', '')::numeric, ltv = nullif(p_data->>'ltv', '')::numeric,
    sales_cycle_days = nullif(p_data->>'sales_cycle_days', '')::int,
    monthly_budget = nullif(p_data->>'monthly_budget', '')::numeric, max_daily_budget = nullif(p_data->>'max_daily_budget', '')::numeric,
    active = coalesce((p_data->>'active')::boolean, true),
    updated_at = now()
  WHERE id = cid;
  PERFORM crm_private.ads_log(CASE WHEN draft THEN 'client_draft_saved' ELSE 'client_saved' END, 'client', cid::text,
    jsonb_build_object('name', p_data->>'name', 'platforms', plats));
  RETURN cid;
END $$;

-- Import accounts found by ads-sync "discover" into a new or an existing client, in one transaction.
-- p_data: {client_id?, client?: {name, crm_segment?, preset?}, accounts: [{platform, external_id, name, currency, timezone, login_customer_id?}]}
-- A new client takes its currency and time zone from the first account (the platform's own values).
CREATE OR REPLACE FUNCTION public.api_ads_import(p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cid uuid := nullif(p_data->>'client_id', '')::uuid; a jsonb; first jsonb; ext text; plat text; added int := 0; skipped jsonb := '[]';
        n int := jsonb_array_length(coalesce(p_data->'accounts', '[]'));
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF n = 0 THEN RAISE EXCEPTION 'Pick at least one account to import' USING ERRCODE = 'PT422'; END IF;
  IF n > 50 THEN RAISE EXCEPTION 'Import up to 50 accounts at a time' USING ERRCODE = 'PT422'; END IF;
  first := p_data->'accounts'->0;
  IF cid IS NULL THEN
    IF length(trim(coalesce(p_data->'client'->>'name', ''))) < 2 THEN RAISE EXCEPTION 'Name the new client' USING ERRCODE = 'PT422'; END IF;
    cid := public.api_ads_client_save(jsonb_build_object('name', p_data->'client'->>'name', 'is_draft', true,
      'crm_segment', p_data->'client'->>'crm_segment', 'preset', p_data->'client'->>'preset',
      'currency', CASE WHEN first->>'currency' ~ '^[A-Z]{3}$' THEN first->>'currency' END,
      'timezone', CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = first->>'timezone') THEN first->>'timezone' END));
  ELSIF NOT EXISTS (SELECT 1 FROM public.ads_clients WHERE id = cid) THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = 'PT404';
  END IF;
  FOR a IN SELECT * FROM jsonb_array_elements(p_data->'accounts') LOOP
    plat := a->>'platform';
    ext := regexp_replace(coalesce(a->>'external_id', ''), '^act_|-', '', 'g');
    IF plat NOT IN ('google', 'meta') OR (plat = 'google' AND ext !~ '^[0-9]{10}$') OR (plat = 'meta' AND ext !~ '^[0-9]{5,25}$') THEN
      skipped := skipped || jsonb_build_object('external_id', ext, 'reason', 'invalid ID'); CONTINUE;
    END IF;
    IF EXISTS (SELECT 1 FROM public.ads_accounts x WHERE x.platform = plat AND x.external_id = ext) THEN
      skipped := skipped || jsonb_build_object('external_id', ext, 'reason', 'already in the CRM'); CONTINUE;
    END IF;
    INSERT INTO public.ads_accounts (client_id, platform, external_id, name, currency, timezone, utm_source, login_customer_id)
    VALUES (cid, plat, ext, nullif(a->>'name', ''), CASE WHEN a->>'currency' ~ '^[A-Z]{3}$' THEN a->>'currency' END, nullif(a->>'timezone', ''),
            CASE plat WHEN 'google' THEN 'google' ELSE 'facebook' END,
            CASE WHEN plat = 'google' AND a->>'login_customer_id' ~ '^[0-9]{10}$' AND a->>'login_customer_id' <> ext THEN a->>'login_customer_id' END);
    added := added + 1;
  END LOOP;
  UPDATE public.ads_clients c SET platforms = ARRAY(SELECT DISTINCT p FROM unnest(c.platforms || ARRAY(
      SELECT DISTINCT x.platform FROM public.ads_accounts x WHERE x.client_id = cid)) p ORDER BY 1)
   WHERE c.id = cid;
  PERFORM crm_private.ads_log('accounts_imported', 'client', cid::text, jsonb_build_object('added', added, 'skipped', skipped));
  RETURN jsonb_build_object('client_id', cid, 'added', added, 'skipped', skipped);
END $$;

-- svc_ads_accounts now also returns the Google manager account to log in through.
CREATE OR REPLACE FUNCTION public.svc_ads_accounts() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'platform', a.platform, 'external_id', a.external_id,
           'login_customer_id', a.login_customer_id)), '[]')
    FROM public.ads_accounts a JOIN public.ads_clients c ON c.id = a.client_id
   WHERE a.status <> 'disabled' AND c.active
$$;

-- Which discovered accounts are already in the CRM (for the import screen).
CREATE OR REPLACE FUNCTION public.svc_ads_known_accounts() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('platform', a.platform, 'external_id', a.external_id, 'client', c.name)), '[]')
    FROM public.ads_accounts a JOIN public.ads_clients c ON c.id = a.client_id
$$;

-- svc_ads_work / svc_ads_unknown: add login_customer_id for Google calls.
CREATE OR REPLACE FUNCTION public.svc_ads_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'after', q.after, 'before', q.before,
      'idempotency_key', q.idempotency_key, 'platform', a.platform, 'account_external_id', a.external_id, 'account_id', a.id,
      'login_customer_id', a.login_customer_id, 'campaign_external_id', c.external_id, 'budget_ref', c.budget_ref) ORDER BY q.approved_at), '[]')
      FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
     WHERE q.status = 'approved') END
$$;

CREATE OR REPLACE FUNCTION public.svc_ads_unknown() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'after', q.after, 'platform', a.platform,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id,
      'campaign_external_id', c.external_id, 'budget_ref', c.budget_ref)), '[]')
    FROM public.ads_change_queue q JOIN public.ads_campaigns c ON c.id = q.campaign_id JOIN public.ads_accounts a ON a.id = c.account_id
   WHERE q.status = 'outcome_unknown' OR (q.status = 'executing' AND q.executed_at < now() - interval '10 minutes')
$$;

DO $$
DECLARE f text;
BEGIN
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('api_ads_options', 'api_ads_client_save', 'api_ads_import') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('svc_ads_accounts', 'svc_ads_known_accounts', 'svc_ads_work', 'svc_ads_unknown') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'crm_private' AND p.proname IN ('ads_opt_ok', 'ads_platform_settings') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;
