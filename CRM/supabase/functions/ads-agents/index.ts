// ads-agents: the ADS agents' only door into the CRM. Called by the ADS helper on the owner's Mac or the cloud runner
// (tools/ads-agents), never by a browser. Google Ads steps, and (migration 104) Meta Ads > Strategy steps. Separate from amazon-bridge: its own token (header x-ads-agents-token,
// only the SHA-256 is stored, migration 093) and its own queue (migration 094).
// Body: {action}
//   next     {meta?} -> {run, context} or {run: null}. Context includes Keyword Planner ideas saved by ads-sync (snapshot.keyword_ideas).
//            Helpers that send meta: true also get Meta strategy steps (meta_researcher / meta_strategist / meta_reviewer),
//            with the Meta context (37-month Insights, proven patterns); older helpers only get Google steps.
//   finish   {id, ok, output, summary?, error?} -> stores the result and queues the next step (code checks run in SQL).
//   release  {id, reason?} -> puts a step back (usage limit, shutdown).
//   ping     -> {ok: true}
// The agents never get Google or Meta credentials; approved operations are sent by ads-sync with Google's own pre-check first,
// and Meta plans are only written to the CRM (the owner creates them in Meta, paused, from Meta Ads > Strategy).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, rpc } from "../_shared/ads_deno.ts";
import { trimContext, trimMetaContext } from "../_shared/ads_agents_ctx.ts";
import { ADS_BUILD } from "../_shared/ads_meta.ts";

const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  // GET .../ads-agents/version: which build is deployed (CRM > Meta Ads > Setup checks it; nothing else is answered without the token)
  if (req.method === "GET" && new URL(req.url).pathname.endsWith("/version")) return reply(200, { build: ADS_BUILD });
  if (req.method !== "POST") return reply(405, { detail: "POST only" });
  try {
    const tok = req.headers.get("x-ads-agents-token") ?? "";
    const { data: okTok } = await admin.rpc("svc_ads_agents_token_ok", { p_token: tok });
    if (okTok !== true) return reply(401, { detail: "Bad or missing ADS agents token" });
    await admin.from("ads_config").upsert({ key: "agents_last_seen", value: new Date().toISOString() });
    let body: any = {};
    try { body = await req.json(); } catch { /* empty */ }
    switch (body.action) {
      case "ping":
        return reply(200, { ok: true });
      case "next": {
        const job = await rpc("svc_ads_agent_next2", { p_meta: body.meta === true }) as any;
        if (!job) return reply(200, { run: null });
        job.context = String(job.run?.role ?? "").startsWith("meta_") ? trimMetaContext(job.context) : trimContext(job.context);
        return reply(200, job);
      }
      case "finish": {
        const id = Number(body.id);
        if (!Number.isInteger(id)) return reply(422, { detail: "id is required" });
        const out = body.output && typeof body.output === "object" && !Array.isArray(body.output) ? body.output : null;
        const args = { p_id: id, p_ok: body.ok === true && !!out, p_output: out,
          p_summary: body.summary ? String(body.summary).slice(0, 500) : null, p_error: body.error ? String(body.error).slice(0, 900) : null };
        const m = await rpc("svc_ads_meta_agent_finish", args) as any;   // Meta strategy steps; {handled: false} for Google ones
        if (m?.handled) return reply(200, m);
        const r = await rpc("svc_ads_agent_finish", args);
        return reply(200, r);
      }
      case "release": {
        await rpc("svc_ads_agent_release", { p_id: Number(body.id), p_reason: body.reason ? String(body.reason).slice(0, 300) : null });
        return reply(200, { ok: true });
      }
      default:
        return reply(422, { detail: "action must be next, finish, release or ping" });
    }
  } catch (e) {
    console.error("ads-agents error", String(e).slice(0, 300));
    return reply(500, { detail: "Something went wrong" });
  }
});
