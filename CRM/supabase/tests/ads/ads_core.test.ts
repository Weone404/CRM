// Unit tests for supabase/functions/_shared/ads_core.ts (Google Ads + Meta connectors).
// Run: node --experimental-strip-types --test supabase/tests/ads/ads_core.test.ts   (Node 22+)
// No network: every platform call goes to a fake fetch that records requests.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AdsError, GoogleAds, MetaAds, dateRange, executeOne, verify, googleErrorStatus, metaErrorStatus, metaMinorToUnits,
  microsToUnits, parseGoogleCampaign, parseGoogleMetric, parseMetaCampaign, parseMetaInsight, scrubSecrets, todayIn,
  unitsToMetaMinor, unitsToMicros,
} from "../../functions/_shared/ads_core.ts";

type Call = { url: string; init?: RequestInit };
function fakeFetch(routes: Array<[RegExp, (c: Call) => { status?: number; body: unknown } | Error]>) {
  const calls: Call[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    const c = { url, init }; calls.push(c);
    for (const [re, h] of routes) if (re.test(url + " " + String(init?.body ?? ""))) {
      const r = h(c);
      if (r instanceof Error) throw r;
      return new Response(JSON.stringify(r.body), { status: r.status ?? 200 });
    }
    return new Response(JSON.stringify({ error: { message: "no route " + url } }), { status: 404 });
  };
  return { fn, calls };
}
const G = { developerToken: "devtok123456", clientId: "x.apps.googleusercontent.com", clientSecret: "secret-abcdefgh",
  refreshToken: "1//refresh-abcdefghijk", loginCustomerId: "9998887777", version: "v26" };
const TOKEN = [/oauth2\.googleapis\.com\/token/, () => ({ body: { access_token: "ya29.token" } })] as [RegExp, any];

test("money conversions", () => {
  assert.equal(microsToUnits("1234560000"), 1234.56);
  assert.equal(microsToUnits(null), null);
  assert.equal(unitsToMicros(1500.5), "1500500000");
  assert.equal(metaMinorToUnits("50000", "INR"), 500);
  assert.equal(metaMinorToUnits("5000", "JPY"), 5000);
  assert.equal(unitsToMetaMinor(750, "INR"), "75000");
  assert.equal(unitsToMetaMinor(750, "KRW"), "750");
});

test("dates", () => {
  assert.deepEqual(dateRange(30, "2026-11-10"), { since: "2026-10-12", until: "2026-11-10" });
  assert.deepEqual(dateRange(1, "2026-03-01"), { since: "2026-03-01", until: "2026-03-01" });
  assert.equal(todayIn("Asia/Kolkata", new Date("2026-11-09T19:00:00Z")), "2026-11-10");   // 00:30 IST next day
  assert.equal(todayIn("America/Los_Angeles", new Date("2026-11-09T19:00:00Z")), "2026-11-09");
});

test("error classification", () => {
  assert.equal(googleErrorStatus(401, {}), "auth_required");
  assert.equal(googleErrorStatus(400, { error: { details: [{ errors: [{ errorCode: { authorizationError: "DEVELOPER_TOKEN_NOT_APPROVED" } }] }] } }), "permission_missing");
  assert.equal(googleErrorStatus(429, {}), "rate_limited");
  assert.equal(googleErrorStatus(503, {}), "unavailable");
  assert.equal(metaErrorStatus(400, { error: { code: 190 } }), "auth_required");
  assert.equal(metaErrorStatus(400, { error: { code: 17 } }), "rate_limited");
  assert.equal(metaErrorStatus(403, { error: { code: 200 } }), "permission_missing");
});

test("secrets are scrubbed", () => {
  const s = scrubSecrets("bad token EAAabcdefghijklmn and ya29.zzz and secret-abcdefgh and access_token=xyz", { a: "secret-abcdefgh" });
  assert.ok(!s.includes("EAAabcdefghijklmn") && !s.includes("ya29.zzz") && !s.includes("secret-abcdefgh") && !s.includes("xyz"));
});

