// Unit tests for supabase/functions/_shared/ads_meta.ts and the Meta lead / Conversions API calls in ads_core.ts (migration 100).
// Run: deno test --allow-all ads_meta.test.ts   or   node --experimental-strip-types --test supabase/tests/ads/ads_meta.test.ts
// No network: Meta is a fake fetch that records every request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac, createHash } from "node:crypto";
import { MetaAds, AdsError } from "../../functions/_shared/ads_core.ts";
import {
  buildEvent, consentAnswer, crmEvent, ctwaPayload, EventError, messagingEvent, metaLeadPayload, parseWebhook,
  safeEqual, serializeEvents, verifySignature, webEvent, type CapiItem,
  deployState, ADS_BUILD, isTestLead, organicPayload,
} from "../../functions/_shared/ads_meta.ts";

const hmac = async (k: string, m: string) => createHmac("sha256", k).update(m).digest("hex");
const sha = (s: string) => createHash("sha256").update(s).digest("hex");
const NOW = 1_794_800_000;

// ---------------------------------------------------------------- webhook signature
test("MW01 a correctly signed delivery is accepted", async () => {
  const body = '{"object":"page","entry":[]}';
  assert.equal(await verifySignature("appsecret123", body, `sha256=${await hmac("appsecret123", body)}`, hmac), true);
});
test("MW02 wrong secret, changed body, missing or malformed header, no secret: all refused", async () => {
  const body = '{"object":"page","entry":[]}';
  const good = `sha256=${await hmac("appsecret123", body)}`;
  assert.equal(await verifySignature("other-secret", body, good, hmac), false);
  assert.equal(await verifySignature("appsecret123", body + " ", good, hmac), false);
  assert.equal(await verifySignature("appsecret123", body, null, hmac), false);
  assert.equal(await verifySignature("appsecret123", body, good.replace("sha256=", "sha1="), hmac), false);
  assert.equal(await verifySignature("appsecret123", body, "sha256=abc", hmac), false);
  assert.equal(await verifySignature("", body, good, hmac), false);
  assert.equal(await verifySignature(null, body, good, hmac), false);
  assert.equal(safeEqual("abc", "abd"), false);
});

// ---------------------------------------------------------------- webhook parsing
test("MW03 a leadgen change becomes one instant_form row with Meta's ids", () => {
  const rows = parseWebhook({ object: "page", entry: [{ id: "111222333444", time: 1, changes: [{ field: "leadgen", value: {
    leadgen_id: "1234567890123456", page_id: "111222333444", form_id: "987654321", adgroup_id: "555", ad_id: "666", created_time: 1794800000 } }] }] });
  assert.deepEqual(rows, [{ source: "instant_form", external_id: "1234567890123456", page_id: "111222333444", form_id: "987654321",
    ad_id: "666", adgroup_id: "555", created_time: 1794800000 }]);
});
test("MW04 a WhatsApp message from an ad becomes a ctwa row; a normal message is ignored", () => {
  const rows = parseWebhook({ object: "whatsapp_business_account", entry: [{ id: "123456789012", changes: [{ field: "messages", value: {
    contacts: [{ wa_id: "919811200001", profile: { name: "Asha" } }],
    messages: [
      { from: "919811200001", timestamp: "1794800000", referral: { source_type: "ad", source_id: "777", source_url: "https://fb.me/x", ctwa_clid: "ARAkLkA8rmlFeiCktEJQ" } },
      { from: "919811200002", timestamp: "1794800001", text: { body: "hello" } }] } }] }] });
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0], { source: "ctwa", external_id: "ARAkLkA8rmlFeiCktEJQ", ad_id: "777", created_time: "1794800000",
    payload: { name: "Asha", phone: "919811200001", waba_id: "123456789012", source_url: "https://fb.me/x", headline: null } });
});
test("MW05 junk, other objects and other fields never throw and give nothing", () => {
  for (const b of [null, 1, "x", [], {}, { entry: "x" }, { object: "page", entry: [{ changes: [{ field: "feed", value: { leadgen_id: "1" } }] }] },
    { object: "instagram", entry: [{ changes: [{ field: "leadgen", value: { leadgen_id: "1" } }] }] },
    { object: "page", entry: [{ changes: [{ field: "leadgen", value: {} }, null, { field: "leadgen" }] }] }]) {
    assert.deepEqual(parseWebhook(b), []);
  }
});
test("MW06 one delivery can carry several leads (Meta batches up to 1000)", () => {
  const ch = (id: string) => ({ field: "leadgen", value: { leadgen_id: id, form_id: "9", page_id: "1" } });
  assert.equal(parseWebhook({ object: "page", entry: [{ id: "1", changes: [ch("100001"), ch("100002")] }, { id: "1", changes: [ch("100003")] }] }).length, 3);
});

