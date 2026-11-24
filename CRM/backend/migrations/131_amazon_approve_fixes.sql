-- 131: Approve-all fixes (Amazon Decisions)
--  1. A draft goes Stale only when Amazon moved one of the SAME fields it changes (was: any change to the
--     listing, so approving one change made every other change of that product stale).
--  2. Two waiting changes to the same field of the same product: approving one closes the other
--     (was: both went live a minute apart, the first was then reported "Amazon still shows the old title").
--  3. Wrongly-stale drafts and the dispatch/price changes that failed only because of our preview bug
--     go back to Waiting. Nothing is sent: each still needs your approval.
-- Re-runnable.

-- The fields one change touches: top-level keys, attributes as attributes.<name>.
CREATE OR REPLACE FUNCTION crm_private.amz_change_fields(p_after jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(f ORDER BY f), '{}') FROM (
    SELECT k AS f FROM jsonb_object_keys(coalesce(p_after, '{}')) k WHERE k <> 'attributes'
    UNION
    SELECT 'attributes.' || a FROM jsonb_object_keys(CASE WHEN jsonb_typeof(p_after->'attributes') = 'object' THEN p_after->'attributes' ELSE '{}' END) a
  ) s
$$;

CREATE OR REPLACE FUNCTION crm_private.amz_same_value(p_field text, a jsonb, b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF a IS NULL OR a = 'null' THEN RETURN b IS NULL OR b = 'null'; END IF;
  IF b IS NULL OR b = 'null' THEN RETURN false; END IF;
  IF p_field IN ('price', 'mrp', 'handling_days', 'quantity') THEN
    BEGIN RETURN (a #>> '{}')::numeric = (b #>> '{}')::numeric; EXCEPTION WHEN others THEN RETURN false; END;
  END IF;
  IF jsonb_typeof(a) = 'string' AND jsonb_typeof(b) = 'string' THEN RETURN btrim(a #>> '{}') = btrim(b #>> '{}'); END IF;
  RETURN a = b;
END $$;

-- Fields Amazon changed since the draft was made AND that are not already what the draft wants.
CREATE OR REPLACE FUNCTION crm_private.amz_moved_fields(q public.amazon_change_queue) RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.amazon_listings; snap jsonb; f text; cur jsonb; was jsonb; want jsonb; moved text[] := '{}';
BEGIN
  IF q.sku IS NULL OR q.before IS NULL OR q.before = '{}' THEN RETURN '{}'; END IF;
  SELECT * INTO l FROM public.amazon_listings WHERE sku = q.sku;
  IF l.sku IS NULL THEN RETURN '{}'; END IF;
  snap := crm_private.amz_snapshot(q.sku);
  FOREACH f IN ARRAY crm_private.amz_change_fields(q.after) LOOP
    IF f LIKE 'attributes.%' THEN
      cur := l.attributes -> substr(f, 12); was := q.before #> ARRAY['attributes', substr(f, 12)]; want := q.after #> ARRAY['attributes', substr(f, 12)];
      IF NOT (q.before ? 'attributes') THEN CONTINUE; END IF;
    ELSE
      IF NOT (snap ? f) OR NOT (q.before ? f) THEN CONTINUE; END IF;   -- fields we cannot compare (photos, swatch...) never block
      cur := snap -> f; was := q.before -> f; want := q.after -> f;
    END IF;
    IF NOT crm_private.amz_same_value(f, cur, was) AND NOT crm_private.amz_same_value(f, cur, want) THEN
      moved := moved || f;
    END IF;
  END LOOP;
  RETURN moved;
END $$;

CREATE OR REPLACE FUNCTION crm_private.amz_field_label(p_fields text[]) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT string_agg(CASE f WHEN 'title' THEN 'name' WHEN 'backend_terms' THEN 'hidden search words' WHEN 'handling_days' THEN 'dispatch time'
    WHEN 'attributes.title_differentiation' THEN 'item highlights' WHEN 'mrp' THEN 'MRP' ELSE replace(replace(f, 'attributes.', ''), '_', ' ') END, ', ')
  FROM unnest(p_fields) f
$$;

-- Approve: stale only on a real conflict; otherwise the draft is re-based on the current version.
CREATE OR REPLACE FUNCTION public.api_amz_approve(p_id uuid, p_second_confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.amazon_change_queue; cur int; me uuid := crm_private.current_employee_id(); moved text[]; busy text;
BEGIN
  IF NOT crm_private.amz_can_approve() THEN RAISE EXCEPTION 'You are not allowed to approve Amazon changes' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO q FROM public.amazon_change_queue WHERE id = p_id FOR UPDATE;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Change not found' USING ERRCODE = 'PT404'; END IF;
  IF q.status = 'cancelled' AND q.reject_reason LIKE 'Replaced:%' THEN RETURN to_jsonb(q); END IF;   -- Approve all: already replaced, not an error
  IF q.status <> 'pending' THEN RAISE EXCEPTION 'Already %', q.status USING ERRCODE = 'PT409'; END IF;
  IF q.sku IS NOT NULL THEN
    moved := crm_private.amz_moved_fields(q);
    IF cardinality(moved) > 0 THEN
      -- Not an exception: an exception would undo the Stale mark. The caller sees status = 'stale'.
      UPDATE public.amazon_change_queue SET status = 'stale',
        error = format('Amazon''s %s changed since this draft was made. Review again.', crm_private.amz_field_label(moved))
       WHERE id = p_id RETURNING * INTO q;
      PERFORM crm_private.amz_log('change_stale', 'change', p_id::text, jsonb_build_object('sku', q.sku, 'fields', moved));
      RETURN to_jsonb(q);
    END IF;
    -- Another change to the same field of this product is already on its way: wait for it.
    SELECT crm_private.amz_field_label(array_agg(DISTINCT f)) INTO busy
      FROM public.amazon_change_queue o, unnest(crm_private.amz_change_fields(o.after)) f
     WHERE o.sku = q.sku AND o.id <> q.id AND o.status IN ('approved', 'executing')
       AND f = ANY (crm_private.amz_change_fields(q.after));
    IF busy IS NOT NULL THEN
      RAISE EXCEPTION 'Another change to the % of this product is going live right now. Try again in a minute.', busy USING ERRCODE = 'PT409';
    END IF;
    SELECT version INTO cur FROM public.amazon_listings WHERE sku = q.sku;
    IF cur IS DISTINCT FROM q.base_version THEN
      UPDATE public.amazon_change_queue SET base_version = cur WHERE id = p_id RETURNING * INTO q;
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

-- Approving one change closes its alternatives AND every other waiting change to the same field of the same product.
CREATE OR REPLACE FUNCTION crm_private.amz_close_siblings() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
    IF NEW.alt_group IS NOT NULL THEN
      UPDATE public.amazon_change_queue SET status = 'cancelled', reject_reason = 'Another choice was approved'
       WHERE alt_group = NEW.alt_group AND id <> NEW.id AND status IN ('pending', 'stale');
    END IF;
    IF NEW.sku IS NOT NULL THEN
      UPDATE public.amazon_change_queue o SET status = 'cancelled',
             reject_reason = 'Replaced: another change to the ' || crm_private.amz_field_label(crm_private.amz_change_fields(NEW.after)) || ' was approved'
       WHERE o.sku = NEW.sku AND o.id <> NEW.id AND o.status IN ('pending', 'stale') AND o.kind <> 'rollback'
         AND crm_private.amz_change_fields(o.after) && crm_private.amz_change_fields(NEW.after);
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- Sync: it marks every waiting draft of a changed listing Stale. Keep the ones whose own fields did not move.
CREATE OR REPLACE FUNCTION crm_private.amz_keep_unmoved() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cur int;
BEGIN
  IF NEW.status = 'stale' AND OLD.status = 'pending' AND NEW.error = 'Listing changed on Amazon after this draft was made.' THEN
    BEGIN
      IF cardinality(crm_private.amz_moved_fields(NEW)) = 0 THEN
        SELECT version INTO cur FROM public.amazon_listings WHERE sku = NEW.sku;
        NEW.status := 'pending'; NEW.error := OLD.error; NEW.base_version := coalesce(cur, NEW.base_version);
      END IF;
    EXCEPTION WHEN others THEN NULL;     -- never break the sync: if in doubt it stays Stale
    END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS amz_keep_unmoved ON public.amazon_change_queue;
CREATE TRIGGER amz_keep_unmoved BEFORE UPDATE OF status ON public.amazon_change_queue
  FOR EACH ROW EXECUTE FUNCTION crm_private.amz_keep_unmoved();

REVOKE ALL ON FUNCTION crm_private.amz_change_fields(jsonb), crm_private.amz_same_value(text, jsonb, jsonb),
  crm_private.amz_moved_fields(public.amazon_change_queue), crm_private.amz_field_label(text[]),
  crm_private.amz_keep_unmoved() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- one-time repair of the queue
-- (a) Waiting/Stale changes whose wanted values are all already on Amazon: nothing left to do.
-- (b) Stale only because of the old version rule, or failed only because of our preview bug (nothing was sent):
--     back to Waiting, newest per product+field; older duplicates closed.
DO $$
DECLARE r public.amazon_change_queue; cur int;
BEGIN
  FOR r IN
    SELECT q.* FROM public.amazon_change_queue q
     WHERE q.kind <> 'rollback' AND q.sku IS NOT NULL AND (
           (q.status = 'stale' AND (q.error LIKE 'Listing changed since this draft (version%' OR q.error = 'Listing changed on Amazon after this draft was made.'))
        OR (q.status = 'failed' AND q.error LIKE 'Validation preview failed: 400 Invalid operation found in patch%Merge operation is not allowed%'))
     ORDER BY q.created_at DESC
  LOOP
    CONTINUE WHEN (SELECT status FROM public.amazon_change_queue WHERE id = r.id) NOT IN ('stale', 'failed');   -- closed by a newer one
    IF cardinality(crm_private.amz_moved_fields(r)) > 0 THEN CONTINUE; END IF;        -- Amazon really moved: stays Stale
    IF EXISTS (SELECT 1 FROM public.amazon_change_queue o                              -- a newer change to the same field exists
                WHERE o.sku = r.sku AND o.id <> r.id AND o.created_at > r.created_at
                  AND o.status IN ('pending', 'approved', 'executing', 'live', 'needs_manual')
                  AND (o.alt_group IS NULL OR r.alt_group IS NULL OR o.alt_group <> r.alt_group)
                  AND crm_private.amz_change_fields(o.after) && crm_private.amz_change_fields(r.after)) THEN CONTINUE; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.amazon_listings l WHERE l.sku = r.sku AND NOT l.is_parent) THEN CONTINUE; END IF;
    SELECT version INTO cur FROM public.amazon_listings WHERE sku = r.sku;
    UPDATE public.amazon_change_queue SET status = 'pending', error = NULL, base_version = cur,
           reason = coalesce(reason, '') || CASE WHEN coalesce(reason, '') = '' THEN '' ELSE ' ' END || '(Back for approval: it was blocked by a CRM bug, nothing was sent.)'
     WHERE id = r.id;
    -- older waiting/stale/failed duplicates of the same product+field are closed
    UPDATE public.amazon_change_queue o SET status = 'cancelled', reject_reason = 'Replaced: a newer change to the same field is waiting'
     WHERE o.sku = r.sku AND o.id <> r.id AND o.status IN ('pending', 'stale', 'failed') AND o.kind <> 'rollback'
       AND o.created_at < r.created_at
       AND (o.alt_group IS NULL OR r.alt_group IS NULL OR o.alt_group <> r.alt_group)
       AND crm_private.amz_change_fields(o.after) && crm_private.amz_change_fields(r.after)
       AND (o.status <> 'failed' OR o.error LIKE 'Validation preview failed: 400 Invalid operation%');
  END LOOP;
  -- (c) Stale drafts overtaken by a newer change to the same field that is already live: closed
  UPDATE public.amazon_change_queue q SET status = 'cancelled', reject_reason = 'Replaced: a newer change to the same field is live'
   WHERE q.status = 'stale' AND q.kind <> 'rollback' AND q.sku IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.amazon_change_queue o
                  WHERE o.sku = q.sku AND o.id <> q.id AND o.status = 'live' AND o.executed_at > q.created_at
                    AND crm_private.amz_change_fields(o.after) && crm_private.amz_change_fields(q.after));
  -- (a) after revival: anything already exactly on Amazon is done
  UPDATE public.amazon_change_queue q SET status = 'cancelled', reject_reason = 'Already on Amazon'
   WHERE q.status IN ('pending', 'stale') AND q.kind <> 'rollback' AND q.sku IS NOT NULL
     AND crm_private.amz_change_fields(q.after) <@ ARRAY['title','bullets','description','backend_terms','price','mrp','handling_days','country_of_origin','manufacturer']
     AND NOT EXISTS (SELECT 1 FROM unnest(crm_private.amz_change_fields(q.after)) f
                      WHERE NOT crm_private.amz_same_value(f, crm_private.amz_snapshot(q.sku) -> f, q.after -> f));
END $$;