test("google campaign parsing: shared and non-daily budgets are not editable", () => {
  const own = parseGoogleCampaign({ campaign: { id: "11", name: "A", status: "ENABLED", advertisingChannelType: "SEARCH" },
    campaignBudget: { resourceName: "customers/1/campaignBudgets/5", amountMicros: "2000000000", explicitlyShared: false, period: "DAILY" } });
  assert.equal(own.daily_budget, 2000); assert.equal(own.budget_ref, "customers/1/campaignBudgets/5"); assert.equal(own.status, "ENABLED");
  const shared = parseGoogleCampaign({ campaign: { id: "12", status: "PAUSED" }, campaignBudget: { resourceName: "r", amountMicros: "1000000", explicitlyShared: true } });
  assert.equal(shared.budget_ref, null);
  const odd = parseGoogleCampaign({ campaign: { id: "13", status: "UNKNOWN" }, campaignBudget: {} });
  assert.equal(odd.status, "OTHER"); assert.equal(odd.budget_ref, null);
});

test("google metric parsing", () => {
  const m = parseGoogleMetric({ campaign: { id: "11" }, segments: { date: "2026-11-01" },
    metrics: { impressions: "1000", clicks: "40", costMicros: "123450000", conversions: 3.5, conversionsValue: 900 } });
  assert.deepEqual([m.campaign_external_id, m.day, m.impressions, m.clicks, m.spend, m.conversions, m.conversion_value],
    ["11", "2026-11-01", 1000, 40, 123.45, 3.5, 900]);
});

test("meta parsing: campaign budget vs ad-set budget; lead action", () => {
  const cbo = parseMetaCampaign({ id: "7", name: "Leads", status: "ACTIVE", daily_budget: "150000" }, "INR");
  assert.equal(cbo.status, "ENABLED"); assert.equal(cbo.daily_budget, 1500); assert.equal(cbo.budget_ref, "campaign");
  const abo = parseMetaCampaign({ id: "8", status: "PAUSED" }, "INR");
  assert.equal(abo.daily_budget, null); assert.equal(abo.budget_ref, null);
  const i = parseMetaInsight({ campaign_id: "7", date_start: "2026-11-01", spend: "812.40", impressions: "9000", clicks: "120", reach: "7000",
    actions: [{ action_type: "link_click", value: "120" }, { action_type: "lead", value: "6" }], action_values: [] });
  assert.deepEqual([i.spend, i.conversions, i.conversion_value, i.reach], [812.4, 6, 0, 7000]);
});

test("google search pages through results and sends the right headers", async () => {
  let page = 0;
  const f = fakeFetch([TOKEN, [/googleAds:search/, () => ({ body: page++ === 0
    ? { results: [{ campaign: { id: "1" } }], nextPageToken: "p2" } : { results: [{ campaign: { id: "2" } }] } })]]);
  const g = new GoogleAds(G, f.fn);
  const rows = await g.search("1112223333", "SELECT campaign.id FROM campaign");
  assert.equal(rows.length, 2);
  const h = f.calls[1].init!.headers as Record<string, string>;
  assert.equal(h["developer-token"], undefined, "developer token not sent (retired 2026-09-09)"); assert.equal(h["login-customer-id"], "9998887777");
  assert.equal(h.Authorization, "Bearer ya29.token");
  assert.match(f.calls[1].url, /\/v26\/customers\/1112223333\/googleAds:search$/);
  assert.equal(JSON.parse(String(f.calls[2].init!.body)).pageToken, "p2");
  assert.equal(f.calls.filter((c) => /oauth2/.test(c.url)).length, 1, "token fetched once");
});

test("google bad refresh token -> auth_required", async () => {
  const f = fakeFetch([[/oauth2/, () => ({ status: 400, body: { error: "invalid_grant", error_description: "Token has been expired or revoked." } })]]);
  await assert.rejects(new GoogleAds(G, f.fn).account("1112223333"), (e: AdsError) => e.status === "auth_required" && /revoked/.test(e.message));
});

test("google missing credentials are refused before any request; developer token is no longer needed", () => {
  assert.throws(() => new GoogleAds({ ...G, clientId: "" }, fakeFetch([]).fn), /clientId/);
  assert.doesNotThrow(() => new GoogleAds({ ...G, developerToken: undefined }, fakeFetch([]).fn));
});

