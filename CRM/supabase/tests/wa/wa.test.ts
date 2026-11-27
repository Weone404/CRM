// Unit tests for supabase/functions/_shared/wa.ts (migration 150): the flow engine, webhook parsing, Meta payloads,
// error rules and signature checks. No network: Meta is a fake fetch that records every request.
// Run: node --experimental-strip-types --test supabase/tests/wa/wa.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import {
  buildMessage, classify, decide, describe, fill, graph, norm, parseWebhook, pushesFor, renderStep, ruleMatches, sendMessage,
  templatePayload, verifySignature, type Ctx, type Inbound, type Rule, type Step,
} from "../../functions/_shared/wa.ts";

// The starter Aviation flow and rules, as migration 150 seeds them.
const STEPS: Step[] = [
  { key: "welcome", kind: "buttons", is_start: true, body: "Hi {{name}}, welcome to We One Aviation! Student or parent?",
    buttons: [{ id: "student", title: "I'm a student", goto: "pcm" }, { id: "parent", title: "I'm a parent", goto: "pcm" }, { id: "counsellor", title: "Talk to counsellor", action: "handoff" }] },
  { key: "pcm", kind: "buttons", body: "Physics and Maths in 12th?",
    buttons: [{ id: "pcm_yes", title: "Yes", goto: "city" }, { id: "pcm_no", title: "No", goto: "nios" }, { id: "pcm_unsure", title: "Not sure", goto: "city" }] },
  { key: "nios", kind: "text", body: "NIOS route.", auto_next: "city" },
  { key: "city", kind: "text", body: "Which city are you in?", capture: "city", next_key: "brochure" },
  { key: "brochure", kind: "document", body: "Here is our brochure.", auto_next: "counselling" },
  { key: "counselling", kind: "buttons", body: "Free counselling?",
    buttons: [{ id: "book", title: "Book free counselling", action: "book_counselling" }, { id: "later", title: "Call me later", action: "handoff" }, { id: "browse", title: "Just browsing", goto: "end" }] },
  { key: "booked", kind: "text", body: "Great! Call us on {{counsellor_phone}}.", handoff: true },
  { key: "end", kind: "text", body: "No problem, {{name}}." },
];
const RULES: Rule[] = [
  { step_key: null, match_type: "exact", patterns: ["stop", "unsubscribe", "stop messages", "band karo"], priority: 100, action: "optout", reply_text: "Done. Reply START any time." },
  { step_key: null, match_type: "exact", patterns: ["start", "hi", "hello", "menu"], priority: 50, action: "restart" },
  { step_key: null, match_type: "contains", patterns: ["counsellor", "call me", "baat"], priority: 40, action: "handoff", reply_text: "Sure, call {{counsellor_phone}}." },
  { step_key: null, match_type: "contains", patterns: ["fee", "fees", "kitna", "how much"], priority: 30, action: "handoff", reply_text: "Our counsellor will share details." },
  { step_key: null, match_type: "contains", patterns: ["brochure", "pdf"], priority: 20, action: "send_brochure" },
  { step_key: null, match_type: "exact", patterns: ["not interested", "just browsing"], priority: 15, action: "end" },
  { step_key: "welcome", match_type: "synonym", patterns: ["student", "parent", "father", "papa"], priority: 10, action: "goto", goto_key: "pcm" },
  { step_key: "pcm", match_type: "synonym", patterns: ["yes", "haan"], priority: 10, action: "goto", goto_key: "city" },
  { step_key: "pcm", match_type: "synonym", patterns: ["no", "nahi", "commerce"], priority: 10, action: "goto", goto_key: "nios" },
];
const ctx = (conv: Record<string, unknown> = {}, extra: Partial<Ctx> = {}): Ctx => ({
  conversation: { status: "bot", current_step: "welcome", miss_count: 0, ...conv }, contact: { opted_out: false },
  steps: STEPS, rules: RULES, vars: { name: "Riya", counsellor_phone: "9355566991", brand: "We One Aviation" },
  brochure: { url: "https://weoneaviation.in/brochure.pdf", name: "We One Aviation brochure.pdf" }, bot_on: true, ...extra,
});
const msg = (text: string, extra: Partial<Inbound> = {}): Inbound => ({ wamid: "w1", from: "919822222222", kind: "text", text, ...extra });
const tap = (title: string, id = ""): Inbound => ({ wamid: "w2", from: "919822222222", kind: "button", button_title: title, button_id: id });

