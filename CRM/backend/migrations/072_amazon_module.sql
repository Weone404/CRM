-- 072: Amazon module (CRM > Amazon). Additive only: new amazon_* tables and api_amz_* / svc_amz_* functions.
--
-- Access
--   * View the Amazon section: Admin, plus employees Admin adds to amazon_approvers.
--   * Approve changes: Admin, plus approvers with can_approve.
--   * Settings (API keys): Admin only. Keys live in Supabase Vault (names amz_*), never in a table,
--     never returned to the browser (only the last 4 characters and the saved date).
--   * Every table has RLS on and no grants to anon/authenticated: the browser reaches data only
--     through the SECURITY DEFINER api_amz_* functions below, which check the caller first.
--   * svc_amz_* functions are for the amazon-* Edge Functions (service role) only.
--
-- Guards live in amazon_rules (rows, not code). Every change in amazon_change_queue is checked by
-- crm_private.amz_evaluate() on insert/update; a change with blockers can never be approved.
--
-- Re-runnable: CREATE ... IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO NOTHING throughout.

-- ===========================================================================================
-- 1. Tables
-- ===========================================================================================
CREATE TABLE IF NOT EXISTS public.amazon_config (
  key text PRIMARY KEY, value text, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_approvers (
  employee_id uuid PRIMARY KEY REFERENCES public.employee(id) ON DELETE CASCADE,
  can_approve boolean NOT NULL DEFAULT false,
  granted_by uuid, granted_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_listings (
  sku text PRIMARY KEY,
  asin text,
  parent_asin text,
  is_parent boolean NOT NULL DEFAULT false,
  product_type text,
  status text,                      -- Active / Inactive / Suppressed / Variations(n) ...
  title text,
  item_highlights text,
  bullets jsonb NOT NULL DEFAULT '[]',
  description text,
  backend_terms text,
  price numeric(10,2),
  mrp numeric(10,2),
  buybox_price numeric(10,2),
  has_buybox boolean,               -- true = we hold it, false = someone else, null = unknown / none shown
  buybox_seller text,
  quantity int,
  fulfillment text,                 -- FBM / FBA
  fees numeric(10,2),
  country_of_origin text,
  manufacturer text,
  net_quantity text,
  attributes jsonb NOT NULL DEFAULT '{}',
  images jsonb NOT NULL DEFAULT '[]',   -- [{slot, url, width, height, white_bg, has_text}]
  issues jsonb NOT NULL DEFAULT '[]',   -- Amazon's issues [{code, message, severity}]
  version int NOT NULL DEFAULT 1,
  last_approved_title text,         -- the title we last pushed (or first saw); drift = Amazon changed it
  last_changed_on text,
  synced_at timestamptz,            -- null = never synced from Amazon (imported from CSV)
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_amz_listings_asin ON public.amazon_listings (asin);

CREATE TABLE IF NOT EXISTS public.amazon_listing_versions (
  id bigserial PRIMARY KEY,
  sku text NOT NULL REFERENCES public.amazon_listings(sku) ON DELETE CASCADE,
  version int NOT NULL,
  source text NOT NULL CHECK (source IN ('import', 'sync', 'change', 'amazon_drift', 'rollback')),
  snapshot jsonb NOT NULL,
  change_id uuid,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_amz_versions_sku ON public.amazon_listing_versions (sku, version DESC);

-- Product Brief: the facts a listing may claim. Claude may only write claims that appear here.
CREATE TABLE IF NOT EXISTS public.amazon_product_facts (
  asin text PRIMARY KEY,
  buyer text, use_cases text,
  facts jsonb NOT NULL DEFAULT '[]',   -- ["160 lined pages", "PU leather cover", ...]
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_competitors (
  asin text PRIMARY KEY,
  my_asin text,
  title text, price numeric(10,2), bsr int, buybox_seller text, image_count int,
  has_aplus boolean, notes text,
  active boolean NOT NULL DEFAULT true,
  added_by uuid, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_keywords (
  id bigserial PRIMARY KEY,
  keyword text NOT NULL,
  source text NOT NULL DEFAULT 'claude' CHECK (source IN ('claude', 'user', 'ads', 'catalog', 'competitor')),
  asins text[] NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'pinned', 'rejected')),
  placement text,                    -- title / bullets / backend / ads
  notes text,
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS uq_amz_keyword ON public.amazon_keywords (lower(keyword));

CREATE TABLE IF NOT EXISTS public.amazon_sales_daily (
  day date NOT NULL,                 -- IST calendar day
  sku text NOT NULL,
  asin text,
  units int NOT NULL DEFAULT 0,
  revenue numeric(12,2) NOT NULL DEFAULT 0,
  sessions int, page_views int,
  buybox_pct numeric(5,2),
  refunds int NOT NULL DEFAULT 0,
  fees numeric(12,2),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (day, sku));

CREATE TABLE IF NOT EXISTS public.amazon_health_daily (
  day date PRIMARY KEY,
  odr numeric(6,3), cancel_rate numeric(6,3), late_ship_rate numeric(6,3), valid_tracking_rate numeric(6,3),
  policy_issues int, raw jsonb, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_rules (
  code text PRIMARY KEY,
  label text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('blocker', 'warning', 'confirm')),
  value jsonb NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  source_url text,
  updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.amazon_audit_findings (
  id bigserial PRIMARY KEY,
  sku text, asin text,
  rule_code text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('blocker', 'warning', 'info')),
  message text NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'fixed', 'dismissed')),
  dismiss_reason text,
  source text NOT NULL DEFAULT 'audit' CHECK (source IN ('audit', 'claude', 'seed', 'sync')),
  created_at timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz);
CREATE UNIQUE INDEX IF NOT EXISTS uq_amz_finding_open
  ON public.amazon_audit_findings (coalesce(sku, ''), coalesce(asin, ''), rule_code) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS public.amazon_change_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('listing', 'price', 'ads_budget', 'rollback', 'create')),
  sku text, asin text,
  summary text NOT NULL DEFAULT '',
  before jsonb NOT NULL DEFAULT '{}',
  after jsonb NOT NULL DEFAULT '{}',
  base_version int,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN
    ('pending', 'approved', 'executing', 'live', 'rejected', 'stale', 'failed', 'needs_manual', 'cancelled')),
  guard_result jsonb NOT NULL DEFAULT '{}',
  needs_second_confirm boolean NOT NULL DEFAULT false,
  second_confirmed_by uuid,
  preview_result jsonb,
  idempotency_key uuid NOT NULL DEFAULT gen_random_uuid(),
  batch_id uuid,
  created_by_type text NOT NULL DEFAULT 'user' CHECK (created_by_type IN ('user', 'claude', 'system')),
  created_by uuid,
  approved_by uuid, approved_at timestamptz,
  executed_at timestamptz,
  reject_reason text, error text,
  rollback_of uuid REFERENCES public.amazon_change_queue(id),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_amz_queue_status ON public.amazon_change_queue (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_amz_queue_batch ON public.amazon_change_queue (batch_id) WHERE batch_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.amazon_claude_requests (
  id bigserial PRIMARY KEY,
  question text NOT NULL CHECK (length(question) BETWEEN 3 AND 4000),
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'answered', 'cancelled')),
  answer text,
  asked_by uuid, created_at timestamptz NOT NULL DEFAULT now(), answered_at timestamptz);

CREATE TABLE IF NOT EXISTS public.amazon_tasks (            -- Strategy & Calendar
  id bigserial PRIMARY KEY,
  title text NOT NULL, detail text, due_on date,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'dropped')),
  source text NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'claude', 'seed')),
  created_at timestamptz NOT NULL DEFAULT now(), done_at timestamptz);

CREATE TABLE IF NOT EXISTS public.amazon_sync_runs (
  id bigserial PRIMARY KEY,
  job text NOT NULL,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'error', 'skipped')),
  items int, detail text,
  started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_amz_runs_job ON public.amazon_sync_runs (job, started_at DESC);

-- Who did what. Never stores secret values.
CREATE TABLE IF NOT EXISTS public.amazon_activity_log (
  id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  actor uuid, actor_type text NOT NULL DEFAULT 'user',
  action text NOT NULL, entity text, entity_id text, details jsonb);
CREATE INDEX IF NOT EXISTS idx_amz_activity_at ON public.amazon_activity_log (at DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_config','amazon_approvers','amazon_listings','amazon_listing_versions',
    'amazon_product_facts','amazon_competitors','amazon_keywords','amazon_sales_daily','amazon_health_daily',
    'amazon_rules','amazon_audit_findings','amazon_change_queue','amazon_claude_requests','amazon_tasks',
    'amazon_sync_runs','amazon_activity_log']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- ===========================================================================================
