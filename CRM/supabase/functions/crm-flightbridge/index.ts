// crm-flightbridge: the parts of the FlightBridge tab that need a secret or an outside service.
//
//   POST /crm-flightbridge/integrations/{name}        save + test an API key   (signed-in FlightBridge admin)
//   POST /crm-flightbridge/integrations/{name}/test   test the saved key       (signed-in FlightBridge admin)
//   POST /crm-flightbridge/areas                      add an area by name; Google finds the coordinates (admin)
//   POST /crm-flightbridge/templates/generate         "Write with AI": 3-5 checked email-template versions (admin)
//   POST /crm-flightbridge/webhooks/hostinger         Hostinger mailbox webhook (Authorization: Bearer <secret>)
//
// Edge Function secrets:
//   FB_SECRETS_KEY                 the same value the engine uses (Render: FB_SECRETS_KEY, or SECRET_KEY if that
//                                  was never set). Keys are encrypted with it exactly like flightbridge/secrets.py,
//                                  so the engine on the Mac Mini can read them.
//   FB_HOSTINGER_WEBHOOK_SECRET    only if the Hostinger webhook is used.
// Permission checks run in the database with the caller's own token (api_fb_integration_check / api_fb_area_*);
// only reading/writing the encrypted key uses the service role. Key values are never logged or returned.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { fernetDecrypt, fernetEncrypt, last4 } from "./fernet.ts";
import { type Brief, groqJson, morePrompt, parseVariants, prompt, repairPrompt, styleIssues, SYSTEM, type Variant } from "./templates.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const ALLOWED = new Set([
  "https://crm.weoneaviation.in", "https://crm-pi-self.vercel.app",
  "http://localhost:3000", "http://localhost:5173",
]);
const PREVIEW = /^https:\/\/crm-[a-z0-9-]+-weone404s-projects\.vercel\.app$/;
const cors = (req: Request) => {
  const o = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED.has(o) || PREVIEW.test(o) ? o : "https://crm.weoneaviation.in",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
};
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

