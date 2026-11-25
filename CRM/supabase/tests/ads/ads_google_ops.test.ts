// Unit tests for _shared/ads_google_ops.ts with a fake Google Ads API (no network).
import { AdsError, GoogleAds } from "../../functions/_shared/ads_core.ts";
import { buildOps, dryRunGoogleOp, executeGoogleOp, flatRow, resultNames, verifyNames, verifyNamesBatched } from "../../functions/_shared/ads_google_ops.ts";

const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}\n got ${JSON.stringify(a)}\nwant ${JSON.stringify(b)}`); };
const CID = "6318538100";

// Fake fetch: OAuth token, mutate (records validateOnly), search (answers from a table).
function fake(opts: { validateFails?: boolean; mutateNetErr?: boolean; rows?: (q: string) => any[]; names?: string[] } = {}) {
  const calls: { path: string; body: any }[] = [];
  const f = async (url: string, init?: RequestInit) => {
    if (url.includes("oauth2")) return new Response(JSON.stringify({ access_token: "ya29.x" }));
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    const path = url.replace(/^.*v26\//, "");
    calls.push({ path, body });
    if (path.endsWith("googleAds:mutate")) {
      if (body.validateOnly && opts.validateFails) return new Response(JSON.stringify({ error: { status: "INVALID_ARGUMENT", message: "Policy finding: unverified claim" } }), { status: 400 });
      if (!body.validateOnly && opts.mutateNetErr) throw new TypeError("connection reset");
      if (body.validateOnly) return new Response("{}");
      return new Response(JSON.stringify({ mutateOperationResponses: (opts.names ?? []).map((rn) => ({ someResult: { resourceName: rn } })) }));
    }
    if (path.endsWith("googleAds:search")) return new Response(JSON.stringify({ results: opts.rows ? opts.rows(body.query) : [] }));
    return new Response("{}", { status: 404 });
  };
  const g = new GoogleAds({ clientId: "c", clientSecret: "s", refreshToken: "r", version: "v26" }, f as any);
  return { g, calls };
}

Deno.test("keyword_add builds one create per keyword with match types", () => {
  const b = buildOps(CID, "keyword_add", { ad_group_id: "200162758466", keywords: [{ text: " cpl ground classes ", match: "phrase" }, { text: "dgca ground classes", match: "EXACT" }] });
  eq(b.ops[0], { adGroupCriterionOperation: { create: { adGroup: `customers/${CID}/adGroups/200162758466`, status: "ENABLED", keyword: { text: "cpl ground classes", matchType: "PHRASE" } } } }, "kw op");
  eq(b.checks.length, 2, "one check per keyword");
});

Deno.test("negatives go to the campaign or the shared list", () => {
  eq(Object.keys(buildOps(CID, "negative_add", { level: "campaign", campaign_id: "1", keywords: [{ text: "cabin crew", match: "PHRASE" }] }).ops[0]), ["campaignCriterionOperation"], "campaign");
  const s = buildOps(CID, "negative_add", { level: "shared_set", shared_set_id: "11955185109", keywords: [{ text: "air hostess", match: "BROAD" }] }).ops[0];
  eq(s.sharedCriterionOperation.create.sharedSet, `customers/${CID}/sharedSets/11955185109`, "shared set");
});

Deno.test("rsa_create, geo, callout (temp id), conversion goal, status changes", () => {
  const r = buildOps(CID, "rsa_create", { ad_group_id: "5", final_url: "https://weoneaviation.in", headlines: ["A", "B", "C"], descriptions: ["d1", "d2"], path1: "pilot" }).ops[0];
  eq(r.adGroupAdOperation.create.ad.responsiveSearchAd.headlines, [{ text: "A" }, { text: "B" }, { text: "C" }], "headlines");
  eq(r.adGroupAdOperation.create.ad.responsiveSearchAd.path1, "pilot", "path1");
  const g = buildOps(CID, "campaign_geo", { campaign_id: "9", target_type: "presence", add: ["1007765"], remove: ["20466"] });
  eq(g.ops.length, 3, "geo ops");
  eq(g.ops[0].campaignOperation.updateMask, "geoTargetTypeSetting.positiveGeoTargetType", "geo mask");
  eq(g.ops[2], { campaignCriterionOperation: { remove: `customers/${CID}/campaignCriteria/9~20466` } }, "geo remove");
  const c = buildOps(CID, "callout_add", { text: "Free Career Counselling" });
  eq(c.ops[0].assetOperation.create.resourceName, `customers/${CID}/assets/-1`, "temp asset id");
  eq(c.ops[1].customerAssetOperation.create, { asset: `customers/${CID}/assets/-1`, fieldType: "CALLOUT" }, "link to account");
  eq(buildOps(CID, "conversion_goal", { conversion_action_id: "7", primary: false }).ops[0].conversionActionOperation.update.primaryForGoal, false, "goal");
  eq(buildOps(CID, "keyword_status", { resource_name: `customers/${CID}/adGroupCriteria/1~2`, status: "REMOVED" }).ops[0], { adGroupCriterionOperation: { remove: `customers/${CID}/adGroupCriteria/1~2` } }, "remove");
  eq(buildOps(CID, "ad_group_create", { campaign_id: "1", name: "DGCA", cpc_bid: 40 }).ops[0].adGroupOperation.create.cpcBidMicros, "40000000", "cpc micros");
});

Deno.test("another account's resource is refused before anything is built", () => {
  let threw = false;
  try { buildOps(CID, "ad_status", { resource_name: "customers/1111111111/adGroupAds/1~2", status: "PAUSED" }); } catch (e) { threw = e instanceof AdsError; }
  eq(threw, true, "refused");
});

Deno.test("resultNames and flatRow", () => {
  eq(resultNames({ mutateOperationResponses: [{ assetResult: { resourceName: "a" } }, { customerAssetResult: { resourceName: "b" } }] }), ["a", "b"], "names");
  eq(flatRow({ campaign: { id: "1", geoTargetTypeSetting: { positiveGeoTargetType: "PRESENCE" } } }), { "campaign.id": "1", "campaign.geoTargetTypeSetting.positiveGeoTargetType": "PRESENCE" }, "flat");
});

Deno.test("execute: Google's pre-check failure means failed and nothing sent for real", async () => {
  const { g, calls } = fake({ validateFails: true });
  const r = await executeGoogleOp(g, { id: "1", kind: "callout_add", payload: { text: "X" }, account_external_id: CID });
  eq(r.status, "failed", "status");
  eq(calls.filter((c) => c.path.endsWith("mutate") && !c.body.validateOnly).length, 0, "no real send");
  if (!/pre-check/.test(r.error ?? "")) throw new Error(r.error);
});

Deno.test("execute: validate, send, read back -> verified", async () => {
  const names = [`customers/${CID}/assets/77`, `customers/${CID}/customerAssets/77~CALLOUT`];
  const { g, calls } = fake({ names, rows: (q) => q.includes("assets/77'") ? [{ asset: { resourceName: names[0] } }] : [{ customerAsset: { resourceName: names[1] } }] });
  const r = await executeGoogleOp(g, { id: "1", kind: "callout_add", payload: { text: "Free Career Counselling" }, account_external_id: CID });
  eq(r.status, "verified", "status");
  eq(calls.filter((c) => c.path.endsWith("mutate")).map((c) => c.body.validateOnly), [true, false], "validate first, then real");
  eq(r.result.resource_names, names, "names kept");
});

Deno.test("execute: read-back mismatch -> failed; network error on send -> outcome_unknown", async () => {
  const rn = `customers/${CID}/conversionActions/7`;
  const a = fake({ names: [rn], rows: () => [{ conversionAction: { resourceName: rn, primaryForGoal: true } }] });
  const r1 = await executeGoogleOp(a.g, { id: "1", kind: "conversion_goal", payload: { conversion_action_id: "7", primary: false }, account_external_id: CID });
  eq(r1.status, "failed", "mismatch");
  const b = fake({ mutateNetErr: true });
  const r2 = await executeGoogleOp(b.g, { id: "2", kind: "callout_add", payload: { text: "X" }, account_external_id: CID });
  eq(r2.status, "outcome_unknown", "unknown");
});

Deno.test("verify: removed means gone or status REMOVED", async () => {
  const rn = `customers/${CID}/customerAssets/5~CALLOUT`;
  const { g } = fake({ rows: () => [{ customerAsset: { resourceName: rn, status: "REMOVED" } }] });
  const v = await verifyNames(g, CID, [rn], [{ mode: "absent" }]);
  eq(v[0].ok, true, "removed ok");
});

Deno.test("search term history covers the past 365 days and only clicked terms", async () => {
  const { historyQuery } = await import("../../functions/_shared/ads_google_ops.ts");
  const q = historyQuery("2026-11-13");
  if (!q.includes("BETWEEN '2025-11-13' AND '2026-11-13'") || !q.includes("metrics.clicks > 0")) throw new Error(q);
});

Deno.test("agents context: compact tables, enabled-only links, costliest first, redundant resource names dropped", async () => {
  const { trimContext } = await import("../../functions/_shared/ads_agents_ctx.ts");
  const ctx = trimContext({ campaigns: [{ id: "1", status: "ENABLED" }, { id: "2", status: "PAUSED" }], snapshot: {
    locations: [{ "campaign.id": "1", "campaign.resourceName": "customers/9/campaigns/1", "campaignCriterion.criterionId": "20456" },
                { "campaign.id": "2", "campaignCriterion.criterionId": "20466" }],
    search_terms_365d: [{ "searchTermView.searchTerm": "a", "metrics.costMicros": "1000000" }, { "searchTermView.searchTerm": "b", "metrics.costMicros": "5000000" }],
    keywords: [{ "adGroupCriterion.resourceName": "customers/9/adGroupCriteria/5~6", "adGroupCriterion.keyword.text": "cpl" }],
    campaigns: { error: "x" } } });
  eq(ctx.snapshot.locations, { columns: ["campaign.id", "campaignCriterion.criterionId"], rows: [["1", "20456"]] }, "enabled only, no campaign rn");
  eq(ctx.snapshot.search_terms_365d.rows, [["b", 5], ["a", 1]], "costliest first in INR");
  eq(ctx.snapshot.keywords.columns[0], "adGroupCriterion.resourceName", "kept: needed for changes");
  eq(ctx.snapshot.campaigns, { error: "x" }, "errors untouched");
});

// ---- bids, budget and conversion reporting (099) ----
import { conversionRow, convertOutcome, googleSnapshot, micros } from "../../functions/_shared/ads_google_ops.ts";

Deno.test("cpc_cap updates only the Maximize Clicks ceiling, in exact micros", () => {
  const b = buildOps(CID, "cpc_cap", { campaign_id: "24283129095", max_cpc: 18.5 });
  eq(b.ops, [{ campaignOperation: { update: { resourceName: `customers/${CID}/campaigns/24283129095`, targetSpend: { cpcBidCeilingMicros: "18500000" } },
    updateMask: "targetSpend.cpcBidCeilingMicros" } }], "op");
  eq(b.checks, [{ mode: "field", field: "target_spend.cpc_bid_ceiling_micros", value: "18500000" }], "check");
});

Deno.test("cpc_cap and budget refuse zero, negative, text and missing amounts", () => {
  for (const v of [0, -5, "abc", null, undefined, NaN, Infinity]) {
    let threw = false;
    try { buildOps(CID, "cpc_cap", { campaign_id: "1", max_cpc: v }); } catch { threw = true }
    if (!threw) throw new Error(`cpc_cap accepted ${v}`);
    threw = false;
    try { buildOps(CID, "budget", { budget_resource: `customers/${CID}/campaignBudgets/9`, daily_budget: v }); } catch { threw = true }
    if (!threw) throw new Error(`budget accepted ${v}`);
  }
});

Deno.test("micros are exact for rupee amounts with paise (no floating point drift)", () => {
  eq([micros(200, "x"), micros(0.1 + 0.2, "x"), micros(19.99, "x"), micros("150", "x")], ["200000000", "300000", "19990000", "150000000"], "micros");
});

Deno.test("budget needs this account's own budget resource", () => {
  const b = buildOps(CID, "budget", { budget_resource: `customers/${CID}/campaignBudgets/15901873674`, daily_budget: 180 });
  eq(b.ops, [{ campaignBudgetOperation: { update: { resourceName: `customers/${CID}/campaignBudgets/15901873674`, amountMicros: "180000000" }, updateMask: "amountMicros" } }], "op");
  for (const rn of [undefined, "", "customers/999/campaignBudgets/1", `customers/${CID}/campaigns/1`, `customers/${CID}/campaignBudgets/1; DROP`]) {
    let threw = false;
    try { buildOps(CID, "budget", { budget_resource: rn, daily_budget: 100 }); } catch { threw = true }
    if (!threw) throw new Error(`budget accepted resource ${rn}`);
  }
});

Deno.test("a budget change is verified by reading the budget back", async () => {
  const rn = `customers/${CID}/campaignBudgets/15901873674`;
  const ok = fake({ names: [rn], rows: () => [{ campaignBudget: { resourceName: rn, amountMicros: "180000000" } }] });
  eq((await executeGoogleOp(ok.g, { id: "1", kind: "budget", payload: { budget_resource: rn, daily_budget: 180 }, account_external_id: CID })).status, "verified", "verified");
  const stale = fake({ names: [rn], rows: () => [{ campaignBudget: { resourceName: rn, amountMicros: "200000000" } }] });
  eq((await executeGoogleOp(stale.g, { id: "1", kind: "budget", payload: { budget_resource: rn, daily_budget: 180 }, account_external_id: CID })).status, "failed", "old value read back");
});

Deno.test("a conversion row carries exactly one click id, the consent flag and a dedupe id", () => {
  const it = { id: 1, event: "enquiry", at: "2026-11-13 14:49:49+00:00", order_id: "L1:enquiry", gclid: "Cj0abc", gbraid: "0AAA" };
  eq(conversionRow(CID, "777", it), { conversionAction: `customers/${CID}/conversionActions/777`, conversionDateTime: "2026-11-13 14:49:49+00:00",
    orderId: "L1:enquiry", consent: { adUserData: "GRANTED" }, gclid: "Cj0abc" }, "gclid wins");
  eq(conversionRow(CID, "777", { ...it, gclid: null })?.gbraid, "0AAA", "gbraid when there is no gclid");
  eq(conversionRow(CID, "777", { ...it, gclid: null, gbraid: null, wbraid: "W1" })?.wbraid, "W1", "wbraid last");
});

Deno.test("no conversion row without a click id, a conversion action or a well-formed time", () => {
  const it = { id: 1, event: "enquiry", at: "2026-11-13 14:49:49+00:00", order_id: "x", gclid: "G" };
  eq([conversionRow(CID, "777", { ...it, gclid: "" }), conversionRow(CID, undefined, it), conversionRow(CID, "abc", it),
    conversionRow(CID, "777", { ...it, at: "13 Nov 2026" }), conversionRow(CID, "777", { ...it, at: "" })], [null, null, null, null, null], "refused");
});

Deno.test("Google's answer decides: sent, try again later, or final failure", () => {
  eq(convertOutcome(null), { status: "sent" }, "accepted");
  eq(convertOutcome("CLICK_CONVERSION_ALREADY_EXISTS: dup").status, "sent", "a repeat is not an error");
  eq(convertOutcome("ORDER_ID_ALREADY_IN_USE: dup").status, "sent", "same order id");
  eq(convertOutcome("TOO_RECENT_CONVERSION_ACTION: wait 6 hours").status, "retry", "new conversion action");
  eq(convertOutcome("TOO_RECENT_EVENT: click too recent").status, "retry", "fresh click");
  eq(convertOutcome("EXPIRED_EVENT: older than the lookback window").status, "failed", "too old");
  eq(convertOutcome("UNPARSEABLE_GCLID: bad").status, "failed", "junk click id");
  eq(convertOutcome("ERROR: something new").status, "failed", "unknown errors are not retried forever");
});

Deno.test("uploadClickConversion: accepted, rejected with Google's code, and a network failure is thrown", async () => {
  const mk = (resp: () => Response) => new GoogleAds({ clientId: "c", clientSecret: "s", refreshToken: "r", version: "v26" },
    (async (url: string) => url.includes("oauth2") ? new Response(JSON.stringify({ access_token: "t" })) : resp()) as any);
  eq(await mk(() => new Response(JSON.stringify({ results: [{ gclid: "G" }] }))).uploadClickConversion(CID, {}), null, "accepted");
  const err = await mk(() => new Response(JSON.stringify({ partialFailureError: { message: "x", details: [{ errors: [{ errorCode: { conversionUploadError: "EXPIRED_EVENT" },
    message: "The click is too old." }] }] }, results: [{}] }))).uploadClickConversion(CID, {});
  eq(err, "EXPIRED_EVENT: The click is too old.", "code and message");
  let threw = false;
  try { await mk(() => { throw new TypeError("reset"); }).uploadClickConversion(CID, {}); } catch { threw = true }
  eq(threw, true, "network error");
});

Deno.test("snapshot: places get names, and one failing query does not lose the others", async () => {
  const { g } = fake({ rows: (q) => q.includes("FROM geo_target_constant") ? [{ geoTargetConstant: { id: "1007751", canonicalName: "New Delhi,Delhi,India" } }]
    : q.includes("FROM user_location_view") ? [{ campaign: { id: "1" }, segments: { geoTargetCity: "geoTargetConstants/1007751" }, metrics: { clicks: "5", costMicros: "9000000" } }]
    : q.includes("campaign_criterion.type = 'LOCATION'") ? [{ campaign: { id: "1" }, campaignCriterion: { criterionId: "1007751", location: { geoTargetConstant: "geoTargetConstants/1007751" } } }]
    : [] });
  const s = await googleSnapshot(g, CID) as any;
  eq([s.by_city_30d[0].place, s.locations[0].place], ["New Delhi,Delhi,India", "New Delhi,Delhi,India"], "names");
  eq(["by_hour_30d", "by_weekday_30d", "by_device_30d", "by_city_30d"].every((k) => Array.isArray(s[k])), true, "new views are present");
});

import { dmRequest } from "../../functions/_shared/ads_google_ops.ts";
Deno.test("Data Manager: one event per request, RFC 3339 time, the manager as login account, refused without click id or action", () => {
  const it = { id: 1, event: "enquiry", at: "2026-11-13 14:49:49+05:30", order_id: "L1:enquiry", gclid: "Cj0abc", gbraid: "0AAA" };
  eq(dmRequest(CID, "9998887776", "777", it), {
    destinations: [{ operatingAccount: { accountType: "GOOGLE_ADS", accountId: CID }, loginAccount: { accountType: "GOOGLE_ADS", accountId: "9998887776" }, productDestinationId: "777" }],
    consent: { adUserData: "CONSENT_GRANTED" },
    events: [{ adIdentifiers: { gclid: "Cj0abc" }, eventTimestamp: "2026-11-13T14:49:49+05:30", transactionId: "L1:enquiry", eventSource: "WEB" }] }, "full request");
  eq((dmRequest(CID, null, "777", { ...it, gclid: null }) as any).destinations[0].loginAccount.accountId, CID, "no manager: the account itself");
  eq((dmRequest(CID, null, "777", { ...it, gclid: null }) as any).events[0].adIdentifiers, { gbraid: "0AAA" }, "gbraid");
  eq([dmRequest(CID, null, "777", { ...it, gclid: null, gbraid: null }), dmRequest(CID, null, undefined, it), dmRequest(CID, null, "777", { ...it, at: "13 Nov" })], [null, null, null], "refused");
});

Deno.test("ingestEvents: accepted, rejected with Google's status, a missing scope stops the run with the fix", async () => {
  const mk = (resp: () => Response) => new GoogleAds({ clientId: "c", clientSecret: "s", refreshToken: "r", version: "v26" },
    (async (url: string) => url.includes("oauth2") ? new Response(JSON.stringify({ access_token: "t" })) : resp()) as any);
  eq(await mk(() => new Response("{}")).ingestEvents({}), null, "accepted");
  eq(await mk(() => new Response(JSON.stringify({ error: { status: "INVALID_ARGUMENT", message: "bad gclid" } }), { status: 400 })).ingestEvents({}), "INVALID_ARGUMENT: bad gclid", "rejected");
  let msg = "";
  try { await mk(() => new Response(JSON.stringify({ error: { status: "PERMISSION_DENIED", message: "Request had insufficient authentication scopes." } }), { status: 403 })).ingestEvents({}); }
  catch (e) { msg = (e as Error).message; }
  eq(/datamanager/.test(msg), true, "scope message");
  eq(convertOutcome("UNAVAILABLE: try later").status, "retry", "transient");
  eq(convertOutcome("INVALID_ARGUMENT: duplicate transaction").status, "sent", "duplicate is sent");
});

// ---- migration 144: new campaign and income filter ----
Deno.test("campaign_create: budget, Search campaign and locations in one request, with temporary ids", () => {
  const b = buildOps(CID, "campaign_create", { name: " Other cities ", daily_budget: 60, max_cpc: 20, locations: ["9061645", 1007801] });
  eq(b.ops.length, 4, "budget + campaign + 2 locations");
  eq(b.checks.every((c) => c.mode === "exists"), true, "every row is read back");
  eq(b.ops[0].campaignBudgetOperation.create, { resourceName: `customers/${CID}/campaignBudgets/-1`, name: "Other cities budget", deliveryMethod: "STANDARD",
    amountMicros: "60000000", explicitlyShared: false }, "its own budget, exact micros");
  const c = b.ops[1].campaignOperation.create;
  eq([c.resourceName, c.name, c.advertisingChannelType, c.status, c.campaignBudget], [`customers/${CID}/campaigns/-2`, "Other cities", "SEARCH", "ENABLED", `customers/${CID}/campaignBudgets/-1`], "campaign");
  eq(c.targetSpend, { cpcBidCeilingMicros: "20000000" }, "Maximize Clicks with the click limit");
  eq(c.networkSettings, { targetGoogleSearch: true, targetSearchNetwork: false, targetContentNetwork: false, targetPartnerSearchNetwork: false }, "Google Search only");
  eq(c.geoTargetTypeSetting, { positiveGeoTargetType: "PRESENCE" }, "people physically there");
  eq(c.containsEuPoliticalAdvertising, "DOES_NOT_CONTAIN_EU_POLITICAL_ADVERTISING", "required declaration");
  eq(b.ops[3].campaignCriterionOperation.create, { campaign: `customers/${CID}/campaigns/-2`, location: { geoTargetConstant: "geoTargetConstants/1007801" } }, "location on the new campaign");
  eq(buildOps(CID, "campaign_create", { name: "Paused one", daily_budget: 1, max_cpc: 3, locations: ["1"], status: "paused" }).ops[1].campaignOperation.create.status, "PAUSED", "paused on request");
});

Deno.test("campaign_create refuses no locations, a bad location, a bad status, no name and bad money", () => {
  const bad = [
    { name: "X campaign", daily_budget: 60, max_cpc: 20, locations: [] },
    { name: "X campaign", daily_budget: 60, max_cpc: 20 },
    { name: "X campaign", daily_budget: 60, max_cpc: 20, locations: ["12a"] },
    { name: "X campaign", daily_budget: 60, max_cpc: 20, locations: ["1"], status: "REMOVED" },
    { name: " a ", daily_budget: 60, max_cpc: 20, locations: ["1"] },
    { name: "X campaign", daily_budget: 0, max_cpc: 20, locations: ["1"] },
    { name: "X campaign", daily_budget: 60, max_cpc: "abc", locations: ["1"] },
  ];
  for (const p of bad) {
    let threw = false;
    try { buildOps(CID, "campaign_create", p); } catch { threw = true }
    if (!threw) throw new Error(`campaign_create accepted ${JSON.stringify(p)}`);
  }
});

Deno.test("income_filter: shuts groups out of a campaign or an ad group, and lets them back in", () => {
  const c = buildOps(CID, "income_filter", { campaign_id: "9", exclude: ["INCOME_RANGE_0_50", "income_range_undetermined"] });
  eq(c.ops, [
    { campaignCriterionOperation: { create: { campaign: `customers/${CID}/campaigns/9`, negative: true, incomeRange: { type: "INCOME_RANGE_0_50" } } } },
    { campaignCriterionOperation: { create: { campaign: `customers/${CID}/campaigns/9`, negative: true, incomeRange: { type: "INCOME_RANGE_UNDETERMINED" } } } },
  ], "campaign level, negative");
  eq(c.checks, [{ mode: "exists" }, { mode: "exists" }], "read back");
  const a = buildOps(CID, "income_filter", { ad_group_id: "5", exclude: ["INCOME_RANGE_70_80"], remove: [`customers/${CID}/adGroupCriteria/5~510001`] });
  eq(a.ops[0], { adGroupCriterionOperation: { create: { adGroup: `customers/${CID}/adGroups/5`, negative: true, incomeRange: { type: "INCOME_RANGE_70_80" } } } }, "ad group level");
  eq(a.ops[1], { adGroupCriterionOperation: { remove: `customers/${CID}/adGroupCriteria/5~510001` } }, "let back in");
  eq(a.checks[1], { mode: "absent" }, "removal is read back as gone");
});

Deno.test("income_filter refuses an unknown group, another account's row, the wrong level and an empty change", () => {
  const bad = [
    { campaign_id: "9", exclude: ["RICH"] },
    { campaign_id: "9", remove: ["customers/1111111111/campaignCriteria/9~510001"] },
    { campaign_id: "9", remove: [`customers/${CID}/adGroupCriteria/9~510001`] },
    { ad_group_id: "5", remove: [`customers/${CID}/campaignCriteria/5~510001`] },
    { campaign_id: "9" },
    { exclude: ["INCOME_RANGE_0_50"] },
  ];
  for (const p of bad) {
    let threw = false;
    try { buildOps(CID, "income_filter", p); } catch { threw = true }
    if (!threw) throw new Error(`income_filter accepted ${JSON.stringify(p)}`);
  }
});

Deno.test("campaign_create: the whole campaign in one request (moved budget first, ad groups on temporary ids)", () => {
  const b = buildOps(CID, "campaign_create", { name: "Other cities", daily_budget: 60, max_cpc: 20, locations: ["1007801"],
    move_budget: { campaign_id: "24283129095", daily_budget: 140 }, move_budget_resource: `customers/${CID}/campaignBudgets/777`,
    income_exclude: ["INCOME_RANGE_0_50", "income_range_undetermined"], shared_set_ids: ["11955185109"],
    negatives: [{ text: "pdf", match: "BROAD" }],
    ad_groups: [
      { name: "Counselling", keywords: [{ text: "pilot training", match: "PHRASE" }], ads: [{ final_url: "https://weoneaviation.in/pilot-career-counselling", headlines: ["A", "B", "C"], descriptions: ["d1", "d2"] }] },
      { name: "DGCA online", keywords: [{ text: "dgca ground classes", match: "PHRASE" }, { text: "cpl ground classes", match: "PHRASE" }], ads: [{ final_url: "https://weoneaviation.in/online-dgca-ground-classes", headlines: ["A", "B", "C"], descriptions: ["d1", "d2"], path1: "online" }] },
    ] });
  const kinds = b.ops.map((o) => Object.keys(o)[0]);
  eq(kinds, ["campaignBudgetOperation", "campaignBudgetOperation", "campaignOperation", "campaignCriterionOperation", "campaignCriterionOperation", "campaignCriterionOperation",
    "campaignSharedSetOperation", "campaignCriterionOperation", "adGroupOperation", "adGroupCriterionOperation", "adGroupAdOperation",
    "adGroupOperation", "adGroupCriterionOperation", "adGroupCriterionOperation", "adGroupAdOperation"], "order: money down, budget, campaign, locations, income, lists, negatives, ad groups");
  eq(b.ops[0].campaignBudgetOperation, { update: { resourceName: `customers/${CID}/campaignBudgets/777`, amountMicros: "140000000" }, updateMask: "amountMicros" }, "the running campaign is lowered first");
  eq(b.checks[0], { mode: "field", field: "amount_micros", value: "140000000" }, "and read back as an amount");
  eq(b.checks.slice(1).every((c) => c.mode === "exists"), true, "everything created is read back");
  eq(b.ops[4].campaignCriterionOperation.create, { campaign: `customers/${CID}/campaigns/-2`, negative: true, incomeRange: { type: "INCOME_RANGE_0_50" } }, "income filter on the new campaign");
  eq(b.ops[6].campaignSharedSetOperation.create, { campaign: `customers/${CID}/campaigns/-2`, sharedSet: `customers/${CID}/sharedSets/11955185109` }, "shared negative list");
  eq(b.ops[7].campaignCriterionOperation.create, { campaign: `customers/${CID}/campaigns/-2`, negative: true, keyword: { text: "pdf", matchType: "BROAD" } }, "campaign negative");
  eq([b.ops[8].adGroupOperation.create.resourceName, b.ops[11].adGroupOperation.create.resourceName], [`customers/${CID}/adGroups/-3`, `customers/${CID}/adGroups/-4`], "ad groups -3, -4");
  eq(b.ops[9].adGroupCriterionOperation.create.adGroup, `customers/${CID}/adGroups/-3`, "keyword in its own group");
  eq(b.ops[13].adGroupCriterionOperation.create.adGroup, `customers/${CID}/adGroups/-4`, "second group's keyword");
  eq(b.ops[14].adGroupAdOperation.create.ad, { finalUrls: ["https://weoneaviation.in/online-dgca-ground-classes"], responsiveSearchAd: { headlines: [{ text: "A" }, { text: "B" }, { text: "C" }], descriptions: [{ text: "d1" }, { text: "d2" }], path1: "online" } }, "ad");
});

Deno.test("campaign_create: moved budget needs this account's own budget row", () => {
  const base = { name: "Other cities", daily_budget: 60, max_cpc: 20, locations: ["1"], move_budget: { campaign_id: "9", daily_budget: 140 } };
  for (const rn of [undefined, "", "customers/1111111111/campaignBudgets/7", `customers/${CID}/campaigns/7`]) {
    let threw = false;
    try { buildOps(CID, "campaign_create", { ...base, move_budget_resource: rn }); } catch { threw = true }
    if (!threw) throw new Error(`accepted move_budget_resource ${rn}`);
  }
});

Deno.test("verifyNamesBatched: reads created rows in groups, keeps the order, falls back for other checks", async () => {
  const names = [`customers/${CID}/campaignBudgets/777`, `customers/${CID}/campaignBudgets/900`, `customers/${CID}/campaigns/55`,
    ...Array.from({ length: 45 }, (_, i) => `customers/${CID}/campaignCriteria/55~${9000 + i}`), `customers/${CID}/adGroups/66`];
  const checks: any[] = [{ mode: "field", field: "amount_micros", value: "140000000" }, ...names.slice(1).map(() => ({ mode: "exists" }))];
  const queries: string[] = [];
  const missing = `customers/${CID}/campaignCriteria/55~9044`;
  const g: any = { search: (_c: string, q: string) => {
    queries.push(q);
    if (q.includes("amount_micros")) return Promise.resolve([{ campaignBudget: { resourceName: names[0], amountMicros: "140000000" } }]);
    const res = /FROM (\w+) WHERE/.exec(q)![1];
    const key = res.replace(/_([a-z])/g, (_m: string, c: string) => c.toUpperCase());
    return Promise.resolve([...q.matchAll(/'([^']+)'/g)].map((m) => m[1]).filter((n) => n !== missing).map((n) => ({ [key]: { resourceName: n } })));
  } };
  const v = await verifyNamesBatched(g, CID, names, checks);
  eq(v.map((x: any) => x.rn), names, "same order as the request");
  eq(v.filter((x: any) => !x.ok).map((x: any) => x.rn), [missing], "the one row Google does not return is reported");
  eq(queries.length, 6, "49 rows read in 6 requests (budget amount, new budget, campaign, 45 locations in 2, ad group)");
  eq(v[0], { rn: names[0], ok: true, got: "140000000", want: "140000000" }, "the moved budget keeps its amount check");
});

Deno.test("dryRunGoogleOp: validate only, never the real request; reports Google's refusal", async () => {
  const calls: boolean[] = [];
  const ok: any = { withLogin: () => ({ mutate: (_c: string, _o: unknown[], validateOnly: boolean) => { calls.push(validateOnly); return Promise.resolve({}); } }) };
  const op = { id: "1", kind: "income_filter", payload: { campaign_id: "9", exclude: ["INCOME_RANGE_0_50"] }, account_external_id: CID };
  eq(await dryRunGoogleOp(ok, op), { ok: true, operations: 1 }, "accepted");
  eq(calls, [true], "one call, validate only");
  const no: any = { withLogin: () => ({ mutate: () => Promise.reject(new Error("POLICY_FINDING: unproven claim")) }) };
  eq(await dryRunGoogleOp(no, op), { ok: false, operations: 1, error: "POLICY_FINDING: unproven claim" }, "refused, with Google's words");
  eq(await dryRunGoogleOp(ok, { ...op, payload: { campaign_id: "9" } }), { ok: false, operations: 0, error: "nothing to change" }, "a bad operation never reaches Google");
});

// ---- migration 145: time-of-day bids ----
Deno.test("ad_schedule: every day, every slot, with the bid change; old rows removed first", () => {
  const b = buildOps(CID, "ad_schedule", { campaign_id: "9", remove: [`customers/${CID}/campaignCriteria/9~300`],
    slots: [{ start_hour: 0, end_hour: 6, bid_pct: -30 }, { start_hour: 6, end_hour: 24 }] });
  eq(b.ops.length, 15, "1 removal + 2 slots x 7 days");
  eq(b.ops[0], { campaignCriterionOperation: { remove: `customers/${CID}/campaignCriteria/9~300` } }, "old row out first");
  eq(b.checks[0], { mode: "absent" }, "read back as gone");
  eq(b.ops[1].campaignCriterionOperation.create, { campaign: `customers/${CID}/campaigns/9`, bidModifier: 0.7,
    adSchedule: { dayOfWeek: "MONDAY", startHour: 0, startMinute: "ZERO", endHour: 6, endMinute: "ZERO" } }, "30% lower, midnight to 6");
  eq(b.ops[14].campaignCriterionOperation.create, { campaign: `customers/${CID}/campaigns/9`, bidModifier: 1,
    adSchedule: { dayOfWeek: "SUNDAY", startHour: 6, startMinute: "ZERO", endHour: 24, endMinute: "ZERO" } }, "the rest of the day unchanged");
});

Deno.test("ad_schedule refuses a gap, an overlap, a short day, half hours, a bad bid and another campaign's row", () => {
  const bad = [
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 6 }, { start_hour: 7, end_hour: 24 }] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 8 }, { start_hour: 6, end_hour: 24 }] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 22 }] },
    { campaign_id: "9", slots: [{ start_hour: 6, end_hour: 24 }] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 6.5 }, { start_hour: 6.5, end_hour: 24 }] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 24, bid_pct: -95 }] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 24, bid_pct: 12.5 }] },
    { campaign_id: "9", slots: [] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 24 }], remove: [`customers/${CID}/campaignCriteria/8~300`] },
    { campaign_id: "9", slots: [{ start_hour: 0, end_hour: 24 }], remove: ["customers/1111111111/campaignCriteria/9~300"] },
  ];
  for (const p of bad) {
    let threw = false;
    try { buildOps(CID, "ad_schedule", p); } catch { threw = true }
    if (!threw) throw new Error(`ad_schedule accepted ${JSON.stringify(p)}`);
  }
});

Deno.test("budget_set: every running campaign's budget in one request, each read back by its amount", () => {
  const b = buildOps(CID, "budget_set", { daily_total: 300, parts: [
    { campaign_id: "1", daily_budget: 210, budget_resource: `customers/${CID}/campaignBudgets/11` },
    { campaign_id: "2", daily_budget: 90, budget_resource: `customers/${CID}/campaignBudgets/22` }] });
  eq(b.ops, [
    { campaignBudgetOperation: { update: { resourceName: `customers/${CID}/campaignBudgets/11`, amountMicros: "210000000" }, updateMask: "amountMicros" } },
    { campaignBudgetOperation: { update: { resourceName: `customers/${CID}/campaignBudgets/22`, amountMicros: "90000000" }, updateMask: "amountMicros" } },
  ], "two budget updates, exact micros");
  eq(b.checks, [{ mode: "field", field: "amount_micros", value: "210000000" }, { mode: "field", field: "amount_micros", value: "90000000" }], "read back by amount");
  eq(buildOps(CID, "budget_set", { daily_total: 255, parts: [
    { daily_budget: 177.5, budget_resource: `customers/${CID}/campaignBudgets/11` },
    { daily_budget: 77.5, budget_resource: `customers/${CID}/campaignBudgets/22` }] }).ops.length, 2, "paise add up exactly (no float drift)");
});

Deno.test("budget_set refuses an unknown budget, another account's budget, one budget twice, bad money and parts that do not add up", () => {
  const r = (n: string) => `customers/${CID}/campaignBudgets/${n}`;
  const bad = [
    { daily_total: 300, parts: [] },
    { daily_total: 300 },
    { daily_total: 300, parts: [{ daily_budget: 300 }] },
    { daily_total: 300, parts: [{ daily_budget: 300, budget_resource: "customers/1111111111/campaignBudgets/1" }] },
    { daily_total: 300, parts: [{ daily_budget: 150, budget_resource: r("1") }, { daily_budget: 150, budget_resource: r("1") }] },
    { daily_total: 300, parts: [{ daily_budget: 0, budget_resource: r("1") }, { daily_budget: 300, budget_resource: r("2") }] },
    { daily_total: 300, parts: [{ daily_budget: "lots", budget_resource: r("1") }] },
    { daily_total: 300, parts: [{ daily_budget: 200, budget_resource: r("1") }, { daily_budget: 90, budget_resource: r("2") }] },
    { daily_total: 300, parts: Array.from({ length: 21 }, (_, i) => ({ daily_budget: 1, budget_resource: r(String(i)) })) },
  ];
  for (const p of bad) {
    let threw = false;
    try { buildOps(CID, "budget_set", p); } catch { threw = true }
    if (!threw) throw new Error(`budget_set accepted ${JSON.stringify(p)}`);
  }
});

Deno.test("executeGoogleOp budget_set: pre-check, one real request, verified only when both amounts read back", async () => {
  const calls: { validate: boolean }[] = [];
  const amounts: Record<string, string> = { [`customers/${CID}/campaignBudgets/11`]: "210000000", [`customers/${CID}/campaignBudgets/22`]: "60000000" };
  const fake = {
    withLogin() { return this; },
    async mutate(_c: string, ops: any[], validate: boolean) {
      calls.push({ validate });
      return { mutateOperationResponses: ops.map((o) => ({ campaignBudgetResult: { resourceName: o.campaignBudgetOperation.update.resourceName } })) };
    },
    async search(_c: string, q: string) {
      const rn = q.match(/resource_name = '([^']+)'/)?.[1] ?? "";
      return [{ campaignBudget: { resourceName: rn, amountMicros: amounts[rn] } }];
    },
  } as any;
  const op = { id: "x", kind: "budget_set", account_external_id: CID, login_customer_id: null, status: "approved", payload: { daily_total: 300, parts: [
    { daily_budget: 210, budget_resource: `customers/${CID}/campaignBudgets/11` }, { daily_budget: 90, budget_resource: `customers/${CID}/campaignBudgets/22` }] } } as any;
  const r1 = await executeGoogleOp(fake, op);
  eq(calls.map((c) => c.validate), [true, false], "Google's pre-check first, then the real request once");
  eq(r1.status, "failed", "one amount did not read back: not verified");
  amounts[`customers/${CID}/campaignBudgets/22`] = "90000000";
  const r2 = await executeGoogleOp(fake, op);
  eq(r2.status, "verified", "both read back: verified");
});
