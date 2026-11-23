// Unit tests for Meta Ads > Strategy (migration 104): the agents' Meta context (ads_agents_ctx.ts), Create in Meta
// (meta_build.ts: steps, request bodies, targeting), the MetaAds create / search / picture calls (fake fetch, no network)
// and the speed-to-lead alert text (lead_alerts.ts).
// Run: deno test --allow-all meta_strategy.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { MetaAds } from "../../functions/_shared/ads_core.ts";
import { META_LIMITS, trimMetaContext } from "../../functions/_shared/ads_agents_ctx.ts";
import {
  adParams, adsetParams, bestMatch, businessPhone, campaignParams, countryCode, createLeadForm, creativeParams, formAttempts, formParams, geoQueries, imageKind, minor, planSteps,
  swapDeprecated, targeting, type BuildWork,
} from "../../functions/_shared/meta_build.ts";
import { alertText } from "../../functions/_shared/lead_alerts.ts";

const plan = {
  title: "CPL admissions", forms: [{ key: "f1", name: "CPL enquiry", type: "higher_intent", headline: "Talk to a counsellor", intro: "Tell us where you are.",
    questions: [{ type: "FULL_NAME" }, { type: "PHONE" }, { type: "CUSTOM", label: "Finished class 12 with PCM?", options: ["Yes", "Not yet"] }],
    thank_you: { title: "Thanks", body: "We will call you.", button_text: "Visit website" } }],
  campaigns: [
    { key: "c1", name: "Leads CPL", objective: "OUTCOME_LEADS", budget_level: "adset", adsets: [
      { key: "a1", name: "Delhi 18-24", daily_budget: 500, optimization: "LEAD_GENERATION", form: "f1", ads: ["i1", "v1"], placements: "advantage",
        audience: { locations: [{ name: "Delhi", type: "city", radius_km: 120 }, { name: "India", type: "country" }], age_min: 18, age_max: 24,
          genders: "male", interests: ["Aviation"], advantage_audience: false } }] },
    { key: "c2", name: "Broad", objective: "OUTCOME_LEADS", budget_level: "campaign", daily_budget: 800, adsets: [
      { key: "a2", name: "India broad", daily_budget: null, optimization: "LEAD_GENERATION", form: "f1", ads: ["i1"],
        placements: ["instagram_reels", "facebook_feed", "nonsense"],
        audience: { locations: [{ name: "India", type: "country" }], age_min: 20, age_max: 35, genders: "all", interests: [], advantage_audience: true } }] }],
  creatives: [
    { key: "i1", name: "Steps to CPL", format: "image", primary_text: "Five steps from class 12 to a CPL.", headline: "Your path to a CPL", description: "Dwarka", cta: "SIGN_UP" },
    { key: "v1", name: "Day at class", format: "video", primary_text: "A day of DGCA ground classes.", headline: "Ground classes", cta: "LEARN_MORE" }],
};
const work = (over: Partial<BuildWork> = {}): BuildWork => ({ strategy_id: 12, version: 1, account_id: "564511644492586", currency: "INR",
  page_id: "100521046017357", goal: { website_url: "https://weoneaviation.in", privacy_url: "https://weoneaviation.in/privacy", start_date: "2026-12-01" },
  plan, steps: {}, images: {}, ...over });

