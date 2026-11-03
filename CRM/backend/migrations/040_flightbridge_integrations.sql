-- 040: FlightBridge integrations (API keys saved in the app, encrypted), engine lock.
-- COPY of nikkk07/FlightBridge-AI db/migrations/004_integrations.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 42e1f55e620df946daf2727407781b55f801d335c08734402509ad97cb5edacb
-- Apply AFTER 039 in the Supabase SQL editor. Additive; touches only schema 'flightbridge'.

-- FlightBridge 004: API keys entered in the app (encrypted), integration settings, and a single-runner engine lock.
-- Canonical source: nikkk07/FlightBridge-AI db/migrations/004_integrations.sql (copied to CRM as 040).
-- Every name is schema-qualified (the Supabase SQL Editor does not honour SET search_path). Idempotent.
-- Reversible: DROP TABLE flightbridge.integration_secret, flightbridge.engine_lease;
--   DELETE FROM flightbridge.system_setting WHERE key='integrations'.
SET client_min_messages = warning;

-- API keys. Only ciphertext is stored (Fernet; key derived from the server's FB_SECRETS_KEY or SECRET_KEY).
-- The app never returns a stored key: it shows the last 4 characters and the result of the last test.
CREATE TABLE IF NOT EXISTS flightbridge.integration_secret (
    name               TEXT PRIMARY KEY CHECK (name IN ('google_places_api_key','groq_api_key','gemini_api_key',
                                                        'hostinger_mail_api_token','hostinger_mailbox_resource_id')),
    ciphertext         TEXT NOT NULL,
    last4              TEXT NOT NULL,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID REFERENCES public.employee(id),
    last_test_at       TIMESTAMPTZ,
    last_test_ok       BOOLEAN,
    last_test_message  TEXT
);

-- Only one engine cycle at a time, wherever it runs (CRM server, GitHub Actions, the Mac).
CREATE TABLE IF NOT EXISTS flightbridge.engine_lease (
    name         TEXT PRIMARY KEY,
    holder       TEXT,
    lease_until  TIMESTAMPTZ
);

INSERT INTO flightbridge.system_setting (key, value) VALUES
    ('integrations', '{"engine_in_crm": true, "llm_provider": "none", "llm_model": "", "inbound_source": "none"}'::jsonb)
ON CONFLICT (key) DO NOTHING;

RESET client_min_messages;
