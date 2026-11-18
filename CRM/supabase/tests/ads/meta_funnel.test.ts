// 107: Funnel audience helpers (engagement rules, Replace batches, errors) and audience targeting in builds.
import { test } from "node:test";
import assert from "node:assert/strict";
import { audienceError, engagementRule, lookalikeParams, replaceBatches, seedReady, sizeOf } from "../../functions/_shared/meta_audience.ts";
import { audienceSpec, targeting } from "../../functions/_shared/meta_build.ts";

const ids = { page_id: "111222333", ig_id: "444555666", forms: ["900000001", "bad", "900000002"] };
const h = (c: string) => c.repeat(64);

test("FT01 lead-form audiences: one rule per form and per Facebook / Instagram source, 90 days at most", () => {
  const r = engagementRule({ source: "lead", event: "lead_generation_dropoff", days: 400 }, ids).rule as any;
  const rules = r.inclusions.rules;
  assert.deepEqual(rules.length, 4);
  assert.deepEqual(rules.map((x: any) => x.event_sources[0].type).sort(), ["ig_lead_generation", "ig_lead_generation", "lead", "lead"]);
  assert.ok(rules.every((x: any) => x.retention_seconds === 90 * 86400 && x.filter.filters[0].value === "lead_generation_dropoff"));
});

test("FT02 Page, Instagram and messaged audiences; missing ids give a reason instead of a call", () => {
  assert.deepEqual((engagementRule({ source: "page", event: "page_engaged", days: 365 }, ids).rule as any).inclusions.rules[0].event_sources[0], { id: "111222333", type: "page" });
  const m = (engagementRule({ source: "page+ig", event: "messaged", days: 365 }, ids).rule as any).inclusions.rules;
  assert.deepEqual(m.map((x: any) => x.filter.filters[0].value), ["page_messaged", "ig_user_messaged_business"]);
  assert.ok(/Instagram/.test(engagementRule({ source: "ig", event: "ig_business_profile_engaged" }, { ...ids, ig_id: null }).missing!));
  assert.ok(/lead forms/.test(engagementRule({ source: "lead", event: "lead_generation_opened" }, { ...ids, forms: [] }).missing!));
  assert.ok(/Unknown/.test(engagementRule({ source: "tiktok" }, ids).missing!));
});

test("FT03 Replace batches: hashed rows only, numbered, last batch flagged", () => {
  const rows: [string, string | null][] = [];
  for (let i = 0; i < 10001; i++) rows.push([h("a"), i % 2 ? h("b") : null]);
  rows.push(["+919999999999", null]);   // never a raw number
  const { batches, total } = replaceBatches(rows, 42);
  assert.deepEqual(total, 10001);
  assert.deepEqual(batches.length, 2);
  const s1 = JSON.parse(batches[0].session), s2 = JSON.parse(batches[1].session);
  assert.deepEqual([s1.batch_seq, s1.last_batch_flag, s2.batch_seq, s2.last_batch_flag, s2.session_id], [1, false, 2, true, 42]);
  const p = JSON.parse(batches[0].payload);
  assert.deepEqual(p.schema, ["PHONE", "EMAIL"]);
  assert.deepEqual(p.data[0], [h("a"), ""]);
  assert.deepEqual(replaceBatches([], 1).batches.length, 0);
});

test("FT04 plain errors and sizes", () => {
  assert.ok(/customaudiences\/tos\/\?act=123/.test(audienceError("OAuthException 200: You must accept the Custom Audience Terms", "123")));
  assert.ok(/ads_management/.test(audienceError("(#200) Permissions error", "1")));
  assert.deepEqual(sizeOf({ approximate_count_lower_bound: 1000, approximate_count_upper_bound: 1200 }), { size_low: 1000, size_high: 1200 });
  assert.deepEqual(sizeOf({ approximate_count_lower_bound: -1 }), { size_low: null, size_high: null });
});

test("FT05 builds: new-people ad sets get the default exclusions; retargeting includes its audience and never excludes it", () => {
  const aud = { map: { form_dropoff_30: "7001", crm_customers: "7002", crm_leads_30: "7003" }, defaults: ["7002", "7003"] };
  const geo = { countries: ["IN"], regions: [], cities: [] };
  const pros = targeting({ audience: { advantage_audience: true } }, geo, [], aud) as any;
  assert.deepEqual(pros.excluded_custom_audiences, [{ id: "7002" }, { id: "7003" }]);
  assert.deepEqual(pros.custom_audiences, undefined);
  const ret = targeting({ audience: { funnel: "retarget", include_audiences: ["form_dropoff_30"], exclude_audiences: ["crm_leads_30", "form_dropoff_30"] } }, geo, [], aud) as any;
  assert.deepEqual(ret.custom_audiences, [{ id: "7001" }]);
  assert.deepEqual(ret.excluded_custom_audiences, [{ id: "7003" }]);
  assert.deepEqual(audienceSpec({ audience: { funnel: "retarget", include_audiences: ["ig_visit_30"] } }, aud).missing, ["ig_visit_30"]);
  assert.deepEqual((targeting({ audience: {} }, geo, []) as any).excluded_custom_audiences, undefined);
});

// 108: website signals and website audiences.
import { gaBody, gscBody, gscSite, parseGa, parseGsc, siteError, windows } from "../../functions/_shared/site_signals.ts";

test("FT06 windows: two back-to-back 28-day windows; Search Console ends 3 days back", () => {
  const w = windows("2026-11-18", 3);
  assert.deepEqual(w.cur, ["2026-10-19", "2026-11-15"]);
  assert.deepEqual(w.prev, ["2026-09-21", "2026-10-18"]);
  assert.deepEqual(windows("2026-11-18", 1).cur[1], "2026-11-17");
});

