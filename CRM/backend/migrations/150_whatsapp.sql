-- 150: WhatsApp (sidebar > Growth > WhatsApp). Database-driven WhatsApp automation on Meta's WhatsApp Cloud API.
--
--   New lead (lead / ads_lead insert)  ->  wa_queue 'welcome' (one per person, never twice)  ->  wa-worker sends the
--   approved template  ->  replies arrive on wa-webhook (through the Cloudflare gateway)  ->  the flow (wa_flow_step +
--   wa_reply_rule, edited in the CRM) answers  ->  anything it can't handle goes to a person in WhatsApp > Inbox.
--
-- The only touch on existing tables: AFTER INSERT triggers on public.lead and public.ads_lead. Their body is wrapped in
-- BEGIN ... EXCEPTION, so a WhatsApp problem can never block or roll back a lead. Nothing in Leads, Academy, ADS or
-- Amazon is changed. Secrets live in Supabase Vault (wa_access_token, wa_app_secret, wa_verify_token) and are never
-- returned to the browser. Re-runnable: safe to paste into the SQL Editor again.

-- =====================================================================================================================
-- 1. Tables
-- =====================================================================================================================
CREATE TABLE IF NOT EXISTS public.wa_access (
  employee_id uuid PRIMARY KEY REFERENCES public.employee(id) ON DELETE CASCADE,
  can_manage boolean NOT NULL DEFAULT false,            -- Setup, Settings, Flow, Templates (otherwise: chats only)
  added_by uuid, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.wa_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled boolean NOT NULL DEFAULT false,               -- Go live
  test_mode boolean NOT NULL DEFAULT true,              -- only test_numbers get messages
  test_numbers text[] NOT NULL DEFAULT '{}',
  pause_all boolean NOT NULL DEFAULT false,             -- stops the bot and follow-ups; people can still reply by hand
  quiet_start time NOT NULL DEFAULT '20:00', quiet_end time NOT NULL DEFAULT '09:00',   -- Asia/Kolkata, follow-ups only
  followup_hours int[] NOT NULL DEFAULT '{24,72}',      -- hours after the welcome
  max_followups int NOT NULL DEFAULT 2 CHECK (max_followups BETWEEN 0 AND 5),
  daily_new_contact_cap int NOT NULL DEFAULT 200 CHECK (daily_new_contact_cap BETWEEN 1 AND 100000),
  auto_sources jsonb NOT NULL DEFAULT '{"website": true, "meta_form": true, "google": true, "charter": true, "justdial": false, "whatsapp_inbound": true, "ctwa": false}',
  templates jsonb NOT NULL DEFAULT '{"aviation": "weone_welcome", "charter": "bmc_welcome", "justdial": "weone_justdial_ack", "followup_1": "weone_followup_1", "followup_2": "weone_followup_2"}',
  counsellor_phone text NOT NULL DEFAULT '9355566991',
  brochure_url text, brochure_name text NOT NULL DEFAULT 'We One Aviation brochure.pdf',
  rates jsonb NOT NULL DEFAULT '{"marketing": 0.8631, "utility": 0.115, "service": 0.115, "free_service": 1000, "gst": 18}',
  gateway_url text,                                     -- Cloudflare gateway address (Meta's Callback URL when set)
  webhook_seen_at timestamptz, gateway_seen_at timestamptz, last_inbound_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid);
INSERT INTO public.wa_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.wa_number (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL DEFAULT 'We One Aviation',
  brands text[] NOT NULL DEFAULT '{aviation,charter}',
  phone_number_id text UNIQUE, waba_id text, app_id text,
  display_phone text, verified_name text, name_status text, quality_rating text, messaging_limit text, status text,
  is_default boolean NOT NULL DEFAULT true,
  last_checked_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.wa_contact (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa_id text NOT NULL UNIQUE CHECK (wa_id ~ '^[0-9]{8,15}$'),           -- country code + number, e.g. 919876543210
  phone10 text GENERATED ALWAYS AS (CASE WHEN wa_id ~ '^91[0-9]{10}$' THEN right(wa_id, 10) END) STORED,
  name text, profile_name text,
  lead_id uuid, ads_lead_id uuid,                                        -- plain ids: organic and ads leads stay separate
  first_source text, brand text NOT NULL DEFAULT 'aviation',
  opted_in boolean NOT NULL DEFAULT false, opt_in_source text, opt_in_at timestamptz,
  opted_out boolean NOT NULL DEFAULT false, opted_out_at timestamptz, opt_out_reason text,
  not_on_whatsapp boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS wa_contact_lead_idx ON public.wa_contact (lead_id) WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS wa_contact_ads_idx ON public.wa_contact (ads_lead_id) WHERE ads_lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS wa_contact_phone10_idx ON public.wa_contact (phone10);

CREATE TABLE IF NOT EXISTS public.wa_conversation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id uuid NOT NULL REFERENCES public.wa_contact(id) ON DELETE CASCADE,
  brand text NOT NULL DEFAULT 'aviation' CHECK (brand IN ('aviation', 'charter')),
  status text NOT NULL DEFAULT 'bot' CHECK (status IN ('bot', 'human', 'closed')),
  source text,
  current_step text, answers jsonb NOT NULL DEFAULT '{}', miss_count int NOT NULL DEFAULT 0,
  assigned_to uuid,
  welcomed_at timestamptz, followups_sent int NOT NULL DEFAULT 0, next_followup_at timestamptz,
  paused_until timestamptz, needs_human_since timestamptz,
  taken_over_at timestamptz,                             -- when staff took the chat (bot replies queued before it are dropped)
  last_inbound_at timestamptz, last_outbound_at timestamptz, last_message_at timestamptz, last_preview text,
  unread int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id, brand));
ALTER TABLE public.wa_conversation ADD COLUMN IF NOT EXISTS taken_over_at timestamptz;
CREATE INDEX IF NOT EXISTS wa_conv_recent_idx ON public.wa_conversation (last_message_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS wa_conv_followup_idx ON public.wa_conversation (next_followup_at) WHERE next_followup_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.wa_message (
  id bigserial PRIMARY KEY,
  conversation_id uuid NOT NULL REFERENCES public.wa_conversation(id) ON DELETE CASCADE,
  direction text NOT NULL CHECK (direction IN ('in', 'out')),
  wamid text UNIQUE,                                     -- Meta's id: a repeated webhook can never add a message twice
  kind text NOT NULL DEFAULT 'text',
  body text, template_name text, payload jsonb NOT NULL DEFAULT '{}', media_path text,
  status text NOT NULL DEFAULT 'sent' CHECK (status IN ('received', 'queued', 'sent', 'delivered', 'read', 'failed')),
  error_code int, error_text text, category text,
  sent_by text,                                          -- 'bot', 'system' or an employee id
  created_at timestamptz NOT NULL DEFAULT now(), status_at timestamptz);
CREATE INDEX IF NOT EXISTS wa_message_conv_idx ON public.wa_message (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS wa_message_day_idx ON public.wa_message (created_at);

CREATE TABLE IF NOT EXISTS public.wa_queue (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('welcome', 'followup', 'reply', 'manual')),
  conversation_id uuid NOT NULL REFERENCES public.wa_conversation(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL UNIQUE,
  item jsonb NOT NULL,                                   -- {type: template|text|buttons|list|document, ...}
  run_after timestamptz NOT NULL DEFAULT now(),
  attempts int NOT NULL DEFAULT 0,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sending', 'done', 'dead', 'skipped')),
  last_error text, wamid text, created_by text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS wa_queue_due_idx ON public.wa_queue (run_after) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS wa_queue_conv_idx ON public.wa_queue (conversation_id, kind);

CREATE TABLE IF NOT EXISTS public.wa_template (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (name ~ '^[a-z0-9_]+$' AND length(name) <= 512), language text NOT NULL DEFAULT 'en',
  category text NOT NULL DEFAULT 'UTILITY' CHECK (category IN ('UTILITY', 'MARKETING')),
  purpose text NOT NULL DEFAULT 'other',
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 1024), footer text,
  buttons jsonb NOT NULL DEFAULT '[]',                   -- ["I'm a student", ...] quick replies (max 3 here)
  meta_id text, meta_status text NOT NULL DEFAULT 'draft', rejection_reason text, synced_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, language));

CREATE TABLE IF NOT EXISTS public.wa_flow_step (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand text NOT NULL CHECK (brand IN ('aviation', 'charter')),
  key text NOT NULL CHECK (key ~ '^[a-z0-9_]{1,40}$'),
  title text,
  kind text NOT NULL DEFAULT 'text' CHECK (kind IN ('text', 'buttons', 'list', 'document')),
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 1024),
  buttons jsonb NOT NULL DEFAULT '[]',                   -- [{id, title, goto, action}]
  capture text,                                          -- store any typed answer under answers[capture]
  next_key text,                                         -- where a captured answer goes next
  auto_next text,                                        -- send this step right after (e.g. brochure -> counselling)
  handoff boolean NOT NULL DEFAULT false,                -- reaching this step hands the chat to a person
  is_start boolean NOT NULL DEFAULT false, sort int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (brand, key));

CREATE TABLE IF NOT EXISTS public.wa_reply_rule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand text CHECK (brand IS NULL OR brand IN ('aviation', 'charter')),   -- NULL: both
  step_key text,                                         -- NULL: any step (global)
  match_type text NOT NULL CHECK (match_type IN ('button', 'exact', 'contains', 'synonym')),
  patterns text[] NOT NULL CHECK (cardinality(patterns) BETWEEN 1 AND 50),
  priority int NOT NULL DEFAULT 0,
  action text NOT NULL CHECK (action IN ('goto', 'handoff', 'optout', 'book_counselling', 'send_brochure', 'restart', 'end')),
  goto_key text, reply_text text, active boolean NOT NULL DEFAULT true, seed_key text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.wa_note (
  id bigserial PRIMARY KEY,
  conversation_id uuid NOT NULL REFERENCES public.wa_conversation(id) ON DELETE CASCADE,
  employee_id uuid, body text NOT NULL CHECK (length(btrim(body)) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.wa_event (
  id bigserial PRIMARY KEY,
  conversation_id uuid REFERENCES public.wa_conversation(id) ON DELETE CASCADE,
  kind text NOT NULL, detail jsonb NOT NULL DEFAULT '{}', actor text,
  notify boolean NOT NULL DEFAULT false, pushed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS wa_event_conv_idx ON public.wa_event (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS wa_event_push_idx ON public.wa_event (created_at) WHERE notify AND pushed_at IS NULL;
CREATE INDEX IF NOT EXISTS wa_event_kind_idx ON public.wa_event (kind, created_at);

CREATE TABLE IF NOT EXISTS public.wa_error (
  id bigserial PRIMARY KEY, place text NOT NULL, detail text, ctx jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.wa_webhook_raw (
  id bigserial PRIMARY KEY,
  sha text NOT NULL UNIQUE,                              -- same delivery twice (Meta retries, gateway replays) = one row
  body jsonb NOT NULL, via text NOT NULL DEFAULT 'direct',
  received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz,
  attempts int NOT NULL DEFAULT 0, last_error text);
CREATE INDEX IF NOT EXISTS wa_raw_todo_idx ON public.wa_webhook_raw (received_at) WHERE processed_at IS NULL;

CREATE TABLE IF NOT EXISTS public.wa_setup_check (
  step text PRIMARY KEY, ok boolean NOT NULL DEFAULT false, detail text, manual boolean NOT NULL DEFAULT false,
  checked_at timestamptz NOT NULL DEFAULT now(), checked_by uuid);

-- Locked down: the browser only uses the api_wa_* functions below, Edge Functions the svc_wa_* ones.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['wa_access', 'wa_settings', 'wa_number', 'wa_contact', 'wa_conversation', 'wa_message', 'wa_queue',
    'wa_template', 'wa_flow_step', 'wa_reply_rule', 'wa_note', 'wa_event', 'wa_error', 'wa_webhook_raw', 'wa_setup_check'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $$;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- =====================================================================================================================
-- 2. Helpers
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION crm_private.wa_can_view() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (SELECT 1 FROM public.wa_access a WHERE a.employee_id = crm_private.current_employee_id())
$$;
CREATE OR REPLACE FUNCTION crm_private.wa_can_manage() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.is_admin() OR EXISTS (SELECT 1 FROM public.wa_access a WHERE a.employee_id = crm_private.current_employee_id() AND a.can_manage)
$$;
CREATE OR REPLACE FUNCTION crm_private.wa_require(p_manage boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_manage AND NOT crm_private.wa_can_manage() THEN
    RAISE EXCEPTION 'You do not have permission to change WhatsApp settings' USING ERRCODE = 'PT403';
  END IF;
  IF NOT crm_private.wa_can_view() THEN
    RAISE EXCEPTION 'You do not have access to WhatsApp' USING ERRCODE = 'PT403';
  END IF;
END $$;

-- Any Indian or international phone -> WhatsApp id (digits with country code). NULL when it can't be a phone.
CREATE OR REPLACE FUNCTION crm_private.wa_wa_id(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN d ~ '^[6-9][0-9]{9}$' THEN '91' || d
    WHEN d ~ '^0[6-9][0-9]{9}$' THEN '91' || right(d, 10)
    WHEN d ~ '^91[6-9][0-9]{9}$' THEN d
    WHEN d ~ '^0091[6-9][0-9]{9}$' THEN right(d, 12)
    WHEN btrim(coalesce(p, '')) LIKE '+%' AND d ~ '^[1-9][0-9]{7,14}$' THEN d
    ELSE NULL END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x
$$;

-- Which lead source a CRM lead counts as (keys of wa_settings.auto_sources).
CREATE OR REPLACE FUNCTION crm_private.wa_source_of(p_utm text, p_segment text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN lower(coalesce(p_utm, '')) = 'justdial' THEN 'justdial'
    WHEN lower(coalesce(p_utm, '')) = 'whatsapp' THEN 'whatsapp_inbound'
    WHEN coalesce(p_segment, '') = 'charter' THEN 'charter'
    WHEN lower(coalesce(p_utm, '')) IN ('facebook', 'instagram', 'meta', 'fb', 'ig') THEN 'meta_form'
    WHEN lower(coalesce(p_utm, '')) LIKE 'google%' THEN 'google'
    ELSE 'website' END
$$;

CREATE OR REPLACE FUNCTION crm_private.wa_first_name(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(nullif(initcap(split_part(btrim(regexp_replace(coalesce(p, ''), '[^[:alpha:] ]', ' ', 'g')), ' ', 1)), ''), 'there')
$$;

CREATE OR REPLACE FUNCTION crm_private.wa_api_version() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF to_regclass('public.ads_config') IS NOT NULL THEN
    EXECUTE $q$SELECT nullif(value, '') FROM public.ads_config WHERE key = 'meta_api_version'$q$ INTO v;   -- one version for all Meta calls
  END IF;
  RETURN coalesce(v, 'v26.0');
END $$;

CREATE OR REPLACE FUNCTION crm_private.wa_secret(p_name text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.name = 'wa_' || p_name LIMIT 1
$$;

CREATE OR REPLACE FUNCTION crm_private.wa_log(p_conv uuid, p_kind text, p_detail jsonb DEFAULT '{}', p_notify boolean DEFAULT false, p_actor text DEFAULT 'system')
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.wa_event (conversation_id, kind, detail, notify, actor) VALUES (p_conv, p_kind, coalesce(p_detail, '{}'), p_notify, p_actor)
$$;

-- Wake wa-worker now (instead of waiting up to a minute). Never fails the caller.
CREATE OR REPLACE FUNCTION crm_private.wa_kick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_regnamespace('net') IS NULL THEN RETURN; END IF;
  BEGIN
    EXECUTE $q$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/wa-worker',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"reason": "kick"}'::jsonb, timeout_milliseconds := 60000) $q$;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END $$;

-- =====================================================================================================================
-- 3. New lead -> contact, conversation and (when allowed) one welcome
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION crm_private.wa_intake(p_kind text, p_id uuid, p_name text, p_phone text, p_source text, p_brand text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.wa_settings; wid text; c public.wa_contact; conv uuid; weak boolean := p_source IN ('justdial');
  v_brand text := CASE WHEN p_brand = 'charter' THEN 'charter' ELSE 'aviation' END;
BEGIN
  wid := crm_private.wa_wa_id(p_phone);
  IF wid IS NULL THEN
    PERFORM crm_private.wa_log(NULL, 'skip_invalid_phone', jsonb_build_object('kind', p_kind, 'id', p_id, 'source', p_source));
    RETURN NULL;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('wa|' || wid));          -- same person from two sources at once -> one contact
  INSERT INTO public.wa_contact (wa_id, name, lead_id, ads_lead_id, first_source, brand, opted_in, opt_in_source, opt_in_at)
  VALUES (wid, left(nullif(btrim(p_name), ''), 120), CASE WHEN p_kind = 'lead' THEN p_id END, CASE WHEN p_kind = 'ads_lead' THEN p_id END,
          p_source, v_brand, NOT weak, CASE WHEN NOT weak THEN p_source END, CASE WHEN NOT weak THEN now() END)
  ON CONFLICT (wa_id) DO UPDATE SET
    name = coalesce(public.wa_contact.name, EXCLUDED.name),
    lead_id = coalesce(EXCLUDED.lead_id, public.wa_contact.lead_id),
    ads_lead_id = coalesce(EXCLUDED.ads_lead_id, public.wa_contact.ads_lead_id),
    opted_in = public.wa_contact.opted_in OR EXCLUDED.opted_in,
    opt_in_source = coalesce(public.wa_contact.opt_in_source, EXCLUDED.opt_in_source),
    opt_in_at = coalesce(public.wa_contact.opt_in_at, EXCLUDED.opt_in_at),
    updated_at = now()
  RETURNING * INTO c;
  INSERT INTO public.wa_conversation (contact_id, brand, source) VALUES (c.id, v_brand, p_source)
  ON CONFLICT (contact_id, brand) DO UPDATE SET updated_at = now(), source = coalesce(public.wa_conversation.source, EXCLUDED.source)
  RETURNING id INTO conv;
  PERFORM crm_private.wa_log(conv, 'lead_in', jsonb_build_object('kind', p_kind, 'id', p_id, 'source', p_source));

  IF p_source = 'whatsapp_inbound' THEN RETURN conv; END IF;      -- they wrote first: the flow answers them
  SELECT * INTO s FROM public.wa_settings WHERE id;
  IF NOT coalesce(s.enabled, false) THEN PERFORM crm_private.wa_log(conv, 'skip_not_live'); RETURN conv; END IF;
  IF NOT coalesce((s.auto_sources ->> p_source)::boolean, false)
     OR (v_brand = 'charter' AND NOT coalesce((s.auto_sources ->> 'charter')::boolean, false)) THEN
    PERFORM crm_private.wa_log(conv, 'skip_source_off', jsonb_build_object('source', p_source)); RETURN conv;
  END IF;
  IF c.opted_out THEN PERFORM crm_private.wa_log(conv, 'skip_opted_out'); RETURN conv; END IF;
  IF c.not_on_whatsapp THEN PERFORM crm_private.wa_log(conv, 'skip_not_on_whatsapp'); RETURN conv; END IF;
  IF EXISTS (SELECT 1 FROM public.wa_queue q WHERE q.conversation_id = conv AND q.kind = 'welcome'
               AND q.state IN ('pending', 'sending', 'done') AND q.created_at > now() - interval '30 days')
     OR EXISTS (SELECT 1 FROM public.wa_conversation v WHERE v.id = conv AND v.last_inbound_at > now() - interval '24 hours') THEN
    PERFORM crm_private.wa_log(conv, 'skip_recent', jsonb_build_object('source', p_source)); RETURN conv;
  END IF;
  INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item, created_by)
  VALUES ('welcome', conv, 'welcome:' || p_kind || ':' || p_id,
          jsonb_build_object('type', 'template', 'purpose', CASE WHEN p_source = 'justdial' THEN 'justdial' ELSE v_brand END), 'system')
  ON CONFLICT (idempotency_key) DO NOTHING;
  PERFORM crm_private.wa_kick();
  RETURN conv;
END $$;

CREATE OR REPLACE FUNCTION crm_private.wa_on_lead() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  BEGIN
    PERFORM crm_private.wa_intake('lead', NEW.id, NEW.name, NEW.phone, crm_private.wa_source_of(NEW.utm_source, NEW.segment), NEW.segment);
  EXCEPTION WHEN OTHERS THEN
    BEGIN INSERT INTO public.wa_error (place, detail, ctx) VALUES ('lead_trigger', left(SQLERRM, 500), jsonb_build_object('lead_id', NEW.id));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION crm_private.wa_on_ads_lead() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE ft jsonb; src text;
BEGIN
  BEGIN
    IF coalesce(NEW.quarantined, false) THEN RETURN NULL; END IF;  -- spam / test leads are never messaged
    ft := coalesce(NEW.first_touch, '{}');
    src := CASE
      WHEN ft ->> 'meta_source' = 'ctwa' THEN 'ctwa'
      WHEN ft ? 'meta_source' OR lower(coalesce(ft ->> 'utm_source', '')) IN ('facebook', 'instagram', 'meta', 'fb', 'ig') THEN 'meta_form'
      WHEN lower(coalesce(ft ->> 'utm_source', '')) LIKE 'google%' OR ft ? 'gclid' THEN 'google'
      ELSE 'website' END;
    PERFORM crm_private.wa_intake('ads_lead', NEW.id, NEW.name, NEW.phone_e164, src, CASE WHEN NEW.pipeline = 'charter' THEN 'charter' ELSE 'aviation' END);
  EXCEPTION WHEN OTHERS THEN
    BEGIN INSERT INTO public.wa_error (place, detail, ctx) VALUES ('ads_lead_trigger', left(SQLERRM, 500), jsonb_build_object('ads_lead_id', NEW.id));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS wa_lead_in ON public.lead;
CREATE TRIGGER wa_lead_in AFTER INSERT ON public.lead FOR EACH ROW EXECUTE FUNCTION crm_private.wa_on_lead();
DO $$
BEGIN
  IF to_regclass('public.ads_lead') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS wa_ads_lead_in ON public.ads_lead;
    CREATE TRIGGER wa_ads_lead_in AFTER INSERT ON public.ads_lead FOR EACH ROW EXECUTE FUNCTION crm_private.wa_on_ads_lead();
  END IF;
END $$;

-- =====================================================================================================================
-- 4. Service functions (Edge Functions only, service_role)
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION public.svc_wa_secrets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'token', crm_private.wa_secret('access_token'), 'app_secret', crm_private.wa_secret('app_secret'),
    'verify_token', crm_private.wa_secret('verify_token'), 'version', crm_private.wa_api_version(),
    'phone_number_id', n.phone_number_id, 'waba_id', n.waba_id, 'app_id', n.app_id)
  FROM (SELECT 1) one LEFT JOIN LATERAL (SELECT * FROM public.wa_number ORDER BY is_default DESC, created_at LIMIT 1) n ON true
$$;

CREATE OR REPLACE FUNCTION public.svc_wa_webhook_seen(p_via text DEFAULT 'direct') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.wa_settings SET webhook_seen_at = now(),
    gateway_seen_at = CASE WHEN p_via = 'gateway' THEN now() ELSE gateway_seen_at END WHERE id
$$;

-- Store a webhook delivery before anything else. NULL = already stored (a repeat).
CREATE OR REPLACE FUNCTION public.svc_wa_raw_add(p_body jsonb, p_sha text, p_via text DEFAULT 'direct') RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid bigint;
BEGIN
  INSERT INTO public.wa_webhook_raw (sha, body, via) VALUES (p_sha, p_body, coalesce(p_via, 'direct'))
  ON CONFLICT (sha) DO NOTHING RETURNING id INTO nid;
  UPDATE public.wa_settings SET webhook_seen_at = now(),
    gateway_seen_at = CASE WHEN p_via = 'gateway' THEN now() ELSE gateway_seen_at END WHERE id;
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION public.svc_wa_raw_pending(p_limit int DEFAULT 20) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'body', r.body) ORDER BY r.id), '[]')
  FROM (SELECT id, body FROM public.wa_webhook_raw
         WHERE processed_at IS NULL AND attempts < 20 AND received_at < now() - interval '20 seconds'
         ORDER BY id LIMIT greatest(1, least(p_limit, 100))) r
$$;

CREATE OR REPLACE FUNCTION public.svc_wa_raw_done(p_id bigint, p_error text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.wa_webhook_raw SET
    processed_at = CASE WHEN p_error IS NULL THEN now() END,
    attempts = attempts + CASE WHEN p_error IS NULL THEN 0 ELSE 1 END,
    last_error = left(p_error, 500)
  WHERE id = p_id
$$;

-- Delivery receipts. Status only moves forward (sent -> delivered -> read); failed always sticks.
CREATE OR REPLACE FUNCTION public.svc_wa_status(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; m public.wa_message; n int := 0; code int; c public.wa_contact;
  rank_of CONSTANT jsonb := '{"queued": 0, "sent": 1, "delivered": 2, "read": 3, "failed": 9}';
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    SELECT * INTO m FROM public.wa_message WHERE wamid = it ->> 'wamid' FOR UPDATE;
    CONTINUE WHEN NOT FOUND OR NOT (rank_of ? (it ->> 'status'));
    CONTINUE WHEN m.status = 'failed' OR (rank_of ->> (it ->> 'status'))::int <= coalesce((rank_of ->> m.status)::int, 0);
    code := nullif(it ->> 'error_code', '')::int;
    UPDATE public.wa_message SET status = it ->> 'status', status_at = now(),
      error_code = coalesce(code, error_code), error_text = coalesce(left(it ->> 'error_text', 500), error_text),
      category = coalesce(it ->> 'category', category)
    WHERE id = m.id;
    n := n + 1;
    IF it ->> 'status' = 'failed' THEN
      SELECT ct.* INTO c FROM public.wa_contact ct JOIN public.wa_conversation v ON v.contact_id = ct.id WHERE v.id = m.conversation_id;
      IF code = 131026 THEN                                 -- not on WhatsApp / can't receive: a person should call
        UPDATE public.wa_contact SET not_on_whatsapp = true, updated_at = now() WHERE id = c.id;
        UPDATE public.wa_conversation SET status = 'human', needs_human_since = coalesce(needs_human_since, now()), updated_at = now()
         WHERE id = m.conversation_id;
        PERFORM crm_private.wa_log(m.conversation_id, 'call_needed', jsonb_build_object('reason', 'Not reachable on WhatsApp', 'code', code), true);
      ELSIF code = 131049 THEN                              -- Meta's per-person marketing limit: no retry, no alarm
        PERFORM crm_private.wa_log(m.conversation_id, 'marketing_limit', jsonb_build_object('code', code));
      ELSE
        PERFORM crm_private.wa_log(m.conversation_id, 'send_failed', jsonb_build_object('code', code, 'text', left(it ->> 'error_text', 300)), true);
      END IF;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- Engine input for one conversation: state, contact, the brand's flow and rules, settings the flow uses.
CREATE OR REPLACE FUNCTION crm_private.wa_ctx(p_conv uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'conversation', to_jsonb(v) || jsonb_build_object('window_open', v.last_inbound_at > now() - interval '24 hours'),
    'contact', to_jsonb(c),
    'steps', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.sort, s.key) FROM public.wa_flow_step s WHERE s.brand = v.brand), '[]'),
    'rules', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.priority DESC, r.created_at) FROM public.wa_reply_rule r
                        WHERE r.active AND (r.brand IS NULL OR r.brand = v.brand)), '[]'),
    'vars', jsonb_build_object('name', crm_private.wa_first_name(coalesce(c.name, c.profile_name)),
                               'counsellor_phone', st.counsellor_phone,
                               'brand', CASE WHEN v.brand = 'charter' THEN 'Book My Charter' ELSE 'We One Aviation' END),
    'brochure', jsonb_build_object('url', st.brochure_url, 'name', st.brochure_name))
  FROM public.wa_conversation v JOIN public.wa_contact c ON c.id = v.contact_id CROSS JOIN public.wa_settings st
  WHERE v.id = p_conv AND st.id
$$;

-- A message from a person. Stores it once, keeps the chat state, returns what the flow needs.
CREATE OR REPLACE FUNCTION public.svc_wa_inbound(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  wid text := regexp_replace(coalesce(p ->> 'from', ''), '\D', '', 'g'); c public.wa_contact; conv uuid; v_brand text;
  isnew boolean := false; s public.wa_settings; lid uuid; prev public.wa_conversation;
BEGIN
  IF wid !~ '^[0-9]{8,15}$' OR coalesce(p ->> 'wamid', '') = '' THEN RETURN jsonb_build_object('skip', 'bad message'); END IF;
  IF EXISTS (SELECT 1 FROM public.wa_message WHERE wamid = p ->> 'wamid') THEN RETURN jsonb_build_object('duplicate', true); END IF;
  PERFORM pg_advisory_xact_lock(hashtext('wa|' || wid));
  SELECT * INTO s FROM public.wa_settings WHERE id;
  SELECT * INTO c FROM public.wa_contact WHERE wa_id = wid;
  IF NOT FOUND THEN
    isnew := true;
    INSERT INTO public.wa_contact (wa_id, name, profile_name, first_source, opted_in, opt_in_source, opt_in_at)
    VALUES (wid, left(nullif(p ->> 'profile_name', ''), 120), left(nullif(p ->> 'profile_name', ''), 120),
            CASE WHEN p ? 'referral' THEN 'ctwa' ELSE 'whatsapp_inbound' END, true, 'messaged_us', now())
    RETURNING * INTO c;
    -- A new person who wrote to us becomes a lead (Leads > We One Aviation), when switched on.
    IF coalesce((s.auto_sources ->> 'whatsapp_inbound')::boolean, false) AND c.phone10 IS NOT NULL THEN
      BEGIN
        INSERT INTO public.lead (name, phone, utm_source, utm_medium, status, dedup_key)
        VALUES (coalesce(c.name, 'WhatsApp ' || c.phone10), c.phone10, 'whatsapp', CASE WHEN p ? 'referral' THEN 'ctwa' ELSE 'direct' END,
                'new', '+91' || c.phone10)
        ON CONFLICT (dedup_key) DO NOTHING RETURNING id INTO lid;
        IF lid IS NULL THEN SELECT id INTO lid FROM public.lead WHERE dedup_key = '+91' || c.phone10; END IF;
        UPDATE public.wa_contact SET lead_id = coalesce(lead_id, lid) WHERE id = c.id RETURNING * INTO c;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.wa_error (place, detail, ctx) VALUES ('inbound_lead', left(SQLERRM, 500), jsonb_build_object('wa_id', wid));
      END;
    END IF;
  ELSE
    UPDATE public.wa_contact SET profile_name = coalesce(nullif(p ->> 'profile_name', ''), profile_name),
      name = coalesce(name, nullif(p ->> 'profile_name', '')), not_on_whatsapp = false, updated_at = now()
    WHERE id = c.id RETURNING * INTO c;
  END IF;
  -- The chat they are answering: the one we wrote in last (a person can be in both Aviation and Charter).
  SELECT * INTO prev FROM public.wa_conversation WHERE contact_id = c.id
   ORDER BY greatest(last_outbound_at, last_inbound_at, created_at) DESC NULLS LAST LIMIT 1;
  v_brand := coalesce(prev.brand, c.brand, 'aviation');
  INSERT INTO public.wa_conversation (contact_id, brand, source) VALUES (c.id, v_brand, c.first_source)
  ON CONFLICT (contact_id, brand) DO NOTHING;
  SELECT w.id INTO conv FROM public.wa_conversation w WHERE w.contact_id = c.id AND w.brand = v_brand;
  INSERT INTO public.wa_message (conversation_id, direction, wamid, kind, body, payload, status, created_at)
  VALUES (conv, 'in', p ->> 'wamid', coalesce(p ->> 'kind', 'text'),
          left(coalesce(nullif(p ->> 'text', ''), nullif(p ->> 'button_title', ''), nullif(p ->> 'caption', '')), 4000),
          coalesce(p -> 'payload', '{}'), 'received', coalesce(to_timestamp(nullif(p ->> 'ts', '')::bigint), now()))
  ON CONFLICT (wamid) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;
  UPDATE public.wa_conversation SET last_inbound_at = now(), last_message_at = now(), unread = unread + 1,
    last_preview = left(coalesce(nullif(p ->> 'text', ''), nullif(p ->> 'button_title', ''), '[' || coalesce(p ->> 'kind', 'message') || ']'), 140),
    next_followup_at = NULL,                                       -- they replied: no more follow-ups
    status = CASE WHEN status = 'closed' THEN 'bot' ELSE status END, updated_at = now()
  WHERE id = conv;
  UPDATE public.wa_settings SET last_inbound_at = now() WHERE id;
  IF isnew AND p ? 'referral' THEN
    PERFORM crm_private.wa_log(conv, 'ctwa_in', jsonb_build_object('referral', p -> 'referral'));
  END IF;
  RETURN crm_private.wa_ctx(conv) || jsonb_build_object('conversation_id', conv, 'is_new', isnew,
    -- The bot answers test numbers any time (Setup's test step), everyone else only once live and out of Test mode.
    'bot_on', NOT s.pause_all AND (wid = ANY (ARRAY(SELECT crm_private.wa_wa_id(t) FROM unnest(s.test_numbers) t))
                                   OR (s.enabled AND NOT s.test_mode)));
END $$;

-- What the flow decided: chat state, replies to queue, events. Returns the queue ids to send right away.
CREATE OR REPLACE FUNCTION public.svc_wa_apply(p_conv uuid, p_patch jsonb, p_out jsonb, p_events jsonb, p_ref text) RETURNS bigint[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE ids bigint[] := '{}'; it jsonb; i int := 0; nid bigint; e jsonb; v public.wa_conversation; ct public.wa_contact; note text;
BEGIN
  SELECT * INTO v FROM public.wa_conversation WHERE id = p_conv FOR UPDATE;
  IF NOT FOUND THEN RETURN ids; END IF;
  p_patch := coalesce(p_patch, '{}');
  UPDATE public.wa_conversation SET
    status = coalesce(p_patch ->> 'status', status),
    current_step = CASE WHEN p_patch ? 'current_step' THEN p_patch ->> 'current_step' ELSE current_step END,
    answers = answers || coalesce(p_patch -> 'answers', '{}'),
    miss_count = coalesce((p_patch ->> 'miss_count')::int, miss_count),
    needs_human_since = CASE WHEN p_patch ->> 'status' = 'human' THEN coalesce(needs_human_since, now())
                             WHEN p_patch ->> 'status' = 'bot' THEN NULL ELSE needs_human_since END,
    updated_at = now()
  WHERE id = p_conv;
  IF coalesce((p_patch ->> 'opted_out')::boolean, false) THEN
    UPDATE public.wa_contact SET opted_out = true, opted_out_at = now(), opt_out_reason = 'Asked to stop on WhatsApp', updated_at = now()
     WHERE id = v.contact_id;
    UPDATE public.wa_conversation SET next_followup_at = NULL WHERE contact_id = v.contact_id;
  ELSIF coalesce((p_patch ->> 'opted_in')::boolean, false) THEN       -- they wrote START after stopping
    UPDATE public.wa_contact SET opted_out = false, opted_out_at = NULL, opt_out_reason = NULL, opted_in = true,
      opt_in_source = 'replied START', opt_in_at = now(), updated_at = now() WHERE id = v.contact_id;
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_out, '[]')) LOOP
    i := i + 1;
    INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item, created_by)
    VALUES ('reply', p_conv, 'reply:' || p_ref || ':' || i, it, 'bot')
    ON CONFLICT (idempotency_key) DO NOTHING RETURNING id INTO nid;
    IF nid IS NOT NULL THEN ids := ids || nid; END IF;
  END LOOP;
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p_events, '[]')) LOOP
    PERFORM crm_private.wa_log(p_conv, e ->> 'kind', coalesce(e -> 'detail', '{}'), coalesce((e ->> 'notify')::boolean, false), 'bot');
    -- Counselling asks and hand-offs also appear on the lead's own notes, so the caller sees them in Leads.
    IF e ->> 'kind' IN ('counselling_requested', 'handoff') AND to_regclass('public.lead_note') IS NOT NULL THEN
      SELECT * INTO ct FROM public.wa_contact WHERE id = v.contact_id;
      note := CASE WHEN e ->> 'kind' = 'counselling_requested' THEN 'WhatsApp: asked for free counselling' ELSE 'WhatsApp: wants to talk to a counsellor' END
              || coalesce(' (' || nullif(e -> 'detail' ->> 'text', '') || ')', '');
      BEGIN
        IF ct.lead_id IS NOT NULL THEN
          EXECUTE 'INSERT INTO public.lead_note (lead_id, body) VALUES ($1, $2)' USING ct.lead_id, left(note, 4000);
        ELSIF ct.ads_lead_id IS NOT NULL THEN
          EXECUTE 'INSERT INTO public.lead_note (ads_lead_id, body) VALUES ($1, $2)' USING ct.ads_lead_id, left(note, 4000);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.wa_error (place, detail, ctx) VALUES ('lead_note', left(SQLERRM, 500), jsonb_build_object('conversation', p_conv));
      END;
    END IF;
  END LOOP;
  RETURN ids;
