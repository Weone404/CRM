// CRM > Website data collector (migration 112). POST {jobs: [...]} with the user's sign-in, or x-cron-token from pg_cron.
//   search    Search Console: per-day totals, searches, pages, devices, countries, search appearance, search+page (28 days and the 28 before)
//   visitors  GA4: per-day totals, channels, sources (AI assistants), devices, new/returning, landing pages, cities, busiest hours, actions
//   live      GA4 realtime (last 30 minutes); returned, not stored
//   speed     PageSpeed Insights for the key pages, phone and computer (real-user Chrome data + Lighthouse)
//   index     Search Console URL Inspection for the key pages, and the sitemaps Google knows
//   scan      The site itself: robots.txt (AI crawlers), llms.txt, every sitemap page (title, description, H1, canonical, schema, noindex), broken internal links
// Google sign-in and the Search Console site / GA4 property are the ones saved in Connections & keys.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asUser, cors, cronOk, json, HttpError, rpc } from "../_shared/ads_deno.ts";
import { googleToken, gscSite, siteError, windows } from "../_shared/site_signals.ts";
import { pool, scanSite } from "../_shared/website_scan.ts";
import { GA_REPORTS, GSC_REPORTS, REALTIME_REPORTS, gaBody, gscBody, parseGaRows, parseGscRows, parseInspection,
  parsePsi, parseRealtime, parseSitemaps, psiUrl, realtimeBody, type WebRow } from "../_shared/website.ts";

type Work = { site_url: string; key_pages: string[]; gsc_url: string | null; ga4_property: string | null;
  client_id: string | null; client_secret: string | null; refresh_token: string | null; psi_key: string | null };
const today = () => new Date().toISOString().slice(0, 10);

async function timed(url: string, init: RequestInit = {}, ms = 20000) {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), ms);
  const started = performance.now();
  try {
    const res = await fetch(url, { redirect: "follow", ...init, signal: ctl.signal });
    return { res, ms: Math.round(performance.now() - started) };
  } finally { clearTimeout(t); }
}
async function gjson(token: string, url: string, body?: unknown) {
  const { res } = await timed(url, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined }, 60000);
  const b = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, b };
}

async function signIn(w: Work) {
  if (!w.client_id || !w.client_secret || !w.refresh_token) throw new HttpError(422, "Google sign-in is not saved yet (Connections & keys > Google)");
  return googleToken(fetch, w.client_id, w.client_secret, w.refresh_token);
}

async function search(w: Work, token: string) {
  const site = gscSite(w.gsc_url ?? "");
  if (!site) throw new Error("Search Console site is not set (Connections & keys > Google)");
  const win = windows(today(), 3);
  const rows: WebRow[] = [];
  for (const r of GSC_REPORTS) for (const [wn, [s, e]] of Object.entries(win) as ["cur" | "prev", readonly [string, string]][]) {
    const x = await gjson(token, `https://www.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/searchAnalytics/query`, gscBody(r.dims, s, e, r.limit));
    if (!x.ok) throw new Error(siteError("Search Console", x.status, x.b));
    rows.push(...parseGscRows(x.b, r.kind, wn));
  }
  const n = await rpc("svc_web_save", { p_src: "gsc", p_kinds: GSC_REPORTS.map((r) => r.kind), p_rows: rows });
  return `Search Console: ${n} rows (${win.cur[0]} to ${win.cur[1]} and the 28 days before)`;
}

async function visitors(w: Work, token: string) {
  const prop = String(w.ga4_property ?? "").replace(/\D/g, "");
  if (!prop) throw new Error("GA4 property is not set (Connections & keys > Google)");
  const win = windows(today(), 1);
  const rows: WebRow[] = [];
  for (const r of GA_REPORTS) for (const [wn, [s, e]] of Object.entries(win) as ["cur" | "prev", readonly [string, string]][]) {
    const x = await gjson(token, `https://analyticsdata.googleapis.com/v1beta/properties/${prop}:runReport`, gaBody(r, s, e));
    if (!x.ok) throw new Error(siteError("GA4", x.status, x.b));
    rows.push(...parseGaRows(x.b, r.kind, wn));
  }
  const n = await rpc("svc_web_save", { p_src: "ga", p_kinds: GA_REPORTS.map((r) => r.kind), p_rows: rows });
  return n ? `GA4: ${n} rows` : "GA4 answered with no visits for this property; check it is the property for the website";
}

async function live(w: Work, token: string) {
  const prop = String(w.ga4_property ?? "").replace(/\D/g, "");
  if (!prop) throw new HttpError(422, "GA4 property is not set");
  const out: Record<string, unknown> = {};
  for (const r of REALTIME_REPORTS) {
    const x = await gjson(token, `https://analyticsdata.googleapis.com/v1beta/properties/${prop}:runRealtimeReport`, realtimeBody(r));
    if (!x.ok) throw new HttpError(502, siteError("GA4", x.status, x.b));
    out[r.kind] = parseRealtime(x.b);
  }
  return { ...out, at: new Date().toISOString() };
}

