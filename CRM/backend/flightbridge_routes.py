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


def _fb_role(emp: dict) -> Optional[str]:
    """'admin' = CRM Admin department or permissions.flightbridge == 'admin';
    'researcher' = permissions.flightbridge == 'researcher' (can verify schools/evidence, never approve or send)."""
    if emp.get("department") == "Admin":
        return "admin"
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT permissions FROM employee WHERE id = %s", (emp["id"],))
        row = cur.fetchone()
    perms = (row[0] if row else None) or {}
    role = perms.get("flightbridge") if isinstance(perms, dict) else None
    return role if role in ("admin", "researcher") else None


def require_member(current_emp=Depends(get_current_employee)):
    role = _fb_role(current_emp)
    if role is None:
        raise HTTPException(status_code=403, detail="FlightBridge access has not been granted to this account")
    return {**current_emp, "fb_role": role}


def require_admin(current_emp=Depends(get_current_employee)):
    if _fb_role(current_emp) != "admin":
        raise HTTPException(status_code=403, detail="This action needs a FlightBridge admin")
    return {**current_emp, "fb_role": "admin"}


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
def summary(emp=Depends(require_member)):
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
def list_approvals(status: str = "open", emp=Depends(require_member)):
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
def approval_detail(task_id: str, emp=Depends(require_member)):
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
def list_outbound(limit: int = 50, emp=Depends(require_member)):
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
def outbound_detail(outbound_id: str, emp=Depends(require_member)):
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
def add_evidence(e: EvidenceIn, emp=Depends(require_member)):
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
def list_suppressions(emp=Depends(require_member)):
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
def list_templates(emp=Depends(require_member)):
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
def inbox(risk: Optional[str] = None, unmatched: bool = False, limit: int = 100, emp=Depends(require_member)):
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
def get_settings(emp=Depends(require_member)):
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
def metrics(emp=Depends(require_member)):
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
        cur.execute("SELECT o.country, count(DISTINCT o.id) FROM flightbridge.organisation o WHERE o.deleted_at IS NULL GROUP BY 1 ORDER BY 2 DESC")
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



# ---------------------------------------------------------------- identity & team (standalone app)
@router.get("/me")
def me(emp=Depends(require_member)):
    return {"id": emp["id"], "name": emp.get("name"), "department": emp.get("department"), "role": emp["fb_role"]}


