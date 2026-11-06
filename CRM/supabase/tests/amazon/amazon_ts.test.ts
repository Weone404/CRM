// Unit tests for the Amazon Edge Function code (run locally: bun test supabase/tests/amazon).
// Amazon is replaced by a scripted fake; nothing here calls the real API.
import { describe, expect, test } from "bun:test";
import { SpApi, LwaError, testConnection, buildPatches, parseListing, parseCompetitiveSummary, parseSalesTraffic,
  parsePerformance, istDayRange, istDay } from "../../functions/_shared/amazon.ts";
import { execute, reconcile, staleFields } from "../../functions/_shared/amazon_exec.ts";

type Step = { status: number; body?: unknown; headers?: Record<string, string> } | Error;
function fakeAmazon(script: Record<string, Step[]>) {
  const log: { method: string; url: string; body?: any }[] = [];
  const fetch = async (url: string, init?: RequestInit) => {
    const method = init?.method || "GET";
    const u = new URL(url);
    const key = url.startsWith("https://api.amazon.com") ? "LWA"
      : `${method} ${u.pathname}${u.searchParams.get("mode") ? "?preview" : ""}`;
    log.push({ method, url, body: init?.body && typeof init.body === "string" ? JSON.parse(init.body) : undefined });
    const q = script[key] || script[`${method} *`];
    if (!q || !q.length) throw new Error(`unscripted call ${key}`);
    const step = q.length > 1 ? q.shift()! : q[0];
    if (step instanceof Error) throw step;
    return new Response(step.body === undefined ? "" : JSON.stringify(step.body), { status: step.status, headers: step.headers });
  };
  return { fetch, log };
}
const LWA_OK = { status: 200, body: { access_token: "Atza|x", expires_in: 3600 } };
const sleeps: number[] = [];
const mkApi = (fetch: any) => new SpApi({ clientId: "amzn1.application-oa2-client.x", clientSecret: "s", refreshToken: "Atzr|r",
  fetch, sleep: async (ms) => { sleeps.push(ms); }, maxRetries: 5 });

const SELLER = "A1SELLER0001";
const secrets = { AMZ_SELLER_ID: SELLER, MARKETPLACE_ID: "A21TJRUUN4KGV", LANGUAGE_TAG: "en_IN" };
const listing = (title: string, price = 449, extra: any = {}) => ({ status: 200, body: {
  sku: "69-E0DG-L8W8",
  summaries: [{ asin: "B0HJ4XXK37", productType: "NOTEBOOK", status: ["BUYABLE", "DISCOVERABLE"], itemName: title }],
  attributes: { item_name: [{ value: title }], purchasable_offer: [{ our_price: [{ schedule: [{ value_with_tax: price }] }] }] },
  offers: [{ offerType: "B2C", price: { amount: price } }], fulfillmentAvailability: [{ fulfillmentChannelCode: "DEFAULT", quantity: 100 }],
  issues: [], ...extra } });

function fakeDb(change: any) {
  const calls: { fn: string; args: any }[] = [];
  let claimed = false;
  const rpc = async (fn: string, args: any = {}) => {
    calls.push({ fn, args });
    if (fn === "svc_amz_claim") { if (claimed) return null; claimed = true; return change; }
    if (fn === "svc_amz_finish") return { status: args.p_status };
    return null;
  };
  return { rpc, calls, finish: () => calls.find((c) => c.fn === "svc_amz_finish")?.args };
}
const change = (after: any, before: any = { title: "Old title", price: 449 }) =>
  ({ id: "c1", kind: "listing", sku: "69-E0DG-L8W8", seller_sku: "69-E0DG-L8W8", product_type: "NOTEBOOK", before, after });

