-- 081: Personalisation. My style (tone + words to use / avoid) for every Claude suggestion, profit per product
-- (your cost + Amazon fees), festival calendar with "prepare" for Claude, decisions linked from the alert email,
-- and replies in the owner's language (English, Hindi or Hinglish; set in the server-side prompt).
-- Re-runnable. Builds on 072-080.

-- ---------------------------------------------------------------- my style
CREATE OR REPLACE FUNCTION public.api_amz_style(p_style jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean jsonb;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_style IS NOT NULL THEN
    IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Only Admin and people allowed to approve can change the style' USING ERRCODE = 'PT403'; END IF;
    IF jsonb_typeof(p_style) <> 'object' OR length(p_style::text) > 4000 THEN RAISE EXCEPTION 'Style is too long' USING ERRCODE = 'PT422'; END IF;
    clean := jsonb_strip_nulls(jsonb_build_object(
      'tone', left(p_style->>'tone', 60),
      'language', CASE WHEN p_style->>'language' IN ('auto', 'english', 'hindi', 'hinglish') THEN p_style->>'language' ELSE 'auto' END,
      'use_words', (SELECT jsonb_agg(DISTINCT left(trim(w), 40)) FROM jsonb_array_elements_text(coalesce(p_style->'use_words', '[]')) w WHERE trim(w) <> ''),
      'avoid_words', (SELECT jsonb_agg(DISTINCT left(lower(trim(w)), 40)) FROM jsonb_array_elements_text(coalesce(p_style->'avoid_words', '[]')) w WHERE trim(w) <> ''),
      'notes', left(p_style->>'notes', 600)));
    INSERT INTO public.amazon_config (key, value) VALUES ('style_guide', clean::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.amz_log('style_set', 'settings', NULL, '{}');
  END IF;
  RETURN coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'style_guide'), '{"language": "auto"}');
END $$;

-- ---------------------------------------------------------------- profit per product
CREATE TABLE IF NOT EXISTS public.amazon_costs (
  sku text PRIMARY KEY,
  cost numeric(10,2) NOT NULL CHECK (cost >= 0),          -- product cost incl. printing the name
  extra numeric(10,2) NOT NULL DEFAULT 0 CHECK (extra >= 0), -- packing etc. per order
  updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.amazon_costs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_costs FROM anon, authenticated;

-- Amazon fees per unit = fees / units over the last 60 days (from Finances); NULL until there is data.
CREATE OR REPLACE FUNCTION crm_private.amz_margins() RETURNS TABLE (sku text, price numeric, cost numeric, extra numeric,
  fee_per_unit numeric, profit numeric, margin_pct numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT l.sku, l.price, c.cost, c.extra,
         round(f.fees / nullif(f.units, 0), 2),
         CASE WHEN c.cost IS NOT NULL AND l.price IS NOT NULL THEN round(l.price - c.cost - c.extra - coalesce(f.fees / nullif(f.units, 0), 0), 2) END,
         CASE WHEN c.cost IS NOT NULL AND l.price > 0 THEN round(100 * (l.price - c.cost - c.extra - coalesce(f.fees / nullif(f.units, 0), 0)) / l.price, 1) END
    FROM public.amazon_listings l
    LEFT JOIN public.amazon_costs c USING (sku)
    LEFT JOIN (SELECT s.sku, sum(abs(s.fees)) fees, sum(s.units) units FROM public.amazon_sales_daily s
                WHERE s.day > current_date - 60 GROUP BY s.sku) f USING (sku)
   WHERE NOT coalesce(l.is_parent, false)
$$;

CREATE OR REPLACE FUNCTION public.api_amz_margins() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(m) || jsonb_build_object('title', l.title, 'photo', l.images->0->>'url') ORDER BY m.margin_pct NULLS FIRST)
    FROM crm_private.amz_margins() m JOIN public.amazon_listings l USING (sku)), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_cost_set(p_sku text, p_cost numeric, p_extra numeric DEFAULT 0) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'Only Admin and people allowed to approve can set costs' USING ERRCODE = 'PT403'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.amazon_listings WHERE sku = p_sku) THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = 'PT404'; END IF;
  IF p_cost IS NULL THEN DELETE FROM public.amazon_costs WHERE sku = p_sku; RETURN; END IF;
  IF p_cost < 0 OR p_cost > 100000 OR coalesce(p_extra, 0) < 0 OR coalesce(p_extra, 0) > 100000 THEN RAISE EXCEPTION 'Enter a cost between 0 and 100000' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.amazon_costs (sku, cost, extra) VALUES (p_sku, p_cost, coalesce(p_extra, 0))
  ON CONFLICT (sku) DO UPDATE SET cost = EXCLUDED.cost, extra = EXCLUDED.extra, updated_at = now();
END $$;