-- 2. Config defaults and rules (policy limits as data)
-- ===========================================================================================
INSERT INTO public.amazon_config (key, value) VALUES
  ('marketplace_id', 'A21TJRUUN4KGV'),
  ('region', 'eu'),
  ('endpoint', 'https://sellingpartnerapi-eu.amazon.com'),
  ('language_tag', 'en_IN'),
  ('currency', 'INR')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.amazon_rules (code, label, severity, value, source_url) VALUES
  ('price_floor', 'Price never below the floor', 'blocker', '{"min": 299}', NULL),
  ('price_change_confirm', 'Price change above this % needs a second confirm', 'confirm', '{"pct": 20}', NULL),
  ('mrp_gte_price', 'MRP must be at least the selling price', 'blocker', '{}', NULL),
  ('title_max_chars', 'Title length (characters, spaces included)', 'blocker', '{"max": 75}',
    'https://myamazonguy.com/?p=165442'),
  ('title_word_repeat', 'No word more than twice in the title', 'blocker',
    '{"max": 2, "ignore": ["a","an","the","and","or","for","with","of","to","in","on","by","at","from","&","|","-"]}',
    'https://searchengineland.com/?p=450485'),
  ('title_promo_words', 'No promotional words in the title', 'blocker',
    '{"words": ["best","best seller","bestseller","sale","free shipping","free delivery","guaranteed","100% quality","#1","top rated","cheapest","discount","offer","deal","limited time","amazon''s choice"]}',
    'https://myamazonguy.com/?p=165442'),
  ('title_special_chars', 'Restricted special characters in the title', 'blocker',
    '{"blocked": "!$?_{}^¬¦", "context": "~#<>*"}', 'https://www.suntecindia.com/blog/wp-json/wp/v2/posts/8526'),
  ('highlights_max_chars', 'Item Highlights length', 'blocker', '{"max": 125}',
    'https://www.supplykick.com/blog/amazon-product-title-optimization'),
  ('backend_terms_bytes', 'Backend search terms size in bytes (UTF-8)', 'blocker', '{"max": 249}',
    'https://www.sellerforge.ai/blog/amazon-keyword-strategy-cosmo'),
  ('backend_no_emoji', 'No emoji in backend search terms', 'blocker', '{}', NULL),
  ('main_image', 'Main image: pure white background, at least this many px on the longest side, no text',
    'blocker', '{"min_px": 1000}', 'https://www.bebolddigital.com/blog/amazon-image-requirements'),
  ('legal_fields', 'Country of origin, MRP, manufacturer and net quantity are mandatory', 'blocker',
    '{"fields": ["country_of_origin","mrp","manufacturer","net_quantity"]}',
    'https://www.medianama.com/2020/07/223-amazon-country-of-origin/'),
  ('claim_traceability', 'Every claim must be a fact in the Product Brief', 'blocker', '{}', NULL),
  ('ads_daily_budget', 'Total daily ad budget across all campaigns (INR)', 'blocker', '{"min": 50, "max": 500}', NULL),
  ('bulk_batch_max', 'Changes per batch', 'blocker', '{"max": 20}', NULL),
  ('parent_edit_confirm', 'Parent / variation edits need a second confirm', 'confirm', '{}', NULL),
  ('lwa_rotation_days', 'LWA client secret must be rotated every N days', 'warning', '{"days": 180, "alerts": [90, 30, 7]}',
    'https://developer-docs.amazon.com/sp-api/lang-US/docs/rotating-your-apps-lwa-credentials'),
  ('health_warn', 'Account health early-warning levels (%)', 'warning',
    '{"odr": 0.7, "cancel_rate": 1.8, "late_ship_rate": 3, "valid_tracking_rate": 96}', NULL)
ON CONFLICT (code) DO NOTHING;

-- ===========================================================================================
-- 3. Access helpers
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.amz_can_view() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (
    SELECT 1 FROM public.amazon_approvers a WHERE a.employee_id = crm_private.current_employee_id())
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_can_approve() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (
    SELECT 1 FROM public.amazon_approvers a WHERE a.employee_id = crm_private.current_employee_id() AND a.can_approve)
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_require_view() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.amz_can_view() THEN
    RAISE EXCEPTION 'You do not have access to the Amazon section' USING ERRCODE = 'PT403';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_require_admin() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can open Amazon settings' USING ERRCODE = 'PT403';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_log(p_action text, p_entity text, p_entity_id text, p_details jsonb,
  p_actor_type text DEFAULT 'user') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_activity_log (actor, actor_type, action, entity, entity_id, details)
  VALUES (crm_private.current_employee_id(), p_actor_type, p_action, p_entity, p_entity_id, p_details)
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_rule(p_code text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT r.value FROM public.amazon_rules r WHERE r.code = p_code AND r.active
$$;

-- ===========================================================================================
-- 4. Guards: one evaluator used by the queue trigger, the audit engine and the UI preview
-- ===========================================================================================
-- Text checks. Returns [{code, severity, message}] for one text field.
CREATE OR REPLACE FUNCTION crm_private.amz_check_title(p_title text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '[]'; r jsonb; w text; n int; ign text[]; ch text; t text := coalesce(p_title, '');
BEGIN
  IF t = '' THEN RETURN out; END IF;
  r := crm_private.amz_rule('title_max_chars');
  IF r IS NOT NULL AND char_length(t) > (r->>'max')::int THEN
    out := out || jsonb_build_object('code', 'title_max_chars', 'severity', 'blocker',
      'message', format('Title is %s characters; the limit is %s.', char_length(t), r->>'max'));
  END IF;
  r := crm_private.amz_rule('title_word_repeat');
  IF r IS NOT NULL THEN
    SELECT array_agg(x) INTO ign FROM jsonb_array_elements_text(r->'ignore') x;
    -- plural and singular count as the same word (diary/diaries, planner/planners)
    FOR w, n IN
      SELECT stem, count(*) FROM (
        SELECT CASE WHEN wd ~ 'ies$' AND length(wd) > 4 THEN regexp_replace(wd, 'ies$', 'y')
                    WHEN wd ~ '[^s]s$' AND length(wd) > 3 THEN regexp_replace(wd, 's$', '')
                    ELSE wd END AS stem
        FROM regexp_split_to_table(lower(t), '[^[:alnum:]]+') wd
        WHERE wd <> '' AND NOT (wd = ANY (coalesce(ign, '{}'))) AND wd !~ '^[0-9]+$') s
      GROUP BY stem HAVING count(*) > (r->>'max')::int
    LOOP
      out := out || jsonb_build_object('code', 'title_word_repeat', 'severity', 'blocker',
        'message', format('"%s" appears %s times in the title; the limit is %s.', w, n, r->>'max'));
    END LOOP;
  END IF;
  r := crm_private.amz_rule('title_promo_words');
  IF r IS NOT NULL THEN
    FOR w IN SELECT x FROM jsonb_array_elements_text(r->'words') x LOOP
      IF lower(t) ~ ('(^|[^[:alnum:]])' || regexp_replace(lower(w), '([.^$*+?()\[\]{}|\\#])', '\\\1', 'g') || '($|[^[:alnum:]])') THEN
        out := out || jsonb_build_object('code', 'title_promo_words', 'severity', 'blocker',
          'message', format('Promotional wording "%s" is not allowed in titles.', w));
      END IF;
    END LOOP;
  END IF;
  r := crm_private.amz_rule('title_special_chars');
  IF r IS NOT NULL THEN
    FOREACH ch IN ARRAY regexp_split_to_array(r->>'blocked', '') LOOP
      IF ch <> '' AND strpos(t, ch) > 0 THEN
        out := out || jsonb_build_object('code', 'title_special_chars', 'severity', 'blocker',
          'message', format('The character "%s" is not allowed in titles.', ch));
      END IF;
    END LOOP;
    FOREACH ch IN ARRAY regexp_split_to_array(r->>'context', '') LOOP
      IF ch <> '' AND strpos(t, ch) > 0 THEN
        out := out || jsonb_build_object('code', 'title_special_chars', 'severity', 'warning',
          'message', format('"%s" is only allowed in identifiers or measurements; check it is used that way.', ch));
      END IF;
    END LOOP;
  END IF;
  RETURN out;
END $$;

-- Full evaluation of a proposed change against the listing it changes.
-- p_after keys used: title, item_highlights, backend_terms, price, mrp, country_of_origin, manufacturer,
-- net_quantity, main_image {width, height, white_bg, has_text}, claims [text], daily_budget_total.
-- Returns {blockers:[...], warnings:[...], confirms:[...], ok:boolean}.
CREATE OR REPLACE FUNCTION crm_private.amz_evaluate(p_kind text, p_sku text, p_after jsonb, p_batch uuid DEFAULT NULL,
  p_self uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  L public.amazon_listings; r jsonb; items jsonb := '[]'; a jsonb := coalesce(p_after, '{}');
  newp numeric; oldp numeric; mrp numeric; f text; v text; img jsonb; c text; facts jsonb; n int; bytes int;
BEGIN
  SELECT * INTO L FROM public.amazon_listings WHERE sku = p_sku;

  IF p_kind IN ('listing', 'price', 'rollback', 'create') AND L.sku IS NULL AND p_kind <> 'create' THEN
    items := items || jsonb_build_object('code', 'unknown_sku', 'severity', 'blocker', 'message', 'This SKU is not in the CRM.');
  END IF;

  -- Title
  IF a ? 'title' THEN items := items || crm_private.amz_check_title(a->>'title'); END IF;

  -- Item Highlights
  r := crm_private.amz_rule('highlights_max_chars');
  IF r IS NOT NULL AND a ? 'item_highlights' AND char_length(coalesce(a->>'item_highlights', '')) > (r->>'max')::int THEN
    items := items || jsonb_build_object('code', 'highlights_max_chars', 'severity', 'blocker',
      'message', format('Item Highlights is %s characters; the limit is %s.', char_length(a->>'item_highlights'), r->>'max'));
  END IF;

  -- Backend search terms: bytes, not characters; no emoji
  IF a ? 'backend_terms' THEN
    bytes := octet_length(coalesce(a->>'backend_terms', ''));
    r := crm_private.amz_rule('backend_terms_bytes');
    IF r IS NOT NULL AND bytes > (r->>'max')::int THEN
      items := items || jsonb_build_object('code', 'backend_terms_bytes', 'severity', 'blocker',
        'message', format('Backend search terms are %s bytes; the limit is %s (Hindi letters take 3 bytes each).', bytes, r->>'max'));
    END IF;
    IF crm_private.amz_rule('backend_no_emoji') IS NOT NULL
       AND coalesce(a->>'backend_terms', '') ~ '[\U0001F000-\U0001FAFF☀-➿️]' THEN
      items := items || jsonb_build_object('code', 'backend_no_emoji', 'severity', 'blocker',
        'message', 'Emoji are not allowed in backend search terms.');
    END IF;
  END IF;

  -- Price floor, MRP, big price moves
  IF a ? 'price' THEN
    newp := nullif(a->>'price', '')::numeric;
    oldp := L.price;
    r := crm_private.amz_rule('price_floor');
    IF r IS NOT NULL AND (newp IS NULL OR newp < (r->>'min')::numeric) THEN
      items := items || jsonb_build_object('code', 'price_floor', 'severity', 'blocker',
        'message', format('Price ₹%s is below the floor of ₹%s.', coalesce(newp::text, '(empty)'), r->>'min'));
    END IF;
    r := crm_private.amz_rule('price_change_confirm');
    IF r IS NOT NULL AND oldp IS NOT NULL AND oldp > 0 AND newp IS NOT NULL
       AND abs(newp - oldp) / oldp * 100 > (r->>'pct')::numeric THEN
      items := items || jsonb_build_object('code', 'price_change_confirm', 'severity', 'confirm',
        'message', format('Price moves from ₹%s to ₹%s (%s%%). Confirm twice.', oldp, newp,
          round((newp - oldp) / oldp * 100, 1)));
    END IF;
  END IF;
  newp := coalesce(nullif(a->>'price', '')::numeric, L.price);
  mrp := coalesce(nullif(a->>'mrp', '')::numeric, L.mrp);
  IF crm_private.amz_rule('mrp_gte_price') IS NOT NULL AND mrp IS NOT NULL AND newp IS NOT NULL AND mrp < newp THEN
    items := items || jsonb_build_object('code', 'mrp_gte_price', 'severity', 'blocker',
      'message', format('MRP ₹%s is lower than the selling price ₹%s.', mrp, newp));
  END IF;

  -- Legal Metrology fields (India). Blocker when Amazon's own data (synced) lacks them or for new listings;
  -- a warning when the listing has never been synced, because the CRM copy may just be incomplete.
  r := crm_private.amz_rule('legal_fields');
  IF r IS NOT NULL AND p_kind IN ('listing', 'create') THEN
    FOR f IN SELECT x FROM jsonb_array_elements_text(r->'fields') x LOOP
      v := coalesce(nullif(a->>f, ''), CASE f WHEN 'country_of_origin' THEN L.country_of_origin
                                             WHEN 'mrp' THEN L.mrp::text
                                             WHEN 'manufacturer' THEN L.manufacturer
                                             WHEN 'net_quantity' THEN L.net_quantity END);
      IF v IS NULL OR v = '' THEN
        items := items || jsonb_build_object('code', 'legal_fields',
          'severity', CASE WHEN p_kind = 'create' OR L.synced_at IS NOT NULL THEN 'blocker' ELSE 'warning' END,
          'message', CASE WHEN p_kind = 'create' OR L.synced_at IS NOT NULL
                          THEN format('%s is missing (Legal Metrology).', replace(f, '_', ' '))
                          ELSE format('%s not in the CRM yet (listing not synced from Amazon).', replace(f, '_', ' ')) END);
      END IF;
    END LOOP;
  END IF;

  -- Main image (metrics measured in the browser before upload)
  IF a ? 'main_image' AND crm_private.amz_rule('main_image') IS NOT NULL THEN
    img := a->'main_image'; r := crm_private.amz_rule('main_image');
    IF greatest(coalesce((img->>'width')::int, 0), coalesce((img->>'height')::int, 0)) < (r->>'min_px')::int THEN
      items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
        'message', format('Main image is %sx%s px; the longest side must be at least %s px.',
          coalesce(img->>'width', '?'), coalesce(img->>'height', '?'), r->>'min_px'));
    END IF;
    IF coalesce((img->>'white_bg')::boolean, false) IS NOT TRUE THEN
      items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
        'message', 'Main image background is not pure white (255,255,255).');
    END IF;
    IF (img->>'has_text') IS NULL THEN
      items := items || jsonb_build_object('code', 'main_image', 'severity', 'confirm',
        'message', 'Confirm the main image has no text, logo or watermark (cannot be detected automatically).');
    ELSIF (img->>'has_text')::boolean THEN
      items := items || jsonb_build_object('code', 'main_image', 'severity', 'blocker',
        'message', 'Main image has text, a logo or a watermark.');
    END IF;
  END IF;

  -- Claim traceability
  IF a ? 'claims' AND crm_private.amz_rule('claim_traceability') IS NOT NULL THEN
    SELECT pf.facts INTO facts FROM public.amazon_product_facts pf WHERE pf.asin = coalesce(L.asin, a->>'asin');
    FOR c IN SELECT x FROM jsonb_array_elements_text(a->'claims') x LOOP
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(facts, '[]')) fx WHERE lower(trim(fx)) = lower(trim(c))) THEN
        items := items || jsonb_build_object('code', 'claim_traceability', 'severity', 'blocker',
          'message', format('Claim "%s" is not in the Product Brief for this ASIN.', c));
      END IF;
    END LOOP;
  END IF;

  -- Ads budget
  IF p_kind = 'ads_budget' THEN
    r := crm_private.amz_rule('ads_daily_budget');
    newp := nullif(a->>'daily_budget_total', '')::numeric;
    IF r IS NOT NULL AND (newp IS NULL OR newp < (r->>'min')::numeric OR newp > (r->>'max')::numeric) THEN
      items := items || jsonb_build_object('code', 'ads_daily_budget', 'severity', 'blocker',
        'message', format('Total daily ad budget ₹%s is outside ₹%s–₹%s.', coalesce(newp::text, '(empty)'), r->>'min', r->>'max'));
    END IF;
  END IF;

  -- Parent / variation edits
  IF L.is_parent AND crm_private.amz_rule('parent_edit_confirm') IS NOT NULL THEN
    items := items || jsonb_build_object('code', 'parent_edit_confirm', 'severity', 'confirm',
      'message', 'This is a parent (variation family) listing; the change affects every variation.');
  END IF;

  -- Bulk batch size
  r := crm_private.amz_rule('bulk_batch_max');
  IF p_batch IS NOT NULL AND r IS NOT NULL THEN
    SELECT count(*) INTO n FROM public.amazon_change_queue q
      WHERE q.batch_id = p_batch AND q.status IN ('pending', 'approved', 'executing') AND q.id IS DISTINCT FROM p_self;
    IF n + 1 > (r->>'max')::int THEN
      items := items || jsonb_build_object('code', 'bulk_batch_max', 'severity', 'blocker',
        'message', format('A batch can hold at most %s changes.', r->>'max'));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'blockers', coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'blocker'), '[]'),
    'warnings', coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'warning'), '[]'),
    'confirms', coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'confirm'), '[]'),
    'ok', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(items) i WHERE i->>'severity' = 'blocker'));