test("google project with only Test access gets a plain explanation", async () => {
  const f = fakeFetch([TOKEN, [/googleAds:search/, () => ({ status: 403, body: { error: { status: "PERMISSION_DENIED",
    details: [{ errors: [{ errorCode: { authorizationError: "CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION" }, message: "x" }] }] } } })]]);
  await assert.rejects(new GoogleAds(G, f.fn).account("1112223333"), (e: AdsError) => e.status === "permission_missing" && /Explorer\/Basic access/.test(e.message));
});

const W = { id: "q1", kind: "budget" as const, after: { daily_budget: 1500 }, platform: "google" as const,
  account_external_id: "1112223333", campaign_external_id: "11", budget_ref: "customers/1112223333/campaignBudgets/5" };

test("execute google budget: mutate then read back -> verified", async () => {
  const f = fakeFetch([TOKEN,
    [/campaignBudgets:mutate/, () => ({ body: { results: [{ resourceName: "customers/1112223333/campaignBudgets/5" }] } })],
    [/googleAds:search/, () => ({ body: { results: [{ campaign: { status: "ENABLED" }, campaignBudget: { amountMicros: "1500000000" } }] } })]]);
  const r = await executeOne({ google: new GoogleAds(G, f.fn) }, W);
  assert.equal(r.status, "verified");
  const mut = JSON.parse(String(f.calls.find((c) => /mutate/.test(c.url))!.init!.body));
  assert.deepEqual(mut.operations[0], { update: { resourceName: W.budget_ref, amountMicros: "1500000000" }, updateMask: "amount_micros" });
});

test("execute: platform accepts but shows old value -> failed (not success)", async () => {
  const f = fakeFetch([TOKEN, [/mutate/, () => ({ body: {} })],
    [/googleAds:search/, () => ({ body: { results: [{ campaign: { status: "ENABLED" }, campaignBudget: { amountMicros: "1000000000" } }] } })]]);
  const r = await executeOne({ google: new GoogleAds(G, f.fn) }, W);
  assert.equal(r.status, "failed");
});

test("execute: platform rejects -> failed with its message", async () => {
  const f = fakeFetch([TOKEN, [/mutate/, () => ({ status: 400, body: { error: { status: "INVALID_ARGUMENT", details: [{ errors: [{ message: "Budget amount is too low." }] }] } } })]]);
  const r = await executeOne({ google: new GoogleAds(G, f.fn) }, W);
  assert.equal(r.status, "failed"); assert.match(r.error!, /too low/);
});

test("execute: network drop during the change -> outcome_unknown, never retried", async () => {
  const f = fakeFetch([TOKEN, [/mutate/, () => new TypeError("connection reset")]]);
  const r = await executeOne({ google: new GoogleAds(G, f.fn) }, W);
  assert.equal(r.status, "outcome_unknown");
  assert.equal(f.calls.filter((c) => /mutate/.test(c.url)).length, 1);
});

test("execute: sent but read-back fails -> outcome_unknown; later verify resolves it", async () => {
  let reads = 0;
  const f = fakeFetch([TOKEN, [/mutate/, () => ({ body: {} })],
    [/googleAds:search/, () => (reads++ === 0 ? new TypeError("timeout")
      : { body: { results: [{ campaign: { status: "ENABLED" }, campaignBudget: { amountMicros: "1500000000" } }] } })]]);
  const g = new GoogleAds(G, f.fn);
  assert.equal((await executeOne({ google: g }, W)).status, "outcome_unknown");
  assert.equal((await verify({ google: g }, W)).status, "verified");
  assert.equal(f.calls.filter((c) => /mutate/.test(c.url)).length, 1, "re-check only reads");
});

