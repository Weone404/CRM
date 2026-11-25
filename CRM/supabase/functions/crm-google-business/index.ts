// CRM > Google > Google My Business data collector (migration 139). POST {jobs: [...], connection?: "<id>"} with the user's
// sign-in, or x-cron-token from pg_cron.
//   discover  each Google login: does it still sign in, does Google let this project read Business Profile, and which
//             profiles does it manage (new ones are added to the list; a login's only profile is tracked at once)
//   sync      every tracked profile: daily numbers (views on Search / Maps, calls, website, directions, messages, bookings),
//             the words people searched (month by month) and the reviews
//   reviews   only the newest reviews of every tracked profile (every 3 hours, so a new review is seen the same day)
//   reply     send the review replies that are approved (migration 140); each review is read again first
//   post      publish the posts a person queued in the CRM (migration 143); one request each, never retried by itself
// The AI helper (tools/ads-agents, header x-ads-agents-token) writes those replies through the same door:
//   {action: "next", roles: [...]} -> {run, context} | {run: null};  {action: "finish", id, ok, output, error};  {action: "release", id}
// It gets a review and returns text. It never gets a Google token and never talks to Google.
// Google's own APIs only. Refresh tokens come from Vault through the service role and never leave this function.
// A login's state is saved in plain words: connected, waiting for Google's approval (quota 0), sign in again, API off, no access.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, asUser, cors, cronOk, json, HttpError, rpc } from "../_shared/ads_deno.ts";
import { runJob, type Job, type Work } from "../_shared/gbp_collect.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now(), deadline = t0 + 135000;
  try {
    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* empty */ }
    if (body === null || typeof body !== "object" || Array.isArray(body)) body = {};
    const agentToken = req.headers.get("x-ads-agents-token");
    if (agentToken !== null || typeof body.action === "string") {
      const { data: okTok } = await admin.rpc("svc_ads_agents_token_ok", { p_token: agentToken ?? "" });
      if (okTok !== true) return json(req, 401, { detail: "Bad or missing agents token" });
      const id = Number(body.id);
      switch (body.action) {
        case "next": {
          const roles = Array.isArray(body.roles) ? body.roles.filter((x: unknown) => typeof x === "string").slice(0, 40) : [];
          return json(req, 200, (await rpc("svc_gbp_reply_next", { p_roles: roles })) ?? { run: null });
        }
        case "finish": {
          if (!Number.isInteger(id)) return json(req, 422, { detail: "id is required" });
          const out = body.output && typeof body.output === "object" && !Array.isArray(body.output) ? body.output : null;
          return json(req, 200, await rpc("svc_gbp_reply_finish", { p_id: id, p_ok: body.ok === true && !!out, p_output: out, p_error: body.error ? String(body.error).slice(0, 300) : null }));
        }
        case "release":
          if (Number.isInteger(id)) await rpc("svc_gbp_reply_release", { p_id: id });
          return json(req, 200, { ok: true });
        default:
          return json(req, 422, { detail: "action must be next, finish or release" });
      }
    }
    const jobs = ["discover", "sync", "reviews", "reply", "post"].filter((j) => (Array.isArray(body.jobs) ? body.jobs : []).includes(j));       // always in this order
    if (!jobs.length) return json(req, 422, { detail: "jobs: discover, sync, reviews, reply or post" });
    const only = typeof body.connection === "string" && /^[0-9a-f-]{36}$/i.test(body.connection) ? body.connection : null;
    if (!(await cronOk(req))) {
      const a = await asUser(req, "api_gbp_access") as { can_view: boolean; can_run: boolean };
      if (!a?.can_view) throw new HttpError(403, "You do not have access to Google My Business");
      if (!a.can_run) throw new HttpError(403, "Only Admin or approvers can refresh Google My Business");
    }
    const results: Record<string, { status: string; detail: string }> = {};
    const deps = { fetch: (u: string, i?: RequestInit) => fetch(u, i), rpc, today: new Date().toISOString().slice(0, 10), expired: () => Date.now() > deadline };
    for (const j of jobs) {
      const id = await rpc("svc_gbp_run_begin", { p_job: j });
      const w = await rpc("svc_gbp_work", { p_connection: only }) as Work;        // read again: discover may have added profiles
      results[j] = await runJob(deps, j as Job, w);
      await rpc("svc_gbp_run_end", { p_id: id, p_status: results[j].status, p_detail: results[j].detail });
    }
    return json(req, 200, { results, seconds: Math.round((Date.now() - t0) / 1000) });
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error("crm-google-business error", String(e).slice(0, 300));
    return json(req, status, { detail: status === 500 ? "Something went wrong" : (e as Error).message });
  }
});
