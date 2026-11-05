-- 061: FlightBridge official-list uploads (FAA Part 141, Transport Canada FTUs, IRCC DLIs, CASA) that a person downloads and uploads.
-- COPY of nikkk07/FlightBridge-AI flightbridge/migrations/008_register_uploads.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 7758c1bea9a2d6fd2afa220eca5485ecf27613e28e875be908b038efdb9cce6a
-- Applied automatically by the FlightBridge engine on start-up (flightbridge db.ensure_schema). Additive; schema 'flightbridge' only.

-- 008: official school lists uploaded by a person in the CRM (FAA Part 141, Transport Canada FTUs, IRCC DLIs, CASA ...).
-- The CRM stores the file here; the engine imports it on its next cycle, then clears the file content and keeps the
-- result (rows read, schools matched / added) for the audit trail.
CREATE TABLE IF NOT EXISTS flightbridge.register_upload (
    id           BIGSERIAL PRIMARY KEY,
    kind         TEXT NOT NULL,                 -- see flightbridge/research/list_upload.py KINDS
    filename     TEXT NOT NULL,
    content_b64  TEXT,
    sha256       TEXT NOT NULL,
    uploaded_by  UUID REFERENCES public.employee(id),
    uploaded_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'imported', 'error')),
    result       JSONB,
    processed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_fb_register_upload_pending ON flightbridge.register_upload (uploaded_at) WHERE status = 'pending';
ALTER TABLE flightbridge.register_upload DROP CONSTRAINT IF EXISTS register_upload_kind_check;
ALTER TABLE flightbridge.register_upload ADD CONSTRAINT register_upload_kind_check CHECK (kind ~ '^[a-z0-9_]{2,40}$');
-- Tavily web-search key can be saved like the other keys
ALTER TABLE flightbridge.integration_secret DROP CONSTRAINT IF EXISTS integration_secret_name_check;
ALTER TABLE flightbridge.integration_secret ADD CONSTRAINT integration_secret_name_check CHECK (name = ANY (ARRAY[
  'google_places_api_key', 'groq_api_key', 'gemini_api_key', 'hostinger_mail_api_token', 'hostinger_mailbox_resource_id',
  'tavily_api_key']));
