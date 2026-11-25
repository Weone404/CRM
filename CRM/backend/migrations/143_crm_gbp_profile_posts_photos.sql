-- 143 CRM > Google > Google My Business: profile health check, posts, photos.
--   Health check  what Google has on the profile (hours, description, categories, phone, website, verification, photos, posts)
--                 against a short list. "basic" items are things a customer needs; "good practice" items are advice, not Google rules.
--   Posts         the posts on the profile, and publishing one from the CRM (a person writes it; nothing is automatic)
--   Photos        the photos on the profile, the owner's and customers'
-- Google gives no view counts for posts or photos any more, so none are shown. Read-only except publishing a post, which goes
-- through a queue (gbp_post_out) sent by crm-google-business; a post is never sent twice. Re-runnable. Needs 139.

-- ---------------------------------------------------------------- tables
ALTER TABLE public.gbp_location ADD COLUMN IF NOT EXISTS details jsonb, ADD COLUMN IF NOT EXISTS details_at timestamptz,
  ADD COLUMN IF NOT EXISTS media_owner int, ADD COLUMN IF NOT EXISTS media_customer int, ADD COLUMN IF NOT EXISTS extras_at timestamptz;
CREATE TABLE IF NOT EXISTS public.gbp_post (
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE, post_id text NOT NULL,
  topic text, state text, summary text, cta_type text, cta_url text, media_url text, search_url text,
  created_at timestamptz, updated_at timestamptz, scheduled_at timestamptz, seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (location_id, post_id));
CREATE INDEX IF NOT EXISTS idx_gbp_post_time ON public.gbp_post (location_id, created_at DESC);
CREATE TABLE IF NOT EXISTS public.gbp_media (
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE, media_id text NOT NULL, by_owner boolean NOT NULL,
  format text, category text, thumb_url text, google_url text, description text, created_at timestamptz, seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (location_id, media_id));
CREATE INDEX IF NOT EXISTS idx_gbp_media_time ON public.gbp_media (location_id, created_at DESC);
CREATE TABLE IF NOT EXISTS public.gbp_post_out (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  location_id uuid NOT NULL REFERENCES public.gbp_location(id) ON DELETE CASCADE,
  summary text NOT NULL, cta_type text, cta_url text, photo_url text,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'failed', 'cancelled')),
  error text, post_name text, created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), taken_at timestamptz, sent_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_gbp_post_out_status ON public.gbp_post_out (status, created_at);
