// Unit tests for Meta Ads > Insights (migration 103): meta_history.ts (Graph rows -> stored rows), the MetaAds history
// calls (fake fetch, no network) and meta_patterns.ts (patterns, what-if, monthly summary text).
// Run: deno test --allow-all meta_insights.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { MetaAds } from "../../functions/_shared/ads_core.ts";
import {
  BREAKDOWNS, creativeInfo, metaLeadCount, monthChunks, monthsBack, namesFromDays, parseAd, parseAdDay, parseAdset, parseBreakdown,
} from "../../functions/_shared/meta_history.ts";
import { audienceTraits, chooseGoal, creativeTraits, findPatterns, reportText, whatIf } from "../../functions/_shared/meta_patterns.ts";

test("metaLeadCount: total 'lead' first, else the form + website parts, else 0", () => {
  assert.equal(metaLeadCount([{ action_type: "lead", value: "7" }, { action_type: "onsite_conversion.lead_grouped", value: "5" }]), 7);
  assert.equal(metaLeadCount([{ action_type: "onsite_conversion.lead_grouped", value: "5" }, { action_type: "offsite_conversion.fb_pixel_lead", value: "2" }]), 7);
  assert.equal(metaLeadCount(undefined), 0);
});

test("parseAdDay keeps ids, numbers and leads; rejects rows without an ad id or date", () => {
  const r = parseAdDay({ ad_id: "120200000000001", adset_id: "120200000000002", campaign_id: "120200000000003", date_start: "2025-03-04",
    spend: "512.40", impressions: "9000", clicks: "120", inline_link_clicks: "80", frequency: "1.4",
    actions: [{ action_type: "lead", value: "6" }, { action_type: "video_view", value: "300" }] });
  assert.deepEqual(r, { ad_ext: "120200000000001", adset_ext: "120200000000002", campaign_ext: "120200000000003", day: "2025-03-04",
    spend: 512.4, impressions: 9000, clicks: 120, link_clicks: 80, leads: 6, video_views: 300, frequency: 1.4 });
  assert.equal(parseAdDay({ ad_id: "x", date_start: "2025-03-04" }), null);
  assert.equal(parseAdDay({ ad_id: "120200000000001" }), null);
});

test("names come with the numbers, so deleted ads keep a name", () => {
  const n = namesFromDays([{ ad_id: "1001", ad_name: "Reel A", adset_id: "2002", adset_name: "Delhi 18-24", campaign_id: "3003", campaign_name: "CPL Leads" },
    { ad_id: "1001", ad_name: "Reel A", adset_id: "2002", campaign_id: "3003" }]);
  assert.equal(n.length, 3);
  assert.deepEqual(n.find((x) => x.level === "ad"), { level: "ad", external_id: "1001", campaign_ext: "3003", adset_ext: "2002", name: "Reel A" });
});

test("creativeInfo reads format, text, call to action and the lead form from each creative shape", () => {
  const v = creativeInfo({ video_id: "9", object_story_spec: { video_data: { message: "Pilot banna hai?", title: "CPL", call_to_action: { type: "SIGN_UP", value: { lead_gen_form_id: "555000111" } } } } });
  assert.equal(v.format, "video"); assert.equal(v.body, "Pilot banna hai?"); assert.equal(v.cta, "SIGN_UP"); assert.equal(v.form_id, "555000111");
  assert.equal(creativeInfo({ object_story_spec: { link_data: { child_attachments: [{}, {}], message: "x" } } }).format, "carousel");
  assert.equal(creativeInfo({ asset_feed_spec: { bodies: [{ text: "Fly" }], call_to_action_types: ["LEARN_MORE"] } }).format, "dynamic");
  assert.equal(creativeInfo({ image_url: "https://x/y.jpg", body: "Join DGCA ground classes" }).format, "image");
  const ad = parseAd({ id: "1001", adset_id: "2002", campaign_id: "3003", effective_status: "PAUSED", creative: { title: "T" } });
  assert.equal(ad.status, "PAUSED"); assert.equal(ad.adset_ext, "2002");
});

test("parseAdset summarises targeting without keeping audience details", () => {
  const s = parseAdset({ id: "2002", campaign_id: "3003", optimization_goal: "LEAD_GENERATION", targeting: { age_min: 18, age_max: 24, genders: [1],
    geo_locations: { countries: ["IN"], cities: [{ key: "1", name: "New Delhi" }] }, flexible_spec: [{ interests: [{ id: 1 }, { id: 2 }] }],
    custom_audiences: [{ id: "9", name: "Lookalike (IN, 1%) - leads" }], targeting_automation: { advantage_audience: 1 } } });
  assert.deepEqual(s.info, { goal: "LEAD_GENERATION", age_min: 18, age_max: 24, genders: ["male"], countries: ["IN"], regions: [], cities: ["New Delhi"],
    interests: 2, custom_audiences: true, lookalike: true, advantage: true });
});