test("Lead form thank-you button: website by default, call the counsellor, WhatsApp, and what to retry when Meta refuses", () => {
  const ty = (thank_you: any, over: Partial<BuildWork> = {}) => JSON.parse(formParams(work(over), { ...plan.forms[0], thank_you }).thank_you_page);
  const web = ty(plan.forms[0].thank_you);
  assert.equal(web.button_type, "VIEW_WEBSITE"); assert.equal(web.website_url, "https://weoneaviation.in"); assert.equal(web.business_phone_number, undefined);
  // "call": the number from the form, else the plan's goal, else the strategy goal; always in full international form
  const call = ty({ title: "Thanks", body: "A counsellor will call you.", button: "call", phone: "+91 93555 66991" });
  assert.deepEqual([call.button_type, call.button_text, call.business_phone_number, call.country_code], ["CALL_BUSINESS", "Call now", "+919355566991", "IN"]);
  assert.equal(call.website_url, "https://weoneaviation.in");
  const fromPlan = ty({ title: "Thanks", button: "CALL", button_text: "Call counsellor" }, { plan: { ...plan, goal: { phone: "93555 66991" } } });
  assert.deepEqual([fromPlan.button_type, fromPlan.button_text, fromPlan.business_phone_number], ["CALL_BUSINESS", "Call counsellor", "+919355566991"]);
  const fromGoal = ty({ title: "Thanks", button: "call" }, { goal: { ...work().goal, phone: "+91-93555-66991" } });
  assert.equal(fromGoal.business_phone_number, "+919355566991");
  const noNumber = ty({ title: "Thanks", button: "call", button_text: "Call now" });
  assert.deepEqual([noNumber.button_type, noNumber.button_text], ["VIEW_WEBSITE", "Visit website"]);   // no number: never a dead call button
  const wa = ty({ title: "Thanks", button: "whatsapp", phone: "+919355566991" });
  assert.deepEqual([wa.button_type, wa.button_text, wa.business_phone_number], ["WHATSAPP", "Chat on WhatsApp", undefined]);
  assert.equal(ty({ title: "Thanks", button: "telegram" }).button_type, "VIEW_WEBSITE");
  // retries: WhatsApp -> call -> no extra screens; call or website -> no extra screens
  const waForm = { ...plan.forms[0], thank_you: { title: "Thanks", button: "whatsapp", phone: "+919355566991" } };
  const tries = formAttempts(work(), waForm);
  assert.deepEqual(tries.map((t) => t.thank_you_page ? JSON.parse(t.thank_you_page).button_type : null), ["WHATSAPP", "CALL_BUSINESS", null]);
  assert.deepEqual(formAttempts(work(), plan.forms[0]).map((t) => t.thank_you_page ? JSON.parse(t.thank_you_page).button_type : null), ["VIEW_WEBSITE", null]);
  // plan v5 form f2 says it in Meta's own names
  const v5 = ty({ title: "Thank you! Talk to a counsellor now", body: "Tap Call now.", button_text: "Call now", button_type: "CALL_BUSINESS", phone: "+919355566991" });
  assert.deepEqual([v5.button_type, v5.button_text, v5.business_phone_number, v5.country_code], ["CALL_BUSINESS", "Call now", "+919355566991", "IN"]);
  assert.equal(ty({ title: "T", button_type: "call_business", business_phone_number: "+91 93555 66991" }).business_phone_number, "+919355566991");
  assert.equal(ty({ title: "T", button_type: "WHATSAPP" }).button_type, "WHATSAPP");
  assert.equal(ty({ title: "T", button_type: "VIEW_WEBSITE", button: "call", phone: "+919355566991" }).button_type, "VIEW_WEBSITE");
  assert.equal(ty({ title: "T", button_type: "DOWNLOAD" }).button_type, "VIEW_WEBSITE");
  assert.equal(businessPhone("12345"), null); assert.equal(businessPhone(""), null);
  assert.deepEqual(businessPhone("+1 415 555 0100"), { number: "+14155550100", country: null });
});