ALTER TABLE public.gbp_post ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_post_out ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gbp_post, public.gbp_media, public.gbp_post_out FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- health check
-- One profile's checks. level: basic (a customer needs it) | practice (advice). ok: true | false.
CREATE OR REPLACE FUNCTION crm_private.gbp_health(p_location uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.gbp_location; d jsonb; c jsonb := '[]'; n int; t timestamptz; dl int;
BEGIN
  SELECT * INTO l FROM public.gbp_location WHERE id = p_location;
  IF NOT FOUND THEN RETURN NULL; END IF;
  d := coalesce(l.details, '{}');
  c := c || jsonb_build_object('key', 'verified', 'level', 'basic', 'ok', l.verified IS TRUE, 'title', 'Verified on Google',
    'detail', CASE WHEN l.verified IS TRUE THEN 'Google has verified that you own this business.'
                   ELSE 'Google has not confirmed this profile as verified. Unverified profiles may not be shown to customers. Finish verification in your Business Profile.' END);
  c := c || jsonb_build_object('key', 'category', 'level', 'basic', 'ok', btrim(coalesce(l.category, '')) <> '', 'title', 'Main category',
    'detail', CASE WHEN btrim(coalesce(l.category, '')) <> '' THEN l.category ELSE 'No main category. Google uses it to decide which searches show you.' END);
  c := c || jsonb_build_object('key', 'phone', 'level', 'basic', 'ok', btrim(coalesce(l.phone, '')) <> '', 'title', 'Phone number',
    'detail', CASE WHEN btrim(coalesce(l.phone, '')) <> '' THEN l.phone ELSE 'No phone number, so nobody can tap Call.' END);
  c := c || jsonb_build_object('key', 'website', 'level', 'basic', 'ok', coalesce(l.website, '') ~* '^https://', 'title', 'Website link',
    'detail', CASE WHEN coalesce(l.website, '') ~* '^https://' THEN l.website WHEN btrim(coalesce(l.website, '')) <> '' THEN 'The link does not start with https://: ' || left(l.website, 120)
                   ELSE 'No website link, so nobody can tap Website.' END);
  IF l.details IS NULL THEN       -- the detailed read has not happened yet: say so instead of marking things missing
    RETURN jsonb_build_object('id', l.id, 'title', coalesce(NULLIF(l.title, ''), l.name), 'maps_uri', l.maps_uri, 'collected', false, 'checks', c,
      'ok', (SELECT count(*) FROM jsonb_array_elements(c) x WHERE (x->>'ok')::boolean), 'total', jsonb_array_length(c));
  END IF;
  c := c || jsonb_build_object('key', 'address', 'level', 'basic', 'ok', btrim(coalesce(l.address, '')) <> '' OR (d->>'service_area')::boolean IS TRUE, 'title', 'Address or service area',
    'detail', CASE WHEN btrim(coalesce(l.address, '')) <> '' THEN l.address WHEN (d->>'service_area')::boolean IS TRUE THEN 'Service area set (no storefront address).'
                   ELSE 'No address and no service area.' END);
  n := CASE WHEN jsonb_typeof(d->'hours') = 'array' THEN jsonb_array_length(d->'hours') ELSE 0 END;
  c := c || jsonb_build_object('key', 'hours', 'level', 'basic', 'ok', n > 0, 'title', 'Opening hours',
    'detail', CASE WHEN n > 0 THEN (SELECT count(DISTINCT h->>'d') FROM jsonb_array_elements(d->'hours') h) || ' day(s) a week have hours.' ELSE 'No opening hours. Google shows "hours not available".' END);
  c := c || jsonb_build_object('key', 'open', 'level', 'basic', 'ok', coalesce(d->>'open_status', 'OPEN') = 'OPEN', 'title', 'Marked as open',
    'detail', CASE coalesce(d->>'open_status', 'OPEN') WHEN 'OPEN' THEN 'The profile says the business is open.' WHEN 'CLOSED_TEMPORARILY' THEN 'The profile says "temporarily closed".'
                   WHEN 'CLOSED_PERMANENTLY' THEN 'The profile says "permanently closed".' ELSE 'Open status: ' || left(d->>'open_status', 40) END);
  c := c || jsonb_build_object('key', 'google_updated', 'level', 'basic', 'ok', (d->>'google_updated')::boolean IS NOT TRUE, 'title', 'No changes by Google waiting for you',
    'detail', CASE WHEN (d->>'google_updated')::boolean IS TRUE THEN 'Google changed something on this profile. Open your Business Profile and accept or reject the changes.' ELSE 'Nothing to review.' END);
  dl := length(btrim(coalesce(d->>'description', '')));
  c := c || jsonb_build_object('key', 'description', 'level', 'basic', 'ok', dl > 0, 'title', 'Business description',
    'detail', CASE WHEN dl > 0 THEN dl || ' of 750 characters used.' ELSE 'No description. Customers and Google get no text about what you do.' END);
  c := c || jsonb_build_object('key', 'description_full', 'level', 'practice', 'ok', dl >= 250, 'title', 'Description says enough',
    'detail', CASE WHEN dl >= 250 THEN 'Long enough to say what you teach, for whom and where.' ELSE 'Only ' || dl || ' characters. Google allows 750: say what you offer, for whom and where.' END);
  n := CASE WHEN jsonb_typeof(d->'more_categories') = 'array' THEN jsonb_array_length(d->'more_categories') ELSE 0 END;
  c := c || jsonb_build_object('key', 'more_categories', 'level', 'practice', 'ok', n > 0, 'title', 'Additional categories',
    'detail', CASE WHEN n > 0 THEN (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(d->'more_categories') x) ELSE 'None. Add the other things you truly are (for example a second type of training).' END);
  IF l.extras_at IS NOT NULL THEN
    SELECT count(*), max(m.created_at) INTO n, t FROM public.gbp_media m WHERE m.location_id = l.id AND m.by_owner;
    c := c || jsonb_build_object('key', 'photo_cover', 'level', 'practice',
      'ok', EXISTS (SELECT 1 FROM public.gbp_media m WHERE m.location_id = l.id AND m.by_owner AND m.category = 'COVER'), 'title', 'Cover photo',
      'detail', CASE WHEN EXISTS (SELECT 1 FROM public.gbp_media m WHERE m.location_id = l.id AND m.by_owner AND m.category = 'COVER') THEN 'Set.' ELSE 'No cover photo chosen by you; Google picks one itself.' END);
    c := c || jsonb_build_object('key', 'photo_logo', 'level', 'practice',
      'ok', EXISTS (SELECT 1 FROM public.gbp_media m WHERE m.location_id = l.id AND m.by_owner AND m.category IN ('PROFILE', 'LOGO')), 'title', 'Logo',
      'detail', CASE WHEN EXISTS (SELECT 1 FROM public.gbp_media m WHERE m.location_id = l.id AND m.by_owner AND m.category IN ('PROFILE', 'LOGO')) THEN 'Set.' ELSE 'No logo on the profile.' END);
    c := c || jsonb_build_object('key', 'photo_count', 'level', 'practice', 'ok', coalesce(l.media_owner, n) >= 10, 'title', 'At least 10 photos of your own',
      'detail', 'You have ' || coalesce(l.media_owner, n) || '; customers added ' || coalesce(l.media_customer, 0) || '.');
    c := c || jsonb_build_object('key', 'photo_fresh', 'level', 'practice', 'ok', coalesce(t > now() - interval '90 days', false), 'title', 'A new photo in the last 90 days',
      'detail', CASE WHEN t IS NULL THEN 'No photo of your own yet.' ELSE 'Last added on ' || to_char(t, 'FMDD Mon YYYY') || '.' END);
    IF (d->>'can_post')::boolean IS NOT FALSE THEN
      SELECT max(p.created_at) INTO t FROM public.gbp_post p WHERE p.location_id = l.id AND p.state = 'LIVE';
      c := c || jsonb_build_object('key', 'post_fresh', 'level', 'practice', 'ok', coalesce(t > now() - interval '30 days', false), 'title', 'A post in the last 30 days',
        'detail', CASE WHEN t IS NULL THEN 'No post on the profile.' ELSE 'Last post on ' || to_char(t, 'FMDD Mon YYYY') || '.' END);
    END IF;
  END IF;
  SELECT count(*) INTO n FROM public.gbp_review r WHERE r.location_id = l.id AND r.reply IS NULL AND r.created_at > now() - interval '90 days';
  c := c || jsonb_build_object('key', 'reviews_answered', 'level', 'practice', 'ok', n = 0, 'title', 'Recent reviews answered',
    'detail', CASE WHEN n = 0 THEN 'No review from the last 90 days is without a reply.' ELSE n || ' review(s) from the last 90 days have no reply.' END);
  RETURN jsonb_build_object('id', l.id, 'title', coalesce(NULLIF(l.title, ''), l.name), 'maps_uri', l.maps_uri, 'collected', true, 'checked_at', l.details_at,
    'checks', c, 'ok', (SELECT count(*) FROM jsonb_array_elements(c) x WHERE (x->>'ok')::boolean), 'total', jsonb_array_length(c),
    'basic_missing', (SELECT count(*) FROM jsonb_array_elements(c) x WHERE x->>'level' = 'basic' AND NOT (x->>'ok')::boolean));
END $$;

-- ---------------------------------------------------------------- browser API
CREATE OR REPLACE FUNCTION public.api_gbp_profile(p_location uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN coalesce((SELECT jsonb_agg(crm_private.gbp_health(l.id) ORDER BY l.title) FROM public.gbp_location l
                    WHERE l.tracked AND (p_location IS NULL OR l.id = p_location)), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_gbp_posts(p_location uuid DEFAULT NULL, p_limit int DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN jsonb_build_object(
    'can_run', crm_private.gbp_can_run(),
    'profiles', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'title', coalesce(NULLIF(l.title, ''), l.name), 'can_post', (l.details->>'can_post')::boolean IS NOT FALSE,
        'collected', l.extras_at IS NOT NULL) ORDER BY l.title), '[]') FROM public.gbp_location l WHERE l.tracked AND (p_location IS NULL OR l.id = p_location)),
    'posts', (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
        SELECT p.post_id, p.location_id, coalesce(NULLIF(l.title, ''), l.name) AS profile, p.topic, p.state, p.summary, p.cta_type, p.cta_url, p.media_url, p.search_url, p.created_at, p.scheduled_at
          FROM public.gbp_post p JOIN public.gbp_location l ON l.id = p.location_id
         WHERE l.tracked AND (p_location IS NULL OR p.location_id = p_location)
         ORDER BY p.created_at DESC NULLS LAST LIMIT least(200, greatest(1, coalesce(p_limit, 50)))) z),
    'waiting', (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC), '[]') FROM (
        SELECT o.id, o.location_id, coalesce(NULLIF(l.title, ''), l.name) AS profile, o.summary, o.cta_type, o.cta_url, o.photo_url, o.status, o.error, o.created_at
          FROM public.gbp_post_out o JOIN public.gbp_location l ON l.id = o.location_id
         WHERE l.tracked AND (p_location IS NULL OR o.location_id = p_location) AND o.status IN ('queued', 'sending', 'failed')
         ORDER BY o.created_at DESC LIMIT 20) z));
