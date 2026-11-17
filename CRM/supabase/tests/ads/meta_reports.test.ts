// Unit tests for Meta Ads > Reports (meta_report.ts) and Health (meta_health.ts), migration 105. No network.
// Run: deno test --allow-all meta_reports.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { BREAKDOWNS, cacheHours, cacheKey, cleanParams, derived, fieldsFor, insightsQuery, parseRow, previousPeriod, sumRows } from "../../functions/_shared/meta_report.ts";
import { healthWarnings, units } from "../../functions/_shared/meta_health.ts";

const TODAY = "2026-11-17";
const base = { level: "ad", from: "2026-11-01", to: "2026-11-16" };

test("Report settings are checked like Ads Manager's limits (37 months, 13 for splits, 6 for frequency)", () => {
  const p = cleanParams({ ...base, breakdown: "age_gender", campaign_ids: ["7001", "x"], statuses: ["ACTIVE", "BAD"], name: "CPL <script>" }, TODAY);
  assert.deepEqual([p.level, p.breakdown, p.campaign_ids, p.statuses, p.name], ["ad", "age_gender", ["7001"], ["ACTIVE"], "CPL script"]);
  assert.throws(() => cleanParams({ ...base, from: "2026-11-20" }, TODAY), /start date is after/);
  assert.throws(() => cleanParams({ ...base, to: "2026-11-18" }, TODAY), /future/);
  assert.throws(() => cleanParams({ ...base, from: "2023-01-01" }, TODAY), /37 months/);
  assert.throws(() => cleanParams({ ...base, from: "2025-06-01", breakdown: "region" }, TODAY), /13 months/);
  assert.throws(() => cleanParams({ ...base, from: "2026-03-01", breakdown: "frequency" }, TODAY), /6 months/);
  assert.equal(cleanParams({ ...base, breakdown: "nonsense", level: "x" }, TODAY).breakdown, null);
  assert.equal(cleanParams({ ...base, level: "x" }, TODAY).level, "campaign");
  assert.deepEqual(previousPeriod("2026-11-01", "2026-11-16"), { from: "2026-10-16", to: "2026-10-31" });
});

test("Insights query: level, fields, splits, time steps and filters", () => {
  const p = cleanParams({ ...base, breakdown: "placement", campaign_ids: ["7001"], statuses: ["ACTIVE"], name: "CPL" }, TODAY);
  const q = insightsQuery(p, p, TODAY);
  assert.equal(q.level, "ad"); assert.equal(q.breakdowns, "publisher_platform,platform_position");
  assert.deepEqual(JSON.parse(q.time_range), { since: "2026-11-01", until: "2026-11-16" });
  assert.deepEqual(JSON.parse(q.filtering), [{ field: "campaign.id", operator: "IN", value: ["7001"] },
    { field: "ad.effective_status", operator: "IN", value: ["ACTIVE"] }, { field: "ad.name", operator: "CONTAIN", value: "CPL" }]);
  assert.ok(q.fields.includes("reach") && q.fields.includes("video_thruplay_watched_actions") && !q.fields.includes("quality_ranking"));
  const t = insightsQuery(p, p, TODAY, true);
  assert.equal(t.level, "account"); assert.equal(t.breakdowns, undefined); assert.ok(!t.fields.includes("ad_name"));
  const w = insightsQuery(cleanParams({ ...base, breakdown: "week" }, TODAY), base, TODAY);
  assert.equal(w.time_increment, "7"); assert.equal(w.breakdowns, undefined);
  assert.ok(fieldsFor(cleanParams(base, TODAY), "2026-11-01", TODAY).includes("quality_ranking"));            // ad level, no split
  assert.ok(!fieldsFor(cleanParams(base, TODAY), "2025-01-01", TODAY).includes("reach"));                      // unique counts: 13 months
  assert.ok(!fieldsFor(cleanParams({ ...base, breakdown: "hour" }, TODAY), "2026-11-01", TODAY).includes("reach"));
  assert.deepEqual(fieldsFor(cleanParams({ ...base, breakdown: "frequency", level: "campaign" }, TODAY), "2026-11-01", TODAY),
    ["campaign_id", "campaign_name", "objective", "reach", "impressions", "spend"]);
  assert.equal(Object.values(BREAKDOWNS).filter((b) => b.group === "Demographics").length, 3);
});

