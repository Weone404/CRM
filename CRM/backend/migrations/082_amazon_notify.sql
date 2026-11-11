-- 082: Instant alerts from the business email (HIOX SMTP, port 465 SSL) and phone notifications (installable CRM app, Web Push).
-- Run after 081. Re-runnable.
--  * SMTP settings live in amazon_config 'smtp' (no password); the password is in Vault 'crm_smtp_password'.
--  * Web Push keys (VAPID) are made once by the amazon-notify Edge Function and kept in Vault 'crm_vapid_keys';
--    only the public key is in amazon_config 'vapid_public'.
--  * New alerts and Claude replies wake amazon-notify through pg_net; a 10-minute cron is the safety net.
--  * If the business email is off or fails, alerts stay unsent by email, so the hourly Gmail task still sends them.

-- ---------------------------------------------------------------- tables / columns
ALTER TABLE public.amazon_alerts ADD COLUMN IF NOT EXISTS pushed_at timestamptz;
UPDATE public.amazon_alerts SET pushed_at = now() WHERE pushed_at IS NULL;
ALTER TABLE public.amazon_claude_requests ADD COLUMN IF NOT EXISTS pushed_at timestamptz;
UPDATE public.amazon_claude_requests SET pushed_at = now() WHERE pushed_at IS NULL AND status = 'answered';

CREATE TABLE IF NOT EXISTS public.amazon_push_subs (
  id bigserial PRIMARY KEY,
  employee_id uuid NOT NULL REFERENCES public.employee(id) ON DELETE CASCADE,
  endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL,
  auth text NOT NULL,
  device text,
  fails int NOT NULL DEFAULT 0,
  last_ok_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS amazon_push_subs_emp ON public.amazon_push_subs (employee_id);
ALTER TABLE public.amazon_push_subs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.amazon_push_subs FROM anon, authenticated;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION crm_private.vault_put(p_name text, p_value text, p_desc text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE sid uuid;
BEGIN
  SELECT id INTO sid FROM vault.secrets WHERE name = p_name;
  IF sid IS NULL THEN PERFORM vault.create_secret(p_value, p_name, p_desc);
  ELSE PERFORM vault.update_secret(sid, p_value); END IF;
END $$;
REVOKE ALL ON FUNCTION crm_private.vault_put(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION crm_private.amz_smtp_ready() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT (value::jsonb->>'enabled')::boolean FROM public.amazon_config WHERE key = 'smtp'), false)
     AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_smtp_password')
     AND jsonb_array_length(coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'alert_emails'), '[]')) > 0
$$;
REVOKE ALL ON FUNCTION crm_private.amz_smtp_ready() FROM PUBLIC, anon, authenticated;