test("Lead form fallback is never silent: the warning says what Meta refused and what the form lacks (QA S10)", async () => {
  const f2 = { ...plan.forms[0], thank_you: { title: "Thanks", button_type: "CALL_BUSINESS", phone: "+919355566991" } };
  const seen: string[] = [];
  const ok = await createLeadForm(work(), f2, async (p) => { seen.push(JSON.parse(p.thank_you_page ?? "null")?.button_type ?? "none"); return "111"; }, () => false);
  assert.deepEqual([ok.id, ok.attempt, ok.warning, seen], ["111", 0, null, ["CALL_BUSINESS"]]);
  // Meta refuses the call button: the form is made without the extra screens, with a warning
  const calls: string[] = [];
  const r = await createLeadForm(work(), f2, async (p) => {
    calls.push(p.thank_you_page ? "full" : "minimal");
    if (p.thank_you_page) throw new Error("(#100) Invalid parameter: business_phone_number");
    return "222";
  }, () => false);
  assert.deepEqual([r.id, r.attempt, calls], ["222", 1, ["full", "minimal"]]);
  assert.match(r.warning!, /refused the form's intro \/ thank-you screens \(\(#100\) Invalid parameter: business_phone_number\)/);
  assert.match(r.warning!, /WITHOUT them: no intro text and no Call button\. Check it in Ads Manager/);
  // WhatsApp refused: the Call button is used, and said so
  const fw = { ...plan.forms[0], thank_you: { title: "Thanks", button_type: "WHATSAPP", phone: "+919355566991" } };
  const rw = await createLeadForm(work(), fw, async (p) => { if (JSON.parse(p.thank_you_page ?? "{}").button_type === "WHATSAPP") throw new Error("WhatsApp not linked"); return "333"; }, () => false);
  assert.equal(rw.attempt, 1); assert.match(rw.warning!, /refused the WhatsApp button \(WhatsApp not linked\), so the form has the Call button instead/);
  // a login / rate-limit error is not retried
  await assert.rejects(createLeadForm(work(), f2, async () => { throw new Error("token expired"); }, () => true), /token expired/);
});

test("Create in Meta: forms, campaigns, ad sets, one creative per creative and form, then ads, in that order", () => {
  const s = planSteps(work({ images: { i1: { hash: "h1" } } }));
  assert.deepEqual(s.map((x) => x.key), ["form:f1", "campaign:c1", "campaign:c2", "adset:a1", "adset:a2", "creative:i1:f1", "creative:v1:f1",
    "ad:a1:i1", "ad:a1:v1", "ad:a2:i1"]);
  assert.deepEqual(s.find((x) => x.key === "ad:a1:i1")!.needs, ["adset:a1", "creative:i1:f1"]);
  assert.match(s.find((x) => x.key === "creative:v1:f1")!.skip!, /Video ad: attach its video in Growth > Content/);
  assert.equal(s.find((x) => x.key === "creative:i1:f1")!.skip, undefined);
  assert.match(planSteps(work()).find((x) => x.key === "creative:i1:f1")!.skip!, /Add the picture/);
});

test("Create in Meta: everything PAUSED, budgets in paise, ad-set budgets keep their split, names carry the strategy", () => {
  const c1 = campaignParams(work(), plan.campaigns[0]), c2 = campaignParams(work(), plan.campaigns[1]);
  assert.equal(c1.status, "PAUSED"); assert.equal(c1.objective, "OUTCOME_LEADS"); assert.equal(c1.special_ad_categories, "[]");
  assert.equal(c1.is_adset_budget_sharing_enabled, "false"); assert.equal(c1.daily_budget, undefined);
  assert.equal(c2.daily_budget, "80000"); assert.equal(c2.bid_strategy, "LOWEST_COST_WITHOUT_CAP"); assert.equal(c2.is_adset_budget_sharing_enabled, undefined);
  assert.equal(c1.name, "Leads CPL · CRM S12");
  assert.equal(minor(499.5, "INR"), 49950); assert.equal(minor(500, "JPY"), 500);
  const t = targeting(plan.campaigns[0].adsets[0], { countries: [], regions: [], cities: [{ key: "1035921", radius: 80, distance_unit: "kilometer" }] }, [{ id: "6003", name: "Aviation" }]);
  const a1 = adsetParams(work(), plan.campaigns[0], plan.campaigns[0].adsets[0], "120", t, "2026-11-17");
  assert.equal(a1.status, "PAUSED"); assert.equal(a1.daily_budget, "50000"); assert.equal(a1.destination_type, "ON_AD");
  assert.equal(a1.optimization_goal, "LEAD_GENERATION"); assert.equal(a1.promoted_object, '{"page_id":"100521046017357"}');
  assert.equal(a1.start_time, "2026-12-01T09:00:00+0530");
  const a2 = adsetParams(work(), plan.campaigns[1], plan.campaigns[1].adsets[0], "121", {}, "2026-12-05");
  assert.equal(a2.daily_budget, undefined); assert.equal(a2.bid_strategy, undefined); assert.equal(a2.start_time, undefined);
  assert.deepEqual(JSON.parse(adParams(work(), "Steps to CPL", "9", "8").creative), { creative_id: "8" });
  assert.equal(adParams(work(), "x", "9", "8").status, "PAUSED");
});

test("Targeting: manual audiences keep ages and gender; Advantage+ keeps 18-65 as limits and the plan's ages as a suggestion", () => {
  const manual = targeting(plan.campaigns[0].adsets[0], { countries: ["IN"], regions: [], cities: [] }, [{ id: "6003", name: "Aviation" }]) as any;
  assert.deepEqual([manual.age_min, manual.age_max, manual.genders], [18, 24, [1]]);
  assert.deepEqual(manual.targeting_automation, { advantage_audience: 0 });
  assert.deepEqual(manual.flexible_spec, [{ interests: [{ id: "6003", name: "Aviation" }] }]);
  assert.equal(manual.publisher_platforms, undefined);   // Advantage+ placements: no placement fields
  const adv = targeting(plan.campaigns[1].adsets[0], { countries: ["IN"], regions: [], cities: [] }, []) as any;
  assert.deepEqual([adv.age_min, adv.age_max, adv.age_range], [18, 65, [20, 35]]);
  assert.deepEqual(adv.targeting_automation, { advantage_audience: 1 });
  assert.equal(adv.genders, undefined);
  assert.deepEqual(adv.publisher_platforms, ["instagram", "facebook"]);
  assert.deepEqual(adv.instagram_positions, ["reels"]); assert.deepEqual(adv.facebook_positions, ["feed"]);
  // never under 18 or over 65, whatever the plan says
  const odd = targeting({ audience: { age_min: 15, age_max: 90, advantage_audience: false } }, { countries: ["IN"], regions: [], cities: [] }, []) as any;
  assert.deepEqual([odd.age_min, odd.age_max], [18, 65]);
  assert.deepEqual(geoQueries(plan.campaigns[0].adsets[0]), [{ name: "Delhi", type: "city", radius_km: 80 }, { name: "India", type: "country" }]);
  assert.equal(countryCode("India"), "IN"); assert.equal(countryCode("IN"), "IN"); assert.equal(countryCode("Atlantis"), null);
  assert.equal(bestMatch([{ name: "Delhi", country_code: "US" }, { name: "Delhi", country_code: "IN" }], "delhi")!.country_code, "IN");
  assert.equal(bestMatch([], "x"), null);
});

test("Lead form and creative: questions with keys, higher intent, privacy policy, the form inside the ad", () => {
  const f = formParams(work(), plan.forms[0]);
  const q = JSON.parse(f.questions);
  assert.deepEqual(q[0], { type: "FULL_NAME" });
  assert.deepEqual(q[2], { type: "CUSTOM", key: "q1", label: "Finished class 12 with PCM?", options: [{ value: "Yes", key: "q1o1" }, { value: "Not yet", key: "q1o2" }] });
  assert.equal(f.is_optimized_for_quality, "true");
  assert.deepEqual(JSON.parse(f.privacy_policy), { url: "https://weoneaviation.in/privacy", link_text: "Privacy policy" });
  assert.ok(f.context_card && f.thank_you_page);
  const min = formParams(work(), plan.forms[0], true);
  assert.equal(min.context_card, undefined); assert.equal(min.thank_you_page, undefined);
  const c = JSON.parse(creativeParams(work({ images: { i1: { hash: "h1" } } }), plan.creatives[0], "777").object_story_spec);
  assert.equal(c.page_id, "100521046017357");
  assert.deepEqual(c.link_data.call_to_action, { type: "SIGN_UP", value: { lead_gen_form_id: "777" } });
  assert.equal(c.link_data.image_hash, "h1"); assert.equal(c.link_data.name, "Your path to a CPL");
});

test("Pictures: PNG and JPEG only", () => {
  assert.equal(imageKind("iVBORw0KGgoAAAANSUhEUg"), "png");
  assert.equal(imageKind("/9j/4AAQSkZJRgABAQ"), "jpeg");
  assert.equal(imageKind("R0lGODlhAQABAIAAAP"), null);   // GIF
});

test("MetaAds create / search / picture upload: form posts, ids back, errors surface", async () => {
  const calls: { url: string; body?: string }[] = [];
  const fake = async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), body: init?.body as string | undefined });
    const u = String(url);
    if (u.includes("/adimages")) return new Response(JSON.stringify({ images: { "p.png": { hash: "abc", url: "x" } } }));
    if (u.includes("/search")) return new Response(JSON.stringify({ data: [{ key: "1035921", name: "Delhi", country_code: "IN" }] }));
    if (u.includes("/bad")) return new Response(JSON.stringify({ error: { message: "Invalid parameter", code: 100 } }), { status: 400 });
    return new Response(JSON.stringify({ id: "120200000000001" }));
  };
  const m = new MetaAds({ accessToken: "EAAtoken", version: "v26.0" }, fake as typeof fetch);
  assert.equal(await m.create("act_1/campaigns", { name: "x", status: "PAUSED" }), "120200000000001");
  assert.match(calls[0].body!, /status=PAUSED/);
  assert.equal((await m.search({ type: "adgeolocation", q: "Delhi" }))[0].key, "1035921");
  assert.match(calls[1].url, /search\?limit=10&type=adgeolocation&q=Delhi/);
  assert.equal(await m.uploadImage("1", "iVBORw0KGgo", "p.png"), "abc");
  await assert.rejects(() => m.create("bad", {}), /Invalid parameter/);
});