test("Rows: leads from instant forms, video quartiles, rankings, split values", () => {
  const p = cleanParams({ ...base, breakdown: "age_gender" }, TODAY);
  const r = parseRow({ ad_id: "9001", ad_name: "Reel", campaign_id: "7001", campaign_name: "CPL", age: "18-24", gender: "male", spend: "500.5",
    impressions: "10000", reach: "6000", frequency: "1.66", clicks: "200", inline_link_clicks: "120",
    actions: [{ action_type: "onsite_conversion.lead_grouped", value: "10" }, { action_type: "video_view", value: "3000" }, { action_type: "link_click", value: "120" }],
    video_p25_watched_actions: [{ action_type: "video_view", value: "2000" }], video_thruplay_watched_actions: [{ action_type: "video_view", value: "600" }] }, p);
  assert.equal(r.key, "9001|18-24|male"); assert.deepEqual(r.dims, { age: "18-24", gender: "male" });
  assert.deepEqual([r.spend, r.leads, r.video_3s, r.p25, r.thruplay, r.reach], [500.5, 10, 3000, 2000, 600, 6000]);
  const d = derived(r);
  assert.equal(d.cpl, 50.05); assert.equal(d.hook, 30); assert.equal(d.hold, 20); assert.equal(d.cpm, 50.05); assert.equal(d.link_ctr, 1.2);
  const hr = parseRow({ campaign_id: "1", campaign_name: "x", hourly_stats_aggregated_by_advertiser_time_zone: "09:00:00 - 09:59:59", spend: "1" },
    cleanParams({ ...base, level: "campaign", breakdown: "hour" }, TODAY));
  assert.equal(hr.dims.hour, "09:00"); assert.equal(hr.reach, null);
  const rk = parseRow({ ad_id: "1", ad_name: "a", quality_ranking: "ABOVE_AVERAGE", engagement_rate_ranking: "AVERAGE", conversion_rate_ranking: "BELOW_AVERAGE_35" }, cleanParams(base, TODAY));
  assert.deepEqual([rk.quality, rk.engagement, rk.conversion], ["ABOVE_AVERAGE", "AVERAGE", "BELOW_AVERAGE_35"]);
  const m = parseRow({ campaign_id: "1", date_start: "2026-10-01" }, cleanParams({ ...base, level: "campaign", breakdown: "month" }, TODAY));
  assert.equal(m.dims.period, "2026-10");
});

test("Totals after filtering split values: reach adds up only across disjoint splits", () => {
  const rows = [{ spend: 10, impressions: 100, reach: 80, clicks: 1, link_clicks: 1, leads: 1 }, { spend: 30, impressions: 300, reach: 200, clicks: 3, link_clicks: 2, leads: 0 }] as any;
  const age = sumRows(rows, true), place = sumRows(rows, false);
  assert.equal(age.spend, 40); assert.equal(age.reach, 280); assert.equal(Math.round(age.frequency! * 100), 143);
  assert.equal(place.reach, null); assert.equal(place.frequency, null);
});

test("Cache: recent periods 3 hours, old ones a week; the key ignores filter order", async () => {
  assert.equal(cacheHours(cleanParams(base, TODAY), TODAY), 3);
  assert.equal(cacheHours(cleanParams({ ...base, from: "2026-01-01", to: "2026-01-31" }, TODAY), TODAY), 168);
  const a = await cacheKey(cleanParams({ ...base, campaign_ids: ["2", "1"] }, TODAY), "acc");
  const b = await cacheKey(cleanParams({ ...base, campaign_ids: ["1", "2"] }, TODAY), "acc");
  const c = await cacheKey(cleanParams({ ...base, campaign_ids: ["1", "2"] }, TODAY), "other");
  assert.equal(a, b); assert.notEqual(a, c); assert.match(a, /^[0-9a-f]{64}$/);
});

