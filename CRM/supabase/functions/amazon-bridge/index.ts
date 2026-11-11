// amazon-bridge: the ONLY door for the Live Claude helper on the owner's Mac Mini.
// POST with header x-bridge-token (made in CRM > Amazon > More > Settings > "Connect your Mac"; stored as a hash).
// Actions:
//   {action:"ping"}                                    -> heartbeat only
//   {action:"claim"}                                   -> {job, context} or {job:null}   (also marks the Mac online)
//   {action:"answer", id, answer, options?, drafts?}   -> saves the reply; drafts become pending Decisions
//   {action:"release", id, note}                       -> could not answer now (e.g. Claude usage limit); retried later
// The helper never sees Amazon keys, never approves, and can only draft listing/price/dispatch changes.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cors, json, HttpError, rpc } from "../_shared/amazon_deno.ts";
import { buildPrompt } from "../_shared/claude_prompt.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  try {
    const token = req.headers.get("x-bridge-token") ?? "";
    if (!(await rpc("svc_amz_bridge_ok", { p_token: token }))) throw new HttpError(401, "Mac is not connected (token missing or revoked)");
    const body = await req.json().catch(() => ({}));
    const id = Number(body.id);
    switch (body.action) {
      case "ping":                                     // heartbeat while Claude is thinking
        return json(req, 200, { ok: true });
      case "claim": {
        const r = await rpc("svc_amz_bridge_claim", { p_by: "mac" });
        if (!r) return json(req, 200, { job: null });
        return json(req, 200, { ...r, prompt: buildPrompt(r.job, r.context) });
      }
      case "answer": {
        if (!Number.isInteger(id) || id <= 0) throw new HttpError(400, "Missing message id");
        const drafts = Array.isArray(body.drafts) ? body.drafts.slice(0, 30) : null;
        const options = Array.isArray(body.options) ? body.options.slice(0, 5) : null;
        return json(req, 200, await rpc("svc_amz_bridge_answer", {
          p_id: id, p_answer: String(body.answer ?? "").slice(0, 8000), p_options: options, p_drafts: drafts, p_by: "mac" }));
      }
      case "release":
        if (!Number.isInteger(id) || id <= 0) throw new HttpError(400, "Missing message id");
        await rpc("svc_amz_bridge_release", { p_id: id, p_note: String(body.note ?? "").slice(0, 300) });
        return json(req, 200, { ok: true });
      default:
        throw new HttpError(400, "Unknown action");
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error("amazon-bridge", e instanceof Error ? e.message : String(e));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Bridge error" });
  }
});