END $$;

-- Next time a deferred send may go: the end of quiet hours (Asia/Kolkata).
CREATE OR REPLACE FUNCTION crm_private.wa_quiet_until(s public.wa_settings) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE loc timestamp := now() AT TIME ZONE 'Asia/Kolkata'; t time := loc::time; d date := loc::date;
BEGIN
  IF s.quiet_start = s.quiet_end THEN RETURN NULL; END IF;
  IF s.quiet_start > s.quiet_end THEN                    -- e.g. 20:00 -> 09:00 crosses midnight
    IF t >= s.quiet_start THEN RETURN ((d + 1) + s.quiet_end) AT TIME ZONE 'Asia/Kolkata'; END IF;
    IF t < s.quiet_end THEN RETURN (d + s.quiet_end) AT TIME ZONE 'Asia/Kolkata'; END IF;
  ELSIF t >= s.quiet_start AND t < s.quiet_end THEN
    RETURN (d + s.quiet_end) AT TIME ZONE 'Asia/Kolkata';
  END IF;
  RETURN NULL;
END $$;

-- Claim what is due to send now. Every rule is checked here, in one place, so no caller can skip one:
-- Pause all, Test mode, opt-outs, quiet hours (follow-ups), the daily cap on new people, the 24-hour window.
CREATE OR REPLACE FUNCTION public.svc_wa_claim(p_ids bigint[] DEFAULT NULL, p_limit int DEFAULT 20) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.wa_settings; q record; out jsonb := '[]'; quiet timestamptz; today_new int; free_form boolean;
  tests text[]; day0 timestamptz := (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
BEGIN
  SELECT * INTO s FROM public.wa_settings WHERE id;
  tests := ARRAY(SELECT crm_private.wa_wa_id(t) FROM unnest(s.test_numbers) t);
  quiet := crm_private.wa_quiet_until(s);
  -- a send that crashed half way (no answer for 5 minutes) is tried again
  UPDATE public.wa_queue SET state = 'pending', updated_at = now()
   WHERE state = 'sending' AND updated_at < now() - interval '5 minutes';
  SELECT count(DISTINCT q2.conversation_id) INTO today_new FROM public.wa_queue q2
   WHERE q2.kind IN ('welcome', 'followup') AND q2.state = 'done' AND q2.updated_at >= day0;
  FOR q IN
    SELECT w.*, c.wa_id, c.opted_out, c.name AS cname, c.profile_name, v.brand, v.last_inbound_at, v.welcomed_at, v.status AS vstatus,
           v.taken_over_at
      FROM public.wa_queue w JOIN public.wa_conversation v ON v.id = w.conversation_id JOIN public.wa_contact c ON c.id = v.contact_id
     WHERE w.state = 'pending' AND w.run_after <= now() AND (p_ids IS NULL OR w.id = ANY (p_ids))
     ORDER BY w.kind = 'reply' DESC, w.kind = 'manual' DESC, w.run_after, w.id
     LIMIT greatest(1, least(p_limit, 100))
     FOR UPDATE OF w SKIP LOCKED
  LOOP
    free_form := coalesce(q.item ->> 'type', 'text') <> 'template';
    IF s.pause_all AND q.kind <> 'manual' THEN CONTINUE; END IF;            -- waits until Pause all is off
    IF q.opted_out AND NOT (q.kind = 'manual' AND q.last_inbound_at > now() - interval '24 hours') THEN
      UPDATE public.wa_queue SET state = 'skipped', last_error = 'Opted out', updated_at = now() WHERE id = q.id; CONTINUE;
    END IF;
    IF (s.test_mode OR NOT s.enabled) AND q.kind <> 'manual' AND NOT (q.wa_id = ANY (tests)) THEN
      UPDATE public.wa_queue SET state = 'skipped', last_error = CASE WHEN s.enabled THEN 'Test mode: not a test number' ELSE 'Not live yet' END,
        updated_at = now() WHERE id = q.id; CONTINUE;
    END IF;
    -- Staff took the chat after the bot queued this (a bot hand-off message itself still goes), or a follow-up to a chat a person handles.
    IF (q.kind = 'followup' AND q.vstatus = 'human')
       OR (q.kind = 'reply' AND q.vstatus = 'human' AND q.taken_over_at IS NOT NULL AND q.taken_over_at >= q.created_at) THEN
      UPDATE public.wa_queue SET state = 'skipped', last_error = 'A person has taken over this chat', updated_at = now() WHERE id = q.id; CONTINUE;
    END IF;
    IF free_form AND NOT coalesce(q.last_inbound_at > now() - interval '24 hours', false) THEN
      UPDATE public.wa_queue SET state = 'dead', last_error = '24-hour window closed: send a template', updated_at = now() WHERE id = q.id; CONTINUE;
    END IF;
    IF q.kind = 'followup' AND quiet IS NOT NULL THEN
      UPDATE public.wa_queue SET run_after = quiet, updated_at = now() WHERE id = q.id; CONTINUE;
    END IF;
    IF q.kind IN ('welcome', 'followup') THEN
      IF today_new >= s.daily_new_contact_cap THEN
        UPDATE public.wa_queue SET run_after = now() + interval '30 minutes', last_error = 'Daily limit reached', updated_at = now() WHERE id = q.id; CONTINUE;
      END IF;
      today_new := today_new + 1;
    END IF;
    UPDATE public.wa_queue SET state = 'sending', attempts = attempts + 1, updated_at = now() WHERE id = q.id;
    out := out || jsonb_build_object('id', q.id, 'kind', q.kind, 'item', q.item, 'attempts', q.attempts + 1,
      'conversation_id', q.conversation_id, 'brand', q.brand, 'to', q.wa_id,
      'vars', jsonb_build_object('name', crm_private.wa_first_name(coalesce(q.cname, q.profile_name))),
      'template', CASE WHEN q.item ->> 'type' = 'template' THEN
        (SELECT jsonb_build_object('name', t.name, 'language', t.language, 'category', t.category, 'body', t.body, 'status', t.meta_status)
           FROM public.wa_template t
          WHERE t.name = coalesce(q.item ->> 'name', s.templates ->> (q.item ->> 'purpose'))
          ORDER BY t.language = 'en' DESC LIMIT 1) END);
  END LOOP;
  RETURN out;
END $$;

-- Result of one send.
CREATE OR REPLACE FUNCTION public.svc_wa_result(p_id bigint, p_ok boolean, p_wamid text, p_error_code int, p_error_text text,
  p_retry boolean, p_sent jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.wa_queue; s public.wa_settings; nxt int; start_key text; v public.wa_conversation;
BEGIN
  SELECT * INTO q FROM public.wa_queue WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO s FROM public.wa_settings WHERE id;
  IF p_ok THEN
    UPDATE public.wa_queue SET state = 'done', wamid = p_wamid, last_error = NULL, updated_at = now() WHERE id = p_id;
    INSERT INTO public.wa_message (conversation_id, direction, wamid, kind, body, template_name, payload, status, sent_by, category)
    VALUES (q.conversation_id, 'out', p_wamid, coalesce(p_sent ->> 'kind', q.item ->> 'type', 'text'), left(p_sent ->> 'body', 4000),
            p_sent ->> 'template_name', coalesce(p_sent -> 'payload', '{}'), 'sent', coalesce(q.created_by, 'bot'), p_sent ->> 'category')
    ON CONFLICT (wamid) DO NOTHING;
    UPDATE public.wa_conversation SET last_outbound_at = now(), last_message_at = now(),
      last_preview = left(coalesce(p_sent ->> 'body', q.item ->> 'body', 'Message'), 140), updated_at = now()
    WHERE id = q.conversation_id RETURNING * INTO v;
    IF q.kind = 'welcome' THEN
      SELECT key INTO start_key FROM public.wa_flow_step WHERE brand = v.brand AND is_start ORDER BY sort LIMIT 1;
      UPDATE public.wa_conversation SET welcomed_at = now(), followups_sent = 0, miss_count = 0,
        current_step = coalesce(start_key, current_step),
        next_followup_at = CASE WHEN s.max_followups > 0 AND cardinality(s.followup_hours) >= 1
                                THEN now() + make_interval(hours => s.followup_hours[1]) END
      WHERE id = q.conversation_id;
    ELSIF q.kind = 'followup' THEN
      nxt := v.followups_sent + 1;
      UPDATE public.wa_conversation SET followups_sent = nxt,
        next_followup_at = CASE WHEN nxt < s.max_followups AND cardinality(s.followup_hours) > nxt
                                THEN coalesce(welcomed_at, now()) + make_interval(hours => s.followup_hours[nxt + 1]) END
      WHERE id = q.conversation_id;
    END IF;
    IF q.kind = 'manual' THEN
      UPDATE public.wa_conversation SET unread = 0 WHERE id = q.conversation_id;
    END IF;
    RETURN;
  END IF;
  IF p_retry AND q.attempts < 5 THEN
    UPDATE public.wa_queue SET state = 'pending', last_error = left(p_error_text, 500),
      run_after = now() + make_interval(mins => power(2, q.attempts)::int), updated_at = now()
    WHERE id = p_id;
    RETURN;
  END IF;
  UPDATE public.wa_queue SET state = 'dead', last_error = left(coalesce(p_error_text, 'Failed'), 500), updated_at = now() WHERE id = p_id;
  INSERT INTO public.wa_message (conversation_id, direction, kind, body, template_name, payload, status, error_code, error_text, sent_by)
  VALUES (q.conversation_id, 'out', coalesce(q.item ->> 'type', 'text'), left(coalesce(p_sent ->> 'body', q.item ->> 'body'), 4000),
          p_sent ->> 'template_name', coalesce(p_sent -> 'payload', '{}'), 'failed', p_error_code, left(p_error_text, 500), coalesce(q.created_by, 'bot'));
  IF p_error_code = 131026 THEN
    UPDATE public.wa_contact SET not_on_whatsapp = true, updated_at = now()
     WHERE id = (SELECT contact_id FROM public.wa_conversation WHERE id = q.conversation_id);
    UPDATE public.wa_conversation SET status = 'human', needs_human_since = coalesce(needs_human_since, now()) WHERE id = q.conversation_id;
    PERFORM crm_private.wa_log(q.conversation_id, 'call_needed', jsonb_build_object('reason', 'Not reachable on WhatsApp'), true);
  ELSIF p_error_code = 131049 THEN
    PERFORM crm_private.wa_log(q.conversation_id, 'marketing_limit', jsonb_build_object('kind', q.kind));
  ELSE
    PERFORM crm_private.wa_log(q.conversation_id, 'send_failed', jsonb_build_object('kind', q.kind, 'code', p_error_code, 'text', left(p_error_text, 300)), true);
  END IF;
END $$;

-- Follow-ups that are due: only people who never replied, never more than max_followups.
CREATE OR REPLACE FUNCTION public.svc_wa_followups_due() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings; v record; n int := 0; purpose text;
BEGIN
  SELECT * INTO s FROM public.wa_settings WHERE id;
  IF NOT s.enabled OR s.pause_all THEN RETURN 0; END IF;
  FOR v IN
    SELECT w.* FROM public.wa_conversation w JOIN public.wa_contact c ON c.id = w.contact_id
     WHERE w.next_followup_at <= now() AND w.status = 'bot' AND w.welcomed_at IS NOT NULL
       AND (w.last_inbound_at IS NULL OR w.last_inbound_at < w.welcomed_at)
       AND w.followups_sent < s.max_followups AND NOT c.opted_out AND NOT c.not_on_whatsapp
     ORDER BY w.next_followup_at LIMIT 200
     FOR UPDATE OF w SKIP LOCKED
  LOOP
    purpose := CASE WHEN v.brand = 'charter' THEN 'charter_' ELSE '' END || 'followup_' || (v.followups_sent + 1);
    UPDATE public.wa_conversation SET next_followup_at = NULL WHERE id = v.id;
    CONTINUE WHEN nullif(s.templates ->> purpose, '') IS NULL;       -- no follow-up template for this brand
    INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item, created_by)
    VALUES ('followup', v.id, 'followup:' || v.id || ':' || coalesce(v.welcomed_at::text, '') || ':' || (v.followups_sent + 1),
            jsonb_build_object('type', 'template', 'purpose', purpose), 'bot')
    ON CONFLICT (idempotency_key) DO NOTHING;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Phone notifications: the CRM's existing push subscriptions (same as Amazon/ADS), for people who can open WhatsApp.
CREATE OR REPLACE FUNCTION public.svc_wa_push_work() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE subs jsonb := '[]'; evs jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'detail', e.detail, 'conversation_id', e.conversation_id,
           'name', coalesce(c.name, c.profile_name, c.phone10, c.wa_id), 'brand', v.brand) ORDER BY e.id), '[]')
    INTO evs
    FROM public.wa_event e LEFT JOIN public.wa_conversation v ON v.id = e.conversation_id LEFT JOIN public.wa_contact c ON c.id = v.contact_id
   WHERE e.notify AND e.pushed_at IS NULL AND e.created_at > now() - interval '6 hours';
  IF evs = '[]' THEN RETURN jsonb_build_object('events', evs, 'subs', subs); END IF;
  IF to_regclass('public.amazon_push_subs') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'endpoint', p.endpoint, 'keys', jsonb_build_object('p256dh', p.p256dh, 'auth', p.auth))), '[]')
        FROM public.amazon_push_subs p JOIN public.employee e ON e.id = p.employee_id
       WHERE e.active AND (e.department = 'Admin' OR EXISTS (SELECT 1 FROM public.wa_access a WHERE a.employee_id = e.id)) $q$ INTO subs;
  END IF;
  RETURN jsonb_build_object('events', evs, 'subs', subs,
    'vapid_keys', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_vapid_keys'));
END $$;

CREATE OR REPLACE FUNCTION public.svc_wa_push_done(p_ids bigint[]) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.wa_event SET pushed_at = now() WHERE id = ANY (p_ids)
$$;

-- Setup's last step: a test number got a message from us and wrote back.
CREATE OR REPLACE FUNCTION public.svc_wa_test_state() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH t AS (SELECT c.id FROM public.wa_contact c, public.wa_settings s
              WHERE s.id AND c.wa_id = ANY (ARRAY(SELECT crm_private.wa_wa_id(x) FROM unnest(s.test_numbers) x)))
  SELECT jsonb_build_object(
    'delivered', EXISTS (SELECT 1 FROM public.wa_message m JOIN public.wa_conversation v ON v.id = m.conversation_id
                          WHERE v.contact_id IN (SELECT id FROM t) AND m.direction = 'out' AND m.status IN ('delivered', 'read')),
    'replied', EXISTS (SELECT 1 FROM public.wa_message m JOIN public.wa_conversation v ON v.id = m.conversation_id
                        WHERE v.contact_id IN (SELECT id FROM t) AND m.direction = 'in'),
    'bot_answered', EXISTS (SELECT 1 FROM public.wa_message m JOIN public.wa_conversation v ON v.id = m.conversation_id
                             WHERE v.contact_id IN (SELECT id FROM t) AND m.direction = 'out' AND m.sent_by = 'bot' AND m.template_name IS NULL
                               AND m.status <> 'failed'))
$$;

-- Setup step j: is the Aviation welcome template approved?
CREATE OR REPLACE FUNCTION public.svc_wa_template_state() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'welcome_status', w.meta_status, 'welcome_reason', w.rejection_reason, 'welcome_approved', coalesce(w.meta_status = 'approved', false),
    'approved', (SELECT count(*) FROM public.wa_template WHERE meta_status = 'approved'),
    'pending', (SELECT count(*) FROM public.wa_template WHERE meta_status IN ('pending', 'in_appeal')),
    'rejected', (SELECT count(*) FROM public.wa_template WHERE meta_status = 'rejected'))
  FROM public.wa_settings s LEFT JOIN public.wa_template w ON w.name = s.templates ->> 'aviation' AND w.language = 'en'
  WHERE s.id