END $$;

-- Queue trigger: re-evaluate on every insert / content edit; refuse to approve or run a blocked change;
-- enforce the status machine so nothing (UI, Claude via SQL, or a bug) can skip a step.
CREATE OR REPLACE FUNCTION crm_private.amz_queue_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE g jsonb;
BEGIN
  IF TG_OP = 'INSERT' OR NEW.after IS DISTINCT FROM OLD.after OR NEW.kind IS DISTINCT FROM OLD.kind
     OR (NEW.status = 'pending' AND OLD.status IN ('failed', 'stale')) THEN
    IF TG_OP = 'UPDATE' AND (NEW.after IS DISTINCT FROM OLD.after OR NEW.kind IS DISTINCT FROM OLD.kind)
       AND OLD.status NOT IN ('pending', 'stale') THEN
      RAISE EXCEPTION 'A change can only be edited while pending' USING ERRCODE = 'PT409';
    END IF;
    g := crm_private.amz_evaluate(NEW.kind, NEW.sku, NEW.after, NEW.batch_id, NEW.id);
    NEW.guard_result := g;
    NEW.needs_second_confirm := jsonb_array_length(g->'confirms') > 0;
    IF TG_OP = 'UPDATE' THEN NEW.second_confirmed_by := NULL; END IF;
    IF NEW.status NOT IN ('pending', 'cancelled', 'rejected') AND TG_OP = 'INSERT' THEN
      NEW.status := 'pending';                 -- inserts always start pending, whoever writes them
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'pending'   AND NEW.status IN ('approved', 'rejected', 'cancelled', 'stale'))
      OR (OLD.status = 'stale'     AND NEW.status IN ('pending', 'rejected', 'cancelled'))
      OR (OLD.status = 'approved'  AND NEW.status IN ('executing', 'cancelled', 'stale'))
      OR (OLD.status = 'executing' AND NEW.status IN ('live', 'failed', 'stale', 'needs_manual'))
      OR (OLD.status = 'failed'    AND NEW.status IN ('pending', 'cancelled'))
      OR (OLD.status = 'needs_manual' AND NEW.status IN ('live', 'cancelled'))) THEN
      RAISE EXCEPTION 'Change cannot go from % to %', OLD.status, NEW.status USING ERRCODE = 'PT409';
    END IF;
    IF NEW.status = 'approved' THEN
      IF NOT coalesce((NEW.guard_result->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'This change has blockers and cannot be approved' USING ERRCODE = 'PT422';
      END IF;
      IF NEW.needs_second_confirm AND NEW.second_confirmed_by IS NULL THEN
        RAISE EXCEPTION 'This change needs a second confirmation' USING ERRCODE = 'PT428';
      END IF;
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_queue_guard ON public.amazon_change_queue;
CREATE TRIGGER amz_queue_guard BEFORE INSERT OR UPDATE ON public.amazon_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_queue_guard();

-- Snapshot of a listing as stored (used for before/after and versions).
CREATE OR REPLACE FUNCTION crm_private.amz_snapshot(p_sku text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('sku', l.sku, 'asin', l.asin, 'title', l.title, 'item_highlights', l.item_highlights,
    'bullets', l.bullets, 'description', l.description, 'backend_terms', l.backend_terms, 'price', l.price,
    'mrp', l.mrp, 'country_of_origin', l.country_of_origin, 'manufacturer', l.manufacturer,
    'net_quantity', l.net_quantity, 'images', l.images, 'product_type', l.product_type, 'version', l.version)
  FROM public.amazon_listings l WHERE l.sku = p_sku
$$;

-- ===========================================================================================
-- 5. Audit engine (nightly via cron, and on demand)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.amz_audit_all() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE L record; i jsonb; wrn jsonb := crm_private.amz_rule('health_warn'); h record; n int;
BEGIN
  -- Everything that fails right now, collected first; then open what is new and close what got fixed.
  CREATE TEMP TABLE IF NOT EXISTS amz_now (sku text, asin text, rule_code text, severity text, message text) ON COMMIT DROP;
  TRUNCATE amz_now;
  FOR L IN SELECT * FROM public.amazon_listings LOOP
    FOR i IN SELECT * FROM jsonb_array_elements(crm_private.amz_check_title(L.title)) LOOP
      INSERT INTO amz_now VALUES (L.sku, L.asin, i->>'code', CASE WHEN i->>'severity' = 'blocker' THEN 'blocker' ELSE 'warning' END, i->>'message');
    END LOOP;
    IF L.title ~ '\m2026\M' THEN
      INSERT INTO amz_now VALUES (L.sku, L.asin, 'stale_year', 'warning', 'Title still says 2026; diaries for the coming year should say 2027.');
    END IF;
    IF L.has_buybox IS FALSE THEN
      INSERT INTO amz_now VALUES (L.sku, L.asin, 'buybox_lost', 'blocker',
        format('Buy Box lost: your price ₹%s, Buy Box ₹%s%s.', L.price, coalesce(L.buybox_price::text, '?'),
               CASE WHEN L.buybox_seller IS NOT NULL THEN ' (seller ' || L.buybox_seller || ')' ELSE '' END));
    ELSIF L.has_buybox IS NULL AND L.buybox_price IS NULL AND NOT L.is_parent AND coalesce(L.status, '') ILIKE 'active%' THEN
      INSERT INTO amz_now VALUES (L.sku, L.asin, 'buybox_none', 'blocker', 'No Buy Box shown on this listing.');
    END IF;
    IF jsonb_array_length(L.issues) > 0 THEN
      INSERT INTO amz_now VALUES (L.sku, L.asin, 'amazon_issue', 'blocker',
        format('Amazon reports %s issue(s): %s', jsonb_array_length(L.issues), left(L.issues->0->>'message', 200)));
    END IF;
  END LOOP;
  SELECT * INTO h FROM public.amazon_health_daily ORDER BY day DESC LIMIT 1;
  IF h.day IS NOT NULL AND wrn IS NOT NULL THEN
    IF h.odr >= (wrn->>'odr')::numeric THEN INSERT INTO amz_now VALUES (NULL, NULL, 'health_odr', 'blocker',
      format('Order Defect Rate %s%% (warn at %s%%, Amazon limit 1%%).', h.odr, wrn->>'odr')); END IF;
    IF h.cancel_rate >= (wrn->>'cancel_rate')::numeric THEN INSERT INTO amz_now VALUES (NULL, NULL, 'health_cancel', 'blocker',
      format('Cancellation rate %s%% (warn at %s%%, Amazon limit 2.5%%).', h.cancel_rate, wrn->>'cancel_rate')); END IF;
    IF h.late_ship_rate >= (wrn->>'late_ship_rate')::numeric THEN INSERT INTO amz_now VALUES (NULL, NULL, 'health_late', 'blocker',
      format('Late shipment rate %s%% (warn at %s%%, Amazon limit 4%%).', h.late_ship_rate, wrn->>'late_ship_rate')); END IF;
    IF h.valid_tracking_rate IS NOT NULL AND h.valid_tracking_rate <= (wrn->>'valid_tracking_rate')::numeric THEN
      INSERT INTO amz_now VALUES (NULL, NULL, 'health_vtr', 'blocker',
      format('Valid tracking rate %s%% (warn at %s%%, Amazon minimum 95%%).', h.valid_tracking_rate, wrn->>'valid_tracking_rate')); END IF;
  END IF;

  -- one row per (sku, asin, rule): keep the first message
  INSERT INTO public.amazon_audit_findings (sku, asin, rule_code, severity, message, source)
  SELECT DISTINCT ON (coalesce(sku, ''), coalesce(asin, ''), rule_code) sku, asin, rule_code, severity, message, 'audit'
    FROM amz_now ORDER BY coalesce(sku, ''), coalesce(asin, ''), rule_code, (severity = 'blocker') DESC
  ON CONFLICT DO NOTHING;
  -- audit-owned findings that no longer fail are fixed (seed / claude / sync findings are left alone)
  UPDATE public.amazon_audit_findings f SET status = 'fixed', resolved_at = now()
   WHERE f.status = 'open' AND f.source = 'audit'
     AND NOT EXISTS (SELECT 1 FROM amz_now x WHERE x.rule_code = f.rule_code
                     AND coalesce(x.sku, '') = coalesce(f.sku, '') AND coalesce(x.asin, '') = coalesce(f.asin, ''));
  SELECT count(*) INTO n FROM amz_now;
  RETURN n;
END $$;

-- ===========================================================================================
-- 6. Settings (Admin only). Secrets in Vault as amz_<name>.
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.amz_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['AMZ_LWA_CLIENT_ID','AMZ_LWA_CLIENT_SECRET','AMZ_REFRESH_TOKEN','AMZ_SELLER_ID',
               'ADS_CLIENT_ID','ADS_CLIENT_SECRET','ADS_REFRESH_TOKEN','ADS_PROFILE_ID']
$$;

CREATE OR REPLACE FUNCTION public.api_amz_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb := '{}'; nm text; s record; rot date; r jsonb := crm_private.amz_rule('lwa_rotation_days'); due date;
BEGIN
  PERFORM crm_private.amz_require_admin();
  FOREACH nm IN ARRAY crm_private.amz_secret_names() LOOP
    SELECT right(d.decrypted_secret, 4) AS last4, d.updated_at INTO s
      FROM vault.decrypted_secrets d WHERE d.name = 'amz_' || lower(nm);
    out := out || jsonb_build_object(nm, CASE WHEN s.last4 IS NULL THEN jsonb_build_object('set', false)
      ELSE jsonb_build_object('set', true, 'last4', s.last4, 'updated_at', s.updated_at) END);
    s := NULL;
  END LOOP;
  rot := (SELECT c.value FROM public.amazon_config c WHERE c.key = 'secret_rotated_on')::date;
  due := rot + coalesce((r->>'days')::int, 180);
  RETURN out || jsonb_build_object(
    'AMZ_MARKETPLACE_ID', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'marketplace_id'),
    'AMZ_REGION', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'region'),
    'AMZ_SECRET_ROTATED_ON', rot,
    'rotation_due', due,
    'rotation_days_left', CASE WHEN due IS NULL THEN NULL ELSE due - (now() AT TIME ZONE 'Asia/Kolkata')::date END,
    'last_test', (SELECT jsonb_build_object('status', max(c.value) FILTER (WHERE c.key = 'last_test_status'),
                    'detail', max(c.value) FILTER (WHERE c.key = 'last_test_detail'),
                    'at', max(c.value) FILTER (WHERE c.key = 'last_test_at'))
                  FROM public.amazon_config c WHERE c.key LIKE 'last_test_%'));
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_settings_save(p_name text, p_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text := trim(coalesce(p_value, '')); sid uuid; vname text;
BEGIN
  PERFORM crm_private.amz_require_admin();
  IF p_name = 'AMZ_MARKETPLACE_ID' THEN
    IF v <> 'A21TJRUUN4KGV' THEN RAISE EXCEPTION 'Marketplace is locked to India (A21TJRUUN4KGV)' USING ERRCODE = 'PT422'; END IF;
    RETURN jsonb_build_object('saved', true);
  ELSIF p_name = 'AMZ_REGION' THEN
    IF v <> 'eu' THEN RAISE EXCEPTION 'Region is locked to eu (Amazon.in is served by the Europe endpoint)' USING ERRCODE = 'PT422'; END IF;
    RETURN jsonb_build_object('saved', true);
  ELSIF p_name = 'AMZ_SECRET_ROTATED_ON' THEN
    IF v !~ '^\d{4}-\d{2}-\d{2}$' OR v::date > (now() AT TIME ZONE 'Asia/Kolkata')::date THEN
      RAISE EXCEPTION 'Enter the date the secret was created, not a future date (YYYY-MM-DD)' USING ERRCODE = 'PT422';
    END IF;
    INSERT INTO public.amazon_config (key, value) VALUES ('secret_rotated_on', v)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.amz_log('settings_saved', 'setting', p_name, '{}');
    RETURN jsonb_build_object('saved', true);
  END IF;
  IF NOT (p_name = ANY (crm_private.amz_secret_names())) THEN
    RAISE EXCEPTION 'Unknown setting' USING ERRCODE = 'PT404';
  END IF;
  IF v = '' THEN RAISE EXCEPTION 'Value is empty' USING ERRCODE = 'PT422'; END IF;
  IF v ~ '\s' THEN RAISE EXCEPTION 'Value contains spaces or line breaks; paste it again' USING ERRCODE = 'PT422'; END IF;
  IF length(v) > 2000 THEN RAISE EXCEPTION 'Value is too long' USING ERRCODE = 'PT422'; END IF;
  IF p_name IN ('AMZ_LWA_CLIENT_ID', 'ADS_CLIENT_ID') AND v NOT LIKE 'amzn1.application-oa2-client.%' THEN
    RAISE EXCEPTION 'Client ID must start with amzn1.application-oa2-client.' USING ERRCODE = 'PT422';
  END IF;
  IF p_name IN ('AMZ_REFRESH_TOKEN', 'ADS_REFRESH_TOKEN') AND v NOT LIKE 'Atzr|%' THEN
    RAISE EXCEPTION 'Refresh token must start with Atzr|' USING ERRCODE = 'PT422';
  END IF;
  IF p_name = 'AMZ_SELLER_ID' AND v !~ '^[A-Z0-9]{8,20}$' THEN
    RAISE EXCEPTION 'Seller ID (merchant token) is 8–20 capital letters and digits' USING ERRCODE = 'PT422';
  END IF;
  vname := 'amz_' || lower(p_name);
  SELECT id INTO sid FROM vault.secrets WHERE name = vname;
  IF sid IS NULL THEN PERFORM vault.create_secret(v, vname, 'CRM Amazon: ' || p_name);
  ELSE PERFORM vault.update_secret(sid, v); END IF;
  -- Name only, never the value.
  PERFORM crm_private.amz_log('settings_saved', 'setting', p_name, '{}');
  RETURN jsonb_build_object('saved', true, 'last4', right(v, 4));
END $$;

-- ===========================================================================================
-- 7. Browser API (authenticated; every function checks access first)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.api_amz_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.amz_can_view(), 'can_approve', crm_private.amz_can_approve(),
                            'is_admin', crm_private.is_admin())
$$;

-- What to fix first: money and account risk before content polish.
CREATE OR REPLACE FUNCTION crm_private.amz_rank(p_code text) RETURNS int
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_code
    WHEN 'suppressed_after_change' THEN 1 WHEN 'amazon_issue' THEN 2
    WHEN 'health_odr' THEN 3 WHEN 'health_cancel' THEN 3 WHEN 'health_late' THEN 3 WHEN 'health_vtr' THEN 3
    WHEN 'buybox_lost' THEN 4 WHEN 'buybox_none' THEN 5 WHEN 'title_drift' THEN 6 WHEN 'stale_year' THEN 7
    WHEN 'title_max_chars' THEN 8 WHEN 'title_word_repeat' THEN 9 ELSE 10 END
$$;

CREATE OR REPLACE FUNCTION public.api_amz_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; rot date; days int;
BEGIN
  PERFORM crm_private.amz_require_view();
  rot := (SELECT c.value FROM public.amazon_config c WHERE c.key = 'secret_rotated_on')::date;
  days := CASE WHEN rot IS NULL THEN NULL ELSE rot + coalesce((crm_private.amz_rule('lwa_rotation_days')->>'days')::int, 180) - today END;
  RETURN jsonb_build_object(
    'listings', (SELECT count(*) FROM public.amazon_listings),
    'sales_today', (SELECT jsonb_build_object('units', coalesce(sum(units), 0), 'revenue', coalesce(sum(revenue), 0))
                    FROM public.amazon_sales_daily WHERE day = today),
    'sales_7d', (SELECT jsonb_build_object('units', coalesce(sum(units), 0), 'revenue', coalesce(sum(revenue), 0))
                 FROM public.amazon_sales_daily WHERE day > today - 7),
    'health', (SELECT to_jsonb(h) - 'raw' FROM public.amazon_health_daily h ORDER BY day DESC LIMIT 1),
    'pending', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'),
    'open_findings', (SELECT jsonb_build_object('blocker', count(*) FILTER (WHERE severity = 'blocker'),
                        'warning', count(*) FILTER (WHERE severity = 'warning'))
                      FROM public.amazon_audit_findings WHERE status = 'open'),
    'top_findings', coalesce((SELECT jsonb_agg(x) FROM (SELECT id, sku, asin, rule_code, severity, message
        FROM public.amazon_audit_findings WHERE status = 'open'
        ORDER BY (severity = 'blocker') DESC, crm_private.amz_rank(rule_code), created_at DESC LIMIT 6) x), '[]'),
    'waiting_requests', (SELECT count(*) FROM public.amazon_claude_requests WHERE status = 'waiting'),
    'last_sync', coalesce((SELECT jsonb_object_agg(job, jsonb_build_object('status', status, 'at', finished_at, 'detail', detail))
        FROM (SELECT DISTINCT ON (job) job, status, finished_at, detail FROM public.amazon_sync_runs
              WHERE status <> 'running' ORDER BY job, started_at DESC) r), '{}'),
    'connected', EXISTS (SELECT 1 FROM vault.decrypted_secrets d WHERE d.name = 'amz_amz_refresh_token'),
    'last_test', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'last_test_status'),
    'rotation_days_left', days,
    'rotation_alert', CASE WHEN days IS NULL THEN NULL WHEN days <= 7 THEN 7 WHEN days <= 30 THEN 30 WHEN days <= 90 THEN 90 END);
