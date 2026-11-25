-- 140 CRM > Google > Google My Business: replies to reviews, written by the AI.
-- Flow for one review:  Writer (AI) -> code checks (this file) -> Reviewer (a second AI that did not write it) -> send.
--   4-5 stars  approved replies are sent by themselves (settings: on/off, from which star, how many a day)
--   1-3 stars  the reply is drafted but always waits for a person (Admin or approver) to send, edit or skip it
-- The AI never talks to Google. It only returns text; crm-google-business sends approved text with the login's own token,
-- after reading the review once more (already answered on Google, or deleted -> nothing is sent).
-- A review is text from a stranger: it is handed to the AI as data, the AI has no tools, and every draft passes the same
-- code checks whatever the review said. Re-runnable. Needs 139.

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS public.gbp_config (
  key text PRIMARY KEY, value text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid);
INSERT INTO public.gbp_config (key, value) VALUES
  ('reply_ai', 'on'),               -- the AI drafts replies
  ('reply_auto', 'on'),             -- approved drafts for good reviews are sent without a person
  ('reply_auto_min_stars', '4'),    -- 4 or 5; 1-3 stars always wait for a person
  ('reply_daily_cap', '10'),        -- automatic replies per day, all profiles together
  ('reply_max_age_days', '30'),     -- older unanswered reviews are only drafted when someone asks
  ('reply_notes', ''),              -- the owner's guidance for the AI (tone, things to mention or avoid)
  ('reply_signature', ''),          -- e.g. "Team We One Aviation"
  ('reply_contact', '')             -- the only phone / email a reply may contain
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.gbp_reply (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  location_id uuid NOT NULL, review_id text NOT NULL, stars int,
  status text NOT NULL DEFAULT 'writing' CHECK (status IN ('writing', 'reviewing', 'needs_owner', 'queued', 'sent', 'failed', 'skipped')),
  source text NOT NULL DEFAULT 'ai' CHECK (source IN ('ai', 'owner')),
  draft text, problems jsonb NOT NULL DEFAULT '[]', flag text, reviewer_note text, note text, error text,
  rounds int NOT NULL DEFAULT 0, attempt int NOT NULL DEFAULT 0, send_tries int NOT NULL DEFAULT 0, auto boolean NOT NULL DEFAULT false,
  claimed_at timestamptz, decided_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz,
  UNIQUE (location_id, review_id),
  FOREIGN KEY (location_id, review_id) REFERENCES public.gbp_review (location_id, review_id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS idx_gbp_reply_status ON public.gbp_reply (status, updated_at);
ALTER TABLE public.gbp_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gbp_reply ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gbp_config, public.gbp_reply FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION crm_private.gbp_cfg(p_key text, p_default text DEFAULT NULL) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT value FROM public.gbp_config WHERE key = p_key), p_default) $$;