@router.get("/team")
def team(emp=Depends(require_admin)):
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT id, name, department, coalesce(permissions->>'flightbridge', '') AS fb_role
                         FROM employee WHERE active = true ORDER BY name""")
        rows = _rows(cur)
    for r in rows:
        r["effective_role"] = "admin" if r["department"] == "Admin" else (r["fb_role"] or None)
    return rows


class RoleIn(BaseModel):
    role: Optional[str] = None      # 'researcher' | 'admin' | None (remove)


@router.post("/team/{employee_id}/role")
def set_role(employee_id: str, r: RoleIn, emp=Depends(require_admin)):
    if r.role not in (None, "researcher", "admin"):
        raise HTTPException(status_code=400, detail="role must be researcher, admin or null")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        if r.role is None:
            cur.execute("UPDATE employee SET permissions = coalesce(permissions,'{}'::jsonb) - 'flightbridge' WHERE id=%s RETURNING id",
                        (employee_id,))
        else:
            cur.execute("""UPDATE employee SET permissions = coalesce(permissions,'{}'::jsonb) || jsonb_build_object('flightbridge', %s::text)
                           WHERE id=%s RETURNING id""", (r.role, employee_id))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Employee not found")
        _audit(cur, emp["id"], "flightbridge_role_set", "employee", employee_id, {"role": r.role})
    return {"employee_id": employee_id, "role": r.role}


# ---------------------------------------------------------------- schools (organisations)
@router.get("/schools")
def schools(country: Optional[str] = None, status: Optional[str] = None, q: Optional[str] = None,
            region: Optional[str] = None, area_id: Optional[int] = None, eligibility: Optional[str] = None,
            kind: Optional[str] = None, limit: int = 300, emp=Depends(require_member)):
    limit = max(1, min(limit, 1000))
    where, args = ["o.deleted_at IS NULL"], []
    if area_id == 0:
        where.append("o.area_id IS NULL")
    elif area_id:
        where.append("o.area_id = %s"); args.append(area_id)
    if eligibility in ("unknown", "eligible_verified", "eligible_claimed", "unqualified"):
        where.append("o.eligibility = %s"); args.append(eligibility)
    if kind in ("flying_school", "ground_school"):
        where.append("o.org_kind = %s"); args.append(kind)
    if country:
        where.append("o.country = %s"); args.append(country.upper()[:2])
    if region == "__none__":
        where.append("o.region IS NULL")
    elif region:
        where.append("o.region = %s"); args.append(region)
    if status:
        where.append("o.status = %s"); args.append(status)
    if q:
        where.append("(o.name ILIKE %s OR o.website_domain ILIKE %s OR ra.approval_ref ILIKE %s)"); args += [f"%{q}%"] * 3
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT o.id, o.name, o.country, o.region, o.city, o.website_domain, o.status, o.rejection_reason, o.updated_at,
                   o.area_id, o.eligibility, o.org_kind,
                   (SELECT count(*) FROM flightbridge.contact_phone p WHERE p.org_id = o.id) AS phones,
                   ra.authority_code, ra.classification, ra.approval_ref, ra.status AS approval_status, ra.checked_at,
                   qr.score, qr.recommended_action,
                   (SELECT count(*) FROM flightbridge.contact c WHERE c.org_id = o.id) AS contacts
              FROM flightbridge.organisation o
         LEFT JOIN LATERAL (SELECT * FROM flightbridge.regulatory_approval r WHERE r.org_id = o.id
                             ORDER BY r.checked_at DESC LIMIT 1) ra ON true
         LEFT JOIN LATERAL (SELECT score, recommended_action FROM flightbridge.qualification_result x WHERE x.org_id = o.id
                             ORDER BY computed_at DESC LIMIT 1) qr ON true
             WHERE {' AND '.join(where)}
             ORDER BY o.country, o.region NULLS LAST, o.name LIMIT %s""", (*args, limit))
        return _rows(cur)


