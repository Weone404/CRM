-- 041: FlightBridge Country > State > Area discovery, per-country eligibility, phone numbers.
-- COPY of nikkk07/FlightBridge-AI db/migrations/005_areas_eligibility.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: d1012401d2aed7367e7f06ca38649ea956e25a9d77e106bf55b224cb69e5fec7
-- Apply AFTER 040 in the Supabase SQL editor. Additive; touches only schema 'flightbridge'.

-- FlightBridge 005: Country > State > Area discovery, per-country eligibility, phone numbers, new official registers.
-- Canonical source: nikkk07/FlightBridge-AI db/migrations/005_areas_eligibility.sql (copied to CRM as 041).
-- Every name is schema-qualified. Idempotent. Additive (CHECK constraints are widened, never narrowed).
-- Reversible: DROP TABLE flightbridge.contact_phone, flightbridge.area CASCADE;
--   ALTER TABLE flightbridge.organisation DROP COLUMN area_id, DROP COLUMN eligibility, DROP COLUMN eligibility_reasons,
--   DROP COLUMN eligibility_checked_at; ALTER TABLE flightbridge.job_request DROP COLUMN area_id.
SET client_min_messages = warning;

-- ---------------------------------------------------------------- areas (training hubs and student-demand hubs)
CREATE TABLE IF NOT EXISTS flightbridge.area (
    id                BIGSERIAL PRIMARY KEY,
    country           CHAR(2) NOT NULL,
    region            TEXT NOT NULL,                       -- state / province / region
    name              TEXT NOT NULL,                       -- e.g. "Sanford", "Ramphal Chowk (Dwarka)"
    kind              TEXT NOT NULL DEFAULT 'training_hub' CHECK (kind IN ('training_hub','demand_hub')),
    lat               DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng               DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
    radius_km         INT NOT NULL DEFAULT 40 CHECK (radius_km BETWEEN 2 AND 50),
    enabled           BOOLEAN NOT NULL DEFAULT true,
    notes             TEXT,
    last_searched_at  TIMESTAMPTZ,
    last_result       JSONB,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (country, region, name)
);

ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS area_id BIGINT REFERENCES flightbridge.area(id);
ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS eligibility TEXT NOT NULL DEFAULT 'unknown';
ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS eligibility_reasons JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE flightbridge.organisation ADD COLUMN IF NOT EXISTS eligibility_checked_at TIMESTAMPTZ;
ALTER TABLE flightbridge.organisation DROP CONSTRAINT IF EXISTS organisation_eligibility_check;
ALTER TABLE flightbridge.organisation ADD CONSTRAINT organisation_eligibility_check
    CHECK (eligibility IN ('unknown','eligible_verified','eligible_claimed','unqualified'));
ALTER TABLE flightbridge.organisation DROP CONSTRAINT IF EXISTS organisation_org_kind_check;
ALTER TABLE flightbridge.organisation ADD CONSTRAINT organisation_org_kind_check
    CHECK (org_kind IN ('flying_school','ground_school','sim_centre','operator','consultancy','recruiter','other'));
