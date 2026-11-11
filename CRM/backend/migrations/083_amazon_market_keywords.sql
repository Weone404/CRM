-- 083: Market watch (competitors ranked ABOVE us, every morning), Keywords section (suggest, apply to all / selected
-- products, edit, remove, prove the effect), automatic "Request a Review", Amazon.in's 200-byte hidden-search-words limit.
-- Run after 082. Re-runnable.
--
-- How it works
--  * amazon-sync job "market" (cron 06:50 IST) searches Amazon.in's catalogue for every tracked keyword (top 20),
--    then calls svc_amz_market_save: our best rank per keyword, and ONLY the competitors above us (cap 10).
--    If we are #1 it watches the 2 just below us; if we are not in the top 20 it watches the top 10.
--  * Keyword ideas come from words most competitors above us use and we don't, festivals, and Claude (spellings,
--    related words). Applying a keyword writes it into the product's HIDDEN SEARCH WORDS only (never title/key points),
--    as a Decision (one per product, merged), inside 199 bytes.
--  * Every applied keyword keeps the product's rank on the day it was applied; after 14 days it shows Working / No effect.

-- ---------------------------------------------------------------- Amazon.in limit: generic keywords < 200 bytes
UPDATE public.amazon_rules SET value = '{"max": 199}',
  label = 'Hidden search words size in bytes (UTF-8). Amazon.in: under 200 bytes',
  source_url = 'https://sellercentral.amazon.in/seller-forums/discussions/t/c37e5f13-6743-4260-8451-4b67e44a143a'
 WHERE code = 'backend_terms_bytes';

-- ---------------------------------------------------------------- tables / columns
ALTER TABLE public.amazon_keywords DROP CONSTRAINT IF EXISTS amazon_keywords_source_check;
ALTER TABLE public.amazon_keywords ADD CONSTRAINT amazon_keywords_source_check
  CHECK (source IN ('claude', 'user', 'ads', 'catalog', 'competitor', 'festival'));
ALTER TABLE public.amazon_keywords
  ADD COLUMN IF NOT EXISTS track boolean NOT NULL DEFAULT false,          -- searched every morning (rank + competitors)
  ADD COLUMN IF NOT EXISTS apply_future boolean NOT NULL DEFAULT false,   -- also add to products created later
  ADD COLUMN IF NOT EXISTS kind text,                                     -- search / spelling / related / gift / festival
  ADD COLUMN IF NOT EXISTS why text,
  ADD COLUMN IF NOT EXISTS competitor_count int,
  ADD COLUMN IF NOT EXISTS competitors_total int,
  ADD COLUMN IF NOT EXISTS created_by uuid,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS public.amazon_keyword_products (
  keyword_id bigint NOT NULL REFERENCES public.amazon_keywords(id) ON DELETE CASCADE,
  sku text NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'live', 'covered', 'no_room', 'removing', 'removed', 'rejected')),
  change_id uuid,
  detail text,
  baseline_rank int,                 -- this product's rank for the keyword when it was applied (NULL = not in top 20)
  applied_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (keyword_id, sku));
CREATE INDEX IF NOT EXISTS amazon_kp_change ON public.amazon_keyword_products (change_id);

ALTER TABLE public.amazon_competitors
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS keywords text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS above_me boolean,
  ADD COLUMN IF NOT EXISTS best_rank int,
  ADD COLUMN IF NOT EXISTS brand text,
  ADD COLUMN IF NOT EXISTS image text,
  ADD COLUMN IF NOT EXISTS bullets jsonb,
  ADD COLUMN IF NOT EXISTS bsr_group text,
  ADD COLUMN IF NOT EXISTS first_seen date,
  ADD COLUMN IF NOT EXISTS last_seen date;

CREATE TABLE IF NOT EXISTS public.amazon_competitor_daily (
  day date NOT NULL, asin text NOT NULL,
  price numeric(10,2), bsr int, image_count int, best_rank int, title text, buybox_seller text,
  PRIMARY KEY (day, asin));

CREATE TABLE IF NOT EXISTS public.amazon_rank_daily (
  day date NOT NULL,
  keyword_id bigint NOT NULL REFERENCES public.amazon_keywords(id) ON DELETE CASCADE,
  my_best_rank int, my_asin text,
  my_ranks jsonb NOT NULL DEFAULT '{}',   -- {asin: rank} for every product of ours in the top 20
  watched jsonb NOT NULL DEFAULT '[]',    -- [{asin, rank, above}] competitors we track for this keyword
  results int,
  PRIMARY KEY (day, keyword_id));

CREATE TABLE IF NOT EXISTS public.amazon_review_requests (
  order_id text PRIMARY KEY,
  asin text,
  status text NOT NULL CHECK (status IN ('sent', 'not_eligible', 'error')),
  detail text,
  checks int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now());

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_keyword_products', 'amazon_competitor_daily', 'amazon_rank_daily', 'amazon_review_requests'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

INSERT INTO public.amazon_config (key, value) VALUES ('review_requests', '{"enabled": true}') ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_kind_chk;
ALTER TABLE public.amazon_claude_requests DROP CONSTRAINT IF EXISTS amazon_claude_requests_kind_check;
ALTER TABLE public.amazon_claude_requests ADD CONSTRAINT amazon_claude_requests_kind_chk
  CHECK (kind IN ('question', 'suggest', 'chat', 'report', 'fix', 'keywords', 'market'));