@router.get("/schools/{org_id}")
def school_detail(org_id: str, emp=Depends(require_member)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM flightbridge.organisation WHERE id=%s", (org_id,))
        rows = _rows(cur)
        if not rows:
            raise HTTPException(status_code=404, detail="School not found")
        out = rows[0]
        for key, sql in {
            "identifiers": "SELECT scheme, value, source_url FROM flightbridge.organisation_identifier WHERE org_id=%s",
            "regulatory": """SELECT id, authority_code, classification, approval_ref, courses, status, source_url, source_version,
                                    checked_at, next_check_due FROM flightbridge.regulatory_approval WHERE org_id=%s""",
            "contacts": """SELECT c.id, c.email, c.is_role_address, c.role, c.source_url, c.verification_level,
                                  (SELECT json_agg(json_build_object('fact', e.fact, 'method', e.method, 'excerpt', e.excerpt,
                                          'source_url', e.source_url, 'expires_at', e.expires_at) ORDER BY e.verified_at DESC)
                                     FROM flightbridge.contact_fact_evidence e WHERE e.contact_id = c.id) AS evidence
                             FROM flightbridge.contact c WHERE c.org_id=%s ORDER BY c.is_role_address DESC, c.email""",
            "qualification": """SELECT score, breakdown, missing, risks, recommended_action, confidence, computed_at
                                  FROM flightbridge.qualification_result WHERE org_id=%s ORDER BY computed_at DESC LIMIT 1""",
            "pages": "SELECT url, http_status, robots_allowed, fetched_at FROM flightbridge.website_page WHERE org_id=%s ORDER BY fetched_at DESC LIMIT 30",
            "profile": "SELECT summary, signals, evidence, generator, updated_at FROM flightbridge.organisation_profile WHERE org_id=%s",
            "phones": """SELECT phone, display, source, source_url, found_at FROM flightbridge.contact_phone WHERE org_id=%s
                          ORDER BY CASE source WHEN 'website' THEN 0 WHEN 'regulator' THEN 1 WHEN 'human' THEN 2 ELSE 3 END""",
            "area": "SELECT a.id, a.name, a.region, a.kind FROM flightbridge.area a JOIN flightbridge.organisation o ON o.area_id=a.id WHERE o.id=%s",
            "jobs": """SELECT id, kind, status, requested_at, finished_at, result FROM flightbridge.job_request
                        WHERE org_id=%s ORDER BY requested_at DESC LIMIT 5""",
            "history": """SELECT at, actor_type, action, payload FROM flightbridge.audit_log
                           WHERE entity='organisation' AND entity_id=%s ORDER BY at DESC LIMIT 30""",
        }.items():
            cur.execute(sql, (org_id,))
            out[key] = _rows(cur)
        out["qualification"] = (out["qualification"] or [None])[0]
        out["profile"] = (out["profile"] or [None])[0]
        out["area"] = (out["area"] or [None])[0]
        try:
            from flightbridge.eligibility import load_rules
            rule = load_rules().get(out["country"])
            out["eligibility_rule"] = {"credential": rule["credential"], "lookup": rule["lookup"]} if rule else None
        except ImportError:
            out["eligibility_rule"] = None
        return out


class ReviewIn(BaseModel):
    decision: str                      # qualified | rejected | needs_human_review
    reason: Optional[str] = Field(default=None, max_length=500)


@router.post("/schools/{org_id}/review")
def review_school(org_id: str, r: ReviewIn, emp=Depends(require_member)):
    if r.decision not in ("qualified", "rejected", "needs_human_review"):
        raise HTTPException(status_code=400, detail="decision must be qualified, rejected or needs_human_review")
    if r.decision == "rejected" and not (r.reason and r.reason.strip()):
        raise HTTPException(status_code=400, detail="A reason is required to reject a school")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""UPDATE flightbridge.organisation SET status=%s, rejection_reason=%s, updated_at=now()
                       WHERE id=%s AND status NOT IN ('contacted','interested','negotiation','partner') RETURNING id""",
                    (r.decision, r.reason.strip() if r.decision == "rejected" else None, org_id))
        if not cur.fetchone():
            raise HTTPException(status_code=409, detail="School not found or already in conversation")
        _audit(cur, emp["id"], f"school_{r.decision}", "organisation", org_id, {"reason": r.reason, "by_role": emp["fb_role"]})
    return {"status": r.decision}


@router.post("/schools/{org_id}/regulatory/{approval_id}/verify")
def verify_regulatory(org_id: str, approval_id: int, emp=Depends(require_member)):
    """A person confirmed this record on the regulator's own site (needed for FAA / Transport Canada / CASA)."""
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""UPDATE flightbridge.regulatory_approval
                          SET status='verified_by_human', checked_by=%s, checked_at=now(), next_check_due=now() + interval '90 days'
                        WHERE id=%s AND org_id=%s RETURNING id""", (emp["id"], approval_id, org_id))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Regulatory record not found")
        _audit(cur, emp["id"], "regulatory_verified_by_human", "organisation", org_id, {"approval_id": approval_id})
    return {"status": "verified_by_human"}



# ---------------------------------------------------------------- navigation: country > region
@router.get("/regions")
def regions(emp=Depends(require_member)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT country, region, count(*) AS total,
                              count(*) FILTER (WHERE status='needs_human_review') AS needs_look,
                              count(*) FILTER (WHERE status IN ('qualified','ready_for_outreach')) AS good_fit,
                              count(*) FILTER (WHERE status IN ('contacted','interested','negotiation','partner')) AS in_contact
                         FROM flightbridge.organisation WHERE deleted_at IS NULL
                        GROUP BY 1, 2 ORDER BY 1, 2 NULLS LAST""")
        rows = _rows(cur)
        try:
            cur.execute("""SELECT a.id, a.country, a.region, a.name, a.kind, a.enabled, a.last_searched_at,
                                  count(o.id) AS total,
                                  count(o.id) FILTER (WHERE o.eligibility='eligible_verified') AS verified,
                                  count(o.id) FILTER (WHERE o.eligibility='eligible_claimed') AS claimed,
                                  count(o.id) FILTER (WHERE o.eligibility='unqualified') AS unqualified
                             FROM flightbridge.area a
                        LEFT JOIN flightbridge.organisation o ON o.area_id=a.id AND o.deleted_at IS NULL
                            GROUP BY a.id ORDER BY a.country, a.region, a.name""")
            areas = _rows(cur)
            cur.execute("""SELECT country, region, count(*) AS n FROM flightbridge.organisation
                            WHERE deleted_at IS NULL AND area_id IS NULL GROUP BY 1, 2""")
            unplaced = {(r["country"], r["region"]): r["n"] for r in _rows(cur)}
        except psycopg.errors.UndefinedTable:
            conn.rollback()
            areas, unplaced = [], {}
    out = {}
    for r in rows:
        c = out.setdefault(r["country"], {"country": r["country"], "total": 0, "needs_look": 0, "regions": []})
        c["total"] += r["total"]; c["needs_look"] += r["needs_look"]
        c["regions"].append({**{k: r[k] for k in ("region", "total", "needs_look", "good_fit", "in_contact")},
                             "areas": [], "unplaced": unplaced.get((r["country"], r["region"]), 0)})
    for a in areas:                       # areas with no schools yet still show (so they can be searched)
        c = out.setdefault(a["country"], {"country": a["country"], "total": 0, "needs_look": 0, "regions": []})
        reg = next((x for x in c["regions"] if x["region"] == a["region"]), None)
        if reg is None:
            reg = {"region": a["region"], "total": 0, "needs_look": 0, "good_fit": 0, "in_contact": 0, "areas": [], "unplaced": 0}
            c["regions"].append(reg)
        reg["areas"].append({k: a[k] for k in ("id", "name", "kind", "enabled", "last_searched_at", "total", "verified", "claimed", "unqualified")})
    for c in out.values():
        c["regions"].sort(key=lambda x: (-x["total"], x["region"] or ""))
    return sorted(out.values(), key=lambda c: (-c["total"], c["country"]))


