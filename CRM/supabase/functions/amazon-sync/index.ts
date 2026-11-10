// amazon-sync: pulls Amazon data into the CRM and runs approved changes.
// Called by pg_cron (header x-cron-token, see migration 073) or by an Admin from the CRM ("Sync now").
// Body: {jobs: ["listings","pricing","execute","reports","finances"]}
// Every job takes its own lock (svc_amz_run_begin), so overlapping runs skip instead of doubling up,
// and every run is recorded in amazon_sync_runs (the CRM shows data age from it).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { SpApi, SpApiError, LwaError, parseListing, parseCompetitiveSummary, parseCatalog, parseSalesTraffic,
  parsePerformance, istDay, istDayRange } from "../_shared/amazon.ts";
import { execute, reconcile } from "../_shared/amazon_exec.ts";
import { asUser, cors, cronOk, json, HttpError, loadApi, rpc, scrub } from "../_shared/amazon_deno.ts";

const DEADLINE_MS = 120_000;            // stay inside the Edge Function wall-clock limit
const started = () => Date.now();

async function job(name: string, fn: () => Promise<{ items: number; detail?: string }>, secrets: Record<string, string>) {
  const run = await rpc("svc_amz_run_begin", { p_job: name, p_seconds: 600 });
  if (run === null) return { job: name, status: "skipped" };
  try {
    const r = await fn();
    await rpc("svc_amz_run_end", { p_run: run, p_job: name, p_status: "ok", p_items: r.items, p_detail: r.detail ?? null });
    return { job: name, status: "ok", ...r };
  } catch (e) {
    const msg = e instanceof LwaError ? `Amazon login failed (${e.kind}). Open Settings > Test Connection.`
      : scrub(e instanceof Error ? e.message : String(e), secrets);
    await rpc("svc_amz_run_end", { p_run: run, p_job: name, p_status: "error", p_items: 0, p_detail: msg.slice(0, 900) });
    return { job: name, status: "error", detail: msg };
  }
}

async function listings(api: SpApi, s: Record<string, string>, t0: number) {
  const items: any[] = [];
  let token: string | undefined;
  for (let page = 0; page < 25 && Date.now() - t0 < DEADLINE_MS; page++) {
    const r = await api.searchListings(s.AMZ_SELLER_ID, token);
    for (const it of r?.items || []) items.push(parseListing(it));
    token = r?.pagination?.nextToken;
    if (!token) break;
  }
  const res = await rpc("svc_amz_upsert_listings", { p_items: items });
  const dispatch = items.filter((i) => i.handling_days != null).map((i) => ({ sku: i.sku, handling_days: i.handling_days }));
  if (dispatch.length) await rpc("svc_amz_upsert_dispatch", { p_items: dispatch });
  return { items: items.length, detail: `drift ${res?.drift ?? 0}` };
}

async function pricing(api: SpApi, s: Record<string, string>, t0: number) {
  const asins: string[] = await rpc("svc_amz_competitor_asins");
  let n = 0;
  for (let i = 0; i < asins.length && i < 60 && Date.now() - t0 < DEADLINE_MS; i += 20) {
    const chunk = asins.slice(i, i + 20);
    const r = await api.competitiveSummary(chunk);       // ~1 call / 30 s; 429 waits are handled inside SpApi
    n += await rpc("svc_amz_upsert_pricing", { p_items: parseCompetitiveSummary(r, s.AMZ_SELLER_ID) });
  }
  const comp = asins.filter(Boolean).slice(0, 20);
  if (comp.length && Date.now() - t0 < DEADLINE_MS) {
    try { await rpc("svc_amz_upsert_catalog", { p_items: parseCatalog(await api.catalogItems(comp)) }); } catch (e) { console.log("catalog skipped", String(e).slice(0, 200)); }
  }
  await rpc("svc_amz_audit");
  return { items: n };
}

async function executeJob(api: SpApi, s: Record<string, string>, t0: number) {
  const work = await rpc("svc_amz_work");
  let n = 0;
  for (const id of work?.approved || []) {
    if (Date.now() - t0 > DEADLINE_MS) break;
    await execute(rpc, api, s, id, { settleMs: 3000 }); n++;
  }
  const rec = await reconcile(rpc, api, s, work?.stuck || []);
  return { items: n + rec.length, detail: `ran ${n}, reconciled ${rec.length}` };
}

async function download(doc: any) {
  const r = await fetch(doc.url);
  if (!r.ok) throw new Error(`report download ${r.status}`);
  if (doc.compressionAlgorithm === "GZIP") {
    const text = await new Response(r.body!.pipeThrough(new DecompressionStream("gzip"))).text();
    return JSON.parse(text);
  }
  return await r.json();
}

