// 107: Funnel audience helpers (engagement rules, Replace batches, errors) and audience targeting in builds.
import { test } from "node:test";
import assert from "node:assert/strict";
import { audienceError, engagementRule, lookalikeParams, replaceBatches, seedReady, sizeOf } from "../../functions/_shared/meta_audience.ts";
import { audienceSpec, geoQueries, targeting } from "../../functions/_shared/meta_build.ts";

const ids = { page_id: "111222333", ig_id: "444555666", forms: ["900000001", "bad", "900000002"] };
const h = (c: string) => c.repeat(64);

test("FT01 lead-form audiences: one rule, one source type, every form (Meta: 5 rules max), 90 days at most", () => {
  const r = engagementRule({ source: "lead", event: "lead_generation_dropoff", days: 400 }, ids).rule as any;
  const rules = r.inclusions.rules;
  assert.deepEqual(rules.length, 1);
  assert.deepEqual(rules[0].event_sources, [{ id: "900000001", type: "lead" }, { id: "900000002", type: "lead" }]);
  assert.ok(rules[0].retention_seconds === 90 * 86400 && rules[0].filter.filters[0].value === "lead_generation_dropoff");
  const many = engagementRule({ source: "lead", event: "lead_generation_opened" }, { ...ids, forms: Array.from({ length: 36 }, (_, i) => String(900000100 + i)) }).rule as any;
  assert.ok(many.inclusions.rules.length <= 5 && new Set(many.inclusions.rules.flatMap((x: any) => x.event_sources.map((e: any) => e.type))).size === 1);
});

test("FT02 Page, Instagram and messaged audiences; missing ids give a reason instead of a call", () => {
  assert.deepEqual((engagementRule({ source: "page", event: "page_engaged", days: 365 }, ids).rule as any).inclusions.rules[0].event_sources[0], { id: "111222333", type: "page" });
  const m = (engagementRule({ source: "page+ig", event: "messaged", days: 365 }, ids).rule as any).inclusions.rules;
  assert.deepEqual(m.map((x: any) => [x.event_sources[0].type, x.filter.filters[0].value]), [["ig_business", "ig_user_messaged_business"]]);
  const pm = (engagementRule({ source: "page+ig", event: "messaged", days: 365 }, { ...ids, ig_id: null }).rule as any).inclusions.rules;
  assert.deepEqual(pm.map((x: any) => x.filter.filters[0].value), ["page_messaged"]);
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

test("FT10 lookalikes: 1-20% in 1% steps, bands, no country (Meta 2026: ad set locations); seeds need 100+ people in Meta", () => {
  const p = lookalikeParams({ seed: "crm_qualified_365", starting_ratio: 0.01, ratio: 0.03 }, "2385", "CRM · LAL", "why")!.params!;
  assert.deepEqual([p.subtype, p.origin_audience_id, JSON.parse(p.lookalike_spec)], ["LOOKALIKE", "2385", { type: "similarity", ratio: 0.03, starting_ratio: 0.01 }]);
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

// 110: Automate helpers.
import { live as liveObj, plan as actionPlan, studyParams, verified as actionVerified } from "../../functions/_shared/meta_actions.ts";

test("FT12 actions: pause / on are skipped when already there; budgets in minor units within limits; ads have no budget", () => {
  const now = liveObj({ status: "ACTIVE", effective_status: "ACTIVE", daily_budget: "150000", name: "A" }, "INR");
  assert.deepEqual(now.daily_budget, 1500);
  assert.deepEqual(actionPlan("pause", "adset", {}, now, "INR", 100, 50000), { path: "object", send: { status: "PAUSED" } });
  assert.deepEqual(actionPlan("activate", "adset", {}, now, "INR", 100, 50000).skip, "Already on");
  assert.deepEqual(actionPlan("budget", "adset", { pct: 15 }, now, "INR", 100, 50000), { path: "object", send: { daily_budget: "172500" }, daily: 1725 });
  assert.deepEqual(actionPlan("budget", "adset", { daily: 90000 }, now, "INR", 100, 50000).daily, 50000);
  assert.ok(/no daily budget/.test(actionPlan("budget", "adset", { pct: 10 }, { ...now, daily_budget: null }, "INR", 100, 50000).error!));
  assert.ok(/no budget/.test(actionPlan("budget", "ad", { pct: 10 }, now, "INR", 100, 50000).error!));
  assert.ok(/deleted/.test(actionPlan("pause", "ad", {}, { ...now, status: "DELETED" }, "INR", 100, 50000).error!));
  const dup = actionPlan("duplicate", "adset", {}, now, "INR", 100, 50000);
  assert.deepEqual([dup.path, dup.send!.status_option, dup.send!.deep_copy], ["copies", "PAUSED", "true"]);
  assert.ok(actionVerified("budget", { ...now, daily_budget: 1725 }, 1725) && !actionVerified("pause", now));
});

test("FT13 Meta split test: equal shares, ad sets or campaigns, starts no earlier than now", () => {
  const p = studyParams({ name: "Hook test", level: "adset", start_date: "2026-11-20", end_date: "2026-12-03",
    cells: [{ name: "A", ids: ["1"] }, { name: "B", ids: ["2"] }, { name: "C", ids: ["3"] }] }, 1795000000);
  assert.deepEqual([p.type, JSON.parse(p.cells).map((c: any) => [c.treatment_percentage, c.adsets[0]])], ["SPLIT_TEST", [[33, "1"], [33, "2"], [33, "3"]]]);
  assert.ok(Number(p.start_time) >= 1795000600 && Number(p.end_time) > Number(p.start_time));
});

test("FT14 premium: PIN codes go to geo_locations.zips; offered income options narrow the interests (own flexible_spec entry)", () => {
  assert.deepEqual(geoQueries({ audience: { locations: [{ type: "zip", name: "110021" }, { type: "zip", name: "11002" }, { type: "city", name: "Delhi" }] } }).map((q) => q.type), ["zip", "city"]);
  const t = targeting({ audience: { age_min: 18, advantage_audience: false } }, { countries: [], regions: [], cities: [], zips: [{ key: "IN:110021" }] },
    [{ id: "6003", name: "Aviation" }], undefined, [{ id: "6002714898572", name: "Top 10%", type: "income" }, { id: "x", name: "bad", type: "Bad Type!" }]) as any;
  assert.deepEqual(t.geo_locations, { zips: [{ key: "IN:110021" }] });
  assert.deepEqual(t.flexible_spec, [{ interests: [{ id: "6003", name: "Aviation" }] }, { income: [{ id: "6002714898572", name: "Top 10%" }] }]);
  assert.equal((targeting({ audience: {} }, { countries: ["IN"], regions: [], cities: [] }, []) as any).flexible_spec, undefined);
});