# ---------------------------------------------------------------- automation (worker status, Run now)
JOB_KINDS = {"cycle", "research_school", "find_websites", "research_batch", "search_area"}
AUTOPILOT_KEYS = {"find_websites", "research", "qualify", "draft"}


def _dispatch_github():
    """Optional: start the GitHub Actions worker immediately instead of waiting for the next 15-minute run.
    Needs FB_GITHUB_DISPATCH_TOKEN (fine-grained token, Actions: write on the FlightBridge repo) on the server."""
    import os
    token = os.environ.get("FB_GITHUB_DISPATCH_TOKEN")
    if not token:
        return False
    import requests
    repo = os.environ.get("FB_GITHUB_REPO", "nikkk07/FlightBridge-AI")
    try:
        r = requests.post(f"https://api.github.com/repos/{repo}/actions/workflows/flightbridge-worker.yml/dispatches",
                          headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
                          json={"ref": "main", "inputs": {"trigger": "queue"}}, timeout=10)
        return r.status_code == 204
    except Exception:
        return False


@router.get("/automation")
def automation_status(emp=Depends(require_member)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT id, started_at, finished_at, runner, trigger, status, stats, error
                         FROM flightbridge.worker_run ORDER BY started_at DESC LIMIT 20""")
        runs = _rows(cur)
        cur.execute("""SELECT j.id, j.kind, j.status, j.requested_at, j.started_at, j.finished_at, j.result,
                              o.name AS org_name, e.name AS requested_by_name
                         FROM flightbridge.job_request j
                    LEFT JOIN flightbridge.organisation o ON o.id = j.org_id
                    LEFT JOIN employee e ON e.id = j.requested_by
                        ORDER BY j.requested_at DESC LIMIT 20""")
        jobs = _rows(cur)
        cur.execute("""SELECT runner, max(started_at) AS last_seen FROM flightbridge.worker_run
                        WHERE started_at > now() - interval '7 days' GROUP BY 1 ORDER BY 2 DESC""")
        runners = _rows(cur)
        cur.execute("""SELECT a.at, a.actor_type, a.action, a.entity, a.entity_id, a.payload, o.name AS org_name
                         FROM flightbridge.audit_log a
                    LEFT JOIN flightbridge.organisation o ON a.entity='organisation' AND o.id::text = a.entity_id
                        WHERE a.action IN ('website_search','research_stored','qualified','draft_created','draft_skipped',
                                           'organisation_created','school_qualified','school_rejected','regulatory_verified_by_human',
                                           'approval_approved','approval_edited_approved','template_approved','kill_switch_set')
                        ORDER BY a.at DESC LIMIT 40""")
        activity = _rows(cur)
        cur.execute("SELECT value FROM flightbridge.system_setting WHERE key='autopilot'")
        row = cur.fetchone()
        cur.execute("""SELECT count(*) FILTER (WHERE website_domain IS NULL AND status IN ('discovered','research_pending')),
                              count(*) FILTER (WHERE website_domain IS NOT NULL AND status IN ('discovered','research_pending')),
                              count(*) FILTER (WHERE status='research_completed')
                         FROM flightbridge.organisation WHERE deleted_at IS NULL""")
        backlog = dict(zip(("need_website", "need_research", "need_scoring"), cur.fetchone()))
    return {"runs": runs, "jobs": jobs, "runners": runners, "activity": activity,
            "autopilot": row[0] if row else None, "backlog": backlog}


class RunIn(BaseModel):
    kind: str
    org_id: Optional[str] = None
    area_id: Optional[int] = None


@router.post("/automation/run")
def automation_run(r: RunIn, emp=Depends(require_member)):
    if r.kind not in JOB_KINDS:
        raise HTTPException(status_code=400, detail=f"kind must be one of {sorted(JOB_KINDS)}")
    if r.kind == "research_school" and not r.org_id:
        raise HTTPException(status_code=400, detail="org_id is required to research one school")
    if r.kind == "search_area" and not r.area_id:
        raise HTTPException(status_code=400, detail="area_id is required to search an area")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        if r.area_id is not None:
            cur.execute("""INSERT INTO flightbridge.job_request (kind, org_id, area_id, requested_by) VALUES (%s,%s,%s,%s)
                           ON CONFLICT DO NOTHING RETURNING id""", (r.kind, r.org_id, r.area_id, emp["id"]))
        else:
            cur.execute("""INSERT INTO flightbridge.job_request (kind, org_id, requested_by) VALUES (%s,%s,%s)
                           ON CONFLICT DO NOTHING RETURNING id""", (r.kind, r.org_id, emp["id"]))
        row = cur.fetchone()
        if row:
            _audit(cur, emp["id"], "run_requested", "job_request", row[0], {"kind": r.kind, "org_id": r.org_id, "area_id": r.area_id})
    started = _dispatch_github() if row else False
    return {"queued": bool(row), "already_queued": not row, "started_now": started,
            "message": ("Started." if started else "Queued. It runs on the next worker cycle (every 15 minutes, "
                        "or within a minute while the Mac runner is on).") if row else "Already queued."}
    # (the CRM-server engine polls the queue every 30 seconds, so in practice it starts within a minute)


class AutopilotIn(BaseModel):
    find_websites: bool
    research: bool
    qualify: bool
    draft: bool
    batch_size: int = Field(ge=1, le=50)


@router.post("/automation/settings")
def automation_settings(a: AutopilotIn, emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.system_setting (key, value, updated_at, updated_by)
                       VALUES ('autopilot', %s::jsonb, now(), %s)
                       ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now(), updated_by=EXCLUDED.updated_by""",
                    (json.dumps(a.model_dump()), emp["id"]))
        _audit(cur, emp["id"], "autopilot_set", "system_setting", "autopilot", a.model_dump())
    return a.model_dump()



