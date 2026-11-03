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


def test_researcher_role_can_review_but_not_approve(app_and_db):
    client, conn, who, admin, sales = app_and_db
    # Admin grants the research role to the Sales employee.
    r = client.post(f"/api/flightbridge/team/{sales}/role", json={"role": "researcher"})
    assert r.status_code == 200
    assert any(m["id"] == sales and m["effective_role"] == "researcher" for m in client.get("/api/flightbridge/team").json())
    task, _, org = _seed_task(conn)
    ra = conn.execute("""INSERT INTO flightbridge.regulatory_approval (org_id, authority_code, classification, status, source_url,
                          checked_at, next_check_due) VALUES (%s,'FAA','PART141_FAA','listed_in_register','https://faa.example',
                          now(), now()) RETURNING id""", (org,)).fetchone()[0]
    who["emp"] = {"id": sales, "department": "Sales", "name": "FB Sales"}
    try:
        assert client.get("/api/flightbridge/me").json()["role"] == "researcher"
        assert client.get("/api/flightbridge/summary").status_code == 200
        lst = client.get("/api/flightbridge/schools", params={"q": "Route Test"}).json()
        assert any(s["id"] == org for s in lst)
        det = client.get(f"/api/flightbridge/schools/{org}").json()
        assert det["regulatory"][0]["status"] == "listed_in_register" and det["contacts"]
        assert client.post(f"/api/flightbridge/schools/{org}/regulatory/{ra}/verify").json()["status"] == "verified_by_human"
        assert client.post(f"/api/flightbridge/schools/{org}/review", json={"decision": "rejected"}).status_code == 400
        assert client.post(f"/api/flightbridge/schools/{org}/review",
                           json={"decision": "rejected", "reason": "Helicopter only"}).status_code == 200
        # Admin-only actions are refused.
        assert client.post(f"/api/flightbridge/approvals/{task}/decision", json={"action": "approve"}).status_code == 403
        assert client.post("/api/flightbridge/kill-switch", json={"engaged": False}).status_code == 403
        assert client.get("/api/flightbridge/team").status_code == 403
        assert client.post(f"/api/flightbridge/team/{sales}/role", json={"role": "admin"}).status_code == 403
    finally:
        who["emp"] = {"id": admin, "department": "Admin"}
    hist = client.get(f"/api/flightbridge/schools/{org}").json()["history"]
    assert {"school_rejected", "regulatory_verified_by_human"} <= {h["action"] for h in hist}
    assert client.post(f"/api/flightbridge/team/{sales}/role", json={"role": None}).status_code == 200
    who["emp"] = {"id": sales, "department": "Sales"}
    try:
        assert client.get("/api/flightbridge/me").status_code == 403
    finally:
        who["emp"] = {"id": admin, "department": "Admin"}


def test_review_refuses_schools_in_conversation(app_and_db):
    client, conn, *_ = app_and_db
    org = conn.execute("INSERT INTO flightbridge.organisation (name, country, status) VALUES ('Busy Aero','GB','contacted') "
                       "RETURNING id").fetchone()[0]
    assert client.post(f"/api/flightbridge/schools/{org}/review", json={"decision": "qualified"}).status_code == 409


def test_cors_allows_flightbridge_origins_only(app_and_db):
    client, *_ = app_and_db
    for origin, ok in [("https://flying.weoneaviation.in", True),
                       ("https://flightbridge-ai-abc123-weone404s-projects.vercel.app", True),
                       ("https://flightbridge-ai-abc123-someone-else.vercel.app", False),
                       ("https://evil.example", False)]:
        r = client.options("/api/flightbridge/me", headers={"Origin": origin, "Access-Control-Request-Method": "GET"})
        assert (r.headers.get("access-control-allow-origin") == origin) is ok, origin


def test_regions_tree_and_region_filter(app_and_db):
    client, conn, *_ = app_and_db
    conn.execute("INSERT INTO flightbridge.organisation (name, country, region, status) VALUES "
                 "('Wales Aero', 'GB', 'Wales', 'research_pending'), ('Scot Aero', 'GB', 'Scotland', 'needs_human_review')")
    tree = client.get("/api/flightbridge/regions").json()
    gb = next(c for c in tree if c["country"] == "GB")
    regs = {r["region"]: r for r in gb["regions"]}
    assert regs["Wales"]["total"] >= 1 and regs["Scotland"]["needs_look"] >= 1
    names = [s["name"] for s in client.get("/api/flightbridge/schools", params={"country": "GB", "region": "Wales"}).json()]
    assert "Wales Aero" in names and "Scot Aero" not in names


