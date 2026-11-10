// ads-sync: the CRM's link to Google Ads and Meta.
// Called by pg_cron (header x-cron-token, see migration 077) or from CRM > ADS by a signed-in user.
// Body: {jobs: ["test", "sync", "execute"]}
//   test     Admin. Checks each platform's credentials and every added account; records the result.
//   sync     Viewer. Account details, campaigns and daily metrics for the last `sync_days`, then recommendations.
//   execute  Approver. Sends approved changes, reads each campaign back, records verified / failed / outcome_unknown.
// Every job takes its own lock (svc_ads_run_begin), so overlapping runs skip instead of doubling up.
// Keys come from Vault through the service role and never leave this function (responses and logs are scrubbed).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asUser, cors, cronOk, json, HttpError, rpc } from "../_shared/ads_deno.ts";
import { AdsError, GoogleAds, MetaAds, dateRange, executeOne, scrubSecrets, todayIn, verify, type Platforms, type WorkItem } from "../_shared/ads_core.ts";

const DEADLINE_MS = 120_000;

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function platforms(s: Record<string, string>): { p: Platforms; missing: Record<string, string[]> } {
  const missing: Record<string, string[]> = { google: [], meta: [] };
  for (const k of ["GOOGLE_ADS_DEVELOPER_TOKEN", "GOOGLE_ADS_CLIENT_ID", "GOOGLE_ADS_CLIENT_SECRET", "GOOGLE_ADS_REFRESH_TOKEN"]) if (!s[k]) missing.google.push(k);
  if (!s.META_ACCESS_TOKEN) missing.meta.push("META_ACCESS_TOKEN");
  const p: Platforms = {};
  if (!missing.google.length) p.google = new GoogleAds({ developerToken: s.GOOGLE_ADS_DEVELOPER_TOKEN, clientId: s.GOOGLE_ADS_CLIENT_ID,
    clientSecret: s.GOOGLE_ADS_CLIENT_SECRET, refreshToken: s.GOOGLE_ADS_REFRESH_TOKEN, loginCustomerId: s.GOOGLE_ADS_LOGIN_CUSTOMER_ID,
    version: s.GOOGLE_API_VERSION }, fetch);
  if (!missing.meta.length) p.meta = new MetaAds({ accessToken: s.META_ACCESS_TOKEN, appSecret: s.META_APP_SECRET, version: s.META_API_VERSION, hmac: hmacHex }, fetch);
  return { p, missing };
}

async function runJob(name: string, secrets: Record<string, string>, fn: () => Promise<{ items: number; detail?: string; status?: "ok" | "error" }>) {
  const run = await rpc("svc_ads_run_begin", { p_job: name, p_seconds: 600 });
  if (run === null) return { job: name, status: "skipped" };
  try {
    const r = await fn();
    const st = r.status ?? "ok";
    await rpc("svc_ads_run_end", { p_run: run, p_job: name, p_status: st, p_items: r.items, p_detail: r.detail ? scrubSecrets(r.detail, secrets) : null });
    return { job: name, status: st, items: r.items, detail: r.detail ? scrubSecrets(r.detail, secrets) : undefined };
  } catch (e) {
    const msg = scrubSecrets(e instanceof Error ? e.message : String(e), secrets).slice(0, 900);
    await rpc("svc_ads_run_end", { p_run: run, p_job: name, p_status: "error", p_items: 0, p_detail: msg });
    return { job: name, status: "error", detail: msg };
  }
}

type Acct = { id: string; platform: "google" | "meta"; external_id: string };

async function test(s: Record<string, string>) {
  const { p, missing } = platforms(s);
  const out: Record<string, unknown> = {};
  for (const plat of ["google", "meta"] as const) {
    out[plat] = await runJob(`test_${plat}`, s, async () => {
      if (missing[plat].length) return { items: 0, status: "error", detail: `Not configured: ${missing[plat].join(", ")}` };
      if (plat === "meta") await p.meta!.me();              // token works at all
      const accts = ((await rpc("svc_ads_accounts")) as Acct[]).filter((a) => a.platform === plat);
      if (plat === "google" && !accts.length) return { items: 0, status: "error", detail: "Add a Google Ads account (customer ID) first; the token is checked against it." };
      const problems: string[] = [];
      for (const a of accts) {
        try {
          const info = plat === "google" ? await p.google!.account(a.external_id) : await p.meta!.account(a.external_id);
          await rpc("svc_ads_account_status", { p_account: a.id, p_status: "connected", p_error: null, p_name: info.name, p_currency: info.currency, p_timezone: info.timezone });
        } catch (e) {
          const st = e instanceof AdsError ? e.status : "sync_failed";
          const m = scrubSecrets(e instanceof Error ? e.message : String(e), s);
          await rpc("svc_ads_account_status", { p_account: a.id, p_status: st, p_error: m });
          problems.push(`${a.external_id}: ${m}`);
        }
      }
      return problems.length
        ? { items: accts.length, status: "error", detail: problems.join(" | ") }
        : { items: accts.length, detail: accts.length ? `Connected. ${accts.length} account(s) reachable.` : "Connected. No accounts added yet." };
    });
  }
  return out;
}