$$;

CREATE OR REPLACE FUNCTION public.svc_wa_queue_error(p_id bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT last_error FROM public.wa_queue WHERE id = p_id
$$;

CREATE OR REPLACE FUNCTION public.svc_wa_media_saved(p_wamid text, p_path text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.wa_message SET media_path = p_path WHERE wamid = p_wamid
$$;

CREATE OR REPLACE FUNCTION public.svc_wa_error(p_place text, p_detail text, p_ctx jsonb DEFAULT '{}') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.wa_error (place, detail, ctx) VALUES (left(p_place, 60), left(p_detail, 1000), coalesce(p_ctx, '{}'))
$$;

-- Setup checks and the phone number's details, written by wa-admin after it asked Meta.
CREATE OR REPLACE FUNCTION public.svc_wa_setup_save(p_step text, p_ok boolean, p_detail text, p_number jsonb DEFAULT NULL, p_by uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.wa_setup_check (step, ok, detail, manual, checked_at, checked_by) VALUES (p_step, p_ok, left(p_detail, 1000), false, now(), p_by)
  ON CONFLICT (step) DO UPDATE SET ok = EXCLUDED.ok, detail = EXCLUDED.detail, manual = false, checked_at = now(), checked_by = EXCLUDED.checked_by;
  IF p_number IS NOT NULL THEN
    UPDATE public.wa_number SET
      display_phone = coalesce(p_number ->> 'display_phone', display_phone), verified_name = coalesce(p_number ->> 'verified_name', verified_name),
      name_status = coalesce(p_number ->> 'name_status', name_status), quality_rating = coalesce(p_number ->> 'quality_rating', quality_rating),
      messaging_limit = coalesce(p_number ->> 'messaging_limit', messaging_limit), status = coalesce(p_number ->> 'status', status),
      last_checked_at = now()
    WHERE id = (SELECT id FROM public.wa_number ORDER BY is_default DESC, created_at LIMIT 1);
  END IF;
END $$;

-- Template states from Meta (submit or sync).
CREATE OR REPLACE FUNCTION public.svc_wa_templates_meta(p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE it jsonb; n int := 0;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]')) LOOP
    UPDATE public.wa_template SET meta_status = lower(coalesce(it ->> 'status', meta_status)), meta_id = coalesce(it ->> 'id', meta_id),
      category = CASE WHEN upper(it ->> 'category') IN ('UTILITY', 'MARKETING') THEN upper(it ->> 'category') ELSE category END,
      rejection_reason = nullif(nullif(it ->> 'rejected_reason', ''), 'NONE'), synced_at = now()
    WHERE name = it ->> 'name' AND language = coalesce(it ->> 'language', language);
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- =====================================================================================================================
-- 5. CRM functions (signed-in staff)
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION public.api_wa_access() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('can_view', crm_private.wa_can_view(), 'can_manage', crm_private.wa_can_manage(), 'is_admin', crm_private.is_admin())
$$;

-- Top of the WhatsApp page: live/test/paused, setup progress and what needs a person.
CREATE OR REPLACE FUNCTION public.api_wa_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings; day0 timestamptz := (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')) AT TIME ZONE 'Asia/Kolkata';
BEGIN
  PERFORM crm_private.wa_require();
  SELECT * INTO s FROM public.wa_settings WHERE id;
  RETURN jsonb_build_object(
    'enabled', s.enabled, 'test_mode', s.test_mode, 'pause_all', s.pause_all,
    'setup_ok', (SELECT count(*) FROM public.wa_setup_check WHERE ok), 'setup_total', 11,
    'needs_human', (SELECT count(*) FROM public.wa_conversation WHERE status = 'human'),
    'unread', (SELECT coalesce(sum(unread), 0) FROM public.wa_conversation),
    'today', jsonb_build_object(
      'welcomed', (SELECT count(*) FROM public.wa_queue WHERE kind = 'welcome' AND state = 'done' AND updated_at >= day0),
      'replies', (SELECT count(*) FROM public.wa_message WHERE direction = 'in' AND created_at >= day0),
      'failed', (SELECT count(*) FROM public.wa_message WHERE direction = 'out' AND status = 'failed' AND created_at >= day0)),
    'queue_dead', (SELECT count(*) FROM public.wa_queue WHERE state = 'dead' AND updated_at > now() - interval '7 days'),
    'number', (SELECT jsonb_build_object('display_phone', display_phone, 'verified_name', verified_name, 'quality_rating', quality_rating,
                 'status', status, 'messaging_limit', messaging_limit) FROM public.wa_number ORDER BY is_default DESC, created_at LIMIT 1),
    'can_manage', crm_private.wa_can_manage());
END $$;

-- Chat list. filter: all | human | bot | unread | closed. Newest activity first, 50 at a time.
CREATE OR REPLACE FUNCTION public.api_wa_inbox(p_filter text DEFAULT 'all', p_search text DEFAULT NULL, p_brand text DEFAULT NULL,
  p_limit int DEFAULT 50, p_before timestamptz DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE q text := nullif(btrim(coalesce(p_search, '')), ''); digits text;
BEGIN
  PERFORM crm_private.wa_require();
  digits := nullif(regexp_replace(coalesce(q, ''), '\D', '', 'g'), '');
  RETURN coalesce((SELECT jsonb_agg(r ORDER BY r.last_message_at DESC NULLS LAST) FROM (
    SELECT v.id, v.brand, v.status, v.source, v.current_step, v.unread, v.last_preview, v.last_message_at, v.needs_human_since,
           coalesce(v.last_inbound_at > now() - interval '24 hours', false) AS window_open, v.last_inbound_at,
           c.id AS contact_id, coalesce(c.name, c.profile_name, c.phone10, c.wa_id) AS name, c.wa_id, c.phone10, c.opted_out, c.not_on_whatsapp,
           c.lead_id, c.ads_lead_id, (SELECT e.name FROM public.employee e WHERE e.id = v.assigned_to) AS assigned_name,
           (SELECT m.status FROM public.wa_message m WHERE m.conversation_id = v.id AND m.direction = 'out' ORDER BY m.id DESC LIMIT 1) AS last_out_status
      FROM public.wa_conversation v JOIN public.wa_contact c ON c.id = v.contact_id
     WHERE (p_brand IS NULL OR v.brand = p_brand)
       AND (p_before IS NULL OR v.last_message_at < p_before)
       AND v.last_message_at IS NOT NULL
       AND CASE coalesce(p_filter, 'all')
             WHEN 'human' THEN v.status = 'human' WHEN 'bot' THEN v.status = 'bot' WHEN 'closed' THEN v.status = 'closed'
             WHEN 'unread' THEN v.unread > 0 ELSE v.status <> 'closed' END
       AND (q IS NULL OR c.name ILIKE '%' || q || '%' OR c.profile_name ILIKE '%' || q || '%'
            OR (digits IS NOT NULL AND length(digits) >= 4 AND c.wa_id LIKE '%' || digits || '%'))
     ORDER BY v.last_message_at DESC NULLS LAST
     LIMIT greatest(1, least(coalesce(p_limit, 50), 200))) r), '[]');
END $$;

-- One chat: messages, notes, recent bot events and the lead card.
CREATE OR REPLACE FUNCTION public.api_wa_thread(p_conv uuid, p_limit int DEFAULT 150) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.wa_conversation; c public.wa_contact; lead jsonb;
BEGIN
  PERFORM crm_private.wa_require();
  SELECT * INTO v FROM public.wa_conversation WHERE id = p_conv;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chat not found' USING ERRCODE = 'PT404'; END IF;
  SELECT * INTO c FROM public.wa_contact WHERE id = v.contact_id;
  IF c.lead_id IS NOT NULL THEN
    SELECT jsonb_build_object('kind', 'lead', 'id', l.id, 'name', l.name, 'phone', l.phone, 'course', l.course_interest, 'status', l.status,
             'source', l.utm_source, 'created_at', l.created_at, 'segment', l.segment,
             'assigned', (SELECT e.name FROM public.employee e WHERE e.id = l.assigned_to))
      INTO lead FROM public.lead l WHERE l.id = c.lead_id;
  END IF;
  IF lead IS NULL AND c.ads_lead_id IS NOT NULL AND to_regclass('public.ads_lead') IS NOT NULL THEN
    EXECUTE $q$SELECT jsonb_build_object('kind', 'ads_lead', 'id', a.id, 'name', a.name, 'phone', a.phone_e164, 'course', a.course_interest,
             'status', a.stage, 'created_at', a.created_at, 'segment', CASE WHEN a.pipeline = 'charter' THEN 'charter' ELSE 'aviation' END)
             FROM public.ads_lead a WHERE a.id = $1$q$ INTO lead USING c.ads_lead_id;
  END IF;
  RETURN jsonb_build_object(
    'conversation', to_jsonb(v) || jsonb_build_object('window_open', coalesce(v.last_inbound_at > now() - interval '24 hours', false),
                     'window_ends_at', v.last_inbound_at + interval '24 hours',
                     'assigned_name', (SELECT e.name FROM public.employee e WHERE e.id = v.assigned_to)),
    'contact', to_jsonb(c),
    'lead', lead,
    'messages', coalesce((SELECT jsonb_agg(m ORDER BY m.id) FROM (
        SELECT x.id, x.direction, x.kind, x.body, x.template_name, x.status, x.error_code, x.error_text, x.media_path, x.created_at, x.status_at,
               CASE WHEN x.sent_by ~ '^[0-9a-f-]{36}$' THEN (SELECT e.name FROM public.employee e WHERE e.id::text = x.sent_by) ELSE x.sent_by END AS sent_by,
               x.payload -> 'buttons' AS buttons, x.payload ->> 'filename' AS filename
          FROM public.wa_message x WHERE x.conversation_id = p_conv ORDER BY x.id DESC LIMIT greatest(1, least(coalesce(p_limit, 150), 500))) m), '[]'),
    'notes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'body', n.body, 'created_at', n.created_at,
                 'by', (SELECT e.name FROM public.employee e WHERE e.id = n.employee_id)) ORDER BY n.id DESC)
               FROM public.wa_note n WHERE n.conversation_id = p_conv), '[]'),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', e.kind, 'detail', e.detail, 'created_at', e.created_at, 'actor', e.actor) ORDER BY e.id DESC)
               FROM (SELECT * FROM public.wa_event WHERE conversation_id = p_conv ORDER BY id DESC LIMIT 30) e), '[]'),
    'queue', coalesce((SELECT jsonb_agg(jsonb_build_object('id', w.id, 'kind', w.kind, 'state', w.state, 'run_after', w.run_after, 'last_error', w.last_error) ORDER BY w.id DESC)
               FROM (SELECT * FROM public.wa_queue WHERE conversation_id = p_conv AND state IN ('pending', 'sending', 'dead') ORDER BY id DESC LIMIT 10) w), '[]'),
    'can_manage', crm_private.wa_can_manage());
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_read(p_conv uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require();
  UPDATE public.wa_conversation SET unread = 0 WHERE id = p_conv AND unread > 0;
END $$;

-- Take over (the bot stops for this chat) / hand back to the bot / close.
CREATE OR REPLACE FUNCTION public.api_wa_set_status(p_conv uuid, p_status text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id();
BEGIN
  PERFORM crm_private.wa_require();
  IF p_status NOT IN ('bot', 'human', 'closed') THEN RAISE EXCEPTION 'Unknown status' USING ERRCODE = 'PT400'; END IF;
  UPDATE public.wa_conversation SET status = p_status, miss_count = 0,
    assigned_to = CASE WHEN p_status = 'human' THEN coalesce(me, assigned_to) ELSE assigned_to END,
    taken_over_at = CASE WHEN p_status = 'human' THEN now() ELSE NULL END,
    needs_human_since = CASE WHEN p_status = 'human' THEN needs_human_since ELSE NULL END,
    next_followup_at = CASE WHEN p_status = 'bot' THEN next_followup_at ELSE NULL END,
    updated_at = now()
  WHERE id = p_conv;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chat not found' USING ERRCODE = 'PT404'; END IF;
  PERFORM crm_private.wa_log(p_conv, 'status_' || p_status, '{}', false, coalesce(me::text, 'staff'));
  RETURN jsonb_build_object('status', p_status);
END $$;

-- Queue a message typed in the Inbox. Free text only inside the 24-hour window; templates any time.
CREATE OR REPLACE FUNCTION public.api_wa_send(p_conv uuid, p_item jsonb) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id(); v public.wa_conversation; t text := p_item ->> 'type'; nid bigint;
BEGIN
  PERFORM crm_private.wa_require();
  SELECT * INTO v FROM public.wa_conversation WHERE id = p_conv;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chat not found' USING ERRCODE = 'PT404'; END IF;
  IF t NOT IN ('text', 'template', 'document') THEN RAISE EXCEPTION 'Unknown message type' USING ERRCODE = 'PT400'; END IF;
  IF t = 'text' AND length(btrim(coalesce(p_item ->> 'body', ''))) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'Type a message (up to 4096 characters)' USING ERRCODE = 'PT422';
  END IF;
  IF t <> 'template' AND NOT coalesce(v.last_inbound_at > now() - interval '24 hours', false) THEN
    RAISE EXCEPTION 'More than 24 hours since their last message: send a template instead' USING ERRCODE = 'PT422';
  END IF;
  IF t = 'template' AND NOT EXISTS (SELECT 1 FROM public.wa_template WHERE name = p_item ->> 'name' AND meta_status = 'approved') THEN
    RAISE EXCEPTION 'That template is not approved by Meta yet' USING ERRCODE = 'PT422';
  END IF;
  IF t = 'document' AND coalesce(p_item ->> 'link', '') !~ '^https://' THEN
    RAISE EXCEPTION 'Add the brochure link in WhatsApp > Settings first' USING ERRCODE = 'PT422';
  END IF;
  INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item, created_by)
  VALUES ('manual', p_conv, 'manual:' || gen_random_uuid(), p_item || jsonb_build_object('force', true), coalesce(me::text, 'staff'))
  RETURNING id INTO nid;
  -- Writing by hand means a person is handling this chat now.
  UPDATE public.wa_conversation SET status = CASE WHEN status = 'bot' THEN 'human' ELSE status END,
    taken_over_at = CASE WHEN status = 'bot' THEN now() ELSE coalesce(taken_over_at, now()) END,
    assigned_to = coalesce(assigned_to, me), needs_human_since = NULL, unread = 0, updated_at = now() WHERE id = p_conv;
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_note_add(p_conv uuid, p_body text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require();
  INSERT INTO public.wa_note (conversation_id, employee_id, body) VALUES (p_conv, crm_private.current_employee_id(), btrim(p_body));
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_contacts(p_search text DEFAULT NULL, p_filter text DEFAULT 'all', p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE q text := nullif(btrim(coalesce(p_search, '')), ''); digits text;
BEGIN
  PERFORM crm_private.wa_require();
  digits := nullif(regexp_replace(coalesce(q, ''), '\D', '', 'g'), '');
  RETURN coalesce((SELECT jsonb_agg(r) FROM (
    SELECT c.id, coalesce(c.name, c.profile_name) AS name, c.wa_id, c.phone10, c.first_source, c.brand, c.opted_in, c.opt_in_source, c.opt_in_at,
           c.opted_out, c.opted_out_at, c.opt_out_reason, c.not_on_whatsapp, c.lead_id, c.ads_lead_id, c.created_at,
           (SELECT v.id FROM public.wa_conversation v WHERE v.contact_id = c.id ORDER BY v.last_message_at DESC NULLS LAST LIMIT 1) AS conversation_id
      FROM public.wa_contact c
     WHERE CASE coalesce(p_filter, 'all') WHEN 'opted_out' THEN c.opted_out WHEN 'unreachable' THEN c.not_on_whatsapp
             WHEN 'opted_in' THEN c.opted_in AND NOT c.opted_out ELSE true END
       AND (q IS NULL OR c.name ILIKE '%' || q || '%' OR c.profile_name ILIKE '%' || q || '%'
            OR (digits IS NOT NULL AND length(digits) >= 4 AND c.wa_id LIKE '%' || digits || '%'))
     ORDER BY c.created_at DESC LIMIT greatest(1, least(coalesce(p_limit, 100), 500))) r), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_contact_optout(p_contact uuid, p_out boolean, p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id();
BEGIN
  PERFORM crm_private.wa_require();
  IF p_out THEN
    UPDATE public.wa_contact SET opted_out = true, opted_out_at = now(), opt_out_reason = coalesce(nullif(btrim(p_reason), ''), 'Set by staff'), updated_at = now()
     WHERE id = p_contact;
    UPDATE public.wa_conversation SET next_followup_at = NULL WHERE contact_id = p_contact;
  ELSE
    IF nullif(btrim(coalesce(p_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Write how they agreed to messages again' USING ERRCODE = 'PT422';
    END IF;
    UPDATE public.wa_contact SET opted_out = false, opted_out_at = NULL, opt_out_reason = NULL,
      opted_in = true, opt_in_source = 'staff: ' || left(btrim(p_reason), 200), opt_in_at = now(), updated_at = now()
     WHERE id = p_contact;
  END IF;
  INSERT INTO public.wa_event (conversation_id, kind, detail, actor)
  SELECT v.id, CASE WHEN p_out THEN 'opted_out' ELSE 'opted_in' END, jsonb_build_object('reason', p_reason), coalesce(me::text, 'staff')
    FROM public.wa_conversation v WHERE v.contact_id = p_contact;
END $$;

-- Flow & replies
CREATE OR REPLACE FUNCTION public.api_wa_flow(p_brand text DEFAULT 'aviation') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings;
BEGIN
  PERFORM crm_private.wa_require();
  SELECT * INTO s FROM public.wa_settings WHERE id;
  RETURN jsonb_build_object(
    'steps', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.sort, x.key) FROM public.wa_flow_step x WHERE x.brand = p_brand), '[]'),
    'rules', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.step_key NULLS LAST, r.priority DESC, r.created_at) FROM public.wa_reply_rule r
                        WHERE r.brand IS NULL OR r.brand = p_brand), '[]'),
    'vars', jsonb_build_object('name', 'Rahul', 'counsellor_phone', s.counsellor_phone,
                               'brand', CASE WHEN p_brand = 'charter' THEN 'Book My Charter' ELSE 'We One Aviation' END),
    'brochure', jsonb_build_object('url', s.brochure_url, 'name', s.brochure_name),
    'can_manage', crm_private.wa_can_manage());
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_step_save(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid uuid; b jsonb := coalesce(p -> 'buttons', '[]'); k text := lower(btrim(coalesce(p ->> 'key', '')));
BEGIN
  PERFORM crm_private.wa_require(true);
  IF k !~ '^[a-z0-9_]{1,40}$' THEN RAISE EXCEPTION 'Step name: small letters, numbers and _ only' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_typeof(b) <> 'array' OR jsonb_array_length(b) > (CASE WHEN p ->> 'kind' = 'list' THEN 10 ELSE 3 END) THEN
    RAISE EXCEPTION 'Buttons: up to 3 (or 10 in a list)' USING ERRCODE = 'PT422';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(b) x WHERE length(coalesce(x ->> 'title', '')) NOT BETWEEN 1 AND (CASE WHEN p ->> 'kind' = 'list' THEN 24 ELSE 20 END)) THEN
    RAISE EXCEPTION 'Each button needs a title of up to 20 characters (24 in a list)' USING ERRCODE = 'PT422';
  END IF;
  IF coalesce((p ->> 'is_start')::boolean, false) THEN
    UPDATE public.wa_flow_step SET is_start = false WHERE brand = p ->> 'brand' AND key <> k;
  END IF;
  INSERT INTO public.wa_flow_step (id, brand, key, title, kind, body, buttons, capture, next_key, auto_next, handoff, is_start, sort, updated_at)
  VALUES (coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid()), p ->> 'brand', k, nullif(btrim(p ->> 'title'), ''),
          coalesce(p ->> 'kind', 'text'), btrim(p ->> 'body'), b, nullif(btrim(p ->> 'capture'), ''), nullif(btrim(p ->> 'next_key'), ''),
          nullif(btrim(p ->> 'auto_next'), ''), coalesce((p ->> 'handoff')::boolean, false), coalesce((p ->> 'is_start')::boolean, false),
          coalesce((p ->> 'sort')::int, 0), now())
  ON CONFLICT (id) DO UPDATE SET key = EXCLUDED.key, title = EXCLUDED.title, kind = EXCLUDED.kind, body = EXCLUDED.body,
    buttons = EXCLUDED.buttons, capture = EXCLUDED.capture, next_key = EXCLUDED.next_key, auto_next = EXCLUDED.auto_next,
    handoff = EXCLUDED.handoff, is_start = EXCLUDED.is_start, sort = EXCLUDED.sort, updated_at = now()
  RETURNING id INTO nid;
  RETURN nid;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'A step with that name already exists' USING ERRCODE = 'PT409';
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_step_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require(true);
  IF EXISTS (SELECT 1 FROM public.wa_flow_step WHERE id = p_id AND is_start) THEN
    RAISE EXCEPTION 'This is the first step: make another step the first one before deleting it' USING ERRCODE = 'PT422';
  END IF;
  DELETE FROM public.wa_flow_step WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_rule_save(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid uuid; pats text[];
BEGIN
  PERFORM crm_private.wa_require(true);
  pats := ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(coalesce(p -> 'patterns', '[]')) x WHERE btrim(x) <> '');
  IF cardinality(pats) = 0 THEN RAISE EXCEPTION 'Add at least one word or phrase' USING ERRCODE = 'PT422'; END IF;
  IF p ->> 'action' = 'goto' AND nullif(p ->> 'goto_key', '') IS NULL THEN RAISE EXCEPTION 'Pick the step to go to' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.wa_reply_rule (id, brand, step_key, match_type, patterns, priority, action, goto_key, reply_text, active)
  VALUES (coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid()), nullif(p ->> 'brand', ''), nullif(p ->> 'step_key', ''),
          coalesce(p ->> 'match_type', 'contains'), pats, coalesce((p ->> 'priority')::int, 0), p ->> 'action',
          nullif(p ->> 'goto_key', ''), nullif(btrim(p ->> 'reply_text'), ''), coalesce((p ->> 'active')::boolean, true))
  ON CONFLICT (id) DO UPDATE SET brand = EXCLUDED.brand, step_key = EXCLUDED.step_key, match_type = EXCLUDED.match_type,
    patterns = EXCLUDED.patterns, priority = EXCLUDED.priority, action = EXCLUDED.action, goto_key = EXCLUDED.goto_key,
    reply_text = EXCLUDED.reply_text, active = EXCLUDED.active
  RETURNING id INTO nid;
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_rule_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require(true);
  DELETE FROM public.wa_reply_rule WHERE id = p_id;
