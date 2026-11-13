// Unit tests for _shared/ads_google_ops.ts with a fake Google Ads API (no network).
import { AdsError, GoogleAds } from "../../functions/_shared/ads_core.ts";
import { buildOps, executeGoogleOp, flatRow, resultNames, verifyNames } from "../../functions/_shared/ads_google_ops.ts";

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
