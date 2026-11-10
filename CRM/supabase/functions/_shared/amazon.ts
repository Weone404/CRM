// Amazon SP-API client and helpers shared by the amazon-* Edge Functions.
// Runtime-neutral (no Deno globals) so the same file is unit-tested locally with Bun.
//
// India sells on the Europe endpoint: https://sellingpartnerapi-eu.amazon.com, marketplace A21TJRUUN4KGV.

export const LWA_URL = "https://api.amazon.com/auth/o2/token";
export const INDIA = "A21TJRUUN4KGV";

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export interface SpApiOptions {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
  endpoint?: string;
  marketplaceId?: string;
  fetch?: Fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  maxRetries?: number;
  log?: (msg: string) => void;
}

// What the person sees in Settings > Test Connection.
export type TestStatus = "Connected" | "Wrong marketplace" | "Invalid client" | "Token revoked" | "Throttled" | "Error";
export const TEST_FIX: Record<TestStatus, string> = {
  "Connected": "All good. Amazon.in is reachable with these keys.",
  "Wrong marketplace": "These keys do not sell on Amazon.in. Authorize the app from Seller Central India (sellercentral.amazon.in).",
  "Invalid client": "Client ID or Client Secret is wrong or expired. Copy both again from Seller Central > Apps and Services > Develop Apps (rotate the secret if it expired).",
  "Token revoked": "The refresh token was revoked or belongs to another app. Click Authorize app again and paste the new refresh token.",
  "Throttled": "Amazon is rate-limiting right now. Wait a minute and test again.",
  "Error": "Amazon returned an unexpected error. Try again; if it repeats, check Seller Central for account notices.",
};

export class SpApiError extends Error {
  constructor(public status: number, public code: string, message: string, public body?: unknown) { super(message); }
}
// A write whose result is unknown (timeout / 5xx after sending). Never retried blindly: the caller reconciles.
export class UnknownOutcome extends Error {}
export class LwaError extends Error {
  constructor(public kind: "invalid_client" | "invalid_grant" | "throttled" | "other", message: string) { super(message); }
}

export class SpApi {
  private token: string | null = null;
  private tokenUntil = 0;
  readonly endpoint: string;
  readonly marketplaceId: string;
  private f: Fetch;
  private sleep: (ms: number) => Promise<void>;
  private now: () => number;
  private maxRetries: number;
  private log: (m: string) => void;
  calls = 0;   // HTTP calls made (tests read this)

  constructor(private o: SpApiOptions) {
    if (!o.clientId || !o.clientSecret || !o.refreshToken) throw new LwaError("invalid_client", "Amazon keys are not set in Settings");
    this.endpoint = (o.endpoint || "https://sellingpartnerapi-eu.amazon.com").replace(/\/$/, "");
    this.marketplaceId = o.marketplaceId || INDIA;
    this.f = o.fetch || ((u, i) => fetch(u, i));
    this.sleep = o.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.now = o.now || (() => Date.now());
    this.maxRetries = o.maxRetries ?? 5;
    this.log = o.log || (() => {});
  }