describe("SP-API client", () => {
  test("429 is retried with backoff, honoring Retry-After, and succeeds", async () => {
    sleeps.length = 0;
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK], "GET /sellers/v1/marketplaceParticipations": [
      { status: 429, headers: { "retry-after": "2" } }, { status: 429 }, { status: 200, body: { payload: [] } }] });
    const api = mkApi(fetch);
    await api.marketplaceParticipations();
    expect(log.filter((l) => l.url.includes("marketplaceParticipations")).length).toBe(3);
    expect(sleeps[0]).toBe(2000);                       // Retry-After: 2
    expect(sleeps[1]).toBeGreaterThanOrEqual(2000);     // exponential: 2^1 s (+ jitter)
  });

  test("access token is cached across calls", async () => {
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK], "GET /sellers/v1/marketplaceParticipations": [{ status: 200, body: { payload: [] } }] });
    const api = mkApi(fetch);
    await api.marketplaceParticipations(); await api.marketplaceParticipations();
    expect(log.filter((l) => l.url.startsWith("https://api.amazon.com")).length).toBe(1);
  });

  test("gives up after max retries on persistent 429", async () => {
    const { fetch } = fakeAmazon({ LWA: [LWA_OK], "GET /sellers/v1/marketplaceParticipations": [{ status: 429 }] });
    const api = new SpApi({ clientId: "a", clientSecret: "b", refreshToken: "c", fetch, sleep: async () => {}, maxRetries: 3 });
    await expect(api.marketplaceParticipations()).rejects.toMatchObject({ status: 429 });
  });

  test("missing keys fail fast without calling Amazon", () => {
    expect(() => new SpApi({ clientId: "", clientSecret: "", refreshToken: "" })).toThrow(LwaError);
  });
});

describe("Test Connection (Settings)", () => {
  const run = async (script: Record<string, Step[]>) => testConnection(mkApi(fakeAmazon(script).fetch));
  test("Connected", async () => {
    expect((await run({ LWA: [LWA_OK], "GET /sellers/v1/marketplaceParticipations": [{ status: 200, body: { payload: [
      { marketplace: { id: "A21TJRUUN4KGV" }, participation: { isParticipating: true } }] } }] })).status).toBe("Connected");
  });
  test("Wrong marketplace (keys for amazon.com)", async () => {
    expect((await run({ LWA: [LWA_OK], "GET /sellers/v1/marketplaceParticipations": [{ status: 200, body: { payload: [
      { marketplace: { id: "ATVPDKIKX0DER" }, participation: { isParticipating: true } }] } }] })).status).toBe("Wrong marketplace");
  });
  test("Invalid client", async () => {
    expect((await run({ LWA: [{ status: 401, body: { error: "invalid_client", error_description: "Client authentication failed" } }] })).status).toBe("Invalid client");
  });
  test("Token revoked (X09)", async () => {
    expect((await run({ LWA: [{ status: 400, body: { error: "invalid_grant" } }] })).status).toBe("Token revoked");
  });
  test("Throttled", async () => {
    expect((await run({ LWA: [{ status: 429 }] })).status).toBe("Throttled");
  });
});

