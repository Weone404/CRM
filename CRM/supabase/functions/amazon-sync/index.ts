// amazon-sync: pulls Amazon data into the CRM and runs approved changes.
// Called by pg_cron (header x-cron-token, see migration 073) or by an Admin from the CRM ("Sync now").
// Body: {jobs: ["listings","pricing","execute","reports","finances","orders","market","reviews"]}
// Every job takes its own lock (svc_amz_run_begin), so overlapping runs skip instead of doubling up,
// and every run is recorded in amazon_sync_runs (the CRM shows data age from it).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { SpApi, SpApiError, LwaError, parseListing, parseCompetitiveSummary, parseCatalog, parseOrdersReport, parseOrder, parseOrderItems, parseFeedbackReport,
  parsePerformance, parseSearch, seedPhrases, istDay, istDayRange } from "../_shared/amazon.ts";
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

async function download(doc: any, asText = false) {
  const r = await fetch(doc.url);
  if (!r.ok) throw new Error(`report download ${r.status}`);
  const text = doc.compressionAlgorithm === "GZIP"
    ? await new Response(r.body!.pipeThrough(new DecompressionStream("gzip"))).text()
    : await r.text();
  return asText ? text : JSON.parse(text);
}

// Two reports, each independent (one failing never blocks the other):
// 1. Orders by order date (last 4 IST days) -> units and sales per SKU. One report is kept "pending" in
//    amazon_config; each run reads the finished one and asks for a fresh one, so sales are at most ~1 hour old.
// 2. Seller performance (account health), once per IST day.
async function reports(api: SpApi, _s: Record<string, string>, t0: number) {
  let n = 0; const notes: string[] = []; const errors: string[] = [];
  const today = istDay(new Date());
  const step = async (name: string, fn: () => Promise<void>) => {
    if (Date.now() - t0 > DEADLINE_MS) return;
    try { await fn(); } catch (e) { errors.push(`${name}: ${e instanceof Error ? e.message : String(e)}`); }
  };
  await step("orders", async () => {
    const key = "report_orders_pending";
    const id = await rpc("svc_amz_config_get", { p_key: key });
    if (id) {
      const rep = await api.getReport(id);
      if (rep.processingStatus === "IN_QUEUE" || rep.processingStatus === "IN_PROGRESS") { notes.push(`orders ${rep.processingStatus}`); return; }
      if (rep.processingStatus === "DONE") {
        const rows = parseOrdersReport(await download(await api.getReportDocument(rep.reportDocumentId), true));
        n += rows.length ? await rpc("svc_amz_upsert_sales", { p_items: rows }) : 0;
        notes.push(`orders ${rows.length} rows`);
      } else notes.push(`orders ${rep.processingStatus}`);
    }
    const [start] = istDayRange(istDay(new Date(Date.now() - 3 * 86400000)));
    const r = await api.createReport("GET_FLAT_FILE_ALL_ORDERS_DATA_BY_ORDER_DATE_GENERAL", start, new Date(Date.now() - 120000).toISOString());
    await rpc("svc_amz_config_set", { p_key: key, p_value: r.reportId });
  });
  await step("health", async () => {
    const key = `report_perf_${today}`;
    const state = await rpc("svc_amz_config_get", { p_key: key });
    if (state === "done" || state === "fatal") return;
    if (!state) {
      const [start, end] = istDayRange(istDay(new Date(Date.now() - 86400000)));
      const r = await api.createReport("GET_V2_SELLER_PERFORMANCE_REPORT", start, end);
      await rpc("svc_amz_config_set", { p_key: key, p_value: r.reportId });
      notes.push("health requested");
      return;
    }
    const rep = await api.getReport(state);
    if (rep.processingStatus === "CANCELLED" || rep.processingStatus === "FATAL") {
      await rpc("svc_amz_config_set", { p_key: key, p_value: rep.processingStatus === "FATAL" ? "fatal" : "done" });
      notes.push(`health ${rep.processingStatus}`);
      return;
    }
    if (rep.processingStatus !== "DONE") { notes.push(`health ${rep.processingStatus}`); return; }
    const doc = await download(await api.getReportDocument(rep.reportDocumentId));
    const h = parsePerformance(doc);
    await rpc("svc_amz_upsert_health", { p_day: today, p_odr: h.odr, p_cancel: h.cancel_rate, p_late: h.late_ship_rate,
      p_vtr: h.valid_tracking_rate, p_policy: h.policy_issues, p_raw: doc?.performanceMetrics?.[0] ?? null });
    await rpc("svc_amz_config_set", { p_key: key, p_value: "done" });
    n++;
  });
  // 3. Seller feedback (1-3 stars, last 30 days), once per IST day; 1-2 stars raise an alert.
  await step("feedback", async () => {
    const key = `report_feedback_${today}`;
    const state = await rpc("svc_amz_config_get", { p_key: key });
    if (state === "done" || state === "fatal") return;
    if (!state) {
      const r = await api.createReport("GET_SELLER_FEEDBACK_DATA", new Date(Date.now() - 30 * 86400000).toISOString(), new Date(Date.now() - 120000).toISOString());
      await rpc("svc_amz_config_set", { p_key: key, p_value: r.reportId });
      notes.push("feedback requested");
      return;
    }
    const rep = await api.getReport(state);
    if (rep.processingStatus === "CANCELLED" || rep.processingStatus === "FATAL") {
      await rpc("svc_amz_config_set", { p_key: key, p_value: rep.processingStatus === "FATAL" ? "fatal" : "done" });
      notes.push(`feedback ${rep.processingStatus}`);
      return;
    }
    if (rep.processingStatus !== "DONE") { notes.push(`feedback ${rep.processingStatus}`); return; }
    const rows = parseFeedbackReport(await download(await api.getReportDocument(rep.reportDocumentId), true));
    if (rows.length) await rpc("svc_amz_upsert_feedback", { p_items: rows });
    await rpc("svc_amz_config_set", { p_key: key, p_value: "done" });
    notes.push(`feedback ${rows.length}`);
  });
  if (errors.length) throw new Error([...errors, ...notes].join("; "));   // work already saved stays saved
  return { items: n, detail: [...notes, ...errors].join("; ") };
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

// Orders updated in the last 3 days (status, ship-by time, Easy Ship status), then items for open orders.
// getOrders allows ~1 request/minute after a burst of 20; getOrderItems ~0.5/s: SpApi waits on 429 by itself.
async function orders(api: SpApi, _s: Record<string, string>, t0: number) {
  const since = new Date(Date.now() - 3 * 86400000).toISOString();
  const rows: any[] = [];
  let token: string | undefined;
  for (let page = 0; page < 5 && Date.now() - t0 < DEADLINE_MS; page++) {
    const r = await api.getOrders(since, token);
    for (const o of r?.payload?.Orders || []) rows.push(parseOrder(o));
    token = r?.payload?.NextToken;
    if (!token) break;
  }
  const n = rows.length ? await rpc("svc_amz_upsert_orders", { p_items: rows }) : 0;
  const need: string[] = await rpc("svc_amz_orders_without_items");
  const withItems: any[] = [];
  for (const id of need) {
    if (Date.now() - t0 > DEADLINE_MS) break;
    const base = rows.find((x) => x.order_id === id) || { order_id: id };
    withItems.push({ ...base, items: parseOrderItems(await api.getOrderItems(id)) });
  }
  if (withItems.length) await rpc("svc_amz_upsert_orders", { p_items: withItems.filter((x) => x.status) });
  return { items: n, detail: `${rows.length} orders, items for ${withItems.length}` };
}

// Morning market watch: search every tracked keyword, keep our rank and ONLY the competitors above us, price them,
// then ask Claude for the morning report (and weekly keyword ideas). Keywords marked "also future products" are applied.
async function market(api: SpApi, _s: Record<string, string>, t0: number) {
  let t = await rpc("svc_amz_market_targets");
  if (!t?.keywords?.length) {
    await rpc("svc_amz_keyword_seed", { p_phrases: seedPhrases(t?.my_titles || []) });
    t = await rpc("svc_amz_market_targets");
  }
  const results: any[] = [];
  let failed = 0, lastErr = "";
  for (const k of t?.keywords || []) {
    if (Date.now() - t0 > DEADLINE_MS - 40_000) break;               // leave time for prices + saving
    try { results.push({ keyword_id: k.id, items: parseSearch(await api.searchCatalog(k.keyword)) }); }
    catch (e) {
      if (e instanceof SpApiError && (e.status === 403 || e.status === 401)) {
        throw new Error("Amazon refused the catalogue search (access denied). In Seller Central > Develop Apps, give the app the " +
          "'Product Listing' role, then authorise again.");
      }
      failed++; lastErr = e instanceof Error ? e.message : String(e);
    }
  }
  if (!results.length) throw new Error(`No keyword could be searched${lastErr ? `: ${lastErr.slice(0, 200)}` : ""}`);
  const saved = await rpc("svc_amz_market_save", { p_results: results, p_prices: [] });
  const watched: string[] = await rpc("svc_amz_market_watched");
  let priced = 0;
  for (let i = 0; i < watched.length && i < 40 && Date.now() - t0 < DEADLINE_MS; i += 20) {
    try { priced += await rpc("svc_amz_upsert_pricing", { p_items: parseCompetitiveSummary(await api.competitiveSummary(watched.slice(i, i + 20)), _s.AMZ_SELLER_ID) }); }
    catch (e) { console.log("market prices skipped", String(e).slice(0, 200)); break; }
  }
  await rpc("svc_amz_market_daily_refresh");
  const auto = await rpc("svc_amz_keyword_autoapply");
  await rpc("svc_amz_market_requests");
  return { items: results.length,
    detail: `${results.length} keywords, ${saved?.competitors ?? 0} competitors, ${saved?.ideas ?? 0} ideas, ${priced} prices` +
      `${auto ? `, ${auto} new-product keyword drafts` : ""}${failed ? `, ${failed} searches failed` : ""}` };
}

// Request a Review for shipped orders (Amazon's own button; it decides who is eligible, 5-30 days after delivery).
async function reviews(api: SpApi, _s: Record<string, string>, t0: number) {
  const list: { order_id: string; asin: string | null }[] = await rpc("svc_amz_review_candidates");
  let sent = 0, notYet = 0;
  for (const o of list.slice(0, 25)) {
    if (Date.now() - t0 > DEADLINE_MS) break;
    try {
      const a = await api.solicitationActions(o.order_id);
      const can = (a?._links?.actions || []).some((x: any) => x?.name === "productReviewAndSellerFeedback");
      if (!can) { await rpc("svc_amz_review_result", { p_order: o.order_id, p_asin: o.asin, p_status: "not_eligible", p_detail: "Not eligible yet" }); notYet++; continue; }
      await api.requestReview(o.order_id);
      await rpc("svc_amz_review_result", { p_order: o.order_id, p_asin: o.asin, p_status: "sent", p_detail: "Requested" });
      sent++;
    } catch (e) {
      const msg = e instanceof SpApiError && (e.status === 403 || e.status === 401)
        ? "Amazon refused (access denied): give the app the 'Buyer Solicitation' role in Seller Central > Develop Apps, then authorise again."
        : (e instanceof Error ? e.message : String(e));
      await rpc("svc_amz_review_result", { p_order: o.order_id, p_asin: o.asin, p_status: "error", p_detail: msg.slice(0, 280) });
      if (e instanceof SpApiError && (e.status === 403 || e.status === 401)) throw new Error(msg);
    }
  }
  return { items: sent, detail: `${sent} review requests sent, ${notYet} not eligible yet` };
}

const JOBS: Record<string, (api: SpApi, s: Record<string, string>, t0: number) => Promise<{ items: number; detail?: string }>> =
  { listings, pricing, execute: executeJob, reports, finances, orders, market, reviews };

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