END $$;

-- Templates
CREATE OR REPLACE FUNCTION public.api_wa_templates() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require();
  RETURN jsonb_build_object(
    'templates', coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.purpose, t.name) FROM public.wa_template t), '[]'),
    'map', (SELECT templates FROM public.wa_settings WHERE id),
    'can_manage', crm_private.wa_can_manage());
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_template_save(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid uuid; n text := lower(btrim(coalesce(p ->> 'name', ''))); old public.wa_template; b jsonb := coalesce(p -> 'buttons', '[]');
BEGIN
  PERFORM crm_private.wa_require(true);
  IF n !~ '^[a-z0-9_]+$' OR length(n) > 512 THEN RAISE EXCEPTION 'Template name: small letters, numbers and _ only' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_typeof(b) <> 'array' OR jsonb_array_length(b) > 3
     OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(b) x WHERE length(x) NOT BETWEEN 1 AND 25) THEN
    RAISE EXCEPTION 'Up to 3 quick-reply buttons, 25 characters each' USING ERRCODE = 'PT422';
  END IF;
  IF nullif(p ->> 'id', '') IS NOT NULL THEN
    SELECT * INTO old FROM public.wa_template WHERE id = (p ->> 'id')::uuid;
    IF FOUND AND old.meta_status IN ('approved', 'pending') AND (old.body <> btrim(p ->> 'body') OR old.buttons <> b) THEN
      RAISE EXCEPTION 'Meta has this template already: save the change as a new template name' USING ERRCODE = 'PT422';
    END IF;
  END IF;
  INSERT INTO public.wa_template (id, name, language, category, purpose, body, footer, buttons, updated_at)
  VALUES (coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid()), n, coalesce(nullif(p ->> 'language', ''), 'en'),
          upper(coalesce(p ->> 'category', 'UTILITY')), coalesce(nullif(p ->> 'purpose', ''), 'other'), btrim(p ->> 'body'),
          nullif(btrim(p ->> 'footer'), ''), b, now())
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, language = EXCLUDED.language, category = EXCLUDED.category,
    purpose = EXCLUDED.purpose, body = EXCLUDED.body, footer = EXCLUDED.footer, buttons = EXCLUDED.buttons, updated_at = now()
  RETURNING id INTO nid;
  RETURN nid;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'A template with that name and language already exists' USING ERRCODE = 'PT409';
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_template_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require(true);
  DELETE FROM public.wa_template WHERE id = p_id AND meta_status NOT IN ('approved', 'pending');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only drafts and rejected templates can be deleted here' USING ERRCODE = 'PT422'; END IF;