describe("listing mapping", () => {
  test("buildPatches maps fields for India and reports what the API cannot set", () => {
    const { patches, notPushed } = buildPatches({ title: "T", price: 399, bullets: ["a", "b"], item_highlights: "h", claims: ["x"] }, "A21TJRUUN4KGV", "en_IN");
    expect(patches.map((p) => p.path)).toEqual(["/attributes/item_name", "/attributes/purchasable_offer", "/attributes/bullet_point"]);
    expect(patches[0].value[0]).toEqual({ value: "T", language_tag: "en_IN", marketplace_id: "A21TJRUUN4KGV" });
    expect(patches[1].value[0].our_price[0].schedule[0].value_with_tax).toBe(399);
    expect(notPushed).toEqual(["item_highlights"]);
  });
  test("parseListing reads summaries, price, FBM quantity and issues", () => {
    const l = parseListing(listing("Nitaniya 2027 Diary", 449, { issues: [{ code: "90220", message: "missing country_of_origin", severity: "ERROR" }] }).body);
    expect(l).toMatchObject({ asin: "B0HJ4XXK37", title: "Nitaniya 2027 Diary", price: 449, fulfillment: "FBM", quantity: 100, status: "Active" });
    expect(l.issues[0].severity).toBe("ERROR");
  });
  test("competitive summary: Buy Box held by another seller", () => {
    const r = parseCompetitiveSummary({ responses: [{ body: { asin: "B0GGHDXNY1", featuredBuyingOptions: [{ segmentedFeaturedOffers: [
      { sellerId: "OTHER1", listingPrice: { amount: 329 } }] }] } }] }, SELLER);
    expect(r[0]).toEqual({ asin: "B0GGHDXNY1", buybox_price: 329, buybox_seller: "OTHER1", my_seller_has_buybox: false });
  });
  test("sales & traffic and performance parsing; IST day bounds", () => {
    const rows = parseSalesTraffic({ salesAndTrafficByAsin: [{ sku: "S1", childAsin: "B1",
      salesByAsin: { unitsOrdered: 3, orderedProductSales: { amount: 1197 } }, trafficByAsin: { sessions: 40, pageViews: 55, buyBoxPercentage: 100 } }] }, "2026-11-05");
    expect(rows[0]).toMatchObject({ day: "2026-11-05", sku: "S1", units: 3, revenue: 1197, sessions: 40 });
    expect(parsePerformance({ performanceMetrics: [{ orderDefectRate: { mfn: { rate: 0.0042 } }, preFulfillmentCancellationRate: { rate: 0.01 },
      lateShipmentRate: { rate: 0.02 }, validTrackingRate: { rate: 0.985 } }] })).toMatchObject({ odr: 0.42, cancel_rate: 1, late_ship_rate: 2, valid_tracking_rate: 98.5 });
    expect(istDayRange("2026-11-05")).toEqual(["2026-11-04T18:30:00.000Z", "2026-11-05T18:29:59.000Z"]);   // X21
    expect(istDay("2026-11-05T19:00:00Z")).toBe("2026-11-06");                                             // 00:30 IST next day
  });
});