-- ---------------------------------------------------------------- festival calendar
CREATE TABLE IF NOT EXISTS public.amazon_festivals (
  day date NOT NULL, name text NOT NULL, note text, PRIMARY KEY (day, name));
ALTER TABLE public.amazon_festivals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_festivals FROM anon, authenticated;
-- Dates: officeholidays.com India 2027 (lunar festivals); fixed-date days as per the calendar.
INSERT INTO public.amazon_festivals (day, name, note) VALUES
  ('2026-11-14', 'Children''s Day', 'Gifts for kids and students'),
  ('2026-12-25', 'Christmas', 'Year-end gifting; diaries for the new year'),
  ('2027-01-01', 'New Year', 'Peak season for 2027 diaries and planners'),
  ('2027-01-26', 'Republic Day', 'Corporate and school gifting'),
  ('2027-03-22', 'Holi', 'Festive gifting'),
  ('2027-08-15', 'Independence Day', 'Corporate gifting'),
  ('2027-08-17', 'Raksha Bandhan', 'Gift for brother or sister, name on the cover'),
  ('2027-09-04', 'Ganesh Chaturthi', 'Festive gifting'),
  ('2027-09-05', 'Teachers'' Day', 'Personalised diaries as teacher gifts'),
  ('2027-10-09', 'Dussehra', 'Festive gifting'),
  ('2027-10-29', 'Diwali', 'Biggest gifting season; 2028 diaries start'),
  ('2027-12-25', 'Christmas', 'Year-end gifting; 2028 diaries')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.api_amz_festivals() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('name', f.name, 'day', f.day, 'note', f.note, 'days_left', f.day - today,
      'prepared', EXISTS (SELECT 1 FROM public.amazon_claude_requests r WHERE r.kind = 'chat' AND r.question LIKE 'Festival prep: ' || f.name || '%'
                          AND r.created_at > f.day - 60)) ORDER BY f.day)
    FROM public.amazon_festivals f WHERE f.day >= today AND f.day <= today + 120), '[]');
END $$;