// One report per IST day (sales & traffic per SKU) + the seller performance report. Each step is resumable:
// the report id is kept in amazon_config, so a run that times out continues where it stopped.
async function reports(api: SpApi, _s: Record<string, string>, t0: number) {
  let n = 0; const notes: string[] = [];
  const today = istDay(new Date());
  const days = [1, 2, 3].map((d) => istDay(new Date(Date.now() - d * 86400000)));
  const plan: { key: string; type: string; day: string; options?: Record<string, string> }[] = [
    ...days.map((day) => ({ key: `report_sales_${day}`, type: "GET_SALES_AND_TRAFFIC_REPORT", day,
      options: { dateGranularity: "DAY", asinGranularity: "SKU" } })),
    { key: `report_perf_${today}`, type: "GET_V2_SELLER_PERFORMANCE_REPORT", day: today },
  ];
  for (const p of plan) {
    if (Date.now() - t0 > DEADLINE_MS) break;
    const state = await rpc("svc_amz_config_get", { p_key: p.key });
    if (state === "done" || state === "fatal") continue;
    if (!state) {
      const [start, end] = p.type === "GET_V2_SELLER_PERFORMANCE_REPORT" ? istDayRange(days[0]) : istDayRange(p.day);
      const r = await api.createReport(p.type, start, end, p.options);
      await rpc("svc_amz_config_set", { p_key: p.key, p_value: r.reportId });
      notes.push(`${p.key} requested`);
      continue;
    }
    const rep = await api.getReport(state);
    if (rep.processingStatus === "CANCELLED" || rep.processingStatus === "FATAL") {
      // CANCELLED for sales usually means "no data for that day"; record it and stop asking.
      await rpc("svc_amz_config_set", { p_key: p.key, p_value: rep.processingStatus === "FATAL" ? "fatal" : "done" });
      notes.push(`${p.key} ${rep.processingStatus}`);
      continue;
    }
    if (rep.processingStatus !== "DONE") { notes.push(`${p.key} ${rep.processingStatus}`); continue; }
    const doc = await download(await api.getReportDocument(rep.reportDocumentId));
    if (p.type === "GET_SALES_AND_TRAFFIC_REPORT") {
      n += await rpc("svc_amz_upsert_sales", { p_items: parseSalesTraffic(doc, p.day) });
    } else {
      const h = parsePerformance(doc);
      await rpc("svc_amz_upsert_health", { p_day: p.day, p_odr: h.odr, p_cancel: h.cancel_rate, p_late: h.late_ship_rate,
        p_vtr: h.valid_tracking_rate, p_policy: h.policy_issues, p_raw: doc?.performanceMetrics?.[0] ?? null });
      n++;
    }
    await rpc("svc_amz_config_set", { p_key: p.key, p_value: "done" });
  }
  return { items: n, detail: notes.join("; ") };
}

// Fees and refunds per SKU per IST day for the last 3 full days (overwrites those days only).
async function finances(api: SpApi, _s: Record<string, string>, t0: number) {
  const days = [1, 2, 3].map((d) => istDay(new Date(Date.now() - d * 86400000)));
  const [from] = istDayRange(days[2]);
  const fees = new Map<string, number>(); const refunds = new Map<string, number>();
  let token: string | undefined;
  for (let page = 0; page < 20 && Date.now() - t0 < DEADLINE_MS; page++) {
    const r = await api.financialEvents(from, token);
    const ev = r?.payload?.FinancialEvents || {};
    for (const sh of ev.ShipmentEventList || []) {
      const day = istDay(sh.PostedDate);
      for (const it of sh.ShipmentItemList || []) {
        const k = `${day}|${it.SellerSKU}`;
        for (const f of it.ItemFeeList || []) fees.set(k, (fees.get(k) || 0) - Number(f.FeeAmount?.CurrencyAmount || 0));
      }
    }
    for (const rf of ev.RefundEventList || []) {
      const day = istDay(rf.PostedDate);
      for (const it of rf.ShipmentItemAdjustmentList || []) {
        const k = `${day}|${it.SellerSKU}`;
        refunds.set(k, (refunds.get(k) || 0) + Number(it.QuantityShipped || 1));
      }
    }
    token = r?.payload?.NextToken;
    if (!token) break;
  }
  const rows = [...new Set([...fees.keys(), ...refunds.keys()])].filter((k) => days.includes(k.split("|")[0])).map((k) => {
    const [day, sku] = k.split("|");
    return { day, sku, fees: Math.round((fees.get(k) || 0) * 100) / 100, refunds: refunds.get(k) || 0 };
  });
  return { items: await rpc("svc_amz_upsert_sales", { p_items: rows }) };
}

const JOBS: Record<string, (api: SpApi, s: Record<string, string>, t0: number) => Promise<{ items: number; detail?: string }>> =
  { listings, pricing, execute: executeJob, reports, finances };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  let secrets: Record<string, string> = {};
  try {
    if (!(await cronOk(req))) {
      const access = await asUser(req, "api_amz_access");
      if (!access?.is_admin) throw new HttpError(403, "Only Admin can start a sync");
    }
    const body = await req.json().catch(() => ({}));
    const wanted: string[] = Array.isArray(body.jobs) && body.jobs.length ? body.jobs : ["listings", "pricing"];
    const unknown = wanted.filter((j) => !JOBS[j]);
    if (unknown.length) throw new HttpError(400, `Unknown job: ${unknown.join(", ")}`);
    let loaded;
    try { loaded = await loadApi(); }
    catch (e) { return json(req, 200, { status: "not-configured", detail: "Amazon keys are not saved yet (CRM > Amazon > Settings)." }); }
    secrets = loaded.secrets;
    const t0 = started();
    const results = [];
    for (const j of wanted) results.push(await job(j, () => JOBS[j](loaded.api, secrets, t0), secrets));
    return json(req, 200, { status: "ok", results });
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    const msg = scrub(e instanceof Error ? e.message : String(e), secrets);
    console.error("amazon-sync", msg);
    return json(req, status, { detail: e instanceof HttpError ? e.message : msg.slice(0, 300) });
  }
});