-- Wakes amazon-notify (async through pg_net). Never fails the caller.
CREATE OR REPLACE FUNCTION crm_private.amz_notify_kick() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_regnamespace('net') IS NULL THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.amazon_push_subs) AND NOT crm_private.amz_smtp_ready() THEN RETURN NULL; END IF;
  BEGIN
    EXECUTE $q$SELECT net.http_post(
      url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-notify',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := '{"action": "deliver"}'::jsonb, timeout_milliseconds := 30000)$q$;
  EXCEPTION WHEN OTHERS THEN NULL;   -- the 10-minute cron will deliver
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION crm_private.amz_notify_kick() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS amz_alert_notify ON public.amazon_alerts;
CREATE TRIGGER amz_alert_notify AFTER INSERT ON public.amazon_alerts
  FOR EACH STATEMENT EXECUTE FUNCTION crm_private.amz_notify_kick();
DROP TRIGGER IF EXISTS amz_reply_notify ON public.amazon_claude_requests;
CREATE TRIGGER amz_reply_notify AFTER UPDATE OF status ON public.amazon_claude_requests
  FOR EACH ROW WHEN (NEW.status = 'answered' AND OLD.status IS DISTINCT FROM 'answered' AND NEW.kind IN ('chat', 'fix', 'report'))
  EXECUTE FUNCTION crm_private.amz_notify_kick();

-- ---------------------------------------------------------------- browser API: business email (SMTP)
-- p_cfg NULL = read. Save (Admin): {host, port, username, from_name, enabled, password?}. Password is write-only.
CREATE OR REPLACE FUNCTION public.api_amz_smtp(p_cfg jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c jsonb; host text; port int; usr text; nm text; pw text;
BEGIN
  PERFORM crm_private.amz_require_view();
  IF p_cfg IS NOT NULL THEN
    PERFORM crm_private.amz_require_admin();
    IF jsonb_typeof(p_cfg) <> 'object' THEN RAISE EXCEPTION 'Send the email settings' USING ERRCODE = 'PT422'; END IF;
    host := lower(trim(coalesce(p_cfg->>'host', '')));
    port := CASE WHEN coalesce(p_cfg->>'port', '') ~ '^\d{2,5}$' THEN (p_cfg->>'port')::int END;
    usr := lower(trim(coalesce(p_cfg->>'username', '')));
    nm := trim(coalesce(p_cfg->>'from_name', ''));
    pw := p_cfg->>'password';
    IF host !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' OR length(host) > 120 THEN
      RAISE EXCEPTION 'Mail server name is not valid (e.g. host2.dnsinweb.com)' USING ERRCODE = 'PT422';
    END IF;
    IF port IS NULL OR port NOT IN (465, 2465, 2525) THEN
      RAISE EXCEPTION 'Use port 465 (SSL). Ports 25 and 587 are blocked by Supabase.' USING ERRCODE = 'PT422';
    END IF;
    IF usr !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN RAISE EXCEPTION 'Email address is not valid' USING ERRCODE = 'PT422'; END IF;
    IF length(nm) > 60 OR nm ~ '[\r\n<>"]' THEN RAISE EXCEPTION 'Sender name: up to 60 characters, no < > or quotes' USING ERRCODE = 'PT422'; END IF;
    IF pw IS NOT NULL AND pw <> '' THEN
      IF length(pw) > 200 OR pw ~ '[\r\n]' THEN RAISE EXCEPTION 'Password is not valid' USING ERRCODE = 'PT422'; END IF;
      PERFORM crm_private.vault_put('crm_smtp_password', pw, 'CRM alert email (SMTP) password');
    END IF;
    IF coalesce((p_cfg->>'enabled')::boolean, false) AND NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_smtp_password') THEN
      RAISE EXCEPTION 'Enter the email password first' USING ERRCODE = 'PT422';
    END IF;
    c := jsonb_build_object('host', host, 'port', port, 'username', usr, 'from_name', nullif(nm, ''),
                            'enabled', coalesce((p_cfg->>'enabled')::boolean, false));
    INSERT INTO public.amazon_config (key, value) VALUES ('smtp', c::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    PERFORM crm_private.amz_log('smtp_saved', 'settings', NULL, jsonb_build_object('host', host, 'enabled', c->'enabled',
      'password_changed', pw IS NOT NULL AND pw <> ''));   -- never the password
  END IF;
  c := coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'smtp'),
                '{"host": "host2.dnsinweb.com", "port": 465, "username": "info@weoneaviation.in", "from_name": "CRM Alerts", "enabled": false}');
  RETURN c || jsonb_build_object(
    'password_set', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_smtp_password'),
    'last_test', (SELECT value::jsonb FROM public.amazon_config WHERE key = 'smtp_test'),
    'ready', crm_private.amz_smtp_ready());
END $$;

-- ---------------------------------------------------------------- browser API: phone notifications
CREATE OR REPLACE FUNCTION public.api_amz_push_status(p_endpoint text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id();
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object(
    'vapid_public', (SELECT value FROM public.amazon_config WHERE key = 'vapid_public'),
    'this_device', p_endpoint IS NOT NULL AND EXISTS (SELECT 1 FROM public.amazon_push_subs WHERE endpoint = p_endpoint AND employee_id = me),
    'my_devices', (SELECT count(*) FROM public.amazon_push_subs WHERE employee_id = me),
    'email_ready', crm_private.amz_smtp_ready());
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_push_subscribe(p_sub jsonb, p_device text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id(); ep text := p_sub->>'endpoint';
  k1 text := p_sub->'keys'->>'p256dh'; k2 text := p_sub->'keys'->>'auth';
BEGIN
  PERFORM crm_private.amz_require_view();
  IF me IS NULL THEN RAISE EXCEPTION 'Sign in again' USING ERRCODE = 'PT401'; END IF;
  IF ep IS NULL OR ep !~ '^https://[^\s]+$' OR length(ep) > 1000 OR coalesce(k1, '') !~ '^[A-Za-z0-9_=-]{40,200}$'
     OR coalesce(k2, '') !~ '^[A-Za-z0-9_=-]{8,64}$' THEN
    RAISE EXCEPTION 'This browser sent an invalid notification subscription' USING ERRCODE = 'PT422';
  END IF;
  INSERT INTO public.amazon_push_subs AS s (employee_id, endpoint, p256dh, auth, device)
  VALUES (me, ep, k1, k2, left(p_device, 80))
  ON CONFLICT (endpoint) DO UPDATE SET employee_id = me, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
    device = coalesce(EXCLUDED.device, s.device), fails = 0;
  DELETE FROM public.amazon_push_subs WHERE employee_id = me AND id NOT IN (
    SELECT id FROM public.amazon_push_subs WHERE employee_id = me ORDER BY created_at DESC LIMIT 10);
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.api_amz_push_unsubscribe(p_endpoint text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  DELETE FROM public.amazon_push_subs WHERE endpoint = p_endpoint AND employee_id = crm_private.current_employee_id();
  RETURN jsonb_build_object('ok', true);
END $$;

-- Who is calling (used by amazon-notify for the test buttons).
CREATE OR REPLACE FUNCTION public.api_amz_notify_me() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.amz_require_view();
  RETURN jsonb_build_object('employee_id', crm_private.current_employee_id(), 'is_admin', crm_private.is_admin());
END $$;

-- ---------------------------------------------------------------- service API for amazon-notify
CREATE OR REPLACE FUNCTION public.svc_amz_notify_config() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'smtp', (SELECT value::jsonb FROM public.amazon_config WHERE key = 'smtp'),
    'smtp_password', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_smtp_password'),
    'smtp_ready', crm_private.amz_smtp_ready(),
    'recipients', coalesce((SELECT value::jsonb FROM public.amazon_config WHERE key = 'alert_emails'), '[]'),
    'vapid_keys', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_vapid_keys'),
    'vapid_public', (SELECT value FROM public.amazon_config WHERE key = 'vapid_public'))
$$;

-- First caller wins; returns the keys that are actually stored.
CREATE OR REPLACE FUNCTION public.svc_amz_vapid_init(p_keys text, p_public text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('crm_vapid_keys'));
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_vapid_keys') THEN
    IF p_public !~ '^[A-Za-z0-9_-]{80,100}$' OR p_keys IS NULL OR length(p_keys) > 4000 THEN
      RAISE EXCEPTION 'Invalid keys';
    END IF;
    PERFORM vault.create_secret(p_keys, 'crm_vapid_keys', 'CRM phone notifications (Web Push VAPID keys)');
    INSERT INTO public.amazon_config (key, value) VALUES ('vapid_public', p_public)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  END IF;
  RETURN jsonb_build_object('vapid_keys', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_vapid_keys'),
                            'vapid_public', (SELECT value FROM public.amazon_config WHERE key = 'vapid_public'));
END $$;

-- Claims everything waiting to be delivered (each item once). Email items are claimed only when the
-- business email is ready; otherwise they stay for the hourly Gmail task.
CREATE OR REPLACE FUNCTION public.svc_amz_notify_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pushes jsonb; mails jsonb; replies jsonb; has_subs boolean := EXISTS (SELECT 1 FROM public.amazon_push_subs);
BEGIN
  IF has_subs THEN
    WITH x AS (UPDATE public.amazon_alerts SET pushed_at = now()
                WHERE pushed_at IS NULL AND created_at > now() - interval '12 hours' RETURNING id, kind, title, body, link, created_at)
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY created_at), '[]') INTO pushes FROM x;
    WITH x AS (UPDATE public.amazon_claude_requests r SET pushed_at = now()
                WHERE r.status = 'answered' AND r.pushed_at IS NULL AND r.kind IN ('chat', 'fix', 'report')
                  AND r.answered_at > now() - interval '2 hours' AND r.asked_by IS NOT NULL
                RETURNING r.id, r.kind, r.sku, r.asked_by, left(r.answer, 300) AS answer, left(r.question, 120) AS question)
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO replies FROM x;
  END IF;
  IF crm_private.amz_smtp_ready() THEN
    WITH x AS (UPDATE public.amazon_alerts SET emailed_at = now()
                WHERE emailed_at IS NULL AND created_at > now() - interval '1 day' RETURNING id, kind, title, body, link, created_at)
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY created_at), '[]') INTO mails FROM x;
  END IF;
  RETURN jsonb_build_object('push', coalesce(pushes, '[]'), 'replies', coalesce(replies, '[]'), 'email', coalesce(mails, '[]'),
    'subs', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'employee_id', employee_id, 'endpoint', endpoint,
                        'keys', jsonb_build_object('p256dh', p256dh, 'auth', auth))) FROM public.amazon_push_subs), '[]'));
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_push_subs_for(p_employee uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'employee_id', employee_id, 'endpoint', endpoint,
           'keys', jsonb_build_object('p256dh', p256dh, 'auth', auth))), '[]')
    FROM public.amazon_push_subs WHERE employee_id = p_employee