def test_run_now_queue_dedupes_and_autopilot_is_admin_only(app_and_db):
    client, conn, who, admin, sales = app_and_db
    org = conn.execute("INSERT INTO flightbridge.organisation (name, country, status) VALUES ('Queue Aero','GB','research_pending') "
                       "RETURNING id").fetchone()[0]
    r1 = client.post("/api/flightbridge/automation/run", json={"kind": "research_school", "org_id": str(org)}).json()
    r2 = client.post("/api/flightbridge/automation/run", json={"kind": "research_school", "org_id": str(org)}).json()
    assert r1["queued"] and r2["already_queued"]
    assert client.post("/api/flightbridge/automation/run", json={"kind": "research_school"}).status_code == 400
    st = client.get("/api/flightbridge/automation").json()
    assert any(j["org_name"] == "Queue Aero" and j["status"] == "queued" for j in st["jobs"])
    assert {"need_website", "need_research", "need_scoring"} <= set(st["backlog"])
    body = {"find_websites": True, "research": True, "qualify": True, "draft": False, "batch_size": 5}
    assert client.post("/api/flightbridge/automation/settings", json=body).status_code == 200
    client.post(f"/api/flightbridge/team/{sales}/role", json={"role": "researcher"})
    who["emp"] = {"id": sales, "department": "Sales"}
    try:
        assert client.post("/api/flightbridge/automation/settings", json=body).status_code == 403
        r = client.post("/api/flightbridge/automation/run", json={"kind": "find_websites"})   # researchers may queue work
        assert r.status_code == 200 and (r.json()["queued"] or r.json()["already_queued"])
    finally:
        who["emp"] = {"id": admin, "department": "Admin"}
        client.post(f"/api/flightbridge/team/{sales}/role", json={"role": None})


def test_integration_keys_saved_encrypted_and_never_returned(app_and_db, monkeypatch):
    client, conn, who, admin, sales = app_and_db
    from flightbridge import integrations
    monkeypatch.setattr(integrations, "check", lambda name, value, mailbox_token=None: (True, "Connected."))
    r = client.post("/api/flightbridge/integrations/google_places_api_key", json={"value": "  AIzaSyTESTKEY-wxyz  "})
    assert r.status_code == 200 and r.json()["last4"] == "wxyz" and r.json()["test_ok"] is True
    ct = conn.execute("SELECT ciphertext FROM flightbridge.integration_secret WHERE name='google_places_api_key'").fetchone()[0]
    assert "AIzaSy" not in ct
    st = client.get("/api/flightbridge/integrations").json()
    assert "AIzaSyTESTKEY" not in str(st)
    g = next(k for k in st["keys"] if k["name"] == "google_places_api_key")
    assert g["saved"] and g["last4"] == "wxyz" and g["last_test_ok"] is True
    from flightbridge import secrets
    assert secrets.get("google_places_api_key", __import__("os").environ["DATABASE_URL"]) == "AIzaSyTESTKEY-wxyz"
    assert client.post("/api/flightbridge/integrations/not_a_key", json={"value": "x"}).status_code == 404
    bad = client.post("/api/flightbridge/integrations-settings", json={"llm_provider": "openai"})
    assert bad.status_code == 400
    ok = client.post("/api/flightbridge/integrations-settings",
                     json={"engine_in_crm": True, "llm_provider": "groq", "llm_model": "", "inbound_source": "none"})
    assert ok.status_code == 200 and client.get("/api/flightbridge/integrations").json()["settings"]["llm_provider"] == "groq"
    client.post(f"/api/flightbridge/team/{sales}/role", json={"role": "researcher"})
    who["emp"] = {"id": sales, "department": "Sales"}
    try:
        assert client.get("/api/flightbridge/integrations").status_code == 403
        assert client.post("/api/flightbridge/integrations/groq_api_key", json={"value": "gsk_x"}).status_code == 403
    finally:
        who["emp"] = {"id": admin, "department": "Admin"}
        client.post(f"/api/flightbridge/team/{sales}/role", json={"role": None})
    assert client.delete("/api/flightbridge/integrations/google_places_api_key").json()["saved"] is False


def test_engine_runs_inside_the_crm_and_respects_the_switch(app_and_db, monkeypatch):
    client, conn, *_ = app_and_db
    import flightbridge_engine
    from flightbridge import automation
    monkeypatch.setattr(automation, "REGISTER_DIR", __import__("pathlib").Path("/nonexistent"))
    conn.execute("""INSERT INTO flightbridge.system_setting (key, value) VALUES ('integrations', '{"engine_in_crm": false}')
                    ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value""")
    from flightbridge import secrets
    secrets.configure(None)
    assert flightbridge_engine.run_cycle() is None                       # switched off in Settings
    conn.execute("UPDATE flightbridge.system_setting SET value='{\"engine_in_crm\": true}' WHERE key='integrations'")
    secrets.configure(None)
    out = flightbridge_engine.run_cycle("manual")
    assert out and out.get("run_id") and out["dry_run"] is True and out["outbound_enabled"] is False
    runner = conn.execute("SELECT runner FROM flightbridge.worker_run WHERE id=%s", (out["run_id"],)).fetchone()[0]
    assert runner == "crm-server"

    class FakeScheduler:
        def __init__(self): self.jobs = []
        def add_job(self, fn, trigger, **kw): self.jobs.append(kw["id"])
    sch = FakeScheduler()
    flightbridge_engine.register(sch)
    assert sch.jobs == ["flightbridge_cycle", "flightbridge_queue"]