test("execute meta: pause uses Graph POST and verifies", async () => {
  const f = fakeFetch([
    [/graph\.facebook\.com\/v26\.0\/777 status=PAUSED/, () => ({ body: { success: true } })],
    [/graph\.facebook\.com\/v26\.0\/777\?/, () => ({ body: { status: "PAUSED", daily_budget: "150000" } })]]);
  const m = new MetaAds({ accessToken: "EAAtoken1234567", version: "v26.0" }, f.fn);
  const r = await executeOne({ meta: m, metaCurrency: () => "INR" },
    { id: "q2", kind: "status", after: { status: "PAUSED" }, platform: "meta", account_external_id: "998877", campaign_external_id: "777", budget_ref: "campaign" });
  assert.equal(r.status, "verified");
  assert.equal((f.calls[0].init!.headers as Record<string, string>).Authorization, "Bearer EAAtoken1234567");
  assert.ok(!f.calls[0].url.includes("EAAtoken"), "token never in the URL");
});

test("meta budget in minor units; ad-set budget refused", async () => {
  const f = fakeFetch([[/daily_budget=200000/, () => ({ body: { success: true } })],
    [/\?fields=status/, () => ({ body: { status: "ACTIVE", daily_budget: "200000" } })]]);
  const m = new MetaAds({ accessToken: "EAAtoken1234567", version: "v26.0" }, f.fn);
  const base = { id: "q3", kind: "budget" as const, after: { daily_budget: 2000 }, platform: "meta" as const, account_external_id: "1", campaign_external_id: "9" };
  assert.equal((await executeOne({ meta: m, metaCurrency: () => "INR" }, { ...base, budget_ref: "campaign" })).status, "verified");
  const r = await executeOne({ meta: m, metaCurrency: () => "INR" }, { ...base, budget_ref: null });
  assert.equal(r.status, "failed"); assert.match(r.error!, /campaign-level/);
});

test("meta expired token -> auth_required; appsecret_proof added when app secret set", async () => {
  const f = fakeFetch([[/me\?/, () => ({ status: 400, body: { error: { code: 190, type: "OAuthException", message: "Session has expired" } } })]]);
  const m = new MetaAds({ accessToken: "EAAtoken1234567", appSecret: "appsecret", version: "v26.0", hmac: async () => "proofhex" }, f.fn);
  await assert.rejects(m.me(), (e: AdsError) => e.status === "auth_required");
  assert.match(f.calls[0].url, /appsecret_proof=proofhex/);
});

test("meta insights paginate via paging.next", async () => {
  let n = 0;
  const f = fakeFetch([[/insights|page2/, () => ({ body: n++ === 0
    ? { data: [{ campaign_id: "1", date_start: "2026-11-01", spend: "10" }], paging: { next: "https://graph.facebook.com/v26.0/page2" } }
    : { data: [{ campaign_id: "1", date_start: "2026-11-02", spend: "12" }] } })]]);
  const rows = await new MetaAds({ accessToken: "EAAtoken1234567", version: "v26.0" }, f.fn).metrics("998877", "2026-11-01", "2026-11-02");
  assert.deepEqual(rows.map((r) => r.spend), [10, 12]);
  assert.match(decodeURIComponent(f.calls[0].url), /time_range=\{"since":"2026-11-01","until":"2026-11-02"\}/);
});

// ---------------------------------------------------------------- discovery (Import existing accounts)
import { discover } from "../../functions/_shared/ads_core.ts";