test("E01 template button tap moves to the next step", () => {
  const d = decide(ctx(), tap("I'm a student"));
  assert.equal(d.patch.current_step, "pcm");
  assert.equal(d.out[0].type, "buttons");
});
test("E02 interactive reply matched by id", () => {
  const d = decide(ctx({ current_step: "pcm" }), { wamid: "w", from: "1", kind: "interactive", button_title: "No", button_id: "pcm_no" });
  assert.deepEqual(d.out.map((o) => o.type), ["text", "text"]);        // NIOS info, then "Which city" (auto_next)
  assert.equal(d.patch.current_step, "city");
});
test("E03 typed button title counts as the tap", () => {
  assert.equal(decide(ctx(), msg("i'm a parent")).patch.current_step, "pcm");
});
test("E04 Hinglish synonym on the current step", () => {
  assert.equal(decide(ctx({ current_step: "pcm" }), msg("haan")).patch.current_step, "city");
  assert.equal(decide(ctx({ current_step: "welcome" }), msg("main papa hoon")).patch.current_step, "pcm");
});
test("E05 small typo still matches a synonym", () => {
  assert.equal(decide(ctx({ current_step: "welcome" }), msg("studnt")).patch.current_step, "pcm");
});
test("E06 STOP always wins and opts out", () => {
  const d = decide(ctx({ current_step: "pcm" }), msg("STOP"));
  assert.equal(d.patch.opted_out, true);
  assert.match((d.out[0] as { body: string }).body, /START/);
});
test("E07 opted-out person: silence, START brings them back", () => {
  const off = ctx({}, { contact: { opted_out: true } });
  assert.equal(decide(off, msg("hello?")).out.length, 0);
  const d = decide(off, msg("start"));
  assert.equal(d.patch.opted_in, true);
  assert.equal(d.patch.current_step, "welcome");
});
test("E08 rule priority: button > exact > contains > synonym, step before global", () => {
  // "yes" at pcm: step synonym; "hello" anywhere: global exact restart beats nothing
  assert.equal(decide(ctx({ current_step: "pcm" }), msg("yes")).patch.current_step, "city");
  assert.equal(decide(ctx({ current_step: "pcm" }), msg("hello")).patch.current_step, "welcome");
  // contains (fees) beats a step synonym
  const d = decide(ctx({ current_step: "pcm" }), msg("yes but what is the fees"));
  assert.equal(d.patch.status, "human");
  assert.equal(d.matched?.startsWith("rule:"), true);
});
test("E09 fees question: hand-off, never a number", () => {
  const d = decide(ctx(), msg("kitna fees hai?"));
  assert.equal(d.patch.status, "human");
  assert.ok(!/₹|\d{4,}/.test((d.out[0] as { body: string }).body.replace("9355566991", "")));
  assert.equal(d.events[0].kind, "handoff");
  assert.equal(d.events[0].notify, true);
});
test("E10 city question keeps any answer and moves on (brochure, then counselling)", () => {
  const d = decide(ctx({ current_step: "city" }), msg("Chandigarh"));
  assert.deepEqual(d.patch.answers, { city: "Chandigarh" });
  assert.deepEqual(d.out.map((o) => o.type), ["document", "buttons"]);
  assert.equal(d.patch.current_step, "counselling");
});
test("E11 book counselling: booked message, a person takes over, team alerted", () => {
  const d = decide(ctx({ current_step: "counselling" }), tap("Book free counselling", "book"));
  assert.equal(d.patch.status, "human");
  assert.ok(d.events.some((e) => e.kind === "counselling_requested" && e.notify));
  assert.ok(!d.events.some((e) => e.kind === "handoff"));        // one alert, not two
  assert.match((d.out[0] as { body: string }).body, /9355566991/);
});
test("E12 first miss shows the options again, second miss goes to a person", () => {
  const d1 = decide(ctx({ current_step: "pcm", miss_count: 0 }), msg("what about the medical"));
  assert.equal(d1.patch.miss_count, 1);
  assert.deepEqual(d1.out.map((o) => o.type), ["text", "buttons"]);
  const d2 = decide(ctx({ current_step: "pcm", miss_count: 1 }), msg("what about the medical"));
  assert.equal(d2.patch.status, "human");
  assert.equal(d2.events[0].kind, "handoff");
});
test("E13 question after the flow ended goes straight to a person", () => {
  const d = decide(ctx({ current_step: "end" }), msg("Do you have hostel?"));
  assert.equal(d.patch.status, "human");
});
test("E14 a person has taken over: the bot stays quiet and alerts them", () => {
  const d = decide(ctx({ status: "human" }), msg("hello?"));
  assert.equal(d.out.length, 0);
  assert.equal(d.events[0].kind, "inbound_for_person");
});
test("E15 bot off (test mode, not a test number): nothing", () => {
  const d = decide(ctx({}, { bot_on: false }), msg("hi"));
  assert.equal(d.out.length + d.events.length, 0);
});
test("E16 someone who wrote first gets the first step; a global rule still wins", () => {
  assert.equal(decide(ctx({ current_step: null }), msg("hi there")).patch.current_step, "welcome");
  assert.equal(decide(ctx({ current_step: null }), msg("fees kitna hai")).patch.status, "human");
});
test("E17 reactions and unsupported messages are not answered", () => {
  assert.equal(decide(ctx(), { wamid: "r", from: "1", kind: "reaction" }).out.length, 0);
});
test("E18 brochure without a link: text, and a heads-up", () => {
  const d = decide(ctx({ current_step: "city" }, { brochure: { url: null } }), msg("Delhi"));
  assert.equal(d.out[0].type, "text");
  assert.ok(d.events.some((e) => e.kind === "brochure_missing"));
});
test("E19 a goto to a deleted step hands over instead of failing", () => {
  const rules: Rule[] = [{ match_type: "contains", patterns: ["hostel"], action: "goto", goto_key: "gone" }];
  const d = decide(ctx({}, { rules }), msg("hostel?"));
  assert.equal(d.patch.status, "human");
});
test("E20 variables filled, text normalised", () => {
  assert.equal(fill("Hi {{name}}, call {{ counsellor_phone }}", { name: "Riya", counsellor_phone: "1" }), "Hi Riya, call 1");
  assert.equal(norm("  I’m a STUDENT!! "), "im a student");
  assert.equal(norm("हाँ जी"), "हाँ जी");
  assert.equal(ruleMatches({ match_type: "contains", patterns: ["fee"], action: "handoff" }, "coffee please", ""), false);
});