END $$;

-- Heuristic scorecard (0-100 each). Clearly a CRM heuristic, not an Amazon score.
CREATE OR REPLACE FUNCTION crm_private.amz_score(L public.amazon_listings) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t jsonb := crm_private.amz_check_title(L.title); blockers int; idx int := 0; intent int := 0; conv int := 0;
        disc text[] := ARRAY['target_audience_keyword','specific_uses_for_product','theme','paper_size','number_of_pages',
                             'cover_material','binding','style','color','material'];
        k text; have int := 0;
BEGIN
  SELECT count(*) INTO blockers FROM jsonb_array_elements(t) i WHERE i->>'severity' = 'blocker';
  idx := (CASE WHEN coalesce(L.title, '') <> '' AND blockers = 0 THEN 40 ELSE 0 END)
       + (CASE WHEN coalesce(L.backend_terms, '') <> '' THEN 30 ELSE 0 END)
       + (CASE WHEN coalesce(L.item_highlights, '') <> '' THEN 15 ELSE 0 END)
       + (CASE WHEN jsonb_array_length(L.bullets) >= 5 THEN 15 ELSE jsonb_array_length(L.bullets) * 3 END);
  FOREACH k IN ARRAY disc LOOP IF L.attributes ? k THEN have := have + 1; END IF; END LOOP;
  intent := round(100.0 * have / array_length(disc, 1));
  conv := (CASE WHEN L.has_buybox IS TRUE THEN 40 ELSE 0 END)
        + least(jsonb_array_length(L.images), 7) * 5
        + (CASE WHEN coalesce(L.description, '') <> '' THEN 15 ELSE 0 END)
        + (CASE WHEN L.quantity > 0 THEN 10 ELSE 0 END);
  RETURN jsonb_build_object('index', least(idx, 100), 'intent', intent, 'conversion', least(conv, 100),
    'compliance', greatest(0, 100 - 25 * (blockers + jsonb_array_length(L.issues))),
    'failing', t);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_listings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(l) || jsonb_build_object('score', crm_private.amz_score(l),
      'title_chars', char_length(coalesce(l.title, ''))) ORDER BY l.is_parent DESC, l.asin, l.sku)
    FROM public.amazon_listings l), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_listing(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RAISE EXCEPTION 'Listing not found' USING ERRCODE = 'PT404'; END IF;
  RETURN to_jsonb(l) || jsonb_build_object('score', crm_private.amz_score(l),
    'facts', (SELECT to_jsonb(f) FROM public.amazon_product_facts f WHERE f.asin = l.asin),
    'versions', coalesce((SELECT jsonb_agg(jsonb_build_object('version', v.version, 'source', v.source, 'at', v.created_at)
                 ORDER BY v.version DESC) FROM public.amazon_listing_versions v WHERE v.sku = l.sku), '[]'),
    'findings', coalesce((SELECT jsonb_agg(f) FROM public.amazon_audit_findings f WHERE f.sku = l.sku AND f.status = 'open'), '[]'));
END $$;

-- Preview the guard result of a draft without saving it (Content Studio uses this while typing).
CREATE OR REPLACE FUNCTION public.api_amz_check(p_kind text, p_sku text, p_after jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN crm_private.amz_evaluate(p_kind, p_sku, p_after);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_draft_create(p_kind text, p_sku text, p_after jsonb, p_summary text DEFAULT '',
  p_batch uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; l public.amazon_listings; clean jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_kind NOT IN ('listing', 'price', 'ads_budget', 'create') THEN RAISE EXCEPTION 'Unknown change type' USING ERRCODE = 'PT422'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF p_kind <> 'ads_budget' AND p_kind <> 'create' AND l.sku IS NULL THEN RAISE EXCEPTION 'Listing not found' USING ERRCODE = 'PT404'; END IF;
  -- keep only fields the module knows
  SELECT coalesce(jsonb_object_agg(k, v), '{}') INTO clean FROM jsonb_each(coalesce(p_after, '{}')) e(k, v)
   WHERE k IN ('title','item_highlights','bullets','description','backend_terms','price','mrp','country_of_origin',
               'manufacturer','net_quantity','main_image','claims','daily_budget_total','asin','product_type');
  IF clean = '{}' THEN RAISE EXCEPTION 'Nothing to change' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, batch_id, created_by_type, created_by)
  VALUES (p_kind, p_sku, coalesce(l.asin, clean->>'asin'), left(coalesce(p_summary, ''), 300),
          coalesce(crm_private.amz_snapshot(p_sku), '{}'), clean, l.version, p_batch, 'user', crm_private.current_employee_id())
  RETURNING * INTO q;
  PERFORM crm_private.amz_log('draft_created', 'change', q.id::text, jsonb_build_object('sku', p_sku, 'kind', p_kind));
  RETURN to_jsonb(q);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_queue(p_status text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC) FROM (
      SELECT * FROM public.amazon_change_queue
      WHERE p_status IS NULL OR status = p_status OR (p_status = 'open' AND status IN ('pending', 'approved', 'executing', 'stale', 'failed', 'needs_manual'))
      ORDER BY created_at DESC LIMIT 300) q), '[]');
