-- 065: FlightBridge 24x7 Verify worker: per-school claim and schedule columns, and the AI website reading.
-- COPY of nikkk07/FlightBridge-AI flightbridge/migrations/009_verify.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: b4ef3e69267fef8ce2d88cef37b26f9be1cbd383b6fe42b1232bb2e9807582cf
-- Applied automatically by the FlightBridge engine on start-up (flightbridge db.ensure_schema). Additive; schema 'flightbridge' only.

-- 009: the 24x7 Verify worker (flightbridge/verify.py). Each school waiting for a decision is claimed by one runner at
-- a time (Mac Mini and CRM server share the queue), and comes back on its own schedule when it is waiting for
-- something (the monthly web-search allowance, a list upload, a week before re-checking).
ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS verify_claim_until TIMESTAMPTZ;
ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS verify_next_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_fb_org_verify_queue ON flightbridge.organisation (verify_next_at NULLS FIRST)
  WHERE deleted_at IS NULL AND eligibility IN ('unknown', 'eligible_claimed');
-- What the AI read on the school's website: which credential claims are real, the company's legal name(s), with quotes
ALTER TABLE flightbridge.organisation_profile ADD COLUMN IF NOT EXISTS ai JSONB;
