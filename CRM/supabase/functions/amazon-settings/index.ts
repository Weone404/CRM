// amazon-settings: CRM > Amazon > Settings > Test Connection (Admin only).
// POST {action: "test"} with the signed-in user's token.
// Exchanges the saved refresh token, calls getMarketplaceParticipations, confirms Amazon.in, records the result.
// Saving keys is NOT done here: the browser calls api_amz_settings_save (Vault, write-only).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { testConnection, LwaError, TEST_FIX } from "../_shared/amazon.ts";
import { asUser, cors, json, HttpError, loadApi, rpc, scrub } from "../_shared/amazon_deno.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  let secrets: Record<string, string> = {};
  try {
    const access = await asUser(req, "api_amz_access");
    if (!access?.is_admin) throw new HttpError(403, "Only Admin can test the Amazon connection");
    const body = await req.json().catch(() => ({}));
    if (body.action !== "test") throw new HttpError(400, "Unknown action");

    let result;
    try {
      const loaded = await loadApi();
      secrets = loaded.secrets;
      result = await testConnection(loaded.api);
    } catch (e) {
      result = e instanceof LwaError ? { status: "Invalid client" as const, detail: e.message.includes("not set")
        ? "Save Client ID, Client Secret, Refresh Token and Seller ID first." : TEST_FIX["Invalid client"] }
        : { status: "Error" as const, detail: TEST_FIX["Error"] };
    }
    await rpc("svc_amz_record_test", { p_status: result.status, p_detail: result.detail });
    return json(req, 200, result);
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    console.error("amazon-settings", scrub(String(e), secrets));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Test failed" });
  }
});