# ---------------------------------------------------------------- integrations (API keys entered here; encrypted at rest)
INTEGRATION_KEYS = {
    "google_places_api_key": "Google Places API key",
    "groq_api_key": "Groq API key",
    "gemini_api_key": "Gemini API key",
    "hostinger_mail_api_token": "Hostinger Mail API token",
    "hostinger_mailbox_resource_id": "Hostinger mailbox ID",
}


def _fb_pkg():
    try:
        from flightbridge import integrations, secrets
        return secrets, integrations
    except ImportError:
        raise HTTPException(status_code=503, detail="FlightBridge engine is not installed on the server (requirements.txt)")


@router.get("/integrations")
def integrations_status(emp=Depends(require_admin)):
    import os
    secrets, _ = _fb_pkg()
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT name, last4, updated_at, last_test_at, last_test_ok, last_test_message
                         FROM flightbridge.integration_secret""")
        saved = {r["name"]: r for r in _rows(cur)}
        cur.execute("SELECT value FROM flightbridge.system_setting WHERE key='integrations'")
        row = cur.fetchone()
    keys = []
    for name, label in INTEGRATION_KEYS.items():
        env_name = secrets.NAMES[name]
        r = saved.get(name) or {}
        keys.append({"name": name, "label": label, "saved": bool(r), "last4": r.get("last4"),
                     "updated_at": r.get("updated_at"), "from_server_env": bool(os.environ.get(env_name)),
                     "last_test_at": r.get("last_test_at"), "last_test_ok": r.get("last_test_ok"),
                     "last_test_message": r.get("last_test_message")})
    cfg = dict(secrets.DEFAULT_SETTINGS)
    if row and isinstance(row[0], dict):
        cfg.update({k: v for k, v in row[0].items() if k in cfg})
    return {"keys": keys, "settings": cfg, "engine_env_off": os.environ.get("FLIGHTBRIDGE_ENGINE", "").lower() == "off",
            "dry_run": os.environ.get("DRY_RUN", "true").strip() != "false",
            "outbound_enabled": os.environ.get("OUTBOUND_ENABLED", "false").strip() == "true"}


class KeyIn(BaseModel):
    value: str = Field(min_length=1, max_length=4000)


def _record_test(cur, name, ok, msg):
    cur.execute("""UPDATE flightbridge.integration_secret SET last_test_at=now(), last_test_ok=%s, last_test_message=%s
                   WHERE name=%s""", (ok, msg[:500], name))


@router.post("/integrations/{name}")
def integrations_save(name: str, k: KeyIn, emp=Depends(require_admin)):
    if name not in INTEGRATION_KEYS:
        raise HTTPException(status_code=404, detail="Unknown key")
    secrets, integrations = _fb_pkg()
    value = k.value.strip()
    token = None
    if name == "hostinger_mailbox_resource_id":
        token = secrets.get("hostinger_mail_api_token", _db_url())
    ok, msg = integrations.check(name, value, mailbox_token=token)
    try:
        with _SchemaGuard(), get_db() as conn:
            cur = conn.cursor()
            l4 = secrets.save(_PsycopgAdapter(cur), name, value, emp["id"])
            _record_test(cur, name, ok, msg)
            _audit(cur, emp["id"], "integration_key_saved", "integration", name, {"last4": l4, "test_ok": ok})
    except secrets.SecretUnreadable as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return {"name": name, "saved": True, "last4": l4, "test_ok": ok, "message": msg}


@router.post("/integrations/{name}/test")
def integrations_test(name: str, emp=Depends(require_admin)):
    if name not in INTEGRATION_KEYS:
        raise HTTPException(status_code=404, detail="Unknown key")
    secrets, integrations = _fb_pkg()
    url = _db_url()
    secrets.configure(url)
    value = secrets.get(name, url)
    if not value:
        raise HTTPException(status_code=400, detail="No key saved (or it can't be read any more - enter it again)")
    ok, msg = integrations.check(name, value, mailbox_token=secrets.get("hostinger_mail_api_token", url))
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        _record_test(cur, name, ok, msg)
    return {"name": name, "test_ok": ok, "message": msg}


@router.delete("/integrations/{name}")
def integrations_delete(name: str, emp=Depends(require_admin)):
    if name not in INTEGRATION_KEYS:
        raise HTTPException(status_code=404, detail="Unknown key")
    secrets, _ = _fb_pkg()
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM flightbridge.integration_secret WHERE name=%s", (name,))
        _audit(cur, emp["id"], "integration_key_removed", "integration", name, {})
    secrets.configure(None)
    return {"name": name, "saved": False}


class IntegrationSettingsIn(BaseModel):
    engine_in_crm: bool = True
    llm_provider: str = "none"
    llm_model: str = Field(default="", max_length=100)
    inbound_source: str = "none"


@router.post("/integrations-settings")
def integrations_settings(i: IntegrationSettingsIn, emp=Depends(require_admin)):
    if i.llm_provider not in ("none", "groq", "gemini"):
        raise HTTPException(status_code=400, detail="llm_provider must be none, groq or gemini")
    if i.inbound_source not in ("none", "hostinger"):
        raise HTTPException(status_code=400, detail="inbound_source must be none or hostinger")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.system_setting (key, value, updated_at, updated_by)
                       VALUES ('integrations', %s::jsonb, now(), %s)
                       ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now(), updated_by=EXCLUDED.updated_by""",
                    (json.dumps(i.model_dump()), emp["id"]))
        _audit(cur, emp["id"], "integration_settings_set", "system_setting", "integrations", i.model_dump())
    return i.model_dump()


