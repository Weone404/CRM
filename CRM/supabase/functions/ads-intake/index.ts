// ads-intake: ADS-only entry point for enquiries that came from an ad (click ID or paid UTM).
// Organic enquiries keep using crm-leads; this function never touches them.
//
// POST /ads-intake/enquiry   Called from the visitor's browser on our websites.
//   Body: the form fields + attribution (gclid, gbraid, wbraid, fbclid, fbc, fbp, utm_*, referrer, landing_page,
//   page_url, first_touch, submission_id, elapsed_ms, consent{notice_version, marketing, ad_data_sharing}).
//   The pipeline comes from the website, never from the body: bookmycharter.in -> charter, others -> pilot_training.
//   200 { status: "created" | "duplicate", lead_id [, reference] }
//   409 { detail: "not_an_ad_enquiry" }  -> the site should send this enquiry to crm-leads instead
//   422 { detail } / { detail: { errors } } for invalid input (same shapes as crm-leads)
// verify_jwt is off: website visitors have no CRM account. The database function is service_role only.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const SITES: Record<string, "pilot_training" | "charter"> = {
  "https://www.weoneaviation.com": "pilot_training", "https://weoneaviation.com": "pilot_training",
  "https://www.weoneaviation.in": "pilot_training", "https://weoneaviation.in": "pilot_training",
  "https://www.pilotschool.in": "pilot_training", "https://pilotschool.in": "pilot_training",
  "https://www.bookmycharter.in": "charter", "https://bookmycharter.in": "charter",
};
const cors = (req: Request): Record<string, string> => {
  const o = req.headers.get("Origin") ?? "";
  return o in SITES
    ? { "Access-Control-Allow-Origin": o, "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" }
    : { "Vary": "Origin" };
};
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function enquiry(req: Request): Promise<Response> {
  const pipeline = SITES[req.headers.get("Origin") ?? ""];
  if (!pipeline) return json(req, 403, { detail: "Unknown website" });
  const text = await req.text();
  if (text.length > 20000) return json(req, 413, { detail: "Too large" });
  let body: unknown;
  try { body = JSON.parse(text); } catch { return json(req, 422, { detail: "Invalid JSON" }); }
  const { data, error } = await db.rpc("svc_ads_ingest_enquiry", { payload: body, pipeline });
  if (error) throw error;
  const d = data as Record<string, unknown>;
  if (d.error === "not_an_ad_enquiry") return json(req, 409, { detail: "not_an_ad_enquiry" });
  if (d.error) return json(req, 422, { detail: d.error });
  if (d.errors_json) return json(req, 422, { detail: { errors: JSON.parse(String(d.errors_json)) } });
  return json(req, 200, d);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  const path = new URL(req.url).pathname.replace(/^.*\/ads-intake/, "").replace(/\/+$/, "");
  try {
    if (req.method === "POST" && path === "/enquiry") return await enquiry(req);
    return json(req, 404, { detail: "Not found" });
  } catch (e) {
    console.error("ads-intake error", String(e));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