// ---------------------------------------------------------------- Meta lead -> ADS intake payload
const LEAD = { id: "1234567890123456", created_time: "2026-11-16T09:00:00+0000", ad_id: "666", adset_id: "555", campaign_id: "120200000000001",
  form_id: "987654321", platform: "ig", is_organic: false,
  field_data: [{ name: "full_name", values: ["Asha Verma"] }, { name: "phone_number", values: ["+919811200001"] },
    { name: "email", values: ["Asha@Example.com"] }, { name: "course_interest", values: ["CPL"] }, { name: "ad_data_sharing", values: ["Yes"] },
    { name: "city", values: ["Delhi"] }] };
test("ML01 a Meta lead becomes an ADS intake payload marked as a paid Meta lead form, with the campaign id", () => {
  const p = metaLeadPayload(LEAD, { consentField: "ad_data_sharing" }) as any;
  assert.equal(p.name, "Asha Verma"); assert.equal(p.phone, "+919811200001"); assert.equal(p.email, "Asha@Example.com");
  assert.equal(p.course_interest, "CPL"); assert.equal(p.submission_id, "meta-lead-1234567890123456");
  assert.equal(p.utm_medium, "paid_social"); assert.equal(p.utm_source, "facebook");
  assert.equal(p.first_touch.meta_source, "instant_form"); assert.equal(p.first_touch.leadgen_id, "1234567890123456");
  assert.equal(p.first_touch.utm_campaignid, "120200000000001"); assert.equal(p.first_touch.at, "2026-11-16T09:00:00Z");
  assert.deepEqual(p.consent, { notice_version: "meta_instant_form", ad_data_sharing: true });
  assert.deepEqual(p.meta_answers, { city: "Delhi" });
});
test("ML02 consent: yes / no answers, an optional consent checkbox, and a form that did not ask", () => {
  const withAns = (a: string) => ({ field_data: [{ name: "consent_q", values: [a] }] });
  assert.equal(consentAnswer(withAns("Yes"), "consent_q"), true);
  assert.equal(consentAnswer(withAns("no"), "consent_q"), false);
  assert.equal(consentAnswer(withAns("maybe later"), "consent_q"), undefined);
  assert.equal(consentAnswer({ custom_disclaimer_responses: [{ checkbox_key: "share_ok", is_checked: "1" }] }, "share_ok"), true);
  assert.equal(consentAnswer({ custom_disclaimer_responses: [{ checkbox_key: "share_ok", is_checked: "" }] }, "share_ok"), false);
  assert.equal(consentAnswer(LEAD, "not_on_form"), undefined);
  assert.equal(consentAnswer(LEAD, null), undefined);
  const p = metaLeadPayload({ ...LEAD, field_data: [{ name: "first_name", values: ["Ravi"] }, { name: "last_name", values: ["K"] }] }, { consentField: "x", consentPurpose: "marketing" }) as any;
  assert.equal(p.name, "Ravi K");
  assert.deepEqual(p.consent, { notice_version: "meta_instant_form" });            // not asked: no answer recorded
  const q = metaLeadPayload(LEAD, { consentField: "ad_data_sharing", consentPurpose: "marketing" }) as any;
  assert.deepEqual(q.consent, { notice_version: "meta_instant_form", marketing: true });
});
test("ML03 a WhatsApp ad chat becomes an ADS intake payload marked as ctwa", () => {
  const p = ctwaPayload({ external_id: "ARAkLkA8rmlFeiCktEJQ", ad_id: "777", created_time: "1794800000",
    payload: { name: "Asha", phone: "919811200001", waba_id: "123456789012" } }) as any;
  assert.equal(p.phone, "919811200001"); assert.equal(p.submission_id, "meta-ctwa-ARAkLkA8rmlFeiCktEJQ");
  assert.equal(p.first_touch.meta_source, "ctwa"); assert.equal(p.first_touch.ctwa_clid, "ARAkLkA8rmlFeiCktEJQ");
  assert.equal(p.first_touch.waba_id, "123456789012"); assert.equal(p.utm_medium, "paid_social");
});