test("FT07 Search Console and GA4 requests and rows", () => {
  assert.deepEqual(gscBody("query", "2026-10-19", "2026-11-15", 1000), { startDate: "2026-10-19", endDate: "2026-11-15", dimensions: ["query"], type: "web", rowLimit: 1000, dataState: "final" });
  const g = parseGsc({ rows: [{ keys: ["pilot training fees"], clicks: 12, impressions: 300, ctr: 0.04, position: 7.2 }, { keys: [""] }] }, "query", "cur");
  assert.deepEqual(g, [{ src: "gsc", kind: "query", k1: "pilot training fees", k2: "", win: "cur", m: { clicks: 12, impressions: 300, ctr: 0.04, position: 7.2 } }]);
  const body = gaBody({ dims: ["city", "region"], metrics: ["activeUsers", "keyEvents"], limit: 100 }, "a", "b") as any;
  assert.deepEqual(body.dimensions, [{ name: "city" }, { name: "region" }]);
  assert.deepEqual(body.orderBys[0].metric.metricName, "activeUsers");
  const ga = parseGa({ metricHeaders: [{ name: "activeUsers" }, { name: "keyEvents" }], rows: [
    { dimensionValues: [{ value: "Delhi" }, { value: "Delhi" }], metricValues: [{ value: "120" }, { value: "4" }] },
    { dimensionValues: [{ value: "(not set)" }], metricValues: [{ value: "9" }] }] }, "city", "cur");
  assert.deepEqual(ga, [{ src: "ga", kind: "city", k1: "Delhi", k2: "Delhi", win: "cur", m: { activeUsers: 120, keyEvents: 4 } }]);
});

test("FT08 site settings and plain errors", () => {
  assert.deepEqual(gscSite("sc-domain:WeOneAviation.in"), "sc-domain:weoneaviation.in");
  assert.deepEqual(gscSite("https://weoneaviation.in"), "https://weoneaviation.in/");
  assert.deepEqual(gscSite("weoneaviation.in"), null);
  assert.ok(/read scope/.test(siteError("GA4", 403, { error: { message: "Request had insufficient authentication scopes." } })));
  assert.ok(/no access/.test(siteError("Search Console", 403, { error: { message: "User does not have sufficient permission" } })));
  assert.ok(/GA4 property ID/.test(siteError("GA4", 404, {})));
});

test("FT09 website audiences use the Pixel: URL rules, the Lead event, all visitors; 180 days at most", () => {
  const ids = { page_id: "1", ig_id: null, forms: [], pixel_id: "555666777" };
  const fees = (engagementRule({ source: "pixel", url_any: ["fee", "cost"], days: 400 }, ids).rule as any).inclusions.rules;
  assert.deepEqual(fees.map((r: any) => [r.event_sources[0], r.retention_seconds, r.filter.filters[0]]), [
    [{ id: "555666777", type: "pixel" }, 180 * 86400, { field: "url", operator: "i_contains", value: "fee" }],
    [{ id: "555666777", type: "pixel" }, 180 * 86400, { field: "url", operator: "i_contains", value: "cost" }]]);
  assert.deepEqual((engagementRule({ source: "pixel", event: "Lead", days: 30 }, ids).rule as any).inclusions.rules[0].filter.filters[0], { field: "event", operator: "i_contains", value: "Lead" });
  assert.deepEqual((engagementRule({ source: "pixel", days: 30 }, ids).rule as any).inclusions.rules[0].filter.filters[0].value, "");
  assert.ok(/Pixel/.test(engagementRule({ source: "pixel", days: 30 }, { ...ids, pixel_id: null }).missing!));
});

test("FT10 lookalikes: 1-20% in 1% steps, bands, India by default; seeds need 100+ people in Meta", () => {
  const p = lookalikeParams({ seed: "crm_qualified_365", starting_ratio: 0.01, ratio: 0.03 }, "2385", "CRM · LAL", "why")!.params!;
  assert.deepEqual([p.subtype, p.origin_audience_id, JSON.parse(p.lookalike_spec)], ["LOOKALIKE", "2385", { type: "similarity", ratio: 0.03, country: "IN", starting_ratio: 0.01 }]);
  assert.ok(/1% to 20%/.test(lookalikeParams({ ratio: 0.25 }, "1", "n", "").problem!));
  assert.ok(/1% to 20%/.test(lookalikeParams({ ratio: 0.015 }, "1", "n", "").problem!));
  assert.ok(/start below/.test(lookalikeParams({ ratio: 0.02, starting_ratio: 0.02 }, "1", "n", "").problem!));
  assert.deepEqual(seedReady({ key: "s", enabled: true, meta_id: "1", status: "ready", size_low: 1200 }), { ok: true });
  assert.ok(/needs at least 100/.test(seedReady({ key: "s", enabled: true, meta_id: "1", status: "ready", size_low: null, members: 40 }).why!));
  assert.ok(/not in Meta yet/.test(seedReady({ key: "s", enabled: true, meta_id: null, status: "planned" }).why!));
});

test("FT11 new-people ad sets: seed audiences are hints only with Advantage+ audience, never hard limits", () => {
  const aud = { map: { lal_qualified_1: "8001", crm_customers: "7002" }, defaults: ["7002"] };
  const geo = { countries: ["IN"], regions: [], cities: [] };
  const hint = targeting({ audience: { advantage_audience: true, include_audiences: ["lal_qualified_1"] } }, geo, [], aud) as any;
  assert.deepEqual(hint.custom_audiences, [{ id: "8001" }]);
  const hard = targeting({ audience: { advantage_audience: false, include_audiences: ["lal_qualified_1"] } }, geo, [], aud) as any;
  assert.deepEqual([hard.custom_audiences, hard.excluded_custom_audiences], [undefined, [{ id: "7002" }]]);
});
