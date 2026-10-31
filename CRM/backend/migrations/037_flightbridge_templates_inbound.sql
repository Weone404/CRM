-- 037: FlightBridge templates, inbound processing, AI classification, follow-ups.
-- COPY of nikkk07/FlightBridge-AI db/migrations/002_templates_inbound_followups.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 02b59a75568c03b3c4fd696921e2e9cf24c9fecb83c96c3617ce3c59f81c2c97
-- Apply AFTER 036 in the Supabase SQL editor. Additive; touches only schema 'flightbridge'.

-- FlightBridge 002: owner-pasted outreach templates, inbound processing, AI classification, follow-up settings.
-- Canonical source: nikkk07/FlightBridge-AI db/migrations/002_templates_inbound_followups.sql (copied to CRM as 037).
-- Additive and idempotent. Reversible: DROP TABLE flightbridge.outreach_template, flightbridge.ai_classification,
--   flightbridge.webhook_event, flightbridge.mailbox_cursor CASCADE; ALTER TABLE ... DROP COLUMN (listed below).
SET client_min_messages = warning;
SET search_path = flightbridge, public;

-- ---------------------------------------------------------------- outreach templates (pasted in the CRM)
CREATE TABLE IF NOT EXISTS outreach_template (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         TEXT NOT NULL CHECK (kind IN ('initial','followup_1','followup_2','followup_3')),
    version      INT NOT NULL,
    subject      TEXT NOT NULL CHECK (length(btrim(subject)) BETWEEN 1 AND 150),
    body         TEXT NOT NULL CHECK (length(btrim(body)) BETWEEN 20 AND 20000),
    status       TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','archived')),
    validation   JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_by   UUID REFERENCES public.employee(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by  UUID REFERENCES public.employee(id),
    approved_at  TIMESTAMPTZ,
    UNIQUE (kind, version),
    CONSTRAINT approved_has_approver CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
-- At most one approved template per kind.
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_template_one_approved ON outreach_template (kind) WHERE status = 'approved';

ALTER TABLE ai_draft ADD COLUMN IF NOT EXISTS template_id UUID REFERENCES outreach_template(id);

-- ---------------------------------------------------------------- inbound processing
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS mailbox TEXT;
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS is_bounce BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS is_auto_reply BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS is_unsubscribe BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS match_method TEXT
    CHECK (match_method IS NULL OR match_method IN ('in_reply_to','ref_token','sender_address','sender_domain','unmatched','outbound'));
ALTER TABLE email_message ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;
-- UIDs are only unique per mailbox+folder: replace 001's (folder, uid) uniqueness.
ALTER TABLE email_message DROP CONSTRAINT IF EXISTS email_message_provider_folder_provider_uid_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_msg_mailbox_folder_uid ON email_message (mailbox, provider_folder, provider_uid)
    WHERE provider_uid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fb_msg_unprocessed ON email_message (stored_at) WHERE direction = 'inbound' AND processed_at IS NULL;

-- Where each mailbox/folder has been read up to (polling reconciliation; webhooks are only hints).
CREATE TABLE IF NOT EXISTS mailbox_cursor (
    mailbox     TEXT NOT NULL,
    folder      TEXT NOT NULL,
    last_uid    BIGINT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (mailbox, folder)
);

-- Webhook deliveries (deduplicated). Authenticated with the Bearer secret before insert.
CREATE TABLE IF NOT EXISTS webhook_event (
    id            BIGSERIAL PRIMARY KEY,
    provider      TEXT NOT NULL,
    event_key     TEXT NOT NULL,
    payload       JSONB NOT NULL,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at  TIMESTAMPTZ,
    UNIQUE (provider, event_key)
);

-- ---------------------------------------------------------------- AI classification
CREATE TABLE IF NOT EXISTS ai_classification (
    id            BIGSERIAL PRIMARY KEY,
    message_id    UUID NOT NULL UNIQUE REFERENCES email_message(id),
    intent        TEXT NOT NULL,
    risk          TEXT NOT NULL CHECK (risk IN ('GREEN','AMBER','RED')),
    confidence    NUMERIC(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    signals       JSONB NOT NULL DEFAULT '[]'::jsonb,
    questions     JSONB NOT NULL DEFAULT '[]'::jsonb,
    injection     BOOLEAN NOT NULL DEFAULT false,
    classifier    TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- follow-up settings
ALTER TABLE follow_up_task ADD COLUMN IF NOT EXISTS outbound_id UUID REFERENCES outbound_message(id);
ALTER TABLE follow_up_task ADD COLUMN IF NOT EXISTS draft_id UUID REFERENCES ai_draft(id);
INSERT INTO system_setting (key, value) VALUES
    ('followup_schedule_days', '[4, 9, 16]'::jsonb),
    ('followup_business_hours', '{"start": 9, "end": 17}'::jsonb)
ON CONFLICT (key) DO NOTHING;

RESET search_path;
RESET client_min_messages;
