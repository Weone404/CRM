"""Runs the FlightBridge engine inside the CRM backend's existing APScheduler (no extra service, no GitHub secrets).

  * full cycle every 15 minutes (first one ~2 minutes after start-up)
  * "Run now" requests from the app are picked up within ~30 seconds
  * one cycle at a time across every backend instance (the engine's own lock in flightbridge.engine_lease)
  * Verify worker step every minute (engine 1.5.0+, flightbridge/verify.py): takes undecided schools to Eligible or
    Not Qualified; shares its queue with the Mac Mini (each school claimed by one runner at a time)
  * switched off from FlightBridge Settings ("Run automation on the CRM server"), or with FLIGHTBRIDGE_ENGINE=off
  * never raises into the scheduler: if the package, the schema or the database is missing it logs and waits

Sending stays governed by DRY_RUN / OUTBOUND_ENABLED (unset => safe defaults: nothing is sent) and the kill switch.
"""
import logging
import os
import threading
from datetime import datetime, timedelta

log = logging.getLogger("flightbridge.engine")
CYCLE_MINUTES = 15
QUEUE_POLL_SECONDS = 30
_running = threading.Lock()   # the DB lock is per process; this stops two threads of one process overlapping
_verifying = threading.Lock()
VERIFY_SECONDS = 60


def _settings():
    from flightbridge.settings import Settings
    return Settings.from_env()


def _enabled(database_url: str) -> bool:
    if os.environ.get("FLIGHTBRIDGE_ENGINE", "").lower() == "off":
        return False
    from flightbridge import secrets
    return bool(secrets.settings(database_url).get("engine_in_crm", True))


def run_cycle(trigger: str = "schedule"):
    if not _running.acquire(blocking=False):
        return None
    try:
        os.environ.setdefault("FB_RUNNER", "crm-server")
        s = _settings()
        if not s.database_url or not _enabled(s.database_url):
            return None
        from flightbridge.worker import run_once
        out = run_once(s, trigger=trigger)
        log.info("FlightBridge cycle (%s): %s", trigger, {k: out.get(k) for k in ("run_id", "skipped") if k in out})
        return out
    except ImportError:
        log.warning("FlightBridge engine not installed (requirements.txt: flightbridge)")
    except Exception:
        log.exception("FlightBridge cycle failed; the next one retries")
    finally:
        _running.release()
    return None


def poll_queue():
    try:
        s = _settings()
        if not s.database_url or not _enabled(s.database_url):
            return
        from flightbridge import automation
        if automation.queued_jobs(s.database_url):
            run_cycle("queue")
    except ImportError:
        pass
    except Exception as exc:          # schema not installed yet, DB blip: stay quiet, try again next poll
        log.debug("FlightBridge queue poll skipped: %s", exc)


def ensure_schema():
    """Install FlightBridge's own database updates (idempotent, flightbridge schema only). Never raises."""
    try:
        s = _settings()
        if s.database_url:
            from flightbridge.db import ensure_schema as _ensure
            log.info("FlightBridge schema: %s", _ensure(s.database_url))
    except ImportError:
        log.warning("FlightBridge engine not installed (requirements.txt: flightbridge)")
    except Exception:
        log.exception("FlightBridge schema update failed; the app keeps running and retries on the next cycle")


def verify_step():
    """One Verify step (about a minute); repeats straight away while schools are waiting, up to ~4 minutes."""
    if not _verifying.acquire(blocking=False):
        return
    try:
        import time
        os.environ.setdefault("FB_RUNNER", "crm-server")
        s = _settings()
        if not s.database_url or not _enabled(s.database_url):
            return
        from flightbridge import worker
        if not hasattr(worker, "verify_step"):
            return                    # engine older than 1.5.0
        end = time.time() + 240
        while time.time() < end and not worker.verify_step(s).get("idle"):
            pass
    except ImportError:
        pass
    except Exception:
        log.exception("FlightBridge verify step failed; the next one retries")
    finally:
        _verifying.release()


def register(scheduler) -> None:
    """Add the FlightBridge jobs to the CRM's existing scheduler. Safe to call once at start-up."""
    if scheduler is None or os.environ.get("FLIGHTBRIDGE_ENGINE", "").lower() == "off":
        return
    threading.Thread(target=ensure_schema, name="flightbridge-schema", daemon=True).start()
    scheduler.add_job(run_cycle, "interval", minutes=CYCLE_MINUTES, id="flightbridge_cycle", replace_existing=True,
                      max_instances=1, coalesce=True, next_run_time=datetime.now() + timedelta(minutes=2))
    scheduler.add_job(poll_queue, "interval", seconds=QUEUE_POLL_SECONDS, id="flightbridge_queue", replace_existing=True,
                      max_instances=1, coalesce=True)
    scheduler.add_job(verify_step, "interval", seconds=VERIFY_SECONDS, id="flightbridge_verify", replace_existing=True,
                      max_instances=1, coalesce=True, next_run_time=datetime.now() + timedelta(minutes=3))
    log.info("FlightBridge engine registered (cycle every %s min, Run-now poll every %ss, Verify every %ss)",
             CYCLE_MINUTES, QUEUE_POLL_SECONDS, VERIFY_SECONDS)