END $$;

CREATE OR REPLACE FUNCTION public.api_gbp_media(p_location uuid DEFAULT NULL, p_limit int DEFAULT 120) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN jsonb_build_object(
    'collected', EXISTS (SELECT 1 FROM public.gbp_location l WHERE l.tracked AND (p_location IS NULL OR l.id = p_location) AND l.extras_at IS NOT NULL),
    'owner', (SELECT coalesce(sum(coalesce(l.media_owner, 0)), 0) FROM public.gbp_location l WHERE l.tracked AND (p_location IS NULL OR l.id = p_location)),
    'customers', (SELECT coalesce(sum(coalesce(l.media_customer, 0)), 0) FROM public.gbp_location l WHERE l.tracked AND (p_location IS NULL OR l.id = p_location)),
    'last_added', (SELECT max(m.created_at) FROM public.gbp_media m JOIN public.gbp_location l ON l.id = m.location_id
                    WHERE l.tracked AND (p_location IS NULL OR l.id = p_location) AND m.by_owner),
    'by_category', (SELECT coalesce(jsonb_object_agg(z.category, z.n), '{}') FROM (
        SELECT coalesce(m.category, 'ADDITIONAL') AS category, count(*) AS n FROM public.gbp_media m JOIN public.gbp_location l ON l.id = m.location_id
         WHERE l.tracked AND (p_location IS NULL OR l.id = p_location) AND m.by_owner GROUP BY 1) z),
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
        SELECT m.media_id, m.location_id, coalesce(NULLIF(l.title, ''), l.name) AS profile, m.by_owner, m.format, m.category, m.thumb_url, m.google_url, m.description, m.created_at
          FROM public.gbp_media m JOIN public.gbp_location l ON l.id = m.location_id
         WHERE l.tracked AND (p_location IS NULL OR l.id = p_location)
         ORDER BY m.created_at DESC NULLS LAST LIMIT least(500, greatest(1, coalesce(p_limit, 120)))) z));
