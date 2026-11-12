// amazon-bridge: the ONLY door for the Live Claude helper on the owner's Mac Mini.
// POST with header x-bridge-token (made in CRM > Amazon > More > Settings > "Connect your Mac"; stored as a hash).
// Actions:
//   {action:"ping"}                                    -> heartbeat only
//   {action:"claim"}                                   -> {job, context} or {job:null}   (also marks the Mac online)
//   {action:"answer", id, answer, options?, drafts?}   -> saves the reply; drafts become pending Decisions
//   {action:"release", id, note}                       -> could not answer now (e.g. Claude usage limit); retried later
//   {action:"studio_claim"}                            -> next Studio photo job + short-lived links to its input photos
//   {action:"studio_file", id, sku, b64}               -> stores one result photo in the PRIVATE Studio bucket -> {path}
//   {action:"studio_done", id, ok, result?, error?, files?:[{kind, path, width, height, checks, score, meta}]} -> finishes the job
// The helper never sees Amazon keys, never approves, and can only draft listing/price/dispatch changes.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, cors, json, HttpError, rpc } from "../_shared/amazon_deno.ts";

const b64bytes = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const isImage = (b: Uint8Array) => (b[0] === 0xff && b[1] === 0xd8) || (b[0] === 0x89 && b[1] === 0x50);
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
        const drafts = Array.isArray(body.drafts) ? body.drafts.slice(0, 60) : null;   // names with a keyword: 2 per product
        const options = Array.isArray(body.options) ? body.options.slice(0, 40) : null;   // 5 suggestions, or up to 40 keyword ideas
        return json(req, 200, await rpc("svc_amz_bridge_answer", {
          p_id: id, p_answer: String(body.answer ?? "").slice(0, 8000), p_options: options, p_drafts: drafts, p_by: "mac" }));
      }
      case "release":
        if (!Number.isInteger(id) || id <= 0) throw new HttpError(400, "Missing message id");
        await rpc("svc_amz_bridge_release", { p_id: id, p_note: String(body.note ?? "").slice(0, 300) });
        return json(req, 200, { ok: true });
      case "studio_claim": {
        const r = await rpc("svc_amz_studio_claim");
        if (!r) return json(req, 200, { job: null });
        const inputs = [];
        for (const i of r.inputs || []) {
          const { data } = await admin.storage.from("amazon-studio").createSignedUrl(i.path, 900);
          inputs.push({ id: i.id, url: data?.signedUrl, ext: String(i.path).split(".").pop() });
        }
        return json(req, 200, { job: r.job, inputs });
      }
      case "studio_file": {                            // one result photo per request (keeps requests small)
        if (!Number.isInteger(id) || id <= 0) throw new HttpError(400, "Missing job id");
        if (typeof body.b64 !== "string" || body.b64.length > 21_000_000) throw new HttpError(413, "Photo too big");
        const bytes = b64bytes(body.b64);
        if (!isImage(bytes)) throw new HttpError(415, "Not a JPG/PNG");
        const png = bytes[0] === 0x89;
        const sku = String(body.sku || "").replace(/[^A-Za-z0-9._-]/g, "") || "x";
        const path = `${sku}/job${id}/${crypto.randomUUID()}.${png ? "png" : "jpg"}`;
        const { error } = await admin.storage.from("amazon-studio").upload(path, bytes, { contentType: png ? "image/png" : "image/jpeg" });
        if (error) throw new Error(error.message);
        return json(req, 200, { path, bytes: bytes.length });
      }
      case "studio_done": {
        if (!Number.isInteger(id) || id <= 0) throw new HttpError(400, "Missing job id");
        const files = (Array.isArray(body.files) ? body.files : []).slice(0, 4)
          .filter((f: any) => ["cutout", "main", "swatch"].includes(f?.kind) && typeof f.path === "string" && f.path.includes(`/job${id}/`))
          .map((f: any) => ({ kind: f.kind, path: f.path, width: f.width, height: f.height, bytes: f.bytes, checks: f.checks ?? [],
                              score: f.score ?? null, meta: f.meta ?? {} }));
        return json(req, 200, await rpc("svc_amz_studio_finish", { p_job: id, p_ok: body.ok !== false, p_result: body.result ?? {},
          p_error: body.error ? String(body.error).slice(0, 300) : null, p_files: files }));
      }
      default:
        throw new HttpError(400, "Unknown action");
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error("amazon-bridge", e instanceof Error ? e.message : String(e));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Bridge error" });
  }
});