CREATE INDEX IF NOT EXISTS idx_fb_org_area ON flightbridge.organisation (area_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_fb_org_eligibility ON flightbridge.organisation (country, eligibility) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------- new official registers / credentials
ALTER TABLE flightbridge.aviation_authority DROP CONSTRAINT IF EXISTS aviation_authority_retrieval_check;
ALTER TABLE flightbridge.aviation_authority ADD CONSTRAINT aviation_authority_retrieval_check
    CHECK (retrieval IN ('pdf_parse','human_lookup','per_state_register','data_download'));
INSERT INTO flightbridge.aviation_authority (code, name, country, register_url, retrieval, notes) VALUES
 ('CRICOS', 'CRICOS (Commonwealth Register of Institutions and Courses for Overseas Students)', 'AU',
  'https://data.gov.au/data/dataset/cricos', 'data_download', 'Monthly XLSX; providers allowed to enrol student-visa holders, with approved courses'),
 ('SEVP',   'Student and Exchange Visitor Program (M-1 vocational schools)', 'US',
  'https://studyinthestates.dhs.gov/school-search', 'human_lookup', 'Site blocks automated access; confirm by hand'),
 ('IRCC_DLI', 'IRCC Designated Learning Institutions', 'CA',
  'https://www.canada.ca/en/immigration-refugees-citizenship/services/study-canada/study-permit/prepare/designated-learning-institutions-list.html', 'human_lookup', 'Needed for study permits'),
 ('CAA_NZ', 'Civil Aviation Authority of New Zealand (Part 141)', 'NZ', 'https://www.aviation.govt.nz/', 'human_lookup', 'Part 141 aviation training organisation certificate'),
 ('NZQA',   'New Zealand Qualifications Authority (international student providers)', 'NZ', 'https://www.nzqa.govt.nz/', 'human_lookup', 'Code of Practice signatory for international students')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE flightbridge.regulatory_approval DROP CONSTRAINT IF EXISTS regulatory_approval_classification_check;
ALTER TABLE flightbridge.regulatory_approval ADD CONSTRAINT regulatory_approval_classification_check CHECK (classification IN (
    'FTO_DGCA','ATO_UK','DTO_UK','ATO_EU_NCA','DTO_EU_NCA','PART141_FAA','PART61_OPERATOR_UNVERIFIED','FTU_TC',
    'PART141_CASA','PART142_CASA','UNCLASSIFIED','CRICOS_PROVIDER','SEVP_M1','DLI_CA','PART141_NZ','NZQA_PROVIDER'));

ALTER TABLE flightbridge.organisation_identifier DROP CONSTRAINT IF EXISTS organisation_identifier_scheme_check;
ALTER TABLE flightbridge.organisation_identifier ADD CONSTRAINT organisation_identifier_scheme_check CHECK (scheme IN (
    'dgca_fto','uk_caa_ref','faa_cert','tc_ftu','casa_arn','eu_nca_ref','google_place_id','domain',
    'cricos_code','sevp_id','dli_number','caa_nz_ref','nzqa_id'));

-- ---------------------------------------------------------------- phone numbers (website, regulator, Google, person)
CREATE TABLE IF NOT EXISTS flightbridge.contact_phone (
    id          BIGSERIAL PRIMARY KEY,
    org_id      UUID NOT NULL REFERENCES flightbridge.organisation(id),
    phone       TEXT NOT NULL CHECK (phone ~ '^\+?[0-9]{6,16}$'),   -- digits only (+ optional), for de-duplication
    display     TEXT NOT NULL,
    source      TEXT NOT NULL CHECK (source IN ('website','regulator','google_places','human')),
    source_url  TEXT,
    found_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (org_id, phone)
);

-- ---------------------------------------------------------------- Run-now: search one area
ALTER TABLE flightbridge.job_request ADD COLUMN IF NOT EXISTS area_id BIGINT REFERENCES flightbridge.area(id);
ALTER TABLE flightbridge.job_request DROP CONSTRAINT IF EXISTS job_request_kind_check;
ALTER TABLE flightbridge.job_request ADD CONSTRAINT job_request_kind_check
    CHECK (kind IN ('cycle','research_school','find_websites','research_batch','search_area'));
ALTER TABLE flightbridge.job_request DROP CONSTRAINT IF EXISTS search_area_needs_area;
ALTER TABLE flightbridge.job_request ADD CONSTRAINT search_area_needs_area CHECK (kind <> 'search_area' OR area_id IS NOT NULL);
DROP INDEX IF EXISTS flightbridge.uq_fb_job_queued;
CREATE UNIQUE INDEX IF NOT EXISTS uq_fb_job_queued2 ON flightbridge.job_request
    (kind, coalesce(org_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(area_id, 0)) WHERE status = 'queued';

-- ---------------------------------------------------------------- automation switches + Google storage choice
UPDATE flightbridge.system_setting SET value = value || '{"discover_areas": true, "eligibility": true}'::jsonb
 WHERE key = 'autopilot' AND NOT (value ? 'discover_areas');
UPDATE flightbridge.system_setting SET value = value || '{"store_google_contacts": true}'::jsonb
 WHERE key = 'integrations' AND NOT (value ? 'store_google_contacts');

-- ---------------------------------------------------------------- starter areas (airport-centred; edit or add freely)
-- Coordinates are the airfield at the centre of each hub; radius covers the schools around it.
INSERT INTO flightbridge.area (country, region, name, kind, lat, lng, radius_km, notes) VALUES
 ('US','Florida','Sanford (Orlando)','training_hub',28.7776,-81.2375,40,'seed'),
 ('US','Florida','Daytona Beach','training_hub',29.1799,-81.0581,35,'seed'),
 ('US','Florida','Vero Beach','training_hub',27.6556,-80.4179,30,'seed'),
 ('US','Florida','Fort Pierce','training_hub',27.4951,-80.3683,25,'seed'),
 ('US','Florida','Miami (Opa-locka)','training_hub',25.9070,-80.2780,40,'seed'),
 ('US','Arizona','Phoenix (Mesa)','training_hub',33.4608,-111.7283,40,'seed'),
 ('US','Arizona','Goodyear','training_hub',33.4225,-112.3760,30,'seed'),
 ('US','Arizona','Prescott','training_hub',34.6545,-112.4196,30,'seed'),
 ('US','Texas','Dallas (Addison)','training_hub',32.9686,-96.8364,45,'seed'),
 ('US','Texas','Houston','training_hub',30.0618,-95.5528,50,'seed'),
 ('US','California','San Diego','training_hub',32.8157,-117.1396,40,'seed'),
 ('US','California','Bay Area (Hayward)','training_hub',37.6589,-122.1217,45,'seed'),
 ('US','California','Long Beach','training_hub',33.8177,-118.1516,40,'seed'),
 ('US','Colorado','Denver (Centennial)','training_hub',39.5701,-104.8493,40,'seed'),
 ('CA','British Columbia','Langley / Abbotsford','training_hub',49.1008,-122.6308,35,'seed'),
 ('CA','British Columbia','Vancouver (Boundary Bay)','training_hub',49.0742,-123.0075,25,'seed'),
 ('CA','British Columbia','Kelowna','training_hub',49.9561,-119.3778,30,'seed'),
 ('CA','Ontario','Toronto East (Oshawa)','training_hub',43.9228,-78.8950,40,'seed'),
 ('CA','Ontario','Waterloo','training_hub',43.4608,-80.3786,30,'seed'),
 ('CA','Ontario','Brantford','training_hub',43.1314,-80.3425,25,'seed'),
 ('CA','Ontario','Ottawa','training_hub',45.3225,-75.6692,35,'seed'),
 ('CA','Alberta','Calgary (Springbank)','training_hub',51.1031,-114.3739,40,'seed'),
 ('CA','Alberta','Edmonton (Villeneuve)','training_hub',53.6675,-113.8533,40,'seed'),
 ('CA','Manitoba','Winnipeg (St. Andrews)','training_hub',50.0564,-97.0325,35,'seed'),
 ('CA','Quebec','Montreal (Saint-Hubert)','training_hub',45.5175,-73.4169,40,'seed'),
 ('AU','Queensland','Brisbane (Archerfield)','training_hub',-27.5703,153.0081,40,'seed'),
 ('AU','Queensland','Gold Coast','training_hub',-28.1644,153.5047,30,'seed'),
 ('AU','Queensland','Cairns','training_hub',-16.8858,145.7553,30,'seed'),
 ('AU','New South Wales','Sydney (Bankstown)','training_hub',-33.9244,150.9883,35,'seed'),
 ('AU','New South Wales','Camden','training_hub',-34.0403,150.6872,25,'seed'),
 ('AU','Victoria','Melbourne (Moorabbin)','training_hub',-37.9758,145.1022,40,'seed'),
 ('AU','Western Australia','Perth (Jandakot)','training_hub',-32.0975,115.8811,40,'seed'),
 ('AU','South Australia','Adelaide (Parafield)','training_hub',-34.7933,138.6331,35,'seed'),
 ('NZ','Auckland','Ardmore','training_hub',-37.0297,174.9733,40,'seed'),
 ('NZ','Waikato','Hamilton','training_hub',-37.8667,175.3322,35,'seed'),
 ('NZ','Canterbury','Christchurch','training_hub',-43.4894,172.5322,40,'seed'),
 ('NZ','Hawke''s Bay','Napier','training_hub',-39.4658,176.8700,30,'seed'),
 ('NZ','Bay of Plenty','Tauranga','training_hub',-37.6719,176.1961,30,'seed'),
 ('NZ','Manawatu-Whanganui','Palmerston North','training_hub',-40.3206,175.6169,30,'seed'),
 ('IN','Delhi','Ramphal Chowk (Dwarka)','demand_hub',28.5921,77.0460,5,'seed: ground schools, pilot training and cabin-crew institutes')
ON CONFLICT (country, region, name) DO NOTHING;

RESET client_min_messages;