-- Ask Claude to prepare names / prices / key points for a festival (drafts land in Decisions).
CREATE OR REPLACE FUNCTION public.api_amz_festival_prep(p_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE f public.amazon_festivals; r public.amazon_claude_requests;
BEGIN
  PERFORM crm_private.amz_require_view();
  PERFORM crm_private.amz_require_chat();
  SELECT * INTO f FROM public.amazon_festivals WHERE name = p_name AND day >= (now() AT TIME ZONE 'Asia/Kolkata')::date ORDER BY day LIMIT 1;
  IF f.name IS NULL THEN RAISE EXCEPTION 'Festival not found' USING ERRCODE = 'PT404'; END IF;
  INSERT INTO public.amazon_claude_requests (question, asked_by, kind)
  VALUES (format('Festival prep: %s on %s (%s). Suggest which products to push and draft better names, key points and (only if margins allow) prices for the 5 best-fitting products. Keep every rule.',
                 f.name, to_char(f.day, 'DD Mon YYYY'), coalesce(f.note, '')), crm_private.current_employee_id(), 'chat')
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

-- ---------------------------------------------------------------- decisions in the alert email
ALTER TABLE public.amazon_change_queue ADD COLUMN IF NOT EXISTS emailed_at timestamptz;

-- Waiting decisions not yet emailed (best choice per problem only), marked as emailed. Links open the CRM card;
-- approving still needs a signed-in Admin, so a forwarded email cannot approve anything.
CREATE OR REPLACE FUNCTION public.svc_amz_decisions_for_email() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE out jsonb;
BEGIN
  WITH pick AS (
    SELECT q.id FROM public.amazon_change_queue q
     WHERE q.status = 'pending' AND q.emailed_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.amazon_change_queue x WHERE x.alt_group = q.alt_group AND x.status = 'pending'
                         AND coalesce(x.alt_rank, 1) < coalesce(q.alt_rank, 1))
     ORDER BY q.created_at LIMIT 15),
  upd AS (UPDATE public.amazon_change_queue q SET emailed_at = now() FROM pick WHERE q.id = pick.id
          RETURNING q.id, q.summary, q.reason, q.sku, q.created_at)
  SELECT coalesce(jsonb_agg(jsonb_build_object('summary', u.summary, 'why', u.reason, 'product', left(l.title, 70),
           'link', 'https://crm.weoneaviation.in/#/amazon/decisions?open=' || u.id) ORDER BY u.created_at), '[]')
    INTO out FROM upd u LEFT JOIN public.amazon_listings l USING (sku);
  RETURN jsonb_build_object('items', out, 'waiting_total', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'));
END $$;

-- ---------------------------------------------------------------- Claude context: style, margins, festivals
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_context(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'today_ist', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'rules', jsonb_build_object('price_floor', 299, 'title_max_chars', 75, 'bullet_max', 10, 'backend_terms_bytes', 249,
              'note', 'Generic brand (no Brand Registry). Personalised diaries; buyer name on cover via Amazon Custom. Easy Ship FBM.'),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent', l.is_parent, 'title', l.title,
        'price', l.price, 'mrp', l.mrp, 'stock', l.quantity, 'dispatch_days', l.handling_days, 'status', l.status,
        'wins_add_to_cart', l.has_buybox, 'add_to_cart_price', l.buybox_price, 'add_to_cart_seller', l.buybox_seller,
        'photos', jsonb_array_length(coalesce(l.images, '[]')),
        'has_swatch_photo', l.attributes ? 'swatch_product_image_locator',
        'bullets', CASE WHEN p_sku IS NULL OR l.sku = p_sku THEN l.bullets END,
        'description', CASE WHEN l.sku = p_sku THEN left(l.description, 2000) END,
        'backend_terms', CASE WHEN l.sku = p_sku THEN l.backend_terms END,
        'amazon_issues', CASE WHEN l.sku = p_sku THEN l.issues END,
        'details', (SELECT jsonb_object_agg(k, l.attributes->k->0->'value') FROM jsonb_object_keys(coalesce(l.attributes, '{}')) k
                     WHERE k IN ('color', 'size', 'paper_size', 'pages', 'page_count', 'ruling_type', 'style', 'pattern', 'binding', 'theme'))
      ) ORDER BY l.asin) FROM public.amazon_listings l), '[]'),
    'competitors', coalesce((SELECT jsonb_agg(to_jsonb(c) - 'id') FROM (SELECT * FROM public.amazon_competitors LIMIT 20) c), '[]'),
    'keywords', coalesce((SELECT jsonb_agg(keyword) FROM (SELECT keyword FROM public.amazon_keywords WHERE status <> 'rejected' ORDER BY updated_at DESC LIMIT 40) k), '[]'),
    'problems', coalesce((SELECT jsonb_agg(jsonb_build_object('id', f.id, 'sku', f.sku, 'code', f.rule_code, 'message', left(f.message, 300)))
       FROM public.amazon_audit_findings f WHERE f.status = 'open' AND (p_sku IS NULL OR f.sku = p_sku)), '[]'),
    'sales_14d', coalesce((SELECT jsonb_agg(jsonb_build_object('day', s.day, 'units', s.units, 'revenue', s.revenue)) FROM (
       SELECT day, sum(units) units, sum(revenue) revenue FROM public.amazon_sales_daily WHERE day > current_date - 14 GROUP BY day ORDER BY day) s), '[]'),
    'health', (SELECT to_jsonb(h) - 'raw' FROM public.amazon_health_daily h ORDER BY day DESC LIMIT 1),
    'waiting_decisions', (SELECT count(*) FROM public.amazon_change_queue WHERE status = 'pending'),
    'orders_to_ship', (SELECT count(*) FROM public.amazon_orders WHERE status IN ('Unshipped', 'PartiallyShipped')),
    'recent_chat', coalesce((SELECT jsonb_agg(jsonb_build_object('q', left(question, 500), 'a', left(answer, 800)) ORDER BY created_at) FROM (
       SELECT question, answer, created_at FROM public.amazon_claude_requests WHERE kind IN ('chat', 'question') AND status = 'answered'
        ORDER BY created_at DESC LIMIT 6) c), '[]'),
    'rejected_before', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', q.sku, 'summary', q.summary, 'reason', q.reject_reason)) FROM (
       SELECT sku, summary, reject_reason FROM public.amazon_change_queue WHERE status = 'rejected' AND reject_reason IS NOT NULL
          AND reject_reason <> 'Edited before approval' AND (p_sku IS NULL OR sku = p_sku) ORDER BY updated_at DESC LIMIT 15) q), '[]'),
    'owner_style', coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'style_guide'), '{}'),
    'margins', coalesce((SELECT jsonb_agg(m) FROM (SELECT * FROM crm_private.amz_margins()) m), '[]'),
    'festivals_next_60_days', coalesce((SELECT jsonb_agg(jsonb_build_object('name', name, 'day', day, 'note', note) ORDER BY day)
       FROM public.amazon_festivals WHERE day BETWEEN (now() AT TIME ZONE 'Asia/Kolkata')::date AND (now() AT TIME ZONE 'Asia/Kolkata')::date + 60), '[]'))
$$;

-- ---------------------------------------------------------------- grants
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_style(jsonb)', 'public.api_amz_margins()', 'public.api_amz_cost_set(text, numeric, numeric)',
    'public.api_amz_festivals()', 'public.api_amz_festival_prep(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_decisions_for_email()', 'public.svc_amz_bridge_context(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION crm_private.amz_margins() FROM PUBLIC, anon, authenticated;
