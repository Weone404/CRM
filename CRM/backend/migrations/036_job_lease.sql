-- Single-runner leases for scheduled jobs (SLA check, Mongo import, attendance
-- retention) when the backend runs on several hosts at once (Render + Koyeb +
-- Railway behind the failover Worker). See backend/job_lease.py.
--
-- Additive and backward compatible. The backend also creates this table on
-- first use if this migration has not been applied.
--
-- Reversible:
--   DROP TABLE job_lease;

CREATE TABLE IF NOT EXISTS job_lease (
    name        TEXT PRIMARY KEY,
    holder      TEXT,
    lease_until TIMESTAMPTZ
);
