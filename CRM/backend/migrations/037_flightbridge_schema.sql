-- 037: FlightBridge partnership module schema.
-- COPY of nikkk07/FlightBridge-AI db/migrations/001_flightbridge_schema.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 377b72f048d4093df8f8e5f0441b2d196fe7e4acdc0cee0a28b19fb62e777557
-- Apply in the Supabase SQL editor like earlier migrations. Creates schema 'flightbridge' only; public tables untouched.

-- FlightBridge AI schema (canonical source: nikkk07/FlightBridge-AI db/migrations/001_flightbridge_schema.sql)
-- Lives in its own Postgres schema so it can never collide with CRM tables in `public`.
-- Additive only: creates schema `flightbridge`; touches nothing in `public` except FKs to public.employee(id).
-- Idempotent: safe to re-run.
-- Reversible: DROP SCHEMA flightbridge CASCADE;  (destroys all FlightBridge data)

CREATE SCHEMA IF NOT EXISTS flightbridge;
SET client_min_messages = warning;
SET search_path = flightbridge, public;

-- ---------------------------------------------------------------- settings / kill switch
CREATE TABLE IF NOT EXISTS system_setting (
    key         TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID REFERENCES public.employee(id)
);
-- Kill switch defaults to ENGAGED (no outbound) and must be released deliberately.
INSERT INTO system_setting (key, value) VALUES
    ('outbound_kill_switch', 'true'::jsonb),
    ('auto_reply_kill_switch', 'true'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- append-only audit
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL PRIMARY KEY,
    at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_type  TEXT NOT NULL CHECK (actor_type IN ('system','employee')),
    actor_id    UUID,
    action      TEXT NOT NULL,
    entity      TEXT NOT NULL,
    entity_id   TEXT,
    payload     JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_fb_audit_entity ON audit_log (entity, entity_id, at DESC);

CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% on %.% is forbidden (append-only)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END $$;
DROP TRIGGER IF EXISTS trg_audit_append_only ON audit_log;
CREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---------------------------------------------------------------- regulators
CREATE TABLE IF NOT EXISTS aviation_authority (
    code          TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    country       CHAR(2) NOT NULL,
    register_url  TEXT,
    retrieval     TEXT NOT NULL CHECK (retrieval IN ('pdf_parse','human_lookup','per_state_register')),
    notes         TEXT
);
INSERT INTO aviation_authority (code, name, country, register_url, retrieval, notes) VALUES
 ('DGCA',   'Directorate General of Civil Aviation', 'IN', 'https://www.dgca.gov.in/digigov-portal/jsp/dgca/topHeader/aboutDGCA/Ranking%20of%20FTOs-April%202026.pdf', 'pdf_parse', 'MoCA count: 41 FTOs / 63 bases till 2026-07-02'),
 ('UK_CAA', 'UK Civil Aviation Authority', 'GB', 'https://www.caa.co.uk/publication/pid/2854', 'pdf_parse', 'SD31 = ATOs, SD30 = DTOs'),
 ('FAA',    'Federal Aviation Administration', 'US', 'https://www.faa.gov/av-info/facility-dashboard', 'human_lookup', 'No documented export'),
 ('TC',     'Transport Canada', 'CA', 'https://tc.canada.ca/en/aviation/licensing-pilots-personnel/getting-trained-pilot-crew-member/how-select-flying-school', 'human_lookup', 'FTU search'),
 ('CASA',   'Civil Aviation Safety Authority', 'AU', 'https://www.casa.gov.au/search-centre/flight-training-operators', 'human_lookup', 'Full list robots-disallowed; dedupe on ARN'),
 ('EU_NCA', 'EU national competent authority (per state)', 'EU', NULL, 'per_state_register', 'EASA list is not a complete directory')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------- organisations
CREATE TABLE IF NOT EXISTS organisation (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name              TEXT NOT NULL,
    country           CHAR(2) NOT NULL,
    region            TEXT,
    city              TEXT,
    website_domain    TEXT,
    entity_type       TEXT NOT NULL DEFAULT 'unknown'
                      CHECK (entity_type IN ('corporate','sole_trader','partnership','scottish_partnership','government','unknown')),
    org_kind          TEXT NOT NULL DEFAULT 'flying_school'
                      CHECK (org_kind IN ('flying_school','sim_centre','operator','consultancy','recruiter','other')),
    status            TEXT NOT NULL DEFAULT 'discovered'
                      CHECK (status IN ('discovered','research_pending','research_completed','authority_verified',
                                        'contact_verified','qualified','rejected','needs_human_review',
                                        'ready_for_outreach','contacted','interested','negotiation','partner')),
    rejection_reason  TEXT,
    discovered_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    CONSTRAINT rejected_needs_reason CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_fb_org_country_status ON organisation (country, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_org_domain ON organisation (lower(website_domain))
    WHERE website_domain IS NOT NULL AND deleted_at IS NULL;

-- Multiple identifiers per organisation drive de-duplication (never name similarity alone).
CREATE TABLE IF NOT EXISTS organisation_identifier (
    id          BIGSERIAL PRIMARY KEY,
    org_id      UUID NOT NULL REFERENCES organisation(id),
    scheme      TEXT NOT NULL CHECK (scheme IN ('dgca_fto','uk_caa_ref','faa_cert','tc_ftu','casa_arn','eu_nca_ref','google_place_id','domain')),
    value       TEXT NOT NULL,
    source_url  TEXT,
    added_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (scheme, value)
);

CREATE TABLE IF NOT EXISTS regulatory_approval (
    id              BIGSERIAL PRIMARY KEY,
    org_id          UUID NOT NULL REFERENCES organisation(id),
    authority_code  TEXT NOT NULL REFERENCES aviation_authority(code),
    classification  TEXT NOT NULL CHECK (classification IN (
                        'FTO_DGCA','ATO_UK','DTO_UK','ATO_EU_NCA','DTO_EU_NCA','PART141_FAA',
                        'PART61_OPERATOR_UNVERIFIED','FTU_TC','PART141_CASA','PART142_CASA','UNCLASSIFIED')),
    approval_ref    TEXT,
    courses         JSONB NOT NULL DEFAULT '[]'::jsonb,
    status          TEXT NOT NULL CHECK (status IN ('listed_in_register','verified_by_human','not_found','expired')),
    source_url      TEXT NOT NULL,
    source_version  TEXT,
    checked_at      TIMESTAMPTZ NOT NULL,
    checked_by      UUID REFERENCES public.employee(id),
    next_check_due  TIMESTAMPTZ NOT NULL,
    UNIQUE (org_id, authority_code, classification)
);

-- ---------------------------------------------------------------- research provenance
CREATE TABLE IF NOT EXISTS website_page (
    id              BIGSERIAL PRIMARY KEY,
    org_id          UUID NOT NULL REFERENCES organisation(id),
    url             TEXT NOT NULL UNIQUE,
    http_status     INT,
    robots_allowed  BOOLEAN NOT NULL,
    content_sha256  TEXT,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS research_fact (
    id            BIGSERIAL PRIMARY KEY,
    org_id        UUID NOT NULL REFERENCES organisation(id),
    fact_key      TEXT NOT NULL,
    fact_value    JSONB NOT NULL,
    source_url    TEXT NOT NULL,
    extracted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified      BOOLEAN NOT NULL DEFAULT false,
    UNIQUE (org_id, fact_key, source_url)
);

-- ---------------------------------------------------------------- contacts
CREATE TABLE IF NOT EXISTS contact (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id              UUID NOT NULL REFERENCES organisation(id),
    email               TEXT NOT NULL CHECK (email = lower(btrim(email)) AND email LIKE '%_@_%'),
    email_hash          TEXT NOT NULL,
    email_domain        TEXT NOT NULL,
    is_role_address     BOOLEAN NOT NULL,
    person_name         TEXT,
    role                TEXT,
    source_url          TEXT NOT NULL,
    discovered_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    verification_level  TEXT NOT NULL DEFAULT 'syntax'
                        CHECK (verification_level IN ('syntax','domain','mx','delivered','bounced')),
    UNIQUE (org_id, email_hash)
);
CREATE INDEX IF NOT EXISTS idx_fb_contact_hash ON contact (email_hash);

-- Legal-condition facts (e.g. CASL conspicuous publication) only count with evidence.
CREATE TABLE IF NOT EXISTS contact_fact_evidence (
    id            BIGSERIAL PRIMARY KEY,
    contact_id    UUID NOT NULL REFERENCES contact(id),
    fact          TEXT NOT NULL,
    source_url    TEXT NOT NULL,
    excerpt       TEXT NOT NULL CHECK (length(btrim(excerpt)) > 0),
    method        TEXT NOT NULL CHECK (method IN ('automated_extraction','human_verified')),
    verified_by   UUID REFERENCES public.employee(id),
    verified_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    CONSTRAINT human_needs_actor CHECK (method <> 'human_verified' OR verified_by IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_fb_cfe_contact ON contact_fact_evidence (contact_id, fact, expires_at DESC);

CREATE TABLE IF NOT EXISTS qualification_result (
    id                  BIGSERIAL PRIMARY KEY,
    org_id              UUID NOT NULL REFERENCES organisation(id),
    score               NUMERIC(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
    weights_version     TEXT NOT NULL,
    breakdown           JSONB NOT NULL,
    missing             JSONB NOT NULL DEFAULT '[]'::jsonb,
    risks               JSONB NOT NULL DEFAULT '[]'::jsonb,
    recommended_action  TEXT NOT NULL,
    confidence          TEXT NOT NULL CHECK (confidence IN ('low','medium','high')),
    computed_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- suppression (never deleted)
CREATE TABLE IF NOT EXISTS public_mail_domain (domain TEXT PRIMARY KEY);
INSERT INTO public_mail_domain (domain) VALUES
 ('gmail.com'),('googlemail.com'),('outlook.com'),('hotmail.com'),('live.com'),('msn.com'),('yahoo.com'),
 ('yahoo.co.in'),('yahoo.co.uk'),('icloud.com'),('me.com'),('aol.com'),('proton.me'),('protonmail.com'),
 ('gmx.com'),('gmx.de'),('web.de'),('zoho.com'),('yandex.com'),('mail.com'),('rediffmail.com'),('bigpond.com')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS suppression (
    id          BIGSERIAL PRIMARY KEY,
    scope       TEXT NOT NULL CHECK (scope IN ('contact','organisation','domain')),
    email_hash  TEXT,
    org_id      UUID REFERENCES organisation(id),
    domain      TEXT CHECK (domain IS NULL OR domain = lower(domain)),
    reason      TEXT NOT NULL CHECK (reason IN ('unsubscribe','rejection','complaint','hard_bounce','legal','manual')),
    source_ref  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID REFERENCES public.employee(id),
    CONSTRAINT scope_columns CHECK (
        (scope = 'contact'      AND email_hash IS NOT NULL AND org_id IS NULL AND domain IS NULL) OR
        (scope = 'organisation' AND org_id IS NOT NULL     AND email_hash IS NULL AND domain IS NULL) OR
        (scope = 'domain'       AND domain IS NOT NULL     AND email_hash IS NULL AND org_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_supp_contact ON suppression (email_hash) WHERE scope = 'contact';
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_supp_org     ON suppression (org_id)     WHERE scope = 'organisation';
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_supp_domain  ON suppression (domain)     WHERE scope = 'domain';

CREATE OR REPLACE FUNCTION suppression_domain_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.scope = 'domain' AND EXISTS (SELECT 1 FROM flightbridge.public_mail_domain p WHERE p.domain = NEW.domain) THEN
        RAISE EXCEPTION 'domain-scope suppression of shared provider % would block unrelated organisations; use contact or organisation scope', NEW.domain;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_suppression_domain_guard ON suppression;
CREATE TRIGGER trg_suppression_domain_guard BEFORE INSERT ON suppression
    FOR EACH ROW EXECUTE FUNCTION suppression_domain_guard();
DROP TRIGGER IF EXISTS trg_suppression_append_only ON suppression;
CREATE TRIGGER trg_suppression_append_only BEFORE UPDATE OR DELETE ON suppression
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---------------------------------------------------------------- knowledge base (approved facts only)
CREATE TABLE IF NOT EXISTS knowledge_document (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        TEXT NOT NULL UNIQUE,
    category    TEXT NOT NULL CHECK (category IN ('verified_company_fact','approved_commercial','restricted','outdated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS document_version (
    id           BIGSERIAL PRIMARY KEY,
    document_id  UUID NOT NULL REFERENCES knowledge_document(id),
    version      INT NOT NULL,
    body         TEXT NOT NULL,
    evidence     TEXT NOT NULL,
    approved_by  UUID REFERENCES public.employee(id),
    approved_at  TIMESTAMPTZ,
    UNIQUE (document_id, version)
);

-- ---------------------------------------------------------------- email threads / messages
CREATE TABLE IF NOT EXISTS email_thread (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id              UUID REFERENCES organisation(id),
    contact_id          UUID REFERENCES contact(id),
    subject_normalised  TEXT,
    root_message_id     TEXT,
    provider_thread_id  TEXT,   -- only populated if a live test proves the provider supplies one
    status              TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open','awaiting_reply','awaiting_approval','closed','suppressed')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS email_message (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id         UUID NOT NULL REFERENCES email_thread(id),
    direction         TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
    rfc_message_id    TEXT UNIQUE,
    in_reply_to       TEXT,
    references_ids    TEXT[] NOT NULL DEFAULT '{}',
    provider_uid      BIGINT,
    provider_folder   TEXT,
    from_address      TEXT,
    to_addresses      TEXT[] NOT NULL DEFAULT '{}',
    subject           TEXT,
    body_text         TEXT,
    fb_ref_token      TEXT UNIQUE,
    occurred_at       TIMESTAMPTZ NOT NULL,
    stored_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider_folder, provider_uid)
);
CREATE INDEX IF NOT EXISTS idx_fb_msg_thread ON email_message (thread_id, occurred_at);

-- ---------------------------------------------------------------- AI drafts & human approval
CREATE TABLE IF NOT EXISTS ai_draft (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id           UUID REFERENCES email_thread(id),
    org_id              UUID NOT NULL REFERENCES organisation(id),
    contact_id          UUID NOT NULL REFERENCES contact(id),
    inbound_message_id  UUID REFERENCES email_message(id),
    kind                TEXT NOT NULL CHECK (kind IN ('initial','followup','reply')),
    risk                TEXT NOT NULL CHECK (risk IN ('GREEN','AMBER','RED')),
    intent              TEXT,
    summary             TEXT,
    extracted_questions JSONB NOT NULL DEFAULT '[]'::jsonb,
    subject             TEXT NOT NULL,
    body_text           TEXT NOT NULL,
    evidence            JSONB NOT NULL DEFAULT '[]'::jsonb,
    generator           TEXT NOT NULL,          -- template id or model id
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS approval_task (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    draft_id          UUID NOT NULL UNIQUE REFERENCES ai_draft(id),
    risk              TEXT NOT NULL CHECK (risk IN ('GREEN','AMBER','RED')),
    escalation_reason TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','approved','edited_approved','rejected','more_research','resolved')),
    assigned_to       UUID REFERENCES public.employee(id),
    decided_by        UUID REFERENCES public.employee(id),
    decided_at        TIMESTAMPTZ,
    final_subject     TEXT,
    final_body        TEXT,
    decision_note     TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decision_complete CHECK (
        status IN ('open') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
    CONSTRAINT approved_has_final CHECK (
        status NOT IN ('approved','edited_approved') OR (final_subject IS NOT NULL AND final_body IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_fb_approval_open ON approval_task (status, risk, created_at) WHERE status = 'open';

-- ---------------------------------------------------------------- compliance checks
CREATE TABLE IF NOT EXISTS compliance_check (
    id            BIGSERIAL PRIMARY KEY,
    outbound_id   UUID NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('jurisdiction','content')),
    decision      TEXT NOT NULL CHECK (decision IN ('ALLOW','HUMAN_REVIEW','BLOCK','PASS','FAIL')),
    rule_key      TEXT,
    rules_version TEXT NOT NULL,
    content_sha256 TEXT,
    reasons       JSONB NOT NULL DEFAULT '[]'::jsonb,
    evaluated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decision_matches_kind CHECK (
        (kind = 'jurisdiction' AND decision IN ('ALLOW','HUMAN_REVIEW','BLOCK')) OR
        (kind = 'content'      AND decision IN ('PASS','FAIL')))
);
DROP TRIGGER IF EXISTS trg_compliance_append_only ON compliance_check;
CREATE TRIGGER trg_compliance_append_only BEFORE UPDATE OR DELETE ON compliance_check
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---------------------------------------------------------------- outbound (transactional outbox)
CREATE TABLE IF NOT EXISTS outbound_message (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key       TEXT NOT NULL UNIQUE,
    contact_id            UUID NOT NULL REFERENCES contact(id),
    org_id                UUID NOT NULL REFERENCES organisation(id),
    thread_id             UUID REFERENCES email_thread(id),
    approval_task_id      UUID REFERENCES approval_task(id),
    reply_to_message_id   UUID REFERENCES email_message(id),
    kind                  TEXT NOT NULL CHECK (kind IN ('initial','followup','reply')),
    subject               TEXT NOT NULL,
    body_text             TEXT NOT NULL,
    content_sha256        TEXT NOT NULL,
    ref_token             TEXT NOT NULL UNIQUE,
    status                TEXT NOT NULL DEFAULT 'pending_checks'
                          CHECK (status IN ('pending_checks','blocked','needs_review','authorized',
                                            'dry_run_rendered','sending','sent','send_unknown','failed','cancelled')),
    eligibility_check_id  BIGINT REFERENCES compliance_check(id),
    content_check_id      BIGINT REFERENCES compliance_check(id),
    attempts              INT NOT NULL DEFAULT 0,
    last_error            TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    authorized_at         TIMESTAMPTZ,
    sent_at               TIMESTAMPTZ,
    CONSTRAINT authorized_requires_checks CHECK (
        status NOT IN ('authorized','dry_run_rendered','sending','sent','send_unknown')
        OR (eligibility_check_id IS NOT NULL AND content_check_id IS NOT NULL AND authorized_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_fb_outbound_status ON outbound_message (status, created_at);
-- One live outbound per contact+kind for initial outreach: a retry can never create a second intro.
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_one_initial_per_contact ON outbound_message (contact_id)
    WHERE kind = 'initial' AND status NOT IN ('blocked','cancelled','failed');

-- Database-level enforcement: an outbound row may only become authorized (or beyond) if the referenced
-- checks belong to THIS message, passed, were computed on THIS exact content, and are fresh (<= 15 min).
CREATE OR REPLACE FUNCTION outbound_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e flightbridge.compliance_check; c flightbridge.compliance_check;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status IN ('sent','dry_run_rendered','cancelled','blocked','failed')
       AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'outbound % is terminal (%), cannot move to %', OLD.id, OLD.status, NEW.status;
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.subject, NEW.body_text, NEW.contact_id) IS DISTINCT FROM (OLD.subject, OLD.body_text, OLD.contact_id) THEN
        RAISE EXCEPTION 'outbound content/recipient is immutable; create a new outbound row';
    END IF;
    IF NEW.status = 'authorized' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'authorized') THEN
        SELECT * INTO e FROM flightbridge.compliance_check WHERE id = NEW.eligibility_check_id;
        SELECT * INTO c FROM flightbridge.compliance_check WHERE id = NEW.content_check_id;
        IF e.id IS NULL OR e.outbound_id <> NEW.id OR e.kind <> 'jurisdiction' OR e.decision <> 'ALLOW' THEN
            RAISE EXCEPTION 'outbound % lacks a passing jurisdiction check', NEW.id;
        END IF;
        IF c.id IS NULL OR c.outbound_id <> NEW.id OR c.kind <> 'content' OR c.decision <> 'PASS'
           OR c.content_sha256 IS DISTINCT FROM NEW.content_sha256 THEN
            RAISE EXCEPTION 'outbound % lacks a passing content check for its exact content', NEW.id;
        END IF;
        IF e.evaluated_at < now() - interval '15 minutes' OR c.evaluated_at < now() - interval '15 minutes' THEN
            RAISE EXCEPTION 'outbound % compliance checks are stale', NEW.id;
        END IF;
    END IF;
    IF NEW.kind = 'reply' AND NEW.approval_task_id IS NULL AND NEW.status NOT IN ('pending_checks','blocked','cancelled') THEN
        RAISE EXCEPTION 'replies require an approval task in this release (auto-reply disabled)';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_outbound_guard ON outbound_message;
CREATE TRIGGER trg_outbound_guard BEFORE INSERT OR UPDATE ON outbound_message
    FOR EACH ROW EXECUTE FUNCTION outbound_guard();

-- ---------------------------------------------------------------- follow-ups
CREATE TABLE IF NOT EXISTS follow_up_task (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id         UUID NOT NULL REFERENCES email_thread(id),
    step              INT NOT NULL CHECK (step BETWEEN 1 AND 3),
    due_at            TIMESTAMPTZ NOT NULL,
    status            TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','cancelled','enqueued','done')),
    cancelled_reason  TEXT,
    UNIQUE (thread_id, step)
);

-- ---------------------------------------------------------------- durable job queue
CREATE TABLE IF NOT EXISTS job (
    id               BIGSERIAL PRIMARY KEY,
    kind             TEXT NOT NULL,
    payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
    idempotency_key  TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','done','failed','dead')),
    run_after        TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts         INT NOT NULL DEFAULT 0,
    max_attempts     INT NOT NULL DEFAULT 5,
    locked_by        TEXT,
    locked_until     TIMESTAMPTZ,
    last_error       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_fb_job_ready ON job (status, run_after) WHERE status IN ('queued','running');

RESET search_path;
RESET client_min_messages;
