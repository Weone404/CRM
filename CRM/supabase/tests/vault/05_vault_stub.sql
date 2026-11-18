-- Local test harness only: the other key stores 111 reads (AI keys, FlightBridge keys, CRM audit log).
CREATE TABLE IF NOT EXISTS public.audit_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor uuid, action text NOT NULL,
  entity text NOT NULL, ts timestamptz DEFAULT now(), payload jsonb);
-- The ADS stub names the time column "at"; production (001_init_schema) calls it "ts".
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS ts timestamptz DEFAULT now();
CREATE TABLE IF NOT EXISTS crm_private.ai_integration (provider text PRIMARY KEY, vault_id uuid NOT NULL, last4 text NOT NULL,
  enabled boolean NOT NULL DEFAULT true, updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid);
CREATE SCHEMA IF NOT EXISTS flightbridge;
CREATE TABLE IF NOT EXISTS flightbridge.integration_secret (name text PRIMARY KEY, ciphertext text NOT NULL, last4 text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid, last_test_at timestamptz, last_test_ok boolean, last_test_message text);
