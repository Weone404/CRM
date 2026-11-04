// crm-attendance: machine-to-machine attendance endpoints (no browser, no user session).
//
// POST /crm-attendance/hikvision?token=...        Hikvision DS-K1T320EFWX terminal push (JSON or multipart).
//      Always answers 200 (except a bad token) so the device never retry-storms.
// POST /crm-attendance/ingest                      CCTV system feed. Header: Authorization: Bearer <device token>
// GET  /crm-attendance/partner/attendance/by-mobile?mobile=&month=YYYY-MM
//      Partner apps (e.g. DGCA prep). Header: Authorization: Bearer <partner token>
//
// Tokens live in Supabase Vault (crm_attendance_ingest_token / crm_partner_api_token) and are
// checked in the database; all writes go through service-role-only svc_* functions.
// verify_jwt is off: the device cannot send a Supabase JWT, and every route checks its own token.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// null -> token not configured (503), false -> wrong token (401)
async function tokenOk(kind: "device" | "partner", token: string): Promise<boolean | null> {
  const { data, error } = await db.rpc("svc_attendance_token_ok", { kind, token });
  if (error) throw error;
  return data as boolean | null;
}

function bearer(req: Request): string {
  return (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
}

// Hikvision sends application/json, or multipart/form-data (JSON in a part usually named "event_log").
async function parseHikvisionBody(req: Request): Promise<Record<string, unknown> | null> {
  const ctype = req.headers.get("content-type") ?? "";
  try {
    if (ctype.includes("application/json")) return await req.json();
    if (ctype.includes("form-data") || ctype.includes("multipart")) {
      const form = await req.formData();
      let raw: unknown = form.get("event_log");
      if (raw == null) {
        for (const v of form.values()) {
          if (typeof v === "string" && v.trim().startsWith("{")) { raw = v; break; }
        }
      }
      if (raw == null) { console.warn("hikvision: multipart without JSON part", [...form.keys()]); return null; }
      if (raw instanceof File) raw = await raw.text();
      return JSON.parse(String(raw));
    }
    const text = (await req.text()).trim();
    if (text.startsWith("{")) return JSON.parse(text);
    console.warn("hikvision: unsupported body", ctype, text.slice(0, 80));
    return null;
  } catch (e) {
    console.warn("hikvision: unparseable body", ctype, String(e));
    return null;
  }
}

// Device time: honour an explicit offset / Z; a bare local time is India time.
function deviceTime(raw: unknown): string | null {
  if (typeof raw !== "string" || !raw.trim()) return null;
  const s = raw.trim();
  const withZone = /(Z|[+-]\d{2}:?\d{2})$/i.test(s) ? s : `${s}+05:30`;
  const d = new Date(withZone);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

async function hikvision(req: Request, url: URL): Promise<Response> {
  const ok = await tokenOk("device", url.searchParams.get("token") ?? "");
  if (ok === null) return json(503, { detail: "Attendance token is not configured" });
  if (!ok) return json(401, { detail: "Invalid attendance token" });
  try {
    const payload = await parseHikvisionBody(req);
    if (!payload || typeof payload !== "object") return json(200, { status: "ignored", reason: "unparseable body" });
    const ev = (payload.AccessControllerEvent && typeof payload.AccessControllerEvent === "object"
      ? payload.AccessControllerEvent : {}) as Record<string, unknown>;
    if (String(ev.majorEventType) !== "5") {
      return json(200, { status: "ignored", reason: `majorEventType=${ev.majorEventType ?? "None"}` });
    }
    const emp = String(ev.employeeNoString ?? "").trim();
    if (!emp) return json(200, { status: "ignored", reason: "no employeeNoString" });
    const { data, error } = await db.rpc("svc_hik_punch", {
      emp,
      name: String(ev.name ?? "").trim(),
      att_status: String(ev.attendanceStatus ?? "").trim(),
      at: deviceTime(ev.dateTime ?? payload.dateTime),
    });
    if (error) throw error;
    console.log("hikvision", emp, JSON.stringify(data));
    return json(200, data);
  } catch (e) {
    console.error("hikvision: error", String(e));
    return json(200, { status: "error-ignored" });
  }
}

async function ingest(req: Request): Promise<Response> {
  const ok = await tokenOk("device", bearer(req));
  if (ok === null) return json(503, { detail: "Attendance token is not configured" });
  if (!ok) return json(401, { detail: "Invalid attendance token" });
  let body: unknown;
  try { body = await req.json(); } catch { return json(422, { detail: "Invalid JSON" }); }
  const { data, error } = await db.rpc("svc_cctv_ingest", { payload: body });
  if (error) return json(422, { detail: error.message });
  if ((data as Record<string, unknown>)?.error) return json(422, { detail: (data as Record<string, unknown>).error });
  return json(200, data);
}

async function partner(req: Request, url: URL): Promise<Response> {
  const ok = await tokenOk("partner", bearer(req));
  if (ok === null) return json(503, { detail: "Partner token is not configured" });
  if (!ok) return json(401, { detail: "Invalid partner token" });
  const { data, error } = await db.rpc("svc_partner_attendance", {
    mobile: url.searchParams.get("mobile") ?? "",
    month: url.searchParams.get("month"),
  });
  if (error) throw error;
  const d = data as Record<string, unknown>;
  if (d?.error) return json(Number(d.code) || 422, { detail: d.error });
  return json(200, d);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/crm-attendance/, "").replace(/\/+$/, "");
  try {
    if (req.method === "POST" && path === "/hikvision") return await hikvision(req, url);
    if (req.method === "POST" && path === "/ingest") return await ingest(req);
    if (req.method === "GET" && path === "/partner/attendance/by-mobile") return await partner(req, url);
    return json(404, { detail: "Not found" });
  } catch (e) {
    console.error("crm-attendance error", String(e));
    return json(500, { detail: "Something went wrong" });
  }
});
