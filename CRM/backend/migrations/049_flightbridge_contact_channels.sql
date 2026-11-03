-- 049: FlightBridge contact channels (LinkedIn / Facebook / enquiry-form links found on a school's own website).
-- COPY of nikkk07/FlightBridge-AI flightbridge/migrations/006_contact_channels.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 4c65217159d1ab6a47f2349554e19245e8e55931d8f303f465259f1e03c4ad88
-- Applied automatically by the CRM server on start-up (flightbridge db.ensure_schema). Additive; schema 'flightbridge' only.

-- FlightBridge 006: other ways to reach a school, found on its own website (LinkedIn page, enquiry form, Facebook …).
-- These are links for a person to use; nothing is scraped from LinkedIn or other platforms.
CREATE TABLE IF NOT EXISTS flightbridge.contact_channel (
    id          BIGSERIAL PRIMARY KEY,
    org_id      UUID NOT NULL REFERENCES flightbridge.organisation(id),
    kind        TEXT NOT NULL CHECK (kind IN ('contact_form','linkedin','facebook','instagram','x','youtube','whatsapp')),
    url         TEXT NOT NULL,
    source_url  TEXT,
    found_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (org_id, kind, url)
);
CREATE INDEX IF NOT EXISTS idx_fb_contact_channel_org ON flightbridge.contact_channel (org_id);

ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS contacts_searched_at TIMESTAMPTZ;