END $$;

-- Settings
CREATE OR REPLACE FUNCTION public.api_wa_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require();
  RETURN (SELECT to_jsonb(s) - 'id' FROM public.wa_settings s WHERE s.id)
    || jsonb_build_object('can_manage', crm_private.wa_can_manage(),
         'ready_to_go_live', NOT EXISTS (SELECT 1 FROM unnest(ARRAY['business', 'app', 'number', 'payment', 'token', 'ids', 'webhook',
                                           'subscribed', 'registered', 'templates', 'test']) k
                                         WHERE NOT EXISTS (SELECT 1 FROM public.wa_setup_check c WHERE c.step = k AND c.ok)));
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_settings_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings; hours int[]; nums text[]; bad text;
BEGIN
  PERFORM crm_private.wa_require(true);
  SELECT * INTO s FROM public.wa_settings WHERE id FOR UPDATE;
  IF coalesce((p ->> 'enabled')::boolean, s.enabled) AND NOT s.enabled THEN
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['business', 'app', 'number', 'payment', 'token', 'ids', 'webhook', 'subscribed', 'registered', 'templates', 'test']) k
                WHERE NOT EXISTS (SELECT 1 FROM public.wa_setup_check c WHERE c.step = k AND c.ok)) THEN
      RAISE EXCEPTION 'Finish every step in WhatsApp > Setup before going live' USING ERRCODE = 'PT422';
    END IF;
  END IF;
  IF p ? 'followup_hours' THEN
    hours := ARRAY(SELECT x::int FROM jsonb_array_elements_text(p -> 'followup_hours') x);
    IF EXISTS (SELECT 1 FROM unnest(hours) h WHERE h NOT BETWEEN 1 AND 720) THEN
      RAISE EXCEPTION 'Follow-up hours must be between 1 and 720' USING ERRCODE = 'PT422';
    END IF;
    hours := ARRAY(SELECT DISTINCT h FROM unnest(hours) h ORDER BY h);
  END IF;
  IF p ? 'test_numbers' THEN
    SELECT x INTO bad FROM jsonb_array_elements_text(p -> 'test_numbers') x WHERE crm_private.wa_wa_id(x) IS NULL LIMIT 1;
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'Not a phone number: %', bad USING ERRCODE = 'PT422'; END IF;
    nums := ARRAY(SELECT DISTINCT crm_private.wa_wa_id(x) FROM jsonb_array_elements_text(p -> 'test_numbers') x);
  END IF;
  IF nullif(p ->> 'brochure_url', '') IS NOT NULL AND p ->> 'brochure_url' !~ '^https://' THEN
    RAISE EXCEPTION 'The brochure link must start with https://' USING ERRCODE = 'PT422';
  END IF;
  IF nullif(p ->> 'gateway_url', '') IS NOT NULL AND p ->> 'gateway_url' !~ '^https://[^ ]+$' THEN
    RAISE EXCEPTION 'The gateway address must start with https://' USING ERRCODE = 'PT422';
  END IF;
  UPDATE public.wa_settings SET
    enabled = coalesce((p ->> 'enabled')::boolean, enabled),
    test_mode = coalesce((p ->> 'test_mode')::boolean, test_mode),
    test_numbers = coalesce(nums, test_numbers),
    pause_all = coalesce((p ->> 'pause_all')::boolean, pause_all),
    quiet_start = coalesce(nullif(p ->> 'quiet_start', '')::time, quiet_start),
    quiet_end = coalesce(nullif(p ->> 'quiet_end', '')::time, quiet_end),
    followup_hours = coalesce(hours, followup_hours),
    max_followups = coalesce((p ->> 'max_followups')::int, max_followups),
    daily_new_contact_cap = coalesce((p ->> 'daily_new_contact_cap')::int, daily_new_contact_cap),
    auto_sources = CASE WHEN jsonb_typeof(p -> 'auto_sources') = 'object' THEN auto_sources || (p -> 'auto_sources') ELSE auto_sources END,
    templates = CASE WHEN jsonb_typeof(p -> 'templates') = 'object' THEN templates || (p -> 'templates') ELSE templates END,
    counsellor_phone = coalesce(nullif(regexp_replace(coalesce(p ->> 'counsellor_phone', ''), '\D', '', 'g'), ''), counsellor_phone),
    brochure_url = CASE WHEN p ? 'brochure_url' THEN nullif(btrim(p ->> 'brochure_url'), '') ELSE brochure_url END,
    brochure_name = coalesce(nullif(btrim(p ->> 'brochure_name'), ''), brochure_name),
    rates = CASE WHEN jsonb_typeof(p -> 'rates') = 'object' THEN rates || (p -> 'rates') ELSE rates END,
    gateway_url = CASE WHEN p ? 'gateway_url' THEN nullif(rtrim(btrim(p ->> 'gateway_url'), '/'), '') ELSE gateway_url END,
    updated_at = now(), updated_by = crm_private.current_employee_id()
  WHERE id;
  RETURN public.api_wa_settings();