def _db_url():
    import os
    return os.environ.get("FLIGHTBRIDGE_DATABASE_URL") or os.environ.get("DATABASE_URL")


class _PsycopgAdapter:
    """flightbridge.secrets.save expects conn.execute(); the CRM gives a cursor."""
    def __init__(self, cur):
        self.cur = cur

    def execute(self, sql, args=None):
        self.cur.execute(sql, args)
        return self.cur



# ---------------------------------------------------------------- areas (Country > State > Area)
class AreaIn(BaseModel):
    country: str = Field(min_length=2, max_length=2)
    region: str = Field(min_length=1, max_length=80)
    name: str = Field(min_length=1, max_length=120)
    kind: str = "training_hub"
    radius_km: int = Field(default=40, ge=2, le=50)
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)


@router.get("/areas")
def areas_list(emp=Depends(require_member)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""SELECT a.*, (SELECT count(*) FROM flightbridge.organisation o WHERE o.area_id=a.id AND o.deleted_at IS NULL) AS schools
                         FROM flightbridge.area a ORDER BY a.country, a.region, a.name""")
        return _rows(cur)


@router.post("/areas")
def areas_add(a: AreaIn, emp=Depends(require_admin)):
    if a.kind not in ("training_hub", "demand_hub"):
        raise HTTPException(status_code=400, detail="kind must be training_hub or demand_hub")
    lat, lng = a.lat, a.lng
    if lat is None or lng is None:
        try:
            from flightbridge import secrets
            from flightbridge.research.discover import geocode
            from flightbridge.research.places import PlacesError
        except ImportError:
            raise HTTPException(status_code=503, detail="FlightBridge engine is not installed on the server")
        secrets.configure(_db_url())
        try:
            found = geocode(a.name.strip(), a.region.strip(), a.country.upper())
        except PlacesError as exc:
            raise HTTPException(status_code=400, detail=f"Couldn't locate the area with Google: {exc}. Add the Google Places key in Settings, or enter coordinates.")
        if not found:
            raise HTTPException(status_code=400, detail="Google couldn't find that place. Check the spelling or enter coordinates.")
        lat, lng = found
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO flightbridge.area (country, region, name, kind, lat, lng, radius_km, notes)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,'added in the app') ON CONFLICT (country, region, name) DO NOTHING
                       RETURNING id""", (a.country.upper(), a.region.strip(), a.name.strip(), a.kind, lat, lng, a.radius_km))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=409, detail="That area already exists")
        _audit(cur, emp["id"], "area_added", "area", row[0], {"name": a.name, "region": a.region, "country": a.country})
    return {"id": row[0], "lat": lat, "lng": lng}


