// 107: Funnel audience helpers (engagement rules, Replace batches, errors) and audience targeting in builds.
import { test } from "node:test";
import assert from "node:assert/strict";
import { audienceError, engagementRule, replaceBatches, sizeOf } from "../../functions/_shared/meta_audience.ts";
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
  assert.ok(/Unknown/.test(engagementRule({ source: "pixel" }, ids).missing!));
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
  assert.deepEqual(audienceSpec({ audience: { include_audiences: ["ig_visit_30"] } }, aud).missing, ["ig_visit_30"]);
  assert.deepEqual((targeting({ audience: {} }, geo, []) as any).excluded_custom_audiences, undefined);
});