describe("execute one approved change", () => {
  test("happy path: preview, submit once, verify -> live", async () => {
    const db = fakeDb(change({ title: "Nitaniya 2027 Diary B5 PU Leather" }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title"), listing("Nitaniya 2027 Diary B5 PU Leather")],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 200, body: { status: "ACCEPTED", submissionId: "s1", issues: [] } }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r.status).toBe("live");
    expect(log.filter((l) => l.method === "PATCH" && !l.url.includes("mode=")).length).toBe(1);
    expect(db.finish().p_status).toBe("live");
  });

  test("X06: running the same change twice executes it once", async () => {
    const db = fakeDb(change({ title: "Nitaniya 2027 Diary B5 PU Leather" }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title"), listing("Nitaniya 2027 Diary B5 PU Leather")],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 200, body: { status: "ACCEPTED", issues: [] } }] });
    const api = mkApi(fetch);
    const [a, b] = await Promise.all([execute(db.rpc, api, secrets, "c1"), execute(db.rpc, api, secrets, "c1")]);
    expect([a.status, b.status].sort()).toEqual(["live", "skipped"]);
    expect(log.filter((l) => l.method === "PATCH" && !l.url.includes("mode=")).length).toBe(1);
  });

  test("X08: 429 on the real submit backs off and submits exactly once", async () => {
    const db = fakeDb(change({ price: 399 }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title", 449), listing("Old title", 399)],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 429 }, { status: 429 }, { status: 200, body: { status: "ACCEPTED", issues: [] } }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    const submits = log.filter((l) => l.method === "PATCH" && !l.url.includes("mode="));
    expect(submits.length).toBe(3);                                      // 2 throttled (not processed by Amazon) + 1 accepted
    expect(r.status).toBe("live");
    expect(db.calls.filter((c) => c.fn === "svc_amz_finish").length).toBe(1);
  });

  test("X07: 5xx on submit is not retried; change stays Executing for reconcile", async () => {
    const db = fakeDb(change({ price: 399 }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title", 449)],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 503 }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r.status).toBe("executing");
    expect(log.filter((l) => l.method === "PATCH" && !l.url.includes("mode=")).length).toBe(1);
    expect(db.finish()).toBeUndefined();
  });

  test("X07b: reconcile settles a stuck change from Amazon's real state", async () => {
    const calls: any[] = [];
    const rpc = async (fn: string, args: any) => { calls.push({ fn, args }); return null; };
    const { fetch } = fakeAmazon({ LWA: [LWA_OK], "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title", 399)] });
    const out = await reconcile(rpc, mkApi(fetch), secrets, [{ id: "c1", sku: "69-E0DG-L8W8", after: { price: 399 }, executed_at: new Date().toISOString() }]);
    expect(out[0].status).toBe("live");
    expect(calls[0].args.p_status).toBe("live");
  });

  test("preview error -> failed, nothing submitted", async () => {
    const db = fakeDb(change({ title: "Nitaniya 2027 Diary" }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title")],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "INVALID",
        issues: [{ code: "8541", message: "value is not allowed", severity: "ERROR" }] } }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r.status).toBe("failed");
    expect(log.filter((l) => l.method === "PATCH" && !l.url.includes("mode=")).length).toBe(0);
    expect(db.finish().p_error).toContain("value is not allowed");
  });

  test("X05: Amazon changed the listing since the draft -> stale, nothing sent", async () => {
    const db = fakeDb(change({ title: "Our new title" }, { title: "Old title" }));
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Title someone set in Seller Central")] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r.status).toBe("stale");
    expect(log.some((l) => l.method === "PATCH")).toBe(false);
  });

  test("X14: listing suppressed after the change -> finish with rollback flag", async () => {
    const db = fakeDb(change({ title: "Nitaniya 2027 Diary" }));
    const { fetch } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title"),
        listing("Nitaniya 2027 Diary", 449, { issues: [{ code: "1", message: "suppressed", severity: "ERROR" }] })],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 200, body: { status: "ACCEPTED", issues: [] } }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r).toMatchObject({ status: "live", suppressed: true });
    expect(db.finish().p_suppressed).toBe(true);
  });

  test("fields the API cannot set -> needs manual after pushing the rest", async () => {
    const db = fakeDb(change({ title: "Nitaniya 2027 Diary", item_highlights: "A5, dated" }));
    const { fetch } = fakeAmazon({ LWA: [LWA_OK],
      "GET /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [listing("Old title"), listing("Nitaniya 2027 Diary")],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8?preview": [{ status: 200, body: { status: "VALID", issues: [] } }],
      "PATCH /listings/2021-08-01/items/A1SELLER0001/69-E0DG-L8W8": [{ status: 200, body: { status: "ACCEPTED", issues: [] } }] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c1");
    expect(r.status).toBe("needs_manual");
    expect(db.finish().p_error).toContain("item_highlights");
  });

  test("ads budget is never pushed automatically", async () => {
    const db = fakeDb({ id: "c2", kind: "ads_budget", after: { daily_budget_total: 300 } });
    const { fetch, log } = fakeAmazon({ LWA: [LWA_OK] });
    const r = await execute(db.rpc, mkApi(fetch), secrets, "c2");
    expect(r.status).toBe("needs_manual");
    expect(log.length).toBe(0);
  });

  test("staleFields ignores fields Amazon already shows at our new value", () => {
    expect(staleFields({ price: 449 }, { price: 399 }, { price: 399 })).toEqual([]);
    expect(staleFields({ price: 449 }, { price: 399 }, { price: 429 })).toEqual(["price"]);
  });
});