-- ---------------------------------------------------------------- text helpers
CREATE OR REPLACE FUNCTION crm_private.amz_norm(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT btrim(regexp_replace(regexp_replace(regexp_replace(lower(coalesce(p, '')), '[''’]', '', 'g'),
                                             '[^[:alnum:][:space:]]+', ' ', 'g'), '\s+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_words(p text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT w), '{}') FROM regexp_split_to_table(crm_private.amz_norm(p), ' ') w WHERE w <> ''
$$;

-- Words that carry no search meaning on their own.
CREATE OR REPLACE FUNCTION crm_private.amz_stopword(w text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT w = ANY (ARRAY['a','an','and','the','of','to','in','on','for','with','by','at','or','your','you','our','from','as','is','it','its',
    'this','that','these','be','are','all','any','per','pack','pcs','pc','piece','pieces','set','x','size','inch','inches','cm','mm','gsm',
    'page','pages','sheet','sheets','ideal','perfect','great','best','new','top','high','quality','premium','free','sale','offer','discount',
    'pack','one','two','three','amazon','india','made','item','product','products','includes','including','also','can','will','use','used'])
     OR w ~ '^\d+$' AND w !~ '^20\d\d$'
     OR length(w) < 2
$$;

-- 1-3 word phrases a shopper could type, from one piece of text.
CREATE OR REPLACE FUNCTION crm_private.amz_terms(p text) RETURNS SETOF text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH w AS (SELECT word, ord FROM regexp_split_to_table(crm_private.amz_norm(p), ' ') WITH ORDINALITY AS t(word, ord) WHERE word <> ''),
  g AS (
    SELECT a.word AS t, a.word AS f, a.word AS l FROM w a
    UNION ALL SELECT a.word || ' ' || b.word, a.word, b.word FROM w a JOIN w b ON b.ord = a.ord + 1
    UNION ALL SELECT a.word || ' ' || b.word || ' ' || c.word, a.word, c.word FROM w a JOIN w b ON b.ord = a.ord + 1 JOIN w c ON c.ord = a.ord + 2)
  SELECT DISTINCT t FROM g WHERE NOT crm_private.amz_stopword(f) AND NOT crm_private.amz_stopword(l) AND length(t) BETWEEN 3 AND 40
$$;

-- All words a listing can be found by (name, key points, description, hidden search words).
CREATE OR REPLACE FUNCTION crm_private.amz_listing_words(l public.amazon_listings) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT crm_private.amz_words(concat_ws(' ', l.title, l.item_highlights,
    (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b),
    l.description, l.backend_terms))
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_backend_max() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT (value->>'max')::int FROM public.amazon_rules WHERE code = 'backend_terms_bytes'), 199)
$$;

-- Adds a keyword's missing words (no filler words) to hidden search words. Returns the new text, the SAME text when every word is
-- already findable (name/key points/hidden words), or NULL when it would pass the byte limit.
CREATE OR REPLACE FUNCTION crm_private.amz_backend_add(p_current text, p_keyword text, p_visible_words text[]) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE cur text := crm_private.amz_norm(p_current); add text[]; nxt text;
BEGIN
  SELECT coalesce(array_agg(w ORDER BY ord), '{}') INTO add FROM (
    SELECT DISTINCT ON (w) w, ord FROM regexp_split_to_table(crm_private.amz_norm(p_keyword), ' ') WITH ORDINALITY t(w, ord)
     WHERE w <> '' ORDER BY w, ord) x
   WHERE NOT (w = ANY (p_visible_words)) AND NOT (w = ANY (crm_private.amz_words(cur)))
     AND NOT crm_private.amz_stopword(w);           -- "for", "with", "the" ... waste bytes (Amazon ignores them)
  IF cardinality(add) = 0 THEN RETURN coalesce(p_current, ''); END IF;
  nxt := btrim(cur || ' ' || array_to_string(add, ' '));
  IF octet_length(nxt) > crm_private.amz_backend_max() THEN RETURN NULL; END IF;
  RETURN nxt;
END $$;

-- Removes a keyword's words from hidden search words, keeping words other live/pending keywords of this product need.
CREATE OR REPLACE FUNCTION crm_private.amz_backend_remove(p_current text, p_keyword_id bigint, p_sku text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH keep AS (
    SELECT DISTINCT unnest(crm_private.amz_words(k.keyword)) w FROM public.amazon_keyword_products kp
      JOIN public.amazon_keywords k ON k.id = kp.keyword_id
     WHERE kp.sku = p_sku AND kp.keyword_id <> p_keyword_id AND kp.status IN ('pending', 'live')),
  gone AS (SELECT unnest(crm_private.amz_words((SELECT keyword FROM public.amazon_keywords WHERE id = p_keyword_id))) w EXCEPT SELECT w FROM keep)
  SELECT coalesce(string_agg(w, ' ' ORDER BY ord), '') FROM regexp_split_to_table(crm_private.amz_norm(p_current), ' ') WITH ORDINALITY t(w, ord)
   WHERE w <> '' AND w NOT IN (SELECT w FROM gone)
$$;

-- ---------------------------------------------------------------- keyword drafts (one pending Decision per product)
CREATE OR REPLACE FUNCTION crm_private.amz_kw_draft(p_sku text, p_backend text, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; nid uuid;
BEGIN
  SELECT * INTO q FROM public.amazon_change_queue
   WHERE sku = p_sku AND status = 'pending' AND created_by_type = 'system' AND reason LIKE 'Keywords:%'
     AND kind = 'listing' AND (after - 'backend_terms') = '{}' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF q.id IS NOT NULL THEN
    UPDATE public.amazon_change_queue SET after = jsonb_build_object('backend_terms', p_backend),
      reason = left(q.reason || '; ' || p_note, 600),
      summary = left('Update hidden search words (' || (length(q.reason) - length(replace(q.reason, ';', '')) + 2) || ' keyword changes)', 300),
      updated_at = now()
     WHERE id = q.id;
    RETURN q.id;
  END IF;
  nid := crm_private.amz_draft_internal('listing', p_sku, jsonb_build_object('backend_terms', p_backend),
          'Update hidden search words', 'Keywords: ' || p_note, 'system', NULL);
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_pending_backend(p_sku text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT after->>'backend_terms' FROM public.amazon_change_queue
     WHERE sku = p_sku AND status = 'pending' AND created_by_type = 'system' AND reason LIKE 'Keywords:%' AND kind = 'listing'
       AND (after - 'backend_terms') = '{}' ORDER BY created_at DESC LIMIT 1),
    (SELECT backend_terms FROM public.amazon_listings WHERE sku = p_sku))
$$;

-- Products a keyword can go to: sellable children (not the parent of a variation family).
CREATE OR REPLACE FUNCTION crm_private.amz_kw_skus() RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT sku FROM public.amazon_listings WHERE NOT is_parent ORDER BY sku
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_kw_apply(p_id bigint, p_skus text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; l public.amazon_listings; cur text; nxt text; vis text[]; cid uuid;
  drafted int := 0; covered int := 0; noroom int := 0; base int;
BEGIN
  SELECT * INTO k FROM public.amazon_keywords WHERE id = p_id;
  IF k.id IS NULL THEN RAISE EXCEPTION 'Keyword not found' USING ERRCODE = 'PT404'; END IF;
  FOR l IN SELECT * FROM public.amazon_listings WHERE sku = ANY (p_skus) AND NOT is_parent LOOP
    cur := crm_private.amz_pending_backend(l.sku);
    vis := crm_private.amz_words(concat_ws(' ', l.title, l.item_highlights,
      (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b), l.description));
    nxt := crm_private.amz_backend_add(cur, k.keyword, vis);
    base := (SELECT (r.my_ranks->>l.asin)::int FROM public.amazon_rank_daily r WHERE r.keyword_id = p_id ORDER BY r.day DESC LIMIT 1);
    IF nxt IS NULL THEN
      INSERT INTO public.amazon_keyword_products AS kp (keyword_id, sku, status, detail, updated_at)
      VALUES (p_id, l.sku, 'no_room', format('No room: hidden search words would pass %s bytes. Remove a weaker keyword first.', crm_private.amz_backend_max()), now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'no_room', detail = EXCLUDED.detail, change_id = NULL, updated_at = now()
       WHERE kp.status NOT IN ('live', 'pending');
      noroom := noroom + 1;
    ELSIF crm_private.amz_norm(nxt) = crm_private.amz_norm(cur) THEN
      INSERT INTO public.amazon_keyword_products AS kp (keyword_id, sku, status, detail, baseline_rank, applied_at, updated_at)
      VALUES (p_id, l.sku, 'covered', 'Already findable: every word is in the name, key points or hidden search words.', base, now(), now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'covered', detail = EXCLUDED.detail, updated_at = now()
       WHERE kp.status NOT IN ('live', 'pending');
      covered := covered + 1;
    ELSE
      cid := crm_private.amz_kw_draft(l.sku, nxt, '+ ' || k.keyword);
      IF cid IS NULL THEN CONTINUE; END IF;
      INSERT INTO public.amazon_keyword_products (keyword_id, sku, status, change_id, detail, baseline_rank, updated_at)
      VALUES (p_id, l.sku, 'pending', cid, 'Waiting in Decisions', base, now())
      ON CONFLICT (keyword_id, sku) DO UPDATE SET status = 'pending', change_id = cid, detail = 'Waiting in Decisions',
        baseline_rank = coalesce(public.amazon_keyword_products.baseline_rank, base), updated_at = now();
      drafted := drafted + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('drafted', drafted, 'covered', covered, 'no_room', noroom);
END $$;

-- A Decision went live / was refused: move its keywords along.
CREATE OR REPLACE FUNCTION crm_private.amz_kw_on_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF NEW.status = 'live' THEN
    UPDATE public.amazon_keyword_products SET status = CASE WHEN status = 'removing' THEN 'removed' ELSE 'live' END,
      applied_at = CASE WHEN status = 'pending' THEN now() ELSE applied_at END,
      detail = CASE WHEN status = 'removing' THEN 'Removed from hidden search words' ELSE 'Live on Amazon' END, updated_at = now()
     WHERE change_id = NEW.id AND status IN ('pending', 'removing');
  ELSIF NEW.status IN ('failed', 'needs_manual', 'stale') THEN
    UPDATE public.amazon_keyword_products SET detail = 'Decision ' || replace(NEW.status, '_', ' ') || ': see Decisions', updated_at = now()
     WHERE change_id = NEW.id AND status IN ('pending', 'removing');
  ELSIF NEW.status IN ('rejected', 'cancelled') THEN
    UPDATE public.amazon_keyword_products SET status = CASE WHEN status = 'removing' THEN 'live' ELSE 'rejected' END,
      detail = CASE WHEN status = 'removing' THEN 'Removal was not applied' ELSE 'Not applied: the Decision was ' || NEW.status END,
      updated_at = now()
     WHERE change_id = NEW.id AND status IN ('pending', 'removing');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_kw_on_change ON public.amazon_change_queue;
CREATE TRIGGER amz_kw_on_change AFTER UPDATE OF status ON public.amazon_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_kw_on_change();

-- ---------------------------------------------------------------- browser API: Keywords section
CREATE OR REPLACE FUNCTION public.api_amz_keywords() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'byte_limit', crm_private.amz_backend_max(),
    'can_apply', crm_private.amz_can_approve(),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent_asin', l.parent_asin, 'title', l.title,
        'image', (SELECT i->>'url' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(l.images) = 'array' THEN l.images ELSE '[]' END) i ORDER BY (i->>'slot' = 'main') DESC LIMIT 1),
        'color', l.attributes->'color'->0->>'value',
        'bytes', octet_length(coalesce(crm_private.amz_pending_backend(l.sku), ''))) ORDER BY l.parent_asin NULLS LAST, l.title)
      FROM public.amazon_listings l WHERE NOT l.is_parent), '[]'),
    'keywords', coalesce((WITH lw AS (SELECT crm_private.amz_listing_words(l) words FROM public.amazon_listings l WHERE NOT l.is_parent)
      SELECT jsonb_agg(x ORDER BY x->>'sort') FROM (
      SELECT jsonb_build_object('id', k.id, 'keyword', k.keyword, 'source', k.source, 'kind', k.kind, 'why', k.why, 'status', k.status,
        'track', k.track, 'apply_future', k.apply_future, 'competitor_count', k.competitor_count, 'competitors_total', k.competitors_total,
        'bytes', octet_length(k.keyword),
        'findable', (SELECT count(*) FROM lw WHERE crm_private.amz_words(k.keyword) <@ lw.words),
        'rank_today', r.my_best_rank, 'rank_week_ago', r7.my_best_rank, 'had_week', r7.day IS NOT NULL, 'checked', r.day,
        'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', kp.sku, 'status', kp.status, 'detail', kp.detail, 'change_id', kp.change_id,
            'baseline_rank', kp.baseline_rank, 'applied_at', kp.applied_at,
            'rank_now', (SELECT (rr.my_ranks->>l2.asin)::int FROM public.amazon_rank_daily rr WHERE rr.keyword_id = k.id ORDER BY rr.day DESC LIMIT 1),
            'effect', CASE WHEN kp.status <> 'live' OR kp.applied_at IS NULL THEN NULL
                           WHEN kp.applied_at > now() - interval '14 days' THEN 'too_early'
                           WHEN coalesce((SELECT (rr.my_ranks->>l2.asin)::int FROM public.amazon_rank_daily rr WHERE rr.keyword_id = k.id ORDER BY rr.day DESC LIMIT 1), 99)
                                < coalesce(kp.baseline_rank, 99) THEN 'working' ELSE 'no_effect' END))
          FROM public.amazon_keyword_products kp JOIN public.amazon_listings l2 ON l2.sku = kp.sku WHERE kp.keyword_id = k.id), '[]'),
        'sort', CASE k.status WHEN 'pinned' THEN '1' WHEN 'candidate' THEN '2' ELSE '3' END || lpad((999 - coalesce(k.competitor_count, 0))::text, 3, '0') || k.keyword)
      FROM public.amazon_keywords k
      LEFT JOIN public.amazon_rank_daily r ON r.keyword_id = k.id AND r.day = (SELECT max(day) FROM public.amazon_rank_daily WHERE keyword_id = k.id)
      LEFT JOIN public.amazon_rank_daily r7 ON r7.keyword_id = k.id AND r7.day = r.day - 7) s(x)), '[]'),
    'claude_running', EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind = 'keywords' AND status IN ('waiting', 'working')),
    'today', today);
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_kw_check(p text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE n text := crm_private.amz_norm(p); bad text;
BEGIN
  IF length(n) < 2 OR length(n) > 60 THEN RAISE EXCEPTION 'A keyword is 2 to 60 letters' USING ERRCODE = 'PT422'; END IF;
  SELECT w INTO bad FROM unnest(ARRAY['best seller','bestseller','#1','free','sale','offer','discount','cheapest','guaranteed','amazon choice']) w
   WHERE (' ' || n || ' ') LIKE ('% ' || w || ' %') LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Amazon does not allow sales words in search words ("%")', bad USING ERRCODE = 'PT422'; END IF;
  SELECT b INTO bad FROM (SELECT DISTINCT crm_private.amz_norm(brand) b FROM public.amazon_competitors WHERE brand IS NOT NULL) c
   WHERE length(b) >= 3 AND b NOT IN ('generic', 'nitaniya') AND (' ' || n || ' ') LIKE ('% ' || b || ' %') LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Competitor brand names are not allowed ("%")', bad USING ERRCODE = 'PT422'; END IF;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keyword_add(p_keyword text, p_track boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n text; r public.amazon_keywords;
BEGIN
  PERFORM crm_private.amz_require_view();
  n := crm_private.amz_kw_check(p_keyword);
  INSERT INTO public.amazon_keywords AS k (keyword, source, status, kind, why, track, created_by)
  VALUES (n, 'user', 'pinned', 'manual', 'Added by you', coalesce(p_track, true), crm_private.current_employee_id())
  ON CONFLICT (lower(keyword)) DO UPDATE SET status = 'pinned', track = k.track OR coalesce(p_track, true), updated_at = now()
  RETURNING * INTO r;
  IF (SELECT count(*) FROM public.amazon_keywords WHERE track) > 15 THEN
    UPDATE public.amazon_keywords SET track = false WHERE id = r.id;
  END IF;
  PERFORM crm_private.amz_log('keyword_added', 'keyword', r.id::text, jsonb_build_object('keyword', n));
  RETURN jsonb_build_object('id', r.id, 'keyword', r.keyword, 'tracked', (SELECT track FROM public.amazon_keywords WHERE id = r.id));
END $$;

-- Keep / hide / watch daily.
CREATE OR REPLACE FUNCTION public.api_amz_keyword_flag(p_id bigint, p_status text DEFAULT NULL, p_track boolean DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_status IS NOT NULL AND p_status NOT IN ('candidate', 'pinned', 'rejected') THEN RAISE EXCEPTION 'Unknown status' USING ERRCODE = 'PT422'; END IF;
  IF p_track AND (SELECT count(*) FROM public.amazon_keywords WHERE track AND id <> p_id) >= 15 THEN
    RAISE EXCEPTION 'Up to 15 keywords can be watched every morning. Stop watching one first.' USING ERRCODE = 'PT422';
  END IF;
  UPDATE public.amazon_keywords SET status = coalesce(p_status, status), track = CASE WHEN p_status = 'rejected' THEN false ELSE coalesce(p_track, track) END,
    updated_at = now() WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keyword_apply(p_id bigint, p_skus text[] DEFAULT NULL, p_future boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; skus text[];
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  PERFORM crm_private.amz_kw_check((SELECT keyword FROM public.amazon_keywords WHERE id = p_id));
  skus := coalesce(p_skus, ARRAY(SELECT crm_private.amz_kw_skus()));
  IF cardinality(skus) = 0 THEN RAISE EXCEPTION 'Choose at least one product' USING ERRCODE = 'PT422'; END IF;
  r := crm_private.amz_kw_apply(p_id, skus);
  UPDATE public.amazon_keywords SET status = 'pinned', apply_future = CASE WHEN p_skus IS NULL THEN coalesce(p_future, false) ELSE apply_future END,
    updated_at = now() WHERE id = p_id;
  PERFORM crm_private.amz_log('keyword_applied', 'keyword', p_id::text, r || jsonb_build_object('products', cardinality(skus)));
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_keyword_remove(p_id bigint, p_skus text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE kp public.amazon_keyword_products; cur text; nxt text; cid uuid; n int := 0; in_name int := 0; vis text[]; l public.amazon_listings;
  kw text := (SELECT keyword FROM public.amazon_keywords WHERE id = p_id);
BEGIN
  PERFORM crm_private.amz_require_view();
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
  FOR kp IN SELECT * FROM public.amazon_keyword_products WHERE keyword_id = p_id AND (p_skus IS NULL OR sku = ANY (p_skus))
              AND status IN ('pending', 'live', 'covered', 'no_room', 'rejected') FOR UPDATE LOOP
    IF kp.status IN ('covered', 'no_room', 'rejected') THEN
      UPDATE public.amazon_keyword_products SET status = 'removed', detail = 'Removed from the list', updated_at = now()
       WHERE keyword_id = p_id AND sku = kp.sku;
      CONTINUE;
    END IF;
    cur := crm_private.amz_pending_backend(kp.sku);
    nxt := crm_private.amz_backend_remove(cur, p_id, kp.sku);
    SELECT * INTO l FROM public.amazon_listings WHERE sku = kp.sku;
    vis := crm_private.amz_words(concat_ws(' ', l.title, (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b)));
    IF crm_private.amz_words(kw) <@ vis THEN in_name := in_name + 1; END IF;
    IF crm_private.amz_norm(nxt) = crm_private.amz_norm(cur) THEN
      UPDATE public.amazon_keyword_products SET status = 'removed', detail = 'Nothing to remove from hidden search words', updated_at = now()
       WHERE keyword_id = p_id AND sku = kp.sku;
      CONTINUE;
    END IF;
    cid := crm_private.amz_kw_draft(kp.sku, nxt, '- ' || kw);
    UPDATE public.amazon_keyword_products SET status = CASE WHEN kp.status = 'pending' AND kp.change_id = cid THEN 'removed' ELSE 'removing' END,
      change_id = cid, detail = CASE WHEN kp.status = 'pending' AND kp.change_id = cid THEN 'Taken out of the waiting Decision' ELSE 'Removal waiting in Decisions' END,
      updated_at = now() WHERE keyword_id = p_id AND sku = kp.sku;
    n := n + 1;
  END LOOP;
  -- A waiting Decision that is now identical to what is live is pointless: cancel it.
  UPDATE public.amazon_change_queue q SET status = 'cancelled', updated_at = now()
   FROM public.amazon_listings li
   WHERE q.sku = li.sku AND q.status = 'pending' AND q.created_by_type = 'system' AND q.reason LIKE 'Keywords:%'
     AND crm_private.amz_norm(q.after->>'backend_terms') = crm_private.amz_norm(li.backend_terms);
  PERFORM crm_private.amz_log('keyword_removed', 'keyword', p_id::text, jsonb_build_object('products', n));
  RETURN jsonb_build_object('changed', n, 'still_in_name', in_name);
END $$;

-- Edit a keyword: products that have it get the new words instead (same waiting Decision per product).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_edit(p_id bigint, p_keyword text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n text; skus text[]; nid bigint; r jsonb := '{}';
BEGIN
  PERFORM crm_private.amz_require_view();
  n := crm_private.amz_kw_check(p_keyword);
  IF n = (SELECT keyword FROM public.amazon_keywords WHERE id = p_id) THEN RETURN jsonb_build_object('id', p_id); END IF;
  skus := ARRAY(SELECT sku FROM public.amazon_keyword_products WHERE keyword_id = p_id AND status IN ('pending', 'live'));
  IF cardinality(skus) > 0 THEN
    IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to change Amazon products' USING ERRCODE = 'PT403'; END IF;
    PERFORM public.api_amz_keyword_remove(p_id, skus);
  END IF;
  SELECT id INTO nid FROM public.amazon_keywords WHERE lower(keyword) = n;
  IF nid IS NULL THEN
    IF cardinality(skus) = 0 THEN
      UPDATE public.amazon_keywords SET keyword = n, source = 'user', updated_at = now() WHERE id = p_id;
      RETURN jsonb_build_object('id', p_id);
    END IF;
    INSERT INTO public.amazon_keywords (keyword, source, status, kind, why, track, apply_future, created_by)
    SELECT n, 'user', 'pinned', 'manual', 'Edited from "' || keyword || '"', track, apply_future, crm_private.current_employee_id()
      FROM public.amazon_keywords WHERE id = p_id RETURNING id INTO nid;
  END IF;
  UPDATE public.amazon_keywords SET status = 'rejected', track = false, apply_future = false, updated_at = now() WHERE id = p_id;
  IF cardinality(skus) > 0 THEN r := crm_private.amz_kw_apply(nid, skus); END IF;
  RETURN r || jsonb_build_object('id', nid);
END $$;

-- Ask Claude for more ideas now (spellings, related words, gift words).
CREATE OR REPLACE FUNCTION public.api_amz_keyword_ideas() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object('id', crm_private.amz_keyword_request(crm_private.current_employee_id()));
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_keyword_request(p_by uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint;
BEGIN
  SELECT id INTO rid FROM public.amazon_claude_requests WHERE kind = 'keywords' AND status IN ('waiting', 'working') LIMIT 1;
  IF rid IS NOT NULL THEN RETURN rid; END IF;
  INSERT INTO public.amazon_claude_requests (question, kind, asked_by)
  VALUES ('Suggest search keywords for my products using the market data.', 'keywords', p_by) RETURNING id INTO rid;
  RETURN rid;
END $$;

-- ---------------------------------------------------------------- browser API: market (competitors above us)
CREATE OR REPLACE FUNCTION public.api_amz_market() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE d date := (SELECT max(day) FROM public.amazon_rank_daily);
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'day', d,
    'last_run', (SELECT jsonb_build_object('at', started_at, 'status', status, 'detail', detail) FROM public.amazon_sync_runs WHERE job = 'market' ORDER BY started_at DESC LIMIT 1),
    'can_run', crm_private.is_admin(),
    'keywords', coalesce((SELECT jsonb_agg(jsonb_build_object('id', k.id, 'keyword', k.keyword, 'my_rank', r.my_best_rank, 'my_asin', r.my_asin,
        'my_rank_before', y.my_best_rank, 'had_before', y.day IS NOT NULL, 'results', r.results,
        'watched', coalesce((SELECT jsonb_agg(jsonb_build_object('asin', w->>'asin', 'rank', (w->>'rank')::int, 'above', (w->>'above')::boolean,
            'rank_before', (SELECT (yw->>'rank')::int FROM jsonb_array_elements(y.watched) yw WHERE yw->>'asin' = w->>'asin'),
            'new', y.day IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(y.watched) yw WHERE yw->>'asin' = w->>'asin'))
            ORDER BY (w->>'rank')::int) FROM jsonb_array_elements(r.watched) w), '[]'))
        ORDER BY r.my_best_rank NULLS LAST, k.keyword)
      FROM public.amazon_keywords k JOIN public.amazon_rank_daily r ON r.keyword_id = k.id AND r.day = d
      LEFT JOIN LATERAL (SELECT * FROM public.amazon_rank_daily y WHERE y.keyword_id = k.id AND y.day < d ORDER BY y.day DESC LIMIT 1) y ON true
      WHERE k.track), '[]'),
    'competitors', coalesce((SELECT jsonb_agg(jsonb_build_object('asin', c.asin, 'title', c.title, 'brand', c.brand, 'image', c.image,
        'price', c.price, 'bsr', c.bsr, 'bsr_group', c.bsr_group, 'images', c.image_count, 'buybox_seller', c.buybox_seller,
        'keywords', c.keywords, 'above_me', c.above_me, 'best_rank', c.best_rank, 'source', c.source, 'first_seen', c.first_seen,
        'title_len', length(c.title),
        'price_before', p.price, 'bsr_before', p.bsr, 'images_before', p.image_count, 'title_changed', p.title IS NOT NULL AND p.title <> c.title)
        ORDER BY cardinality(c.keywords) DESC, c.best_rank NULLS LAST)
      FROM public.amazon_competitors c
      LEFT JOIN LATERAL (SELECT * FROM public.amazon_competitor_daily cd WHERE cd.asin = c.asin AND cd.day < coalesce(d, current_date) ORDER BY cd.day DESC LIMIT 1) p ON true
      WHERE c.active), '[]'),
    'mine', (SELECT jsonb_build_object('photos_avg', round(avg(jsonb_array_length(coalesce(images, '[]'))), 1), 'price_min', min(price), 'price_max', max(price))
      FROM public.amazon_listings WHERE NOT is_parent),
    'report', (SELECT jsonb_build_object('id', id, 'status', status, 'answer', answer, 'at', coalesce(answered_at, created_at), 'drafts', jsonb_array_length(coalesce(draft_ids, '[]')))
      FROM public.amazon_claude_requests WHERE kind = 'market' ORDER BY created_at DESC LIMIT 1));
END $$;

-- ---------------------------------------------------------------- service API for the morning job
CREATE OR REPLACE FUNCTION public.svc_amz_market_targets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'keywords', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'keyword', keyword) ORDER BY id) FROM (
        SELECT id, keyword FROM public.amazon_keywords WHERE track AND status <> 'rejected' ORDER BY id LIMIT 15) k), '[]'),
    'my_titles', coalesce((SELECT jsonb_agg(title) FROM public.amazon_listings WHERE NOT is_parent AND title IS NOT NULL), '[]'),
    'manual_asins', coalesce((SELECT jsonb_agg(asin) FROM public.amazon_competitors WHERE active AND source = 'manual'), '[]'))
