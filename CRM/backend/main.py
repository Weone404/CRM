from fastapi import FastAPI, Depends, HTTPException, UploadFile, File, Form, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles
from contextlib import asynccontextmanager
from dotenv import load_dotenv
import psycopg
from database import get_db
from auth import (
    authenticate_employee, create_access_token, get_current_employee,
    get_current_student, hash_password, verify_password, STUDENT_TOKEN_EXPIRE_HOURS,
)
from schemas import LoginRequest, TokenResponse, EmployeeCreate
from lead_ingestion import ingest_lead, normalize_phone
from charter_ingestion import (
    CharterValidationError, ingest_charter_lead, insert_charter_lead, validate_charter,
)
import r2_storage
import io
from sla_monitor import start_sla_monitor
from quote_generator import generate_quote_pdf
from encryption import encrypt_value, decrypt_value
from mongo_bridge import start_mongo_bridge
import calendar
import json
import re
import time
from collections import defaultdict
from datetime import datetime, date, timedelta
from zoneinfo import ZoneInfo
import logging
import os
import secrets
import uuid

load_dotenv()
logging.basicConfig(level=logging.INFO)

# Attendance retention window: raw cctv_attendance rows older than this many
# months are aggregated into attendance_monthly_summary and then purged.
ATTENDANCE_RETENTION_MONTHS = 3

# The Hikvision terminal re-pushes old stored records; reject events whose date
# is more than this many days in the past (or more than 1 day in the future).
HIKVISION_MAX_EVENT_AGE_DAYS = 2

# An accidental double-tap on the terminal (seconds apart) must NOT turn a fresh
# entry into an exit, nor keep overwriting the exit. Ignore any punch landing
# within this many minutes of an already-recorded entry or exit for the day.
ATTENDANCE_MIN_PUNCH_GAP_MINUTES = 5

# Day-status thresholds. A full shift is SHIFT_HOURS; anything at/above
# FULL_DAY_MIN_HOURS counts as a full day, at/above HALF_DAY_MIN_HOURS as a half
# day. These only classify a day for reporting — they do NOT affect pay here.
SHIFT_HOURS = 8
FULL_DAY_MIN_HOURS = 7      # >= this counts as a full day
HALF_DAY_MIN_HOURS = 4      # >= this but < full = half day


def blank_to_none(data: dict, *fields: str) -> None:
    """HTML forms POST "" for optional inputs the user never touched, and Postgres
    rejects "" for DATE/NUMERIC columns ("invalid input syntax for type date").
    Rewrite blanks to None in place so they land as NULL."""
    for f in fields:
        v = data.get(f)
        if isinstance(v, str) and not v.strip():
            data[f] = None


def require_fields(data: dict, *fields: str) -> None:
    """400 naming the offending field, instead of letting psycopg raise a 500."""
    for f in fields:
        v = data.get(f)
        if v is None or (isinstance(v, str) and not v.strip()):
            raise HTTPException(status_code=400, detail=f"{f} is required")


# Nobody on the roster was born before this many years ago; anything older (or in
# the future) is a mistyped year, and a wrong DOB means a wrong birthday popup.
MAX_AGE_YEARS = 100


def validate_dob(data: dict, field: str = 'date_of_birth') -> None:
    """Range-check an optional date of birth. Call AFTER blank_to_none, so a blank
    input (already None by then) is simply skipped and stored as NULL.
    Uses _IST (defined in the attendance section below, resolved at call time) so
    "today" is the institute's day, not the server's UTC day."""
    raw = data.get(field)
    if raw is None:
        return
    try:
        dob = date.fromisoformat(str(raw)[:10])
    except ValueError:
        raise HTTPException(status_code=400, detail="Date of birth must be a valid date (YYYY-MM-DD)")
    today = datetime.now(_IST).date()
    if dob > today:
        raise HTTPException(status_code=400, detail="Date of birth cannot be in the future")
    try:
        earliest = today.replace(year=today.year - MAX_AGE_YEARS)
    except ValueError:
        # 29 Feb today, and the year MAX_AGE_YEARS back is not a leap year.
        earliest = today.replace(year=today.year - MAX_AGE_YEARS, month=2, day=28)
    if dob < earliest:
        raise HTTPException(
            status_code=400,
            detail=f"Date of birth cannot be more than {MAX_AGE_YEARS} years ago",
        )
    data[field] = dob.isoformat()


scheduler = None
mongo_scheduler = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global scheduler, mongo_scheduler
    scheduler = start_sla_monitor()
    mongo_scheduler = start_mongo_bridge()
    # Reuse the SLA scheduler (do NOT start a second one): run the attendance
    # retention purge on the 1st of every month at 02:00 Asia/Kolkata.
    scheduler.add_job(
        run_attendance_retention, 'cron',
        day=1, hour=2, minute=0, timezone='Asia/Kolkata',
        id='attendance_retention', replace_existing=True,
    )
    logging.info("Attendance retention job registered (1st of month, 02:00 IST)")
    yield
    if scheduler:
        scheduler.shutdown()
    if mongo_scheduler:
        mongo_scheduler.shutdown()
    # Cleanly drain the DB connection pool on shutdown.
    try:
        from database import pool
        pool.close()
    except Exception:
        pass

app = FastAPI(lifespan=lifespan)

# Compress responses (esp. the large /api/sync snapshot) to cut transfer time.
app.add_middleware(GZipMiddleware, minimum_size=500)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://crm-three-smoky-26.vercel.app",
        "https://crm-pi-self.vercel.app",   # weone404 Vercel project (crm)
        "http://localhost:3000",
        # Lead-capture websites that POST to /api/leads/ingest from the browser
        "https://www.weoneaviation.com",
        "https://weoneaviation.com",
        "https://www.weoneaviation.in",
        "https://weoneaviation.in",
        "https://www.pilotschool.in",
        "https://pilotschool.in",
        "https://www.bookmycharter.in",
        "https://bookmycharter.in",
    ],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["*"]
)

@app.get("/health")
async def health_check():
    """Health endpoint for uptime monitoring - no auth, no DB query"""
    return {"status": "ok"}

@app.post("/api/seed-admin")
async def seed_admin():
    """One-off endpoint to create initial admin user in empty DB"""
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM employee WHERE department = 'Admin'")
        if cur.fetchone()[0] > 0:
            raise HTTPException(status_code=400, detail="Admin already exists")
        
        hashed = hash_password("admin")
        cur.execute("""
            INSERT INTO employee (
                id, name, phone, email, department,
                password_hash, date_of_joining, is_active, login_id
            ) VALUES (
                'EMP001', 'Admin', '+919999999999', 'admin@weoneaviation.in',
                'Admin', %s, CURRENT_DATE, true, 'admin'
            )
        """, (hashed,))
        conn.commit()
        return {"status": "admin created", "login_id": "admin", "password": "admin"}

@app.post("/api/auth/login", response_model=TokenResponse)
async def login(req: LoginRequest):
    emp = authenticate_employee(req.login_id, req.password)
    if not emp:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token({"sub": emp["id"]})
    return TokenResponse(access_token=token, employee=emp)

@app.post("/api/auth/employee-login")
async def employee_login(data: dict):
    """Employee login using login_id and optional PIN."""
    login_id = data.get('login_id', '').strip()
    pin = data.get('pin', '').strip()
    
    if not login_id:
        raise HTTPException(status_code=400, detail="Login ID required")
    
    with get_db() as conn:
        cur = conn.cursor()
        
        cur.execute("""
            SELECT id, employee_id, name, phone, email, 
                   login_pin, job_role, active, department
            FROM employee
            WHERE active = true AND LOWER(login_id) = LOWER(%s)
            LIMIT 1
        """, (login_id,))
        
        row = cur.fetchone()
        
        if not row:
            raise HTTPException(status_code=401, detail="Employee not found")
        
        emp_id, emp_employee_id, name, phone, email, login_pin, job_role, active, department = row
        
        if login_pin and login_pin != pin:
            raise HTTPException(status_code=401, detail="Invalid PIN")
        
        emp_data = {
            "id": str(emp_id),
            "employee_id": emp_employee_id,
            "name": name,
            "phone": phone,
            "email": email,
            "department": department,
            "job_role": job_role,
            "is_employee_session": True
        }
        
        token = create_access_token({"sub": str(emp_id), "is_employee": True})

        return {"access_token": token, "employee": emp_data}


# --- Student login: mobile + bcrypt PIN, with per-mobile rate limiting -------
# In-memory failed-attempt tracker: mobile_normalized -> [failure timestamps].
# Single-process deployment (Render), so an in-process window is sufficient.
_student_login_fails = defaultdict(list)
_STUDENT_LOGIN_MAX_FAILS = 5
_STUDENT_LOGIN_WINDOW_SEC = 15 * 60


def _student_login_is_rate_limited(mobile_norm: str) -> bool:
    now = time.time()
    recent = [t for t in _student_login_fails.get(mobile_norm, []) if now - t < _STUDENT_LOGIN_WINDOW_SEC]
    _student_login_fails[mobile_norm] = recent
    return len(recent) >= _STUDENT_LOGIN_MAX_FAILS


def _student_login_record_failure(mobile_norm: str):
    _student_login_fails[mobile_norm].append(time.time())


@app.post("/api/auth/student-login")
async def student_login(data: dict):
    """Students authenticate with a 10-digit mobile + PIN. Mobile alone is never enough."""
    raw = (data.get('mobile') or '').strip()
    pin = (data.get('pin') or '').strip()

    # Accept a bare 10-digit number; reject anything else after stripping spaces/dashes.
    digits = re.sub(r'\D', '', raw)
    if len(digits) != 10:
        raise HTTPException(status_code=400, detail="Enter a valid 10-digit mobile number")
    mobile_norm = normalize_phone(digits)  # -> +91XXXXXXXXXX

    # Rate limit BEFORE touching the DB so the endpoint can't be hammered for enumeration.
    if _student_login_is_rate_limited(mobile_norm):
        raise HTTPException(status_code=429, detail="Too many failed attempts. Try again in 15 minutes.")

    # Identical response for "unknown number" and "wrong PIN" — no student enumeration.
    generic = HTTPException(status_code=401, detail="Invalid mobile number or PIN")

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, first_name, last_name, login_pin_hash, login_enabled FROM student WHERE mobile_normalized = %s",
            (mobile_norm,)
        )
        row = cur.fetchone()

        if not row:
            _student_login_record_failure(mobile_norm)
            raise generic

        student_id, first_name, last_name, pin_hash, login_enabled = row

        # No PIN configured -> login is impossible. NEVER treat a missing PIN as "no check".
        if not pin_hash:
            raise HTTPException(status_code=403, detail="PIN not set — contact the institute.")

        if not pin or not verify_password(pin, pin_hash):
            _student_login_record_failure(mobile_norm)
            raise generic

        # Correct PIN but access revoked. Only revealed to someone who knows the PIN.
        if not login_enabled:
            raise HTTPException(status_code=403, detail="Login is disabled for this account. Contact the institute.")

        cur.execute("UPDATE student SET last_login_at = NOW() WHERE id = %s", (student_id,))

    # Successful login clears the failure counter for this mobile.
    _student_login_fails.pop(mobile_norm, None)

    token = create_access_token(
        {"sub": str(student_id), "type": "student"},
        expires_delta=timedelta(hours=STUDENT_TOKEN_EXPIRE_HOURS),
    )
    return {
        "access_token": token,
        "student": {
            "id": str(student_id),
            "first_name": first_name,
            "last_name": last_name,
            "name": " ".join(x for x in [first_name, last_name] if x),
        },
    }


@app.post("/api/auth/change-password")
async def change_password(data: dict, current_emp = Depends(get_current_employee)):
    """Allow any logged-in user to change their own password"""
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if not old_password or not new_password:
        raise HTTPException(status_code=400, detail="Old and new passwords required")
    
    if len(new_password) < 6:
        raise HTTPException(status_code=400, detail="New password must be at least 6 characters")
    
    with get_db() as conn:
        cur = conn.cursor()
        
        # Verify old password
        cur.execute("SELECT password_hash FROM employee WHERE id = %s", (current_emp['id'],))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        
        from auth import verify_password, hash_password
        if not verify_password(old_password, row[0]):
            raise HTTPException(status_code=401, detail="Current password is incorrect")
        
        # Update password
        new_hash = hash_password(new_password)
        cur.execute("UPDATE employee SET password_hash = %s WHERE id = %s", (new_hash, current_emp['id']))
        
        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp['id'], 'change_password', 'employee', json.dumps({"employee_id": current_emp['id']}))
        )
    
    return {"status": "success", "message": "Password changed successfully"}