class AreaPatch(BaseModel):
    enabled: Optional[bool] = None
    radius_km: Optional[int] = Field(default=None, ge=2, le=50)


@router.patch("/areas/{area_id}")
def areas_patch(area_id: int, p: AreaPatch, emp=Depends(require_admin)):
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        cur.execute("""UPDATE flightbridge.area SET enabled=coalesce(%s, enabled), radius_km=coalesce(%s, radius_km)
                       WHERE id=%s RETURNING id""", (p.enabled, p.radius_km, area_id))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Area not found")
        _audit(cur, emp["id"], "area_changed", "area", area_id, p.model_dump(exclude_none=True))
    return {"id": area_id, **p.model_dump(exclude_none=True)}


# ---------------------------------------------------------------- eligibility decisions by a person
class EligibilityIn(BaseModel):
    decision: str                                     # confirm | unqualified | recheck
    reference: Optional[str] = Field(default=None, max_length=80)
    source_url: Optional[str] = Field(default=None, max_length=2048)
    note: Optional[str] = Field(default=None, max_length=500)


@router.post("/schools/{org_id}/eligibility")
def school_eligibility(org_id: str, e: EligibilityIn, emp=Depends(require_member)):
    try:
        from flightbridge import eligibility as elig
    except ImportError:
        raise HTTPException(status_code=503, detail="FlightBridge engine is not installed on the server")
    if e.decision not in ("confirm", "unqualified", "recheck"):
        raise HTTPException(status_code=400, detail="decision must be confirm, unqualified or recheck")
    if e.decision == "unqualified" and not (e.note and e.note.strip()):
        raise HTTPException(status_code=400, detail="Say why it's unqualified")
    if e.source_url and not e.source_url.lower().startswith(("https://", "http://")):
        raise HTTPException(status_code=400, detail="source_url must be a web address")
    with _SchemaGuard(), get_db() as conn:
        cur = conn.cursor()
        a = _PsycopgAdapter(cur)
        cur.execute("SELECT 1 FROM flightbridge.organisation WHERE id=%s", (org_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="School not found")
        try:
            if e.decision == "confirm":
                result = elig.confirm(a, org_id, emp["id"], e.reference, e.source_url)
            elif e.decision == "unqualified":
                elig.mark_unqualified(a, org_id, emp["id"], e.note.strip())
                result = "unqualified"
            else:
                cur.execute("UPDATE flightbridge.organisation SET eligibility_reasons='[]'::jsonb WHERE id=%s", (org_id,))
                result = elig.evaluate_org(a, org_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        _audit(cur, emp["id"], f"eligibility_{e.decision}", "organisation", org_id,
               {"result": result, "reference": e.reference, "note": e.note, "by_role": emp["fb_role"]})
    return {"eligibility": result}
