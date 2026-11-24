-- 132: trustworthy product checks + one choice per product and field
--  1. Checks that were missing: size conflict (name vs details vs bullets), old year left in the text,
--     two product codes on one Amazon listing. Re-run for a product whenever its listing changes.
--  2. False alarms close by themselves: "name changed outside the CRM" when the name is one we approved,
--     "hidden after a change" when the listing is selling again (its waiting undo is closed too).
--  3. Product page: api_amz_product_todo(sku) = open problems, fixes waiting, changes waiting.
--  4. Decisions: one waiting choice per product and field (one-time tidy), and a newer keyword/growth
--     suggestion replaces the older one instead of piling up.
-- Re-runnable. Nothing here sends anything to Amazon.

-- ---------------------------------------------------------------- checks for one product
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint WHERE conrelid = 'public.amazon_audit_findings'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%source%';
  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE public.amazon_audit_findings DROP CONSTRAINT %I', c); END IF;
  ALTER TABLE public.amazon_audit_findings ADD CONSTRAINT amazon_audit_findings_source_check
    CHECK (source IN ('audit', 'seed', 'claude', 'sync', 'check'));
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_sizes(p_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT upper(m[1]) ORDER BY upper(m[1])), '{}')
    FROM regexp_matches(coalesce(p_text, ''), '\m(A4|A5|A6|B5|B6)\M', 'gi') m
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_check_listing(p_sku text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; n int := 0; t_sz text[]; d_sz text[]; b_sz text[]; body text; parts text[] := '{}';
  yr text; old_yr text; twin text; ok boolean;
BEGIN
  SELECT * INTO l FROM public.amazon_listings WHERE sku = p_sku;
  IF l.sku IS NULL THEN RETURN 0; END IF;
  CREATE TEMP TABLE IF NOT EXISTS amz_chk (rule_code text, severity text, message text) ON COMMIT DROP;
  DELETE FROM amz_chk;
  IF NOT l.is_parent THEN
    body := coalesce((SELECT string_agg(b, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(l.bullets) = 'array' THEN l.bullets ELSE '[]' END) b), '')
            || ' ' || coalesce(l.description, '');
    -- size: the name, the "paper size" detail and the bullets/description must agree
    t_sz := crm_private.amz_sizes(l.title);
    d_sz := crm_private.amz_sizes(l.attributes #>> '{paper_size,0,value}');
    b_sz := crm_private.amz_sizes(body);
    IF cardinality(t_sz) > 0 THEN parts := parts || ('name says ' || array_to_string(t_sz, '/')); END IF;
    IF cardinality(d_sz) > 0 THEN parts := parts || ('details say ' || array_to_string(d_sz, '/')); END IF;
    IF cardinality(b_sz) > 0 THEN parts := parts || ('bullets or description say ' || array_to_string(b_sz, '/')); END IF;
    IF (SELECT count(DISTINCT s) FROM unnest(t_sz || d_sz || b_sz) s) > 1 THEN
      INSERT INTO amz_chk VALUES ('size_conflict', 'blocker', 'Size does not match: ' || array_to_string(parts, ', ') || '.');
    END IF;
    -- year: a 2027 product whose bullets or description still mention an older year
    yr := substring(l.title from '\m(20[2-9][0-9])\M');
    IF yr IS NOT NULL THEN
      SELECT m[1] INTO old_yr FROM regexp_matches(body, '\m(20[2-9][0-9])\M', 'g') m WHERE m[1]::int < yr::int ORDER BY m[1] LIMIT 1;
      IF old_yr IS NOT NULL THEN
        INSERT INTO amz_chk VALUES ('old_year_text', 'warning',
          format('The name says %s but the bullets or description still mention %s: "%s"', yr, old_yr,
                 btrim(substring(body from '.{0,40}\m' || old_yr || '\M.{0,40}'))));
      END IF;
    END IF;
    -- two product codes on one Amazon listing
    SELECT string_agg(o.sku, ', ' ORDER BY o.sku) INTO twin FROM public.amazon_listings o
     WHERE o.asin = l.asin AND o.sku <> l.sku AND NOT o.is_parent AND l.asin IS NOT NULL;
    IF twin IS NOT NULL THEN
      INSERT INTO amz_chk VALUES ('duplicate_listing', 'warning',
        format('This product code and %s point to the same Amazon listing (%s). Amazon does not allow duplicate offers of the same product.', twin, l.asin));
    END IF;
  END IF;
  INSERT INTO public.amazon_audit_findings (sku, asin, rule_code, severity, message, source)
  SELECT l.sku, l.asin, c.rule_code, c.severity, left(c.message, 500), 'check' FROM amz_chk c
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  -- keep the wording current, close what no longer fails
  UPDATE public.amazon_audit_findings f SET message = left(c.message, 500)
    FROM amz_chk c WHERE f.sku = l.sku AND f.status = 'open' AND f.source = 'check' AND f.rule_code = c.rule_code AND f.message IS DISTINCT FROM left(c.message, 500);
  UPDATE public.amazon_audit_findings f SET status = 'fixed', resolved_at = now()
   WHERE f.sku = l.sku AND f.status = 'open' AND f.source = 'check'
     AND NOT EXISTS (SELECT 1 FROM amz_chk c WHERE c.rule_code = f.rule_code);
  -- false alarm: "name changed outside the CRM" while the name on Amazon is one we approved
  UPDATE public.amazon_audit_findings f SET status = 'fixed', resolved_at = now()
   WHERE f.sku = l.sku AND f.status = 'open' AND f.rule_code = 'title_drift'
     AND (l.title IS NOT DISTINCT FROM l.last_approved_title
          OR EXISTS (SELECT 1 FROM public.amazon_change_queue q WHERE q.sku = l.sku AND q.status = 'live' AND q.after->>'title' = l.title));
  -- stale: "hidden after a change" while the listing is selling again; its waiting undo would revert a good change
  ok := coalesce(l.status, '') ILIKE 'active%' AND jsonb_array_length(coalesce(l.issues, '[]')) = 0;
  IF ok AND EXISTS (SELECT 1 FROM public.amazon_audit_findings f WHERE f.sku = l.sku AND f.status = 'open' AND f.rule_code = 'suppressed_after_change') THEN
    UPDATE public.amazon_audit_findings f SET status = 'fixed', resolved_at = now()
     WHERE f.sku = l.sku AND f.status = 'open' AND f.rule_code = 'suppressed_after_change';
    UPDATE public.amazon_change_queue q SET status = 'cancelled', reject_reason = 'Not needed: the product is selling again on Amazon'
     WHERE q.sku = l.sku AND q.kind = 'rollback' AND q.status = 'pending' AND q.created_by_type = 'system';
  END IF;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_check_listing_trg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  BEGIN PERFORM crm_private.amz_check_listing(NEW.sku);
  EXCEPTION WHEN others THEN NULL;            -- a check must never block a sync or a save
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS amz_check_listing ON public.amazon_listings;
CREATE TRIGGER amz_check_listing AFTER INSERT OR UPDATE OF title, bullets, description, attributes, status, asin, issues, last_approved_title
  ON public.amazon_listings FOR EACH ROW EXECUTE FUNCTION crm_private.amz_check_listing_trg();

-- A name we changed ourselves in the last 3 hours is not "changed outside the CRM" (Amazon shows the old one for a while).
CREATE OR REPLACE FUNCTION crm_private.amz_finding_filter() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.rule_code = 'title_drift' AND NEW.sku IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.amazon_change_queue q WHERE q.sku = NEW.sku AND q.after ? 'title'
          AND (q.status IN ('approved', 'executing') OR (q.status IN ('live', 'failed') AND q.executed_at > now() - interval '3 hours'))) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_finding_filter ON public.amazon_audit_findings;
CREATE TRIGGER amz_finding_filter BEFORE INSERT ON public.amazon_audit_findings
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_finding_filter();

-- ---------------------------------------------------------------- product page
CREATE OR REPLACE FUNCTION public.api_amz_product_todo(p_sku text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'problems', coalesce((SELECT jsonb_agg(jsonb_build_object('id', f.id, 'rule_code', f.rule_code, 'severity', f.severity, 'message', f.message,
          'created_at', f.created_at,
          'fix_waiting', (SELECT count(*) FROM public.amazon_change_queue q WHERE q.finding_id = f.id AND q.status = 'pending'))
          ORDER BY (f.severity = 'blocker') DESC, f.id)
        FROM public.amazon_audit_findings f WHERE f.sku = p_sku AND f.status = 'open'), '[]'),
    'waiting', coalesce((SELECT jsonb_agg(jsonb_build_object('id', q.id, 'summary', q.summary, 'kind', q.kind,
          'fields', crm_private.amz_field_label(crm_private.amz_change_fields(q.after)), 'created_at', q.created_at) ORDER BY q.created_at DESC)
        FROM public.amazon_change_queue q WHERE q.sku = p_sku AND q.status = 'pending'), '[]'),
    'fixing', EXISTS (SELECT 1 FROM public.amazon_claude_requests r WHERE r.kind = 'fix' AND r.sku = p_sku AND r.status IN ('waiting', 'working')),
    'can_fix', crm_private.amz_can_approve());
END $$;

-- ---------------------------------------------------------------- one choice per product and field, from now on
-- A newer keyword / growth suggestion replaces the older suggestion for the same field of the same product.
-- Fixes for a problem, people's own drafts and undo drafts are never replaced this way.
CREATE OR REPLACE FUNCTION crm_private.amz_replace_older() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.status = 'pending' AND NEW.sku IS NOT NULL AND NEW.kind <> 'rollback' AND coalesce(NEW.alt_rank, 1) = 1 THEN
    UPDATE public.amazon_change_queue o SET status = 'cancelled', reject_reason = 'Replaced: a newer suggestion for the same field arrived'
     WHERE o.sku = NEW.sku AND o.id <> NEW.id AND o.status = 'pending' AND o.kind <> 'rollback'
       AND o.created_by_type <> 'user' AND o.finding_id IS NULL
       AND (o.alt_group LIKE 'kw%' OR o.alt_group LIKE 'growth:%')
       AND o.alt_group IS DISTINCT FROM NEW.alt_group
       AND o.created_at <= NEW.created_at
       AND crm_private.amz_change_fields(o.after) && crm_private.amz_change_fields(NEW.after);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS amz_replace_older ON public.amazon_change_queue;
CREATE TRIGGER amz_replace_older AFTER INSERT ON public.amazon_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_replace_older();

REVOKE ALL ON FUNCTION crm_private.amz_sizes(text), crm_private.amz_check_listing(text), crm_private.amz_check_listing_trg(),
  crm_private.amz_finding_filter(), crm_private.amz_replace_older() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_amz_product_todo(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_amz_product_todo(text) TO authenticated;

-- ---------------------------------------------------------------- one-time: run the checks, tidy Decisions
DO $$
DECLARE s text; r public.amazon_change_queue; taken text[]; f text[]; keys text[];
BEGIN
  FOR s IN SELECT sku FROM public.amazon_listings LOOP PERFORM crm_private.amz_check_listing(s); END LOOP;
  -- Decisions: keep the best waiting choice per product and field. Order: size corrections, people's own drafts,
  -- then the top-ranked and newest suggestion. Undo drafts are left alone.
  taken := '{}';
  FOR r IN SELECT * FROM public.amazon_change_queue q
            WHERE q.status = 'pending' AND q.sku IS NOT NULL AND q.kind <> 'rollback'
            ORDER BY q.sku, (q.alt_group LIKE 'size:%') DESC NULLS LAST, (q.created_by_type = 'user') DESC,
                     (q.finding_id IS NOT NULL) DESC, coalesce(q.alt_rank, 1), q.created_at DESC LOOP
    f := crm_private.amz_change_fields(r.after);
    SELECT array_agg(r.sku || '|' || x) INTO keys FROM unnest(f) x;
    IF keys && taken THEN
      UPDATE public.amazon_change_queue SET status = 'cancelled', reject_reason = 'Tidied: a better choice for the same field of this product is waiting'
       WHERE id = r.id;
    ELSE
      taken := taken || keys;
    END IF;
  END LOOP;
END $$;