@app.post("/api/auth/register")
async def register(req: EmployeeCreate, current_emp = Depends(get_current_employee)):
    # department is NOT NULL (migration 020) and enum-constrained; reject unknown values before insert
    if req.department not in ('Admin', 'IT', 'Sales', 'Instructors'):
        raise HTTPException(status_code=400, detail="department must be one of: Admin, IT, Sales, Instructors")
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO employee (name, phone, email, department, permissions, password_hash)
               VALUES (%s, %s, %s, %s, %s, %s) RETURNING id""",
            (req.name, req.phone, req.email, req.department, json.dumps(req.permissions), hash_password(req.password))
        )
        emp_id = cur.fetchone()[0]
        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "create", "employee", json.dumps({"employee_id": str(emp_id)}))
        )
    return {"id": str(emp_id)}

@app.get("/api/me")
async def me(current_emp = Depends(get_current_employee)):
    return current_emp

@app.get("/api/config")
def get_config(current_emp = Depends(get_current_employee)):  # sync → threadpool
    """Slim endpoint: just the config key/value map. The frontend used to pull
    this out of the heavy /api/sync snapshot (employees + 500 leads + 1000
    contact attempts) on every 60s poll and discard everything else. Config
    rarely changes, so the app now loads it once from here instead."""
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT key, value FROM config")
        return {r[0]: r[1] for r in cur.fetchall()}

@app.post("/api/leads/ingest")
async def ingest_lead_endpoint(data: dict):
    result = ingest_lead(data)
    return result

@app.post("/api/leads/charter")
def charter_lead_ingest(data: dict, authorization: str = Header(default="")):  # sync → threadpool
    """Charter enquiries from bookmycharter.in (server-to-server).

    Secured by its own shared secret: 'Authorization: Bearer <CHARTER_INGEST_TOKEN>'.
    Creates a lead in the 'charter' segment; a repeat of the same trip returns
    the existing lead with status 'duplicate' (HTTP 200, so the website does not
    tell the customer their enquiry failed).
    """
    token = os.getenv("CHARTER_INGEST_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503,
                            detail="CHARTER_INGEST_TOKEN not configured on the CRM server")
    if not secrets.compare_digest(authorization.encode(), f"Bearer {token}".encode()):
        raise HTTPException(status_code=401, detail="Invalid charter token")
    try:
        return ingest_charter_lead(data)
    except CharterValidationError as exc:
        raise HTTPException(status_code=422, detail={"errors": exc.errors})

@app.get("/api/leads")
def get_leads(current_emp = Depends(get_current_employee)):  # sync → runs in threadpool (blocking DB)
    # Access: Admin or Sales only
    if current_emp['department'] not in ['Admin', 'Sales']:
        raise HTTPException(status_code=403, detail="Lead access requires Admin or Sales department")
    
    with get_db() as conn:
        cur = conn.cursor()
        # not_reachable_count via a single grouped LEFT JOIN instead of a
        # correlated per-row subquery (one index scan for the whole result set
        # rather than one lookup per lead).
        cur.execute("""
            SELECT l.id, l.name, l.phone, l.email, l.address, l.course_interest,
                   l.utm_source, l.utm_medium, l.utm_campaign, l.status, l.assigned_to,
                   l.created_at, l.first_contacted_at, l.dedup_key, l.last_note,
                   COALESCE(l.parked, FALSE) as parked, COALESCE(l.closed, FALSE) as closed,
                   COALESCE(nr.cnt, 0) as not_reachable_count,
                   EXTRACT(EPOCH FROM (NOW() - l.created_at))/60 as age_minutes,
                   l.closure_outcome, l.guardian_name, l.qualifications, l.is_eligible, l.nios_interested,
                   l.interest_track, COALESCE(l.segment, 'aviation'), l.charter_details
            FROM lead l
            LEFT JOIN (
                SELECT lead_id, COUNT(*) AS cnt
                FROM contact_attempt
                WHERE disposition = 'Not reachable'
                GROUP BY lead_id
            ) nr ON nr.lead_id = l.id
            ORDER BY l.created_at DESC
        """)
        leads = []
        for r in cur.fetchall():
            leads.append({
                "id": str(r[0]), "name": r[1], "phone": r[2], "email": r[3], "address": r[4],
                "course_interest": r[5], "utm_source": r[6], "utm_medium": r[7], "utm_campaign": r[8],
                "status": r[9] or "new", "assigned_to": str(r[10]) if r[10] else None,
                "created_at": r[11].isoformat(), "first_contacted_at": r[12].isoformat() if r[12] else None,
                "dedup_key": r[13], "last_note": r[14], "parked": r[15], "closed": r[16],
                "not_reachable_count": r[17], "age_minutes": float(r[18]),
                "closure_outcome": r[19], "guardian_name": r[20], "qualifications": r[21] or [],
                "is_eligible": r[22], "nios_interested": r[23],
                "interest_track": r[24],
                "segment": r[25], "charter_details": r[26]
            })
    return leads

@app.post("/api/leads/{lead_id}/contact")
async def log_contact(lead_id: str, data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        
        # Get lead details
        cur.execute("""
            SELECT name, phone, email, course_interest, address 
            FROM lead WHERE id = %s
        """, (lead_id,))
        lead_row = cur.fetchone()
        
        if not lead_row:
            raise HTTPException(status_code=404, detail="Lead not found")
        
        name, phone, email, course_interest, address = lead_row
        disposition = data.get('disposition')
        note = data.get('note')
        interest_track = data.get('interest_track')
        
        cur.execute(
            """INSERT INTO contact_attempt (lead_id, staff_id, channel, disposition, note, connected, attempted_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW()) RETURNING id""",
            (lead_id, current_emp["id"], data.get('channel', 'phone'), disposition, 
             note, disposition in ['Connected', 'Interested', 'Callback'])
        )
        attempt_id = cur.fetchone()[0]
        
        # Update status and note - status is single source of truth
        cur.execute("""
            UPDATE lead 
            SET first_contacted_at = COALESCE(first_contacted_at, NOW()), 
                status = %s, 
                last_note = %s 
            WHERE id = %s
        """, (disposition, note, lead_id))
        
        # Persist course track only for Interested leads (keeps course_interest untouched)
        if disposition == 'Interested' and interest_track:
            cur.execute("UPDATE lead SET interest_track = %s WHERE id = %s", (interest_track, lead_id))

        # Set flags based on disposition (don't overwrite status)
        if disposition == 'Not interested':
            cur.execute("UPDATE lead SET closed = TRUE WHERE id = %s", (lead_id,))
        
        if disposition == 'Not reachable':
            cur.execute(
                "SELECT COUNT(*) FROM contact_attempt WHERE lead_id = %s AND disposition = 'Not reachable'",
                (lead_id,)
            )
            not_reachable_count = cur.fetchone()[0]
            if not_reachable_count >= 3:
                cur.execute("UPDATE lead SET parked = TRUE WHERE id = %s", (lead_id,))
        
        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "contact", "lead", json.dumps({"lead_id": lead_id, "disposition": disposition}))
        )
        
    return {"id": str(attempt_id)}

@app.post("/api/leads/{lead_id}/close")
async def close_lead(lead_id: str, data: dict, current_emp = Depends(get_current_employee)):
    if current_emp['department'] not in ['Admin', 'Sales']:
        raise HTTPException(status_code=403, detail="Lead access requires Admin or Sales department")

    outcome = data.get('closure_outcome')
    allowed = {
        'aviation': ('admission_completed', 'admission_aborted'),
        'charter': ('booking_confirmed', 'booking_lost'),
    }

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(segment, 'aviation') FROM lead WHERE id = %s", (lead_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Lead not found")
        if outcome not in allowed[row[0]]:
            raise HTTPException(status_code=400,
                                detail=f"closure_outcome must be one of {allowed[row[0]]}")

        note = data.get('note')
        # status is the top-level state; closure_outcome is the sub-state
        cur.execute("""
            UPDATE lead
            SET status = 'closed', closed = TRUE, closure_outcome = %s,
                first_contacted_at = COALESCE(first_contacted_at, NOW()),
                last_note = COALESCE(%s, last_note)
            WHERE id = %s
        """, (outcome, note, lead_id))

        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "close", "lead", json.dumps({"lead_id": lead_id, "closure_outcome": outcome}))
        )
    return {"status": "closed", "closure_outcome": outcome}

@app.post("/api/leads/query")
async def create_query(data: dict, current_emp = Depends(get_current_employee)):
    """Manual lead entry (Add Query). Reuses the normalized-phone dedup used by the Mongo bridge."""
    if current_emp['department'] not in ['Admin', 'Sales']:
        raise HTTPException(status_code=403, detail="Lead access requires Admin or Sales department")

    if data.get('segment') == 'charter':
        # Charter enquiry taken by phone / walk-in. Date and passengers may not
        # be known yet on a first call, so only name, phone and route are required.
        try:
            cleaned = validate_charter(data, require_date=False)
        except CharterValidationError as exc:
            first = next(iter(exc.errors.items()))
            raise HTTPException(status_code=400, detail=f"{first[0]}: {first[1]}")
        with get_db() as conn:
            cur = conn.cursor()
            return insert_charter_lead(
                cur, cleaned,
                source=(data.get('utm_source') or 'Direct Call')[:80],
                medium='manual', campaign='add_query', actor=current_emp["id"],
            )

    name = (data.get('name') or '').strip()
    raw_phone = (data.get('phone') or '').strip()
    course = data.get('course_interest')
    if not name or not raw_phone or not course:
        raise HTTPException(status_code=400, detail="Name, phone and course are required")

    phone_normalized = normalize_phone(raw_phone)
    qualifications = data.get('qualifications') or []

    with get_db() as conn:
        cur = conn.cursor()

        # Dedup on normalized phone (same key the Mongo bridge uses)
        cur.execute("SELECT id, name FROM lead WHERE dedup_key = %s", (phone_normalized,))
        existing = cur.fetchone()
        if existing:
            return {"status": "duplicate", "lead_id": str(existing[0]), "name": existing[1]}

        # Eligibility rule comes from config, not hardcoded
        cur.execute("SELECT value FROM config WHERE key = 'eligibility_required_qualification'")
        rule_row = cur.fetchone()
        required_qual = rule_row[0] if rule_row else "12th with Physics & Maths"
        is_eligible = required_qual in qualifications
        nios_interested = data.get('nios_interested') if not is_eligible else None

        cur.execute(
            """INSERT INTO lead (name, phone, email, address, course_interest,
                                 utm_source, utm_medium, utm_campaign, status, dedup_key,
                                 guardian_name, qualifications, is_eligible, nios_interested)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'new', %s, %s, %s, %s, %s) RETURNING id""",
            (name, phone_normalized, data.get('email'), data.get('address'), course,
             data.get('utm_source'), 'manual', 'add_query', phone_normalized,
             data.get('guardian_name'), json.dumps(qualifications), is_eligible, nios_interested)
        )
        lead_id = cur.fetchone()[0]

        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "create_query", "lead", json.dumps({
                "lead_id": str(lead_id), "source": data.get('utm_source'),
                "is_eligible": is_eligible, "nios_interested": nios_interested
            }))
        )
    return {"status": "created", "lead_id": str(lead_id), "is_eligible": is_eligible}

@app.post("/api/leads/{lead_id}/followup")
async def create_followup(lead_id: str, data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO followup (lead_id, due_date, reason, created_by)
               VALUES (%s, %s, %s, %s) RETURNING id""",
            (lead_id, data.get('due_date'), data.get('reason'), current_emp["id"])
        )
        followup_id = cur.fetchone()[0]
    return {"id": str(followup_id)}

@app.get("/api/followups/pending")
def get_pending_followups(current_emp = Depends(get_current_employee)):  # sync → threadpool
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT f.id, f.lead_id, f.due_date, f.reason, l.name, l.phone, l.course_interest
            FROM followup f
            JOIN lead l ON f.lead_id = l.id
            WHERE f.done = false AND f.due_date <= NOW() + INTERVAL '24 hours'
            ORDER BY f.due_date
        """)
        followups = []
        for r in cur.fetchall():
            followups.append({
                "id": str(r[0]), "lead_id": str(r[1]), "due_date": r[2].isoformat(),
                "reason": r[3], "lead_name": r[4], "lead_phone": r[5], "course_interest": r[6]
            })
    return followups

@app.get("/api/reports/funnel")
async def get_funnel_report(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT 
                utm_source, utm_medium, utm_campaign,
                COUNT(*) as total_leads,
                COUNT(CASE WHEN first_contacted_at IS NOT NULL THEN 1 END) as contacted,
                COUNT(CASE WHEN status = 'closed' AND id IN (
                    SELECT lead_id FROM contact_attempt WHERE disposition = 'Interested'
                ) THEN 1 END) as interested
            FROM lead
            GROUP BY utm_source, utm_medium, utm_campaign
            ORDER BY total_leads DESC
        """)
        funnel = []
        for r in cur.fetchall():
            funnel.append({
                "utm_source": r[0], "utm_medium": r[1], "utm_campaign": r[2],
                "total_leads": r[3], "contacted": r[4], "interested": r[5]
            })
    return funnel

@app.get("/api/courses")
async def get_courses(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT c.id, c.code, c.name, c.base_fee, c.installment_count,
                   COALESCE(SUM(cli.amount), 0) as line_items_total
            FROM course c
            LEFT JOIN course_line_item cli ON c.id = cli.course_id
            WHERE c.active = true
            GROUP BY c.id
            ORDER BY c.name
        """)
        courses = []
        for r in cur.fetchall():
            total_fee = r[3] + r[5]
            courses.append({
                "id": str(r[0]),
                "code": r[1],
                "name": r[2],
                "base_fee": r[3],
                "installment_count": r[4],
                "total_fee": total_fee
            })
    return courses

@app.patch("/api/courses/{course_id}/discount")
async def update_course_discount(course_id: str, data: dict, current_emp = Depends(get_current_employee)):
    discount_percent = data.get('discount_percent', 0)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE course SET discount_percent = %s WHERE id = %s",
            (discount_percent, course_id)
        )
    return {"status": "updated"}

@app.patch("/api/courses/{course_id}/installments")
async def update_course_installments(course_id: str, data: dict, current_emp = Depends(get_current_employee)):
    installment_count = data.get('installment_count', 1)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE course SET installment_count = %s WHERE id = %s",
            (installment_count, course_id)
        )
    return {"status": "updated"}

@app.post("/api/quotes/generate")
async def generate_quote(data: dict, current_emp = Depends(get_current_employee)):
    lead_id = data.get('lead_id')
    course_id = data.get('course_id')
    down_payment = data.get('down_payment', 0)
    
    with get_db() as conn:
        cur = conn.cursor()
        
        if down_payment > 0:
            cur.execute(
                "UPDATE course SET down_payment = %s WHERE id = %s",
                (down_payment, course_id)
            )
        
        cur.execute("SELECT name FROM lead WHERE id = %s", (lead_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Lead not found")
        lead_name = row[0]
        
        cur.execute("SELECT name FROM course WHERE id = %s", (course_id,))
        row = cur.fetchone()
        if not row:
            # Only courses with fees configured in the course table can be quoted (currently CPL).
            raise HTTPException(status_code=400, detail="No fee configured for this course. Add it in Course Config before generating a quote.")
        course_name = row[0]
        
        quote_id = str(uuid.uuid4())[:8].upper()
        
        # Generate PDF bytes (no file write)
        pdf_bytes = generate_quote_pdf(lead_name, course_id, quote_id)
        
        # Store PDF in database
        cur.execute(
            """INSERT INTO outbox_message (lead_id, type, body, pdf_bytes, status)
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (lead_id, 'quote', f'Quote for {course_name}', pdf_bytes, 'pending')
        )
        outbox_id = cur.fetchone()[0]
        
        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "generate_quote", "quote", json.dumps({
                "lead_id": lead_id, "course_id": course_id, "quote_id": quote_id, "outbox_id": str(outbox_id)
            }))
        )
        
    return {"id": str(outbox_id), "quote_id": quote_id}

@app.get("/api/quotes/{outbox_id}/pdf")
async def get_quote_pdf(outbox_id: str, current_emp = Depends(get_current_employee)):
    """Serve PDF from database"""
    from fastapi.responses import Response
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT pdf_bytes FROM outbox_message WHERE id = %s", (outbox_id,))
        row = cur.fetchone()
        
        if not row or not row[0]:
            raise HTTPException(status_code=404, detail="PDF not found")
        
        return Response(
            content=bytes(row[0]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"inline; filename=quote_{outbox_id}.pdf"}
        )

