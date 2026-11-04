-- 057: FlightBridge world sweep (whole-Earth school search), Google free-quota meter, "Check needed" for countries without a register.
-- COPY of nikkk07/FlightBridge-AI flightbridge/migrations/007_world_sweep.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: 842b93c1585060d67b08e55e34f7990b63377bb2d427833ba2a7c4c222a7e337
-- Applied automatically by the FlightBridge engine on start-up (flightbridge db.ensure_schema). Additive; schema 'flightbridge' only.

-- FlightBridge 007: whole-world school sweep, Google free-quota meter, "Check needed" for countries without a register.
-- Additive and idempotent. Reversible: DROP TABLE flightbridge.sweep_cell, flightbridge.sweep_country,
-- flightbridge.detection, flightbridge.google_usage; the two CHECK lists below only gain values.

-- ---------------------------------------------------------------- Google Maps Platform usage, per calendar month (UTC)
-- One row per month and SKU. A call is counted BEFORE it is made, atomically, and refused once the cap is reached,
-- so every runner together stays inside the free monthly allowance.
CREATE TABLE IF NOT EXISTS flightbridge.google_usage (
    month   DATE NOT NULL,
    sku     TEXT NOT NULL,
    calls   INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (month, sku)
);

-- ---------------------------------------------------------------- world sweep: countries in order, 1-degree squares
CREATE TABLE IF NOT EXISTS flightbridge.sweep_country (
    country       CHAR(2) PRIMARY KEY,
    priority      INTEGER NOT NULL,
    pass          INTEGER NOT NULL DEFAULT 1,
    cells_total   INTEGER NOT NULL DEFAULT 0,
    cells_done    INTEGER NOT NULL DEFAULT 0,
    schools_found INTEGER NOT NULL DEFAULT 0,
    schools_new   INTEGER NOT NULL DEFAULT 0,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    enabled       BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS flightbridge.sweep_cell (
    id          BIGSERIAL PRIMARY KEY,
    country     CHAR(2) NOT NULL,
    pass        INTEGER NOT NULL DEFAULT 1,
    lat0        DOUBLE PRECISION NOT NULL,
    lng0        DOUBLE PRECISION NOT NULL,
    lat1        DOUBLE PRECISION NOT NULL,
    lng1        DOUBLE PRECISION NOT NULL,
    depth       SMALLINT NOT NULL DEFAULT 0,
    parent_id   BIGINT REFERENCES flightbridge.sweep_cell(id),
    status      TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','scanning','done','split','error')),
    results     INTEGER,
    schools     INTEGER,
    new_schools INTEGER,
    calls       INTEGER NOT NULL DEFAULT 0,
    error       TEXT,
    searched_at TIMESTAMPTZ,
    UNIQUE (country, pass, depth, lat0, lng0)
);
CREATE INDEX IF NOT EXISTS idx_fb_sweep_cell_queue ON flightbridge.sweep_cell (status, pass, country) WHERE status IN ('queued','scanning');

-- Every school the sweep (or an area search) sees, with where it is: feeds the live globe in the CRM.
CREATE TABLE IF NOT EXISTS flightbridge.detection (
    id        BIGSERIAL PRIMARY KEY,
    org_id    UUID NOT NULL REFERENCES flightbridge.organisation(id),
    cell_id   BIGINT REFERENCES flightbridge.sweep_cell(id),
    country   CHAR(2) NOT NULL,
    name      TEXT NOT NULL,
    lat       DOUBLE PRECISION NOT NULL,
    lng       DOUBLE PRECISION NOT NULL,
    is_new    BOOLEAN NOT NULL,
    at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fb_detection_at ON flightbridge.detection (at DESC);
CREATE INDEX IF NOT EXISTS idx_fb_detection_org ON flightbridge.detection (org_id);

-- ---------------------------------------------------------------- a person's check for countries with no register
INSERT INTO flightbridge.aviation_authority (code, name, country, register_url, retrieval, notes) VALUES
 ('NATIONAL_CAA', 'The country''s national civil aviation authority (checked by a person)', 'ZZ', NULL, 'human_lookup',
  'Used where FlightBridge has no register for the country yet; the person records the authority page they checked')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE flightbridge.regulatory_approval DROP CONSTRAINT IF EXISTS regulatory_approval_classification_check;
ALTER TABLE flightbridge.regulatory_approval ADD CONSTRAINT regulatory_approval_classification_check CHECK (classification IN (
    'FTO_DGCA','ATO_UK','DTO_UK','ATO_EU_NCA','DTO_EU_NCA','PART141_FAA','PART61_OPERATOR_UNVERIFIED','FTU_TC',
    'PART141_CASA','PART142_CASA','UNCLASSIFIED','CRICOS_PROVIDER','SEVP_M1','DLI_CA','PART141_NZ','NZQA_PROVIDER',
    'NATIONAL_APPROVAL'));