test("P01 webhook parsing: text, template button, interactive, media, status with error", () => {
  const body = { entry: [{ changes: [{ field: "messages", value: {
    metadata: { phone_number_id: "123" }, contacts: [{ wa_id: "919822222222", profile: { name: "Riya" } }],
    messages: [
      { id: "m1", from: "919822222222", timestamp: "1795000000", type: "text", text: { body: "hi" } },
      { id: "m2", from: "919822222222", type: "button", button: { text: "I'm a student", payload: "I'm a student" } },
      { id: "m3", from: "919822222222", type: "interactive", interactive: { type: "button_reply", button_reply: { id: "pcm_yes", title: "Yes" } } },
      { id: "m4", from: "919822222222", type: "image", image: { id: "media1", mime_type: "image/jpeg", caption: "marksheet" } },
      { id: "m5", from: "919822222222", type: "text", text: { body: "from ad" }, referral: { source_id: "ad1", ctwa_clid: "c1", headline: "CPL" } },
    ],
    statuses: [{ id: "s1", status: "failed", errors: [{ code: 131026, title: "Undeliverable", error_data: { details: "Message undeliverable" } }] }],
  } }] }] };
  const p = parseWebhook(body);
  assert.equal(p.messages.length, 5);
  assert.equal(p.messages[0].profile_name, "Riya");
  assert.equal(p.messages[1].button_title, "I'm a student");
  assert.equal(p.messages[2].button_id, "pcm_yes");
  assert.equal(p.messages[3].media?.id, "media1");
  assert.equal(p.messages[3].caption, "marksheet");
  assert.equal(p.messages[4].referral?.ctwa_clid, "c1");
  assert.deepEqual(p.statuses[0], { wamid: "s1", status: "failed", error_code: 131026, error_text: "Message undeliverable", category: undefined });
  assert.deepEqual(parseWebhook({ entry: [{ changes: [{ field: "account_update", value: {} }] }] }), { messages: [], statuses: [] });
  assert.deepEqual(parseWebhook("junk"), { messages: [], statuses: [] });
});

test("S01 signature check: right secret passes, anything else fails", async () => {
  const hmac = async (k: string, m: string) => createHmac("sha256", k).update(m).digest("hex");
  const raw = JSON.stringify({ entry: [] });
  const sig = `sha256=${await hmac("app-secret", raw)}`;
  assert.equal(await verifySignature("app-secret", raw, sig, hmac), true);
  assert.equal(await verifySignature("other", raw, sig, hmac), false);
  assert.equal(await verifySignature("app-secret", raw + " ", sig, hmac), false);
  assert.equal(await verifySignature("app-secret", raw, null, hmac), false);
  assert.equal(await verifySignature(null, raw, sig, hmac), false);
});

