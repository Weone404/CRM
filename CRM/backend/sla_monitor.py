from apscheduler.schedulers.background import BackgroundScheduler
from database import get_db
from keepalive import self_ping
from job_lease import acquire_lease
import logging

logger = logging.getLogger(__name__)

def check_sla_breaches():
    # Runs every 5 min; 10-min lease keeps one instance as the runner while it lives.
    if not acquire_lease('sla_check', 600):
        return
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("SELECT value FROM config WHERE key = 'sla_first_response_minutes'")
            row = cur.fetchone()
            sla_minutes = int(row[0]) if row else 60
            
            cur.execute("""
                SELECT id, name, phone, course_interest, created_at,
                       EXTRACT(EPOCH FROM (NOW() - created_at))/60 as age_minutes
                FROM lead
                WHERE first_contacted_at IS NULL
                  AND status = 'new'
                  AND EXTRACT(EPOCH FROM (NOW() - created_at))/60 > %s
            """, (sla_minutes,))
            
            breaches = cur.fetchall()
            if breaches:
                logger.warning(f"Found {len(breaches)} SLA breaches")
                for breach in breaches:
                    logger.warning(f"Lead {breach[0]} ({breach[1]}) breached SLA by {breach[5] - sla_minutes:.1f} minutes")
    
    except Exception as e:
        logger.error(f"SLA check failed: {e}")

def start_sla_monitor():
    scheduler = BackgroundScheduler()
    scheduler.add_job(check_sla_breaches, 'interval', minutes=5)
    scheduler.add_job(self_ping, 'interval', minutes=10, id='self_ping')
    scheduler.start()
    logger.info("SLA monitor started")
    logger.info("Self-ping registered (10min interval)")
    return scheduler