-- What a reply may never contain, whoever wrote the review and whatever it said. Returns the problems in plain words ([] = fine).
CREATE OR REPLACE FUNCTION crm_private.gbp_reply_check(p_text text, p_location uuid DEFAULT NULL, p_review text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := btrim(coalesce(p_text, '')); low text; bare text; contact text := lower(crm_private.gbp_cfg('reply_contact', '')); m text; out text[] := '{}';
BEGIN
  low := lower(t);
  IF length(t) < 30 THEN out := out || 'Too short (under 30 characters)'::text; END IF;
  IF length(t) > 600 THEN out := out || 'Too long (over 600 characters)'::text; END IF;
  IF t ~ '[\[\]{}<>]' OR low ~ '(lorem ipsum|\mxxx+\M|your name|business name|reviewer name|\minsert\M)' THEN out := out || 'Contains a placeholder or brackets'::text; END IF;
  FOR m IN SELECT lower(x[1]) FROM regexp_matches(t, '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g') x LOOP
    IF position(m IN contact) = 0 THEN out := out || 'Contains an email address that is not the saved contact'::text; EXIT; END IF;
  END LOOP;
  FOR m IN SELECT regexp_replace(x[1], '\D', '', 'g') FROM regexp_matches(t, '(\+?\d[\d\s().-]{5,}\d)', 'g') x LOOP
    IF length(m) >= 7 AND position(m IN regexp_replace(contact, '\D', '', 'g')) = 0 THEN out := out || 'Contains a phone number that is not the saved contact'::text; EXIT; END IF;
  END LOOP;
  bare := regexp_replace(low, '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}', ' ', 'g');
  IF bare ~ '(https?://|www\.|\m[a-z0-9-]{3,}\.(com|in|org|net|co|io)\M)' THEN out := out || 'Contains a link'::text; END IF;
  IF low ~ '\m(discount|coupon|cashback|refund\w*|compensat\w*|voucher|gift|free of cost|complimentary|special offer|offer code|\d+ ?% off)\M' THEN
    out := out || 'Offers money, a gift or a discount'::text; END IF;
  IF low ~ '(\mguarantee\w*|100 ?%|\massured (placement|job|result|pass|success)|sure-?shot)' THEN out := out || 'Makes a guarantee'::text; END IF;
  IF low ~ '\m(change|update|edit|remove|delete|revise|reconsider|take down)\M\W+(\w+\W+){0,4}(review|rating|stars?)\M' THEN out := out || 'Asks the person to change or remove the review'::text; END IF;
  IF low ~ '\m(fake (review|account|profile|id)s?|liar|lying|false (review|claim|statement|allegation)s?|defam\w*|legal (action|notice)|lawyer|court case|police complaint)\M' THEN out := out || 'Argues with or threatens the reviewer'::text; END IF;
  IF low ~ '(as an ai|language model|chatgpt|\mclaude\M|openai|anthropic|\mai[- ](generated|written|assistant)\M)' THEN out := out || 'Mentions AI'::text; END IF;
  IF length(t) - length(replace(t, '!', '')) > 2 OR t ~ '[A-Z]{2,}(\s+[A-Z]{2,}){3,}' THEN out := out || 'Shouts (capitals or too many exclamation marks)'::text; END IF;
  IF EXISTS (SELECT 1 FROM public.gbp_reply r WHERE r.status = 'sent' AND r.sent_at > now() - interval '90 days'
              AND (r.location_id, r.review_id) IS DISTINCT FROM (p_location, p_review)
              AND regexp_replace(lower(btrim(r.draft)), '\s+', ' ', 'g') = regexp_replace(low, '\s+', ' ', 'g')) THEN
    out := out || 'Same wording as an earlier reply'::text; END IF;
  RETURN to_jsonb(out);
END $$;

CREATE OR REPLACE FUNCTION crm_private.gbp_reply_log(p_action text, p_id bigint, p_extra jsonb DEFAULT '{}') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE 'INSERT INTO public.audit_log (actor, action, entity, payload) VALUES ($1, $2, $3, $4)'
      USING crm_private.current_employee_id(), p_action, 'gbp_reply', jsonb_build_object('id', p_id) || coalesce(p_extra, '{}');
  END IF;
END $$;

-- A review answered on Google itself needs no reply from here; an edited review gets a fresh draft.
CREATE OR REPLACE FUNCTION crm_private.gbp_review_changed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.reply IS NOT NULL AND OLD.reply IS NULL THEN
    UPDATE public.gbp_reply SET status = 'skipped', error = 'Answered on Google', claimed_at = NULL, updated_at = now()
     WHERE location_id = NEW.location_id AND review_id = NEW.review_id AND status NOT IN ('sent', 'skipped');
  ELSIF NEW.reply IS NULL AND (NEW.comment IS DISTINCT FROM OLD.comment OR NEW.stars IS DISTINCT FROM OLD.stars) THEN
    DELETE FROM public.gbp_reply WHERE location_id = NEW.location_id AND review_id = NEW.review_id AND status NOT IN ('sent');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_gbp_review_changed ON public.gbp_review;
CREATE TRIGGER trg_gbp_review_changed AFTER UPDATE ON public.gbp_review FOR EACH ROW EXECUTE FUNCTION crm_private.gbp_review_changed();

-- ---------------------------------------------------------------- AI helper (through crm-google-business, ADS agents token)
-- Hands out one step: a draft waiting for the Reviewer, else a review waiting for the Writer, else the newest unanswered review.
CREATE OR REPLACE FUNCTION public.svc_gbp_reply_next(p_roles text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.gbp_reply; rv record; role text; input jsonb; ctx jsonb; who text;
BEGIN
  IF NOT (coalesce(p_roles, '{}') @> ARRAY['gbp_reply_writer', 'gbp_reply_reviewer']) THEN RETURN NULL; END IF;
  IF crm_private.gbp_cfg('reply_ai', 'on') <> 'on' THEN RETURN NULL; END IF;
  -- a step given out three times without an answer goes to a person instead of going round forever
  UPDATE public.gbp_reply SET status = 'needs_owner', claimed_at = NULL, error = 'The AI could not finish this reply; write it by hand or ask again', updated_at = now()
   WHERE status IN ('writing', 'reviewing') AND attempt >= 3 AND (claimed_at IS NULL OR claimed_at < now() - interval '20 minutes');
  SELECT * INTO r FROM public.gbp_reply WHERE status IN ('reviewing', 'writing') AND (claimed_at IS NULL OR claimed_at < now() - interval '20 minutes')
   ORDER BY (status = 'reviewing') DESC, updated_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    INSERT INTO public.gbp_reply (location_id, review_id, stars)
    SELECT v.location_id, v.review_id, v.stars FROM public.gbp_review v JOIN public.gbp_location l ON l.id = v.location_id
     WHERE l.tracked AND v.reply IS NULL AND v.stars IS NOT NULL
       AND v.created_at > now() - make_interval(days => least(365, greatest(1, crm_private.gbp_cfg('reply_max_age_days', '30')::int)))
       AND NOT EXISTS (SELECT 1 FROM public.gbp_reply x WHERE x.location_id = v.location_id AND x.review_id = v.review_id)
     ORDER BY v.created_at DESC LIMIT 1
    ON CONFLICT (location_id, review_id) DO NOTHING RETURNING * INTO r;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;
  UPDATE public.gbp_reply SET attempt = attempt + 1, claimed_at = now() WHERE id = r.id RETURNING * INTO r;
  SELECT v.reviewer, v.stars, v.comment, v.created_at, coalesce(l.title, l.name) AS title, l.category, l.address INTO rv
    FROM public.gbp_review v JOIN public.gbp_location l ON l.id = v.location_id WHERE v.location_id = r.location_id AND v.review_id = r.review_id;
  who := NULLIF(split_part(btrim(coalesce(rv.reviewer, '')), ' ', 1), '');
  IF who IS NULL OR lower(coalesce(rv.reviewer, '')) = 'a google user' OR who !~ '^[[:alpha:]][[:alpha:]''.-]{1,29}$' THEN who := NULL; END IF;
  role := CASE r.status WHEN 'reviewing' THEN 'gbp_reply_reviewer' ELSE 'gbp_reply_writer' END;
  input := jsonb_build_object('review', jsonb_build_object('stars', rv.stars, 'text', left(coalesce(rv.comment, ''), 4000), 'first_name', who, 'date', rv.created_at::date));
  IF role = 'gbp_reply_reviewer' THEN
    input := input || jsonb_build_object('reply', r.draft);
  ELSE
    input := input || jsonb_build_object('previous_draft', r.draft, 'problems_to_fix', r.problems, 'owner_note', r.note);
  END IF;
  ctx := jsonb_build_object(
    'business', jsonb_build_object('name', rv.title, 'category', rv.category, 'address', rv.address),
    'guidance', NULLIF(crm_private.gbp_cfg('reply_notes', ''), ''), 'signature', NULLIF(crm_private.gbp_cfg('reply_signature', ''), ''),
    'contact', NULLIF(crm_private.gbp_cfg('reply_contact', ''), ''), 'max_chars', 600,
    'recent_replies', CASE WHEN role = 'gbp_reply_writer' THEN coalesce((SELECT jsonb_agg(z.draft) FROM (
        SELECT x.draft FROM public.gbp_reply x WHERE x.status = 'sent' AND x.location_id = r.location_id ORDER BY x.sent_at DESC LIMIT 5) z), '[]') ELSE NULL END);
  RETURN jsonb_build_object('run', jsonb_build_object('id', r.id, 'role', role, 'job', 'review_reply', 'attempt', r.attempt, 'input', input), 'context', jsonb_strip_nulls(ctx));
END $$;

-- The helper's answer. Writer: {reply, needs_owner?, reason?}. Reviewer: {verdict: approve|reject, problems?: [], risk?: low|high, notes?}.
CREATE OR REPLACE FUNCTION public.svc_gbp_reply_finish(p_id bigint, p_ok boolean, p_output jsonb DEFAULT NULL, p_error text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.gbp_reply; txt text; probs jsonb; auto_ok boolean; nxt text;
BEGIN
  SELECT * INTO r FROM public.gbp_reply WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR r.status NOT IN ('writing', 'reviewing') OR r.claimed_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'ignored', true); END IF;
  IF p_ok IS NOT TRUE OR p_output IS NULL OR jsonb_typeof(p_output) <> 'object' THEN
    UPDATE public.gbp_reply SET claimed_at = NULL, error = left(coalesce(p_error, 'No usable answer'), 300), updated_at = now(),
           status = CASE WHEN attempt >= 3 THEN 'needs_owner' ELSE status END WHERE id = p_id RETURNING status INTO nxt;
    RETURN jsonb_build_object('ok', true, 'status', nxt);
  END IF;
  IF r.status = 'writing' THEN
    txt := btrim(coalesce(p_output->>'reply', ''));
    IF txt = '' THEN       -- the Writer may hand a review to a person (threats, safety, legal, something only the owner can answer)
      UPDATE public.gbp_reply SET status = 'needs_owner', claimed_at = NULL, error = NULL, updated_at = now(),
             flag = left(coalesce(NULLIF(btrim(p_output->>'reason'), ''), 'The AI left this one to you'), 300) WHERE id = p_id;
      RETURN jsonb_build_object('ok', true, 'status', 'needs_owner');
    END IF;
    probs := crm_private.gbp_reply_check(txt, r.location_id, r.review_id);
    IF jsonb_array_length(probs) > 0 THEN
      nxt := CASE WHEN r.rounds + 1 >= 3 THEN 'needs_owner' ELSE 'writing' END;
      UPDATE public.gbp_reply SET status = nxt, draft = left(txt, 1500), problems = probs, rounds = rounds + 1, attempt = 0, claimed_at = NULL, error = NULL, updated_at = now() WHERE id = p_id;
      RETURN jsonb_build_object('ok', true, 'status', nxt, 'problems', probs);
    END IF;
    UPDATE public.gbp_reply SET status = 'reviewing', draft = txt, problems = '[]', rounds = rounds + 1, attempt = 0, claimed_at = NULL, error = NULL, updated_at = now(),
           flag = CASE WHEN lower(coalesce(p_output->>'needs_owner', '')) = 'true' THEN left(coalesce(NULLIF(btrim(p_output->>'reason'), ''), 'The AI asks you to look at this one'), 300) ELSE NULL END
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'reviewing');
  END IF;
  -- Reviewer
  IF lower(btrim(coalesce(p_output->>'verdict', ''))) = 'approve' THEN
    probs := crm_private.gbp_reply_check(r.draft, r.location_id, r.review_id);       -- settings may have changed since it was written
    IF jsonb_array_length(probs) > 0 THEN
      UPDATE public.gbp_reply SET status = 'needs_owner', problems = probs, claimed_at = NULL, attempt = 0, updated_at = now() WHERE id = p_id;
      RETURN jsonb_build_object('ok', true, 'status', 'needs_owner', 'problems', probs);
    END IF;
    auto_ok := crm_private.gbp_cfg('reply_auto', 'on') = 'on' AND r.source = 'ai' AND r.flag IS NULL AND r.note IS NULL
      AND coalesce(r.stars, 0) >= least(5, greatest(4, crm_private.gbp_cfg('reply_auto_min_stars', '4')::int))
      AND lower(coalesce(p_output->>'risk', 'low')) <> 'high';
    nxt := CASE WHEN auto_ok THEN 'queued' ELSE 'needs_owner' END;
    UPDATE public.gbp_reply SET status = nxt, auto = auto_ok, send_tries = 0, claimed_at = NULL, attempt = 0, error = NULL, updated_at = now(),
           reviewer_note = left(NULLIF(btrim(coalesce(p_output->>'notes', '')), ''), 300) WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', nxt);
  END IF;
  probs := coalesce((SELECT jsonb_agg(left(x, 200)) FROM (SELECT x FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(p_output->'problems') = 'array' THEN p_output->'problems' ELSE '[]'::jsonb END) x WHERE btrim(x) <> '' LIMIT 5) z), '["The Reviewer rejected it without a reason"]');
  nxt := CASE WHEN r.rounds >= 3 THEN 'needs_owner' ELSE 'writing' END;
  UPDATE public.gbp_reply SET status = nxt, problems = probs, claimed_at = NULL, attempt = 0, error = NULL, updated_at = now(),
         reviewer_note = left(NULLIF(btrim(coalesce(p_output->>'notes', '')), ''), 300) WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'status', nxt);
