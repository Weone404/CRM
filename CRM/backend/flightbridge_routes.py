"""FlightBridge partnership module for the CRM (Admin only).

This router NEVER sends email. Human decisions are recorded here; the FlightBridge central
sending service (nikkk07/FlightBridge-AI) picks up approved tasks, runs the jurisdiction and
content gates, and is the only component that can transmit. Requires migration
037_flightbridge_schema.sql and 038_flightbridge_templates_inbound.sql; until they are applied every endpoint returns 503.
"""
import json
from datetime import datetime, timedelta, timezone
from typing import Optional

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from auth import get_current_employee
from database import get_db

router = APIRouter(prefix="/api/flightbridge", tags=["flightbridge"])

# Facts a human may attest to, with the maximum validity the FlightBridge rules accept (days).
HUMAN_FACTS = {
    "address_conspicuously_published": 90,
    "no_refusal_statement_near_address": 90,
    "message_relevant_to_business_role": 180,
    "recipient_is_corporate_subscriber": 365,
    "legitimate_interests_assessment_done": 365,
    "refusal_statement_present": 3650,
    "recipient_is_sole_trader_or_non_scottish_partnership": 3650,
}
DECISIONS = {"approve", "edit_approve", "reject", "more_research", "resolve", "reassign"}


def require_admin(current_emp=Depends(get_current_employee)):
    if current_emp.get("department") != "Admin":
        raise HTTPException(status_code=403, detail="FlightBridge requires Admin department")
    return current_emp


class _SchemaGuard:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type and issubclass(exc_type, psycopg.errors.UndefinedTable):
            raise HTTPException(status_code=503, detail="FlightBridge schema not installed (apply migrations 037 and 038)")
        return False


def _audit(cur, emp_id, action, entity, entity_id, payload):
    cur.execute(
        "INSERT INTO flightbridge.audit_log (actor_type, actor_id, action, entity, entity_id, payload) "
        "VALUES ('employee', %s, %s, %s, %s, %s)",
        (emp_id, action, entity, str(entity_id), json.dumps(payload, default=str)))