test("google discovery: accessible accounts + accounts under a manager, managers themselves excluded, direct access preferred", async () => {
  const f = fakeFetch([TOKEN,
    [/customers:listAccessibleCustomers/, () => ({ body: { resourceNames: ["customers/9998887777", "customers/1112223333"] } })],
    [/customers\/9998887777\/googleAds:search/, () => ({ body: { results: [
      { customerClient: { clientCustomer: "customers/9998887777", descriptiveName: "My MCC", manager: true, status: "ENABLED", level: 0 } },
      { customerClient: { clientCustomer: "customers/1112223333", descriptiveName: "Client A", manager: false, status: "ENABLED", currencyCode: "INR", timeZone: "Asia/Kolkata", level: 1 } },
      { customerClient: { clientCustomer: "customers/4445556666", descriptiveName: "Client B", manager: false, status: "CANCELED", currencyCode: "USD", timeZone: "America/New_York", level: 1 } }] } })],
    [/customers\/1112223333\/googleAds:search/, () => ({ body: { results: [
      { customerClient: { clientCustomer: "customers/1112223333", descriptiveName: "Client A", manager: false, status: "ENABLED", currencyCode: "INR", timeZone: "Asia/Kolkata", level: 0 } }] } })]]);
  const r = await discover({ google: new GoogleAds({ ...G, loginCustomerId: undefined }, f.fn) });
  assert.equal(r.google.ok, true);
  assert.deepEqual(r.google.accounts.map((a) => [a.external_id, a.active, a.login_customer_id ?? null]),
    [["1112223333", true, null], ["4445556666", false, "9998887777"]]);
  const hierCall = f.calls.find((c) => /9998887777\/googleAds:search/.test(c.url))!;
  assert.equal((hierCall.init!.headers as Record<string, string>)["login-customer-id"], "9998887777", "manager queried through itself");
  assert.equal(f.calls.filter((c) => /oauth2/.test(c.url)).length, 1, "one sign-in shared by all calls");
  assert.match(r.meta.error!, /not set/);
});

test("meta discovery: ad accounts with status; one platform failing does not hide the other", async () => {
  const f = fakeFetch([[/me\/adaccounts/, () => ({ body: { data: [
    { account_id: "998877", name: "WOA Meta", currency: "INR", timezone_name: "Asia/Kolkata", account_status: 1, business: { name: "WeOne" } },
    { account_id: "112233", name: "Old", currency: "INR", timezone_name: "Asia/Kolkata", account_status: 101 }] } })],
    [/oauth2/, () => ({ status: 400, body: { error: "invalid_grant" } })]]);
  const r = await discover({ meta: new MetaAds({ accessToken: "EAAtoken1234567", version: "v26.0" }, f.fn), google: new GoogleAds(G, f.fn) });
  assert.equal(r.meta.ok, true);
  assert.deepEqual(r.meta.accounts.map((a) => [a.external_id, a.status, a.active, a.business]), [["998877", "ACTIVE", true, "WeOne"], ["112233", "CLOSED", false, null]]);
  assert.equal(r.google.ok, false); assert.match(r.google.error!, /sign-in failed/);
});

test("imported account behind a manager: changes go through that manager", async () => {
  const f = fakeFetch([TOKEN, [/mutate/, () => ({ body: {} })],
    [/googleAds:search/, () => ({ body: { results: [{ campaign: { status: "PAUSED" }, campaignBudget: { amountMicros: "1000000000" } }] } })]]);
  const r = await executeOne({ google: new GoogleAds({ ...G, loginCustomerId: undefined }, f.fn) },
    { id: "q9", kind: "status", after: { status: "PAUSED" }, platform: "google", account_external_id: "4445556666", campaign_external_id: "11", budget_ref: null, login_customer_id: "9998887777" });
  assert.equal(r.status, "verified");
  assert.ok(f.calls.filter((c) => /googleads/.test(c.url)).every((c) => (c.init!.headers as Record<string, string>)["login-customer-id"] === "9998887777"));
});

Deno.test("google campaign keeps primary status and reasons (v26)", () => {
  const r = parseGoogleCampaign({ campaign: { id: "7", name: "S", status: "ENABLED", advertisingChannelType: "SEARCH", primaryStatus: "LIMITED",
    primaryStatusReasons: ["BUDGET_CONSTRAINED", "SEARCH_VOLUME_LIMITED"], servingStatus: "SERVING" },
    campaignBudget: { resourceName: "customers/1/campaignBudgets/2", amountMicros: "200000000", period: "DAILY" } });
  if (r.raw.primary_status !== "LIMITED" || (r.raw.primary_status_reasons as string[]).join() !== "BUDGET_CONSTRAINED,SEARCH_VOLUME_LIMITED"
      || r.raw.serving_status !== "SERVING" || r.daily_budget !== 200) throw new Error(JSON.stringify(r));
  const e = parseGoogleCampaign({ campaign: { id: "8", status: "PAUSED" }, campaignBudget: {} });
  if (e.raw.primary_status !== null || (e.raw.primary_status_reasons as string[]).length !== 0) throw new Error(JSON.stringify(e));
});