END $$;

-- Publish a post on a profile. A person writes it; it goes out as written. p_cta_type: NULL | BOOK | ORDER | SHOP | LEARN_MORE | SIGN_UP | CALL.
CREATE OR REPLACE FUNCTION public.api_gbp_post_create(p_location uuid, p_summary text, p_cta_type text DEFAULT NULL, p_cta_url text DEFAULT NULL, p_photo_url text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.gbp_location; t text := btrim(coalesce(p_summary, '')); ct text := NULLIF(upper(btrim(coalesce(p_cta_type, ''))), '');
        cu text := NULLIF(btrim(coalesce(p_cta_url, '')), ''); ph text := NULLIF(btrim(coalesce(p_photo_url, '')), ''); rid bigint;
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can publish a post' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO l FROM public.gbp_location WHERE id = p_location AND tracked;
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose one of the tracked profiles' USING ERRCODE = 'PT404'; END IF;
  IF (l.details->>'can_post')::boolean IS FALSE THEN RAISE EXCEPTION 'Google does not allow posts on this profile' USING ERRCODE = 'PT422'; END IF;
  IF length(t) < 1 THEN RAISE EXCEPTION 'Write the post first' USING ERRCODE = 'PT422'; END IF;
  IF length(t) > 1500 THEN RAISE EXCEPTION 'Keep the post under 1,500 characters (it has %)', length(t) USING ERRCODE = 'PT422'; END IF;
  IF t ~ '[<>]' THEN RAISE EXCEPTION 'No < or > in a post' USING ERRCODE = 'PT422'; END IF;
  IF ct IS NOT NULL AND ct NOT IN ('BOOK', 'ORDER', 'SHOP', 'LEARN_MORE', 'SIGN_UP', 'CALL') THEN RAISE EXCEPTION 'Unknown button type' USING ERRCODE = 'PT422'; END IF;
  IF ct = 'CALL' THEN cu := NULL;       -- Google uses the profile's own phone number
  ELSIF ct IS NOT NULL AND (cu IS NULL OR cu !~* '^https://[^\s<>"]+$' OR length(cu) > 500) THEN RAISE EXCEPTION 'The button needs a link that starts with https://' USING ERRCODE = 'PT422';
  ELSIF ct IS NULL AND cu IS NOT NULL THEN RAISE EXCEPTION 'Choose what the button says, or remove the link' USING ERRCODE = 'PT422'; END IF;
  IF ph IS NOT NULL AND (ph !~* '^https://[^\s<>"]+$' OR length(ph) > 1000) THEN RAISE EXCEPTION 'The photo must be a link that starts with https://' USING ERRCODE = 'PT422'; END IF;
  IF EXISTS (SELECT 1 FROM public.gbp_post_out o WHERE o.location_id = l.id AND o.status IN ('queued', 'sending', 'sent') AND o.created_at > now() - interval '24 hours'
              AND regexp_replace(lower(o.summary), '\s+', ' ', 'g') = regexp_replace(lower(t), '\s+', ' ', 'g')) THEN
    RAISE EXCEPTION 'The same post was already published on this profile in the last 24 hours' USING ERRCODE = 'PT422'; END IF;
  IF (SELECT count(*) FROM public.gbp_post_out o WHERE o.location_id = l.id AND o.status IN ('queued', 'sending', 'sent') AND o.created_at > now() - interval '24 hours') >= 10 THEN
    RAISE EXCEPTION 'At most 10 posts a day on one profile' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.gbp_post_out (location_id, summary, cta_type, cta_url, photo_url, created_by) VALUES (l.id, t, ct, cu, ph, crm_private.current_employee_id()) RETURNING id INTO rid;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, $2, $3, $4)'
      USING crm_private.current_employee_id(), 'gbp_post_create', 'gbp_post', jsonb_build_object('id', rid, 'location', l.id, 'length', length(t));
  END IF;
  RETURN jsonb_build_object('id', rid, 'status', 'queued');