test("breakdowns: month and keys per kind; hours become 00-23; empty keys dropped", () => {
  assert.deepEqual(parseBreakdown("age_gender", { date_start: "2025-11-01", age: "18-24", gender: "female", spend: "100", actions: [{ action_type: "lead", value: "3" }] }),
    { month: "2025-11-01", k1: "18-24", k2: "female", spend: 100, impressions: 0, clicks: 0, leads: 3 });
  assert.equal(parseBreakdown("hour", { date_start: "2025-11-01", hourly_stats_aggregated_by_advertiser_time_zone: "21:00:00 - 21:59:59" })?.k1, "21");
  assert.equal(parseBreakdown("region", { date_start: "2025-11-01" }), null);
  assert.equal(BREAKDOWNS.find((b) => b.kind === "frequency")?.months, 6);
});

test("month chunks run from the cursor to today; monthsBack gives the back-fill start", () => {
  const c = monthChunks("2026-09-01", "2026-11-17");
  assert.deepEqual(c.map((x) => [x.since, x.until, x.next]), [["2026-09-01", "2026-09-30", "2026-10-01"], ["2026-10-01", "2026-10-31", "2026-11-01"], ["2026-11-01", "2026-11-17", "2026-12-01"]]);
  assert.equal(monthChunks("2026-12-01", "2026-11-17").length, 0);
  assert.equal(monthsBack("2026-11-17", 37), "2023-11-01");
  assert.equal(monthsBack("2026-11-17", 13), "2025-11-01");
});

test("MetaAds history calls: ad-level daily insights and account breakdowns, read-only GETs", async () => {
  const calls: string[] = [];
  const fetchFn = (async (u: string, init?: RequestInit) => {
    calls.push(`${init?.method ?? "GET"} ${u}`);
    return new Response(JSON.stringify({ data: [{ ad_id: "1" }] }), { status: 200 });
  }) as typeof fetch;
  const m = new MetaAds({ accessToken: "tok", version: "v26.0" }, fetchFn);
  await m.adDays("123", "2025-01-01", "2025-01-31");
  await m.breakdown("123", "age,gender", "2025-11-01", "2026-11-17");
  await m.historyAds("123");
  assert.ok(calls.every((c) => c.startsWith("GET https://graph.facebook.com/v26.0/act_123/")));
  assert.match(decodeURIComponent(calls[0]), /level=ad.*time_increment=1/);
  assert.match(decodeURIComponent(calls[1]), /breakdowns=age,gender.*time_increment=monthly/);
  assert.match(decodeURIComponent(calls[2]), /effective_status.*ARCHIVED/);
});

// ------------------------------------------------------------------ patterns
const board = (rows: any[]) => rows.map((r, i) => ({ ext: String(1000 + i), name: r.name ?? `R${i}`, impressions: 0, clicks: 0, meta_leads: 0,
  crm_leads: 0, qualified: 0, customers: 0, ...r }));
function sample() {
  return {
    period: { from: "2026-08-01", to: "2026-10-31", days: 92 },
    current: { spend: 300000, impressions: 900000, clicks: 9000, meta_leads: 600, crm_leads: 580, qualified: 120, customers: 12 },
    previous: { spend: 250000, impressions: 800000, clicks: 8000, meta_leads: 500, crm_leads: 480, qualified: 90, customers: 9 },
    board: {
      campaign: board([{ name: "Winner", spend: 120000, meta_leads: 300, qualified: 80, customers: 9 },
                       { name: "Loser", spend: 150000, meta_leads: 250, qualified: 35, customers: 3 },
                       { name: "Dud", spend: 30000, meta_leads: 50, qualified: 5, customers: 0 }]),
      adset: board([{ name: "Delhi 18-24", spend: 150000, qualified: 80, customers: 9, info: { age_min: 18, age_max: 24, genders: ["all"], cities: ["New Delhi"] } },
                    { name: "India 25-45", spend: 150000, qualified: 40, customers: 3, info: { age_min: 25, age_max: 45, genders: ["all"], countries: ["IN"] } }]),
      ad: board([{ name: "Reel Q", spend: 140000, qualified: 85, customers: 9, info: { format: "video", body: "Pilot banna hai? Join now" } },
                 { name: "Static", spend: 160000, qualified: 35, customers: 3, info: { format: "image", body: "DGCA classes. Fees from ₹2 lakh" } }]),
    },
    breakdowns: { age_gender: [{ k1: "18-24", k2: "male", spend: 100000, leads: 300 }, { k1: "35-44", k2: "female", spend: 60000, leads: 40 },
                               { k1: "25-34", k2: "male", spend: 140000, leads: 260 }] },
    weekday: [], fatigue: [{ week: 1, ctr_index: 1, ads: 7 }, { week: 2, ctr_index: 0.92, ads: 7 }, { week: 3, ctr_index: 0.74, ads: 6 }],
  };
}

test("goal: admissions when 8+, else qualified when 15+, else Meta leads", () => {
  assert.equal(chooseGoal({ customers: 8 }), "customers");
  assert.equal(chooseGoal({ customers: 3, qualified: 15 }), "qualified");
  assert.equal(chooseGoal({ qualified: 3 }), "meta_leads");
});