$$;

-- First run with nothing tracked: start from the phrases our own product names use most.
CREATE OR REPLACE FUNCTION public.svc_amz_keyword_seed(p_phrases text[]) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p text; n int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.amazon_keywords WHERE track) THEN RETURN 0; END IF;
  FOREACH p IN ARRAY coalesce(p_phrases, '{}') LOOP
    EXIT WHEN n >= 8;
    p := crm_private.amz_norm(p);
    CONTINUE WHEN length(p) < 3;
    INSERT INTO public.amazon_keywords AS k (keyword, source, status, kind, why, track)
    VALUES (p, 'catalog', 'pinned', 'search', 'From your own product names (most used phrase)', true)
    ON CONFLICT (lower(keyword)) DO UPDATE SET track = true, status = CASE WHEN k.status = 'rejected' THEN k.status ELSE 'pinned' END;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- p_results: [{keyword_id, items:[{asin, rank, title, brand, bsr, bsr_group, image, images, bullets}]}]
-- p_prices:  [{asin, buybox_price, buybox_seller}]
CREATE OR REPLACE FUNCTION public.svc_amz_market_save(p_results jsonb, p_prices jsonb DEFAULT '[]') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; res jsonb; mine text[]; best int; my_asin text; watched jsonb;
  kid bigint; kw_count int := 0; comp_total int; ideas int := 0;