@app.get("/api/outbox")
async def get_outbox(current_emp = Depends(get_current_employee)):
    # Access: Admin or Sales only
    if current_emp['department'] not in ['Admin', 'Sales']:
        raise HTTPException(status_code=403, detail="Outbox access requires Admin or Sales department")
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT o.id, o.lead_id, o.type, o.body, o.status, o.created_at,
                   l.name, l.phone
            FROM outbox_message o
            JOIN lead l ON o.lead_id = l.id
            WHERE o.status IN ('draft', 'pending', 'approved')
            ORDER BY o.created_at DESC
        """)
        messages = []
        for r in cur.fetchall():
            messages.append({
                "id": str(r[0]), "lead_id": str(r[1]), "type": r[2], "body": r[3],
                "status": r[4], "created_at": r[5].isoformat(),
                "lead_name": r[6], "lead_phone": r[7],
                "pdf_url": f"/api/quotes/{r[0]}/pdf" if r[2] == 'quote' else None
            })
    return messages

@app.post("/api/outbox/{message_id}/approve")
async def approve_outbox_message(message_id: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE outbox_message SET status = 'approved', approved_by = %s, approved_at = NOW() WHERE id = %s",
            (current_emp["id"], message_id)
        )
    return {"status": "approved"}

@app.post("/api/outbox/{message_id}/sent")
async def mark_outbox_sent(message_id: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE outbox_message SET status = 'sent', approved_by = %s, approved_at = NOW() WHERE id = %s",
            (current_emp["id"], message_id)
        )
        cur.execute(
            """INSERT INTO audit_log (actor, action, entity, payload)
               VALUES (%s, %s, %s, %s)""",
            (current_emp["id"], "mark_sent", "outbox_message", json.dumps({"message_id": message_id}))
        )
    return {"status": "sent"}

@app.get("/api/sync")
def sync_snapshot(current_emp = Depends(get_current_employee)):  # sync → threadpool
    with get_db() as conn:
        cur = conn.cursor()
        
        cur.execute("SELECT id, name, phone, email, department, permissions, active, created_at FROM employee WHERE active = true")
        employees = [
            {
                "id": str(r[0]), "name": r[1], "phone": r[2], "email": r[3],
                "department": r[4], "permissions": r[5], "active": r[6], "created_at": r[7].isoformat()
            }
            for r in cur.fetchall()
        ]
        
        cur.execute("""
            SELECT id, name, phone, email, address, course_interest, utm_source, utm_medium, utm_campaign,
                   status, assigned_to, created_at, first_contacted_at, dedup_key, last_note
            FROM lead
            ORDER BY created_at DESC
            LIMIT 500
        """)
        leads = [
            {
                "id": str(r[0]), "name": r[1], "phone": r[2], "email": r[3], "address": r[4],
                "course_interest": r[5], "utm_source": r[6], "utm_medium": r[7], "utm_campaign": r[8],
                "status": r[9], "assigned_to": str(r[10]) if r[10] else None,
                "created_at": r[11].isoformat(), "first_contacted_at": r[12].isoformat() if r[12] else None,
                "dedup_key": r[13], "last_note": r[14]
            }
            for r in cur.fetchall()
        ]
        
        cur.execute("""
            SELECT id, lead_id, staff_id, channel, attempted_at, disposition, note, connected
            FROM contact_attempt
            ORDER BY attempted_at DESC
            LIMIT 1000
        """)
        contact_attempts = [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "staff_id": str(r[2]), "channel": r[3],
                "attempted_at": r[4].isoformat(), "disposition": r[5], "note": r[6], "connected": r[7]
            }
            for r in cur.fetchall()
        ]
        
        cur.execute("""
            SELECT id, lead_id, due_date, reason, done, created_by, created_at, completed_at
            FROM followup
            WHERE NOT done OR completed_at > NOW() - INTERVAL '30 days'
            ORDER BY due_date
        """)
        followups = [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "due_date": r[2].isoformat(), "reason": r[3],
                "done": r[4], "created_by": str(r[5]), "created_at": r[6].isoformat(),
                "completed_at": r[7].isoformat() if r[7] else None
            }
            for r in cur.fetchall()
        ]
        
        cur.execute("SELECT key, value FROM config")
        config = {r[0]: r[1] for r in cur.fetchall()}
        
    return {
        "employees": employees,
        "leads": leads,
        "contact_attempts": contact_attempts,
        "followups": followups,
        "config": config,
        "synced_at": datetime.utcnow().isoformat()
    }

@app.get("/api/tasks")
def get_tasks(current_emp = Depends(get_current_employee)):  # sync → threadpool
    with get_db() as conn:
        cur = conn.cursor()
        
        # Admin sees all tasks
        if current_emp['department'] == 'Admin':
            cur.execute("""
                SELECT t.id, t.title, t.description, t.assigned_to, t.created_by, t.status, 
                       t.due_date, t.created_at, t.finish_date, t.abort_reason,
                       e1.name as assignee_name, e2.name as creator_name
                FROM task t
                LEFT JOIN employee e1 ON t.assigned_to = e1.id
                JOIN employee e2 ON t.created_by = e2.id
                ORDER BY t.created_at DESC
            """)
        else:
            # Sales, IT, Instructor: only see own tasks
            cur.execute("""
                SELECT t.id, t.title, t.description, t.assigned_to, t.created_by, t.status, 
                       t.due_date, t.created_at, t.finish_date, t.abort_reason,
                       e1.name as assignee_name, e2.name as creator_name
                FROM task t
                LEFT JOIN employee e1 ON t.assigned_to = e1.id
                JOIN employee e2 ON t.created_by = e2.id
                WHERE t.assigned_to = %s
                ORDER BY t.created_at DESC
            """, (current_emp['id'],))
        
        tasks = []
        for r in cur.fetchall():
            tasks.append({
                "id": str(r[0]), "title": r[1], "description": r[2],
                "assigned_to": str(r[3]) if r[3] else None, "created_by": str(r[4]),
                "status": r[5], "due_date": r[6].isoformat() if r[6] else None,
                "created_at": r[7].isoformat(), "finish_date": r[8].isoformat() if r[8] else None,
                "abort_reason": r[9],
                "assignee_name": r[10], "creator_name": r[11]
            })
    return tasks

@app.post("/api/tasks")
async def create_task(data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        
        # Permission: Admin can create for anyone; others only for self
        assigned_to = data.get('assigned_to')
        if current_emp['department'] != 'Admin':
            if assigned_to and assigned_to != current_emp['id']:
                raise HTTPException(status_code=403, detail="Can only create tasks for yourself")
            assigned_to = current_emp['id']

        # Safety net against double-submit (Render cold starts make users click repeatedly):
        # reject an identical task (same title + assignee) created in the last 30 seconds.
        # IS NOT DISTINCT FROM so NULL title/assignee compare correctly.
        cur.execute(
            """SELECT id FROM task
               WHERE title IS NOT DISTINCT FROM %s
                 AND assigned_to IS NOT DISTINCT FROM %s
                 AND created_at > NOW() - INTERVAL '30 seconds'
               LIMIT 1""",
            (data.get('title'), assigned_to)
        )
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="This task was just created.")

        cur.execute(
            """INSERT INTO task (title, description, assigned_to, created_by, status, due_date)
               VALUES (%s, %s, %s, %s, %s, %s) RETURNING id""",
            (data.get('title'), data.get('description'), assigned_to, 
             current_emp['id'], data.get('status', 'pending'), data.get('due_date'))
        )
        task_id = cur.fetchone()[0]
    return {"id": str(task_id)}

@app.patch("/api/tasks/{task_id}")
async def update_task(task_id: str, data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        
        # Admin can update any task; others can only update their own
        if current_emp['department'] != 'Admin':
            cur.execute("SELECT assigned_to FROM task WHERE id = %s", (task_id,))
            row = cur.fetchone()
            if not row or str(row[0]) != current_emp['id']:
                raise HTTPException(status_code=403, detail="Can only update your own tasks")
        
        if data.get('status') == 'done':
            cur.execute(
                "UPDATE task SET status = %s, finish_date = NOW() WHERE id = %s",
                ('done', task_id)
            )
        elif data.get('status') == 'aborted':
            abort_reason = data.get('abort_reason')
            if not abort_reason:
                raise HTTPException(status_code=400, detail="abort_reason required when status is aborted")
            cur.execute(
                "UPDATE task SET status = %s, abort_reason = %s WHERE id = %s",
                ('aborted', abort_reason, task_id)
            )
        else:
            fields = []
            values = []
            if 'status' in data:
                fields.append("status = %s")
                values.append(data['status'])
            if 'title' in data:
                fields.append("title = %s")
                values.append(data['title'])
            if 'description' in data:
                fields.append("description = %s")
                values.append(data['description'])
            # Only Admin can reassign tasks
            if 'assigned_to' in data:
                if current_emp['department'] == 'Admin':
                    fields.append("assigned_to = %s")
                    values.append(data['assigned_to'])
            if 'due_date' in data:
                fields.append("due_date = %s")
                values.append(data['due_date'])
            
            if fields:
                values.append(task_id)
                cur.execute(f"UPDATE task SET {', '.join(fields)} WHERE id = %s", values)
    return {"status": "updated"}

@app.delete("/api/tasks/{task_id}")
async def delete_task(task_id: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT created_by, assigned_to FROM task WHERE id = %s", (task_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Task not found")
        # Admin may delete any task; others only a task they created or that is assigned to them.
        if current_emp['department'] != 'Admin':
            created_by = str(row[0])
            assigned_to = str(row[1]) if row[1] else None
            if current_emp['id'] not in (created_by, assigned_to):
                raise HTTPException(status_code=403,
                                    detail="You can only delete tasks you created or are assigned to")
        # task_comment.task_id has ON DELETE CASCADE (migration 001), so comments are removed automatically.
        cur.execute("DELETE FROM task WHERE id = %s", (task_id,))
    return {"status": "deleted"}

@app.get("/api/tasks/{task_id}/comments")
async def get_task_comments(task_id: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT tc.id, tc.body, tc.created_at, e.name
            FROM task_comment tc
            JOIN employee e ON tc.author_id = e.id
            WHERE tc.task_id = %s
            ORDER BY tc.created_at
        """, (task_id,))
        comments = []
        for r in cur.fetchall():
            comments.append({
                "id": str(r[0]), "body": r[1], "created_at": r[2].isoformat(), "author_name": r[3]
            })
    return comments

@app.post("/api/tasks/{task_id}/comments")
async def add_task_comment(task_id: str, data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO task_comment (task_id, author_id, body) VALUES (%s, %s, %s) RETURNING id",
            (task_id, current_emp['id'], data.get('body'))
        )
        comment_id = cur.fetchone()[0]
    return {"id": str(comment_id)}

@app.get("/api/employees")
async def get_employees(current_emp = Depends(get_current_employee)):
    # Directory access: Admin only
    if current_emp['department'] != 'Admin':
        raise HTTPException(status_code=403, detail="Employee directory access requires Admin department")
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, employee_id, name, job_role, joining_date, status, date_of_birth
            FROM employee
            WHERE active = true
            ORDER BY name
        """)
        employees = []
        for r in cur.fetchall():
            employees.append({
                "id": str(r[0]),
                "employee_id": r[1],
                "name": r[2],
                "job_role": r[3],
                "joining_date": r[4].isoformat() if r[4] else None,
                "status": r[5] or 'active',
                "date_of_birth": r[6].isoformat() if r[6] else None
            })
    return employees

@app.get("/api/employees/{employee_id}")
async def get_employee_detail(employee_id: str, current_emp = Depends(get_current_employee)):
    # Admin can view any employee; others can only view themselves
    if current_emp['department'] != 'Admin':
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only view your own profile")
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, employee_id, name, phone, email, job_role, address,
                   pay_scale_encrypted, joining_date, status, date_of_leaving,
                   paid_leave_quota, monthly_salary, department, date_of_birth
            FROM employee
            WHERE id = %s
        """, (employee_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Employee not found")
        
        # Decrypt pay_scale ONLY for Admin
        pay_scale = None
        if row[7]:
            if current_emp['department'] == 'Admin':
                pay_scale = decrypt_value(row[7])
            else:
                pay_scale = "••••••"
        
        # Get current month leave days
        from datetime import date
        today = date.today()
        first_day = today.replace(day=1)
        if today.month == 12:
            last_day = date(today.year + 1, 1, 1)
        else:
            last_day = date(today.year, today.month + 1, 1)
        
        cur.execute("""
            SELECT leave_date, leave_type
            FROM employee_leave_day
            WHERE employee_id = %s AND leave_date >= %s AND leave_date < %s
            ORDER BY leave_date
        """, (employee_id, first_day, last_day))
        
        leave_days = []
        for ld in cur.fetchall():
            leave_days.append({
                "date": ld[0].isoformat(),
                "type": ld[1]
            })
        
        # Count leave types for current month
        cur.execute("""
            SELECT leave_type, COUNT(*) as count
            FROM employee_leave_day
            WHERE employee_id = %s AND leave_date >= %s AND leave_date < %s
            GROUP BY leave_type
        """, (employee_id, first_day, last_day))
        
        leave_counts = {}
        for lc in cur.fetchall():
            leave_counts[lc[0]] = lc[1]
        
        # Get paid leave info for CURRENT MONTH (not year)
        cur.execute("""
            SELECT paid_leave_quota, monthly_salary, department
            FROM employee
            WHERE id = %s
        """, (employee_id,))
        pq_row = cur.fetchone()
        paid_leave_quota = pq_row[0] if pq_row and pq_row[0] else 0
        monthly_salary = float(pq_row[1]) if pq_row and pq_row[1] else None
        department = pq_row[2] if pq_row else None
        
        # Count paid leaves used THIS MONTH (not year)
        cur.execute("""
            SELECT COUNT(*) FROM employee_leave_day
            WHERE employee_id = %s 
              AND leave_type = 'paid_leave'
              AND leave_date >= %s 
              AND leave_date < %s
        """, (employee_id, first_day, last_day))
        paid_leave_used = cur.fetchone()[0]
        
        # Calculate salary deduction for current month
        import calendar
        days_in_month = calendar.monthrange(today.year, today.month)[1]
        per_day_salary = monthly_salary / days_in_month if monthly_salary else 0
        
        # Count leave days for deduction calculation
        total_leave_days = leave_counts.get('leave', 0)
        total_half_days = leave_counts.get('half_day', 0)
        total_deduction_days = total_leave_days + (total_half_days * 0.5)
        deduction_amount = total_deduction_days * per_day_salary
        net_salary = monthly_salary - deduction_amount if monthly_salary else None
        
        return {
            "id": str(row[0]),
            "employee_id": row[1],
            "name": row[2],
            "phone": row[3],
            "email": row[4],
            "job_role": row[5],
            "address": row[6],
            "pay_scale": pay_scale,
            "joining_date": row[8].isoformat() if row[8] else None,
            "status": row[9] or 'active',
            "date_of_leaving": row[10].isoformat() if row[10] else None,
            "paid_leave_quota": row[11] if row[11] else 0,
            "monthly_salary": float(row[12]) if row[12] else None,
            "department": row[13],
            "date_of_birth": row[14].isoformat() if row[14] else None,
            "leave_days": leave_days,
            "leave_counts": leave_counts,
            "paid_leave_used": paid_leave_used,
            "paid_leave_remaining": (row[11] or 0) - paid_leave_used,
            "days_in_month": days_in_month if monthly_salary else None,
            "per_day_salary": round(per_day_salary, 2) if monthly_salary else None,
            "deduction_amount": round(deduction_amount, 2) if monthly_salary else None,
            "net_salary": round(net_salary, 2) if monthly_salary else None
        }

# ---------------------------------------------------------------------------
# Biometric attendance helpers (source: cctv_attendance, joined via crm_id).
# NOTE: there is no holiday concept anywhere in the codebase, so "working day"
# means Mon-Sat and we EXCLUDE Sundays only.
# ---------------------------------------------------------------------------

def _parse_hms(t):
    """Parse an 'HH:MM:SS' (or 'HH:MM') attendance time string into seconds. None on bad/empty input."""
    if not t:
        return None
    parts = str(t).split(":")
    try:
        h = int(parts[0])
        m = int(parts[1]) if len(parts) > 1 else 0
        s = int(parts[2]) if len(parts) > 2 else 0
        return h * 3600 + m * 60 + s
    except (ValueError, IndexError):
        return None

def _fmt_hms(total_seconds):
    """Format an average number of seconds back into a display 'HH:MM'. None passes through."""
    if total_seconds is None:
        return None
    total_seconds = int(total_seconds) % 86400
    return f"{total_seconds // 3600:02d}:{(total_seconds % 3600) // 60:02d}"

def _compute_day_status(entry_time, exit_time):
    """Classify a day from its HH:MM:SS entry/exit strings.

    Returns (day_status, hours_worked). hours_worked is a float rounded to 2dp,
    or None when it cannot be computed. Statuses:
      - 'full_day'     hours >= FULL_DAY_MIN_HOURS
      - 'half_day'     hours >= HALF_DAY_MIN_HOURS but < full
      - 'short_day'    0 <= hours < HALF_DAY_MIN_HOURS  (review state)
      - 'missing_exit' entry present but no usable exit  (review state; do NOT guess)
      - None           no entry at all
    'short_day' and 'missing_exit' are REVIEW states — callers must never treat
    them as a plain full day or as absent.
    """
    e = _parse_hms(entry_time)
    if e is None:
        return None, None
    x = _parse_hms(exit_time)
    if x is None or x < e:
        # No exit, or an exit that lands before entry (corrupt) — needs a human.
        return 'missing_exit', None
    hours = round((x - e) / 3600.0, 2)
    if hours >= FULL_DAY_MIN_HOURS:
        return 'full_day', hours
    if hours >= HALF_DAY_MIN_HOURS:
        return 'half_day', hours
    return 'short_day', hours


def _report_status(entry_time, exit_time, day_status, status_override):
    """The status a report/UI should show for a row.

    Prefers an Admin status_override, then the stored day_status, and finally
    computes one live from the times (for old rows left NULL by migration 031 —
    this is deterministic, not a guessed backfill, and is never written to the DB).
    """
    if status_override:
        return status_override
    if day_status:
        return day_status
    ds, _ = _compute_day_status(entry_time, exit_time)
    return ds


# Statuses that mean "a human still needs to look at this day". They must never
# be silently collapsed into present/full-day or absent in any report.
ATTENDANCE_REVIEW_STATUSES = ('short_day', 'missing_exit')

# Day types markable on the calendar (employee_leave_day.leave_type, migration 033).
# 'wfh' is NOT leave: it means the person worked from home, so it neither deducts
# salary nor consumes paid leave quota — it only stops the day counting as absent.
MARKABLE_DAY_TYPES = ('leave', 'half_day', 'paid_leave', 'wfh')


def compute_employee_attendance(cur, employee_id, year, month):
    """Compute per-day + summary biometric attendance for one employee/month.

    Returns (mapped, days, summary). If the employee has no device mapping at all,
    mapped is False and the summary reads zero present / zero absent so callers can
    say 'not linked to a biometric device' instead of implying absence every day.
    """
    import calendar as _calendar
    from datetime import date as _date

    # Is this employee linked to any biometric device id?
    cur.execute(
        "SELECT 1 FROM device_person_map WHERE crm_person_id = %s AND person_type = 'employee' LIMIT 1",
        (employee_id,),
    )
    mapped = cur.fetchone() is not None

    first_day = _date(year, month, 1)
    last_day = _date(year + 1, 1, 1) if month == 12 else _date(year, month + 1, 1)

    cur.execute(
        """
        SELECT date, entry_time, exit_time, day_status, status_override
        FROM cctv_attendance
        WHERE crm_id = %s AND date >= %s AND date < %s
        ORDER BY date
        """,
        (employee_id, first_day, last_day),
    )
    rows = cur.fetchall()

    days = []
    entry_secs = []
    exit_secs = []
    total_hours = 0.0
    present_dates = set()
    full_days = 0
    half_days = 0
    review_days = 0
    for d, et, xt, day_status, status_override in rows:
        e = _parse_hms(et)
        x = _parse_hms(xt)
        hours = None
        if e is not None and x is not None and x >= e:
            hours = round((x - e) / 3600.0, 2)
            total_hours += hours
        if et:
            present_dates.add(d)
            if e is not None:
                entry_secs.append(e)
        if x is not None:
            exit_secs.append(x)
        status = _report_status(et, xt, day_status, status_override)
        if status == 'full_day':
            full_days += 1
        elif status == 'half_day':
            half_days += 1
        elif status in ATTENDANCE_REVIEW_STATUSES:
            review_days += 1
        days.append({
            "date": d.isoformat(),
            "entry_time": et,
            "exit_time": xt,
            "hours_worked": hours,
            "status": status,
        })

    # Leave days already recorded this month (any type) don't count as absences.
    # 'wfh' lives in the same table but means the person WORKED — it is excluded
    # from absences like the others and reported separately as wfh_days. It is
    # never a biometric "day present" (no punch) and never counts as leave.
    cur.execute(
        """
        SELECT leave_date, leave_type FROM employee_leave_day
        WHERE employee_id = %s AND leave_date >= %s AND leave_date < %s
        """,
        (employee_id, first_day, last_day),
    )
    leave_rows = cur.fetchall()
    leave_dates = {r[0] for r in leave_rows}
    wfh_days = len([r for r in leave_rows if r[1] == 'wfh'])

    # Working days = non-Sundays, capped at today so future days of an ongoing
    # month are not counted as absences.
    today = _date.today()
    days_in_month = _calendar.monthrange(year, month)[1]
    working_days = 0
    for dnum in range(1, days_in_month + 1):
        dt = _date(year, month, dnum)
        if dt.weekday() == 6:      # Sunday
            continue
        if dt > today:             # future day of the current month
            continue
        working_days += 1

    days_present = len(present_dates)

    if not mapped:
        # No device mapping -> do NOT imply absence.
        return False, [], {
            "days_present": 0,
            "days_absent": 0,
            "total_hours": 0.0,
            "average_entry_time": None,
            "average_exit_time": None,
            "working_days": working_days,
            "full_days": 0,
            "half_days": 0,
            "days_needing_review": 0,
            "wfh_days": wfh_days,
        }

    working_leave_days = len([d for d in leave_dates if d.weekday() != 6])
    days_absent = working_days - days_present - working_leave_days
    if days_absent < 0:
        days_absent = 0

    summary = {
        "days_present": days_present,
        "days_absent": days_absent,
        "total_hours": round(total_hours, 2),
        "average_entry_time": _fmt_hms(sum(entry_secs) / len(entry_secs)) if entry_secs else None,
        "average_exit_time": _fmt_hms(sum(exit_secs) / len(exit_secs)) if exit_secs else None,
        "working_days": working_days,
        "full_days": full_days,
        "half_days": half_days,
        "days_needing_review": review_days,
        "wfh_days": wfh_days,
    }
    return True, days, summary

@app.get("/api/employees/{employee_id}/attendance/{year}/{month}")
async def get_employee_attendance(employee_id: str, year: int, month: int, current_emp = Depends(get_current_employee)):
    """Per-employee biometric attendance for a month (from cctv_attendance via crm_id)."""
    # Admin can view anyone; an employee can only view their own record.
    if current_emp['department'] != 'Admin':
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only view your own attendance")

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT name FROM employee WHERE id = %s", (employee_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Employee not found")

        mapped, days, summary = compute_employee_attendance(cur, employee_id, year, month)

    return {
        "employee_id": employee_id,
        "employee_name": row[0],
        "year": year,
        "month": month,
        "mapped": mapped,
        "days": days,
        "summary": summary,
    }