test("Agents' Meta context: Insights cut to what a planner reads, with the CRM's own patterns", () => {
  const ads = Array.from({ length: 70 }, (_, i) => ({ ext: `9${i}`, name: `Ad ${i}`, spend: 1000 - i, meta_leads: i % 5, crm_leads: 0, qualified: 0, customers: 0,
    info: { format: "video", body: "x".repeat(900), thumbnail_url: "https://cdn/x.jpg", form_id: "555" } }));
  const ctx = trimMetaContext({ goal: { objective: "leads" }, insights: {
    period: { days: 1125 }, current: { spend: 50000, meta_leads: 650 }, board: {
      campaign: [{ ext: "7001", name: "Pilot Training Nov", spend: 15518, meta_leads: 401, objective: "OUTCOME_LEADS" },
                 { ext: "7002", name: "Engagement", spend: 6699, meta_leads: 0, objective: "OUTCOME_ENGAGEMENT" }],
      adset: [{ ext: "8001", name: "Delhi", spend: 100, info: { goal: "LEAD_GENERATION", age_min: 18, cities: ["Delhi"], advantage: false, extra: "drop" } }],
      ad: ads }, breakdowns: { age_gender: [] }, weekday: [], fatigue: [], trend: Array.from({ length: 40 }, (_, i) => ({ week: i })) } });
  assert.equal(ctx.insights.ads.length, META_LIMITS.ad);
  assert.equal(ctx.insights.rows_not_shown.ads, 30);
  assert.equal(ctx.insights.ads[0].creative.body.length, META_LIMITS.text + 1);   // cut, with an ellipsis
  assert.equal(ctx.insights.ads[0].creative.thumbnail_url, undefined);
  assert.deepEqual(ctx.insights.adsets[0].targeting, { goal: "LEAD_GENERATION", age_min: 18, cities: ["Delhi"], advantage: false });
  assert.equal(ctx.insights.weekly_trend_last_26.length, 26);
  assert.equal(ctx.patterns.judged_on, "meta_leads");
  assert.ok(Array.isArray(ctx.patterns.items));
  assert.ok(ctx.patterns.items.some((p: any) => /Engagement/.test(p.title) && p.tone === "loss"));
  assert.deepEqual(trimMetaContext({ goal: 1 }), { goal: 1 });   // no insights: unchanged
});

