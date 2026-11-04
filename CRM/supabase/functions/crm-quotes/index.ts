// crm-quotes: builds a course quote PDF for a lead.
//
// POST /crm-quotes/generate   (signed-in Sales/Admin; Authorization: Bearer <user access token>)
//   body { lead_id, course_id, discount_percent?, installment_count?, down_payment? }
//   -> { id, quote_id }   The quote appears in the Outbox; its PDF is stored in the private "quotes" bucket.
//
// The quote is recorded with the caller's own token (so the database checks their role and does the
// maths); only the PDF upload uses the service role. If the PDF cannot be stored, the quote is removed.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";
import { buildQuotePdf, type Quote } from "./pdf.ts";

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

async function generate(req: Request): Promise<Response> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return json(req, 401, { detail: "Could not validate credentials" });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(req, 400, { detail: "Invalid JSON" }); }

  const asUser = createClient(URL_, ANON, {
    global: { headers: { Authorization: auth } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await asUser.rpc("api_quote_create", { p_data: body });
  if (error) {
    const m = /^PT(\d{3})$/.exec(error.code ?? "");
    const status = m ? Number(m[1]) : (/JWT/i.test(error.message) ? 401 : 500);
    return json(req, status, { detail: status === 401 ? "Could not validate credentials" : error.message });
  }
  const rec = data as { id: string; quote_id: string; quote: Quote };

  try {
    const pdf = await buildQuotePdf(rec.quote, { PDFDocument, rgb, StandardFonts });
    const path = `quotes/${rec.id}.pdf`;
    const up = await admin.storage.from("quotes").upload(path, pdf, { contentType: "application/pdf", upsert: true });
    if (up.error) throw up.error;
    const set = await admin.rpc("svc_quote_set_pdf", { p_id: rec.id, p_path: path });
    if (set.error) throw set.error;
  } catch (e) {
    console.error("quote pdf failed", rec.id, String(e));
    await admin.rpc("svc_quote_discard", { p_id: rec.id });
    return json(req, 500, { detail: "Could not create the quote PDF. Please try again." });
  }
  return json(req, 200, { id: rec.id, quote_id: rec.quote_id });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  const path = new URL(req.url).pathname.replace(/^.*\/crm-quotes/, "").replace(/\/+$/, "");
  try {
    if (req.method === "POST" && path === "/generate") return await generate(req);
    return json(req, 404, { detail: "Not found" });
  } catch (e) {
    console.error("crm-quotes error", String(e));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