@app.post("/api/employees")
async def create_employee(data: dict, current_emp = Depends(get_current_employee)):
    # name/phone are NOT NULL (migration 001) — name them in a 400 rather than
    # letting the insert raise a 500.
    require_fields(data, 'name', 'phone')
    # joining_date/date_of_leaving are DATE and paid_leave_quota/monthly_salary are
    # numeric: "" from the form has to become NULL, not reach Postgres as a string.
    blank_to_none(data, 'employee_id', 'email', 'job_role', 'address', 'pay_scale',
                  'joining_date', 'date_of_leaving', 'login_pin',
                  'paid_leave_quota', 'monthly_salary', 'date_of_birth')
    validate_dob(data)
    with get_db() as conn:
        cur = conn.cursor()

        # Encrypt pay_scale if provided
        pay_scale_encrypted = None
        if data.get('pay_scale'):
            pay_scale_encrypted = encrypt_value(data['pay_scale'])

        # department is NOT NULL + enum-constrained (migration 020). Default to most restrictive; reject unknown.
        department = data.get('department') or 'IT'
        if department not in ('Admin', 'IT', 'Sales', 'Instructors'):
            raise HTTPException(status_code=400, detail="department must be one of: Admin, IT, Sales, Instructors")

        # login_id is NOT NULL with a UNIQUE index on LOWER(login_id) (migration 019).
        # Derive it following migration 019's own convention: employee_id, else phone.
        login_id = data.get('login_id') or data.get('employee_id') or data.get('phone')
        if not login_id:
            raise HTTPException(status_code=400, detail="login_id, employee_id or phone is required")

        # login_pin is optional (migration 009); insert only when provided.
        login_pin = data.get('login_pin') or None

        # Pre-check the case-insensitive UNIQUE index to give a clean 409 instead of a raw DB error.
        cur.execute("SELECT 1 FROM employee WHERE LOWER(login_id) = LOWER(%s)", (login_id,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="An employee with this login ID already exists")

        try:
            cur.execute(
                """INSERT INTO employee (
                    employee_id, login_id, login_pin, name, phone, email, job_role, address,
                    pay_scale_encrypted, joining_date, status, date_of_leaving, date_of_birth,
                    department, password_hash, permissions
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id""",
                (
                    data.get('employee_id'), login_id, login_pin,
                    data.get('name'), data.get('phone'),
                    data.get('email'), data.get('job_role'), data.get('address'),
                    pay_scale_encrypted, data.get('joining_date'),
                    data.get('status') or 'active', data.get('date_of_leaving'),
                    data.get('date_of_birth'),
                    department,
                    hash_password(data.get('password', 'welcome123')),
                    json.dumps(data.get('permissions', {}))
                )
            )
            emp_id = cur.fetchone()[0]
        except psycopg.errors.UniqueViolation:
            # Closes the race between the pre-check above and the insert.
            raise HTTPException(status_code=409, detail="An employee with this login ID already exists")
    return {"id": str(emp_id)}

@app.patch("/api/employees/{employee_id}")
async def update_employee(employee_id: str, data: dict, current_emp = Depends(get_current_employee)):
    # Only admin can edit most fields; employees can edit their own limited fields
    if current_emp.get('is_employee_session'):
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only edit your own profile")
        # Employees cannot edit most fields
        allowed_fields = []  # No direct profile edits for employees yet
        if any(key not in allowed_fields for key in data.keys()):
            raise HTTPException(status_code=403, detail="Cannot edit profile fields")
    
    # Only Admin can edit pay_scale and department
    if 'pay_scale' in data and current_emp['department'] != 'Admin':
        raise HTTPException(status_code=403, detail="Only Admin can edit pay scale")
    
    if 'department' in data and current_emp['department'] != 'Admin':
        raise HTTPException(status_code=403, detail="Only Admin can change department")

    # Clearing the DOB input sends "" and must store NULL, not reach the DATE column.
    blank_to_none(data, 'date_of_birth')
    validate_dob(data)

    with get_db() as conn:
        cur = conn.cursor()
        fields = []
        values = []
        
        field_map = {
            'employee_id': 'employee_id', 'name': 'name', 'phone': 'phone',
            'email': 'email', 'job_role': 'job_role', 'address': 'address',
            'joining_date': 'joining_date', 'status': 'status', 
            'date_of_leaving': 'date_of_leaving', 'date_of_birth': 'date_of_birth',
            'login_pin': 'login_pin',
            'paid_leave_quota': 'paid_leave_quota', 'monthly_salary': 'monthly_salary',
            'department': 'department', 'login_id': 'login_id'
        }
        
        for key, col in field_map.items():
            if key in data:
                fields.append(f"{col} = %s")
                values.append(data[key])
        
        # Handle pay_scale encryption
        if 'pay_scale' in data:
            fields.append("pay_scale_encrypted = %s")
            values.append(encrypt_value(data['pay_scale']) if data['pay_scale'] else None)
        
        if fields:
            values.append(employee_id)
            cur.execute(f"UPDATE employee SET {', '.join(fields)} WHERE id = %s", values)
    
    return {"status": "updated"}

@app.post("/api/employees/{employee_id}/leave")
async def mark_leave_day(employee_id: str, data: dict, current_emp = Depends(get_current_employee)):
    # Admin can mark anyone's leave; employees can mark their own
    if current_emp['department'] != 'Admin':
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only mark your own leave")

    leave_type = data.get('leave_type')
    leave_date = data.get('leave_date')

    # Reject unknown types here rather than letting the CHECK constraint 500.
    if leave_type not in MARKABLE_DAY_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid leave_type '{leave_type}'. Must be one of: {', '.join(MARKABLE_DAY_TYPES)}"
        )
    if not leave_date:
        raise HTTPException(status_code=400, detail="leave_date is required")

    with get_db() as conn:
        cur = conn.cursor()
        
        # Check paid leave quota if marking as paid leave (MONTHLY quota)
        if leave_type == 'paid_leave':
            from datetime import datetime
            leave_date_obj = datetime.fromisoformat(leave_date)
            
            # Get employee's paid leave quota (monthly)
            cur.execute("""
                SELECT paid_leave_quota FROM employee WHERE id = %s
            """, (employee_id,))
            row = cur.fetchone()
            quota = row[0] if row and row[0] else 0
            
            if quota == 0:
                raise HTTPException(status_code=400, detail="No paid leave quota assigned. Contact admin.")
            
            # Count paid leaves used THIS MONTH (not year)
            from datetime import date
            year = leave_date_obj.year
            month = leave_date_obj.month
            first_day = date(year, month, 1)
            if month == 12:
                last_day = date(year + 1, 1, 1)
            else:
                last_day = date(year, month + 1, 1)
            
            cur.execute("""
                SELECT COUNT(*) FROM employee_leave_day
                WHERE employee_id = %s 
                  AND leave_type = 'paid_leave'
                  AND leave_date >= %s 
                  AND leave_date < %s
                  AND leave_date != %s
            """, (employee_id, first_day, last_day, leave_date))
            used = cur.fetchone()[0]
            
            if used >= quota:
                raise HTTPException(
                    status_code=400, 
                    detail=f"No More Paid Leaves Available. Used {used}/{quota} for this month"
                )
        
        cur.execute("""
            INSERT INTO employee_leave_day (employee_id, leave_date, leave_type, marked_by)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (employee_id, leave_date) 
            DO UPDATE SET leave_type = EXCLUDED.leave_type, marked_by = EXCLUDED.marked_by
            RETURNING id
        """, (employee_id, leave_date, leave_type, current_emp['id']))
        leave_id = cur.fetchone()[0]
    return {"id": str(leave_id)}

@app.delete("/api/employees/{employee_id}/leave/{leave_date}")
async def unmark_leave_day(employee_id: str, leave_date: str, current_emp = Depends(get_current_employee)):
    # Admin can unmark anyone's leave; employees can unmark their own
    if current_emp['department'] != 'Admin':
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only unmark your own leave")
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM employee_leave_day WHERE employee_id = %s AND leave_date = %s",
            (employee_id, leave_date)
        )
    return {"status": "deleted"}

@app.get("/api/employees/{employee_id}/salary-report/{year}/{month}")
async def get_monthly_salary_report(employee_id: str, year: int, month: int, current_emp = Depends(get_current_employee)):
    """Calculate monthly salary with leave deductions"""
    # Only Admin or employee themselves can view
    if current_emp['department'] != 'Admin':
        if employee_id != current_emp['id']:
            raise HTTPException(status_code=403, detail="Can only view your own salary report")
    
    from datetime import date
    import calendar
    
    with get_db() as conn:
        cur = conn.cursor()
        
        # Get employee monthly salary
        cur.execute("SELECT monthly_salary, name FROM employee WHERE id = %s", (employee_id,))
        row = cur.fetchone()
        if not row or not row[0]:
            raise HTTPException(status_code=404, detail="Monthly salary not set for employee")
        
        base_salary = float(row[0])
        emp_name = row[1]
        
        # Calculate days in month
        days_in_month = calendar.monthrange(year, month)[1]
        per_day_salary = base_salary / days_in_month
        
        # Get leave days for the month
        first_day = date(year, month, 1)
        if month == 12:
            last_day = date(year + 1, 1, 1)
        else:
            last_day = date(year, month + 1, 1)
        
        cur.execute("""
            SELECT leave_type, COUNT(*) as count
            FROM employee_leave_day
            WHERE employee_id = %s AND leave_date >= %s AND leave_date < %s
            GROUP BY leave_type
        """, (employee_id, first_day, last_day))
        
        leave_days = 0
        half_days = 0
        paid_leave_days = 0
        
        for lt, cnt in cur.fetchall():
            if lt == 'leave':
                leave_days = cnt
            elif lt == 'half_day':
                half_days = cnt
            elif lt == 'paid_leave':
                paid_leave_days = cnt
        
        # Calculate deduction
        # Leave = full day deduction
        # Half day = 0.5 day deduction
        # Paid leave = 0 deduction
        total_deduction_days = leave_days + (half_days * 0.5)
        deduction_amount = total_deduction_days * per_day_salary
        net_salary = base_salary - deduction_amount
        
        # Save/update report
        cur.execute("""
            INSERT INTO monthly_salary_report (
                employee_id, year, month, days_in_month, base_salary,
                leave_days, half_days, paid_leave_days, deduction_amount, net_salary
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (employee_id, year, month)
            DO UPDATE SET
                days_in_month = EXCLUDED.days_in_month,
                base_salary = EXCLUDED.base_salary,
                leave_days = EXCLUDED.leave_days,
                half_days = EXCLUDED.half_days,
                paid_leave_days = EXCLUDED.paid_leave_days,
                deduction_amount = EXCLUDED.deduction_amount,
                net_salary = EXCLUDED.net_salary
            RETURNING id
        """, (employee_id, year, month, days_in_month, base_salary, 
              leave_days, half_days, paid_leave_days, deduction_amount, net_salary))

        # Biometric attendance figures for the same month. These are ADDITIONAL,
        # informational fields — they do NOT feed into deduction_amount/net_salary,
        # which are still driven solely by marked leave (see get_monthly_salary_report docstring).
        att_mapped, _att_days, att_summary = compute_employee_attendance(cur, employee_id, year, month)

        return {
            "employee_id": employee_id,
            "employee_name": emp_name,
            "year": year,
            "month": month,
            "days_in_month": days_in_month,
            "base_salary": base_salary,
            "per_day_salary": round(per_day_salary, 2),
            "leave_days": leave_days,
            "half_days": half_days,
            "paid_leave_days": paid_leave_days,
            "total_deduction_days": round(total_deduction_days, 2),
            "deduction_amount": round(deduction_amount, 2),
            "net_salary": round(net_salary, 2),
            # --- Biometric attendance (informational; not used in pay calc) ---
            "attendance_mapped": att_mapped,
            "days_present": att_summary["days_present"],
            "days_absent": att_summary["days_absent"],
            "total_hours": att_summary["total_hours"],
            "working_days": att_summary["working_days"]
        }

