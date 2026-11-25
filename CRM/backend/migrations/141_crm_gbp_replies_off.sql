-- 141 Google My Business: review replies stay built, but are not in use.
-- The business already answers its reviews elsewhere, so the CRM must not write or send replies. Everything from 140 stays
-- (tables, checks, queues, settings), behind one switch: gbp_config.reply_enabled, off by default.
--   off  the Reviews tab is a read-only list; the AI helper is given nothing; the send queue is always empty
--   on   UPDATE public.gbp_config SET value = 'on' WHERE key IN ('reply_enabled', 'reply_ai', 'reply_auto');
-- Re-runnable: the first run switches everything off; later runs leave whatever was chosen since. Needs 140.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.gbp_config WHERE key = 'reply_enabled') THEN
    INSERT INTO public.gbp_config (key, value) VALUES ('reply_enabled', 'off');
    UPDATE public.gbp_config SET value = 'off', updated_at = now() WHERE key IN ('reply_ai', 'reply_auto');
    -- anything the AI had queued by itself is pulled back; nothing is sent while the switch is off
    UPDATE public.gbp_reply SET status = 'needs_owner', auto = false, updated_at = now() WHERE status = 'queued' AND auto;
  END IF;
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
    'enabled', crm_private.gbp_cfg('reply_enabled', 'off') = 'on', 'helper_seen', seen, 'access', public.api_gbp_access());
END $$;

-- ---------------------------------------------------------------- sender (crm-google-business, job "reply")
-- Replies ready to go: a person's own sends first, then automatic ones up to the daily limit.
CREATE OR REPLACE FUNCTION public.svc_gbp_reply_queue(p_limit int DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cap int := least(50, greatest(1, crm_private.gbp_cfg('reply_daily_cap', '10')::int)); used int;
BEGIN
  IF crm_private.gbp_cfg('reply_enabled', 'off') <> 'on' THEN RETURN '[]'::jsonb; END IF;      -- the feature is not in use: nothing is ever sent
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
