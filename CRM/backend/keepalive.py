import os
import logging
import requests

logger = logging.getLogger(__name__)

def self_ping():
    # Set ENABLE_SELF_PING=false to let a free Render instance sleep (saves the
    # 750 free instance hours/month); the failover Worker covers cold starts.
    if os.environ.get("ENABLE_SELF_PING", "true").strip().lower() != "true":
        return
    url = os.environ.get("RENDER_EXTERNAL_URL")
    if not url:
        return
    try:
        r = requests.get(f"{url}/health", timeout=10)
        logger.info("Self-ping OK -> %s", r.status_code)
    except Exception as exc:
        logger.warning("Self-ping failed (will retry): %s", exc)
