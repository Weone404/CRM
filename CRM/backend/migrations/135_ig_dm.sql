-- 135: Instagram comment-to-DM runs on the CRM (moved from Reel Studio, whose cloud project is restricted).
--  * Someone comments on a recent We One Aviation post: the account sends them ONE private reply (Instagram "private replies":
--    one message per comment, within 7 days of it) and, under the comment, a short public "check your inbox" reply.
--    One DM per person; spam gets nothing; angry or "fraud" comments are left for a person. Someone who messages the
--    account first gets the same message once. A mobile number sent in the chat becomes a CRM lead (svc_content_dm_lead, 123).
--  * Runs every 2 minutes (edge function ig-dm, cron crm-ig-dm) with the Instagram Login token saved in Vault as
--    ads_instagram_login_token (Connections & keys / Vault name). Nothing runs until the token is saved and ig_dm.on is true.
--  * Never twice: a comment is claimed in ig_dm_log (primary key) BEFORE anything is sent, and a comment that already has a
--    reply from the account (Reel Studio answered it before the move) is recorded as 'imported' and skipped.
--  * Hourly cap (ig_dm.cap, default 60 sends an hour, at most 200) counted in ig_dm_send.
-- Re-runnable. Down: 135_ig_dm_down.sql.

CREATE TABLE IF NOT EXISTS public.ig_dm_log (
  comment_id text PRIMARY KEY,
  media_id text,
  username text,
  person text,
  text text,
  state text NOT NULL CHECK (state IN ('sending', 'sent', 'public', 'skipped', 'failed', 'imported')),
  reason text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz);
CREATE INDEX IF NOT EXISTS ig_dm_log_created ON public.ig_dm_log (created_at DESC);
ALTER TABLE public.ig_dm_log ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.ig_dm_person (
  person text PRIMARY KEY,                 -- Instagram-scoped id, or u:<username> when Instagram gave no id
  igsid text,
  username text,
  source text CHECK (source IN ('comment', 'dm')),
  dm_at timestamptz,                       -- when our one message reached them
  last_in_at timestamptz,                  -- their newest message we have read
  phone text,
  lead_id uuid,
  note text,
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ig_dm_person_username ON public.ig_dm_person (lower(username));
ALTER TABLE public.ig_dm_person ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.ig_dm_send (
  id bigserial PRIMARY KEY,
  kind text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ig_dm_send_created ON public.ig_dm_send (created_at DESC);
ALTER TABLE public.ig_dm_send ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.ig_dm_log, public.ig_dm_person, public.ig_dm_send FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.ig_dm_log, public.ig_dm_person, public.ig_dm_send TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.ig_dm_send_id_seq TO service_role;

-- the token is one more ADS secret (Settings > Connections & keys show it like the others; Vault name ads_instagram_login_token)
CREATE OR REPLACE FUNCTION crm_private.ads_secret_names() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['GOOGLE_ADS_DEVELOPER_TOKEN','GOOGLE_ADS_CLIENT_ID','GOOGLE_ADS_CLIENT_SECRET','GOOGLE_ADS_REFRESH_TOKEN',
               'GOOGLE_ADS_LOGIN_CUSTOMER_ID','META_APP_ID','META_APP_SECRET','META_ACCESS_TOKEN',
               'META_WEBHOOK_VERIFY_TOKEN','META_PAGE_TOKEN','GOOGLE_SITE_REFRESH_TOKEN','INSTAGRAM_LOGIN_TOKEN']
$$;

-- settings: on, message, public replies, thanks, cap, inbox, crm; plus what the runs record (state, note, user, started_at ...)
INSERT INTO public.ads_config (key, value) VALUES ('ig_dm', jsonb_build_object(
  'on', true, 'mode', 'universal',
  'message', E'Hi {name}! Thanks for your comment ✈️\n\nWe One Aviation helps you become a Commercial Pilot: an eligibility check, the DGCA medical and a full CPL roadmap.\n\nWant a free career counselling call? Send your mobile number here, or call / WhatsApp 93555 66991. No commitment.',
  'thanks', E'Thank you! Our counsellor will call you on this number soon. ✈️',
  'public_reply', true,
  'public_replies', jsonb_build_array('Boarding pass is in your inbox 🎫', 'Boarding pass is in your inbox ✈️', 'Boarding pass is in your inbox 🛫'),
  'cap', 60, 'inbox', true, 'crm', true, 'state', 'not_connected',
  'note', 'Save the Instagram Login token (ads_instagram_login_token) to start.')::text)
ON CONFLICT (key) DO NOTHING;

-- one read for each run: settings + token (the token never leaves the edge function)
CREATE OR REPLACE FUNCTION public.svc_ig_dm_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'cfg', coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}'),
    'token', (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.name = 'ads_instagram_login_token' LIMIT 1),
    'token_at', (SELECT s.updated_at FROM vault.secrets s WHERE s.name = 'ads_instagram_login_token' LIMIT 1),
    'sent_last_hour', (SELECT count(*) FROM public.ig_dm_send WHERE created_at > now() - interval '1 hour'))
$$;

-- what a run learned (state, note, user id, inbox_at ...): merged, so the owner's settings are never overwritten
CREATE OR REPLACE FUNCTION public.svc_ig_dm_cfg(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value)
  VALUES ('ig_dm', (coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}')
                    || (coalesce(p, '{}') - 'on' - 'message' - 'thanks' - 'public_reply' - 'public_replies' - 'cap' - 'inbox' - 'crm'))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

