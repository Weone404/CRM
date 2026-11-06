// amazon-execute: runs ONE approved change right after someone approves it in the Change Queue.
// POST {id} with the signed-in user's token. The user must have access to the Amazon section.
// The change must already be approved (api_amz_approve): this function cannot approve anything,
// and svc_amz_claim lets exactly one caller run it. If the browser closes first, the 5-minute cron runs it.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { execute } from "../_shared/amazon_exec.ts";
import { asUser, cors, json, HttpError, loadApi, rpc, scrub } from "../_shared/amazon_deno.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  let secrets: Record<string, string> = {};
  try {
    const access = await asUser(req, "api_amz_access");
    if (!access?.can_view) throw new HttpError(403, "You do not have access to the Amazon section");
    const { id } = await req.json().catch(() => ({}));
    if (!/^[0-9a-f-]{36}$/.test(String(id ?? ""))) throw new HttpError(400, "Missing change id");
    const loaded = await loadApi();
    secrets = loaded.secrets;
    const result = await execute(rpc, loaded.api, secrets, id, { settleMs: 4000 });
    return json(req, 200, result);
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    const msg = scrub(e instanceof Error ? e.message : String(e), secrets);
    console.error("amazon-execute", msg);
    return json(req, status, { detail: e instanceof HttpError ? e.message : `Could not run the change: ${msg.slice(0, 200)}` });
  }
});