// ---------------------------------------------------------------- Conversions API events
const EM = sha("asha@example.com"), PH = sha("919811200001");
const base: CapiItem = { id: 1, source: "instant_form", event_name: "qualified", event_id: "x:qualified", event_time: NOW - 3600, em: EM, ph: PH };
test("MC01 CRM event (Conversion Leads): system_generated, event_source crm, lead_event_source = the CRM name, lead_id, hashes", () => {
  const e = crmEvent({ ...base, lead_id: "1234567890123456" }, "We One CRM", NOW) as any;
  assert.equal(e.action_source, "system_generated");
  assert.deepEqual(e.custom_data, { event_source: "crm", lead_event_source: "We One CRM" });
  assert.equal(e.event_name, "qualified"); assert.equal(e.event_time, NOW - 3600);
  assert.deepEqual(e.user_data, { lead_id: "1234567890123456", em: [EM], ph: [PH] });
});
test("MC02 a 17-digit lead id reaches Meta as an exact JSON number (no rounding)", () => {
  const s = serializeEvents([crmEvent({ ...base, lead_id: "12345678901234567" }, "We One CRM", NOW)]);
  assert.match(s, /"lead_id":12345678901234567[,}]/);
  assert.ok(!s.includes('"lead_id":"'));
  assert.equal(Number.isSafeInteger(12345678901234567), false);               // why it is not left to JSON.stringify
});
test("MC03 CRM event refused: no lead id, event older than 7 days, time in ms, future time, odd name", () => {
  assert.throws(() => crmEvent(base, "We One CRM", NOW), EventError);
  assert.throws(() => crmEvent({ ...base, lead_id: "123456789012345", event_time: NOW - 8 * 86400 }, "x", NOW), /7 days/);
  assert.throws(() => crmEvent({ ...base, lead_id: "123456789012345", event_time: NOW * 1000 }, "x", NOW), /future/);
  assert.throws(() => crmEvent({ ...base, lead_id: "123456789012345", event_time: NOW + 3600 }, "x", NOW), /future/);
  assert.throws(() => crmEvent({ ...base, lead_id: "123456789012345", event_name: "<script>" }, "x", NOW), /name/);
});
test("MC04 values that are not SHA-256 hex are never sent as hashes", () => {
  const e = crmEvent({ ...base, lead_id: "123456789012345", em: "asha@example.com", ph: "9811200001" }, "x", NOW) as any;
  assert.deepEqual(e.user_data, { lead_id: "123456789012345" });
});
test("MC05 website event: fbc unhashed, page address, browser, event_id; refused without them or with a non-lead event", () => {
  const w: CapiItem = { ...base, source: "website", event_name: "Lead", fbc: "fb.1.1794790000000.IwAR2F4-dbP0l7Mn1", event_source_url: "https://weoneaviation.in/cpl",
    client_user_agent: "Mozilla/5.0" };
  const e = webEvent(w, NOW) as any;
  assert.equal(e.action_source, "website"); assert.equal(e.event_id, "x:qualified"); assert.equal(e.event_source_url, "https://weoneaviation.in/cpl");
  assert.deepEqual(e.user_data, { fbc: "fb.1.1794790000000.IwAR2F4-dbP0l7Mn1", client_user_agent: "Mozilla/5.0", em: [EM], ph: [PH] });
  assert.throws(() => webEvent({ ...w, client_user_agent: null }, NOW), /browser/);
  assert.throws(() => webEvent({ ...w, event_source_url: null }, NOW), /page/);
  assert.throws(() => webEvent({ ...w, fbc: "IwAR2F4" }, NOW), /click id/);
  assert.throws(() => webEvent({ ...w, event_name: "Purchase" }, NOW), /Website event/);
});
test("MC06 WhatsApp event: business_messaging, whatsapp, WABA + ctwa_clid; only LeadSubmitted / QualifiedLead", () => {
  const c: CapiItem = { ...base, source: "ctwa", event_name: "LeadSubmitted", ctwa_clid: "ARAkLkA8rmlFeiCktEJQ", waba_id: "123456789012" };
  const e = messagingEvent(c, NOW) as any;
  assert.equal(e.action_source, "business_messaging"); assert.equal(e.messaging_channel, "whatsapp");
  assert.deepEqual(e.user_data, { whatsapp_business_account_id: "123456789012", ctwa_clid: "ARAkLkA8rmlFeiCktEJQ" });
  assert.throws(() => messagingEvent({ ...c, event_name: "Lead" }, NOW), /WhatsApp event/);
  assert.throws(() => messagingEvent({ ...c, event_name: "Purchase" }, NOW), /WhatsApp event/);
  assert.throws(() => messagingEvent({ ...c, waba_id: null }, NOW), /Business Account/);
  assert.throws(() => messagingEvent({ ...c, ctwa_clid: null }, NOW), /ctwa_clid/);
});
test("MC07 buildEvent picks the right builder per source", () => {
  assert.equal((buildEvent({ ...base, lead_id: "123456789012345" }, "n", NOW) as any).action_source, "system_generated");
  assert.equal((buildEvent({ ...base, source: "ctwa", event_name: "QualifiedLead", ctwa_clid: "ARAkLkA8rmlFeiCktEJQ", waba_id: "123456789012" }, "n", NOW) as any).action_source, "business_messaging");
});
test("MC08 SHA-256 here matches the database's crm_private.ads_sha256 for the same value (100_ads_meta_tests.sql MS14)", () => {
  assert.equal(sha("919811200001"), "f77667a8777bcb65d8ffb30434830d854552d739e2b840b28fa78d7a6c428a02");
});