END $$;

CREATE OR REPLACE FUNCTION public.svc_gbp_reply_release(p_id bigint) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.gbp_reply SET claimed_at = NULL, attempt = greatest(0, attempt - 1) WHERE id = p_id AND status IN ('writing', 'reviewing') $$;

-- ---------------------------------------------------------------- sender (crm-google-business, job "reply")
-- Replies ready to go: a person's own sends first, then automatic ones up to the daily limit.
CREATE OR REPLACE FUNCTION public.svc_gbp_reply_queue(p_limit int DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cap int := least(50, greatest(1, crm_private.gbp_cfg('reply_daily_cap', '10')::int)); used int;
BEGIN
  SELECT count(*) INTO used FROM public.gbp_reply WHERE auto AND status = 'sent' AND sent_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata';
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(z)) FROM (
    SELECT q.id, q.connection_id, q.account, q.location, q.review_id, q.text FROM (
      SELECT r.id, l.connection_id, l.account, l.name AS location, r.review_id, r.draft AS text, r.auto, r.updated_at,
             row_number() OVER (PARTITION BY r.auto ORDER BY r.updated_at) AS n
        FROM public.gbp_reply r JOIN public.gbp_location l ON l.id = r.location_id
       WHERE r.status = 'queued' AND l.tracked AND btrim(coalesce(r.draft, '')) <> '') q
     WHERE NOT q.auto OR q.n <= greatest(0, cap - used)
     ORDER BY q.auto, q.updated_at LIMIT least(25, greatest(1, coalesce(p_limit, 10)))) z), '[]');
