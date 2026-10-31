-- 039: FlightBridge automation engine (worker run log, Run-now queue, autopilot settings, website profiles).
-- COPY of nikkk07/FlightBridge-AI db/migrations/003_automation.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 8d6940c3d3e49da9af395266c3838aedf88e88bdea3a37dfeb25a44c792b9832
-- Apply AFTER 038 in the Supabase SQL editor. Additive; touches only schema 'flightbridge'.

-- FlightBridge 003: automation engine — worker run log, run-now job queue, autopilot settings, website profiles.
-- Canonical source: nikkk07/FlightBridge-AI db/migrations/003_automation.sql (copied to CRM as 039).
-- Additive and idempotent. Reversible: DROP TABLE flightbridge.worker_run, flightbridge.job_request,
--   flightbridge.organisation_profile; DELETE FROM flightbridge.system_setting WHERE key='autopilot'.
SET client_min_messages = warning;
SET search_path = flightbridge, public;

-- One row per worker cycle, wherever it ran (GitHub Actions, the Mac, a manual run).
CREATE TABLE IF NOT EXISTS worker_run (
    id           BIGSERIAL PRIMARY KEY,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at  TIMESTAMPTZ,
    runner       TEXT NOT NULL,                 -- e.g. github-actions, mac, manual
    trigger      TEXT NOT NULL DEFAULT 'schedule' CHECK (trigger IN ('schedule','manual','queue')),
    status       TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','partial','failed')),
    stats        JSONB NOT NULL DEFAULT '{}'::jsonb,
    error        TEXT
);
CREATE INDEX IF NOT EXISTS idx_fb_worker_run_started ON worker_run (started_at DESC);

-- "Run now" requests from the app; the next worker cycle claims them (FOR UPDATE SKIP LOCKED).
CREATE TABLE IF NOT EXISTS job_request (
    id            BIGSERIAL PRIMARY KEY,
    kind          TEXT NOT NULL CHECK (kind IN ('cycle','research_school','find_websites','research_batch')),
    org_id        UUID REFERENCES organisation(id),
    requested_by  UUID REFERENCES public.employee(id),
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','done','failed')),
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    result        JSONB,
    CONSTRAINT research_school_needs_org CHECK (kind <> 'research_school' OR org_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_fb_job_queued ON job_request (requested_at) WHERE status = 'queued';
-- At most one queued request of each kind per school (stops double-clicks piling up work).
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_job_queued ON job_request (kind, coalesce(org_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status = 'queued';

-- What the school's own website says (signals + short summary), refreshed on each research pass.
CREATE TABLE IF NOT EXISTS organisation_profile (
    org_id      UUID PRIMARY KEY REFERENCES organisation(id),
    summary     TEXT,
    signals     JSONB NOT NULL DEFAULT '{}'::jsonb,   -- has_cpl, has_ppl, intl_students, fleet_published, ...
    evidence    JSONB NOT NULL DEFAULT '[]'::jsonb,   -- [{signal, url, excerpt}]
    generator   TEXT NOT NULL,                        -- keywords-v1 | groq:<model> | gemini:<model>
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_fb_org_country_region ON organisation (country, region) WHERE deleted_at IS NULL;

-- Which automatic stages run each cycle. Sending stays governed by DRY_RUN / OUTBOUND_ENABLED / the kill switch.
INSERT INTO system_setting (key, value) VALUES
    ('autopilot', '{"find_websites": true, "research": true, "qualify": true, "draft": true, "batch_size": 8}'::jsonb)
ON CONFLICT (key) DO NOTHING;

RESET search_path;
RESET client_min_messages;