BEGIN
  mine := ARRAY(SELECT asin FROM public.amazon_listings WHERE asin IS NOT NULL UNION SELECT parent_asin FROM public.amazon_listings WHERE parent_asin IS NOT NULL);
  CREATE TEMP TABLE IF NOT EXISTS _amz_seen (asin text, rank int, above boolean, keyword text, title text, brand text, bsr int, bsr_group text,
    image text, images int, bullets jsonb) ON COMMIT DROP;
  TRUNCATE _amz_seen;
  FOR res IN SELECT * FROM jsonb_array_elements(coalesce(p_results, '[]')) LOOP
    kid := (res->>'keyword_id')::bigint;
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM public.amazon_keywords WHERE id = kid);
    SELECT min((i->>'rank')::int), (array_agg(i->>'asin' ORDER BY (i->>'rank')::int))[1] INTO best, my_asin
      FROM jsonb_array_elements(res->'items') i WHERE i->>'asin' = ANY (mine);
    -- who we watch: everyone above us (max 10); at #1 the 2 just below; not in the top 20 -> the top 10
    SELECT coalesce(jsonb_agg(jsonb_build_object('asin', i->>'asin', 'rank', (i->>'rank')::int, 'above', best IS NULL OR (i->>'rank')::int < best)
             ORDER BY (i->>'rank')::int), '[]') INTO watched
      FROM (SELECT i FROM jsonb_array_elements(res->'items') i
             WHERE NOT (i->>'asin' = ANY (mine))
               AND (best IS NULL OR (best > 1 AND (i->>'rank')::int < best) OR (best = 1 AND (i->>'rank')::int > 1))
             ORDER BY (i->>'rank')::int LIMIT CASE WHEN best = 1 THEN 2 ELSE 10 END) x(i);
    INSERT INTO public.amazon_rank_daily (day, keyword_id, my_best_rank, my_asin, my_ranks, watched, results)
    VALUES (today, kid, best, my_asin,
      coalesce((SELECT jsonb_object_agg(i->>'asin', (i->>'rank')::int) FROM jsonb_array_elements(res->'items') i WHERE i->>'asin' = ANY (mine)), '{}'),
      watched, jsonb_array_length(coalesce(res->'items', '[]')))
    ON CONFLICT (day, keyword_id) DO UPDATE SET my_best_rank = EXCLUDED.my_best_rank, my_asin = EXCLUDED.my_asin, my_ranks = EXCLUDED.my_ranks,
      watched = EXCLUDED.watched, results = EXCLUDED.results;
    INSERT INTO _amz_seen
    SELECT i->>'asin', (i->>'rank')::int, (w->>'above')::boolean, (SELECT keyword FROM public.amazon_keywords WHERE id = kid),
           left(i->>'title', 500), left(i->>'brand', 100), (i->>'bsr')::int, left(i->>'bsr_group', 100), i->>'image',
           (i->>'images')::int, CASE WHEN jsonb_typeof(i->'bullets') = 'array' THEN i->'bullets' END
      FROM jsonb_array_elements(res->'items') i JOIN jsonb_array_elements(watched) w ON w->>'asin' = i->>'asin';
    kw_count := kw_count + 1;
  END LOOP;
  IF kw_count = 0 THEN RETURN jsonb_build_object('keywords', 0); END IF;

  -- competitors: auto ones not watched today stop showing; manual ones stay
  INSERT INTO public.amazon_competitors AS c (asin, title, brand, bsr, bsr_group, image, image_count, bullets, keywords, above_me, best_rank,
                                             source, active, first_seen, last_seen, updated_at)
  SELECT asin, (array_agg(title))[1], (array_agg(brand))[1], (array_agg(bsr))[1], (array_agg(bsr_group))[1], (array_agg(image))[1],
         (array_agg(images))[1], (array_agg(bullets))[1], array_agg(DISTINCT keyword), bool_or(above), min(rank), 'auto', true, today, today, now()
    FROM _amz_seen GROUP BY asin
  ON CONFLICT (asin) DO UPDATE SET title = coalesce(EXCLUDED.title, c.title), brand = coalesce(EXCLUDED.brand, c.brand),
    bsr = coalesce(EXCLUDED.bsr, c.bsr), bsr_group = coalesce(EXCLUDED.bsr_group, c.bsr_group), image = coalesce(EXCLUDED.image, c.image),
    image_count = coalesce(EXCLUDED.image_count, c.image_count), bullets = coalesce(EXCLUDED.bullets, c.bullets),
    keywords = EXCLUDED.keywords, above_me = EXCLUDED.above_me, best_rank = EXCLUDED.best_rank, active = true,
    first_seen = coalesce(c.first_seen, today), last_seen = today, updated_at = now();
  UPDATE public.amazon_competitors SET active = false, keywords = '{}', above_me = NULL
   WHERE source = 'auto' AND active AND coalesce(last_seen, today - 1) < today;
  UPDATE public.amazon_competitors c SET price = coalesce((p->>'buybox_price')::numeric, c.price), buybox_seller = coalesce(p->>'buybox_seller', c.buybox_seller)
    FROM jsonb_array_elements(coalesce(p_prices, '[]')) p WHERE c.asin = p->>'asin';
  INSERT INTO public.amazon_competitor_daily (day, asin, price, bsr, image_count, best_rank, title, buybox_seller)
  SELECT today, asin, price, bsr, image_count, best_rank, title, buybox_seller FROM public.amazon_competitors WHERE active
  ON CONFLICT (day, asin) DO UPDATE SET price = EXCLUDED.price, bsr = EXCLUDED.bsr, image_count = EXCLUDED.image_count,
    best_rank = EXCLUDED.best_rank, title = EXCLUDED.title, buybox_seller = EXCLUDED.buybox_seller;

  -- keyword ideas: phrases most competitors above us use, that our products can't be found by yet
  comp_total := (SELECT count(*) FROM public.amazon_competitors WHERE active AND source = 'auto');
  WITH ctext AS (
    SELECT asin, concat_ws(' ', title, (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(coalesce(bullets, '[]')) b)) t
      FROM public.amazon_competitors WHERE active AND source = 'auto'),
  brands AS (SELECT DISTINCT unnest(crm_private.amz_words(brand)) w FROM public.amazon_competitors WHERE brand IS NOT NULL),
  terms AS (SELECT term, count(DISTINCT asin) n FROM ctext, crm_private.amz_terms(t) term GROUP BY term),
  minewords AS (SELECT coalesce(array_agg(DISTINCT w), '{}') ws FROM public.amazon_listings l, unnest(crm_private.amz_listing_words(l)) w WHERE NOT l.is_parent),
  covered AS (
    SELECT t.term, t.n,
      (SELECT count(*) FROM public.amazon_listings l WHERE NOT l.is_parent AND crm_private.amz_words(t.term) <@ crm_private.amz_listing_words(l)) have,
      (SELECT count(*) FROM public.amazon_listings WHERE NOT is_parent) total
      FROM terms t
     WHERE t.n >= greatest(2, ceil(comp_total * 0.4))
       AND NOT EXISTS (SELECT 1 FROM brands b WHERE b.w = ANY (crm_private.amz_words(t.term)) AND b.w NOT IN ('diary', 'planner', 'notebook', 'journal'))),
  -- prefer phrases: a single word or short phrase is dropped when a longer picked phrase used as often contains it
  cand AS (SELECT * FROM covered WHERE have < total),
  pick AS (SELECT c.* FROM cand c WHERE NOT EXISTS (
             SELECT 1 FROM cand c2 WHERE length(c2.term) > length(c.term) AND c2.n >= c.n
                AND crm_private.amz_words(c.term) <@ crm_private.amz_words(c2.term))
           ORDER BY n DESC, length(term) DESC LIMIT 25)
  INSERT INTO public.amazon_keywords AS k (keyword, source, status, kind, why, competitor_count, competitors_total)
  SELECT term, 'competitor', 'candidate', 'search',
         format('Used by %s of %s competitors above you; %s of %s of your products can''t be found by it yet', n, comp_total, total - have, total),
         n, comp_total FROM pick
  ON CONFLICT (lower(keyword)) DO UPDATE SET competitor_count = EXCLUDED.competitor_count, competitors_total = EXCLUDED.competitors_total,
    why = CASE WHEN k.source = 'competitor' THEN EXCLUDED.why ELSE k.why END, updated_at = now();
  GET DIAGNOSTICS ideas = ROW_COUNT;
  -- refresh "used by" for every other keyword too
  UPDATE public.amazon_keywords k SET competitor_count = (SELECT count(*) FROM public.amazon_competitors c WHERE c.active AND c.source = 'auto'
      AND crm_private.amz_words(k.keyword) <@ crm_private.amz_words(concat_ws(' ', c.title, (SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(coalesce(c.bullets, '[]')) b)))),
    competitors_total = comp_total
   WHERE k.status <> 'rejected';

  -- festival words: 45 days before each festival
  INSERT INTO public.amazon_keywords AS k (keyword, source, status, kind, why)
  SELECT crm_private.amz_norm(f.name || ' gift diary'), 'festival', 'candidate', 'festival',
         format('%s is on %s: add before, remove after', f.name, to_char(f.day, 'DD Mon'))
    FROM public.amazon_festivals f WHERE f.day BETWEEN today AND today + 45
  ON CONFLICT (lower(keyword)) DO NOTHING;

  RETURN jsonb_build_object('keywords', kw_count, 'competitors', (SELECT count(*) FROM public.amazon_competitors WHERE active AND source = 'auto'), 'ideas', ideas);