END $$;

-- Setup page: every step, what is saved (never the secret itself), the copy-paste values.
CREATE OR REPLACE FUNCTION public.api_wa_setup() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings;
BEGIN
  PERFORM crm_private.wa_require(true);
  SELECT * INTO s FROM public.wa_settings WHERE id;
  RETURN jsonb_build_object(
    'checks', coalesce((SELECT jsonb_object_agg(c.step, jsonb_build_object('ok', c.ok, 'detail', c.detail, 'manual', c.manual, 'at', c.checked_at))
                         FROM public.wa_setup_check c), '{}'),
    'number', (SELECT to_jsonb(n) FROM public.wa_number n ORDER BY n.is_default DESC, n.created_at LIMIT 1),
    'secrets', jsonb_build_object(
      'access_token', (SELECT jsonb_build_object('set', true, 'last4', right(d.decrypted_secret, 4), 'at', d.updated_at) FROM vault.decrypted_secrets d WHERE d.name = 'wa_access_token'),
      'app_secret', (SELECT jsonb_build_object('set', true, 'last4', right(d.decrypted_secret, 4), 'at', d.updated_at) FROM vault.decrypted_secrets d WHERE d.name = 'wa_app_secret')),
    'verify_token', crm_private.wa_secret('verify_token'),          -- not a secret: it is pasted into Meta
    'webhook_url', 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/wa-webhook',
    'gateway_url', s.gateway_url, 'webhook_seen_at', s.webhook_seen_at, 'gateway_seen_at', s.gateway_seen_at,
    'last_inbound_at', s.last_inbound_at, 'test_numbers', s.test_numbers, 'enabled', s.enabled,
    'api_version', crm_private.wa_api_version());
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_secret_save(p_name text, p_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE sid uuid; v text := btrim(coalesce(p_value, ''));
BEGIN
  PERFORM crm_private.wa_require(true);
  IF p_name NOT IN ('access_token', 'app_secret', 'verify_token') THEN RAISE EXCEPTION 'Unknown key' USING ERRCODE = 'PT400'; END IF;
  IF length(v) NOT BETWEEN 8 AND 4000 OR v ~ '\s' THEN RAISE EXCEPTION 'That does not look right: paste the whole value, no spaces' USING ERRCODE = 'PT422'; END IF;
  SELECT id INTO sid FROM vault.secrets WHERE name = 'wa_' || p_name;
  IF sid IS NULL THEN PERFORM vault.create_secret(v, 'wa_' || p_name, 'WhatsApp Cloud API (' || p_name || ')');
  ELSE PERFORM vault.update_secret(sid, v); END IF;
  DELETE FROM public.wa_setup_check WHERE step IN ('token', 'app') AND p_name IN ('access_token', 'app_secret');
  PERFORM crm_private.wa_log(NULL, 'secret_saved', jsonb_build_object('name', p_name), false, coalesce(crm_private.current_employee_id()::text, 'staff'));
END $$;

-- A fresh verify token (Meta asks for one when the Callback URL is saved).
CREATE OR REPLACE FUNCTION public.api_wa_verify_token_new() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := 'weone_' || replace(gen_random_uuid()::text, '-', '');
BEGIN
  PERFORM public.api_wa_secret_save('verify_token', t);
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_number_save(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid text := nullif(regexp_replace(coalesce(p ->> 'phone_number_id', ''), '\D', '', 'g'), '');
        wid text := nullif(regexp_replace(coalesce(p ->> 'waba_id', ''), '\D', '', 'g'), '');
        aid text := nullif(regexp_replace(coalesce(p ->> 'app_id', ''), '\D', '', 'g'), '');
BEGIN
  PERFORM crm_private.wa_require(true);
  IF NOT EXISTS (SELECT 1 FROM public.wa_number) THEN INSERT INTO public.wa_number (label) VALUES ('We One Aviation'); END IF;
  UPDATE public.wa_number SET
    phone_number_id = CASE WHEN p ? 'phone_number_id' THEN pid ELSE phone_number_id END,
    waba_id = CASE WHEN p ? 'waba_id' THEN wid ELSE waba_id END,
    app_id = CASE WHEN p ? 'app_id' THEN aid ELSE app_id END,
    label = coalesce(nullif(btrim(p ->> 'label'), ''), label)
  WHERE id = (SELECT id FROM public.wa_number ORDER BY is_default DESC, created_at LIMIT 1);
  DELETE FROM public.wa_setup_check WHERE step IN ('ids', 'number', 'app') AND (p ? 'phone_number_id' OR p ? 'waba_id' OR p ? 'app_id');
END $$;

-- The two steps Meta can't confirm through the API: business verification and the payment method.
CREATE OR REPLACE FUNCTION public.api_wa_setup_mark(p_step text, p_ok boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.wa_require(true);
  IF p_step NOT IN ('business', 'payment') THEN RAISE EXCEPTION 'This step is checked automatically' USING ERRCODE = 'PT400'; END IF;
  INSERT INTO public.wa_setup_check (step, ok, detail, manual, checked_at, checked_by)
  VALUES (p_step, p_ok, CASE WHEN p_ok THEN 'Marked done' ELSE 'Not done yet' END, true, now(), crm_private.current_employee_id())
  ON CONFLICT (step) DO UPDATE SET ok = EXCLUDED.ok, detail = EXCLUDED.detail, manual = true, checked_at = now(), checked_by = EXCLUDED.checked_by;
END $$;

-- Setup step k: queue a welcome to one test number (it must be in Test numbers).
CREATE OR REPLACE FUNCTION public.api_wa_test_welcome(p_phone text, p_brand text DEFAULT 'aviation') RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.wa_settings; wid text := crm_private.wa_wa_id(p_phone); c uuid; conv uuid; nid bigint;
BEGIN
  PERFORM crm_private.wa_require(true);
  SELECT * INTO s FROM public.wa_settings WHERE id;
  IF wid IS NULL THEN RAISE EXCEPTION 'Enter a phone number' USING ERRCODE = 'PT422'; END IF;
  IF NOT (wid = ANY (ARRAY(SELECT crm_private.wa_wa_id(t) FROM unnest(s.test_numbers) t))) THEN
    RAISE EXCEPTION 'Add this number to Test numbers in Settings first' USING ERRCODE = 'PT422';
  END IF;
  INSERT INTO public.wa_contact (wa_id, name, first_source, brand, opted_in, opt_in_source, opt_in_at)
  VALUES (wid, 'Test', 'test', p_brand, true, 'test', now())
  ON CONFLICT (wa_id) DO UPDATE SET opted_out = false, not_on_whatsapp = false, updated_at = now() RETURNING id INTO c;
  INSERT INTO public.wa_conversation (contact_id, brand, source) VALUES (c, p_brand, 'test')
  ON CONFLICT (contact_id, brand) DO UPDATE SET status = 'bot', updated_at = now() RETURNING id INTO conv;
  INSERT INTO public.wa_queue (kind, conversation_id, idempotency_key, item, created_by)
  VALUES ('welcome', conv, 'test:' || gen_random_uuid(), jsonb_build_object('type', 'template', 'purpose', p_brand),
          coalesce(crm_private.current_employee_id()::text, 'staff'))
  RETURNING id INTO nid;
  RETURN nid;
END $$;

-- Who can open WhatsApp (Admin always can).
CREATE OR REPLACE FUNCTION public.api_wa_access_list() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change who has access' USING ERRCODE = 'PT403'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'department', e.department,
           'has_access', a.employee_id IS NOT NULL, 'can_manage', coalesce(a.can_manage, false)) ORDER BY a.employee_id IS NULL, e.name)
    FROM public.employee e LEFT JOIN public.wa_access a ON a.employee_id = e.id
   WHERE e.active AND coalesce(e.department, '') <> 'Admin'), '[]');