// ---------------------------------------------------------------- Meta Graph calls (fake network)
type Call = { url: string; init?: RequestInit };
function fake(routes: Array<[RegExp, (c: Call) => { status?: number; body: unknown }]>) {
  const calls: Call[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    const c = { url, init }; calls.push(c);
    for (const [re, h] of routes) if (re.test(url + " " + String(init?.body ?? ""))) {
      const r = h(c); return new Response(JSON.stringify(r.body), { status: r.status ?? 200 });
    }
    return new Response(JSON.stringify({ error: { message: "no route" } }), { status: 404 });
  };
  return { fn, calls };
}
const META = { accessToken: "EAAsystemusertoken123", appSecret: "appsecret123", version: "v26.0", hmac };

test("MG01 sendEvents posts the events to /{dataset}/events with appsecret_proof and returns events_received", async () => {
  const f = fake([[/\/v26\.0\/1122334455\/events/, () => ({ body: { events_received: 2, fbtrace_id: "Ab" } })]]);
  const m = new MetaAds(META, f.fn);
  const data = serializeEvents([crmEvent({ ...base, lead_id: "123456789012345" }, "n", NOW)]);
  const r = await m.sendEvents("1122334455", data);
  assert.equal(r.events_received, 2);
  const body = new URLSearchParams(String(f.calls[0].init?.body));
  assert.equal(f.calls[0].init?.method, "POST");
  assert.equal(body.get("data"), data);
  assert.equal(body.get("appsecret_proof"), await hmac("appsecret123", "EAAsystemusertoken123"));
});
test("MG02 a refused batch is an error the caller can see (http 400 = not accepted, not a network problem)", async () => {
  const f = fake([[/events/, () => ({ status: 400, body: { error: { code: 100, message: "Invalid parameter" } } })]]);
  await assert.rejects(new MetaAds(META, f.fn).sendEvents("1122334455", "[]"), (e: any) => e instanceof AdsError && e.http === 400 && e.status === "sync_failed");
  const g = fake([[/events/, () => ({ status: 400, body: { error: { code: 17, message: "User request limit reached" } } })]]);
  await assert.rejects(new MetaAds(META, g.fn).sendEvents("1122334455", "[]"), (e: any) => e.status === "rate_limited");
});
test("MG03 the Page token is read with the System User token, then used (with its own appsecret_proof) for leads", async () => {
  const f = fake([[/\/111222333444\?fields=access_token/, () => ({ body: { access_token: "EAApagetoken999", id: "111222333444" } })],
    [/\/1234567890123456\?/, () => ({ body: LEAD })]]);
  const sys = new MetaAds(META, f.fn);
  const page = sys.withToken(await sys.pageToken("111222333444"));
  const lead = await page.getLead("1234567890123456");
  assert.equal(lead.id, "1234567890123456");
  const u = new URL(f.calls[1].url);
  assert.match(u.searchParams.get("fields") ?? "", /field_data/);
  assert.match(u.searchParams.get("fields") ?? "", /custom_disclaimer_responses/);
  assert.equal(f.calls[1].init?.headers && (f.calls[1].init.headers as any).Authorization, "Bearer EAApagetoken999");
  assert.equal(u.searchParams.get("appsecret_proof"), await hmac("appsecret123", "EAApagetoken999"));
});
test("MG04 no Page token returned: a plain permission message", async () => {
  const f = fake([[/access_token/, () => ({ body: { id: "1" } })]]);
  await assert.rejects(new MetaAds(META, f.fn).pageToken("111222333444"), /System User access to the Page/);
});
test("MG05 form leads are filtered by time_created on Meta's side and paged", async () => {
  const f = fake([[/after=x/, () => ({ body: { data: [{ id: "100002" }] } })],
    [/\/987654321\/leads\?/, () => ({ body: { data: [{ id: "100001" }], paging: { next: "https://graph.facebook.com/v26.0/987654321/leads?after=x" } } })]]);
  const rows = await new MetaAds(META, f.fn).formLeads("987654321", 1794700000);
  assert.deepEqual(rows.map((r) => r.id), ["100001", "100002"]);
  const flt = JSON.parse(new URL(f.calls[0].url).searchParams.get("filtering") ?? "[]");
  assert.deepEqual(flt, [{ field: "time_created", operator: "GREATER_THAN", value: 1794700000 }]);
});
test("MG06 lead forms and the leadgen subscription of the Page", async () => {
  const f = fake([[/leadgen_forms/, () => ({ body: { data: [{ id: "987654321", name: "CPL enquiry", status: "ACTIVE" }] } })],
    [/subscribed_apps\?/, () => ({ body: { data: [{ id: "55", subscribed_fields: ["leadgen", "feed"] }] } })],
    [/subscribed_apps subscribed_fields=leadgen/, () => ({ body: { success: true } })]]);
  const m = new MetaAds(META, f.fn);
  assert.deepEqual(await m.leadgenForms("111222333444"), [{ id: "987654321", name: "CPL enquiry", status: "ACTIVE" }]);
  assert.deepEqual(await m.subscribedApps("111222333444"), [{ id: "55", subscribed_fields: ["leadgen", "feed"] }]);
  await m.subscribeLeadgen("111222333444");
  assert.equal(f.calls[2].init?.method, "POST");
});