@app.get("/api/salary-reports/{year}/{month}")
async def get_all_salary_reports(year: int, month: int, current_emp = Depends(get_current_employee)):
    """Get all employees' salary reports for a given month (Admin only)"""
    if current_emp['department'] != 'Admin':
        raise HTTPException(status_code=403, detail="Admin access required")
    
    with get_db() as conn:
        cur = conn.cursor()
        
        # Get all active employees with monthly salary
        cur.execute("""
            SELECT id, name, monthly_salary
            FROM employee
            WHERE active = true AND monthly_salary IS NOT NULL
            ORDER BY name
        """)
        
        reports = []
        for emp_id, emp_name, _ in cur.fetchall():
            try:
                # Generate report for each employee
                report_res = await get_monthly_salary_report(str(emp_id), year, month, current_emp)
                reports.append(report_res)
            except:
                pass  # Skip employees with errors
        
        return reports

@app.get("/api/leaves")
async def get_leaves(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT l.id, l.employee_id, l.start_date, l.end_date, l.reason, l.approved, l.created_at,
                   e.name as employee_name
            FROM leave_record l
            JOIN employee e ON l.employee_id = e.id
            WHERE l.start_date >= NOW() - INTERVAL '90 days'
            ORDER BY l.start_date DESC
        """)
        leaves = []
        for r in cur.fetchall():
            leaves.append({
                "id": str(r[0]), "employee_id": str(r[1]), "start_date": r[2].isoformat(),
                "end_date": r[3].isoformat(), "reason": r[4], "approved": r[5],
                "created_at": r[6].isoformat(), "employee_name": r[7]
            })
    return leaves

@app.post("/api/leaves")
async def create_leave(data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO leave_record (employee_id, start_date, end_date, reason, approved)
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (data.get('employee_id', current_emp['id']), data.get('start_date'), 
             data.get('end_date'), data.get('reason'), False)
        )
        leave_id = cur.fetchone()[0]
    return {"id": str(leave_id)}

@app.patch("/api/leaves/{leave_id}/approve")
async def approve_leave(leave_id: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE leave_record SET approved = true, approved_by = %s WHERE id = %s",
            (current_emp['id'], leave_id)
        )
    return {"status": "approved"}

@app.get("/api/meetings")
async def get_meetings(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT m.id, m.title, m.description, m.scheduled_at, m.duration_minutes, m.created_at,
                   e.name as creator_name
            FROM meeting m
            JOIN employee e ON m.created_by = e.id
            WHERE m.scheduled_at >= NOW() - INTERVAL '7 days'
            ORDER BY m.scheduled_at
        """)
        meetings = []
        for r in cur.fetchall():
            meetings.append({
                "id": str(r[0]), "title": r[1], "description": r[2],
                "scheduled_at": r[3].isoformat(), "duration_minutes": r[4],
                "created_at": r[5].isoformat(), "creator_name": r[6]
            })
    return meetings

@app.post("/api/meetings")
async def create_meeting(data: dict, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO meeting (title, description, scheduled_at, duration_minutes, created_by)
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (data.get('title'), data.get('description'), data.get('scheduled_at'),
             data.get('duration_minutes', 60), current_emp['id'])
        )
        meeting_id = cur.fetchone()[0]
        
        if data.get('attendees'):
            for attendee_id in data['attendees']:
                cur.execute(
                    "INSERT INTO meeting_attendee (meeting_id, employee_id) VALUES (%s, %s)",
                    (meeting_id, attendee_id)
                )
    return {"id": str(meeting_id)}

@app.get("/api/policy-docs")
async def get_policy_docs(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, title, content, created_at FROM policy_doc ORDER BY created_at DESC")
        docs = []
        for r in cur.fetchall():
            docs.append({
                "id": str(r[0]), "title": r[1], "content": r[2][:200], "created_at": r[3].isoformat()
            })
    return docs

@app.post("/api/policy-docs")
async def create_policy_doc(data: dict, current_emp = Depends(get_current_employee)):
    title = data.get('title')
    content = data.get('content')
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO policy_doc (title, content, created_by)
               VALUES (%s, %s, %s) RETURNING id""",
            (title, content, current_emp['id'])
        )
        doc_id = cur.fetchone()[0]
    
    return {"id": str(doc_id)}

@app.post("/api/policy-docs/upload")
async def upload_policy_doc(file: UploadFile = File(...), current_emp = Depends(get_current_employee)):
    content = (await file.read()).decode('utf-8')
    title = file.filename
    
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO policy_doc (title, content, created_by)
               VALUES (%s, %s, %s) RETURNING id""",
            (title, content, current_emp['id'])
        )
        doc_id = cur.fetchone()[0]
    
    return {"id": str(doc_id), "title": title}

@app.get("/api/policy-docs/search")
async def search_policy_docs(q: str, current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, title, content, created_at 
            FROM policy_doc 
            WHERE title ILIKE %s OR content ILIKE %s
            ORDER BY created_at DESC
        """, (f'%{q}%', f'%{q}%'))
        docs = []
        for r in cur.fetchall():
            docs.append({
                "id": str(r[0]), "title": r[1], "content": r[2][:300], "created_at": r[3].isoformat()
            })
    return docs

@app.get("/api/dispositions/stats")
async def get_disposition_stats(current_emp = Depends(get_current_employee)):
    """Get counts for each disposition table"""
    with get_db() as conn:
        cur = conn.cursor()
        
        cur.execute("SELECT COUNT(*) FROM interested")
        interested_count = cur.fetchone()[0]
        
        cur.execute("SELECT COUNT(*) FROM not_interested")
        not_interested_count = cur.fetchone()[0]
        
        cur.execute("SELECT COUNT(*) FROM not_reachable")
        not_reachable_count = cur.fetchone()[0]
        
        cur.execute("SELECT COUNT(*) FROM callback")
        callback_count = cur.fetchone()[0]
        
        return {
            "interested": interested_count,
            "not_interested": not_interested_count,
            "not_reachable": not_reachable_count,
            "callback": callback_count
        }

@app.get("/api/dispositions/interested")
async def get_interested_leads(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, lead_id, name, phone, email, course_interest, address, note, 
                   marked_by, marked_at
            FROM interested
            ORDER BY marked_at DESC
        """)
        return [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "name": r[2], "phone": r[3],
                "email": r[4], "course_interest": r[5], "address": r[6], "note": r[7],
                "marked_by": str(r[8]) if r[8] else None, 
                "marked_at": r[9].isoformat() if r[9] else None
            }
            for r in cur.fetchall()
        ]

@app.get("/api/dispositions/not-interested")
async def get_not_interested_leads(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, lead_id, name, phone, email, course_interest, address, note, 
                   marked_by, marked_at
            FROM not_interested
            ORDER BY marked_at DESC
        """)
        return [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "name": r[2], "phone": r[3],
                "email": r[4], "course_interest": r[5], "address": r[6], "note": r[7],
                "marked_by": str(r[8]) if r[8] else None, 
                "marked_at": r[9].isoformat() if r[9] else None
            }
            for r in cur.fetchall()
        ]

@app.get("/api/dispositions/not-reachable")
async def get_not_reachable_leads(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, lead_id, name, phone, email, course_interest, address, note, 
                   marked_by, marked_at
            FROM not_reachable
            ORDER BY marked_at DESC
        """)
        return [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "name": r[2], "phone": r[3],
                "email": r[4], "course_interest": r[5], "address": r[6], "note": r[7],
                "marked_by": str(r[8]) if r[8] else None, 
                "marked_at": r[9].isoformat() if r[9] else None
            }
            for r in cur.fetchall()
        ]

@app.get("/api/dispositions/callback")
async def get_callback_leads(current_emp = Depends(get_current_employee)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, lead_id, name, phone, email, course_interest, address, note, 
                   callback_date, callback_reason, marked_by, marked_at
            FROM callback
            ORDER BY marked_at DESC
        """)
        return [
            {
                "id": str(r[0]), "lead_id": str(r[1]), "name": r[2], "phone": r[3],
                "email": r[4], "course_interest": r[5], "address": r[6], "note": r[7],
                "callback_date": r[8].isoformat() if r[8] else None,
                "callback_reason": r[9],
                "marked_by": str(r[10]) if r[10] else None, 
                "marked_at": r[11].isoformat() if r[11] else None
            }
            for r in cur.fetchall()
        ]

# ============================ STUDENTS MODULE ============================

STUDENT_DOC_TYPES = [
    'photo_id_proof', 'passport_photo', 'signature',
    'marksheet_10', 'certificate_10', 'marksheet_12', 'certificate_12',
    'board_verification_10', 'board_verification_12',
    'passport', 'i20_admission_letter', 'medical',
]
_ALLOWED_IMAGE_FORMATS = {'JPEG', 'PNG', 'HEIF', 'HEIC'}
_MAX_UPLOAD_BYTES = 10 * 1024 * 1024
_heif_registered = False


def _require_students_access(current_emp):
    # Fail-closed department gate, consistent with leads: only Admin/Sales.
    if current_emp['department'] not in ('Admin', 'Sales'):
        raise HTTPException(status_code=403, detail="Students access requires Admin or Sales department")


def _process_image(raw: bytes):
    """Validate real image type from CONTENT (not extension), enforce size, convert HEIC/HEIF->JPEG.
    Returns (out_bytes, mime_type, ext). Rejects anything that is not JPEG/PNG/HEIF/HEIC."""
    global _heif_registered
    if len(raw) > _MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=400, detail="File exceeds 10MB limit")
    from PIL import Image
    if not _heif_registered:
        import pillow_heif
        pillow_heif.register_heif_opener()
        _heif_registered = True
    try:
        img = Image.open(io.BytesIO(raw))
        fmt = (img.format or '').upper()
    except Exception:
        raise HTTPException(status_code=400, detail="Unreadable or invalid image file")
    if fmt not in _ALLOWED_IMAGE_FORMATS:
        raise HTTPException(status_code=400, detail="Unsupported file type. Allowed: JPEG, PNG, HEIF, HEIC")
    if fmt in ('HEIF', 'HEIC'):
        out = io.BytesIO()
        img.convert('RGB').save(out, format='JPEG', quality=90)
        return out.getvalue(), 'image/jpeg', 'jpg'
    if fmt == 'PNG':
        return raw, 'image/png', 'png'
    return raw, 'image/jpeg', 'jpg'


def validate_student_mobile(raw) -> str:
    """Return the E.164 form of an Indian 10-digit mobile, or 400.

    Tolerates the shapes people actually type — spaces, dashes, a +91/91/0 prefix —
    then insists on exactly 10 digits starting 6-9. Normalization itself is delegated
    to normalize_phone so there is one implementation of that in the codebase."""
    digits = re.sub(r'\D', '', str(raw))
    if len(digits) == 12 and digits.startswith('91'):
        digits = digits[2:]
    elif len(digits) == 11 and digits.startswith('0'):
        digits = digits[1:]
    if len(digits) != 10 or digits[0] not in '6789':
        raise HTTPException(
            status_code=400,
            detail="Mobile must be a 10-digit Indian mobile number (starting 6-9)",
        )
    return normalize_phone(digits)


def _audit(cur, actor, action, entity, payload):
    cur.execute(
        "INSERT INTO audit_log (actor, action, entity, payload) VALUES (%s, %s, %s, %s)",
        (actor, action, entity, json.dumps(payload))
    )


@app.get("/api/students")
async def list_students(search: str = "", current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        like = f"%{search.strip()}%"
        cur.execute("""
            SELECT s.id, s.first_name, s.middle_name, s.last_name, s.mobile, s.course,
                   s.admission_date, s.computer_number, s.date_of_birth,
                   (SELECT COUNT(DISTINCT doc_type) FROM student_document WHERE student_id = s.id) AS doc_count
            FROM student s
            WHERE (%s = '' OR
                   s.first_name ILIKE %s OR s.last_name ILIKE %s OR s.middle_name ILIKE %s OR
                   s.mobile ILIKE %s OR s.computer_number ILIKE %s OR s.course ILIKE %s)
            ORDER BY s.created_at DESC
        """, (search.strip(), like, like, like, like, like, like))
        total = len(STUDENT_DOC_TYPES)
        return [
            {
                "id": str(r[0]),
                "name": " ".join(x for x in [r[1], r[2], r[3]] if x),
                "mobile": r[4], "course": r[5],
                "admission_date": r[6].isoformat() if r[6] else None,
                "computer_number": r[7],
                "date_of_birth": r[8].isoformat() if r[8] else None,
                "documents_complete": r[9], "documents_total": total,
            }
            for r in cur.fetchall()
        ]


@app.get("/api/students/prefill-leads")
async def student_prefill_leads(current_emp = Depends(get_current_employee)):
    """Leads with completed admissions, for prefilling Add Student."""
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, name, guardian_name, phone, address, course_interest
            FROM lead
            WHERE closure_outcome = 'admission_completed'
            ORDER BY created_at DESC
        """)
        return [
            {"id": str(r[0]), "name": r[1], "guardian_name": r[2], "phone": r[3],
             "address": r[4], "course_interest": r[5]}
            for r in cur.fetchall()
        ]


