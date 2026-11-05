"""FlightBridge engine on the Mac Mini (takes over from the Render server's scheduler).

  * full cycle every 15 minutes: finds websites, reads them, checks eligibility, scores, drafts emails for approval
  * "Run now" / "Research this school" / "Search this area" from the CRM are picked up within ~30 seconds
  * in between, the 24x7 Verify worker (engine 1.5.0+): takes every undecided school to Eligible or Not Qualified,
    sharing its queue with the CRM server
  * one cycle at a time across every runner (the engine's own lock, flightbridge.engine_lease), so it is safe
    while Render is still on; whichever runner holds the lock does the cycle
  * paused from FlightBridge AI > Settings ("Run automation"), or with FLIGHTBRIDGE_ENGINE=off in the .env file
  * reports its state to the CRM (system_setting 'engine_status'): dry run on/off, which keys come from this Mac

Sending stays governed by DRY_RUN / OUTBOUND_ENABLED (missing or anything else => nothing is sent) and the CRM
kill switch. Settings come from ~/FlightBridgeEngine/.env (private to this Mac; never commit or paste it).
"""
import json
import logging
import logging.handlers
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.environ.get("FLIGHTBRIDGE_HOME", Path.home() / "FlightBridgeEngine"))
CYCLE_SECONDS = 15 * 60
POLL_SECONDS = 30
ENV_KEYS = ("GOOGLE_PLACES_API_KEY", "GROQ_API_KEY", "GEMINI_API_KEY", "HOSTINGER_MAIL_API_TOKEN", "HOSTINGER_MAILBOX_RESOURCE_ID")
log = logging.getLogger("flightbridge.mac")


def load_env(path: Path) -> None:
    """KEY=VALUE lines; optional quotes; '#' comments. Values already in the environment win."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip().removeprefix("export ").strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        os.environ.setdefault(key, value)


def setup_logging() -> None:
    (HOME / "logs").mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(HOME / "logs" / "engine.log", maxBytes=5_000_000, backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler, logging.StreamHandler(sys.stdout)])


def heartbeat(s, engine_off: bool) -> None:
    from flightbridge import db
    status = {"runner": os.environ.get("FB_RUNNER"), "host": socket.gethostname(),
              "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
              "dry_run": s.dry_run, "outbound_enabled": s.outbound_enabled, "engine_off": engine_off,
              "env_keys": [k for k in ENV_KEYS if os.environ.get(k)]}
    with db.tx(s.database_url) as conn:
        conn.execute("""INSERT INTO flightbridge.system_setting (key, value, updated_at) VALUES ('engine_status', %s::jsonb, now())
                        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()""", (json.dumps(status),))


def main() -> None:
    load_env(HOME / ".env")
    os.environ.setdefault("FB_RUNNER", "mac-mini")
    setup_logging()
    from flightbridge import automation, secrets
    from flightbridge.settings import Settings
    from flightbridge.worker import run_once
    try:
        from flightbridge.worker import verify_step
    except ImportError:               # engine older than 1.5.0
        verify_step = None

    s = Settings.from_env()
    if not s.database_url or "PASTE_" in s.database_url:
        log.error("DATABASE_URL is not set in %s - fill it in, then run install.sh again", HOME / ".env")
        time.sleep(300)                 # launchd restarts the job; don't spin
        sys.exit(2)
    log.info("FlightBridge engine started on %s (dry_run=%s, outbound_enabled=%s)", socket.gethostname(), s.dry_run, s.outbound_enabled)
    last_cycle = 0.0
    while True:
        try:
            engine_off = os.environ.get("FLIGHTBRIDGE_ENGINE", "").strip().lower() == "off"
            heartbeat(s, engine_off)
            enabled = not engine_off and bool(secrets.settings(s.database_url).get("engine_in_crm", True))
            if enabled:
                if time.time() - last_cycle >= CYCLE_SECONDS:
                    out = run_once(s, trigger="schedule")
                    last_cycle = time.time()
                    log.info("cycle: %s", {k: out.get(k) for k in ("run_id", "skipped") if k in out})
                elif automation.queued_jobs(s.database_url):
                    out = run_once(s, trigger="queue")
                    log.info("run-now: %s", {k: out.get(k) for k in ("run_id", "skipped") if k in out})
                elif verify_step is not None:
                    out = verify_step(s)
                    if not out.get("idle"):
                        log.info("verify: %s", {k: out.get(k) for k in ("schools", "eligible_verified", "unqualified",
                                                                       "eligible_claimed", "unknown", "errors")})
                        continue              # more schools waiting: next step straight away
        except Exception:
            log.exception("FlightBridge cycle failed; retrying shortly")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
