// crm-auth: sign-in by login ID / phone / email + password, plus account provisioning.
//
// POST { action: "login", identifier, password }
//   -> { session: { access_token, refresh_token, expires_at, expires_in, token_type }, profile }
// POST { action: "provision", bootstrap_token }            (one-time, before any admin exists)
// POST { action: "provision" }  + Authorization: Bearer <Admin or Sales access token>
//   Creates a Supabase Auth account for every active employee / student without one.
//   Temporary password = their own mobile number (digits). An employee without a mobile
//   keeps their existing CRM password (bcrypt hash imported as-is).
// POST { action: "reset_password", person_type, person_id } + admin token
//   Resets that person's password back to their mobile number.
//
// verify_jwt is off for this function: login must work without a session, and every
// privileged action checks the caller itself (admin JWT or one-time bootstrap token).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const AUTH_EMAIL_DOMAIN = "users.crm.weoneaviation.in"; // internal sign-in addresses (never receive mail)

const ALLOWED_ORIGINS = new Set([
  "https://crm.weoneaviation.in",
  "https://crm-pi-self.vercel.app",
  "https://flying.weoneaviation.in",
  "http://localhost:3000",
  "http://localhost:5173",
]);

// Vercel preview deployments of the `crm` project (team weone404s-projects).
const VERCEL_PREVIEW = /^https:\/\/crm-[a-z0-9-]+-weone404s-projects\.vercel\.app$/;

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) || VERCEL_PREVIEW.test(origin) ? origin : "https://crm.weoneaviation.in",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json" },
  });
}

const admin: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

async function callerDepartment(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token || token === ANON_KEY) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  const { data: prof } = await admin.rpc("svc_person_profile", { auth_id: data.user.id });
  return Array.isArray(prof) && prof[0]?.person_type === "employee" ? (prof[0]?.department ?? null) : null;
}
async function callerIsAdmin(req: Request): Promise<boolean> {
  return (await callerDepartment(req)) === "Admin";
}

// Mobile number -> temporary password: last 10 digits (or all digits if fewer).
function tempPassword(phoneDigits: string | null): string | null {
  if (!phoneDigits) return null;
  const d = phoneDigits.replace(/\D/g, "");
  if (d.length < 6) return null; // Supabase Auth minimum password length
  return d.length > 10 ? d.slice(-10) : d;
}

async function login(req: Request, body: Record<string, unknown>): Promise<Response> {
  const identifier = String(body.identifier ?? "").trim();
  const password = String(body.password ?? "");
  if (!identifier || !password) return json(req, 400, { error: "Enter your login ID / phone / email and password." });

  const { data: allowed } = await admin.rpc("svc_login_check", { identifier });
  if (allowed === false) {
    return json(req, 429, { error: "Too many failed attempts. Try again in 15 minutes." });
  }

  const { data: matches, error } = await admin.rpc("svc_resolve_login", { identifier });
  if (error) return json(req, 500, { error: "Login is temporarily unavailable." });
  const rows = (matches ?? []) as Array<{ auth_email: string; person_type: string; person_id: string }>;

  const generic = { error: "Incorrect login details." };
  if (rows.length !== 1) {
    await admin.rpc("svc_login_record", { identifier, ok: false });
    // Same message whether the account exists or not.
    return json(req, 401, rows.length > 1
      ? { error: "This phone number matches more than one account. Use your login ID instead." }
      : generic);
  }

  const anonClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: signIn, error: signErr } = await anonClient.auth.signInWithPassword({
    email: rows[0].auth_email,
    password,
  });
  if (signErr || !signIn.session) {
    await admin.rpc("svc_login_record", { identifier, ok: false });
    return json(req, 401, generic);
  }
  await admin.rpc("svc_login_record", { identifier, ok: true });

  const { data: prof } = await admin.rpc("svc_person_profile", { auth_id: signIn.user!.id });
  const s = signIn.session;
  return json(req, 200, {
    session: {
      access_token: s.access_token,
      refresh_token: s.refresh_token,
      expires_at: s.expires_at,
      expires_in: s.expires_in,
      token_type: s.token_type,
    },
    profile: Array.isArray(prof) ? prof[0] ?? null : null,
  });
}