END $$;

-- What happened to one send. sent | skipped (answered or gone on Google) | retry (Google busy or not approved yet) | failed.
CREATE OR REPLACE FUNCTION public.svc_gbp_reply_result(p_id bigint, p_state text, p_error text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.gbp_reply;
BEGIN
  SELECT * INTO r FROM public.gbp_reply WHERE id = p_id AND status = 'queued' FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF p_state = 'sent' THEN
    UPDATE public.gbp_reply SET status = 'sent', sent_at = now(), error = NULL, updated_at = now() WHERE id = p_id;
    UPDATE public.gbp_review SET reply = r.draft, reply_at = now() WHERE location_id = r.location_id AND review_id = r.review_id;
  ELSIF p_state = 'skipped' THEN
    UPDATE public.gbp_reply SET status = 'skipped', error = left(coalesce(p_error, 'Nothing to answer'), 300), updated_at = now() WHERE id = p_id;
  ELSIF p_state = 'retry' THEN
    UPDATE public.gbp_reply SET send_tries = send_tries + 1, error = left(p_error, 300), updated_at = now(),
           status = CASE WHEN send_tries + 1 >= 12 THEN 'failed' ELSE 'queued' END WHERE id = p_id;
  ELSE
    UPDATE public.gbp_reply SET status = 'failed', error = left(coalesce(p_error, 'Google refused the reply'), 300), updated_at = now() WHERE id = p_id;
  END IF;
END $$;

-- ---------------------------------------------------------------- browser API
-- Reviews with the state of their reply. p_filter: all | unreplied | low (1-3 stars) | waiting (needs a person).
CREATE OR REPLACE FUNCTION public.api_gbp_reviews(p_location uuid DEFAULT NULL, p_filter text DEFAULT 'all', p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
    SELECT r.review_id, r.location_id, coalesce(l.title, l.name) AS profile, r.reviewer, r.stars, r.comment, r.created_at, r.updated_at, r.reply, r.reply_at,
           CASE WHEN a.id IS NULL THEN NULL ELSE jsonb_build_object('id', a.id, 'status', a.status, 'source', a.source, 'draft', a.draft, 'problems', a.problems,
             'flag', a.flag, 'note', a.reviewer_note, 'error', a.error, 'auto', a.auto, 'sent_at', a.sent_at, 'updated_at', a.updated_at) END AS ai
      FROM public.gbp_review r JOIN public.gbp_location l ON l.id = r.location_id
      LEFT JOIN public.gbp_reply a ON a.location_id = r.location_id AND a.review_id = r.review_id
     WHERE l.tracked AND (p_location IS NULL OR r.location_id = p_location)
       AND CASE coalesce(p_filter, 'all') WHEN 'unreplied' THEN r.reply IS NULL WHEN 'low' THEN r.stars <= 3
            WHEN 'waiting' THEN r.reply IS NULL AND a.status IN ('needs_owner', 'failed') ELSE true END
     ORDER BY r.created_at DESC NULLS LAST LIMIT least(500, greatest(1, coalesce(p_limit, 100)))) z);