END $$;

-- Drop a post that has not gone out (queued or failed).
CREATE OR REPLACE FUNCTION public.api_gbp_post_cancel(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can publish a post' USING ERRCODE = 'PT403'; END IF;
  UPDATE public.gbp_post_out SET status = 'cancelled' WHERE id = p_id AND status IN ('queued', 'failed');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'That post is already on its way or was already removed' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('id', p_id, 'status', 'cancelled');
END $$;

-- ---------------------------------------------------------------- service API (crm-google-business)
-- Profile details read with the profile list: [{name, details}]
CREATE OR REPLACE FUNCTION public.svc_gbp_details_save(p_connection uuid, p_rows jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN RETURN 0; END IF;
  UPDATE public.gbp_location l SET details = r.value->'details', details_at = now()
    FROM jsonb_array_elements(p_rows) r
   WHERE l.connection_id = p_connection AND jsonb_typeof(r.value) = 'object' AND l.name = r.value->>'name' AND jsonb_typeof(r.value->'details') = 'object';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Posts of one profile. p_complete: the whole list was read, so posts no longer on Google are removed here too.
CREATE OR REPLACE FUNCTION public.svc_gbp_posts_save(p_location uuid, p_rows jsonb, p_complete boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := 0; t0 timestamptz := clock_timestamp();
BEGIN
  IF p_rows IS NOT NULL AND jsonb_typeof(p_rows) = 'array' THEN
    INSERT INTO public.gbp_post (location_id, post_id, topic, state, summary, cta_type, cta_url, media_url, search_url, created_at, updated_at, scheduled_at, seen_at)
    SELECT DISTINCT ON (r->>'id') p_location, left(r->>'id', 200), left(r->>'topic', 30), left(r->>'state', 30), left(r->>'summary', 4000), left(r->>'cta_type', 30), left(r->>'cta_url', 1000),
           left(r->>'media_url', 2000), left(r->>'search_url', 1000), NULLIF(r->>'created', '')::timestamptz, NULLIF(r->>'updated', '')::timestamptz, NULLIF(r->>'scheduled', '')::timestamptz, t0
      FROM jsonb_array_elements(p_rows) r WHERE jsonb_typeof(r) = 'object' AND coalesce(r->>'id', '') <> ''
    ON CONFLICT (location_id, post_id) DO UPDATE SET topic = EXCLUDED.topic, state = EXCLUDED.state, summary = EXCLUDED.summary, cta_type = EXCLUDED.cta_type, cta_url = EXCLUDED.cta_url,
      media_url = EXCLUDED.media_url, search_url = EXCLUDED.search_url, created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at, scheduled_at = EXCLUDED.scheduled_at, seen_at = EXCLUDED.seen_at;
    GET DIAGNOSTICS n = ROW_COUNT;
  END IF;
  IF p_complete IS TRUE THEN DELETE FROM public.gbp_post WHERE location_id = p_location AND seen_at < t0; END IF;
  UPDATE public.gbp_location SET extras_at = now() WHERE id = p_location;
  RETURN n;
END $$;

-- Photos of one profile: [{id, by_owner, format, category, thumb, url, description, created}] and Google's own totals.
CREATE OR REPLACE FUNCTION public.svc_gbp_media_save(p_location uuid, p_rows jsonb, p_owner_total int DEFAULT NULL, p_customer_total int DEFAULT NULL, p_complete boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int := 0; t0 timestamptz := clock_timestamp();
BEGIN
  IF p_rows IS NOT NULL AND jsonb_typeof(p_rows) = 'array' THEN
    INSERT INTO public.gbp_media (location_id, media_id, by_owner, format, category, thumb_url, google_url, description, created_at, seen_at)
    SELECT DISTINCT ON (r->>'id') p_location, left(r->>'id', 300), coalesce((r->>'by_owner')::boolean, true), left(r->>'format', 20), left(r->>'category', 40),
           CASE WHEN r->>'thumb' ~* '^https://' THEN left(r->>'thumb', 2000) END, CASE WHEN r->>'url' ~* '^https://' THEN left(r->>'url', 2000) END,
           left(r->>'description', 1000), NULLIF(r->>'created', '')::timestamptz, t0
      FROM jsonb_array_elements(p_rows) r WHERE jsonb_typeof(r) = 'object' AND coalesce(r->>'id', '') <> ''
    ON CONFLICT (location_id, media_id) DO UPDATE SET by_owner = EXCLUDED.by_owner, format = EXCLUDED.format, category = EXCLUDED.category, thumb_url = EXCLUDED.thumb_url,
      google_url = EXCLUDED.google_url, description = EXCLUDED.description, created_at = EXCLUDED.created_at, seen_at = EXCLUDED.seen_at;
    GET DIAGNOSTICS n = ROW_COUNT;
  END IF;
  IF p_complete IS TRUE THEN DELETE FROM public.gbp_media WHERE location_id = p_location AND seen_at < t0; END IF;
  UPDATE public.gbp_location SET extras_at = now(),
         media_owner = CASE WHEN p_owner_total >= 0 THEN p_owner_total ELSE media_owner END,
         media_customer = CASE WHEN p_customer_total >= 0 THEN p_customer_total ELSE media_customer END WHERE id = p_location;
  RETURN n;
END $$;

-- Posts waiting to go out. Taking one marks it "sending": if the run dies before Google answers, it is NOT sent again by
-- itself (a post cannot be checked for duplicates the way a review reply can); it shows as failed and a person decides.
CREATE OR REPLACE FUNCTION public.svc_gbp_post_queue(p_limit int DEFAULT 5) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE res jsonb;
BEGIN
  UPDATE public.gbp_post_out SET status = 'failed', error = 'Google did not confirm this post. Check the profile on Google before publishing it again.'
   WHERE status = 'sending' AND taken_at < now() - interval '5 minutes';
  WITH pick AS (
    SELECT o.id FROM public.gbp_post_out o JOIN public.gbp_location l ON l.id = o.location_id
     WHERE o.status = 'queued' AND l.tracked ORDER BY o.created_at LIMIT least(10, greatest(1, coalesce(p_limit, 5))) FOR UPDATE OF o SKIP LOCKED),
  upd AS (UPDATE public.gbp_post_out o SET status = 'sending', taken_at = now() FROM pick WHERE o.id = pick.id RETURNING o.*)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'location_id', l.id, 'connection_id', l.connection_id, 'account', l.account, 'location', l.name,
           'summary', u.summary, 'cta_type', u.cta_type, 'cta_url', u.cta_url, 'photo_url', u.photo_url) ORDER BY u.created_at), '[]') INTO res
    FROM upd u JOIN public.gbp_location l ON l.id = u.location_id;
  RETURN res;
END $$;

-- p_state: sent | failed | retry (nothing reached Google, e.g. sign-in failed before the request: safe to try again)
CREATE OR REPLACE FUNCTION public.svc_gbp_post_result(p_id bigint, p_state text, p_error text DEFAULT NULL, p_name text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.gbp_post_out SET
    status = CASE p_state WHEN 'sent' THEN 'sent' WHEN 'retry' THEN 'queued' ELSE 'failed' END,
    error = CASE WHEN p_state = 'sent' THEN NULL ELSE left(coalesce(p_error, 'Google refused the post'), 300) END,
    post_name = CASE WHEN p_state = 'sent' THEN left(p_name, 300) ELSE post_name END,
    sent_at = CASE WHEN p_state = 'sent' THEN now() ELSE sent_at END
  WHERE id = p_id AND status = 'sending' $$;

-- ---------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION crm_private.gbp_health(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_gbp_profile(uuid), public.api_gbp_posts(uuid, int), public.api_gbp_media(uuid, int),
  public.api_gbp_post_create(uuid, text, text, text, text), public.api_gbp_post_cancel(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_gbp_profile(uuid), public.api_gbp_posts(uuid, int), public.api_gbp_media(uuid, int),
  public.api_gbp_post_create(uuid, text, text, text, text), public.api_gbp_post_cancel(bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_gbp_details_save(uuid, jsonb), public.svc_gbp_posts_save(uuid, jsonb, boolean), public.svc_gbp_media_save(uuid, jsonb, int, int, boolean),
  public.svc_gbp_post_queue(int), public.svc_gbp_post_result(bigint, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_gbp_details_save(uuid, jsonb), public.svc_gbp_posts_save(uuid, jsonb, boolean), public.svc_gbp_media_save(uuid, jsonb, int, int, boolean),
  public.svc_gbp_post_queue(int), public.svc_gbp_post_result(bigint, text, text, text) TO service_role;
