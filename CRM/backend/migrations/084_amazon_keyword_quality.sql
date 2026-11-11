-- 084: better keyword ideas from the market watch. The first real run (53 competitors) produced vague single words
-- ("daily", "smooth", "making"). Ideas are now 2-3 word phrases that name the product or gift, used by at least 12% of
-- the competitors above us, and marketing filler words can't start or end a phrase. Run after 083. Re-runnable.

CREATE OR REPLACE FUNCTION crm_private.amz_stopword(w text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT w = ANY (ARRAY['a','an','and','the','of','to','in','on','for','with','by','at','or','your','you','our','from','as','is','it','its',
    'this','that','these','be','are','all','any','per','pack','pcs','pc','piece','pieces','set','x','size','inch','inches','cm','mm','gsm',
    'page','pages','sheet','sheets','ideal','perfect','great','best','new','top','high','quality','premium','free','sale','offer','discount',
    'pack','one','two','three','amazon','india','made','item','product','products','includes','including','also','can','will','use','used',
    -- marketing filler: never the first or last word of a search phrase
    'easy','smooth','making','make','design','designed','professional','durable','beautiful','stylish','elegant','unique','special','classic',
    'luxury','luxurious','strong','sturdy','perfectly','smoothly','everyday','multipurpose','multi','purpose',
    'excellent','amazing','attractive','comfortable','convenient','portable','lightweight','handy','keep','keeps','organized','organised',
    'helps','help','great','good','nice','beautifully','plus','extra','more','each','every','other','etc','like','type','style','features'])
     OR w ~ '^\d+$' AND w !~ '^20\d\d$'
     OR length(w) < 2
$$;

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
     WHERE t.term LIKE '% %'                              -- phrases only: single words are too vague to help ranking
       -- a phrase a buyer types names the product or the gift ("leather diary", "corporate gifting"), not "ink bleeding"
       AND crm_private.amz_words(t.term) && ARRAY['diary','diaries','planner','planners','journal','journals','notebook','notebooks',
             'organiser','organizer','agenda','notepad','gift','gifts','gifting','calendar','logbook','book','books']
       AND t.n >= greatest(2, ceil(comp_total * 0.12))
       AND NOT EXISTS (SELECT 1 FROM brands b WHERE b.w = ANY (crm_private.amz_words(t.term)) AND b.w NOT IN ('diary', 'planner', 'notebook', 'journal'))),
  -- prefer phrases: a single word or short phrase is dropped when a longer picked phrase used as often contains it
  cand AS (SELECT * FROM covered WHERE have < total),
  pick AS (SELECT c.* FROM cand c WHERE NOT EXISTS (
             SELECT 1 FROM cand c2 WHERE length(c2.term) > length(c.term) AND c2.n >= c.n
                AND crm_private.amz_words(c.term) <@ crm_private.amz_words(c2.term))
           ORDER BY n DESC, length(term) DESC LIMIT 20)
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

-- Drop the vague ideas from the first run (only untouched suggestions; anything used or kept stays).
DELETE FROM public.amazon_keywords k
 WHERE k.source = 'competitor' AND k.status = 'candidate'
   AND NOT EXISTS (SELECT 1 FROM public.amazon_keyword_products kp WHERE kp.keyword_id = k.id);

REVOKE ALL ON FUNCTION public.svc_amz_market_save(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_amz_market_save(jsonb, jsonb) TO service_role;