END $$;

-- Competitors watched today (their prices are fetched right after the search) and today's snapshot refresh.
CREATE OR REPLACE FUNCTION public.svc_amz_market_watched() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(asin ORDER BY cardinality(keywords) DESC, best_rank NULLS LAST), '{}') FROM (
    SELECT asin, keywords, best_rank FROM public.amazon_competitors WHERE active ORDER BY cardinality(keywords) DESC, best_rank NULLS LAST LIMIT 40) c
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_market_daily_refresh() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.amazon_competitor_daily d SET price = c.price, buybox_seller = c.buybox_seller
    FROM public.amazon_competitors c WHERE d.asin = c.asin AND d.day = (now() AT TIME ZONE 'Asia/Kolkata')::date
$$;

-- "Apply to future products": new products get those keywords as a Decision.
CREATE OR REPLACE FUNCTION public.svc_amz_keyword_autoapply() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k public.amazon_keywords; skus text[]; n int := 0;
BEGIN
  FOR k IN SELECT * FROM public.amazon_keywords WHERE apply_future AND status <> 'rejected' LOOP
    skus := ARRAY(SELECT s FROM crm_private.amz_kw_skus() s WHERE NOT EXISTS (
              SELECT 1 FROM public.amazon_keyword_products kp WHERE kp.keyword_id = k.id AND kp.sku = s));
    IF cardinality(skus) > 0 THEN PERFORM crm_private.amz_kw_apply(k.id, skus); n := n + cardinality(skus); END IF;
  END LOOP;
  RETURN n;
