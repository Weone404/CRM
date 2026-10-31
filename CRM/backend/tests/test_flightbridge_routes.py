"""Tests for the FlightBridge CRM module. Needs a Postgres with migrations 001-038 applied:
    TEST_DATABASE_URL=postgresql://... python -m pytest CRM/backend/tests -q
"""
import os
import sys
import uuid

import pytest

DB = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB, reason="TEST_DATABASE_URL not set")

if DB:
    os.environ["DATABASE_URL"] = DB
    os.environ.setdefault("SECRET_KEY", "test-secret")
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="module")
def app_and_db():
    import psycopg
    from fastapi.testclient import TestClient
    import main
    from auth import get_current_employee

    conn = psycopg.connect(DB, autocommit=True)
    admin = conn.execute("INSERT INTO employee (name, phone, password_hash, department, login_id) VALUES "
                         "('FB Admin', %s, 'x', 'Admin', %s) RETURNING id", (uuid.uuid4().hex[:10], "fbadmin" + uuid.uuid4().hex[:6])).fetchone()[0]
    sales = conn.execute("INSERT INTO employee (name, phone, password_hash, department, login_id) VALUES "
                         "('FB Sales', %s, 'x', 'Sales', %s) RETURNING id", (uuid.uuid4().hex[:10], "fbsales" + uuid.uuid4().hex[:6])).fetchone()[0]
    who = {"emp": {"id": str(admin), "department": "Admin", "name": "FB Admin"}}
    main.app.dependency_overrides[get_current_employee] = lambda: who["emp"]
    yield TestClient(main.app), conn, who, str(admin), str(sales)
    main.app.dependency_overrides.clear()
    conn.close()
    from database import pool
    pool.close()


def _seed_task(conn):
    org = conn.execute("INSERT INTO flightbridge.organisation (name, country, status) VALUES ('Route Test Aero','US','qualified') "
                       "RETURNING id").fetchone()[0]
    email = f"info+{uuid.uuid4().hex[:6]}@routetest.example"
    con = conn.execute("""INSERT INTO flightbridge.contact (org_id,email,email_hash,email_domain,is_role_address,source_url)
                          VALUES (%s,%s,md5(%s),'routetest.example',true,'https://routetest.example/contact') RETURNING id""",
                       (org, email, email)).fetchone()[0]
    d = conn.execute("""INSERT INTO flightbridge.ai_draft (org_id,contact_id,kind,risk,subject,body_text,generator)
                        VALUES (%s,%s,'initial','AMBER','Partnership enquiry','Dear team','t') RETURNING id""",
                     (org, con)).fetchone()[0]
    t = conn.execute("INSERT INTO flightbridge.approval_task (draft_id,risk,escalation_reason) VALUES (%s,'AMBER','first contact') "
                     "RETURNING id", (d,)).fetchone()[0]
    return str(t), str(con), str(org)


def test_existing_routes_still_registered(app_and_db):
    client, *_ = app_and_db
    paths = {r.path for r in client.app.routes}
    for p in ("/health", "/api/leads", "/api/outbox", "/api/students", "/api/employees", "/api/tasks"):
        assert p in paths
    assert client.get("/health").status_code == 200


def test_non_admin_forbidden(app_and_db):
    client, conn, who, admin, sales = app_and_db
    who["emp"] = {"id": sales, "department": "Sales"}
    try:
        assert client.get("/api/flightbridge/summary").status_code == 403
    finally:
        who["emp"] = {"id": admin, "department": "Admin"}


def test_approve_flow_records_decision_and_never_sends(app_and_db):
    client, conn, who, admin, _ = app_and_db
    task, _, _ = _seed_task(conn)
    lst = client.get("/api/flightbridge/approvals").json()
    assert any(x["id"] == task for x in lst)
    det = client.get(f"/api/flightbridge/approvals/{task}").json()
    assert det["organisation"]["name"] == "Route Test Aero" and det["contact"]["is_role_address"] is True
    r = client.post(f"/api/flightbridge/approvals/{task}/decision", json={"action": "approve", "note": "ok"})
    assert r.status_code == 200 and r.json()["status"] == "approved"
    assert client.post(f"/api/flightbridge/approvals/{task}/decision", json={"action": "reject"}).status_code == 409
    assert conn.execute("SELECT count(*) FROM flightbridge.outbound_message m JOIN flightbridge.approval_task a "
                        "ON a.id=m.approval_task_id WHERE a.id=%s", (task,)).fetchone()[0] == 0   # CRM never creates/sends
    row = conn.execute("SELECT final_subject, decided_by::text FROM flightbridge.approval_task WHERE id=%s", (task,)).fetchone()
    assert row == ("Partnership enquiry", admin)


def test_edit_approve_requires_content_and_audits_original(app_and_db):
    client, conn, *_ = app_and_db
    task, _, _ = _seed_task(conn)
    assert client.post(f"/api/flightbridge/approvals/{task}/decision", json={"action": "edit_approve"}).status_code == 400
    r = client.post(f"/api/flightbridge/approvals/{task}/decision",
                    json={"action": "edit_approve", "subject": "Edited subject", "body": "Edited body"})
    assert r.json()["status"] == "edited_approved"
    final = conn.execute("SELECT final_body FROM flightbridge.approval_task WHERE id=%s", (task,)).fetchone()[0]
    assert final == "Edited body"
    payload = conn.execute("SELECT payload FROM flightbridge.audit_log WHERE entity_id=%s AND action='approval_edited_approved'",
                           (task,)).fetchone()[0]
    assert payload["original_body"] == "Dear team" and payload["edited"] is True


