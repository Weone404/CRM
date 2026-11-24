// CRM > Google > Google My Business data collector (migration 139). POST {jobs: [...], connection?: "<id>"} with the user's
// sign-in, or x-cron-token from pg_cron.
//   discover  each Google login: does it still sign in, does Google let this project read Business Profile, and which
//             profiles does it manage (new ones are added to the list; a login's only profile is tracked at once)
//   sync      every tracked profile: daily numbers (views on Search / Maps, calls, website, directions, messages, bookings),
//             the words people searched (month by month) and the reviews
// Google's own APIs only. Refresh tokens come from Vault through the service role and never leave this function.
// A login's state is saved in plain words: connected, waiting for Google's approval (quota 0), sign in again, API off, no access.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asUser, cors, cronOk, json, HttpError, rpc } from "../_shared/ads_deno.ts";
import { runJob, type Work } from "../_shared/gbp_collect.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now(), deadline = t0 + 135000;
  try {
    let body: { jobs?: string[]; connection?: string } = {};
    try { body = await req.json(); } catch { /* empty */ }
    const jobs = ["discover", "sync"].filter((j) => (body.jobs ?? []).includes(j));       // always in this order
    if (!jobs.length) return json(req, 422, { detail: "jobs: discover or sync" });
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
      results[j] = await runJob(deps, j as "discover" | "sync", w);
      await rpc("svc_gbp_run_end", { p_id: id, p_status: results[j].status, p_detail: results[j].detail });
    }
    return json(req, 200, { results, seconds: Math.round((Date.now() - t0) / 1000) });
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error("crm-google-business error", String(e).slice(0, 300));
    return json(req, status, { detail: status === 500 ? "Something went wrong" : (e as Error).message });
  }
});