$$;

-- Email failed: give the alerts back so the hourly Gmail task sends them.
CREATE OR REPLACE FUNCTION public.svc_amz_notify_unclaim_email(p_ids bigint[]) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.amazon_alerts SET emailed_at = NULL WHERE id = ANY (p_ids)
$$;

-- Push results: ok -> reset; gone -> delete; other failures -> count, delete after 5.
CREATE OR REPLACE FUNCTION public.svc_amz_push_result(p_ok bigint[], p_gone bigint[], p_failed bigint[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.amazon_push_subs SET fails = 0, last_ok_at = now() WHERE id = ANY (coalesce(p_ok, '{}'));
  DELETE FROM public.amazon_push_subs WHERE id = ANY (coalesce(p_gone, '{}'));
  UPDATE public.amazon_push_subs SET fails = fails + 1 WHERE id = ANY (coalesce(p_failed, '{}'));
  DELETE FROM public.amazon_push_subs WHERE fails >= 5;
END $$;

CREATE OR REPLACE FUNCTION public.svc_amz_smtp_test_save(p_ok boolean, p_detail text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.amazon_config (key, value)
  VALUES ('smtp_test', jsonb_build_object('ok', p_ok, 'detail', left(p_detail, 300), 'at', now())::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
$$;

-- Decisions digest only when the business email is ready (else the Gmail task does it).
CREATE OR REPLACE FUNCTION public.svc_amz_notify_digest() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.amz_smtp_ready() THEN RETURN jsonb_build_object('items', '[]'::jsonb, 'waiting_total', 0); END IF;
  RETURN public.svc_amz_decisions_for_email();
END $$;

-- ---------------------------------------------------------------- grants
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.api_amz_smtp(jsonb)', 'public.api_amz_push_status(text)', 'public.api_amz_push_subscribe(jsonb, text)',
    'public.api_amz_push_unsubscribe(text)', 'public.api_amz_notify_me()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.svc_amz_notify_config()', 'public.svc_amz_vapid_init(text, text)', 'public.svc_amz_notify_claim()',
    'public.svc_amz_notify_unclaim_email(bigint[])', 'public.svc_amz_push_result(bigint[], bigint[], bigint[])',
    'public.svc_amz_smtp_test_save(boolean, text)', 'public.svc_amz_notify_digest()', 'public.svc_amz_push_subs_for(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- cron (only where pg_cron exists)
DO $outer$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN RETURN; END IF;
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-amazon-notify', 'crm-amazon-digest');
  -- Safety net: deliver anything the instant wake-up missed.
  PERFORM cron.schedule('crm-amazon-notify', '*/10 * * * *', $job$
    SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-notify',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := '{"action": "deliver"}'::jsonb, timeout_milliseconds := 30000)
  $job$);
  -- Waiting decisions by email: hourly 9:05 AM to 8:05 PM IST (03:35-14:35 UTC).
  PERFORM cron.schedule('crm-amazon-digest', '35 3-14 * * *', $job$
    SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/amazon-notify',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
      body := '{"action": "digest"}'::jsonb, timeout_milliseconds := 30000)
  $job$);
END $outer$;