END $$;

CREATE OR REPLACE FUNCTION public.api_wa_access_set(p_employee uuid, p_on boolean, p_manage boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change who has access' USING ERRCODE = 'PT403'; END IF;
  IF p_on THEN
    INSERT INTO public.wa_access (employee_id, can_manage, added_by) VALUES (p_employee, coalesce(p_manage, false), crm_private.current_employee_id())
    ON CONFLICT (employee_id) DO UPDATE SET can_manage = EXCLUDED.can_manage;
  ELSE
    DELETE FROM public.wa_access WHERE employee_id = p_employee;
  END IF;
END $$;

-- Results by lead source: leads -> welcomed -> delivered -> replied -> counselling, failures, estimated Meta cost.
CREATE OR REPLACE FUNCTION public.api_wa_insights(p_days int DEFAULT 30) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365))); s public.wa_settings;
  util int; mkt int; svc int; months numeric;
BEGIN
  PERFORM crm_private.wa_require();
  SELECT * INTO s FROM public.wa_settings WHERE id;
  SELECT count(*) FILTER (WHERE m.template_name IS NOT NULL AND coalesce(t.category, 'UTILITY') = 'UTILITY'),
         count(*) FILTER (WHERE m.template_name IS NOT NULL AND t.category = 'MARKETING'),
         count(*) FILTER (WHERE m.template_name IS NULL)
    INTO util, mkt, svc
    FROM public.wa_message m LEFT JOIN public.wa_template t ON t.name = m.template_name
   WHERE m.direction = 'out' AND m.status IN ('delivered', 'read') AND m.created_at >= since;
  months := greatest(1, ceil(extract(epoch FROM now() - since) / 2592000.0));
  RETURN jsonb_build_object(
    'days', p_days,
    'by_source', coalesce((SELECT jsonb_agg(x ORDER BY x.leads DESC) FROM (
      SELECT coalesce(v.source, 'other') AS source, count(*) AS leads,
             count(*) FILTER (WHERE v.welcomed_at IS NOT NULL) AS welcomed,
             count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.wa_message m WHERE m.conversation_id = v.id AND m.direction = 'out' AND m.status IN ('delivered', 'read'))) AS delivered,
             count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.wa_message m WHERE m.conversation_id = v.id AND m.direction = 'out' AND m.status = 'read')) AS read,
             count(*) FILTER (WHERE v.last_inbound_at IS NOT NULL) AS replied,
             count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.wa_event e WHERE e.conversation_id = v.id AND e.kind = 'counselling_requested')) AS counselling,
             count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.wa_event e WHERE e.conversation_id = v.id AND e.kind IN ('handoff', 'counselling_requested'))) AS handed_over,
             count(*) FILTER (WHERE c.opted_out) AS opted_out
        FROM public.wa_conversation v JOIN public.wa_contact c ON c.id = v.contact_id
       WHERE v.created_at >= since GROUP BY 1) x), '[]'),
    'failures', coalesce((SELECT jsonb_agg(jsonb_build_object('code', f.error_code, 'text', f.t, 'count', f.n) ORDER BY f.n DESC) FROM (
      SELECT error_code, max(error_text) AS t, count(*) AS n FROM public.wa_message
       WHERE direction = 'out' AND status = 'failed' AND created_at >= since GROUP BY error_code) f), '[]'),
    'reply_minutes_median', (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM v.last_inbound_at - v.welcomed_at) / 60))::numeric, 1)
                               FROM public.wa_conversation v WHERE v.welcomed_at >= since AND v.last_inbound_at > v.welcomed_at),
    'messages', jsonb_build_object('utility', util, 'marketing', mkt, 'service', svc,
      'inbound', (SELECT count(*) FROM public.wa_message WHERE direction = 'in' AND created_at >= since)),
    'cost', jsonb_build_object(
      'before_gst', round(util * (s.rates ->> 'utility')::numeric + mkt * (s.rates ->> 'marketing')::numeric
                     + greatest(0, svc - months * (s.rates ->> 'free_service')::numeric) * (s.rates ->> 'service')::numeric, 2),
      'gst_pct', (s.rates ->> 'gst')::numeric, 'rates', s.rates));