async function speed(w: Work, deadline: number) {
  const jobs = w.key_pages.flatMap((u) => (["mobile", "desktop"] as const).map((s) => ({ u, s })));
  let ok = 0; const errs: string[] = [];
  await pool(jobs, 3, deadline, async ({ u, s }) => {
    try {
      const { res } = await timed(psiUrl(u, s, w.psi_key), {}, 70000);
      const b = await res.json().catch(() => ({}));
      if (!res.ok) { errs.push(`${s} ${u}: ${b?.error?.message ?? res.status}`.slice(0, 200)); return; }
      await rpc("svc_web_check_save", { p_key: `psi:${u}|${s}`, p_data: parsePsi(b) }); ok++;
    } catch (e) { errs.push(`${s} ${u}: ${(e as Error).message}`.slice(0, 200)); }
  });
  await rpc("svc_web_checks_prune", { p_prefix: "psi:", p_keep: jobs.map(({ u, s }) => `psi:${u}|${s}`) });
  if (!ok && errs.length) throw new Error(`PageSpeed: ${errs[0]}${w.psi_key ? "" : " (a free PageSpeed API key in Website settings raises the limit)"}`);
  return `PageSpeed: ${ok} of ${jobs.length} checks${errs.length ? `; ${errs.length} failed` : ""}`;
}

async function index(w: Work, token: string) {
  const site = gscSite(w.gsc_url ?? "");
  if (!site) throw new Error("Search Console site is not set");
  let ok = 0;
  for (const u of w.key_pages) {
    const x = await gjson(token, "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect", { inspectionUrl: u, siteUrl: site, languageCode: "en-IN" });
    if (!x.ok) throw new Error(siteError("Search Console", x.status, x.b));
    await rpc("svc_web_check_save", { p_key: `inspect:${u}`, p_data: parseInspection(x.b) }); ok++;
  }
  await rpc("svc_web_checks_prune", { p_prefix: "inspect:", p_keep: w.key_pages.map((u) => `inspect:${u}`) });
  const sm = await gjson(token, `https://www.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/sitemaps`);
  if (sm.ok) await rpc("svc_web_check_save", { p_key: "sitemaps", p_data: { list: parseSitemaps(sm.b) } });
  return `Indexing: ${ok} key pages inspected${sm.ok ? "; sitemaps read" : ""}`;
}

async function scan(w: Work, deadline: number) {
  return scanSite(w.site_url, deadline, (key, data) => rpc("svc_web_check_save", { p_key: key, p_data: data }),
    async (rows) => Number(await rpc("svc_web_pages_save", { p_rows: rows })));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now(), deadline = t0 + 140000;
  try {
    let body: { jobs?: string[] } = {};
    try { body = await req.json(); } catch { /* empty */ }
    const jobs = (body.jobs ?? []).filter((j) => ["search", "visitors", "live", "speed", "index", "scan"].includes(j));
    if (!jobs.length) return json(req, 422, { detail: "jobs: search, visitors, live, speed, index or scan" });
    if (!(await cronOk(req))) {
      const a = await asUser(req, "api_web_access") as { can_view: boolean; can_run: boolean };
      if (!a?.can_view) throw new HttpError(403, "You do not have access to the Website section");
      if (jobs.some((j) => j !== "live") && !a.can_run) throw new HttpError(403, "Only Admin or approvers can refresh website data");
    }
    const w = await rpc("svc_web_work") as Work;
    const needsGoogle = jobs.some((j) => ["search", "visitors", "live", "index"].includes(j));
    const token = needsGoogle ? await signIn(w) : "";
    if (jobs.length === 1 && jobs[0] === "live") return json(req, 200, { live: await live(w, token) });
    const results: Record<string, { status: string; detail: string }> = {};
    for (const j of jobs) {
      if (j === "live") continue;
      const id = await rpc("svc_web_run_begin", { p_job: j });
      try {
        const detail = j === "search" ? await search(w, token) : j === "visitors" ? await visitors(w, token)
          : j === "speed" ? await speed(w, deadline) : j === "index" ? await index(w, token) : await scan(w, deadline);
        results[j] = { status: "ok", detail };
        await rpc("svc_web_run_end", { p_id: id, p_status: "ok", p_detail: detail });
      } catch (e) {
        const detail = (e as Error).message.slice(0, 500);
        results[j] = { status: "error", detail };
        await rpc("svc_web_run_end", { p_id: id, p_status: "error", p_detail: detail });
      }
    }
    return json(req, 200, { results, seconds: Math.round((Date.now() - t0) / 1000) });
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    return json(req, status, { detail: (e as Error).message });
  }
});