END $$;

-- Approve. Row-locked: two people approving at once -> exactly one approval; the second gets "already approved".
CREATE OR REPLACE FUNCTION public.api_amz_approve(p_id uuid, p_second_confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; cur int; me uuid := crm_private.current_employee_id();
BEGIN
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to approve Amazon changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO q FROM public.amazon_change_queue WHERE id = p_id FOR UPDATE;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Change not found' USING ERRCODE = 'PT404'; END IF;
  IF q.status <> 'pending' THEN RAISE EXCEPTION 'Already %', q.status USING ERRCODE = 'PT409'; END IF;
  -- Stale check: listing changed since the draft was made
  IF q.sku IS NOT NULL AND q.base_version IS NOT NULL THEN
    SELECT version INTO cur FROM public.amazon_listings WHERE sku = q.sku;
    IF cur IS DISTINCT FROM q.base_version THEN
      -- Not an exception: an exception would undo the Stale mark. The caller sees status = 'stale'.
      UPDATE public.amazon_change_queue SET status = 'stale',
        error = format('Listing changed since this draft (version %s, now %s). Review again.', q.base_version, cur)
       WHERE id = p_id RETURNING * INTO q;
      PERFORM crm_private.amz_log('change_stale', 'change', p_id::text, jsonb_build_object('sku', q.sku));
      RETURN to_jsonb(q);
    END IF;
  END IF;
  IF NOT coalesce((q.guard_result->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'This change has blockers and cannot be approved' USING ERRCODE = 'PT422';
  END IF;
  IF q.needs_second_confirm AND NOT coalesce(p_second_confirm, false) THEN
    RAISE EXCEPTION 'This change needs a second confirmation' USING ERRCODE = 'PT428';
  END IF;
  UPDATE public.amazon_change_queue SET
      second_confirmed_by = CASE WHEN q.needs_second_confirm THEN me END,
      status = 'approved', approved_by = me, approved_at = now()
   WHERE id = p_id RETURNING * INTO q;
  PERFORM crm_private.amz_log('change_approved', 'change', p_id::text,
    jsonb_build_object('sku', q.sku, 'second_confirm', q.needs_second_confirm));
  RETURN to_jsonb(q);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_reject(p_id uuid, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue;
BEGIN
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to reject Amazon changes' USING ERRCODE = 'PT403'; END IF;
  IF length(trim(coalesce(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'Give a reason (Claude reads it before drafting again)' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.amazon_change_queue SET status = 'rejected', reject_reason = trim(p_reason)
   WHERE id = p_id AND status IN ('pending', 'stale') RETURNING * INTO q;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Only pending or stale changes can be rejected' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.amz_log('change_rejected', 'change', p_id::text, jsonb_build_object('reason', q.reject_reason));
  RETURN to_jsonb(q);
END $$;

-- Rollback = a new pending change that restores the 'before' snapshot of a live change (same guards, same approval).
CREATE OR REPLACE FUNCTION public.api_amz_rollback(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; r public.amazon_change_queue; restore jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  SELECT * INTO q FROM public.amazon_change_queue WHERE id = p_id;
  IF q.id IS NULL OR q.status NOT IN ('live', 'needs_manual', 'failed') THEN
    RAISE EXCEPTION 'Only live (or failed) changes can be rolled back' USING ERRCODE = 'PT409';
  END IF;
  SELECT coalesce(jsonb_object_agg(k, q.before->k), '{}') INTO restore FROM jsonb_object_keys(q.after) k WHERE q.before ? k;
  IF restore = '{}' THEN RAISE EXCEPTION 'Nothing to restore' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, rollback_of, created_by_type, created_by)
  SELECT 'rollback', q.sku, q.asin, 'Roll back: ' || q.summary, crm_private.amz_snapshot(q.sku), restore,
         l.version, q.id, 'user', crm_private.current_employee_id()
    FROM public.amazon_listings l WHERE l.sku = q.sku RETURNING * INTO r;
  PERFORM crm_private.amz_log('rollback_drafted', 'change', r.id::text, jsonb_build_object('of', p_id));
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_cancel_batch(p_batch uuid) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Not allowed' USING ERRCODE = 'PT403'; END IF;
  UPDATE public.amazon_change_queue SET status = 'cancelled' WHERE batch_id = p_batch AND status IN ('pending', 'approved');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM crm_private.amz_log('batch_cancelled', 'batch', p_batch::text, jsonb_build_object('cancelled', n));
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_findings(p_status text DEFAULT 'open') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY (f.severity = 'blocker') DESC, crm_private.amz_rank(f.rule_code), f.created_at DESC)
    FROM public.amazon_audit_findings f WHERE p_status IS NULL OR f.status = p_status), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_finding_dismiss(p_id bigint, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF length(trim(coalesce(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = 'PT422'; END IF;
  UPDATE public.amazon_audit_findings SET status = 'dismissed', dismiss_reason = trim(p_reason), resolved_at = now()
   WHERE id = p_id AND status = 'open';
  PERFORM crm_private.amz_log('finding_dismissed', 'finding', p_id::text, jsonb_build_object('reason', trim(p_reason)));
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_audit_run() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN crm_private.amz_audit_all();
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keywords() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(k) ORDER BY (k.status = 'pinned') DESC, k.updated_at DESC)
    FROM public.amazon_keywords k), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keyword_set(p_keyword text, p_status text, p_asins text[] DEFAULT NULL,
  p_placement text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF length(trim(coalesce(p_keyword, ''))) < 2 THEN RAISE EXCEPTION 'Keyword is empty' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_keywords (keyword, source, status, asins, placement)
  VALUES (lower(trim(p_keyword)), 'user', coalesce(p_status, 'candidate'), coalesce(p_asins, '{}'), p_placement)
  ON CONFLICT (lower(keyword)) DO UPDATE SET status = coalesce(p_status, public.amazon_keywords.status),
    asins = coalesce(p_asins, public.amazon_keywords.asins), placement = coalesce(p_placement, public.amazon_keywords.placement),
    updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_competitors() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.my_asin, c.updated_at DESC)
    FROM public.amazon_competitors c WHERE c.active), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_competitor_set(p_asin text, p_my_asin text, p_active boolean DEFAULT true) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF upper(trim(p_asin)) !~ '^B0[A-Z0-9]{8}$' THEN RAISE EXCEPTION 'ASIN looks wrong (B0 + 8 letters/digits)' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_competitors (asin, my_asin, active, added_by)
  VALUES (upper(trim(p_asin)), upper(trim(p_my_asin)), p_active, crm_private.current_employee_id())
  ON CONFLICT (asin) DO UPDATE SET active = p_active, my_asin = coalesce(EXCLUDED.my_asin, public.amazon_competitors.my_asin), updated_at = now();
  PERFORM crm_private.amz_log(CASE WHEN p_active THEN 'competitor_added' ELSE 'competitor_removed' END, 'competitor', upper(trim(p_asin)), '{}');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_facts_set(p_asin text, p_buyer text, p_use_cases text, p_facts jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF jsonb_typeof(coalesce(p_facts, '[]')) <> 'array' THEN RAISE EXCEPTION 'Facts must be a list' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_product_facts (asin, buyer, use_cases, facts, updated_by)
  VALUES (p_asin, p_buyer, p_use_cases, coalesce(p_facts, '[]'), crm_private.current_employee_id())
  ON CONFLICT (asin) DO UPDATE SET buyer = EXCLUDED.buyer, use_cases = EXCLUDED.use_cases, facts = EXCLUDED.facts,
    updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM crm_private.amz_log('brief_saved', 'product_facts', p_asin, '{}');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_sales(p_days int DEFAULT 30) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE since date := (now() AT TIME ZONE 'Asia/Kolkata')::date - greatest(1, least(coalesce(p_days, 30), 730));
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'daily', coalesce((SELECT jsonb_agg(d ORDER BY d.day) FROM (SELECT day, sum(units) units, sum(revenue) revenue,
        sum(sessions) sessions, sum(refunds) refunds, sum(fees) fees FROM public.amazon_sales_daily WHERE day > since GROUP BY day) d), '[]'),
    'by_sku', coalesce((SELECT jsonb_agg(d ORDER BY d.revenue DESC) FROM (SELECT s.sku, max(s.asin) asin, sum(units) units,
        sum(revenue) revenue, sum(sessions) sessions,
        CASE WHEN sum(sessions) > 0 THEN round(100.0 * sum(units) / sum(sessions), 2) END conversion_pct
        FROM public.amazon_sales_daily s WHERE day > since GROUP BY s.sku) d), '[]'));
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_health(p_days int DEFAULT 90) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object('warn', crm_private.amz_rule('health_warn'),
    'days', coalesce((SELECT jsonb_agg(to_jsonb(h) - 'raw' ORDER BY h.day)
      FROM public.amazon_health_daily h WHERE h.day > (now() AT TIME ZONE 'Asia/Kolkata')::date - coalesce(p_days, 90)), '[]'));
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_inventory() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x.days_of_cover NULLS LAST) FROM (
    SELECT l.sku, l.asin, l.title, l.quantity, l.price, l.buybox_price, l.has_buybox, l.buybox_seller, l.fulfillment,
           s.units_30, CASE WHEN coalesce(s.units_30, 0) > 0 THEN round(l.quantity / (s.units_30 / 30.0), 1) END AS days_of_cover
      FROM public.amazon_listings l
      LEFT JOIN (SELECT sku, sum(units) units_30 FROM public.amazon_sales_daily
                 WHERE day > (now() AT TIME ZONE 'Asia/Kolkata')::date - 30 GROUP BY sku) s ON s.sku = l.sku
     WHERE NOT l.is_parent) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_tasks() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY (t.status = 'open') DESC, t.due_on NULLS LAST, t.id)
    FROM public.amazon_tasks t), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_task_set(p_id bigint, p_title text, p_due date, p_status text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_id IS NULL THEN
    IF length(trim(coalesce(p_title, ''))) < 2 THEN RAISE EXCEPTION 'Title is empty' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.amazon_tasks (title, due_on, source) VALUES (trim(p_title), p_due, 'user');
  ELSE
    UPDATE public.amazon_tasks SET status = coalesce(p_status, status), due_on = coalesce(p_due, due_on),
      done_at = CASE WHEN p_status = 'done' THEN now() END WHERE id = p_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_requests() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC) FROM (
    SELECT * FROM public.amazon_claude_requests ORDER BY created_at DESC LIMIT 100) r), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_request_create(p_question text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests;
BEGIN
  PERFORM crm_private.amz_require_view();
  INSERT INTO public.amazon_claude_requests (question, asked_by) VALUES (trim(p_question), crm_private.current_employee_id())
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_request_cancel(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  UPDATE public.amazon_claude_requests SET status = 'cancelled' WHERE id = p_id AND status = 'waiting';
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_activity(p_limit int DEFAULT 200) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x.at DESC) FROM (
    SELECT a.*, e.name AS actor_name FROM public.amazon_activity_log a LEFT JOIN public.employee e ON e.id = a.actor
    ORDER BY a.at DESC LIMIT greatest(1, least(coalesce(p_limit, 200), 1000))) x), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_rules() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.code) FROM public.amazon_rules r), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_rule_set(p_code text, p_value jsonb, p_active boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_admin();
  IF p_code = 'price_floor' AND coalesce((p_value->>'min')::numeric, 0) < 1 THEN
    RAISE EXCEPTION 'Price floor must be a positive amount' USING ERRCODE = 'PT422';
  END IF;
  UPDATE public.amazon_rules SET value = coalesce(p_value, value), active = coalesce(p_active, active), updated_at = now()
   WHERE code = p_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown rule' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.amz_log('rule_changed', 'rule', p_code, jsonb_build_object('value', p_value, 'active', p_active));
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_approvers() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_admin();
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.name, 'department', e.department,
      'access', a.employee_id IS NOT NULL, 'can_approve', coalesce(a.can_approve, false)) ORDER BY e.name)
    FROM public.employee e LEFT JOIN public.amazon_approvers a ON a.employee_id = e.id WHERE e.active), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_approver_set(p_employee uuid, p_access boolean, p_can_approve boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_admin();
  IF NOT coalesce(p_access, false) THEN
    DELETE FROM public.amazon_approvers WHERE employee_id = p_employee;
  ELSE
    INSERT INTO public.amazon_approvers (employee_id, can_approve, granted_by)
    VALUES (p_employee, coalesce(p_can_approve, false), crm_private.current_employee_id())
    ON CONFLICT (employee_id) DO UPDATE SET can_approve = EXCLUDED.can_approve, granted_by = EXCLUDED.granted_by, granted_at = now();
  END IF;
  PERFORM crm_private.amz_log('approver_set', 'employee', p_employee::text,
    jsonb_build_object('access', p_access, 'can_approve', p_can_approve));
END $$;

-- ===========================================================================================
-- 8. Service API for the amazon-* Edge Functions (service role only)
-- ===========================================================================================
CREATE OR REPLACE FUNCTION public.svc_amz_secrets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_object_agg(upper(substr(d.name, 5)), d.decrypted_secret), '{}') || jsonb_build_object(
    'MARKETPLACE_ID', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'marketplace_id'),
    'ENDPOINT', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'endpoint'),
    'LANGUAGE_TAG', (SELECT c.value FROM public.amazon_config c WHERE c.key = 'language_tag'))
  FROM vault.decrypted_secrets d WHERE d.name LIKE 'amz\_%'
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_record_test(p_status text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_config (key, value) VALUES
    ('last_test_status', p_status), ('last_test_detail', left(p_detail, 500)), ('last_test_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  INSERT INTO public.amazon_activity_log (actor_type, action, entity, details)
  VALUES ('system', 'connection_tested', 'settings', jsonb_build_object('status', p_status));
$$;

-- Run lock per job (same lease table as the other background jobs).
CREATE OR REPLACE FUNCTION public.svc_amz_run_begin(p_job text, p_seconds int DEFAULT 600) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint;
BEGIN
  IF NOT crm_private.take_lease('amazon_' || p_job, p_seconds) THEN
    INSERT INTO public.amazon_sync_runs (job, status, detail, finished_at) VALUES (p_job, 'skipped', 'another run holds the lock', now());
    RETURN NULL;
  END IF;
  INSERT INTO public.amazon_sync_runs (job) VALUES (p_job) RETURNING id INTO rid;
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_run_end(p_run bigint, p_job text, p_status text, p_items int, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.amazon_sync_runs SET status = p_status, items = p_items, detail = left(p_detail, 1000), finished_at = now()
   WHERE id = p_run;
  UPDATE public.job_lease SET lease_until = now() WHERE name = 'amazon_' || p_job AND holder = 'supabase';
END $$;

-- Listings from Amazon. Detects Amazon rewriting a title (drift) and records versions.
-- p_items: [{sku, asin, parent_asin, is_parent, product_type, status, title, bullets, description, backend_terms,
--            price, mrp, quantity, fulfillment, country_of_origin, manufacturer, net_quantity, attributes, images, issues}]
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_listings(p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; old public.amazon_listings; n int := 0; drift int := 0; changed boolean;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    SELECT * INTO old FROM public.amazon_listings WHERE sku = it->>'sku' FOR UPDATE;
    IF old.sku IS NULL THEN
      INSERT INTO public.amazon_listings (sku, asin, title, last_approved_title, version) VALUES (it->>'sku', it->>'asin', it->>'title', it->>'title', 1);
      changed := true;
    ELSE
      changed := (old.title, old.bullets, old.description, old.backend_terms, old.price, old.mrp, old.images)
        IS DISTINCT FROM (it->>'title', coalesce(it->'bullets', '[]'), it->>'description', it->>'backend_terms',
                          nullif(it->>'price', '')::numeric, nullif(it->>'mrp', '')::numeric, coalesce(it->'images', '[]'));
      -- Drift: Amazon's title differs from the last title we approved, and no change of ours is in flight.
      IF old.last_approved_title IS NOT NULL AND it->>'title' IS DISTINCT FROM old.last_approved_title
         AND NOT EXISTS (SELECT 1 FROM public.amazon_change_queue q WHERE q.sku = old.sku AND q.status IN ('approved', 'executing')) THEN
        INSERT INTO public.amazon_audit_findings (sku, asin, rule_code, severity, message, source)
        VALUES (old.sku, old.asin, 'title_drift', 'warning',
          format('Title changed outside the CRM (changed by Amazon or in Seller Central). Was: "%s"', left(old.last_approved_title, 120)), 'sync')
        ON CONFLICT DO NOTHING;
        drift := drift + 1;
      END IF;
    END IF;
    UPDATE public.amazon_listings SET
      asin = coalesce(it->>'asin', asin), parent_asin = it->>'parent_asin',
      is_parent = coalesce((it->>'is_parent')::boolean, is_parent), product_type = coalesce(it->>'product_type', product_type),
      status = coalesce(it->>'status', status), title = coalesce(it->>'title', title),
      bullets = coalesce(it->'bullets', bullets), description = coalesce(it->>'description', description),
      backend_terms = coalesce(it->>'backend_terms', backend_terms),
      price = coalesce(nullif(it->>'price', '')::numeric, price), mrp = coalesce(nullif(it->>'mrp', '')::numeric, mrp),
      quantity = coalesce(nullif(it->>'quantity', '')::int, quantity), fulfillment = coalesce(it->>'fulfillment', fulfillment),
      country_of_origin = coalesce(it->>'country_of_origin', country_of_origin),
      manufacturer = coalesce(it->>'manufacturer', manufacturer), net_quantity = coalesce(it->>'net_quantity', net_quantity),
      attributes = coalesce(it->'attributes', attributes), images = coalesce(it->'images', images),
      issues = coalesce(it->'issues', '[]'),
      version = CASE WHEN changed AND old.sku IS NOT NULL THEN version + 1 ELSE version END,
      synced_at = now(), updated_at = now()
     WHERE sku = it->>'sku';
    IF changed THEN
      INSERT INTO public.amazon_listing_versions (sku, version, source, snapshot)
      SELECT sku, version, CASE WHEN old.sku IS NULL THEN 'import' ELSE 'sync' END, crm_private.amz_snapshot(sku)
        FROM public.amazon_listings WHERE sku = it->>'sku';
      -- Pending drafts made against the old version are now stale.
      UPDATE public.amazon_change_queue SET status = 'stale', error = 'Listing changed on Amazon after this draft was made.'
       WHERE sku = it->>'sku' AND status = 'pending' AND old.sku IS NOT NULL;
    END IF;
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('upserted', n, 'drift', drift);
END $$;

-- [{asin, buybox_price, buybox_seller, my_seller_has_buybox}]
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_pricing(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; n int := 0;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    UPDATE public.amazon_listings SET buybox_price = nullif(it->>'buybox_price', '')::numeric,
      buybox_seller = it->>'buybox_seller', has_buybox = (it->>'my_seller_has_buybox')::boolean, updated_at = now()
     WHERE asin = it->>'asin';
    UPDATE public.amazon_competitors SET price = nullif(it->>'buybox_price', '')::numeric, buybox_seller = it->>'buybox_seller',
      updated_at = now() WHERE asin = it->>'asin';
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- [{asin, title, bsr, image_count}]
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_catalog(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; n int := 0;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    UPDATE public.amazon_competitors SET title = coalesce(it->>'title', title), bsr = nullif(it->>'bsr', '')::int,
      image_count = nullif(it->>'image_count', '')::int, updated_at = now() WHERE asin = it->>'asin';
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- [{day, sku, asin, units, revenue, sessions, page_views, buybox_pct, refunds, fees}] (only keys present are written)
CREATE OR REPLACE FUNCTION public.svc_amz_upsert_sales(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; n int := 0;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    INSERT INTO public.amazon_sales_daily (day, sku, asin, units, revenue, sessions, page_views, buybox_pct, refunds, fees)
    VALUES ((it->>'day')::date, it->>'sku', it->>'asin', coalesce((it->>'units')::int, 0), coalesce((it->>'revenue')::numeric, 0),
            (it->>'sessions')::int, (it->>'page_views')::int, (it->>'buybox_pct')::numeric, coalesce((it->>'refunds')::int, 0),
            (it->>'fees')::numeric)
    ON CONFLICT (day, sku) DO UPDATE SET
      asin = coalesce(EXCLUDED.asin, public.amazon_sales_daily.asin),
      units = CASE WHEN it ? 'units' THEN EXCLUDED.units ELSE public.amazon_sales_daily.units END,
      revenue = CASE WHEN it ? 'revenue' THEN EXCLUDED.revenue ELSE public.amazon_sales_daily.revenue END,
      sessions = CASE WHEN it ? 'sessions' THEN EXCLUDED.sessions ELSE public.amazon_sales_daily.sessions END,
      page_views = CASE WHEN it ? 'page_views' THEN EXCLUDED.page_views ELSE public.amazon_sales_daily.page_views END,
      buybox_pct = CASE WHEN it ? 'buybox_pct' THEN EXCLUDED.buybox_pct ELSE public.amazon_sales_daily.buybox_pct END,
      refunds = CASE WHEN it ? 'refunds' THEN EXCLUDED.refunds ELSE public.amazon_sales_daily.refunds END,
      fees = CASE WHEN it ? 'fees' THEN EXCLUDED.fees ELSE public.amazon_sales_daily.fees END,
      updated_at = now();
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_upsert_health(p_day date, p_odr numeric, p_cancel numeric, p_late numeric,
  p_vtr numeric, p_policy int, p_raw jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_health_daily (day, odr, cancel_rate, late_ship_rate, valid_tracking_rate, policy_issues, raw)
  VALUES (p_day, p_odr, p_cancel, p_late, p_vtr, p_policy, p_raw)
  ON CONFLICT (day) DO UPDATE SET odr = EXCLUDED.odr, cancel_rate = EXCLUDED.cancel_rate,
    late_ship_rate = EXCLUDED.late_ship_rate, valid_tracking_rate = EXCLUDED.valid_tracking_rate,
    policy_issues = EXCLUDED.policy_issues, raw = EXCLUDED.raw, updated_at = now();
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_config_get(p_key text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT c.value FROM public.amazon_config c WHERE c.key = p_key $$;
CREATE OR REPLACE FUNCTION public.svc_amz_config_set(p_key text, p_value text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_config (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_competitor_asins() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT a), '{}') FROM (
    SELECT asin a FROM public.amazon_listings WHERE asin IS NOT NULL AND NOT is_parent
    UNION SELECT asin FROM public.amazon_competitors WHERE active) x
$$;

-- Claim one approved change for execution. Exactly once: the UPDATE ... WHERE status = 'approved' wins for one caller.
CREATE OR REPLACE FUNCTION public.svc_amz_claim(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue;
BEGIN
  UPDATE public.amazon_change_queue SET status = 'executing', executed_at = now()
   WHERE id = p_id AND status = 'approved' RETURNING * INTO q;
  IF q.id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.amazon_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('system', 'change_executing', 'change', p_id::text, jsonb_build_object('idempotency_key', q.idempotency_key));
  RETURN to_jsonb(q) || jsonb_build_object('listing', crm_private.amz_snapshot(q.sku),
    'seller_sku', q.sku, 'product_type', (SELECT l.product_type FROM public.amazon_listings l WHERE l.sku = q.sku));
END $$;

-- Approved items nobody has run yet (browser closed), and items stuck in 'executing' (network drop) to reconcile.
CREATE OR REPLACE FUNCTION public.svc_amz_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'approved', coalesce((SELECT jsonb_agg(id ORDER BY approved_at) FROM public.amazon_change_queue
                          WHERE status = 'approved' AND approved_at < now() - interval '2 minutes'), '[]'),
    'stuck', coalesce((SELECT jsonb_agg(to_jsonb(q)) FROM public.amazon_change_queue q
                       WHERE status = 'executing' AND executed_at < now() - interval '10 minutes'), '[]'))
$$;

-- Write a live change's values into the CRM copy of the listing and record a version.
CREATE OR REPLACE FUNCTION crm_private.amz_apply_live(q public.amazon_change_queue) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a jsonb;
BEGIN
  IF q.sku IS NOT NULL THEN
    a := q.after;
    UPDATE public.amazon_listings SET
      title = CASE WHEN a ? 'title' THEN a->>'title' ELSE title END,
      last_approved_title = CASE WHEN a ? 'title' THEN a->>'title' ELSE last_approved_title END,
      item_highlights = CASE WHEN a ? 'item_highlights' THEN a->>'item_highlights' ELSE item_highlights END,
      bullets = CASE WHEN a ? 'bullets' THEN a->'bullets' ELSE bullets END,
      description = CASE WHEN a ? 'description' THEN a->>'description' ELSE description END,
      backend_terms = CASE WHEN a ? 'backend_terms' THEN a->>'backend_terms' ELSE backend_terms END,
      price = CASE WHEN a ? 'price' THEN (a->>'price')::numeric ELSE price END,
      mrp = CASE WHEN a ? 'mrp' THEN (a->>'mrp')::numeric ELSE mrp END,
      country_of_origin = CASE WHEN a ? 'country_of_origin' THEN a->>'country_of_origin' ELSE country_of_origin END,
      manufacturer = CASE WHEN a ? 'manufacturer' THEN a->>'manufacturer' ELSE manufacturer END,
      net_quantity = CASE WHEN a ? 'net_quantity' THEN a->>'net_quantity' ELSE net_quantity END,
      version = version + 1, updated_at = now()
     WHERE sku = q.sku;
    INSERT INTO public.amazon_listing_versions (sku, version, source, snapshot, change_id)
    SELECT sku, version, CASE WHEN q.kind = 'rollback' THEN 'rollback' ELSE 'change' END, crm_private.amz_snapshot(sku), q.id
      FROM public.amazon_listings WHERE sku = q.sku;
  END IF;
END $$;

-- Finish an execution. p_status: live | failed | stale | needs_manual.
-- live: write 'after' into the listing, bump version, record version + last_approved_title.
-- p_suppressed: Amazon reports the listing suppressed/blocked after the change -> open a rollback draft.
CREATE OR REPLACE FUNCTION public.svc_amz_finish(p_id uuid, p_status text, p_preview jsonb, p_error text,
  p_suppressed boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; rb uuid;
BEGIN
  UPDATE public.amazon_change_queue SET status = p_status, preview_result = coalesce(p_preview, preview_result),
    error = left(p_error, 1000) WHERE id = p_id AND status = 'executing' RETURNING * INTO q;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Change is not executing' USING ERRCODE = 'PT409'; END IF;
  IF p_status = 'live' THEN PERFORM crm_private.amz_apply_live(q); END IF;
  IF p_suppressed THEN
    INSERT INTO public.amazon_audit_findings (sku, asin, rule_code, severity, message, source)
    VALUES (q.sku, q.asin, 'suppressed_after_change', 'blocker',
      'Listing is suppressed after an approved change. A rollback draft is waiting in the Change Queue.', 'sync')
    ON CONFLICT DO NOTHING;
    INSERT INTO public.amazon_change_queue (kind, sku, asin, summary, before, after, base_version, rollback_of, created_by_type)
    SELECT 'rollback', q.sku, q.asin, 'Roll back (suppressed): ' || q.summary, crm_private.amz_snapshot(q.sku),
           (SELECT coalesce(jsonb_object_agg(k, q.before->k), '{}') FROM jsonb_object_keys(q.after) k WHERE q.before ? k),
           l.version, q.id, 'system'
      FROM public.amazon_listings l WHERE l.sku = q.sku RETURNING id INTO rb;
  END IF;
  INSERT INTO public.amazon_activity_log (actor_type, action, entity, entity_id, details)
  VALUES ('system', 'change_' || p_status, 'change', p_id::text, jsonb_build_object('sku', q.sku, 'rollback_draft', rb));
  RETURN jsonb_build_object('status', p_status, 'rollback_draft', rb);
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_audit() RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.amz_audit_all() $$;


-- "Needs manual": the person did the remaining part in Seller Central / Campaign Manager and confirms it.
CREATE OR REPLACE FUNCTION public.api_amz_manual_done(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue;
BEGIN
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Not allowed' USING ERRCODE = 'PT403'; END IF;
  UPDATE public.amazon_change_queue SET status = 'live' WHERE id = p_id AND status = 'needs_manual' RETURNING * INTO q;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Only changes waiting for manual steps can be marked done' USING ERRCODE = 'PT409'; END IF;
  IF q.kind <> 'ads_budget' THEN PERFORM crm_private.amz_apply_live(q); END IF;
  PERFORM crm_private.amz_log('manual_done', 'change', p_id::text, '{}');
  RETURN to_jsonb(q);
END $$;

-- Failed or stale change sent back to Pending (re-checked against today's listing and rules).
CREATE OR REPLACE FUNCTION public.api_amz_resubmit(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue;
BEGIN
  PERFORM crm_private.amz_require_view();
  UPDATE public.amazon_change_queue SET status = 'pending', error = NULL, approved_by = NULL, approved_at = NULL,
      second_confirmed_by = NULL, before = coalesce(crm_private.amz_snapshot(sku), before),
      base_version = (SELECT l.version FROM public.amazon_listings l WHERE l.sku = amazon_change_queue.sku)
   WHERE id = p_id AND status IN ('failed', 'stale') RETURNING * INTO q;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Only failed or stale changes can be re-submitted' USING ERRCODE = 'PT409'; END IF;
  PERFORM crm_private.amz_log('change_resubmitted', 'change', p_id::text, '{}');
  RETURN to_jsonb(q);
END $$;

-- ===========================================================================================
-- 9. Grants
-- ===========================================================================================
DO $$
DECLARE f text;
BEGIN
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE (n.nspname = 'public' AND p.proname LIKE 'api\_amz\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE (n.nspname = 'public' AND p.proname LIKE 'svc\_amz\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE (n.nspname = 'crm_private' AND p.proname LIKE 'amz\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;