test("Speed-to-lead alert text: first name and course only, the right section, escalation wording", () => {
  const a = { lead_id: "l1", level: 1, waited_min: 6, first_name: "Ravi", course: "CPL", platform: "meta", emails: [], subs: [] };
  const m = alertText(a);
  assert.equal(m.title, "Call now: Ravi (CPL)");
  assert.equal(m.url, "https://crm.weoneaviation.in/#/metaads/leads");
  assert.equal(m.tag, "lead-l1");
  const g = alertText({ ...a, level: 2, platform: "google", course: null, waited_min: 18 });
  assert.equal(g.title, "Still not called: Ravi");
  assert.match(g.body, /waited 18 minutes/);
  assert.equal(g.url, "https://crm.weoneaviation.in/#/ads/leads");
});

test("Video ads (117): with an uploaded video and cover the video creative is built, PAUSED, with its approved text and the lead form", () => {
  const w = work({ images: { i1: { hash: "h1" } }, videos: { v1: { id: "9001", thumb_hash: "th1" } } });
  assert.equal(planSteps(w).find((x) => x.key === "creative:v1:f1")!.skip, undefined);
  assert.match(planSteps(work({ videos: { v1: { id: "9001" } } })).find((x) => x.key === "creative:v1:f1")!.skip!, /attach its video/);   // no cover yet
  const c = JSON.parse(creativeParams(w, plan.creatives[1], "777").object_story_spec);
  assert.deepEqual(c.video_data, { video_id: "9001", image_hash: "th1", message: "A day of DGCA ground classes.", title: "Ground classes",
    call_to_action: { type: "LEARN_MORE", value: { lead_gen_form_id: "777" } } });
  assert.equal(c.link_data, undefined);
  assert.ok(JSON.parse(creativeParams(w, plan.creatives[0], "777").object_story_spec).link_data.image_hash === "h1");     // pictures unchanged
});