def _rows(cur):
    cols = [d.name for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


@router.get("/summary")
def summary(emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        out = {}
        for key, sql in {
            "organisations": "SELECT status, count(*) FROM flightbridge.organisation WHERE deleted_at IS NULL GROUP BY 1",
            "approvals": "SELECT status, count(*) FROM flightbridge.approval_task GROUP BY 1",
            "outbound": "SELECT status, count(*) FROM flightbridge.outbound_message GROUP BY 1",
        }.items():
            cur.execute(sql)
            out[key] = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute("SELECT key, value FROM flightbridge.system_setting WHERE key LIKE '%%kill_switch'")
        out["kill_switches"] = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute("SELECT count(*) FROM flightbridge.suppression")
        out["suppressions"] = cur.fetchone()[0]
    return out


@router.get("/approvals")
def list_approvals(status: str = "open", emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """SELECT a.id, a.status, a.risk, a.escalation_reason, a.created_at, a.assigned_to,
                      d.kind, d.subject, o.name AS org_name, o.country, c.email
                 FROM flightbridge.approval_task a
                 JOIN flightbridge.ai_draft d ON d.id = a.draft_id
                 JOIN flightbridge.organisation o ON o.id = d.org_id
                 JOIN flightbridge.contact c ON c.id = d.contact_id
                WHERE a.status = %s
                ORDER BY CASE a.risk WHEN 'RED' THEN 0 WHEN 'AMBER' THEN 1 ELSE 2 END, a.created_at
                LIMIT 200""", (status,))
        return _rows(cur)


@router.get("/approvals/{task_id}")
def approval_detail(task_id: str, emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """SELECT a.*, d.kind, d.intent, d.summary, d.extracted_questions, d.subject AS draft_subject,
                      d.body_text AS draft_body, d.evidence, d.generator, d.thread_id, d.inbound_message_id,
                      d.org_id, d.contact_id
                 FROM flightbridge.approval_task a JOIN flightbridge.ai_draft d ON d.id = a.draft_id
                WHERE a.id = %s""", (task_id,))
        rows = _rows(cur)
        if not rows:
            raise HTTPException(status_code=404, detail="Approval task not found")
        t = rows[0]
        cur.execute("SELECT id, name, country, city, website_domain, status, entity_type FROM flightbridge.organisation WHERE id=%s",
                    (t["org_id"],))
        t["organisation"] = (_rows(cur) or [None])[0]
        cur.execute("""SELECT authority_code, classification, approval_ref, status, source_url, checked_at, next_check_due
                         FROM flightbridge.regulatory_approval WHERE org_id=%s""", (t["org_id"],))
        t["regulatory"] = _rows(cur)
        cur.execute("""SELECT score, breakdown, missing, risks, recommended_action, confidence, computed_at
                         FROM flightbridge.qualification_result WHERE org_id=%s ORDER BY computed_at DESC LIMIT 1""",
                    (t["org_id"],))
        t["qualification"] = (_rows(cur) or [None])[0]
        cur.execute("SELECT id, email, is_role_address, role, source_url FROM flightbridge.contact WHERE id=%s",
                    (t["contact_id"],))
        t["contact"] = (_rows(cur) or [None])[0]
        cur.execute("""SELECT fact, method, source_url, excerpt, verified_at, expires_at
                         FROM flightbridge.contact_fact_evidence WHERE contact_id=%s ORDER BY verified_at DESC""",
                    (t["contact_id"],))
        t["contact_evidence"] = _rows(cur)
        t["thread"] = []
        if t["thread_id"]:
            cur.execute("""SELECT direction, from_address, subject, body_text, occurred_at
                             FROM flightbridge.email_message WHERE thread_id=%s ORDER BY occurred_at""", (t["thread_id"],))
            t["thread"] = _rows(cur)
        return t


class Decision(BaseModel):
    action: str
    subject: Optional[str] = Field(default=None, max_length=150)
    body: Optional[str] = Field(default=None, max_length=20000)
    note: Optional[str] = Field(default=None, max_length=2000)
    assign_to: Optional[str] = None


@router.post("/approvals/{task_id}/decision")
def decide(task_id: str, d: Decision, emp=Depends(require_admin)):
    if d.action not in DECISIONS:
        raise HTTPException(status_code=400, detail=f"action must be one of {sorted(DECISIONS)}")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT a.status, d.subject, d.body_text FROM flightbridge.approval_task a
                         JOIN flightbridge.ai_draft d ON d.id = a.draft_id WHERE a.id=%s FOR UPDATE OF a""", (task_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Approval task not found")
        status, draft_subject, draft_body = row
        if status != "open":
            raise HTTPException(status_code=409, detail=f"Task already decided ({status})")

        if d.action == "reassign":
            if not d.assign_to:
                raise HTTPException(status_code=400, detail="assign_to is required")
            cur.execute("UPDATE flightbridge.approval_task SET assigned_to=%s WHERE id=%s", (d.assign_to, task_id))
            _audit(cur, emp["id"], "approval_reassigned", "approval_task", task_id, {"to": d.assign_to})
            return {"status": "open", "assigned_to": d.assign_to}

        final_subject = final_body = None
        new_status = {"approve": "approved", "edit_approve": "edited_approved", "reject": "rejected",
                      "more_research": "more_research", "resolve": "resolved"}[d.action]
        if d.action == "approve":
            final_subject, final_body = draft_subject, draft_body
        elif d.action == "edit_approve":
            if not (d.subject and d.subject.strip() and d.body and d.body.strip()):
                raise HTTPException(status_code=400, detail="Edited subject and body are required")
            final_subject, final_body = d.subject.strip(), d.body.strip()
        cur.execute(
            """UPDATE flightbridge.approval_task
                  SET status=%s, decided_by=%s, decided_at=now(), final_subject=%s, final_body=%s, decision_note=%s
                WHERE id=%s AND status='open'""",
            (new_status, emp["id"], final_subject, final_body, d.note, task_id))
        _audit(cur, emp["id"], f"approval_{new_status}", "approval_task", task_id, {
            "note": d.note,
            "edited": d.action == "edit_approve",
            "original_subject": draft_subject if d.action == "edit_approve" else None,
            "original_body": draft_body if d.action == "edit_approve" else None,
        })
    msg = ("Queued for the central sending service; it will run jurisdiction and content checks. "
           "Nothing is sent while DRY_RUN is on or the kill switch is engaged.") if new_status in ("approved", "edited_approved") else None
    return {"status": new_status, "message": msg}


@router.get("/outbound")
def list_outbound(limit: int = 50, emp=Depends(require_admin)):
    limit = max(1, min(limit, 200))
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute(
            """SELECT m.id, m.status, m.kind, m.subject, m.created_at, m.authorized_at, m.sent_at, m.ref_token,
                      c.email, o.name AS org_name, o.country, e.decision AS jurisdiction, e.reasons AS jurisdiction_reasons,
                      k.decision AS content, k.reasons AS content_reasons
                 FROM flightbridge.outbound_message m
                 JOIN flightbridge.contact c ON c.id = m.contact_id
                 JOIN flightbridge.organisation o ON o.id = m.org_id
            LEFT JOIN LATERAL (SELECT decision, reasons FROM flightbridge.compliance_check
                                WHERE outbound_id = m.id AND kind='jurisdiction' ORDER BY id DESC LIMIT 1) e ON true
            LEFT JOIN LATERAL (SELECT decision, reasons FROM flightbridge.compliance_check
                                WHERE outbound_id = m.id AND kind='content' ORDER BY id DESC LIMIT 1) k ON true
                ORDER BY m.created_at DESC LIMIT %s""", (limit,))
        return _rows(cur)


@router.get("/outbound/{outbound_id}")
def outbound_detail(outbound_id: str, emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, status, kind, subject, body_text, ref_token, created_at FROM flightbridge.outbound_message WHERE id=%s",
                    (outbound_id,))
        rows = _rows(cur)
        if not rows:
            raise HTTPException(status_code=404, detail="Not found")
        return rows[0]


@router.post("/outbound/{outbound_id}/recheck")
def recheck(outbound_id: str, emp=Depends(require_admin)):
    """After a human adds evidence, send a 'needs_review' message back through the gates."""
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""UPDATE flightbridge.outbound_message SET status='pending_checks', authorized_at=NULL
                        WHERE id=%s AND status='needs_review' RETURNING id""", (outbound_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=409, detail="Only messages in needs_review can be re-checked")
        _audit(cur, emp["id"], "outbound_recheck_requested", "outbound_message", outbound_id, {})
    return {"status": "pending_checks"}


class EvidenceIn(BaseModel):
    contact_id: str
    fact: str
    source_url: str = Field(max_length=2048)
    excerpt: str = Field(min_length=3, max_length=2000)


@router.post("/evidence")
def add_evidence(e: EvidenceIn, emp=Depends(require_admin)):
    if e.fact not in HUMAN_FACTS:
        raise HTTPException(status_code=400, detail=f"fact must be one of {sorted(HUMAN_FACTS)}")
    if not e.source_url.lower().startswith(("https://", "http://")):
        raise HTTPException(status_code=400, detail="source_url must be http(s)")
    expires = datetime.now(timezone.utc) + timedelta(days=HUMAN_FACTS[e.fact])
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.contact_fact_evidence
                         (contact_id, fact, source_url, excerpt, method, verified_by, expires_at)
                       VALUES (%s,%s,%s,%s,'human_verified',%s,%s) RETURNING id""",
                    (e.contact_id, e.fact, e.source_url, e.excerpt.strip(), emp["id"], expires))
        eid = cur.fetchone()[0]
        _audit(cur, emp["id"], "evidence_added", "contact", e.contact_id, {"fact": e.fact, "evidence_id": eid})
    return {"id": eid, "expires_at": expires.isoformat()}


@router.get("/suppressions")
def list_suppressions(emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT s.id, s.scope, s.domain, s.reason, s.created_at, o.name AS org_name
                         FROM flightbridge.suppression s LEFT JOIN flightbridge.organisation o ON o.id = s.org_id
                        ORDER BY s.created_at DESC LIMIT 500""")
        return _rows(cur)


class SuppressionIn(BaseModel):
    scope: str
    email: Optional[str] = None
    org_id: Optional[str] = None
    domain: Optional[str] = None
    reason: str = "manual"


@router.post("/suppressions")
def add_suppression(s: SuppressionIn, emp=Depends(require_admin)):
    import hashlib
    if s.scope == "contact" and s.email:
        vals = (hashlib.sha256(s.email.strip().lower().encode()).hexdigest(), None, None)
    elif s.scope == "organisation" and s.org_id:
        vals = (None, s.org_id, None)
    elif s.scope == "domain" and s.domain:
        vals = (None, None, s.domain.strip().lower())
    else:
        raise HTTPException(status_code=400, detail="scope must be contact(email) | organisation(org_id) | domain(domain)")
    try:
        with _SchemaGuard(), get_db() as conn:
            cur = conn.cursor()
            cur.execute("""INSERT INTO flightbridge.suppression (scope, email_hash, org_id, domain, reason, created_by)
                           VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING RETURNING id""",
                        (s.scope, *vals, s.reason, emp["id"]))
            row = cur.fetchone()
            _audit(cur, emp["id"], "suppression_added", "suppression", row[0] if row else "existing", {"scope": s.scope})
    except psycopg.errors.RaiseException as exc:
        raise HTTPException(status_code=400, detail=str(exc).split("\n")[0])
    except psycopg.errors.CheckViolation:
        raise HTTPException(status_code=400, detail="Invalid suppression (scope/reason)")
    return {"status": "suppressed"}


class KillSwitch(BaseModel):
    engaged: bool


@router.post("/kill-switch")
def set_kill_switch(k: KillSwitch, emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.system_setting (key, value, updated_at, updated_by)
                       VALUES ('outbound_kill_switch', %s::jsonb, now(), %s)
                       ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now(), updated_by=EXCLUDED.updated_by""",
                    (json.dumps(k.engaged), emp["id"]))
        _audit(cur, emp["id"], "kill_switch_set", "system_setting", "outbound_kill_switch", {"engaged": k.engaged})
    return {"outbound_kill_switch": k.engaged,
            "note": "Releasing the kill switch alone sends nothing: DRY_RUN=false and OUTBOUND_ENABLED=true are also required."}


# ---------------------------------------------------------------- outreach templates (the paste box)
class TemplateIn(BaseModel):
    kind: str
    subject: str = Field(max_length=150)
    body: str = Field(max_length=20000)


@router.get("/templates")
def list_templates(emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT id, kind, version, subject, body, status, validation, created_at, approved_at
                         FROM flightbridge.outreach_template ORDER BY kind, version DESC LIMIT 200""")
        return _rows(cur)


@router.post("/templates")
def save_template(t: TemplateIn, emp=Depends(require_admin)):
    from flightbridge_template_rules import KINDS, validate
    if t.kind not in KINDS:
        raise HTTPException(status_code=400, detail=f"kind must be one of {list(KINDS)}")
    v = validate(t.subject, t.body)
    if len(t.body.strip()) < 20 or not t.subject.strip():
        raise HTTPException(status_code=400, detail="; ".join(v["errors"]) or "subject and body are required")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT coalesce(max(version),0)+1 FROM flightbridge.outreach_template WHERE kind=%s", (t.kind,))
        ver = cur.fetchone()[0]
        cur.execute("""INSERT INTO flightbridge.outreach_template (kind, version, subject, body, validation, created_by)
                       VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
                    (t.kind, ver, t.subject.strip(), t.body.strip(), json.dumps(v), emp["id"]))
        tid = cur.fetchone()[0]
        _audit(cur, emp["id"], "template_saved", "outreach_template", tid, {"kind": t.kind, "version": ver, "ok": v["ok"]})
    return {"id": str(tid), "version": ver, "validation": v}


@router.post("/templates/{template_id}/approve")
def approve_template(template_id: str, emp=Depends(require_admin)):
    from flightbridge_template_rules import validate
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT kind, subject, body, status FROM flightbridge.outreach_template WHERE id=%s FOR UPDATE", (template_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Template not found")
        v = validate(row[1], row[2])
        if not v["ok"]:
            raise HTTPException(status_code=400, detail="Fix before approving: " + "; ".join(v["errors"]))
        cur.execute("UPDATE flightbridge.outreach_template SET status='archived' WHERE kind=%s AND status='approved'", (row[0],))
        cur.execute("""UPDATE flightbridge.outreach_template SET status='approved', approved_by=%s, approved_at=now(), validation=%s
                       WHERE id=%s""", (emp["id"], json.dumps(v), template_id))
        _audit(cur, emp["id"], "template_approved", "outreach_template", template_id, {"kind": row[0]})
    return {"status": "approved", "kind": row[0]}


# ---------------------------------------------------------------- inbox
@router.get("/inbox")
def inbox(risk: Optional[str] = None, unmatched: bool = False, limit: int = 100, emp=Depends(require_admin)):
    limit = max(1, min(limit, 300))
    where, args = ["m.direction='inbound'"], []
    if risk in ("GREEN", "AMBER", "RED"):
        where.append("k.risk=%s"); args.append(risk)
    if unmatched:
        where.append("m.match_method='unmatched'")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute(f"""SELECT m.id, m.thread_id, m.from_address, m.subject, left(m.body_text, 600) AS preview, m.occurred_at,
                               m.match_method, m.is_bounce, m.is_auto_reply, m.is_unsubscribe, k.intent, k.risk, k.confidence,
                               k.signals, k.injection, o.name AS org_name, o.country
                          FROM flightbridge.email_message m
                     LEFT JOIN flightbridge.ai_classification k ON k.message_id = m.id
                          JOIN flightbridge.email_thread t ON t.id = m.thread_id
                     LEFT JOIN flightbridge.organisation o ON o.id = t.org_id
                         WHERE {' AND '.join(where)} ORDER BY m.occurred_at DESC LIMIT %s""", (*args, limit))
        return _rows(cur)


# ---------------------------------------------------------------- settings
class FollowupSettings(BaseModel):
    days: list[int]


@router.get("/settings")
def get_settings(emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT key, value FROM flightbridge.system_setting")
        return {r[0]: r[1] for r in cur.fetchall()}


@router.post("/settings/followups")
def set_followups(f: FollowupSettings, emp=Depends(require_admin)):
    if not (1 <= len(f.days) <= 3) or any(d < 2 or d > 60 for d in f.days) or f.days != sorted(set(f.days)):
        raise HTTPException(status_code=400, detail="Give 1-3 increasing day offsets between 2 and 60, e.g. [4, 9, 16]")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.system_setting (key, value, updated_at, updated_by)
                       VALUES ('followup_schedule_days', %s::jsonb, now(), %s)
                       ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now(), updated_by=EXCLUDED.updated_by""",
                    (json.dumps(f.days), emp["id"]))
        _audit(cur, emp["id"], "followup_schedule_set", "system_setting", "followup_schedule_days", {"days": f.days})
    return {"followup_schedule_days": f.days}


# ---------------------------------------------------------------- metrics (documented calculations)
@router.get("/metrics")
def metrics(emp=Depends(require_admin)):
    """contacted = distinct orgs with >=1 SENT initial; replied = contacted orgs with >=1 non-auto, non-bounce inbound;
    response_rate = replied / contacted. Opens are NOT tracked (a pixel cannot prove an email was read)."""
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            WITH sent AS (SELECT DISTINCT org_id FROM flightbridge.outbound_message WHERE kind='initial' AND status='sent'),
                 replied AS (SELECT DISTINCT t.org_id FROM flightbridge.email_message m JOIN flightbridge.email_thread t ON t.id=m.thread_id
                             WHERE m.direction='inbound' AND NOT m.is_auto_reply AND NOT m.is_bounce AND t.org_id IN (SELECT org_id FROM sent))
            SELECT (SELECT count(*) FROM sent), (SELECT count(*) FROM replied),
                   (SELECT count(*) FROM flightbridge.email_message WHERE direction='inbound'),
                   (SELECT count(*) FROM flightbridge.email_message WHERE direction='inbound' AND is_bounce),
                   (SELECT count(*) FROM flightbridge.approval_task WHERE status='open'),
                   (SELECT count(*) FROM flightbridge.approval_task WHERE status IN ('approved','edited_approved')),
                   (SELECT count(*) FROM flightbridge.approval_task WHERE status='edited_approved'),
                   (SELECT count(*) FROM flightbridge.approval_task WHERE status='rejected')""")
        r = cur.fetchone()
        cur.execute("SELECT risk, count(*) FROM flightbridge.ai_classification GROUP BY 1")
        by_risk = {k: v for k, v in cur.fetchall()}
        cur.execute("SELECT o.country, count(DISTINCT o.id) FROM flightbridge.organisation o GROUP BY 1 ORDER BY 2 DESC")
        by_country = {k: v for k, v in cur.fetchall()}
    contacted, replied = r[0], r[1]
    return {"schools_contacted": contacted, "schools_replied": replied,
            "response_rate": round(replied / contacted, 3) if contacted else None,
            "inbound_total": r[2], "bounces": r[3], "approvals_open": r[4], "approvals_approved": r[5],
            "approvals_edited": r[6], "approvals_rejected": r[7], "inbound_by_risk": by_risk, "schools_by_country": by_country}


# ---------------------------------------------------------------- Hostinger webhook (hint only; no auth dependency)
@router.post("/webhooks/hostinger")
async def hostinger_webhook(request: Request):
    """Hostinger authenticates deliveries with `Authorization: Bearer <secret>` (SDK v1.18.2 model docs).
    The event is stored once (dedupe on the payload hash) and the worker re-reads the mailbox over the API;
    the payload itself is never trusted for content."""
    import hashlib
    import hmac
    import os
    secret = os.getenv("FB_HOSTINGER_WEBHOOK_SECRET", "")
    auth = request.headers.get("authorization", "")
    if not secret or not hmac.compare_digest(auth.encode(), f"Bearer {secret}".encode()):
        raise HTTPException(status_code=401, detail="unauthorized")
    raw = await request.body()
    if len(raw) > 256_000:
        raise HTTPException(status_code=413, detail="payload too large")
    try:
        payload = json.loads(raw or b"{}")
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid JSON")
    key = hashlib.sha256(raw).hexdigest()
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.webhook_event (provider, event_key, payload) VALUES ('hostinger', %s, %s)
                       ON CONFLICT (provider, event_key) DO NOTHING""", (key, json.dumps(payload)))
    return {"ok": True}