async function provision(req: Request, body: Record<string, unknown>): Promise<Response> {
  // Admin, or Sales (who add students): only creates missing logins, never changes existing ones.
  const dept = await callerDepartment(req);
  let authorised = dept === "Admin" || dept === "Sales";
  if (!authorised && typeof body.bootstrap_token === "string") {
    const { data } = await admin.rpc("svc_use_bootstrap_token", { token: body.bootstrap_token });
    authorised = data === true;
  }
  if (!authorised) return json(req, 403, { error: "Admin or Sales only." });

  const { data: people, error } = await admin.rpc("svc_people_to_provision");
  if (error) return json(req, 500, { error: error.message });

  const report = { created: 0, skipped: [] as Array<{ type: string; name: string; reason: string }>, failed: [] as Array<{ type: string; name: string; reason: string }> };
  for (const p of (people ?? []) as Array<{ person_type: string; person_id: string; name: string; email: string | null; phone_digits: string | null; password_hash: string | null }>) {
    const email = p.person_type === "employee" && p.email
      ? p.email
      : `${p.person_type === "employee" ? "emp" : "stu"}.${p.person_id}@${AUTH_EMAIL_DOMAIN}`;
    const pw = tempPassword(p.phone_digits);
    const attrs: Record<string, unknown> = {
      email,
      email_confirm: true,
      app_metadata: { crm_person_type: p.person_type, crm_person_id: p.person_id },
      user_metadata: { name: p.name },
    };
    if (pw) attrs.password = pw;
    else if (p.password_hash && /^\$2[aby]\$/.test(p.password_hash)) attrs.password_hash = p.password_hash;
    else { report.skipped.push({ type: p.person_type, name: p.name, reason: "no mobile number and no existing password" }); continue; }

    let { data: created, error: cErr } = await admin.auth.admin.createUser(attrs);
    if (cErr && /already|exists|registered/i.test(cErr.message)) {
      // An auth user with this email exists already (e.g. re-run): link it instead.
      const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const existing = list?.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
      if (existing) { created = { user: existing } as typeof created; cErr = null; }
    }
    if (cErr || !created?.user) { report.failed.push({ type: p.person_type, name: p.name, reason: cErr?.message ?? "unknown" }); continue; }
    const { error: lErr } = await admin.rpc("svc_link_auth_user", { person_type: p.person_type, person_id: p.person_id, auth_id: created.user.id });
    if (lErr) { report.failed.push({ type: p.person_type, name: p.name, reason: lErr.message }); continue; }
    report.created++;
  }
  return json(req, 200, report);
}

async function resetPassword(req: Request, body: Record<string, unknown>): Promise<Response> {
  if (!(await callerIsAdmin(req))) return json(req, 403, { error: "Admin only." });
  const table = body.person_type === "student" ? "student" : "employee";
  const phoneCol = table === "student" ? "mobile" : "phone";
  const { data: row, error } = await admin.from(table).select(`auth_user_id, ${phoneCol}`).eq("id", String(body.person_id ?? "")).maybeSingle();
  if (error || !row?.auth_user_id) return json(req, 404, { error: "No login account for this person." });
  const pw = tempPassword(String((row as Record<string, unknown>)[phoneCol] ?? ""));
  if (!pw) return json(req, 400, { error: "This person has no valid mobile number to reset to." });
  const { error: uErr } = await admin.auth.admin.updateUserById(row.auth_user_id as string, { password: pw });
  if (uErr) return json(req, 500, { error: uErr.message });
  return json(req, 200, { ok: true, message: "Password reset to their mobile number." });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "Use POST." });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(req, 400, { error: "Invalid JSON." }); }
  try {
    switch (body.action) {
      case "login": return await login(req, body);
      case "provision": return await provision(req, body);
      case "reset_password": return await resetPassword(req, body);
      default: return json(req, 400, { error: "Unknown action." });
    }
  } catch (e) {
    console.error("crm-auth error", e);
    return json(req, 500, { error: "Something went wrong. Please try again." });
  }
});