test("MetaAds video upload: Meta fetches the file from a link; status is read back", async () => {
  const calls: { url: string; body?: string }[] = [];
  const fake = async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), body: init?.body as string | undefined });
    if (String(url).includes("/advideos")) return new Response(JSON.stringify({ id: "9001" }));
    return new Response(JSON.stringify({ status: { video_status: "ready" } }));
  };
  const m = new MetaAds({ accessToken: "EAAtoken", version: "v26.0" }, fake as typeof fetch);
  assert.equal(await m.uploadVideo("1", "https://x.supabase.co/storage/v1/object/sign/content/ad/5/video.mp4?token=t", "Ad"), "9001");
  assert.match(calls[0].url, /act_1\/advideos/); assert.match(calls[0].body!, /file_url=https%3A%2F%2Fx\.supabase\.co/);
  assert.equal(await m.videoStatus("9001"), "ready"); assert.match(calls[1].url, /9001\?fields=status/);
});

test("Ad studio (119): a posted Instagram post becomes the ad itself, with the lead form; without the account it falls back", () => {
  const w = work({ posts: { v1: { ig_media_id: "17950000000000001" } }, ig_user_id: "17841400000000001" });
  assert.equal(planSteps(w).find((x) => x.key === "creative:v1:f1")!.skip, undefined);
  const c = creativeParams(w, plan.creatives[1], "777");
  assert.equal(c.source_instagram_media_id, "17950000000000001"); assert.equal(c.instagram_user_id, "17841400000000001");
  assert.equal(c.object_id, "100521046017357"); assert.equal(c.object_story_spec, undefined);
  assert.deepEqual(JSON.parse(c.call_to_action), { type: "LEARN_MORE", value: { lead_gen_form_id: "777", link: work({}).goal.website_url || "https://weoneaviation.in" } });
  assert.match(planSteps(work({ posts: { v1: { ig_media_id: "1795" } } })).find((x) => x.key === "creative:v1:f1")!.skip!, /attach its video/);   // no account id
});