  async accessToken(): Promise<string> {
    if (this.token && this.now() < this.tokenUntil) return this.token;
    const body = new URLSearchParams({ grant_type: "refresh_token", refresh_token: this.o.refreshToken,
      client_id: this.o.clientId, client_secret: this.o.clientSecret });
    for (let attempt = 0; ; attempt++) {
      this.calls++;
      const r = await this.f(LWA_URL, { method: "POST", body,
        headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" } });
      const j = await r.json().catch(() => ({})) as Record<string, string | number>;
      if (r.ok && j.access_token) {
        this.token = String(j.access_token);
        this.tokenUntil = this.now() + (Number(j.expires_in || 3600) - 120) * 1000;   // refresh 2 min early
        return this.token;
      }
      if (r.status === 429 && attempt < this.maxRetries) { await this.sleep(this.wait(r, attempt)); continue; }
      const err = String(j.error || "");
      if (r.status === 429) throw new LwaError("throttled", "Login with Amazon is throttling");
      if (err === "invalid_client" || err === "unauthorized_client") throw new LwaError("invalid_client", String(j.error_description || err));
      if (err === "invalid_grant") throw new LwaError("invalid_grant", String(j.error_description || err));
      throw new LwaError("other", `LWA ${r.status}: ${String(j.error_description || err || "error")}`);
    }
  }

  // Wait before a retry: Amazon's Retry-After if present, else exponential backoff with jitter (1s, 2s, 4s ... max 30s).
  private wait(r: Response, attempt: number): number {
    const ra = Number(r.headers.get("retry-after"));
    if (Number.isFinite(ra) && ra > 0) return Math.min(ra * 1000, 60000);
    return Math.min(1000 * 2 ** attempt, 30000) + Math.floor(Math.random() * 250);
  }

  // One SP-API call. 429 (throttled = not processed) is retried with backoff for every method.
  // 5xx / network errors: GETs are retried; writes (PATCH/PUT/POST/DELETE) throw UnknownOutcome so they are
  // reconciled by reading Amazon's state, never re-sent blindly.
  async request(method: string, path: string, opts: { query?: Record<string, string | string[] | undefined>; body?: unknown } = {}) {
    const url = new URL(this.endpoint + path);
    for (const [k, v] of Object.entries(opts.query || {})) {
      if (v === undefined) continue;
      url.searchParams.set(k, Array.isArray(v) ? v.join(",") : v);
    }
    const isRead = method === "GET";
    for (let attempt = 0; ; attempt++) {
      const token = await this.accessToken();
      let r: Response;
      this.calls++;
      try {
        r = await this.f(url.toString(), {
          method,
          headers: { "x-amz-access-token": token, "Content-Type": "application/json", "Accept": "application/json",
                     "User-Agent": "WeOneCRM-Amazon/1.0 (Language=TypeScript)" },
          body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
        });
      } catch (e) {
        if (!isRead) throw new UnknownOutcome(`Network error during ${method} ${path}: ${String(e)}`);
        if (attempt < this.maxRetries) { await this.sleep(Math.min(1000 * 2 ** attempt, 30000)); continue; }
        throw e;
      }
      if (r.status === 429 && attempt < this.maxRetries) {
        const ms = this.wait(r, attempt);
        this.log(`429 on ${method} ${path}; retry ${attempt + 1} in ${ms} ms`);
        await this.sleep(ms);
        continue;
      }
      if (r.status >= 500) {
        if (!isRead) throw new UnknownOutcome(`Amazon ${r.status} during ${method} ${path}`);
        if (attempt < this.maxRetries) { await this.sleep(this.wait(r, attempt)); continue; }
      }
      const text = await r.text();
      let body: any = null;
      try { body = text ? JSON.parse(text) : null; } catch { body = text; }
      if (!r.ok) {
        const e0 = body?.errors?.[0] || {};
        throw new SpApiError(r.status, e0.code || String(r.status), e0.message || `Amazon ${r.status}`, body);
      }
      return body;
    }
  }

  // ---------------------------------------------------------------- endpoints used by the module
  marketplaceParticipations() { return this.request("GET", "/sellers/v1/marketplaceParticipations"); }

  getListing(sellerId: string, sku: string) {
    return this.request("GET", `/listings/2021-08-01/items/${enc(sellerId)}/${enc(sku)}`, {
      query: { marketplaceIds: this.marketplaceId, includedData: "summaries,attributes,issues,offers,fulfillmentAvailability",
               issueLocale: "en_US" } });
  }

  searchListings(sellerId: string, pageToken?: string) {
    return this.request("GET", `/listings/2021-08-01/items/${enc(sellerId)}`, {
      query: { marketplaceIds: this.marketplaceId, includedData: "summaries,attributes,issues,offers,fulfillmentAvailability,relationships",
               pageSize: "20", pageToken } });
  }

  patchListing(sellerId: string, sku: string, productType: string, patches: unknown[], preview: boolean) {
    return this.request("PATCH", `/listings/2021-08-01/items/${enc(sellerId)}/${enc(sku)}`, {
      query: { marketplaceIds: this.marketplaceId, mode: preview ? "VALIDATION_PREVIEW" : undefined, issueLocale: "en_US" },
      body: { productType, patches } });
  }

  competitiveSummary(asins: string[]) {
    return this.request("POST", "/batches/products/pricing/2022-05-01/items/competitiveSummary", {
      body: { requests: asins.map((asin) => ({ asin, marketplaceId: this.marketplaceId,
        includedData: ["featuredBuyingOptions", "lowestPricedOffers"],
        method: "GET", uri: "/products/pricing/2022-05-01/items/competitiveSummary" })) } }).catch((e) => {
      // A POST that only reads: safe to surface as a normal error rather than an unknown write.
      if (e instanceof UnknownOutcome) throw new SpApiError(503, "Unavailable", e.message);
      throw e;
    });
  }

  catalogItems(asins: string[]) {
    return this.request("GET", "/catalog/2022-04-01/items", {
      query: { identifiers: asins, identifiersType: "ASIN", marketplaceIds: this.marketplaceId,
               includedData: "summaries,salesRanks,images" } });
  }

  createReport(reportType: string, start: string, end: string, options?: Record<string, string>) {
    return this.request("POST", "/reports/2021-06-30/reports", {
      body: { reportType, marketplaceIds: [this.marketplaceId], dataStartTime: start, dataEndTime: end, reportOptions: options } })
      .catch((e) => { if (e instanceof UnknownOutcome) throw new SpApiError(503, "Unavailable", e.message); throw e; });
  }
  getReport(id: string) { return this.request("GET", `/reports/2021-06-30/reports/${enc(id)}`); }
  getReportDocument(id: string) { return this.request("GET", `/reports/2021-06-30/documents/${enc(id)}`); }
  financialEvents(postedAfter: string, nextToken?: string) {
    return this.request("GET", "/finances/v0/financialEvents", { query: { PostedAfter: postedAfter, NextToken: nextToken, MaxResultsPerPage: "100" } });
  }
}

const enc = encodeURIComponent;

// ---------------------------------------------------------------- Settings > Test Connection
export async function testConnection(api: SpApi): Promise<{ status: TestStatus; detail: string }> {
  try {
    const r = await api.marketplaceParticipations();
    const list: any[] = r?.payload || [];
    const india = list.find((p) => p?.marketplace?.id === api.marketplaceId);
    if (!india) return { status: "Wrong marketplace", detail: TEST_FIX["Wrong marketplace"] };
    if (india.participation && india.participation.isParticipating === false) {
      return { status: "Wrong marketplace", detail: "The account is registered for Amazon.in but not currently selling there." };
    }
    return { status: "Connected", detail: TEST_FIX["Connected"] };
  } catch (e) {
    if (e instanceof LwaError) {
      const s: TestStatus = e.kind === "invalid_client" ? "Invalid client" : e.kind === "invalid_grant" ? "Token revoked"
        : e.kind === "throttled" ? "Throttled" : "Error";
      return { status: s, detail: TEST_FIX[s] };
    }
    if (e instanceof SpApiError && e.status === 429) return { status: "Throttled", detail: TEST_FIX["Throttled"] };
    if (e instanceof SpApiError && e.status === 403) return { status: "Token revoked", detail: "Amazon refused access (403). " + TEST_FIX["Token revoked"] };
    return { status: "Error", detail: TEST_FIX["Error"] };
  }
}

// ---------------------------------------------------------------- listing <-> CRM fields
const first = (a: any) => (Array.isArray(a) && a.length ? a[0] : undefined);
const val = (a: any) => first(a)?.value;

export function parseListing(item: any, sellerSkuFallback?: string) {
  const s = first(item?.summaries) || {};
  const a = item?.attributes || {};
  const offer = (item?.offers || []).find((o: any) => o.offerType === "B2C") || first(item?.offers);
  const fa = first(item?.fulfillmentAvailability) || {};
  const price = offer?.price?.amount ?? first(first(a.purchasable_offer)?.our_price)?.schedule?.[0]?.value_with_tax;
  const mrp = first(a.list_price)?.value_with_tax ?? first(a.list_price)?.value ?? val(a.maximum_retail_price);
  const status: string[] = s.status || [];
  const rel = first(item?.relationships)?.relationships || [];
  const isParent = rel.some((x: any) => Array.isArray(x.childSkus) && x.childSkus.length > 0);
  const parentSku = rel.find((x: any) => Array.isArray(x.parentSkus))?.parentSkus?.[0];
  const images: any[] = [];
  if (val(a.main_product_image_locator) || first(a.main_product_image_locator)?.media_location) {
    images.push({ slot: "MAIN", url: first(a.main_product_image_locator)?.media_location });
  } else if (s.mainImage?.link) {
    images.push({ slot: "MAIN", url: s.mainImage.link, width: s.mainImage.width, height: s.mainImage.height });
  }
  for (let i = 1; i <= 8; i++) {
    const loc = first(a[`other_product_image_locator_${i}`])?.media_location;
    if (loc) images.push({ slot: `PT0${i}`, url: loc });
  }
  return {
    sku: item?.sku || sellerSkuFallback,
    asin: s.asin,
    is_parent: isParent,
    parent_asin: parentSku ?? null,
    product_type: s.productType,
    status: status.includes("BUYABLE") ? "Active" : status.length ? status.join("/") : "Inactive",
    title: s.itemName ?? val(a.item_name),
    bullets: (a.bullet_point || []).map((b: any) => b.value),
    description: val(a.product_description) ?? null,
    backend_terms: val(a.generic_keyword) ?? null,
    price: price != null ? Number(price) : null,
    mrp: mrp != null ? Number(mrp) : null,
    quantity: fa.quantity ?? null,
    // Easy Ship dispatch time (handling time): 0 = same day, 1 = next day. Null when Amazon does not return it.
    handling_days: (() => { const d = first(a.fulfillment_availability)?.lead_time_to_ship_max_days;
      return d == null || d === "" || Number.isNaN(Number(d)) ? null : Number(d); })(),
    fulfillment: fa.fulfillmentChannelCode && fa.fulfillmentChannelCode !== "DEFAULT" ? "FBA" : "FBM",
    country_of_origin: val(a.country_of_origin) ?? null,
    manufacturer: val(a.manufacturer) ?? null,
    net_quantity: val(a.net_content) ?? val(a.item_package_quantity)?.toString() ?? null,
    attributes: a,
    images,
    issues: (item?.issues || []).map((i: any) => ({ code: i.code, message: i.message, severity: i.severity })),
  };
}

// Fields the module can push, and how. Anything else is reported as notPushed (set by hand in Seller Central).
export function buildPatches(after: Record<string, any>, mk: string, lang: string, before: Record<string, any> = {}) {
  const patches: any[] = [];
  const notPushed: string[] = [];
  // Stock and dispatch time share one attribute; send them together as one merge so nothing else is touched.
  const fa: Record<string, unknown> = { fulfillment_channel_code: "DEFAULT" };
  if (after.handling_days != null) fa.lead_time_to_ship_max_days = Number(after.handling_days);
  if (after.quantity != null) fa.quantity = Number(after.quantity);
  if (Object.keys(fa).length > 1) patches.push({ op: "merge", path: "/attributes/fulfillment_availability", value: [fa] });
  const text = (name: string, v: string) => patches.push({ op: "replace", path: `/attributes/${name}`,
    value: [{ value: v, language_tag: lang, marketplace_id: mk }] });
  for (const [k, v] of Object.entries(after)) {
    if (v === undefined || v === null) continue;
    switch (k) {
      case "title": text("item_name", String(v)); break;
      case "description": text("product_description", String(v)); break;
      case "backend_terms": text("generic_keyword", String(v)); break;
      case "manufacturer": text("manufacturer", String(v)); break;
      case "bullets":
        patches.push({ op: "replace", path: "/attributes/bullet_point",
          value: (v as string[]).map((b) => ({ value: b, language_tag: lang, marketplace_id: mk })) });
        break;
      case "price":
        patches.push({ op: "replace", path: "/attributes/purchasable_offer", value: [{ marketplace_id: mk, currency: "INR",
          our_price: [{ schedule: [{ value_with_tax: Number(v) }] }] }] });
        break;
      case "mrp":
        patches.push({ op: "replace", path: "/attributes/list_price",
          value: [{ marketplace_id: mk, currency: "INR", value_with_tax: Number(v) }] });
        break;
      case "country_of_origin":
        patches.push({ op: "replace", path: "/attributes/country_of_origin", value: [{ value: String(v), marketplace_id: mk }] });
        break;
      case "handling_days": case "quantity": break;   // sent above as one fulfillment_availability merge
      case "images": {
        // Ordered photos; the first is the cover. Slots that had a photo before and are now empty are deleted.
        const urls = (v as any[]).map((x) => (typeof x === "string" ? x : x?.url)).filter(Boolean).slice(0, 9);
        const had = Array.isArray(before.images) ? before.images.length : 0;
        if (urls[0]) patches.push({ op: "replace", path: "/attributes/main_product_image_locator", value: [{ media_location: urls[0], marketplace_id: mk }] });
        for (let i = 1; i <= 8; i++) {
          const path = `/attributes/other_product_image_locator_${i}`;
          if (urls[i]) patches.push({ op: "replace", path, value: [{ media_location: urls[i], marketplace_id: mk }] });
          else if (i < had) patches.push({ op: "delete", path, value: [{ marketplace_id: mk }] });
        }
        break;
      }
      case "attributes":
        // Product details, already in Amazon's own shape ([{value, language_tag?, ...}]). null = remove the detail.
        for (const [name, val] of Object.entries(v as Record<string, any>)) {
          if (!/^[a-z][a-z0-9_]{1,63}$/.test(name)) continue;
          if (val == null) {
            const old = before.attributes?.[name];
            patches.push({ op: "delete", path: `/attributes/${name}`,
              value: Array.isArray(old) && old.length ? old.map((o: any) => ({ marketplace_id: o?.marketplace_id ?? mk, ...(o?.language_tag ? { language_tag: o.language_tag } : {}) })) : [{ marketplace_id: mk }] });
          } else {
            patches.push({ op: "replace", path: `/attributes/${name}`,
              value: (val as any[]).map((o) => ({ ...o, marketplace_id: o?.marketplace_id ?? mk })) });
          }
        }
        break;
      case "main_image":
        if ((v as any)?.url) {
          patches.push({ op: "replace", path: "/attributes/main_product_image_locator",
            value: [{ media_location: (v as any).url, marketplace_id: mk }] });
        } else notPushed.push("main_image (no public URL)");
        break;
      case "claims": case "asin": case "product_type": break;   // CRM-only metadata
      default: notPushed.push(k);                                 // item_highlights, net_quantity, daily_budget_total ...
    }
  }
  return { patches, notPushed };
}

// After a push, did Amazon really take our values?
export function verifyApplied(after: Record<string, any>, live: ReturnType<typeof parseListing>) {
  const bad: string[] = [];
  const same = (a: unknown, b: unknown) => String(a ?? "").trim() === String(b ?? "").trim();
  if ("title" in after && !same(after.title, live.title)) bad.push("title");
  if ("price" in after && Number(after.price) !== Number(live.price)) bad.push("price");
  if ("backend_terms" in after && !same(after.backend_terms, live.backend_terms)) bad.push("backend_terms");
  if ("description" in after && !same(after.description, live.description)) bad.push("description");
  if ("bullets" in after && JSON.stringify(after.bullets) !== JSON.stringify(live.bullets)) bad.push("bullets");
  if ("handling_days" in after && live.handling_days != null && Number(after.handling_days) !== live.handling_days) bad.push("handling_days");
  // Not verified on purpose: photos (Amazon re-hosts them, URLs change), stock (orders move it), details (Amazon normalises values).
  return bad;
}

export const isSuppressed = (live: ReturnType<typeof parseListing>) =>
  live.issues.some((i: any) => i.severity === "ERROR") || /SUPPRESS|INACTIVE/i.test(live.status || "");

// ---------------------------------------------------------------- pricing / catalog / reports
export function parseCompetitiveSummary(resp: any, sellerId: string) {
  return (resp?.responses || []).map((r: any) => {
    const b = r?.body || {};
    const asin = b.asin || r?.request?.asin;
    const fbo = first(b.featuredBuyingOptions);
    const seg = first(fbo?.segmentedFeaturedOffers);
    const price = seg?.listingPrice?.amount ?? seg?.price?.amount ?? null;
    const seller = seg?.sellerId ?? null;
    return { asin, buybox_price: price, buybox_seller: seller,
             my_seller_has_buybox: seller == null ? null : seller === sellerId };
  }).filter((x: any) => x.asin);
}

export function parseCatalog(resp: any) {
  return (resp?.items || []).map((it: any) => ({
    asin: it.asin,
    title: first(it.summaries)?.itemName ?? null,
    bsr: first(first(it.salesRanks)?.displayGroupRanks)?.rank ?? first(first(it.salesRanks)?.classificationRanks)?.rank ?? null,
    image_count: first(it.images)?.images?.length ?? null,
  }));
}

// GET_SALES_AND_TRAFFIC_REPORT for ONE day with asinGranularity=SKU -> one row per SKU for that day.
export function parseSalesTraffic(doc: any, day: string) {
  return (doc?.salesAndTrafficByAsin || []).map((r: any) => ({
    day, sku: r.sku, asin: r.childAsin || r.parentAsin,
    units: r.salesByAsin?.unitsOrdered ?? 0,
    revenue: r.salesByAsin?.orderedProductSales?.amount ?? 0,
    sessions: r.trafficByAsin?.sessions ?? null,
    page_views: r.trafficByAsin?.pageViews ?? null,
    buybox_pct: r.trafficByAsin?.buyBoxPercentage ?? null,
  })).filter((x: any) => x.sku);
}

// GET_FLAT_FILE_ALL_ORDERS_DATA_BY_ORDER_DATE_GENERAL (tab-separated) -> units and sales per SKU per IST day.
// Used instead of the Sales & Traffic report, which needs the Brand Analytics role (Brand Registry only).
// Cancelled lines count as 0 but still produce a row, so a later cancellation overwrites the earlier count.
export function parseOrdersReport(tsv: string) {
  const lines = String(tsv || "").replace(/\r/g, "").split("\n").filter((l) => l.trim());
  if (lines.length < 2) return [];
  const head = lines[0].split("\t");
  const col = (n: string) => head.indexOf(n);
  const [iDate, iSku, iAsin, iQty, iPrice, iOs, iIs] = ["purchase-date", "sku", "asin", "quantity", "item-price", "order-status", "item-status"].map(col);
  const agg = new Map<string, { day: string; sku: string; asin: string; units: number; revenue: number }>();
  for (const line of lines.slice(1)) {
    const c = line.split("\t");
    const sku = c[iSku]; const when = c[iDate];
    if (!sku || !when) continue;
    const day = istDay(when);
    const k = `${day}|${sku}`;
    const r = agg.get(k) || { day, sku, asin: c[iAsin] || "", units: 0, revenue: 0 };
    const cancelled = /cancel/i.test(c[iOs] || "") || /cancel/i.test(c[iIs] || "");
    if (!cancelled) { r.units += Number(c[iQty]) || 0; r.revenue += Number(c[iPrice]) || 0; }
    agg.set(k, r);
  }
  return [...agg.values()].map((r) => ({ ...r, revenue: Math.round(r.revenue * 100) / 100 }));
}

// GET_V2_SELLER_PERFORMANCE_REPORT -> percentages (seller-fulfilled figures; this account is FBM only).
export function parsePerformance(doc: any) {
  const m = first(doc?.performanceMetrics) || {};
  const pct = (x: any) => (x == null ? null : Math.round(Number(x) * 100000) / 1000);
  return {
    odr: pct(m.orderDefectRate?.mfn?.rate ?? m.orderDefectRate?.rate),
    cancel_rate: pct(m.preFulfillmentCancellationRate?.rate),
    late_ship_rate: pct(m.lateShipmentRate?.rate),
    valid_tracking_rate: pct(m.validTrackingRate?.rate),
    policy_issues: Object.values(m).reduce((n: number, v: any) => n + (v && typeof v === "object" && "defectsCount" in v ? Number(v.defectsCount) || 0 : 0), 0),
  };
}

// IST calendar day for a timestamp.
export const istDay = (t: Date | string) =>
  new Date(new Date(t).getTime() + 5.5 * 3600 * 1000).toISOString().slice(0, 10);
// [start, end] UTC ISO strings covering one IST day.
export function istDayRange(day: string): [string, string] {
  const start = new Date(`${day}T00:00:00+05:30`);
  return [start.toISOString(), new Date(start.getTime() + 86400000 - 1000).toISOString()];
}