END $$;

-- After the morning search: Claude's morning report (every day) and fresh keyword ideas (weekly).
CREATE OR REPLACE FUNCTION public.svc_amz_market_requests() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; rep bigint; kw bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind = 'market' AND (created_at AT TIME ZONE 'Asia/Kolkata')::date = today) THEN
    INSERT INTO public.amazon_claude_requests (question, kind)
    VALUES ('Morning market report: what changed with the competitors above me, and what should I do today?', 'market') RETURNING id INTO rep;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.amazon_claude_requests WHERE kind = 'keywords' AND created_at > now() - interval '6 days') THEN
    kw := crm_private.amz_keyword_request(NULL);
  END IF;
  RETURN jsonb_build_object('report', rep, 'keywords', kw);
END $$;

-- ---------------------------------------------------------------- Request a Review (Amazon's own button, automated)
CREATE OR REPLACE FUNCTION public.svc_amz_review_candidates() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN coalesce((SELECT (value::jsonb->>'enabled')::boolean FROM public.amazon_config WHERE key = 'review_requests'), true)
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', o.order_id, 'asin', o.items->0->>'asin')) FROM (
      SELECT o.* FROM public.amazon_orders o
       LEFT JOIN public.amazon_review_requests r ON r.order_id = o.order_id
       WHERE o.status = 'Shipped' AND o.purchase_date BETWEEN now() - interval '35 days' AND now() - interval '5 days'
         AND (r.order_id IS NULL OR (r.status IN ('not_eligible', 'error') AND r.updated_at < now() - interval '2 days' AND r.checks < 8))
       ORDER BY o.purchase_date LIMIT 40) o), '[]')
    ELSE '[]'::jsonb END
