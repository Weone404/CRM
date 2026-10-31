"""Single-runner leases for scheduled jobs when several backends run at once.

When the CRM backend runs on more than one host (Render + Koyeb + Railway behind
the failover Worker), every instance starts its own APScheduler. A lease row in
Postgres makes sure each job runs on only one instance per cycle.

Why a lease table and not pg_advisory_lock: the backend talks to Supabase through
the transaction-mode pooler (pgbouncer, port 6543), where session-level advisory
locks can be held on a server connection that is handed to another client. The
lease is ONE atomic INSERT ... ON CONFLICT statement in a single transaction, so
it is safe through the pooler.

Leader affinity: the current holder may renew its own lease; any other instance
can take it over only after it has expired. Use a lease longer than the job
interval so the same instance keeps running the job while it is alive, and
another instance takes over only if the holder disappears.
"""
import logging
import os
import socket

from database import get_db

logger = logging.getLogger(__name__)

INSTANCE_ID = os.getenv("INSTANCE_ID") or f"{socket.gethostname()}:{os.getpid()}"

_CREATE_SQL = """
CREATE TABLE IF NOT EXISTS job_lease (
    name        TEXT PRIMARY KEY,
    holder      TEXT,
    lease_until TIMESTAMPTZ
)
"""

_ACQUIRE_SQL = """
INSERT INTO job_lease (name, holder, lease_until)
VALUES (%s, %s, NOW() + make_interval(secs => %s))
ON CONFLICT (name) DO UPDATE
    SET holder = EXCLUDED.holder, lease_until = EXCLUDED.lease_until
    WHERE job_lease.lease_until < NOW() OR job_lease.holder = EXCLUDED.holder
RETURNING name
"""

_table_ready = False


def _ensure_table():
    """Create the lease table if migration 036 has not been applied yet."""
    global _table_ready
    if _table_ready:
        return
    with get_db() as conn:
        conn.cursor().execute(_CREATE_SQL)
    _table_ready = True


def acquire_lease(name: str, seconds: int) -> bool:
    """Return True if this instance holds the lease for `name` for `seconds`.

    Returns False (skip this run) if another live instance holds it, or if the
    database cannot be reached. Skipping is the safe choice: every wrapped job is
    re-run on its next cycle, so a skipped run is never lost, only delayed.
    """
    try:
        _ensure_table()
        with get_db() as conn:
            cur = conn.cursor()
            cur.execute(_ACQUIRE_SQL, (name, INSTANCE_ID, seconds))
            got = cur.fetchone() is not None
        if not got:
            logger.info("Job '%s' skipped: lease held by another instance", name)
        return got
    except Exception as exc:
        logger.error("Job '%s' skipped: could not acquire lease: %s", name, exc)
        return False