test("findPatterns ranks proven wins and losses by cost per admission against the account average", () => {
  const { goal, baseline, patterns } = findPatterns(sample());
  assert.equal(goal, "customers"); assert.equal(baseline, 25000);
  const win = patterns.find((p) => p.id === "campaign:1000")!;
  assert.equal(win.tone, "win"); assert.equal(win.confidence, "proven"); assert.match(win.title, /Campaign "Winner": ₹13,333 per admission, 47% cheaper/);
  const loss = patterns.find((p) => p.id === "campaign:1001")!;
  assert.equal(loss.tone, "loss"); assert.equal(loss.confidence, "proven"); assert.match(loss.title, /2\.0x the average cost/);
  assert.equal(patterns.find((p) => p.id === "campaign:1002"), undefined);   // ₹30,000 with no admission: not yet 2x the average cost
  assert.ok(patterns.some((p) => p.group === "creative" && /Video ads/.test(p.title) && p.tone === "win"));
  assert.ok(patterns.some((p) => p.group === "targeting" && /18–24/.test(p.title) && p.tone === "win"));
  assert.ok(patterns.some((p) => p.group === "audience" && /Ages 35-44, female: ₹1,500 per lead, 3\.0x/.test(p.title) && p.tone === "loss"));
  assert.match(patterns.find((p) => p.id === "fatigue")!.title, /week 3/);
  assert.ok(patterns.findIndex((p) => p.confidence === "early") === -1 || patterns.findIndex((p) => p.confidence === "early") > patterns.findIndex((p) => p.confidence === "proven"));
});

test("traits: format, hook, language, fees mention; audience age / geo / advantage", () => {
  const t = creativeTraits({ format: "video", cta: "SIGN_UP", body: "Pilot banna hai? Fees ₹45 lakh tak" });
  assert.equal(t.format, "Video ads"); assert.equal(t.hook, "Ads opening with a question"); assert.equal(t.language, "Hinglish ad text");
  assert.equal(t.money, "Ads that mention fees / cost");
  assert.equal(creativeTraits({ body: "पायलट बनें" }).language, "Hindi ad text");
  const a = audienceTraits({ age_min: 18, age_max: 24, genders: ["female"], cities: ["New Delhi"], advantage: false });
  assert.equal(a.age, "Ad sets aimed at ages 18–24"); assert.equal(a.gender, "Ad sets for female only"); assert.equal(a.geo, "Ad sets targeting New Delhi");
});

test("splits use their own average; whole-account splits are left out when filtered to a campaign", () => {
  const d: any = sample(); d.weekday = [1, 2, 3].map((dow) => ({ dow, spend: 1000, meta_leads: 5 }));
  assert.equal(findPatterns(d).patterns.filter((p) => p.id.startsWith("w:")).length, 0);   // all weekdays alike: nothing to say
  d.filters = { campaign: "7001" };
  assert.equal(findPatterns(d).patterns.filter((p) => p.id.startsWith("b:")).length, 0);
  assert.ok(findPatterns(sample()).patterns.some((p) => p.id.startsWith("b:age_gender")));
});

test("no patterns from tiny groups or without results", () => {
  const d = sample(); d.current = { ...d.current, spend: 0 } as any;
  assert.equal(findPatterns(d).patterns.filter((p) => p.group !== "fatigue" && p.group !== "audience").length, 0);
});

test("a campaign that spent 2x the average cost with no result is a proven loss", () => {
  const d = sample(); (d.board.campaign as any[])[2].spend = 60000;
  assert.match(findPatterns(d).patterns.find((p) => p.id === "campaign:1002")!.title, /₹60,000 spent, no admissions/);
});

test("whatIf moves weekly budget from losers to proven winners at their past cost", () => {
  const w = whatIf(sample(), 5000)!;
  assert.equal(w.goal, "customers"); assert.deepEqual(w.to, ["Winner"]); assert.deepEqual(w.from, ["Loser", "Dud"]);
  assert.equal(w.moved, 5000);
  assert.ok(w.gain > 0);
  assert.equal(whatIf({ ...sample(), board: { campaign: [] } }, 5000), null);
});

test("monthly summary text: numbers with change vs previous month and the top patterns", () => {
  const d = sample(); const { patterns } = findPatterns(d);
  const m = reportText("2026-10-01", d, patterns);
  assert.equal(m.subject, "Meta Ads summary - October 2026");
  assert.match(m.text, /Spend: ₹3,00,000 \(\+20% vs previous month\)/);
  assert.match(m.text, /per admission: ₹25,000/);
  assert.match(m.text, /\+ Campaign "Winner"/);
  assert.ok(!/<script/i.test(reportText("2026-10-01", { ...d, board: { campaign: [{ ext: "1", name: "<script>", spend: 1 }] } }, [{ id: "x", tone: "win", group: "c", title: "<script>x", detail: "", cost: 1, baseline: 1, ratio: 0.5, results: 1, spend: 1, confidence: "proven" }]).html));
});
