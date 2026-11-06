// Deno-only glue for the amazon-* Edge Functions: Supabase clients, CORS, caller checks.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { SpApi } from "./amazon.ts";

export const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
export const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const ALLOWED = new Set(["https://crm.weoneaviation.in", "https://crm-pi-self.vercel.app", "http://localhost:5173"]);
const PREVIEW = /^https:\/\/crm-[a-z0-9-]+-weone404\.vercel\.app$/;
export const cors = (req: Request) => {
  const o = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED.has(o) || PREVIEW.test(o) ? o : "https://crm.weoneaviation.in",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-token",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
};
export const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

// Calls an api_* function as the signed-in user (RLS + the function's own checks apply).
export async function asUser(req: Request, fn: string, args: Record<string, unknown> = {}) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) throw new HttpError(401, "Could not validate credentials");
  const client = createClient(URL_, ANON, { global: { headers: { Authorization: auth } },
    auth: { autoRefreshToken: false, persistSession: false } });
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const m = /^PT(\d{3})$/.exec(error.code ?? "");
    const status = m ? Number(m[1]) : (/JWT/i.test(error.message) ? 401 : 500);
    throw new HttpError(status, status === 401 ? "Could not validate credentials" : error.message);
  }
  return data;
}

export async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

export async function cronOk(req: Request) {
  const t = req.headers.get("x-cron-token");
  if (!t) return false;
  const { data } = await admin.rpc("svc_cron_token_ok", { token: t });
  return data === true;
}

// Secrets come from Vault through the service role; they never leave this function.
export async function loadApi(): Promise<{ api: SpApi; secrets: Record<string, string> }> {
  const secrets = (await rpc("svc_amz_secrets")) as Record<string, string>;
  const api = new SpApi({
    clientId: secrets.AMZ_LWA_CLIENT_ID, clientSecret: secrets.AMZ_LWA_CLIENT_SECRET, refreshToken: secrets.AMZ_REFRESH_TOKEN,
    endpoint: secrets.ENDPOINT, marketplaceId: secrets.MARKETPLACE_ID,
    log: (m) => console.log(m),   // messages contain paths and status codes only, never keys
  });
  return { api, secrets };
}

// Never let a key reach a log or a response.
export function scrub(s: string, secrets: Record<string, string> = {}) {
  let out = s;
  for (const v of Object.values(secrets)) if (v && v.length >= 8) out = out.split(v).join("••••");
  return out.replace(/Atz[ar]\|[A-Za-z0-9\-_.|]+/g, "Atz•|••••").replace(/amzn1\.application-oa2-client\.[a-z0-9]+/gi, "amzn1.••••");
}