// Calls an API function as the signed-in user; PTnnn errors become HTTP nnn.
async function asUser(req: Request, fn: string, args: Record<string, unknown>) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) throw new HttpError(401, "Could not validate credentials");
  const client = createClient(URL_, ANON, {
    global: { headers: { Authorization: auth } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const m = /^PT(\d{3})$/.exec(error.code ?? "");
    const status = m ? Number(m[1]) : (/JWT/i.test(error.message) ? 401 : 500);
    throw new HttpError(status, status === 401 ? "Could not validate credentials" : error.message);
  }
  return data;
}

const ENV_NAMES: Record<string, string> = {
  google_places_api_key: "GOOGLE_PLACES_API_KEY", groq_api_key: "GROQ_API_KEY", gemini_api_key: "GEMINI_API_KEY",
  hostinger_mail_api_token: "HOSTINGER_MAIL_API_TOKEN", hostinger_mailbox_resource_id: "HOSTINGER_MAILBOX_RESOURCE_ID",
  tavily_api_key: "TAVILY_API_KEY",
};
const master = () => Deno.env.get("FB_SECRETS_KEY") || "";

// Same lookup order as flightbridge/secrets.get: environment first, then the encrypted value saved in the app.
async function getSecret(name: string): Promise<string | null> {
  const env = Deno.env.get(ENV_NAMES[name]);
  if (env) return env;
  if (!master()) return null;
  const { data, error } = await admin.rpc("svc_fb_secret_get", { p_name: name });
  if (error || !data) return null;
  return await fernetDecrypt(master(), data as string);
}

// ---------------------------------------------------------------- live key checks (port of flightbridge/integrations.py)
const HOSTINGER = "https://api.mail.hostinger.com";
const HOSTINGER_UA = "hostinger_mail_api-python/1.18.2";   // the default UA is blocked by Cloudflare
const PLACES = "https://places.googleapis.com/v1/places:searchText";
const COUNTRY: Record<string, string> = { GB: "United Kingdom", US: "United States", CA: "Canada", AU: "Australia",
  ES: "Spain", IE: "Ireland", NZ: "New Zealand", IN: "India" };

class PlacesError extends Error {}

async function placesSearch(key: string | null, textQuery: string, fieldMask: string) {
  if (!key) throw new PlacesError("GOOGLE_PLACES_API_KEY is not set");
  const r = await fetch(PLACES, {
    method: "POST", signal: AbortSignal.timeout(20000),
    headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": fieldMask, "Content-Type": "application/json" },
    body: JSON.stringify({ textQuery, pageSize: 5 }),
  });
  if (r.status !== 200) {
    const text = await r.text();
    let msg: string;
    try { msg = JSON.parse(text)?.error?.message ?? ""; } catch { msg = text.slice(0, 200); }
    throw new PlacesError(`Places API ${r.status}: ${String(msg).slice(0, 300)}`);
  }
  return ((await r.json())?.places ?? []) as Array<Record<string, any>>;
}

function explainGoogle(msg: string): string {
  if (msg.includes("has not been used in project") || msg.includes("SERVICE_DISABLED") || msg.includes("is disabled")) {
    return "Key works, but Places API (New) is not enabled in its Google Cloud project. Enable it, then test again.";
  }
  if (msg.includes("API key not valid") || msg.includes("API_KEY_INVALID")) {
    return "Google says this key is not valid. Copy it again from Google Cloud > Credentials.";
  }
  if (msg.toLowerCase().includes("referer") || msg.toLowerCase().includes("restricted")) {
    return "The key is restricted (website/app restriction). Allow server use or set restriction to Places API (New) only.";
  }
  return msg.slice(0, 300);
}

const get = (url: string, headers: Record<string, string>) => fetch(url, { headers, signal: AbortSignal.timeout(15000) });

async function check(name: string, value: string, mailboxToken: string | null): Promise<[boolean, string]> {
  try {
    if (name === "google_places_api_key") {
      try {
        await placesSearch(value, "flight training school flight training United Kingdom", "places.id");
        return [true, "Connected. Website search can run."];
      } catch (e) {
        if (e instanceof PlacesError) return [false, explainGoogle(e.message)];
        throw e;
      }
    }
    if (name === "groq_api_key") {
      const r = await get("https://api.groq.com/openai/v1/models", { Authorization: `Bearer ${value}` });
      return r.ok ? [true, "Connected to Groq (free tier)."] : [false, `Groq refused the key (HTTP ${r.status}).`];
    }
    if (name === "gemini_api_key") {
      const r = await get("https://generativelanguage.googleapis.com/v1beta/models", { "x-goog-api-key": value });
      return r.ok ? [true, "Connected to Gemini (free tier)."] : [false, `Gemini refused the key (HTTP ${r.status}).`];
    }
    if (name === "tavily_api_key") {     // one basic search = 1 of the 1,000 free monthly credits
      const r = await fetch("https://api.tavily.com/search", {
        method: "POST", signal: AbortSignal.timeout(20000),
        headers: { Authorization: `Bearer ${value}`, "Content-Type": "application/json" },
        body: JSON.stringify({ query: "flight school", search_depth: "basic", max_results: 1 }),
      });
      return r.ok ? [true, "Connected to Tavily (free 1,000 searches a month)."] : [false, `Tavily refused the key (HTTP ${r.status}).`];
    }
    if (name === "hostinger_mail_api_token") {
      const r = await get(`${HOSTINGER}/api/v1/me`, { Authorization: `Bearer ${value}`, Accept: "application/json", "User-Agent": HOSTINGER_UA });
      return r.ok ? [true, "Connected to Hostinger Mail."] : [false, `Hostinger refused the token (HTTP ${r.status}).`];
    }
    if (name === "hostinger_mailbox_resource_id") {
      if (!mailboxToken) return [false, "Save the Hostinger API token first, then test the mailbox."];
      const r = await get(`${HOSTINGER}/api/v1/mailboxes/${encodeURIComponent(value)}/folders`,
        { Authorization: `Bearer ${mailboxToken}`, Accept: "application/json", "User-Agent": HOSTINGER_UA });
      return r.ok ? [true, "Mailbox found. Replies can be read."] : [false, `Mailbox not found for this token (HTTP ${r.status}).`];
    }
    return [false, "Unknown key."];
  } catch (e) {
    const kind = (e as Error)?.name === "TimeoutError" ? "Timeout" : "ConnectionError";
    return [false, `Could not reach the service (${kind}). Try again.`];
  }
}

async function saveKey(req: Request, name: string): Promise<Response> {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { throw new HttpError(422, "value is required"); }
  const { employee_id } = await asUser(req, "api_fb_integration_check", { p_name: name }) as { employee_id: string };
  if (typeof body?.value !== "string" || body.value.length < 1) throw new HttpError(422, "value is required");
  if (body.value.length > 4000) throw new HttpError(422, "value must be at most 4000 characters");
  const value = body.value.trim();
  if (!value) throw new HttpError(400, "enter a key (up to 4000 characters)");
  if (!master()) throw new HttpError(500, "FB_SECRETS_KEY must be set (Supabase > Edge Functions > Secrets) to store API keys");
  const token = name === "hostinger_mailbox_resource_id" ? await getSecret("hostinger_mail_api_token") : null;
  const [ok, msg] = await check(name, value, token);
  const l4 = last4(value);
  const { error } = await admin.rpc("svc_fb_secret_save", {
    p_name: name, p_ciphertext: await fernetEncrypt(master(), value), p_last4: l4, p_emp: employee_id, p_ok: ok, p_msg: msg,
  });
  if (error) throw new Error("save failed: " + error.message);
  return json(req, 200, { name, saved: true, last4: l4, test_ok: ok, message: msg });
}

async function testKey(req: Request, name: string): Promise<Response> {
  await asUser(req, "api_fb_integration_check", { p_name: name });
  const value = await getSecret(name);
  if (!value) throw new HttpError(400, "No key saved (or it can't be read any more - enter it again)");
  const [ok, msg] = await check(name, value, await getSecret("hostinger_mail_api_token"));
  const { error } = await admin.rpc("svc_fb_secret_tested", { p_name: name, p_ok: ok, p_msg: msg });
  if (error) throw new Error("test record failed: " + error.message);
  return json(req, 200, { name, test_ok: ok, message: msg });
}

// Add an area typed by name: check it (as the user), ask Google for its coordinates, then add it (as the user).
async function addArea(req: Request): Promise<Response> {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { throw new HttpError(422, "Invalid JSON"); }
  const a = await asUser(req, "api_fb_area_check", { p_data: body }) as Record<string, any>;
  let lat = a.lat, lng = a.lng;
  if (lat == null || lng == null) {
    let found: [number, number] | null = null;
    try {
      const country = String(a.country);
      const places = await placesSearch(await getSecret("google_places_api_key"),
        `${a.name}, ${a.region}, ${COUNTRY[country] ?? country}`, "places.location");
      const loc = places.find((p) => p.location)?.location;
      if (loc) found = [loc.latitude, loc.longitude];
    } catch (e) {
      const why = e instanceof PlacesError ? e.message : "Google could not be reached";
      throw new HttpError(400, `Couldn't locate the area with Google: ${why}. Add the Google Places key in Settings, or enter coordinates.`);
    }
    if (!found) throw new HttpError(400, "Google couldn't find that place. Check the spelling or enter coordinates.");
    [lat, lng] = found;
  }
  const out = await asUser(req, "api_fb_area_add", { p_data: { ...body, lat, lng } });
  return json(req, 200, out);
}

// "Write with AI": permission, daily limit and the remembered brief are handled in the database (as the user); the
// Groq key is read here; every version is checked with the template rules, and broken ones are sent back once.
async function checkVariants(req: Request, vs: Variant[]): Promise<{ ok: boolean; errors: string[]; warnings: string[] }[]> {
  const items: { subject: string; body: string }[] = [];
  for (const v of vs) {
    for (const s of v.subjects) items.push({ subject: s, body: v.body });
    items.push({ subject: v.followup_subject || v.subjects[0], body: v.followup_body || v.body });
  }
  const res = await asUser(req, "api_fb_template_check_many", { p_items: items }) as { ok: boolean; errors: string[]; warnings: string[] }[];
  let k = 0;
  return vs.map((v) => {
    const parts = res.slice(k, k + v.subjects.length + 1);
    k += v.subjects.length + 1;
    const errors = [...new Set(parts.flatMap((p) => p.errors))];
    const warnings = [...new Set(parts.flatMap((p) => p.warnings))];
    if (!v.followup_body) errors.push("no follow-up was written");
    return { ok: errors.length === 0, errors, warnings };
  });
}

async function generateTemplates(req: Request): Promise<Response> {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { throw new HttpError(422, "Invalid JSON"); }
  const brief = await asUser(req, "api_fb_template_generate_start", { p_data: body }) as Brief;
  const key = await getSecret("groq_api_key");
  if (!key) throw new HttpError(400, "Save the Groq key in FlightBridge AI > Settings first");
  let first;
  try { first = await groqJson(key, SYSTEM, prompt(brief), 1200 * brief.count + 2500); } catch (e) { throw new HttpError(502, String((e as Error).message)); }
  const variants = parseVariants(first.data, brief.count);
  if (!variants.length) throw new HttpError(502, "The AI writer returned nothing usable. Try again.");
  if (variants.length < brief.count) {          // the model sometimes writes fewer than asked: ask once for the rest
    try {
      const n = brief.count - variants.length;
      variants.push(...parseVariants((await groqJson(key, SYSTEM, morePrompt(brief, variants, n), 1200 * n + 2500)).data, n));
    } catch (e) { console.error("more versions failed", String(e)); }
  }
  let checks = await checkVariants(req, variants);
  const bad = variants.map((v, i) => ({ v, i, issues: [...checks[i].errors, ...styleIssues(v, brief)] })).filter((x) => x.issues.length);
  if (bad.length) {
    try {
      const fixed = parseVariants((await groqJson(key, SYSTEM, repairPrompt(brief, bad), 1200 * bad.length + 2500)).data, bad.length);
      fixed.forEach((f, j) => { variants[bad[j].i] = f; });
      checks = await checkVariants(req, variants);
    } catch (e) { console.error("template repair failed", String(e)); }
  }
  return json(req, 200, { model: first.model, variants: variants.map((v, i) => ({ ...v, check: checks[i], style: styleIssues(v, brief) })) });
}

function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// Hostinger authenticates deliveries with "Authorization: Bearer <secret>". The event is stored once (dedupe on the
// payload hash) and the engine re-reads the mailbox over the API; the payload itself is never trusted for content.
async function hostingerWebhook(req: Request): Promise<Response> {
  const secret = Deno.env.get("FB_HOSTINGER_WEBHOOK_SECRET") ?? "";
  if (!secret || !safeEqual(req.headers.get("Authorization") ?? "", `Bearer ${secret}`)) throw new HttpError(401, "unauthorized");
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.length > 256_000) throw new HttpError(413, "payload too large");
  let payload: unknown;
  try { payload = raw.length ? JSON.parse(new TextDecoder().decode(raw)) : {}; } catch { throw new HttpError(400, "invalid JSON"); }
  const key = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", raw)), (b) => b.toString(16).padStart(2, "0")).join("");
  const { error } = await admin.rpc("svc_fb_webhook", { p_key: key, p_payload: payload });
  if (error) throw new Error("webhook store failed: " + error.message);
  return json(req, 200, { ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  const path = new URL(req.url).pathname.replace(/^.*\/crm-flightbridge/, "").replace(/\/+$/, "");
  try {
    if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
    let m: RegExpExecArray | null;
    if ((m = /^\/integrations\/([a-z_]+)\/test$/.exec(path))) return await testKey(req, m[1]);
    if ((m = /^\/integrations\/([a-z_]+)$/.exec(path))) return await saveKey(req, m[1]);
    if (path === "/areas") return await addArea(req);
    if (path === "/templates/generate") return await generateTemplates(req);
    if (path === "/webhooks/hostinger") return await hostingerWebhook(req);
    return json(req, 404, { detail: "Not found" });
  } catch (e) {
    if (e instanceof HttpError) return json(req, e.status, { detail: e.message });
    console.error("crm-flightbridge error", path, String(e));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