async function sync(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  return runJob("sync", s, async () => {
    const accts = (await rpc("svc_ads_accounts")) as Acct[];
    const days = Math.min(90, Math.max(1, Number(s.SYNC_DAYS) || 30));
    let campaigns = 0, metrics = 0;
    const problems: string[] = [];
    for (const a of accts) {
      if (Date.now() - t0 > DEADLINE_MS) { problems.push("time limit reached; remaining accounts next run"); break; }
      try {
        const api = a.platform === "google" ? p.google : p.meta;
        if (!api) throw new AdsError("auth_required", `${a.platform === "google" ? "Google Ads" : "Meta"} keys are not set in ADS > Settings`);
        const info = a.platform === "google" ? await p.google!.account(a.external_id) : await p.meta!.account(a.external_id);
        const { since, until } = dateRange(days, todayIn(info.timezone ?? "Asia/Kolkata"));
        const camps = a.platform === "google" ? await p.google!.campaigns(a.external_id) : await p.meta!.campaigns(a.external_id, info.currency);
        campaigns += await rpc("svc_ads_upsert_campaigns", { p_account: a.id, p_items: camps });
        const mets = a.platform === "google" ? await p.google!.metrics(a.external_id, since, until) : await p.meta!.metrics(a.external_id, since, until);
        metrics += await rpc("svc_ads_upsert_metrics", { p_account: a.id, p_items: mets });
        await rpc("svc_ads_account_status", { p_account: a.id, p_status: "connected", p_error: null, p_name: info.name, p_currency: info.currency, p_timezone: info.timezone });
      } catch (e) {
        const st = e instanceof AdsError ? e.status : "sync_failed";
        const m = scrubSecrets(e instanceof Error ? e.message : String(e), s);
        await rpc("svc_ads_account_status", { p_account: a.id, p_status: st, p_error: m });
        problems.push(`${a.platform} ${a.external_id}: ${m}`);
      }
    }
    const recs = await rpc("svc_ads_recommend");
    const detail = `${accts.length} account(s), ${campaigns} campaign(s), ${metrics} day-rows, ${recs} new recommendation(s)` +
      (problems.length ? `. Problems: ${problems.join(" | ")}` : "");
    return { items: metrics, detail, status: problems.length ? "error" : "ok" };
  });
}

async function execute(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  const currencies = new Map<string, string | null>();
  if (p.meta) p.metaCurrency = (id) => currencies.get(id) ?? null;
  return runJob("execute", s, async () => {
    if (s.EXECUTION_PAUSED === "true") return { items: 0, detail: "Emergency stop is on; nothing sent." };
    const meta = ((await rpc("svc_ads_accounts")) as Acct[]).filter((a) => a.platform === "meta");
    for (const a of meta) if (p.meta) { try { currencies.set(a.external_id, (await p.meta.account(a.external_id)).currency); } catch { /* resolved per change */ } }
    let n = 0;
    // 1. Re-check changes whose outcome was unknown (never re-sent: only read back)
    for (const w of (await rpc("svc_ads_unknown")) as WorkItem[]) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      const r = await verify(p, w);
      await rpc("svc_ads_finish", { p_id: w.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null, p_verify: r.verify ?? null });
      n++;
    }
    // 2. Approved changes
    for (const w of (await rpc("svc_ads_work")) as WorkItem[]) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      if (!(await rpc("svc_ads_claim", { p_id: w.id }))) continue;
      const r = await executeOne(p, w);
      await rpc("svc_ads_finish", { p_id: w.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null, p_verify: r.verify ?? null });
      n++;
    }
    return { items: n, detail: `${n} change(s) processed` };
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now();
  try {
    let body: { jobs?: string[] } = {};
    try { body = await req.json(); } catch { /* empty body */ }
    const jobs = (body.jobs ?? ["sync"]).filter((j) => ["test", "sync", "execute"].includes(j));
    if (!jobs.length) return json(req, 422, { detail: "jobs must include test, sync or execute" });
    if (!(await cronOk(req))) {
      const access = await asUser(req, "api_ads_access") as { can_view: boolean; can_approve: boolean; is_admin: boolean };
      if (!access?.can_view) throw new HttpError(403, "You do not have access to the ADS section");
      if (jobs.includes("test") && !access.is_admin) throw new HttpError(403, "Only Admin can test connections");
      if (jobs.includes("execute") && !access.can_approve) throw new HttpError(403, "Only approvers can run changes");
    }
    const secrets = (await rpc("svc_ads_secrets")) as Record<string, string>;
    const results: Record<string, unknown> = {};
    if (jobs.includes("test")) results.test = await test(secrets);
    if (jobs.includes("sync")) results.sync = await sync(secrets, t0);
    if (jobs.includes("execute")) results.execute = await execute(secrets, t0);
    return json(req, 200, { results });
  } catch (e) {
    if (e instanceof HttpError) return json(req, e.status, { detail: e.message });
    console.error("ads-sync error", String(e).slice(0, 300));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