-- a refreshed long-lived token replaces the saved one (Instagram Login tokens last 60 days; the run refreshes them)
CREATE OR REPLACE FUNCTION public.svc_ig_dm_token_save(p_token text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE sid uuid; v text := btrim(coalesce(p_token, ''));
BEGIN
  IF v = '' OR v ~ '\s' OR length(v) > 4000 THEN RAISE EXCEPTION 'bad token' USING ERRCODE = 'PT422'; END IF;
  SELECT id INTO sid FROM vault.secrets WHERE name = 'ads_instagram_login_token';
  IF sid IS NULL THEN PERFORM vault.create_secret(v, 'ads_instagram_login_token', 'CRM ADS: INSTAGRAM_LOGIN_TOKEN');
  ELSE PERFORM vault.update_secret(sid, v); END IF;
END $$;

-- Admin: status for the owner (no token), and saving the settings
CREATE OR REPLACE FUNCTION public.api_ig_dm_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'settings', coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}'),
    'token_saved', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'ads_instagram_login_token'),
    'last_24h', (SELECT jsonb_build_object('sent', count(*) FILTER (WHERE state = 'sent'), 'public_only', count(*) FILTER (WHERE state = 'public'),
                   'skipped', count(*) FILTER (WHERE state = 'skipped'), 'failed', count(*) FILTER (WHERE state = 'failed'),
                   'imported', count(*) FILTER (WHERE state = 'imported'))
                 FROM public.ig_dm_log WHERE created_at > now() - interval '24 hours'),
    'people', (SELECT count(*) FROM public.ig_dm_person WHERE dm_at IS NOT NULL),
    'phones', (SELECT count(*) FROM public.ig_dm_person WHERE phone IS NOT NULL),
    'recent', (SELECT coalesce(jsonb_agg(x ORDER BY x->>'at' DESC), '[]') FROM (
                 SELECT jsonb_build_object('at', l.created_at, 'username', l.username, 'state', l.state, 'reason', l.reason, 'error', l.error) x
                   FROM public.ig_dm_log l ORDER BY l.created_at DESC LIMIT 20) q));
END $$;

CREATE OR REPLACE FUNCTION public.api_ig_dm_settings_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cur jsonb := coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}'); nxt jsonb := cur; pubs jsonb;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p ? 'on' THEN nxt := nxt || jsonb_build_object('on', coalesce((p->>'on')::boolean, false)); END IF;
  IF p ? 'message' THEN
    IF length(btrim(coalesce(p->>'message', ''))) NOT BETWEEN 10 AND 900 THEN RAISE EXCEPTION 'Message of 10 to 900 characters' USING ERRCODE = 'PT422'; END IF;
    nxt := nxt || jsonb_build_object('message', btrim(p->>'message'));
  END IF;
  IF p ? 'thanks' THEN nxt := nxt || jsonb_build_object('thanks', nullif(left(btrim(coalesce(p->>'thanks', '')), 500), '')); END IF;
  IF p ? 'public_reply' THEN nxt := nxt || jsonb_build_object('public_reply', coalesce((p->>'public_reply')::boolean, true)); END IF;
  IF p ? 'public_replies' THEN
    SELECT coalesce(jsonb_agg(left(btrim(x), 120)), '[]') INTO pubs FROM jsonb_array_elements_text(coalesce(p->'public_replies', '[]')) x WHERE btrim(x) <> '';
    nxt := nxt || jsonb_build_object('public_replies', pubs);
  END IF;
  IF p ? 'cap' THEN nxt := nxt || jsonb_build_object('cap', greatest(1, least(200, coalesce(nullif(p->>'cap', '')::int, 60)))); END IF;
  IF p ? 'inbox' THEN nxt := nxt || jsonb_build_object('inbox', coalesce((p->>'inbox')::boolean, true)); END IF;
  IF p ? 'crm' THEN nxt := nxt || jsonb_build_object('crm', coalesce((p->>'crm')::boolean, true)); END IF;
  IF nxt->>'state' = 'needs_permission' THEN nxt := nxt || jsonb_build_object('state', 'check'); END IF;   -- saving again retries
  INSERT INTO public.ads_config (key, value) VALUES ('ig_dm', nxt::text) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.ads_log('ig_dm_saved', 'config', 'ig_dm', '{}');
  RETURN jsonb_build_object('saved', true);
END $$;

REVOKE ALL ON FUNCTION public.svc_ig_dm_work(), public.svc_ig_dm_cfg(jsonb), public.svc_ig_dm_token_save(text),
  public.api_ig_dm_status(), public.api_ig_dm_settings_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ig_dm_work(), public.svc_ig_dm_cfg(jsonb), public.svc_ig_dm_token_save(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_status(), public.api_ig_dm_settings_save(jsonb) TO authenticated;

-- every 2 minutes; the function does nothing (and calls nobody) until the token is saved and ig_dm.on is true
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ig-dm';
    PERFORM cron.schedule('crm-ig-dm', '*/2 * * * *', $c$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ig-dm',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{}'::jsonb, timeout_milliseconds := 110000) $c$);
  END IF;
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '135') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