def test_invalid_action_rejected(app_and_db):
    client, conn, *_ = app_and_db
    task, _, _ = _seed_task(conn)
    assert client.post(f"/api/flightbridge/approvals/{task}/decision", json={"action": "send_now"}).status_code == 400


def test_shared_provider_domain_suppression_refused(app_and_db):
    client, *_ = app_and_db
    r = client.post("/api/flightbridge/suppressions", json={"scope": "domain", "domain": "gmail.com"})
    assert r.status_code == 400 and "shared provider" in r.json()["detail"]
    assert client.post("/api/flightbridge/suppressions", json={"scope": "domain", "domain": "optout-school.example"}).status_code == 200


def test_evidence_validation(app_and_db):
    client, conn, *_ = app_and_db
    _, contact, _ = _seed_task(conn)
    bad = client.post("/api/flightbridge/evidence", json={"contact_id": contact, "fact": "made_up", "source_url": "https://x", "excerpt": "abc"})
    assert bad.status_code == 400
    ok = client.post("/api/flightbridge/evidence", json={"contact_id": contact, "fact": "message_relevant_to_business_role",
                                                         "source_url": "https://routetest.example/admissions",
                                                         "excerpt": "International admissions office handles partner schools"})
    assert ok.status_code == 200
    m = conn.execute("SELECT method, verified_by IS NOT NULL FROM flightbridge.contact_fact_evidence WHERE id=%s",
                     (ok.json()["id"],)).fetchone()
    assert m == ("human_verified", True)


def test_kill_switch_and_recheck_guard(app_and_db):
    client, conn, *_ = app_and_db
    r = client.post("/api/flightbridge/kill-switch", json={"engaged": True})
    assert r.json()["outbound_kill_switch"] is True
    assert client.get("/api/flightbridge/summary").json()["kill_switches"]["outbound_kill_switch"] is True
    assert client.post(f"/api/flightbridge/outbound/{uuid.uuid4()}/recheck").status_code == 409


def test_missing_schema_returns_503(app_and_db):
    client, conn, *_ = app_and_db
    conn.execute("ALTER SCHEMA flightbridge RENAME TO flightbridge_hidden")
    try:
        assert client.get("/api/flightbridge/summary").status_code == 503
        assert client.get("/health").status_code == 200        # rest of the CRM unaffected
    finally:
        conn.execute("ALTER SCHEMA flightbridge_hidden RENAME TO flightbridge")


def test_template_paste_validate_and_approve(app_and_db):
    client, conn, *_ = app_and_db
    bad = client.post("/api/flightbridge/templates", json={"kind": "initial", "subject": "Hello",
                                                            "body": "We are India's best academy with 3000+ pilots trained."}).json()
    assert bad["validation"]["ok"] is False
    assert client.post(f"/api/flightbridge/templates/{bad['id']}/approve").status_code == 400
    good = client.post("/api/flightbridge/templates", json={"kind": "initial", "subject": "Partnership enquiry for {{school_name}}",
                                                             "body": "Dear {{school_name}} team,\n\nWe teach DGCA ground subjects in Delhi."}).json()
    assert good["validation"]["ok"] and good["version"] == bad["version"] + 1
    assert client.post(f"/api/flightbridge/templates/{good['id']}/approve").json()["status"] == "approved"
    assert client.post("/api/flightbridge/templates", json={"kind": "promo", "subject": "x", "body": "y" * 30}).status_code == 400
    statuses = {t["id"]: t["status"] for t in client.get("/api/flightbridge/templates").json()}
    assert statuses[good["id"]] == "approved"


def test_webhook_requires_bearer_secret_and_dedupes(app_and_db, monkeypatch):
    client, conn, *_ = app_and_db
    monkeypatch.setenv("FB_HOSTINGER_WEBHOOK_SECRET", "s3cret")
    body = '{"event":"message.received","uid":42}'
    assert client.post("/api/flightbridge/webhooks/hostinger", content=body).status_code == 401
    assert client.post("/api/flightbridge/webhooks/hostinger", content=body, headers={"Authorization": "Bearer wrong"}).status_code == 401
    for _ in range(2):
        assert client.post("/api/flightbridge/webhooks/hostinger", content=body,
                           headers={"Authorization": "Bearer s3cret", "Content-Type": "application/json"}).status_code == 200
    assert conn.execute("SELECT count(*) FROM flightbridge.webhook_event WHERE payload->>'uid'='42'").fetchone()[0] == 1


def test_webhook_refused_when_secret_not_configured(app_and_db, monkeypatch):
    client, *_ = app_and_db
    monkeypatch.delenv("FB_HOSTINGER_WEBHOOK_SECRET", raising=False)
    assert client.post("/api/flightbridge/webhooks/hostinger", content="{}", headers={"Authorization": "Bearer "}).status_code == 401


def test_inbox_metrics_settings(app_and_db):
    client, *_ = app_and_db
    assert isinstance(client.get("/api/flightbridge/inbox").json(), list)
    m = client.get("/api/flightbridge/metrics").json()
    assert "response_rate" in m and "opens" not in m
    assert client.post("/api/flightbridge/settings/followups", json={"days": [9, 4]}).status_code == 400
    assert client.post("/api/flightbridge/settings/followups", json={"days": [3, 7, 14]}).json()["followup_schedule_days"] == [3, 7, 14]
    assert client.get("/api/flightbridge/settings").json()["followup_schedule_days"] == [3, 7, 14]
