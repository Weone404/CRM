// crm-leads: enquiries from the websites into the CRM.
//
// POST /crm-leads/ingest    Institute websites (weoneaviation.com/.in, pilotschool.in, ...). Public, called
//                           from the visitor's browser; same fields and answers as Render's /api/leads/ingest:
//                           { status: "created" | "duplicate", lead_id }
// POST /crm-leads/charter   bookmycharter.in server only. Header: Authorization: Bearer <charter token>.
//                           { status, lead_id, reference } or 422 { detail: { errors: {...} } }
// GET|POST /crm-leads/justdial/<secret>   JustDial lead push (migration 149). One secret link per JustDial listing, given to
//                           the JustDial account manager. Fields come as a query string, form or JSON (leadid, name, mobile,
//                           phone, email, category, city, area, ...). Always answers "RECEIVED" for a known link, so
//                           JustDial does not keep retrying; duplicates are handled in the database.
// verify_jwt is off: website visitors and JustDial have no CRM account; /charter and /justdial check their own secrets.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const WEBSITES = new Set([
  "https://www.weoneaviation.com", "https://weoneaviation.com",
  "https://www.weoneaviation.in", "https://weoneaviation.in",
  "https://www.pilotschool.in", "https://pilotschool.in",
  "https://www.bookmycharter.in", "https://bookmycharter.in",
  "https://crm.weoneaviation.in", "http://localhost:3000",
]);
const cors = (req: Request): Record<string, string> => {
  const o = req.headers.get("Origin") ?? "";
  return WEBSITES.has(o)
    ? { "Access-Control-Allow-Origin": o, "Access-Control-Allow-Headers": "content-type, authorization",
        "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" }
    : { "Vary": "Origin" };
};
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function readJson(req: Request): Promise<unknown> {
  const text = await req.text();
  if (text.length > 20000) throw new Error("too large");
  return JSON.parse(text);
}

async function ingest(req: Request): Promise<Response> {
  let body: unknown;
  try { body = await readJson(req); } catch { return json(req, 422, { detail: "Invalid JSON" }); }
  const { data, error } = await db.rpc("svc_ingest_website_lead", { payload: body });
  if (error) throw error;
  const d = data as Record<string, unknown>;
  if (d.error) return json(req, 422, { detail: d.error });
  return json(req, 200, d);
}

async function charter(req: Request): Promise<Response> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: ok, error: tErr } = await db.rpc("svc_charter_token_ok", { token });
  if (tErr) throw tErr;
  if (ok === null) return json(req, 503, { detail: "Charter token is not configured" });
  if (!ok) return json(req, 401, { detail: "Invalid charter token" });
  let body: unknown;
  try { body = await readJson(req); } catch { return json(req, 422, { detail: { errors: { body: "Expected a JSON object" } } }); }
  const { data, error } = await db.rpc("svc_ingest_charter_lead", { payload: body });
  if (error) throw error;
  const d = data as Record<string, unknown>;
  if (d.errors_json) return json(req, 422, { detail: { errors: JSON.parse(String(d.errors_json)) } });
  return json(req, 200, d);
}

async function justdial(req: Request, token: string): Promise<Response> {
  const text = (body: string, status = 200) => new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
  if (!/^[0-9a-f]{64}$/.test(token)) return text("Unknown link", 404);
  const data: Record<string, unknown> = {};
  new URL(req.url).searchParams.forEach((v, k) => { data[k] = v; });
  if (req.method === "POST") {
    const raw = await req.text();
    if (raw.length > 20000) return text("Too large", 413);
    const type = (req.headers.get("Content-Type") ?? "").toLowerCase();
    try {
      if (type.includes("json") || /^\s*[{[]/.test(raw)) {
        const j = JSON.parse(raw);
        const o = Array.isArray(j) ? j[0] : j;
        if (o && typeof o === "object") Object.assign(data, o);
      } else if (type.includes("multipart/form-data")) {
        const f = await new Response(raw, { headers: { "Content-Type": req.headers.get("Content-Type")! } }).formData();
        f.forEach((v, k) => { data[k] = String(v); });
      } else if (raw.trim()) {
        new URLSearchParams(raw).forEach((v, k) => { data[k] = v; });
      }
    } catch { /* keep what came in the query string */ }
  }
  const { data: res, error } = await db.rpc("svc_jd_ingest", { p_token: token, p_data: data });
  if (error) throw error;
  if ((res as Record<string, unknown>)?.error === "unknown") return text("Unknown link", 404);
  return text("RECEIVED");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  const path = new URL(req.url).pathname.replace(/^.*\/crm-leads/, "").replace(/\/+$/, "");
  try {
    if (req.method === "POST" && path === "/ingest") return await ingest(req);
    if (req.method === "POST" && path === "/charter") return await charter(req);
    const jd = /^\/justdial\/([^/]+)$/.exec(path);
    if (jd && (req.method === "GET" || req.method === "POST")) return await justdial(req, jd[1]);
    return json(req, 404, { detail: "Not found" });
  } catch (e) {
    console.error("crm-leads error", String(e));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