test("deployState tells a deployed, old and missing Edge Function apart (Setup > Check now)", () => {
  assert.equal(deployState(200, JSON.stringify({ build: ADS_BUILD }), ADS_BUILD), "current");
  assert.equal(deployState(404, JSON.stringify({ detail: "Not found" }), ADS_BUILD), "old");           // our function, older build without /version
  assert.equal(deployState(404, '{"code":"NOT_FOUND","message":"Requested function was not found"}', ADS_BUILD), "missing");
  assert.equal(deployState(404, '{"code":"NOT_FOUND","message":"Requested function was not found"}'), "missing");
  assert.equal(deployState(403, "Forbidden"), "current");                                              // webhook without the verify word: it is there
  assert.equal(deployState(502, "bad gateway", ADS_BUILD), "unknown");
  assert.equal(deployState(503, "x"), "unknown");
});

test("ads-intake /version answers the same build as ADS_BUILD (else Setup would say 'old version')", async () => {
  const src = await Deno.readTextFile(new URL("../../functions/ads-intake/index.ts", import.meta.url));
  assert.ok(src.includes(`build: "${ADS_BUILD}"`));
});

test("isTestLead: Meta's Lead Ads Testing Tool leads are recognised; real answers are not", () => {
  const t = { field_data: [{ name: "full_name", values: ["<test lead: dummy data for full_name>"] }, { name: "phone_number", values: ["<test lead: dummy data for phone_number>"] }] };
  assert.equal(isTestLead(t), true);
  assert.equal(isTestLead({ field_data: [{ name: "email", values: ["test@fb.com"] }, { name: "first_name", values: ["test lead: dummy data for first_name"] }] }), true);
  assert.equal(isTestLead({ field_data: [{ name: "full_name", values: ["Ravi Test"] }, { name: "phone_number", values: ["+919811300001"] }] }), false);
  assert.equal(isTestLead({}), false);
});

test("organicPayload: a form fill without an ad becomes a normal lead labelled Meta lead form / organic", () => {
  const p = organicPayload({ id: "1", field_data: [{ name: "full_name", values: ["Asha K"] }, { name: "phone_number", values: ["+919811300009"] },
    { name: "email", values: ["a@x.in"] }, { name: "course_interest", values: ["CPL"] }, { name: "city", values: ["Delhi"] }] });
  assert.deepEqual(p, { name: "Asha K", phone: "+919811300009", email: "a@x.in", course_interest: "CPL", utm_source: "Meta lead form",
    utm_medium: "organic", meta_answers: { city: "Delhi" } });
  assert.equal("first_touch" in p || "submission_id" in p, false);    // not an Ads lead: no click data
});

test("the Setup screen expects the same build as the Edge Functions", async () => {
  const src = await Deno.readTextFile(new URL("../../../frontend/src/components/AdsSetup.jsx", import.meta.url));
  assert.ok(src.includes(`const BUILD = '${ADS_BUILD}'`));
});