const day = (date: string, spend: number, leads: number) => ({ date_start: date, spend: String(spend), impressions: "1000", inline_link_clicks: "10",
  actions: leads ? [{ action_type: "lead", value: String(leads) }] : [] });
const iso = (k: number) => new Date(Date.parse("2026-11-17T00:00:00Z") - k * 86400e3).toISOString().slice(0, 10);
const days = [...Array.from({ length: 14 }, (_, i) => day(iso(i + 4), 1000, 20)), day(iso(3), 1000, 10), day(iso(2), 1000, 10), day(iso(1), 2000, 0), day(iso(0), 300, 1)];

test("Health: account, rejected ads, issues, learning limited, no leads, cost per lead up, spend jump, Opportunity Score", () => {
  const { data, warnings } = healthWarnings({ today: "2026-11-17", currency: "INR",
    account: { name: "We One", account_status: 1, spend_cap: "5000000", amount_spent: "4600000" },
    opportunity: { opportunity_score: 64 },
    recommendations: [{ type: "BUDGET_LIMITED", title: "Raise budget", body: "Stable ad sets", lift_estimate: "Up to 3% more leads", opportunity_score_lift: "14",
      url: "https://adsmanager.facebook.com/x" }, { type: "X", url: "javascript:alert(1)" }],
    campaigns: [{ id: "7001", name: "CPL", daily_budget: "100000" }],
    adsets: [{ id: "8001", name: "Delhi", daily_budget: "50000", learning_stage_info: { status: "FAIL" } }, { id: "8002", name: "India", learning_stage_info: { status: "LEARNING" } }],
    ads: [{ id: "9001", name: "Reel", effective_status: "DISAPPROVED", ad_review_feedback: { global: { "Personal attributes": "Ad implies age" } } },
      { id: "9002", name: "Image", effective_status: "WITH_ISSUES", issues_info: [{ error_summary: "Image has too much text" }] }],
    days, errors: [] });
  const kinds = warnings.map((w) => w.kind).sort();
  assert.deepEqual(kinds, ["ad_issue", "ad_rejected", "cpl_up", "learning_limited", "no_leads", "spend_cap", "spend_jump"]);
  assert.match(warnings.find((w) => w.kind === "ad_rejected")!.detail!, /Personal attributes: Ad implies age/);
  assert.equal(warnings.find((w) => w.kind === "spend_cap")!.severity, "medium");
  assert.equal(data.opportunity.score, 64);
  assert.deepEqual([data.opportunity.recommendations[0].score_lift, data.opportunity.recommendations[0].url, data.opportunity.recommendations[1].url], [14, "https://adsmanager.facebook.com/x", null]);
  assert.deepEqual([data.pacing.daily_budget, data.pacing.today_spend, data.delivery.learning.limited, data.delivery.rejected], [1500, 300, 1, 1]);
  assert.equal(units("100000", "INR"), 1000);
  const quiet = healthWarnings({ today: "2026-11-17", currency: "INR", account: { account_status: 1 }, opportunity: {}, recommendations: [], campaigns: [], adsets: [], ads: [], days: [], errors: ["x"] });
  assert.deepEqual([quiet.warnings.length, quiet.data.opportunity.score], [0, null]);
  const off = healthWarnings({ today: "2026-11-17", currency: "INR", account: { account_status: 3 }, opportunity: {}, recommendations: [], campaigns: [], adsets: [], ads: [], days: [], errors: [] });
  assert.match(off.warnings[0].title, /Unsettled/);
});