@app.get("/api/students/{student_id}")
async def get_student(student_id: str, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, first_name, middle_name, last_name, guardian_name, mobile,
                   emergency_contact, address, course, admission_date, computer_number, lead_id,
                   created_at, date_of_birth
            FROM student WHERE id = %s
        """, (student_id,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="Student not found")
        student = {
            "id": str(r[0]), "first_name": r[1], "middle_name": r[2], "last_name": r[3],
            "guardian_name": r[4], "mobile": r[5], "emergency_contact": r[6], "address": r[7],
            "course": r[8], "admission_date": r[9].isoformat() if r[9] else None,
            "computer_number": r[10], "lead_id": str(r[11]) if r[11] else None,
            "created_at": r[12].isoformat() if r[12] else None,
            "date_of_birth": r[13].isoformat() if r[13] else None,
        }
        cur.execute("""
            SELECT id, doc_type, original_filename, mime_type, size_bytes, uploaded_at
            FROM student_document WHERE student_id = %s ORDER BY uploaded_at DESC
        """, (student_id,))
        docs = {}
        for d in cur.fetchall():
            docs[d[1]] = {
                "id": str(d[0]), "doc_type": d[1], "original_filename": d[2],
                "mime_type": d[3], "size_bytes": d[4],
                "uploaded_at": d[5].isoformat() if d[5] else None,
            }
        student["doc_types"] = STUDENT_DOC_TYPES
        student["documents"] = docs  # keyed by doc_type; missing types absent
        return student


@app.post("/api/students")
async def create_student(data: dict, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    require_fields(data, 'first_name', 'mobile')
    # Every column below this line is nullable: "" from the form must become NULL.
    # last_name included — single-name students are common (migration 032).
    blank_to_none(data, 'middle_name', 'last_name', 'guardian_name', 'emergency_contact',
                  'address', 'course', 'admission_date', 'computer_number', 'lead_id',
                  'date_of_birth')
    validate_dob(data)
    first = data['first_name'].strip()
    last = (data.get('last_name') or '').strip() or None
    raw_mobile = data['mobile'].strip()
    mobile_norm = normalize_phone(raw_mobile)
    emergency = normalize_phone(data['emergency_contact']) if data.get('emergency_contact') else None
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, first_name, last_name FROM student WHERE mobile_normalized = %s", (mobile_norm,))
        dup = cur.fetchone()
        if dup:
            # last_name may be NULL — join only the parts that exist so the
            # message never reads "Aarav None" or carries a trailing space.
            return {"status": "duplicate", "student_id": str(dup[0]),
                    "name": " ".join(x for x in [dup[1], dup[2]] if x)}
        cur.execute("""
            INSERT INTO student (first_name, middle_name, last_name, guardian_name, mobile,
                                 mobile_normalized, emergency_contact, address, course,
                                 admission_date, computer_number, lead_id, date_of_birth, created_by)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, COALESCE(%s, CURRENT_DATE), %s, %s, %s, %s)
            RETURNING id
        """, (first, data.get('middle_name'), last, data.get('guardian_name'), mobile_norm,
              mobile_norm, emergency, data.get('address'), data.get('course'),
              data.get('admission_date'), data.get('computer_number'), data.get('lead_id'),
              data.get('date_of_birth'), current_emp['id']))
        student_id = cur.fetchone()[0]
        _audit(cur, current_emp['id'], 'create', 'student', {"student_id": str(student_id)})
        return {"status": "created", "student_id": str(student_id)}


@app.patch("/api/students/{student_id}")
async def update_student(student_id: str, data: dict, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    allowed = {'first_name', 'middle_name', 'last_name', 'guardian_name', 'address',
               'course', 'admission_date', 'computer_number', 'emergency_contact',
               'date_of_birth', 'mobile'}
    # first_name and mobile are both NOT NULL; blanking either is a 400, not a 500.
    # Blanking mobile would additionally lock the student out of their own portal.
    require_fields(data, *(k for k in ('first_name', 'mobile') if k in data))
    # The rest are nullable: clearing an input sends "" and must store NULL.
    blank_to_none(data, 'middle_name', 'last_name', 'guardian_name', 'address', 'course',
                  'admission_date', 'computer_number', 'emergency_contact', 'date_of_birth')
    validate_dob(data)

    # mobile drives mobile_normalized — the student's LOGIN identifier, and UNIQUE.
    # Normalize once and write BOTH columns from that one value (create_student does
    # the same): if they ever diverge, the student silently cannot sign in.
    mobile_norm = validate_student_mobile(data['mobile']) if 'mobile' in data else None

    fields, values = [], []
    for k in allowed:
        if k in data and k != 'mobile':
            val = data[k]
            if k == 'emergency_contact' and val:
                val = normalize_phone(val)
            fields.append(f"{k} = %s")
            values.append(val)
    if mobile_norm is not None:
        fields.append("mobile = %s")
        values.append(mobile_norm)
        fields.append("mobile_normalized = %s")
        values.append(mobile_norm)
    if not fields:
        raise HTTPException(status_code=400, detail="No editable fields provided")
    fields.append("updated_at = NOW()")
    values.append(student_id)
    with get_db() as conn:
        cur = conn.cursor()
        if mobile_norm is not None:
            # Clean 409 instead of a raw UNIQUE violation; the except below closes
            # the race between this check and the UPDATE.
            cur.execute(
                "SELECT 1 FROM student WHERE mobile_normalized = %s AND id <> %s",
                (mobile_norm, student_id),
            )
            if cur.fetchone():
                raise HTTPException(status_code=409, detail="A student with this mobile number already exists")
        try:
            cur.execute(f"UPDATE student SET {', '.join(fields)} WHERE id = %s RETURNING id", values)
        except psycopg.errors.UniqueViolation:
            raise HTTPException(status_code=409, detail="A student with this mobile number already exists")
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Student not found")
        _audit(cur, current_emp['id'], 'edit', 'student',
               {"student_id": student_id, "fields": [f.split(' =')[0] for f in fields if '=' in f]})
    return {"status": "updated"}


@app.delete("/api/students/{student_id}")
async def delete_student(student_id: str, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT first_name, middle_name, last_name, mobile FROM student WHERE id = %s", (student_id,))
        s = cur.fetchone()
        if not s:
            raise HTTPException(status_code=404, detail="Student not found")
        student_name = " ".join(x for x in [s[0], s[1], s[2]] if x)
        mobile = s[3]

        cur.execute("SELECT COUNT(*), COALESCE(ARRAY_AGG(r2_key), '{}') FROM student_document WHERE student_id = %s", (student_id,))
        doc_count, db_keys = cur.fetchone()

        # 1) Delete ALL R2 objects FIRST. Union of DB keys + anything under the prefix (catch strays).
        prefix = f"students/{student_id}/"
        try:
            keys = set(db_keys) | set(r2_storage.list_keys(prefix))
            for k in keys:
                r2_storage.delete_object(k)
            # 2) Verify nothing remains before we touch the DB — no orphaned objects.
            remaining = r2_storage.list_keys(prefix)
        except Exception as e:
            # Abort: DB rows untouched, so nothing is orphaned; objects still referenced.
            raise HTTPException(status_code=502, detail=f"R2 delete failed, aborted; no rows removed: {e}")
        if remaining:
            raise HTTPException(status_code=502, detail=f"R2 objects still present under {prefix}; aborted")

        # 3) Now the DB rows: documents, then the student.
        cur.execute("DELETE FROM student_document WHERE student_id = %s", (student_id,))
        cur.execute("DELETE FROM student WHERE id = %s", (student_id,))
        # 4) The row disappears; the deletion record must not.
        _audit(cur, current_emp['id'], 'delete', 'student',
               {"student_id": student_id, "name": student_name, "mobile": mobile,
                "documents_removed": doc_count})
    return {"status": "deleted", "documents_removed": doc_count}


@app.post("/api/students/{student_id}/documents")
async def upload_student_document(
    student_id: str,
    doc_type: str = Form(...),
    file: UploadFile = File(...),
    current_emp = Depends(get_current_employee),
):
    _require_students_access(current_emp)
    if doc_type not in STUDENT_DOC_TYPES:
        raise HTTPException(status_code=400, detail="Invalid doc_type")
    raw = await file.read()
    out_bytes, mime, ext = _process_image(raw)  # validates content + converts HEIC->JPEG
    key = r2_storage.build_key(student_id, doc_type, ext)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM student WHERE id = %s", (student_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Student not found")
        # Replace: remove any existing file of this doc_type (delete old R2 object first)
        cur.execute("SELECT id, r2_key FROM student_document WHERE student_id = %s AND doc_type = %s",
                    (student_id, doc_type))
        old = cur.fetchone()
        r2_storage.upload_bytes(key, out_bytes, mime)
        if old:
            try:
                r2_storage.delete_object(old[1])
            except Exception:
                pass
            cur.execute("DELETE FROM student_document WHERE id = %s", (old[0],))
        cur.execute("""
            INSERT INTO student_document (student_id, doc_type, r2_key, original_filename,
                                          mime_type, size_bytes, uploaded_by)
            VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id
        """, (student_id, doc_type, key, file.filename, mime, len(out_bytes), current_emp['id']))
        doc_id = cur.fetchone()[0]
        _audit(cur, current_emp['id'], 'upload_document', 'student_document',
               {"student_id": student_id, "doc_type": doc_type, "replaced": bool(old)})
    return {"status": "uploaded", "id": str(doc_id), "doc_type": doc_type}


@app.get("/api/students/{student_id}/documents/{doc_id}/url")
async def get_student_document_url(student_id: str, doc_id: str, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT r2_key, doc_type FROM student_document WHERE id = %s AND student_id = %s",
                    (doc_id, student_id))
        r = cur.fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="Document not found")
        url = r2_storage.presigned_get(r[0], expires=300)  # <= 5 min
        _audit(cur, current_emp['id'], 'view_document', 'student_document',
               {"student_id": student_id, "doc_id": doc_id, "doc_type": r[1]})
    return {"url": url, "expires_in": 300}


@app.delete("/api/students/{student_id}/documents/{doc_id}")
async def delete_student_document(student_id: str, doc_id: str, current_emp = Depends(get_current_employee)):
    _require_students_access(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT r2_key, doc_type FROM student_document WHERE id = %s AND student_id = %s",
                    (doc_id, student_id))
        r = cur.fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="Document not found")
        try:
            r2_storage.delete_object(r[0])
        except Exception:
            pass
        cur.execute("DELETE FROM student_document WHERE id = %s", (doc_id,))
        _audit(cur, current_emp['id'], 'delete_document', 'student_document',
               {"student_id": student_id, "doc_id": doc_id, "doc_type": r[1]})
    return {"status": "deleted"}


# ------------------------- STUDENT SELF-SERVICE PORTAL ---------------------
# Every endpoint below is scoped to the calling student's own id (from the JWT).
# A student can never name another student's id, so cross-student access is impossible.

# Fields a student may edit on their own profile. Everything else is institutional
# and off-limits (course, admission_date, computer_number, mobile, login_*, lead_id).
_STUDENT_SELF_EDITABLE = {'guardian_name', 'emergency_contact', 'address'}


@app.get("/api/student/me")
async def student_me(current_student = Depends(get_current_student)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, first_name, middle_name, last_name, guardian_name, mobile,
                   emergency_contact, address, course, admission_date, computer_number,
                   created_at, last_login_at
            FROM student WHERE id = %s
        """, (current_student['id'],))
        r = cur.fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="Student not found")
        return {
            "id": str(r[0]), "first_name": r[1], "middle_name": r[2], "last_name": r[3],
            "guardian_name": r[4], "mobile": r[5], "emergency_contact": r[6], "address": r[7],
            "course": r[8], "admission_date": r[9].isoformat() if r[9] else None,
            "computer_number": r[10],
            "created_at": r[11].isoformat() if r[11] else None,
            "last_login_at": r[12].isoformat() if r[12] else None,
        }


@app.patch("/api/student/me")
async def student_update_me(data: dict, current_student = Depends(get_current_student)):
    # student table has no email column; accept-but-ignore for forward compatibility.
    data.pop('email', None)
    # Reject any attempt to touch an institutional / security field with 403.
    forbidden = set(data.keys()) - _STUDENT_SELF_EDITABLE
    if forbidden:
        raise HTTPException(
            status_code=403,
            detail=f"You may not edit: {', '.join(sorted(forbidden))}",
        )
    fields, values = [], []
    for k in _STUDENT_SELF_EDITABLE:
        if k in data:
            val = data[k]
            if k == 'emergency_contact' and val:
                val = normalize_phone(val)  # stored E.164, consistent with create_student
            fields.append(f"{k} = %s")
            values.append(val)
    if not fields:
        raise HTTPException(status_code=400, detail="No editable fields provided")
    fields.append("updated_at = NOW()")
    values.append(current_student['id'])
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(f"UPDATE student SET {', '.join(fields)} WHERE id = %s RETURNING id", values)
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Student not found")
    return {"status": "updated"}