test("M01 Meta payloads: text, buttons (max 3, 20 chars), list, document, template with {{1}}", () => {
  const t = buildMessage("919822222222", { type: "text", body: "hi" });
  assert.equal(t.text.body, "hi");
  const b = buildMessage("9", { type: "buttons", body: "x", buttons: [1, 2, 3, 4].map((i) => ({ id: `b${i}`, title: "A very long button title here" })) });
  assert.equal(b.interactive.action.buttons.length, 3);
  assert.equal(b.interactive.action.buttons[0].reply.title.length, 20);
  const l = buildMessage("9", { type: "list", body: "x", button: "Choose", rows: [{ id: "r", title: "Row" }] });
  assert.equal(l.interactive.type, "list");
  const doc = buildMessage("9", { type: "document", link: "https://x/b.pdf", filename: "b.pdf", caption: "c" });
  assert.equal(doc.document.link, "https://x/b.pdf");
  const tp = buildMessage("9", { type: "template", purpose: "aviation" }, { name: "weone_welcome", language: "en", body: "Hi {{1}}" }, { name: "Riya" });
  assert.deepEqual(tp.template, { name: "weone_welcome", language: { code: "en" }, components: [{ type: "body", parameters: [{ type: "text", text: "Riya" }] }] });
  assert.throws(() => buildMessage("9", { type: "template", purpose: "x" }, null));
  assert.equal(describe({ type: "template" }, { name: "t", body: "Hi {{1}}" }, { name: "Riya" }).body, "Hi Riya");
});

test("M02 rendering a step for WhatsApp", () => {
  const [o] = renderStep(STEPS[0], { name: "Riya" });
  assert.equal(o.type, "buttons");
  assert.match((o as { body: string }).body, /Hi Riya/);
});

test("M03 template for Meta: example for {{1}}, quick replies", () => {
  const p = templatePayload({ name: "weone_welcome", body: "Hi {{1}}", footer: "We One", buttons: ["I'm a student", "I'm a parent"] });
  assert.deepEqual(p.components[0], { type: "BODY", text: "Hi {{1}}", example: { body_text: [["Rahul"]] } });
  assert.equal(p.components[2].buttons[1].type, "QUICK_REPLY");
  assert.equal(p.category, "UTILITY");
});

test("R01 error rules: what is retried", () => {
  assert.equal(classify(400, 131049).retry, false);     // marketing limit: not before 24 h
  assert.equal(classify(400, 131026).retry, false);     // undeliverable
  assert.equal(classify(400, 131047).retry, false);     // window closed
  assert.equal(classify(400, 132001).retry, false);     // template problem
  assert.equal(classify(401, 190).retry, false);        // token
  assert.equal(classify(429, 130429).retry, true);      // rate limit
  assert.equal(classify(400, 131056).retry, true);      // pair rate limit
  assert.equal(classify(503).retry, true);
  assert.equal(classify(0).retry, true);                // network
});

test("R02 send: ok returns the id; errors are classified; token never echoed", async () => {
  const calls: { url: string; body?: string }[] = [];
  const ok = async (url: string, init: { body?: string }) => { calls.push({ url, body: init.body }); return { status: 200, text: async () => '{"messages":[{"id":"wamid.X"}]}' }; };
  const r = await sendMessage(ok, "v26.0", "TOKEN", "123", { to: "9" });
  assert.deepEqual(r, { ok: true, wamid: "wamid.X", retry: false });
  assert.equal(calls[0].url, "https://graph.facebook.com/v26.0/123/messages");
  const bad = async () => ({ status: 400, text: async () => '{"error":{"code":131026,"message":"Undeliverable","error_data":{"details":"Message undeliverable"}}}' });
  const r2 = await sendMessage(bad, "v26.0", "TOKEN", "123", {});
  assert.deepEqual(r2, { ok: false, code: 131026, text: "Message undeliverable", retry: false });
  const down = async () => { throw new Error("connect ECONNREFUSED"); };
  assert.equal((await sendMessage(down, "v26.0", "T", "1", {})).retry, true);
  const leak = async () => ({ status: 400, text: async () => '{"error":{"code":100,"message":"bad url ?access_token=SECRET123&x=1"}}' });
  assert.ok(!(await graph(leak, "v26.0", "T", "x")).message!.includes("SECRET123"));
});

test("N01 phone alerts: one per event, grouped when many", () => {
  const one = pushesFor([{ id: 1, kind: "counselling_requested", conversation_id: "c1", name: "Riya" }]);
  assert.equal(one[0].url, "/#/whatsapp/inbox?c=c1");
  assert.match(one[0].title, /Riya asked for free counselling/);
  assert.equal(pushesFor([1, 2, 3, 4, 5].map((i) => ({ id: i, kind: "handoff", name: `P${i}` }))).length, 1);
});