$$;

CREATE OR REPLACE FUNCTION public.svc_amz_review_result(p_order text, p_asin text, p_status text, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_review_requests AS r (order_id, asin, status, detail)
  VALUES (p_order, p_asin, p_status, left(p_detail, 300))
  ON CONFLICT (order_id) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail, checks = r.checks + 1, updated_at = now()
   WHERE r.status <> 'sent'
$$;

CREATE OR REPLACE FUNCTION public.api_amz_reviews(p_enabled boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_enabled IS NOT NULL THEN
    PERFORM crm_private.amz_require_admin();
    INSERT INTO public.amazon_config (key, value) VALUES ('review_requests', jsonb_build_object('enabled', p_enabled)::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.amz_log('review_requests', 'settings', NULL, jsonb_build_object('enabled', p_enabled));
  END IF;
  RETURN jsonb_build_object(
    'enabled', coalesce((SELECT (value::jsonb->>'enabled')::boolean FROM public.amazon_config WHERE key = 'review_requests'), true),
    'sent_30d', (SELECT count(*) FROM public.amazon_review_requests WHERE status = 'sent' AND updated_at > now() - interval '30 days'),
    'sent_total', (SELECT count(*) FROM public.amazon_review_requests WHERE status = 'sent'),
    'waiting', (SELECT count(*) FROM public.amazon_review_requests WHERE status = 'not_eligible'),
    'last_error', (SELECT detail FROM public.amazon_review_requests WHERE status = 'error' AND updated_at > now() - interval '3 days' ORDER BY updated_at DESC LIMIT 1),
    'last_run', (SELECT jsonb_build_object('at', started_at, 'status', status, 'detail', detail) FROM public.amazon_sync_runs WHERE job = 'reviews' ORDER BY started_at DESC LIMIT 1));
END $$;

-- ---------------------------------------------------------------- Claude: keyword ideas arrive as options
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_answer(p_id bigint, p_answer text, p_options jsonb DEFAULT NULL,
  p_drafts jsonb DEFAULT NULL, p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests; d jsonb; did uuid; ids jsonb := '[]'; n int := 0; grp text; o jsonb; kw text; added int := 0;
BEGIN
  SELECT * INTO r FROM public.amazon_claude_requests WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR r.status NOT IN ('waiting', 'working') THEN RETURN jsonb_build_object('saved', false); END IF;
  IF jsonb_typeof(p_drafts) = 'array' AND r.kind <> 'keywords' THEN
    FOR d IN SELECT * FROM jsonb_array_elements(p_drafts) LIMIT 30 LOOP
      grp := CASE WHEN coalesce(d->>'group', '') <> '' THEN p_id || ':' || left(d->>'group', 60) END;
      did := crm_private.amz_draft_internal(d->>'kind', d->>'sku', d->'after', d->>'summary', d->>'reason', 'claude', p_id,
               grp, CASE WHEN (d->>'rank') ~ '^\d$' THEN (d->>'rank')::int END, d->>'rank_reason',
               CASE WHEN (d->>'finding_id') ~ '^\d{1,12}$' THEN (d->>'finding_id')::bigint END);
      IF did IS NOT NULL THEN ids := ids || to_jsonb(did::text); n := n + 1; END IF;
    END LOOP;
  END IF;
  IF r.kind = 'keywords' AND jsonb_typeof(p_options) = 'array' THEN
    FOR o IN SELECT * FROM jsonb_array_elements(p_options) LIMIT 40 LOOP
      BEGIN
        kw := crm_private.amz_kw_check(CASE WHEN jsonb_typeof(o) = 'string' THEN o #>> '{}' ELSE o->>'keyword' END);
        INSERT INTO public.amazon_keywords (keyword, source, status, kind, why)
        VALUES (kw, 'claude', 'candidate',
                CASE WHEN o->>'type' IN ('search', 'spelling', 'related', 'gift', 'festival') THEN o->>'type' ELSE 'related' END,
                left(coalesce(o->>'why', 'Suggested by Claude'), 300))
        ON CONFLICT (lower(keyword)) DO NOTHING;
        IF FOUND THEN added := added + 1; END IF;
      EXCEPTION WHEN others THEN NULL;   -- sales words, brands, too long: skipped
      END;
    END LOOP;
  END IF;
  UPDATE public.amazon_claude_requests SET
    answer = left(coalesce(nullif(trim(p_answer), ''), CASE WHEN r.kind = 'suggest' THEN 'Suggestions ready'
                                                            WHEN r.kind = 'keywords' THEN added || ' new keyword ideas' ELSE 'Done.' END), 8000),
    options = CASE WHEN r.kind = 'suggest' AND jsonb_typeof(p_options) = 'array' AND jsonb_array_length(p_options) BETWEEN 1 AND 5 THEN p_options ELSE options END,
    status = 'answered', answered_at = now(), answered_by = p_by, note = NULL, draft_ids = ids
   WHERE id = p_id;
  RETURN jsonb_build_object('saved', true, 'drafts', n, 'keywords', added);
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_bridge_claim(p_by text DEFAULT 'mac') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.amazon_claude_requests;
BEGIN
  UPDATE public.amazon_claude_requests SET status = 'waiting', note = 'Retrying after a pause.'
   WHERE status = 'working' AND claimed_at < now() - interval '10 minutes';
  SELECT * INTO r FROM public.amazon_claude_requests
   WHERE status = 'waiting' AND kind IN ('chat', 'question', 'suggest', 'fix', 'market', 'keywords')
     AND (note IS NULL OR note NOT LIKE 'Claude limit%' OR claimed_at IS NULL OR claimed_at < now() - interval '10 minutes')
   ORDER BY (kind = 'chat') DESC, (kind = 'suggest') DESC, (kind IN ('market', 'keywords')) ASC, created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.amazon_claude_requests SET status = 'working', claimed_at = now(), attempts = attempts + 1, answered_by = p_by
   WHERE id = r.id RETURNING * INTO r;
  RETURN jsonb_build_object('job', to_jsonb(r), 'context', public.svc_amz_bridge_context(r.sku));
END $$;

-- Context gains the market (our rank per keyword, competitors above us) and the real byte limit.
CREATE OR REPLACE FUNCTION public.svc_amz_bridge_context(p_sku text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'today_ist', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'rules', jsonb_build_object('price_floor', 299, 'title_max_chars', 75, 'bullet_max', 10, 'backend_terms_bytes', crm_private.amz_backend_max(),
              'note', 'Generic brand (no Brand Registry). Personalised diaries; buyer name on cover via Amazon Custom. Easy Ship FBM. Amazon.in hidden search words must stay under 200 bytes.'),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('sku', l.sku, 'asin', l.asin, 'parent', l.is_parent, 'title', l.title,
        'price', l.price, 'mrp', l.mrp, 'stock', l.quantity, 'dispatch_days', l.handling_days, 'status', l.status,
        'wins_add_to_cart', l.has_buybox, 'add_to_cart_price', l.buybox_price, 'add_to_cart_seller', l.buybox_seller,
        'photos', jsonb_array_length(coalesce(l.images, '[]')),
        'has_swatch_photo', l.attributes ? 'swatch_product_image_locator',
        'bullets', CASE WHEN p_sku IS NULL OR l.sku = p_sku THEN l.bullets END,
        'description', CASE WHEN l.sku = p_sku THEN left(l.description, 2000) END,
        'backend_terms', CASE WHEN p_sku IS NULL OR l.sku = p_sku THEN l.backend_terms END,
        'amazon_issues', CASE WHEN l.sku = p_sku THEN l.issues END,
        'details', (SELECT jsonb_object_agg(k, l.attributes->k->0->'value') FROM jsonb_object_keys(coalesce(l.attributes, '{}')) k
                     WHERE k IN ('color', 'size', 'paper_size', 'pages', 'page_count', 'ruling_type', 'style', 'pattern', 'binding', 'theme'))
      ) ORDER BY l.asin) FROM public.amazon_listings l), '[]'),
    'market', jsonb_build_object(
      'my_rank_by_keyword', coalesce((SELECT jsonb_agg(jsonb_build_object('keyword', k.keyword, 'rank_today', r.my_best_rank,
          'rank_before', (SELECT y.my_best_rank FROM public.amazon_rank_daily y WHERE y.keyword_id = k.id AND y.day < r.day ORDER BY y.day DESC LIMIT 1),
          'watched', r.watched))
        FROM public.amazon_keywords k JOIN public.amazon_rank_daily r ON r.keyword_id = k.id
         AND r.day = (SELECT max(day) FROM public.amazon_rank_daily) WHERE k.track), '[]'),
      'competitors', coalesce((SELECT jsonb_agg(jsonb_build_object('asin', c.asin, 'title', c.title, 'brand', c.brand, 'price', c.price,
          'price_before', p.price, 'bsr', c.bsr, 'bsr_before', p.bsr, 'photos', c.image_count, 'above_me', c.above_me, 'keywords', c.keywords,
          'bullets', c.bullets, 'first_seen', c.first_seen))
        FROM (SELECT * FROM public.amazon_competitors WHERE active ORDER BY cardinality(keywords) DESC, best_rank NULLS LAST LIMIT 15) c
        LEFT JOIN LATERAL (SELECT * FROM public.amazon_competitor_daily cd WHERE cd.asin = c.asin AND cd.day < (now() AT TIME ZONE 'Asia/Kolkata')::date
                           ORDER BY cd.day DESC LIMIT 1) p ON true), '[]')),
    'keywords', coalesce((SELECT jsonb_agg(jsonb_build_object('keyword', keyword, 'status', status, 'used_by_competitors', competitor_count,
        'applied_to', (SELECT count(*) FROM public.amazon_keyword_products kp WHERE kp.keyword_id = k.id AND kp.status IN ('live', 'pending'))))
      FROM (SELECT * FROM public.amazon_keywords WHERE status <> 'rejected' ORDER BY updated_at DESC LIMIT 60) k), '[]'),
    'rejected_keywords', coalesce((SELECT jsonb_agg(keyword) FROM (SELECT keyword FROM public.amazon_keywords WHERE status = 'rejected' ORDER BY updated_at DESC LIMIT 40) k), '[]'),
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
  FOREACH f IN ARRAY ARRAY['public.api_amz_keywords()', 'public.api_amz_keyword_add(text, boolean)', 'public.api_amz_keyword_flag(bigint, text, boolean)',
    'public.api_amz_keyword_apply(bigint, text[], boolean)', 'public.api_amz_keyword_remove(bigint, text[])', 'public.api_amz_keyword_edit(bigint, text)',
    'public.api_amz_keyword_ideas()', 'public.api_amz_market()', 'public.api_amz_reviews(boolean)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_market_targets()', 'public.svc_amz_keyword_seed(text[])', 'public.svc_amz_market_save(jsonb, jsonb)',
    'public.svc_amz_keyword_autoapply()', 'public.svc_amz_market_requests()', 'public.svc_amz_review_candidates()',
    'public.svc_amz_review_result(text, text, text, text)', 'public.svc_amz_bridge_answer(bigint, text, jsonb, jsonb, text)',
    'public.svc_amz_market_watched()', 'public.svc_amz_market_daily_refresh()',
    'public.svc_amz_bridge_claim(text)', 'public.svc_amz_bridge_context(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['crm_private.amz_backend_max()', 'crm_private.amz_backend_remove(text, bigint, text)', 'crm_private.amz_kw_draft(text, text, text)',
    'crm_private.amz_pending_backend(text)', 'crm_private.amz_kw_skus()', 'crm_private.amz_kw_apply(bigint, text[])', 'crm_private.amz_kw_on_change()',
    'crm_private.amz_kw_check(text)', 'crm_private.amz_keyword_request(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- cron: market 06:50 IST (01:20 UTC), reviews 11:40 IST
DO $outer$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN RETURN; END IF;
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-amazon-market', 'crm-amazon-reviews');
  PERFORM cron.schedule('crm-amazon-market', '20 1 * * *', $job$
    SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := '{"jobs": ["market"]}'::jsonb, timeout_milliseconds := 150000)
  $job$);
  -- Request a Review: every day at 11:40 IST (06:10 UTC), separate run so it never eats the market watch's time
  PERFORM cron.schedule('crm-amazon-reviews', '10 6 * * *', $job$
    SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-sync',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := '{"jobs": ["reviews"]}'::jsonb, timeout_milliseconds := 150000)
  $job$);
END $outer$;