END $$;

-- Settings, what is waiting, and when the AI helper was last seen.
CREATE OR REPLACE FUNCTION public.api_gbp_reply_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seen timestamptz;
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  IF to_regclass('public.ads_config') IS NOT NULL THEN
    BEGIN EXECUTE 'SELECT value::timestamptz FROM public.ads_config WHERE key = ''agents_last_seen''' INTO seen; EXCEPTION WHEN OTHERS THEN seen := NULL; END;
  END IF;
  RETURN jsonb_build_object(
    'settings', jsonb_build_object('ai', crm_private.gbp_cfg('reply_ai', 'on') = 'on', 'auto', crm_private.gbp_cfg('reply_auto', 'on') = 'on',
      'min_stars', crm_private.gbp_cfg('reply_auto_min_stars', '4')::int, 'daily_cap', crm_private.gbp_cfg('reply_daily_cap', '10')::int,
      'max_age_days', crm_private.gbp_cfg('reply_max_age_days', '30')::int, 'notes', crm_private.gbp_cfg('reply_notes', ''),
      'signature', crm_private.gbp_cfg('reply_signature', ''), 'contact', crm_private.gbp_cfg('reply_contact', '')),
    'counts', (SELECT jsonb_build_object(
      'needs_owner', count(*) FILTER (WHERE r.status = 'needs_owner'), 'failed', count(*) FILTER (WHERE r.status = 'failed'),
      'queued', count(*) FILTER (WHERE r.status = 'queued'), 'with_ai', count(*) FILTER (WHERE r.status IN ('writing', 'reviewing')),
      'sent_7d', count(*) FILTER (WHERE r.status = 'sent' AND r.sent_at > now() - interval '7 days'),
      'sent_auto_today', count(*) FILTER (WHERE r.status = 'sent' AND r.auto AND r.sent_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata'))
      FROM public.gbp_reply r JOIN public.gbp_location l ON l.id = r.location_id WHERE l.tracked),
    'helper_seen', seen, 'access', public.api_gbp_access());
END $$;

CREATE OR REPLACE FUNCTION public.api_gbp_reply_settings_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text; v text; me uuid := crm_private.current_employee_id();
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change how reviews are answered' USING ERRCODE = 'PT403'; END IF;
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RAISE EXCEPTION 'Nothing to save' USING ERRCODE = 'PT422'; END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(p) LOOP
    v := btrim(coalesce(v, ''));
    IF k IN ('ai', 'auto') THEN
      IF v NOT IN ('true', 'false') THEN RAISE EXCEPTION '% must be on or off', k USING ERRCODE = 'PT422'; END IF;
      v := CASE v WHEN 'true' THEN 'on' ELSE 'off' END;
    ELSIF k = 'min_stars' THEN
      IF v NOT IN ('4', '5') THEN RAISE EXCEPTION 'Automatic replies can start at 4 or 5 stars; 1 to 3 stars always wait for a person' USING ERRCODE = 'PT422'; END IF;
    ELSIF k = 'daily_cap' THEN
      IF v !~ '^\d{1,2}$' OR v::int NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'Automatic replies per day: 1 to 50' USING ERRCODE = 'PT422'; END IF;
    ELSIF k = 'max_age_days' THEN
      IF v !~ '^\d{1,3}$' OR v::int NOT BETWEEN 1 AND 365 THEN RAISE EXCEPTION 'Review age: 1 to 365 days' USING ERRCODE = 'PT422'; END IF;
    ELSIF k IN ('notes', 'signature', 'contact') THEN
      IF v ~ '[<>{}]' THEN RAISE EXCEPTION 'No brackets in %', k USING ERRCODE = 'PT422'; END IF;
      IF length(v) > (CASE k WHEN 'notes' THEN 1000 WHEN 'signature' THEN 60 ELSE 120 END) THEN RAISE EXCEPTION '% is too long', k USING ERRCODE = 'PT422'; END IF;
    ELSE
      RAISE EXCEPTION 'Unknown setting "%"', left(k, 40) USING ERRCODE = 'PT422';
    END IF;
    INSERT INTO public.gbp_config (key, value, updated_by) VALUES (CASE k WHEN 'min_stars' THEN 'reply_auto_min_stars' ELSE 'reply_' || k END, v, me)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = me;
  END LOOP;
  -- switching automatic sending off pulls back what the AI had queued by itself
  IF crm_private.gbp_cfg('reply_auto', 'on') <> 'on' THEN
    UPDATE public.gbp_reply SET status = 'needs_owner', auto = false, updated_at = now() WHERE status = 'queued' AND auto;
  END IF;
  PERFORM crm_private.gbp_reply_log('gbp_reply_settings', NULL, jsonb_build_object('keys', (SELECT jsonb_agg(key) FROM jsonb_object_keys(p) key)));
  RETURN (public.api_gbp_reply_status())->'settings';
END $$;

-- A person's own reply (or their edit of the AI's draft). p_send false = keep it as a draft.
CREATE OR REPLACE FUNCTION public.api_gbp_reply_write(p_location uuid, p_review text, p_text text, p_send boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := btrim(coalesce(p_text, '')); rv public.gbp_review; rid bigint; st text;
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can answer reviews' USING ERRCODE = 'PT403'; END IF;
  SELECT v.* INTO rv FROM public.gbp_review v JOIN public.gbp_location l ON l.id = v.location_id WHERE v.location_id = p_location AND v.review_id = p_review AND l.tracked;
  IF NOT FOUND THEN RAISE EXCEPTION 'That review is no longer in the list' USING ERRCODE = 'PT404'; END IF;
  IF rv.reply IS NOT NULL THEN RAISE EXCEPTION 'This review already has a reply on Google' USING ERRCODE = 'PT422'; END IF;
  IF length(t) < 2 THEN RAISE EXCEPTION 'Write the reply first' USING ERRCODE = 'PT422'; END IF;
  IF length(t) > 1500 THEN RAISE EXCEPTION 'Keep the reply under 1,500 characters' USING ERRCODE = 'PT422'; END IF;
  IF t ~ '[<>]' THEN RAISE EXCEPTION 'No < or > in a reply' USING ERRCODE = 'PT422'; END IF;
  st := CASE WHEN coalesce(p_send, true) THEN 'queued' ELSE 'needs_owner' END;
  INSERT INTO public.gbp_reply (location_id, review_id, stars, status, source, draft, decided_by)
  VALUES (p_location, p_review, rv.stars, st, 'owner', t, crm_private.current_employee_id())
  ON CONFLICT (location_id, review_id) DO UPDATE SET status = EXCLUDED.status, draft = EXCLUDED.draft, decided_by = EXCLUDED.decided_by, auto = false, send_tries = 0,
    source = CASE WHEN public.gbp_reply.draft IS NOT DISTINCT FROM EXCLUDED.draft THEN public.gbp_reply.source ELSE 'owner' END,
    problems = '[]', error = NULL, claimed_at = NULL, updated_at = now()
    WHERE public.gbp_reply.status <> 'sent'
  RETURNING id INTO rid;
  IF rid IS NULL THEN RAISE EXCEPTION 'This review was already answered from the CRM' USING ERRCODE = 'PT422'; END IF;
  PERFORM crm_private.gbp_reply_log(CASE st WHEN 'queued' THEN 'gbp_reply_send' ELSE 'gbp_reply_draft' END, rid);
  RETURN jsonb_build_object('id', rid, 'status', st);
END $$;

-- send | skip | rewrite (ask the AI again, optional note) | cancel (pull back before it is sent) | reopen | draft (ask the AI for a review that has none)
CREATE OR REPLACE FUNCTION public.api_gbp_reply_action(p_id bigint, p_action text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.gbp_reply; st text; v_note text := NULLIF(left(btrim(coalesce(p_note, '')), 300), '');
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can answer reviews' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO r FROM public.gbp_reply WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That reply is no longer there (the review may have been edited)' USING ERRCODE = 'PT404'; END IF;
  IF r.status = 'sent' THEN RAISE EXCEPTION 'This reply was already sent' USING ERRCODE = 'PT422'; END IF;
  IF v_note ~ '[<>{}]' THEN RAISE EXCEPTION 'No brackets in the note' USING ERRCODE = 'PT422'; END IF;
  CASE coalesce(p_action, '')
    WHEN 'send' THEN
      IF r.status NOT IN ('needs_owner', 'failed') OR btrim(coalesce(r.draft, '')) = '' THEN RAISE EXCEPTION 'There is no finished draft to send' USING ERRCODE = 'PT422'; END IF;
      st := 'queued';
      UPDATE public.gbp_reply SET status = st, auto = false, send_tries = 0, error = NULL, decided_by = crm_private.current_employee_id(), updated_at = now() WHERE id = p_id;
    WHEN 'skip' THEN
      st := 'skipped';
      UPDATE public.gbp_reply SET status = st, claimed_at = NULL, error = NULL, decided_by = crm_private.current_employee_id(), updated_at = now() WHERE id = p_id;
    WHEN 'rewrite' THEN
      IF crm_private.gbp_cfg('reply_ai', 'on') <> 'on' THEN RAISE EXCEPTION 'AI replies are switched off' USING ERRCODE = 'PT422'; END IF;
      st := 'writing';
      UPDATE public.gbp_reply SET status = st, source = 'ai', rounds = 0, attempt = 0, claimed_at = NULL, problems = '[]', flag = NULL, error = NULL, note = v_note, auto = false, updated_at = now() WHERE id = p_id;
    WHEN 'cancel' THEN
      IF r.status <> 'queued' THEN RAISE EXCEPTION 'It is not waiting to be sent' USING ERRCODE = 'PT422'; END IF;
      st := 'needs_owner';
      UPDATE public.gbp_reply SET status = st, auto = false, updated_at = now() WHERE id = p_id;
    WHEN 'reopen' THEN
      IF r.status <> 'skipped' THEN RAISE EXCEPTION 'It is not skipped' USING ERRCODE = 'PT422'; END IF;
      IF EXISTS (SELECT 1 FROM public.gbp_review v WHERE v.location_id = r.location_id AND v.review_id = r.review_id AND v.reply IS NOT NULL) THEN
        RAISE EXCEPTION 'This review already has a reply on Google' USING ERRCODE = 'PT422'; END IF;
      st := CASE WHEN btrim(coalesce(r.draft, '')) <> '' THEN 'needs_owner' ELSE 'writing' END;
      UPDATE public.gbp_reply SET status = st, rounds = 0, attempt = 0, claimed_at = NULL, error = NULL, updated_at = now() WHERE id = p_id;
    ELSE RAISE EXCEPTION 'Unknown action' USING ERRCODE = 'PT422';
  END CASE;
  PERFORM crm_private.gbp_reply_log('gbp_reply_' || p_action, p_id);
  RETURN jsonb_build_object('id', p_id, 'status', st);
END $$;

-- Ask the AI for a draft for a review that has none (for example one older than the automatic window).
CREATE OR REPLACE FUNCTION public.api_gbp_reply_request(p_location uuid, p_review text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rv public.gbp_review; rid bigint; v_note text := NULLIF(left(btrim(coalesce(p_note, '')), 300), '');
BEGIN
  IF NOT crm_private.gbp_can_run() THEN RAISE EXCEPTION 'Only Admin or approvers can answer reviews' USING ERRCODE = 'PT403'; END IF;
  IF crm_private.gbp_cfg('reply_ai', 'on') <> 'on' THEN RAISE EXCEPTION 'AI replies are switched off' USING ERRCODE = 'PT422'; END IF;
  IF v_note ~ '[<>{}]' THEN RAISE EXCEPTION 'No brackets in the note' USING ERRCODE = 'PT422'; END IF;
  SELECT v.* INTO rv FROM public.gbp_review v JOIN public.gbp_location l ON l.id = v.location_id WHERE v.location_id = p_location AND v.review_id = p_review AND l.tracked;
  IF NOT FOUND THEN RAISE EXCEPTION 'That review is no longer in the list' USING ERRCODE = 'PT404'; END IF;
  IF rv.reply IS NOT NULL THEN RAISE EXCEPTION 'This review already has a reply on Google' USING ERRCODE = 'PT422'; END IF;
  IF rv.stars IS NULL THEN RAISE EXCEPTION 'This review has no rating to answer' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.gbp_reply (location_id, review_id, stars, note) VALUES (p_location, p_review, rv.stars, v_note)
  ON CONFLICT (location_id, review_id) DO NOTHING RETURNING id INTO rid;
  IF rid IS NULL THEN RAISE EXCEPTION 'A reply for this review is already in progress' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('id', rid, 'status', 'writing');
END $$;

-- ---------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION crm_private.gbp_cfg(text, text), crm_private.gbp_reply_check(text, uuid, text), crm_private.gbp_reply_log(text, bigint, jsonb),
  crm_private.gbp_review_changed() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_gbp_reviews(uuid, text, int), public.api_gbp_reply_status(), public.api_gbp_reply_settings_save(jsonb),
  public.api_gbp_reply_write(uuid, text, text, boolean), public.api_gbp_reply_action(bigint, text, text), public.api_gbp_reply_request(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_gbp_reviews(uuid, text, int), public.api_gbp_reply_status(), public.api_gbp_reply_settings_save(jsonb),
  public.api_gbp_reply_write(uuid, text, text, boolean), public.api_gbp_reply_action(bigint, text, text), public.api_gbp_reply_request(uuid, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_gbp_reply_next(text[]), public.svc_gbp_reply_finish(bigint, boolean, jsonb, text), public.svc_gbp_reply_release(bigint),
  public.svc_gbp_reply_queue(int), public.svc_gbp_reply_result(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_gbp_reply_next(text[]), public.svc_gbp_reply_finish(bigint, boolean, jsonb, text), public.svc_gbp_reply_release(bigint),
  public.svc_gbp_reply_queue(int), public.svc_gbp_reply_result(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------- schedule
-- New reviews are looked for every 3 hours (the nightly run reads everything else); approved replies go out within 10 minutes.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-gbp-reviews', 'crm-gbp-reply');
    PERFORM cron.schedule('crm-gbp-reviews', '20 */3 * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-google-business',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["reviews", "reply"]}'::jsonb, timeout_milliseconds := 150000)
      WHERE EXISTS (SELECT 1 FROM public.gbp_location WHERE tracked) $job$);
    PERFORM cron.schedule('crm-gbp-reply', '*/10 * * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-google-business',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["reply"]}'::jsonb, timeout_milliseconds := 150000)
      WHERE EXISTS (SELECT 1 FROM public.gbp_reply WHERE status = 'queued') $job$);
  END IF;
END $$;