@app.get("/api/student/me/documents")
async def student_my_documents(current_student = Depends(get_current_student)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, doc_type, original_filename, mime_type, size_bytes, uploaded_at
            FROM student_document WHERE student_id = %s ORDER BY uploaded_at DESC
        """, (current_student['id'],))
        docs = {}
        for d in cur.fetchall():
            docs[d[1]] = {
                "id": str(d[0]), "doc_type": d[1], "original_filename": d[2],
                "mime_type": d[3], "size_bytes": d[4],
                "uploaded_at": d[5].isoformat() if d[5] else None,
            }
    return {"doc_types": STUDENT_DOC_TYPES, "documents": docs}


@app.get("/api/student/me/documents/{doc_id}/url")
async def student_my_document_url(doc_id: str, current_student = Depends(get_current_student)):
    with get_db() as conn:
        cur = conn.cursor()
        # Scoped to the caller's own student_id: a student can only ever read their own r2_key.
        cur.execute(
            "SELECT r2_key FROM student_document WHERE id = %s AND student_id = %s",
            (doc_id, current_student['id'])
        )
        r = cur.fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="Document not found")
        url = r2_storage.presigned_get(r[0], expires=300)  # <= 5 min, same as staff flow
    return {"url": url, "expires_in": 300}


@app.post("/api/student/me/documents")
async def student_upload_my_document(
    doc_type: str = Form(...),
    file: UploadFile = File(...),
    current_student = Depends(get_current_student),
):
    if doc_type not in STUDENT_DOC_TYPES:
        raise HTTPException(status_code=400, detail="Invalid doc_type")
    student_id = current_student['id']
    raw = await file.read()
    out_bytes, mime, ext = _process_image(raw)  # same file-type/size limits as staff upload
    key = r2_storage.build_key(student_id, doc_type, ext)
    with get_db() as conn:
        cur = conn.cursor()
        # Replace an existing file of this doc_type (delete old R2 object first).
        cur.execute("SELECT id, r2_key FROM student_document WHERE student_id = %s AND doc_type = %s",
                    (student_id, doc_type))
        old = cur.fetchone()
        r2_storage.upload_bytes(key, out_bytes, mime)
        if old:
            try:
                r2_storage.delete_object(old[1])
            except Exception:
                pass
            cur.execute("DELETE FROM student_document WHERE id = %s", (old[0],))
        # uploaded_by references employee(id); a student is not an employee -> NULL.
        cur.execute("""
            INSERT INTO student_document (student_id, doc_type, r2_key, original_filename,
                                          mime_type, size_bytes, uploaded_by)
            VALUES (%s, %s, %s, %s, %s, %s, NULL) RETURNING id
        """, (student_id, doc_type, key, file.filename, mime, len(out_bytes)))
        doc_id = cur.fetchone()[0]
        _audit(cur, None, 'upload_document', 'student_document',
               {"student_id": student_id, "doc_type": doc_type, "by": "student", "replaced": bool(old)})
    return {"status": "uploaded", "id": str(doc_id), "doc_type": doc_type}


@app.post("/api/students/{student_id}/set-pin")
async def set_student_pin(student_id: str, data: dict, current_emp = Depends(get_current_employee)):
    """Admin-only: set/reset a student's login PIN and/or toggle login_enabled."""
    if current_emp['department'] != 'Admin':
        raise HTTPException(status_code=403, detail="Only the Admin department can manage student PINs")

    pin = data.get('pin')
    login_enabled = data.get('login_enabled')
    if pin is None and login_enabled is None:
        raise HTTPException(status_code=400, detail="Provide a pin and/or login_enabled")

    fields, values = [], []
    if pin is not None:
        pin = str(pin).strip()
        if not re.fullmatch(r'\d{4}', pin):
            raise HTTPException(status_code=400, detail="PIN must be exactly 4 digits")
        fields.append("login_pin_hash = %s")
        values.append(hash_password(pin))  # bcrypt, never plaintext
    if login_enabled is not None:
        fields.append("login_enabled = %s")
        values.append(bool(login_enabled))
    values.append(student_id)

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(f"UPDATE student SET {', '.join(fields)} WHERE id = %s RETURNING id", values)
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Student not found")
        _audit(cur, current_emp['id'], 'set_pin', 'student',
               {"student_id": student_id, "pin_changed": pin is not None,
                "login_enabled": login_enabled})
    return {"status": "updated"}


# ---------------------------------------------------------------------------
# Birthdays
# ---------------------------------------------------------------------------

@app.get("/api/birthdays/today")
def birthdays_today(current_emp = Depends(get_current_employee)):  # sync → threadpool
    """Everyone (employees + students) whose birthday falls on today's IST date.

    Matched by MONTH and DAY only — the year in date_of_birth is the birth year and
    would never equal today's. Deliberately open to every authenticated CRM user
    (employee sessions included) so the popup works on any tab they can reach;
    get_current_employee already rejects student tokens, which matters here because
    the response carries other people's names.
    """
    today = datetime.now(_IST).date()
    # A 29 Feb birthday has no date to land on in a common year: show it on 28 Feb.
    include_feb29 = (today.month, today.day) == (2, 28) and not calendar.isleap(today.year)

    # Same predicate for both tables; matching on the two EXTRACTs keeps it a plain
    # comparison per row (no per-row date construction) and the tables are small.
    day_match = """
        date_of_birth IS NOT NULL
        AND (
            (EXTRACT(MONTH FROM date_of_birth) = %s AND EXTRACT(DAY FROM date_of_birth) = %s)
            OR (%s AND EXTRACT(MONTH FROM date_of_birth) = 2
                   AND EXTRACT(DAY FROM date_of_birth) = 29)
        )
    """
    params = (today.month, today.day, include_feb29)

    people = []
    with get_db() as conn:
        cur = conn.cursor()
        # active = true excludes deleted rows, status excludes people who have left —
        # both conventions are already used by /api/employees and the directory UI.
        cur.execute(f"""
            SELECT id, name, job_role, department
            FROM employee
            WHERE active = true
              AND COALESCE(status, 'active') <> 'non-active'
              AND {day_match}
            ORDER BY name
        """, params)
        for r in cur.fetchall():
            people.append({
                "id": str(r[0]), "name": r[1], "type": "employee",
                "job_role": r[2], "department": r[3],
            })

        # Students are hard-deleted (no active flag), so presence in the table is enough.
        cur.execute(f"""
            SELECT id, first_name, middle_name, last_name, course
            FROM student
            WHERE {day_match}
            ORDER BY first_name, last_name
        """, params)
        for r in cur.fetchall():
            people.append({
                "id": str(r[0]),
                "name": " ".join(x for x in [r[1], r[2], r[3]] if x),
                "type": "student", "course": r[4],
            })
    return people


# ---------------------------------------------------------------------------
# CCTV attendance (synced from the camera system running on the Mac Mini)
# ---------------------------------------------------------------------------

@app.post("/api/attendance/ingest")
async def attendance_ingest(data: dict, authorization: str = Header(default="")):
    """Receives entry/exit updates from the CCTV attendance system.

    Secured by a shared secret: the caller must send
    'Authorization: Bearer <ATTENDANCE_INGEST_TOKEN>'.
    """
    token = os.getenv("ATTENDANCE_INGEST_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503,
                            detail="ATTENDANCE_INGEST_TOKEN not configured on the CRM server")
    if authorization != f"Bearer {token}":
        raise HTTPException(status_code=401, detail="Invalid attendance token")

    required = ("person_id", "name", "date")
    if any(not data.get(k) for k in required):
        raise HTTPException(status_code=422, detail=f"Fields required: {required}")

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO cctv_attendance
                (source_person_id, person_name, person_role, crm_id, date,
                 entry_time, exit_time, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
            ON CONFLICT (source_person_id, date) DO UPDATE SET
                person_name = EXCLUDED.person_name,
                person_role = EXCLUDED.person_role,
                crm_id      = EXCLUDED.crm_id,
                entry_time  = EXCLUDED.entry_time,
                exit_time   = EXCLUDED.exit_time,
                updated_at  = NOW()
        """, (str(data["person_id"]), data["name"], data.get("role"),
              data.get("crm_id"), data["date"],
              data.get("entry_time"), data.get("exit_time")))
    return {"status": "ok"}


@app.get("/api/attendance")
async def attendance_list(date: str = None, current_emp = Depends(get_current_employee)):
    """Daily attendance from the CCTV system. Admin department only."""
    if current_emp.get("department") != "Admin":
        raise HTTPException(status_code=403,
                            detail="Only the Admin department can view CCTV attendance")
    target = date or datetime.now().strftime("%Y-%m-%d")
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, source_person_id, person_name, person_role, crm_id,
                   date, entry_time, exit_time, updated_at,
                   day_status, hours_worked, status_override, override_at
            FROM cctv_attendance
            WHERE date = %s
            ORDER BY entry_time NULLS LAST
        """, (target,))
        rows = [{
            "record_id": r[0],
            "person_id": r[1], "name": r[2], "role": r[3], "crm_id": r[4],
            "date": r[5].isoformat() if r[5] else None,
            "entry_time": r[6], "exit_time": r[7],
            "updated_at": r[8].isoformat() if r[8] else None,
            "day_status": r[9],
            "hours_worked": float(r[10]) if r[10] is not None else None,
            "status_override": r[11],
            "effective_status": _report_status(r[6], r[7], r[9], r[11]),
            "override_at": r[12].isoformat() if r[12] else None,
        } for r in cur.fetchall()]
    return {"date": target, "rows": rows,
            "present": len(rows),
            "inside": sum(1 for r in rows if not r["exit_time"]),
            "needs_review": sum(1 for r in rows
                                if r["effective_status"] in ATTENDANCE_REVIEW_STATUSES)}


# Admin may force a day's status to one of these (overrides the computed day_status).
ATTENDANCE_OVERRIDE_STATUSES = ('full_day', 'half_day', 'absent', 'leave')


@app.patch("/api/attendance/{record_id}")
async def attendance_override(record_id: int, data: dict,
                              current_emp = Depends(get_current_employee)):
    """Admin correction for a single attendance day (mistakes happen).

    Body may contain any of:
      - status_override: 'full_day'|'half_day'|'absent'|'leave', or null to clear
      - entry_time / exit_time: 'HH:MM:SS' corrections (or null to clear)
    Correcting the times recomputes day_status/hours_worked. Every change stamps
    override_by/override_at and writes an audit_log row. Reports prefer
    status_override over the computed day_status.
    """
    _require_attendance_admin(current_emp)

    def _valid_time(v):
        return v in (None, "") or _parse_hms(v) is not None

    fields, values, changed = [], [], {}

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT entry_time, exit_time FROM cctv_attendance WHERE id = %s",
            (record_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        new_entry, new_exit = row[0], row[1]

        if "entry_time" in data:
            if not _valid_time(data["entry_time"]):
                raise HTTPException(status_code=422, detail="entry_time must be HH:MM:SS")
            new_entry = data["entry_time"] or None
            fields.append("entry_time = %s"); values.append(new_entry)
            changed["entry_time"] = new_entry
        if "exit_time" in data:
            if not _valid_time(data["exit_time"]):
                raise HTTPException(status_code=422, detail="exit_time must be HH:MM:SS")
            new_exit = data["exit_time"] or None
            fields.append("exit_time = %s"); values.append(new_exit)
            changed["exit_time"] = new_exit

        # A time correction re-derives the computed status/hours.
        if "entry_time" in data or "exit_time" in data:
            day_status, hours_worked = _compute_day_status(new_entry, new_exit)
            fields.append("day_status = %s"); values.append(day_status)
            fields.append("hours_worked = %s"); values.append(hours_worked)

        if "status_override" in data:
            ov = data["status_override"] or None
            if ov is not None and ov not in ATTENDANCE_OVERRIDE_STATUSES:
                raise HTTPException(
                    status_code=422,
                    detail=f"status_override must be one of {ATTENDANCE_OVERRIDE_STATUSES} or null")
            fields.append("status_override = %s"); values.append(ov)
            changed["status_override"] = ov

        if not fields:
            raise HTTPException(status_code=400, detail="Nothing to update")

        fields.append("override_by = %s"); values.append(current_emp["id"])
        fields.append("override_at = NOW()")
        fields.append("updated_at = NOW()")
        values.append(record_id)
        cur.execute(
            f"UPDATE cctv_attendance SET {', '.join(fields)} WHERE id = %s", values)

        _audit(cur, current_emp["id"], "attendance_override", "cctv_attendance",
               {"record_id": record_id, **changed})

    return {"status": "updated", "record_id": record_id, "changes": changed}


# ---------------------------------------------------------------------------
# Hikvision biometric terminal (DS-K1T320EFWX) attendance webhook
#
# The access terminal pushes events to a plain HTTP listener. It CANNOT send
# custom headers, so this endpoint authenticates via a ?token= query param
# (compared against the same ATTENDANCE_INGEST_TOKEN as /api/attendance/ingest).
# It writes to the shared cctv_attendance table, namespacing device people with
# a "hik:" prefix so they never collide with CCTV-sourced people.
#
# It always returns 200 quickly (except for auth) so the device does not
# retry-storm on malformed/irrelevant events.
# ---------------------------------------------------------------------------

_IST = ZoneInfo("Asia/Kolkata")


async def _parse_hikvision_body(request: Request):
    """Return the pushed JSON dict, or None if it cannot be parsed.

    Hikvision sends application/json, or multipart/form-data when a face image
    is attached (the JSON then lives in a part usually named 'event_log').
    Never raises; logs and returns None on failure (incl. XML-ish payloads).
    """
    ctype = request.headers.get("content-type", "")
    try:
        if "application/json" in ctype:
            return await request.json()

        if "form-data" in ctype or "multipart" in ctype:
            form = await request.form()
            raw = form.get("event_log")
            if raw is None:
                # Fall back to the first part that looks like JSON.
                for value in form.values():
                    if isinstance(value, str) and value.strip().startswith("{"):
                        raw = value
                        break
            if raw is None:
                logging.warning("Hikvision: multipart push with no JSON part; keys=%s",
                                list(form.keys()))
                return None
            if hasattr(raw, "read"):  # UploadFile part
                raw = (await raw.read()).decode("utf-8", "replace")
            return json.loads(raw)

        # Unknown / XML-ish content type: try JSON, otherwise give up gracefully.
        text = (await request.body()).decode("utf-8", "replace").strip()
        if text.startswith("{"):
            return json.loads(text)
        logging.warning("Hikvision: unsupported body (ctype=%r, prefix=%r); ignoring",
                        ctype, text[:80])
        return None
    except Exception as exc:
        logging.warning("Hikvision: failed to parse body (ctype=%r): %s", ctype, exc)
        return None


def _parse_hikvision_dt(raw: str):
    """Parse a Hikvision ISO dateTime into an Asia/Kolkata-aware datetime.

    Handles trailing 'Z' and offsets like +05:30. If no offset is present the
    device time is assumed to already be institute-local (IST). Returns None on
    failure so the caller can fall back to 'now'.
    """
    if not raw:
        return None
    try:
        d = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=_IST)
        return d.astimezone(_IST)
    except Exception:
        return None


@app.post("/api/attendance/hikvision")
async def attendance_hikvision(request: Request, token: str = ""):
    """Attendance webhook for a Hikvision DS-K1T320EFWX access terminal.

    Auth is via ?token= (device can't send headers). Accepts JSON or
    multipart/form-data. Always returns 200 quickly (except auth failures) so
    the device does not retry-storm.
    """
    # --- auth (query param, constant-time compare) ---
    expected = os.getenv("ATTENDANCE_INGEST_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503,
                            detail="ATTENDANCE_INGEST_TOKEN not configured on the CRM server")
    if not secrets.compare_digest(token or "", expected):
        raise HTTPException(status_code=401, detail="Invalid attendance token")

    try:
        payload = await _parse_hikvision_body(request)
        if not isinstance(payload, dict):
            return {"status": "ignored", "reason": "unparseable body"}

        event = payload.get("AccessControllerEvent")
        if not isinstance(event, dict):
            event = {}

        # FILTER: only successful authentication events (majorEventType 5).
        major = event.get("majorEventType")
        if str(major) != "5":
            return {"status": "ignored", "reason": f"majorEventType={major}"}

        emp_no = str(event.get("employeeNoString") or "").strip()
        if not emp_no:
            # Non-person events (door/tamper/etc.) carry no employee id.
            logging.info("Hikvision: auth event without employeeNoString "
                         "(subEventType=%s); ignoring", event.get("subEventType"))
            return {"status": "ignored", "reason": "no employeeNoString"}

        name = str(event.get("name") or "").strip()
        att_status = str(event.get("attendanceStatus") or "").strip().lower()

        # dateTime may be nested in the event or at the top level; may carry an offset.
        dt = _parse_hikvision_dt(event.get("dateTime") or payload.get("dateTime") or "")
        if dt is None:
            dt = datetime.now(_IST)
        date_str = dt.strftime("%Y-%m-%d")
        time_str = dt.strftime("%H:%M:%S")

        # --- staleness guard (before any DB write) ---
        # The terminal keeps re-pushing stored records dated years ago. Drop any
        # event older than HIKVISION_MAX_EVENT_AGE_DAYS, or more than 1 day in the
        # future (clock skew). Still ack 200 so it stops retry-storming.
        today_ist = datetime.now(_IST).date()
        age_days = (today_ist - dt.date()).days
        if age_days > HIKVISION_MAX_EVENT_AGE_DAYS or age_days < -1:
            logging.info("Hikvision: stale event emp=%s date=%s (age %d days); ignoring",
                         emp_no, date_str, age_days)
            return {"status": "ignored-stale", "person_id": f"hik:{emp_no}",
                    "date": date_str}

        source_id = f"hik:{emp_no}"

        with get_db() as conn:
            cur = conn.cursor()

            # --- duplicate suppression ---
            # If this exact (person, date, time) punch was already recorded (as an
            # entry or an exit), skip re-running the upsert.
            cur.execute("""
                SELECT 1 FROM cctv_attendance
                WHERE source_person_id = %s AND date = %s
                  AND (entry_time = %s OR exit_time = %s)
            """, (source_id, date_str, time_str, time_str))
            if cur.fetchone():
                logging.info("Hikvision: duplicate punch emp=%s date=%s time=%s; skipping",
                             emp_no, date_str, time_str)
                return {"status": "ignored-duplicate", "person_id": source_id,
                        "date": date_str, "time": time_str}

            # --- debounce accidental re-taps ---
            # Load the day's existing entry/exit once. A punch landing within
            # ATTENDANCE_MIN_PUNCH_GAP_MINUTES of an already-recorded entry OR exit
            # is a double-tap: ignore it entirely so it can neither flip a fresh
            # entry into an exit nor keep overwriting the exit. Never mutate the row.
            cur.execute("""
                SELECT entry_time, exit_time FROM cctv_attendance
                WHERE source_person_id = %s AND date = %s
            """, (source_id, date_str))
            existing_row = cur.fetchone()
            punch_secs = _parse_hms(time_str)
            if existing_row and punch_secs is not None:
                gap_secs = ATTENDANCE_MIN_PUNCH_GAP_MINUTES * 60
                prev_entry = _parse_hms(existing_row[0])
                prev_exit = _parse_hms(existing_row[1])
                if ((prev_entry is not None and abs(punch_secs - prev_entry) < gap_secs) or
                        (prev_exit is not None and abs(punch_secs - prev_exit) < gap_secs)):
                    logging.info("Hikvision: re-tap ignored emp=%s date=%s time=%s "
                                 "(within %d min of a recorded punch)",
                                 emp_no, date_str, time_str,
                                 ATTENDANCE_MIN_PUNCH_GAP_MINUTES)
                    return {"status": "ignored-retap", "person_id": source_id,
                            "date": date_str, "time": time_str}

            # --- resolve identity from the device->CRM mapping ---
            # If Admin has mapped this raw device id, use the CRM person's name,
            # role and id. If not, keep the device-supplied name and mark the row
            # 'unmapped' so students are never silently mislabelled as employees.
            cur.execute("""
                SELECT display_name, role, crm_person_id
                FROM device_person_map WHERE device_person_id = %s
            """, (emp_no,))
            mapping = cur.fetchone()
            if mapping:
                person_name = mapping[0]
                person_role = mapping[1]
                crm_id = str(mapping[2]) if mapping[2] else None
            else:
                person_name = name
                person_role = 'unmapped'
                crm_id = None

            # --- entry/exit decision ---
            if att_status == "checkin":
                is_entry = True
            elif att_status == "checkout":
                is_entry = False
            else:
                # undefined/missing: first punch of the day = entry; any later
                # punch updates exit_time (last punch of the day becomes exit).
                is_entry = existing_row is None

            if is_entry:
                cur.execute("""
                    INSERT INTO cctv_attendance
                        (source_person_id, person_name, person_role, crm_id, date,
                         entry_time, updated_at)
                    VALUES (%s, %s, %s, %s, %s, %s, NOW())
                    ON CONFLICT (source_person_id, date) DO UPDATE SET
                        person_name = EXCLUDED.person_name,
                        person_role = EXCLUDED.person_role,
                        crm_id      = EXCLUDED.crm_id,
                        entry_time  = COALESCE(cctv_attendance.entry_time,
                                               EXCLUDED.entry_time),
                        updated_at  = NOW()
                """, (source_id, person_name, person_role, crm_id,
                      date_str, time_str))
            else:
                cur.execute("""
                    INSERT INTO cctv_attendance
                        (source_person_id, person_name, person_role, crm_id, date,
                         exit_time, updated_at)
                    VALUES (%s, %s, %s, %s, %s, %s, NOW())
                    ON CONFLICT (source_person_id, date) DO UPDATE SET
                        person_name = EXCLUDED.person_name,
                        person_role = EXCLUDED.person_role,
                        crm_id      = EXCLUDED.crm_id,
                        exit_time   = EXCLUDED.exit_time,
                        updated_at  = NOW()
                """, (source_id, person_name, person_role, crm_id,
                      date_str, time_str))

            # --- recompute day_status + hours from the row as it now stands ---
            # (entry only -> 'missing_exit'; entry+exit -> full/half/short_day).
            # status_override, if an Admin set one, is left untouched.
            cur.execute("""
                SELECT entry_time, exit_time FROM cctv_attendance
                WHERE source_person_id = %s AND date = %s
            """, (source_id, date_str))
            final_row = cur.fetchone()
            if final_row:
                day_status, hours_worked = _compute_day_status(final_row[0], final_row[1])
                cur.execute("""
                    UPDATE cctv_attendance SET day_status = %s, hours_worked = %s
                    WHERE source_person_id = %s AND date = %s
                """, (day_status, hours_worked, source_id, date_str))

        logging.info("Hikvision attendance: emp=%s name=%r date=%s time=%s -> %s",
                     emp_no, name, date_str, time_str,
                     "entry" if is_entry else "exit")
        return {"status": "ok", "person_id": source_id, "date": date_str,
                "time": time_str, "type": "entry" if is_entry else "exit"}
    except Exception as exc:
        # Never surface a 500 to the device; log and ack so it stops retrying.
        logging.exception("Hikvision: error processing push: %s", exc)
        return {"status": "error-ignored"}


# ---------------------------------------------------------------------------
# Device-person mapping, monthly view, and archived summaries (Admin only).
# ---------------------------------------------------------------------------

def _require_attendance_admin(current_emp):
    """Same fail-closed gate as the daily attendance view."""
    if current_emp.get("department") != "Admin":
        raise HTTPException(status_code=403,
                            detail="Only the Admin department can manage CCTV attendance")


def _strip_hik(source_person_id: str) -> str:
    """Return the raw device id (drop the 'hik:' namespace prefix if present)."""
    return source_person_id[4:] if source_person_id.startswith("hik:") else source_person_id


@app.get("/api/attendance/device-people")
async def attendance_device_people(current_emp = Depends(get_current_employee)):
    """Every distinct device person seen in attendance, with its mapping (if any).

    Unmapped people are listed first so Admin can bind them quickly.
    """
    _require_attendance_admin(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT seen.source_person_id, seen.device_name, seen.last_seen,
                   m.person_type, m.crm_person_id, m.display_name, m.role
            FROM (
                SELECT source_person_id,
                       (ARRAY_AGG(person_name ORDER BY date DESC))[1] AS device_name,
                       MAX(date) AS last_seen
                FROM cctv_attendance
                GROUP BY source_person_id
            ) seen
            LEFT JOIN device_person_map m
                ON m.device_person_id = regexp_replace(seen.source_person_id, '^hik:', '')
            ORDER BY (m.device_person_id IS NOT NULL), seen.last_seen DESC
        """)
        people = []
        for r in cur.fetchall():
            is_mapped = r[5] is not None
            people.append({
                "device_person_id": _strip_hik(r[0]),
                "source_person_id": r[0],
                "device_name": r[1],
                "last_seen": r[2].isoformat() if r[2] else None,
                "is_mapped": is_mapped,
                "mapping": {
                    "person_type": r[3],
                    "crm_person_id": str(r[4]) if r[4] else None,
                    "display_name": r[5],
                    "role": r[6],
                } if is_mapped else None,
            })
    return {"people": people,
            "unmapped": sum(1 for p in people if not p["is_mapped"])}


@app.post("/api/attendance/device-people/{device_person_id}/map")
async def attendance_map_device_person(device_person_id: str, data: dict,
                                       current_emp = Depends(get_current_employee)):
    """Bind a raw device id to a CRM person and backfill existing rows.

    Body: {person_type, crm_person_id, display_name, role}.
    """
    _require_attendance_admin(current_emp)
    person_type = (data.get("person_type") or "").strip()
    role = (data.get("role") or "").strip()
    display_name = (data.get("display_name") or "").strip()
    crm_person_id = data.get("crm_person_id")

    if person_type not in ("employee", "student"):
        raise HTTPException(status_code=422, detail="person_type must be 'employee' or 'student'")
    if role not in ("employee", "student"):
        raise HTTPException(status_code=422, detail="role must be 'employee' or 'student'")
    if not display_name:
        raise HTTPException(status_code=422, detail="display_name is required")

    with get_db() as conn:
        cur = conn.cursor()
        # Validate the CRM person exists in the referenced table.
        if crm_person_id:
            table = "employee" if person_type == "employee" else "student"
            cur.execute(f"SELECT 1 FROM {table} WHERE id = %s", (crm_person_id,))
            if cur.fetchone() is None:
                raise HTTPException(status_code=404,
                                    detail=f"No {person_type} found with id {crm_person_id}")

        cur.execute("""
            INSERT INTO device_person_map
                (device_person_id, person_type, crm_person_id, display_name, role)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (device_person_id) DO UPDATE SET
                person_type   = EXCLUDED.person_type,
                crm_person_id = EXCLUDED.crm_person_id,
                display_name  = EXCLUDED.display_name,
                role          = EXCLUDED.role
        """, (device_person_id, person_type, crm_person_id, display_name, role))

        # Backfill: correct every past punch for this device id, prefixed or not.
        crm_id = str(crm_person_id) if crm_person_id else None
        cur.execute("""
            UPDATE cctv_attendance
            SET person_name = %s, person_role = %s, crm_id = %s, updated_at = NOW()
            WHERE source_person_id = %s OR source_person_id = %s
        """, (display_name, role, crm_id,
              device_person_id, f"hik:{device_person_id}"))
        backfilled = cur.rowcount

    return {"status": "mapped", "device_person_id": device_person_id,
            "backfilled_rows": backfilled}


@app.delete("/api/attendance/device-people/{device_person_id}/map")
async def attendance_unmap_device_person(device_person_id: str,
                                         current_emp = Depends(get_current_employee)):
    """Remove a device->CRM mapping. Existing attendance rows are left as-is."""
    _require_attendance_admin(current_emp)
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM device_person_map WHERE device_person_id = %s",
                    (device_person_id,))
        removed = cur.rowcount
    if removed == 0:
        raise HTTPException(status_code=404, detail="No mapping for that device person")
    return {"status": "unmapped", "device_person_id": device_person_id}


@app.get("/api/attendance/monthly")
async def attendance_monthly(month: str = None, current_emp = Depends(get_current_employee)):
    """Per-person attendance for a whole month (YYYY-MM). Admin only."""
    _require_attendance_admin(current_emp)
    target = month or datetime.now(_IST).strftime("%Y-%m")
    try:
        start = datetime.strptime(target + "-01", "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=422, detail="month must be YYYY-MM")
    nm = start.month % 12 + 1
    ny = start.year + (1 if start.month == 12 else 0)
    end = date(ny, nm, 1)

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT source_person_id, person_name, person_role, crm_id,
                   date, entry_time, exit_time, day_status, hours_worked, status_override
            FROM cctv_attendance
            WHERE date >= %s AND date < %s
            ORDER BY person_name, date
        """, (start, end))
        rows = cur.fetchall()

    people = {}
    for r in rows:
        pid = r[0]
        p = people.get(pid)
        if p is None:
            p = people[pid] = {
                "source_person_id": pid,
                "device_person_id": _strip_hik(pid),
                "name": r[1], "role": r[2], "crm_id": r[3],
                "days_present": 0, "first_seen": None, "last_seen": None,
                "full_days": 0, "half_days": 0, "days_needing_review": 0,
                "days": [],
            }
        d = r[4].isoformat()
        status = _report_status(r[5], r[6], r[7], r[9])
        p["days"].append({
            "date": d, "entry_time": r[5], "exit_time": r[6],
            "status": status,
            "hours_worked": float(r[8]) if r[8] is not None else None,
        })
        p["days_present"] += 1
        if status == 'full_day':
            p["full_days"] += 1
        elif status == 'half_day':
            p["half_days"] += 1
        elif status in ATTENDANCE_REVIEW_STATUSES:
            p["days_needing_review"] += 1
        if p["first_seen"] is None or d < p["first_seen"]:
            p["first_seen"] = d
        if p["last_seen"] is None or d > p["last_seen"]:
            p["last_seen"] = d
        # keep the most recent name/role/crm_id
        p["name"], p["role"], p["crm_id"] = r[1], r[2], r[3]

    result = sorted(people.values(), key=lambda x: x["name"] or "")
    return {"month": target, "people": result, "person_count": len(result)}


@app.get("/api/attendance/summary")
async def attendance_summary(months: int = 12, current_emp = Depends(get_current_employee)):
    """Archived monthly summaries (survive the raw-row purge). Admin only."""
    _require_attendance_admin(current_emp)
    months = max(1, min(int(months or 12), 120))
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT month, source_person_id, person_name, person_role, crm_id,
                   days_present, first_date, last_date
            FROM attendance_monthly_summary
            WHERE month >= (date_trunc('month', CURRENT_DATE) - (%s || ' months')::interval)
            ORDER BY month DESC, person_name
        """, (months,))
        rows = [{
            "month": r[0].strftime("%Y-%m") if r[0] else None,
            "source_person_id": r[1],
            "device_person_id": _strip_hik(r[1]),
            "name": r[2], "role": r[3], "crm_id": r[4],
            "days_present": r[5],
            "first_date": r[6].isoformat() if r[6] else None,
            "last_date": r[7].isoformat() if r[7] else None,
        } for r in cur.fetchall()]
    return {"months": months, "rows": rows}


# ---------------------------------------------------------------------------
# Partner read-only API (server-to-server, first-party apps such as DGCA_prep).
#
# Secured by its own shared secret PARTNER_API_TOKEN — deliberately NOT the
# device's ATTENDANCE_INGEST_TOKEN, so leaking one never grants the other.
# Never called from a browser, so CORS is intentionally left untouched.
# ---------------------------------------------------------------------------

@app.get("/api/partner/attendance/by-mobile")
async def partner_attendance_by_mobile(mobile: str, month: str = None,
                                       authorization: str = Header(default="")):
    """One student's biometric attendance, looked up by mobile number.

    Caller must send 'Authorization: Bearer <PARTNER_API_TOKEN>'. Returns ONLY
    that student's own name/course plus their attendance rows — knowing one
    mobile must never expose any other student.
    """
    token = os.getenv("PARTNER_API_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503,
                            detail="PARTNER_API_TOKEN not configured on the CRM server")
    try:
        ok = secrets.compare_digest(authorization, f"Bearer {token}")
    except TypeError:
        # compare_digest rejects non-ASCII str: a malformed header is a 401, not a 500.
        ok = False
    if not ok:
        raise HTTPException(status_code=401, detail="Invalid partner token")

    # Accept any format ('+91 98765-43210', '098765 43210', ...): keep the last
    # 10 digits and run them through the same normalizer used on write.
    digits = re.sub(r'\D', '', mobile or "")
    if len(digits) < 10:
        raise HTTPException(status_code=422, detail="mobile must contain at least 10 digits")
    mobile_norm = normalize_phone(digits[-10:])

    target = month or datetime.now(_IST).strftime("%Y-%m")
    try:
        start = datetime.strptime(target + "-01", "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=422, detail="month must be YYYY-MM")
    nm = start.month % 12 + 1
    ny = start.year + (1 if start.month == 12 else 0)
    end = date(ny, nm, 1)

    def _row(r):
        return {
            "date": r[0].isoformat(),
            "entry_time": r[1],
            "exit_time": r[2],
            "status": _report_status(r[1], r[2], r[3], r[4]),
            "hours_worked": float(r[5]) if r[5] is not None else None,
        }

    with get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, first_name, last_name, course FROM student WHERE mobile_normalized = %s",
            (mobile_norm,))
        student = cur.fetchone()
        if not student:
            return {"linked": False, "device_mapped": False, "month": target,
                    "student": None, "days": [], "recent": []}
        student_id, first_name, last_name, course = student

        # Is a biometric device id actually bound to this student? Without this
        # the caller cannot tell "absent" from "Admin never mapped their face".
        cur.execute(
            "SELECT 1 FROM device_person_map WHERE crm_person_id = %s LIMIT 1",
            (student_id,))
        device_mapped = cur.fetchone() is not None

        cur.execute("""
            SELECT date, entry_time, exit_time, day_status, status_override, hours_worked
            FROM cctv_attendance
            WHERE crm_id = %s AND date >= %s AND date < %s
            ORDER BY date
        """, (str(student_id), start, end))
        days = [_row(r) for r in cur.fetchall()]

        cur.execute("""
            SELECT date, entry_time, exit_time, day_status, status_override, hours_worked
            FROM cctv_attendance
            WHERE crm_id = %s
            ORDER BY date DESC
            LIMIT 15
        """, (str(student_id),))
        recent = [_row(r) for r in cur.fetchall()]

    return {
        "linked": True,
        "device_mapped": device_mapped,
        "month": target,
        "student": {
            "id": str(student_id),
            "name": " ".join(x for x in [first_name, last_name] if x),
            "course": course,
        },
        "days": days,
        "recent": recent,
    }


def _attendance_retention_cutoff(today: date = None) -> date:
    """First day of (current month - ATTENDANCE_RETENTION_MONTHS). Rows strictly
    older than this cutoff are summarized then purged."""
    base = (today or datetime.now(_IST).date()).replace(day=1)
    m = base.month - ATTENDANCE_RETENTION_MONTHS
    y = base.year
    while m <= 0:
        m += 12
        y -= 1
    return date(y, m, 1)


def run_attendance_retention():
    """Aggregate then purge raw attendance older than the retention window.

    Summary upsert (step A) and delete (step C) run in ONE transaction so a
    failure can never delete rows without an archived summary.
    """
    # Monthly cron fires on every instance at the same minute; the 6-hour lease
    # lets exactly one of them run it.
    from job_lease import acquire_lease
    if not acquire_lease('attendance_retention', 6 * 3600):
        return None
    cutoff = _attendance_retention_cutoff()
    try:
        with get_db() as conn:
            cur = conn.cursor()
            # STEP A: roll every old month up into the summary (idempotent upsert).
            cur.execute("""
                INSERT INTO attendance_monthly_summary
                    (month, source_person_id, person_name, person_role, crm_id,
                     days_present, first_date, last_date)
                SELECT date_trunc('month', date)::date AS month,
                       source_person_id,
                       (ARRAY_AGG(person_name ORDER BY date DESC))[1],
                       (ARRAY_AGG(person_role ORDER BY date DESC))[1],
                       (ARRAY_AGG(crm_id ORDER BY date DESC))[1],
                       COUNT(DISTINCT date),
                       MIN(date), MAX(date)
                FROM cctv_attendance
                WHERE date < %s
                GROUP BY month, source_person_id
                ON CONFLICT (month, source_person_id) DO UPDATE SET
                    person_name  = EXCLUDED.person_name,
                    person_role  = EXCLUDED.person_role,
                    crm_id       = EXCLUDED.crm_id,
                    days_present = EXCLUDED.days_present,
                    first_date   = EXCLUDED.first_date,
                    last_date    = EXCLUDED.last_date
            """, (cutoff,))
            rows_summarized = cur.rowcount

            # STEP C: only now that summaries are written, purge the raw rows.
            cur.execute("DELETE FROM cctv_attendance WHERE date < %s", (cutoff,))
            rows_deleted = cur.rowcount
            # get_db() commits on clean exit; both statements land atomically.
        logging.info("Attendance retention: cutoff=%s summarized=%d deleted=%d",
                     cutoff.isoformat(), rows_summarized, rows_deleted)
        return {"cutoff": cutoff.isoformat(),
                "rows_summarized": rows_summarized, "rows_deleted": rows_deleted}
    except Exception as exc:
        logging.exception("Attendance retention failed (cutoff=%s): %s", cutoff, exc)
        raise


if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