END $$;

-- Read-only WhatsApp panel on a lead (Leads > lead window). Sales and Admin see it, plus WhatsApp users.
CREATE OR REPLACE FUNCTION public.api_wa_lead_panel(p_lead uuid DEFAULT NULL, p_ads_lead uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.wa_contact; v public.wa_conversation;
BEGIN
  IF NOT (crm_private.wa_can_view() OR coalesce(crm_private.current_department() IN ('Admin', 'Sales'), false)) THEN
    RAISE EXCEPTION 'You do not have access to WhatsApp' USING ERRCODE = 'PT403';
  END IF;
  SELECT * INTO c FROM public.wa_contact
   WHERE (p_lead IS NOT NULL AND lead_id = p_lead) OR (p_ads_lead IS NOT NULL AND ads_lead_id = p_ads_lead) LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v FROM public.wa_conversation WHERE contact_id = c.id ORDER BY last_message_at DESC NULLS LAST LIMIT 1;
  RETURN jsonb_build_object('conversation_id', v.id, 'status', v.status, 'brand', v.brand, 'current_step', v.current_step,
    'answers', v.answers, 'opted_out', c.opted_out, 'not_on_whatsapp', c.not_on_whatsapp, 'welcomed_at', v.welcomed_at,
    'last_message_at', v.last_message_at, 'can_open', crm_private.wa_can_view(),
    'pending', (SELECT jsonb_build_object('kind', w.kind, 'state', w.state, 'last_error', w.last_error) FROM public.wa_queue w
                 WHERE w.conversation_id = v.id ORDER BY w.id DESC LIMIT 1),
    'messages', coalesce((SELECT jsonb_agg(m ORDER BY m.id) FROM (
       SELECT x.id, x.direction, x.body, x.kind, x.status, x.created_at FROM public.wa_message x
        WHERE x.conversation_id = v.id ORDER BY x.id DESC LIMIT 5) m), '[]'));
END $$;

-- =====================================================================================================================
-- 6. Grants
-- =====================================================================================================================
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname LIKE 'api\_wa\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname LIKE 'svc\_wa\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'crm_private' AND p.proname LIKE 'wa\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- =====================================================================================================================
-- 7. Starter content (only added when missing; your edits are never overwritten)
-- =====================================================================================================================
INSERT INTO public.wa_template (name, language, category, purpose, body, footer, buttons) VALUES
  ('weone_welcome', 'en', 'UTILITY', 'aviation',
   'Hi {{1}}, thank you for your pilot training enquiry with We One Aviation. We have received your details. So we can guide you correctly, are you the student or a parent?',
   'We One Aviation', '["I''m a student", "I''m a parent", "Talk to counsellor"]'),
  ('bmc_welcome', 'en', 'UTILITY', 'charter',
   'Hi {{1}}, thank you for your charter enquiry with Book My Charter. We have received your trip request. Would you like us to share options here on WhatsApp?',
   'Book My Charter', '["Yes, share options", "Call me", "Not now"]'),
  ('weone_justdial_ack', 'en', 'UTILITY', 'justdial',
   'Hi {{1}}, thank you for contacting We One Aviation through JustDial. Tap below and our counsellor will help you with pilot training.',
   'We One Aviation', '["Talk to counsellor", "Not interested"]'),
  ('weone_followup_1', 'en', 'MARKETING', 'followup_1',
   'Hi {{1}}, checking in about your pilot training enquiry. Would you like a free counselling session with our team?',
   'We One Aviation', '["Book free counselling", "Send brochure", "Not interested"]'),
  ('weone_followup_2', 'en', 'MARKETING', 'followup_2',
   'Hi {{1}}, our counsellors are available for a free call about CPL training. Tap below if you would like one.',
   'We One Aviation', '["Yes, call me", "Stop messages"]')
ON CONFLICT (name, language) DO NOTHING;

INSERT INTO public.wa_flow_step (brand, key, title, kind, body, buttons, capture, next_key, auto_next, handoff, is_start, sort) VALUES
  ('aviation', 'welcome', 'Welcome (student or parent)', 'buttons',
   'Hi {{name}}, welcome to We One Aviation! So we can guide you correctly, are you the student or a parent?',
   '[{"id": "student", "title": "I''m a student", "goto": "pcm"}, {"id": "parent", "title": "I''m a parent", "goto": "pcm"}, {"id": "counsellor", "title": "Talk to counsellor", "action": "handoff"}]',
   NULL, NULL, NULL, false, true, 10),
  ('aviation', 'pcm', 'Physics and Maths in 12th', 'buttons',
   'Has the student studied Physics and Maths in 12th (or is studying them now)? DGCA needs both for a Commercial Pilot Licence.',
   '[{"id": "pcm_yes", "title": "Yes", "goto": "city"}, {"id": "pcm_no", "title": "No", "goto": "nios"}, {"id": "pcm_unsure", "title": "Not sure", "goto": "city"}]',
   NULL, NULL, NULL, false, false, 20),
  ('aviation', 'nios', 'No Physics/Maths: NIOS route', 'text',
   'No problem. Students without Physics and Maths can add them through NIOS (National Institute of Open Schooling) and then become eligible. Our counsellor will explain the plan on a call.',
   '[]', NULL, NULL, 'city', false, false, 30),
  ('aviation', 'city', 'Which city', 'text',
   'Which city are you in?', '[]', 'city', 'brochure', NULL, false, false, 40),
  ('aviation', 'brochure', 'Brochure', 'document',
   'Here is our brochure with the full training path.', '[]', NULL, NULL, 'counselling', false, false, 50),
  ('aviation', 'counselling', 'Free counselling', 'buttons',
   'Would you like a free counselling session? Our counsellor will call you and answer every question.',
   '[{"id": "book", "title": "Book free counselling", "action": "book_counselling"}, {"id": "later", "title": "Call me later", "action": "handoff"}, {"id": "browse", "title": "Just browsing", "goto": "end"}]',
   NULL, NULL, NULL, false, false, 60),
  ('aviation', 'booked', 'Counselling booked', 'text',
   'Great! Our counsellor will call you shortly to fix a time. You can also call us on {{counsellor_phone}}.', '[]', NULL, NULL, NULL, true, false, 70),
  ('aviation', 'end', 'Just browsing', 'text',
   'No problem, {{name}}. Message us here any time and we will help you.', '[]', NULL, NULL, NULL, false, false, 80),
  ('charter', 'welcome', 'Welcome', 'buttons',
   'Hi {{name}}, welcome to Book My Charter! Would you like us to share charter options here on WhatsApp?',
   '[{"id": "options", "title": "Yes, share options", "goto": "trip"}, {"id": "call", "title": "Call me", "action": "handoff"}, {"id": "notnow", "title": "Not now", "goto": "end"}]',
   NULL, NULL, NULL, false, true, 10),
  ('charter', 'trip', 'Trip details', 'text',
   'Please share your trip: from city, to city, date and number of passengers.', '[]', 'trip', 'trip_done', NULL, false, false, 20),
  ('charter', 'trip_done', 'Trip received', 'text',
   'Thank you! Our charter desk will send you options shortly.', '[]', NULL, NULL, NULL, true, false, 30),
  ('charter', 'end', 'Not now', 'text',
   'No problem, {{name}}. Message us here whenever you are ready to fly.', '[]', NULL, NULL, NULL, false, false, 40)
ON CONFLICT (brand, key) DO NOTHING;

INSERT INTO public.wa_reply_rule (brand, step_key, match_type, patterns, priority, action, goto_key, reply_text, seed_key) VALUES
  (NULL, NULL, 'exact', '{stop,unsubscribe,"stop messages","band karo","mat bhejo","message mat karo","do not message"}', 100, 'optout', NULL,
   'Done. You will not get more messages from us. Reply START any time to talk again.', 'optout'),
  (NULL, NULL, 'exact', '{start,hi,hello,hey,menu,restart,hii,helo}', 50, 'restart', NULL, NULL, 'restart'),
  (NULL, NULL, 'contains', '{counsellor,counselor,"call me","talk to",baat,"call karo","phone karo","human","agent"}', 40, 'handoff', NULL,
   'Sure, our counsellor will call you shortly. You can also call us on {{counsellor_phone}}.', 'handoff'),
  (NULL, NULL, 'contains', '{fee,fees,cost,price,kitna,kharcha,"how much",charges,loan,emi}', 30, 'handoff', NULL,
   'Our counsellor will share the complete details on a call. They will reach you shortly.', 'fees'),
  ('aviation', NULL, 'contains', '{brochure,pdf,details,syllabus}', 20, 'send_brochure', NULL, NULL, 'brochure'),
  ('aviation', NULL, 'contains', '{"book free counselling","free counselling",counselling,"book a call","demo"}', 25, 'book_counselling', NULL, NULL, 'book'),
  (NULL, NULL, 'exact', '{"not interested","no thanks","not now","just browsing"}', 15, 'end', NULL, NULL, 'not_interested'),
  ('aviation', 'welcome', 'synonym', '{student,"i am student","im student","main student",beta,"self"}', 10, 'goto', 'pcm', NULL, 'role_student'),
  ('aviation', 'welcome', 'synonym', '{parent,father,mother,papa,mummy,"my son","my daughter",guardian}', 10, 'goto', 'pcm', NULL, 'role_parent'),
  ('aviation', 'pcm', 'synonym', '{yes,haan,ha,yeah,yep,done,"pcm hai"}', 10, 'goto', 'city', NULL, 'pcm_yes'),
  ('aviation', 'pcm', 'synonym', '{no,nahi,nope,"not pcm",commerce,arts,biology}', 10, 'goto', 'nios', NULL, 'pcm_no'),
  ('aviation', NULL, 'button', '{"yes, call me"}', 30, 'book_counselling', NULL, NULL, 'followup_call'),
  ('aviation', NULL, 'button', '{"send brochure"}', 30, 'send_brochure', NULL, NULL, 'followup_brochure')
ON CONFLICT (seed_key) DO NOTHING;

-- Inbound photos, voice notes and documents (private).
DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit)
    VALUES ('wa-media', 'wa-media', false, 16777216) ON CONFLICT (id) DO NOTHING;
  END IF;
END $$;

-- wa-worker every minute (sends, follow-ups, retries, unprocessed webhooks, phone alerts). New leads also wake it at once.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-wa-worker';
    PERFORM cron.schedule('crm-wa-worker', '* * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/wa-worker',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"reason": "cron"}'::jsonb, timeout_milliseconds := 120000)
      WHERE EXISTS (SELECT 1 FROM public.wa_number WHERE phone_number_id IS NOT NULL)
    $job$);
  END IF;
END $$;