test("MetaAds Instagram: container, status, publish, numbers, comments, reply and hide", async () => {
  const calls: { url: string; body?: string; method?: string }[] = [];
  const fake = async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url); calls.push({ url: u, body: init?.body as string | undefined, method: init?.method });
    if (u.includes("/me/permissions")) return new Response(JSON.stringify({ data: [{ permission: "instagram_basic", status: "granted" }, { permission: "ads_read", status: "declined" }] }));
    if (u.includes("instagram_business_account")) return new Response(JSON.stringify({ instagram_business_account: { id: "1784", username: "we_one_aviation" } }));
    if (u.endsWith("/1784/media")) return new Response(JSON.stringify({ id: "c1" }));
    if (u.includes("/c1?")) return new Response(JSON.stringify({ status_code: "FINISHED" }));
    if (u.endsWith("/media_publish")) return new Response(JSON.stringify({ id: "m1" }));
    if (u.includes("/m1/insights")) return new Response(JSON.stringify({ data: [{ name: "views", values: [{ value: 4210 }] }, { name: "saved", total_value: { value: 41 } }] }));
    if (u.includes("/m1/comments")) return new Response(JSON.stringify({ data: [{ id: "18000", text: "Fees?", username: "p", timestamp: "2026-11-20T10:00:00+0000" }] }));
    if (u.includes("/m1?")) return new Response(JSON.stringify({ permalink: "https://www.instagram.com/reel/abc/", like_count: 186 }));
    return new Response(JSON.stringify({ id: "r1", success: true }));
  };
  const m = new MetaAds({ accessToken: "EAAtoken", version: "v26.0" }, fake as typeof fetch);
  assert.deepEqual(await m.permissions(), ["instagram_basic"]);
  assert.deepEqual(await m.igAccount("100521046017357"), { id: "1784", username: "we_one_aviation" });
  assert.equal(await m.igContainer("1784", { media_type: "REELS", video_url: "https://x/v.mp4", caption: "Hi", is_ai_generated: "true" }), "c1");
  assert.match(calls.at(-1)!.body!, /media_type=REELS/); assert.match(calls.at(-1)!.body!, /is_ai_generated=true/);
  assert.equal(await m.igContainerStatus("c1"), "FINISHED");
  assert.equal(await m.igPublish("1784", "c1"), "m1"); assert.match(calls.at(-1)!.body!, /creation_id=c1/);
  assert.equal((await m.igMedia("m1")).like_count, 186);
  assert.deepEqual(await m.igInsights("m1", ["views", "saved"]), { views: 4210, saved: 41 });
  assert.equal((await m.igComments("m1"))[0].id, "18000");
  assert.equal(await m.igReply("18000", "Call us for the fee breakdown"), "r1"); assert.match(calls.at(-1)!.url, /18000\/replies/);
  await m.igHide("18000", true); assert.match(calls.at(-1)!.body!, /hide=true/);
});

test("Build (121): a retired interest is swapped for Meta's replacement; other errors are left alone", () => {
  const msg = 'OAuthException 100: Please update the targeting spec to remove them or replace them with alternative options. Relevant alternative options: [{"deprecated_interest_id":"6003089113592","deprecated_interest_name":"Flight training","alternative_interest_id":"6002963523717","alternative_interest_name":"Aviation"},{"deprecated_interest_id":"55"}]';
  const ints = [{ id: "6003089113592", name: "Flight training" }, { id: "6002963523717", name: "Aviation" }, { id: "55", name: "Old" }, { id: "9", name: "Pilot" }];
  assert.deepEqual(swapDeprecated(msg, ints), [{ id: "6002963523717", name: "Aviation" }, { id: "9", name: "Pilot" }]);
  assert.equal(swapDeprecated("OAuthException 100: Invalid parameter", ints), null);
});
