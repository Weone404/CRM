// deno test supabase/functions/ig-dm/ig_dm_test.ts   (no network, no database: fake Instagram + in-memory store)
import { assert, assertEquals } from "jsr:@std/assert@1";
import { classify, httpIG, IGError, phoneOf, refreshToken, render, tick, type IG, type Json, type Store } from "../_shared/ig_dm.ts";

const NOW = Date.parse("2026-11-24T10:00:00Z");
const ago = (min: number) => new Date(NOW - min * 60000).toISOString().replace(/\.\d{3}Z$/, "+0000");
const UID = "17841450423717846", OWN = "we_one_aviation";

type Fake = { ig: IG; calls: string[]; dms: Json[]; replies: Json[] };
function fakeIG(o: { media?: Json[]; comments?: Record<string, Json[]>; replies?: Record<string, Json[]>; convs?: Json[]; msgs?: Record<string, Json[]>;
                    fail?: (path: string, method: string) => IGError | null } = {}): Fake {
  const calls: string[] = [], dms: Json[] = [], replies: Json[] = [];
  const ig: IG = {
    async get(path, q = {}) {
      calls.push(`GET ${path}`);
      const f = o.fail?.(path, "GET"); if (f) throw f;
      if (path === "me") return { user_id: UID, username: OWN };
      if (path === `${UID}/media`) return { data: (o.media ?? []).slice(0, Number(q.limit ?? 12)) };
      const cm = /^(.+)\/comments$/.exec(path); if (cm) return { data: o.comments?.[cm[1]] ?? [] };
      const rp = /^(.+)\/replies$/.exec(path); if (rp) return { data: o.replies?.[rp[1]] ?? [] };
      if (path === "me/conversations") return { data: o.convs ?? [] };
      if (o.msgs?.[path]) return { messages: { data: o.msgs[path].map((m) => ({ id: m.id })) } };
      for (const list of Object.values(o.msgs ?? {})) { const m = list.find((x) => x.id === path); if (m) return m; }
      return {};
    },
    async post(path, q = {}, body) {
      calls.push(`POST ${path}`);
      const f = o.fail?.(path, "POST"); if (f) throw f;
      if (path === `${UID}/messages`) { dms.push(body!); return { recipient_id: body?.recipient?.id ?? `sid_${body?.recipient?.comment_id}` }; }
      const rp = /^(.+)\/replies$/.exec(path); if (rp) { replies.push({ comment: rp[1], message: q.message }); return { id: `r_${rp[1]}` }; }
      return {};
    },
  };
  return { ig, calls, dms, replies };
}

function memStore() {
  const log = new Map<string, Json>(), people = new Map<string, Json>(), sends: string[] = [], leads: Json[] = []; let cfg: Json = {};
  const st: Store = {
    async known(ids) { return new Set(ids.filter((i) => log.has(i))); },
    async claim(row) { if (log.has(row.comment_id)) return false; log.set(row.comment_id, { ...row }); return true; },
    async finish(id, patch) { log.set(id, { ...log.get(id), ...patch }); },
    async release(id) { if (log.get(id)?.state === "sending") log.delete(id); },
    async person(id, username) {
      if (id && people.has(String(id))) return people.get(String(id))!;
      if (username) for (const p of people.values()) if (String(p.username ?? "").toLowerCase() === String(username).toLowerCase()) return p;
      return null;
    },
    async savePerson(row) { const k = row.person; people.set(k, { ...people.get(k), ...row, username: row.username ? String(row.username).toLowerCase() : row.username }); },
    async sent(kind) { sends.push(kind); },
    async lead(p) { leads.push(p); return { status: "created", lead_id: "11111111-1111-1111-1111-111111111111" }; },
    async cfg(p) { cfg = { ...cfg, ...p }; },
  };
  return { st, log, people, sends, leads, get cfg() { return cfg; } };
}
const CFG = { on: true, mode: "universal", message: "Hi {name}! Free career counselling: send your number.", thanks: "Thanks {name}!", public_reply: true, cap: 60,
              inbox: true, crm: true, state: "ready", user_id: UID, username: OWN };
const work = (cfg: Json = {}, extra: Json = {}) => ({ cfg: { ...CFG, ...cfg }, token: "tok_SECRET_123", token_at: "2026-11-24T09:00:00Z", sent_last_hour: 0, ...extra });
const media = [{ id: "m1", timestamp: ago(600) }, { id: "m_old", timestamp: ago(8 * 1440) }];
const c = (id: string, user: string, text: string, min = 30, fromId = `id_${user}`) => ({ id, text, timestamp: ago(min), username: user, from: { id: fromId, username: user } });

Deno.test("a new comment gets one private reply + a public reply; a second run sends nothing more", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c1", "riya", "pilot kaise bane?")] } }); const m = memStore();
  const r = await tick(work(), f.ig, m.st, NOW);
  assertEquals(r.sent, 1); assertEquals(f.dms.length, 1);
  assertEquals(f.dms[0].recipient, { comment_id: "c1" }); assertEquals(f.dms[0].message.text, "Hi @riya! Free career counselling: send your number.");
  assertEquals(f.replies.map((x) => x.comment), ["c1"]); assertEquals(m.log.get("c1")!.state, "sent");
  assert(m.people.get("sid_c1")?.dm_at, "the person is remembered");
  const again = await tick(work(), f.ig, m.st, NOW + 120e3);
  assertEquals(again.sent, 0); assertEquals(f.dms.length, 1, "never twice"); assertEquals(f.replies.length, 1);
});

Deno.test("one DM per person: a second comment by the same person gets only the public reply", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c1", "aman", "info?", 40), c("c2", "aman", "please reply", 20)] } }); const m = memStore();
  await tick(work(), f.ig, m.st, NOW);
  assertEquals(f.dms.length, 1); assertEquals(f.replies.map((x) => x.comment), ["c1", "c2"]);
  assertEquals(m.log.get("c2")!.state, "public");
});

Deno.test("spam and angry comments get nothing; own comments and comments older than 7 days are ignored", async () => {
  const f = fakeIG({ media, comments: {
    m1: [c("s1", "x", "follow www.promo.xyz for followers"), c("n1", "y", "scam hai ye"), c("o1", OWN, "Thanks!", 10, UID)],
    m_old: [c("old", "z", "hello", 8 * 1440)] } });
  const m = memStore(); const r = await tick(work(), f.ig, m.st, NOW);
  assertEquals(f.dms.length, 0); assertEquals(f.replies.length, 0);
  assertEquals(m.log.get("s1")!.reason, "spam"); assertEquals(m.log.get("n1")!.reason, "negative");
  assert(!m.log.has("o1") && !m.log.has("old")); assertEquals([r.spam, r.negative], [1, 1]);
});

Deno.test("a comment the account already answered (Reel Studio, before the move) is imported, not messaged", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c9", "neha", "details")] }, replies: { c9: [{ id: "r1", username: OWN, from: { id: UID, username: OWN } }] } });
  const m = memStore(); const r = await tick(work(), f.ig, m.st, NOW);
  assertEquals(f.dms.length, 0); assertEquals(m.log.get("c9")!.state, "imported"); assertEquals(r.imported, 1);
});

Deno.test("a missing permission stops the run, releases the comment and records why; it waits until the token is replaced", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c1", "riya", "hi")] }, fail: (p, mth) => mth === "POST" && p.endsWith("/messages") ? new IGError("(#10) no permission", 10, false, true) : null });
  const m = memStore(); const r = await tick(work(), f.ig, m.st, NOW);
  assert(r.stop); assert(!m.log.has("c1"), "released so it is answered after the fix");
  assertEquals(m.cfg.state, "needs_permission"); assert(String(m.cfg.note).includes("instagram_business_manage_messages"));
  const waiting = await tick(work({ state: "needs_permission", checked_at: "2026-11-24T09:59:00Z" }), f.ig, m.st, NOW);
  assertEquals(waiting.waiting, "permission");
  const retried = await tick(work({ state: "needs_permission", checked_at: "2026-11-24T09:59:00Z" }, { token_at: "2026-11-24T10:01:00Z" }), fakeIG({ media, comments: { m1: [c("c1", "riya", "hi")] } }).ig, m.st, NOW);
  assertEquals(retried.sent, 1, "a new token retries at once");
});

Deno.test("an expired token marks the connection, no comment is lost", async () => {
  const f = fakeIG({ fail: (p) => p === "me" ? new IGError("Error validating access token", 190, true) : null });
  const m = memStore(); const r = await tick(work({ state: "check", user_id: null }), f.ig, m.st, NOW);
  assertEquals(r.state, "not ready"); assertEquals(m.cfg.state, "not_connected"); assertEquals(m.log.size, 0);
});

Deno.test("first run learns who the account is and when it started", async () => {
  const f = fakeIG({ media, comments: { m1: [] } }); const m = memStore();
  await tick(work({ state: "not_connected", user_id: null, username: null }), f.ig, m.st, NOW);
  assertEquals([m.cfg.state, m.cfg.user_id, m.cfg.username], ["ready", UID, OWN]); assert(m.cfg.started_at);
});

Deno.test("hourly cap: sends stop at the cap and the rest wait", async () => {
  const f = fakeIG({ media, comments: { m1: [c("a", "u1", "hi", 50), c("b", "u2", "hi", 40), c("d", "u3", "hi", 30)] } }); const m = memStore();
  const r = await tick(work({ cap: 60, public_reply: false }, { sent_last_hour: 58 }), f.ig, m.st, NOW);
  assertEquals(f.dms.length, 2); assert(r.capped); assert(!m.log.has("d"), "the third comment is untouched for the next hour");
});

Deno.test("switched off or no token: nothing is read or sent", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c1", "riya", "hi")] } }); const m = memStore();
  assertEquals((await tick(work({ on: false }), f.ig, m.st, NOW)).off, true);
  assertEquals((await tick(work({}, { token: null }), null, m.st, NOW)).connected, false);
  assertEquals(f.calls.length, 0); assertEquals(m.cfg.state, "not_connected");
});

Deno.test("inbox: someone who writes first is welcomed once; a number in a reply becomes a CRM lead with a thank-you", async () => {
  const convs = [{ id: "cv1", updated_time: ago(5) }];
  const msgs = { cv1: [{ id: "mA", created_time: ago(6), from: { id: "p77", username: "kabir" }, message: "pilot banna hai" }] };
  const f = fakeIG({ media: [], convs, msgs }); const m = memStore();
  const r1 = await tick(work(), f.ig, m.st, NOW);
  assertEquals(r1.inbox.welcomed, 1); assertEquals(f.dms[0].recipient, { id: "p77" });
  const msgs2 = { cv1: [...msgs.cv1, { id: "mB", created_time: ago(1), from: { id: "p77", username: "kabir" }, message: "mera number 98765 43210 hai" }] };
  const f2 = fakeIG({ media: [], convs: [{ id: "cv1", updated_time: ago(1) }], msgs: msgs2 });
  const r2 = await tick(work({ inbox_at: m.cfg.inbox_at }), f2.ig, m.st, NOW);
  assertEquals(r2.inbox.welcomed, 0, "welcomed only once"); assertEquals(r2.inbox.leads, 1);
  assertEquals(m.leads[0], { username: "kabir", phone: "+919876543210", source: "dm", text: "mera number 98765 43210 hai" });
  assertEquals(f2.dms.map((d) => d.message.text), ["Thanks @kabir!"]); assertEquals(m.people.get("p77")!.phone, "+919876543210");
});

Deno.test("inbox: no welcome when the team already talks to the person in that chat", async () => {
  const msgs = { cv2: [{ id: "t1", created_time: ago(30), from: { id: UID, username: OWN }, message: "Hello!" },
                       { id: "t2", created_time: ago(3), from: { id: "p88", username: "isha" }, message: "ok" }] };
  const f = fakeIG({ media: [], convs: [{ id: "cv2", updated_time: ago(3) }], msgs }); const m = memStore();
  const r = await tick(work(), f.ig, m.st, NOW);
  assertEquals(r.inbox.welcomed, 0); assertEquals(f.dms.length, 0);
});

Deno.test("helpers: phone numbers, spam / angry, the {name} placeholder", () => {
  assertEquals(phoneOf("call me +91 98765-43210"), "+919876543210"); assertEquals(phoneOf("09876543210"), "+919876543210");
  assertEquals(phoneOf("my code is 12345"), null); assertEquals(phoneOf("5876543210"), null);
  assertEquals(classify("Check my profile for promotion"), "spam"); assertEquals(classify("fraud academy"), "negative"); assertEquals(classify("fees kitni hai?"), null);
  assertEquals(render("Hi {name}!", "riya"), "Hi @riya!"); assertEquals(render("Hi {name}!"), "Hi there!");
});

Deno.test("the token never appears in an error, and long-lived tokens are refreshed after 20 days", async () => {
  const f = (async () => new Response(JSON.stringify({ error: { message: "Invalid token tok_SECRET_123 given", code: 190 } }), { status: 400 })) as unknown as typeof fetch;
  let msg = ""; try { await httpIG("tok_SECRET_123", f).get("me"); } catch (e) { msg = (e as Error).message; assert((e as IGError).auth); }
  assert(!msg.includes("tok_SECRET_123") && msg.includes("***"));
  const ok = (async (u: string) => { assert(String(u).includes("grant_type=ig_refresh_token")); return new Response(JSON.stringify({ access_token: "NEW_TOKEN_abcdefghijklmnopqrstuvwxyz" })); }) as unknown as typeof fetch;
  assertEquals(await refreshToken("old", "2026-11-01T00:00:00Z", ok, NOW), "NEW_TOKEN_abcdefghijklmnopqrstuvwxyz");
  assertEquals(await refreshToken("old", "2026-11-20T00:00:00Z", ok, NOW), null, "younger than 20 days: kept");
});

const PDF = { pdf_url: "https://crm.weoneaviation.in/files/we-one-aviation-brochure.pdf", pdf_name: "brochure" };
Deno.test("brochure: the comment DM invites a reply; the reply gets the PDF once; no PDF set means no invite", async () => {
  const f = fakeIG({ media, comments: { m1: [c("c1", "riya", "fees?")] } }); const m = memStore();
  await tick(work(PDF), f.ig, m.st, NOW);
  assert(f.dms[0].message.text.endsWith("📄 Reply to this message and we'll send you our brochure (PDF) right here."));
  assertEquals(f.dms.length, 1, "Instagram allows one message to a commenter until they reply");
  // riya answers the private reply in the chat
  const msgs = { cv1: [{ id: "m1x", created_time: ago(2), from: { id: "sid_c1", username: "riya" }, message: "yes please" }] };
  const f2 = fakeIG({ media: [], convs: [{ id: "cv1", updated_time: ago(2) }], msgs }); const r = await tick(work({ ...PDF, inbox_at: m.cfg.inbox_at }), f2.ig, m.st, NOW);
  assertEquals(f2.dms.map((d) => d.message.text ?? d.message.attachment.type), ["Here's our brochure ✈️", "file"]);
  assertEquals(f2.dms[1].message.attachment.payload.url, PDF.pdf_url); assertEquals(r.inbox.pdf, 1); assert(m.people.get("sid_c1")!.pdf_at);
  const msgs3 = { cv1: [...msgs.cv1, { id: "m2x", created_time: ago(1), from: { id: "sid_c1", username: "riya" }, message: "thanks" }] };
  const f3 = fakeIG({ media: [], convs: [{ id: "cv1", updated_time: ago(1) }], msgs: msgs3 }); await tick(work({ ...PDF, inbox_at: m.cfg.inbox_at }), f3.ig, m.st, NOW);
  assertEquals(f3.dms.length, 0, "the brochure is sent once");
  const f4 = fakeIG({ media, comments: { m1: [c("c7", "dev", "info")] } }); await tick(work(), f4.ig, memStore().st, NOW);
  assert(!f4.dms[0].message.text.includes("PDF"));
});

Deno.test("brochure: someone who writes first gets the welcome and the PDF together", async () => {
  const msgs = { cv5: [{ id: "q1", created_time: ago(4), from: { id: "p55", username: "arjun" }, message: "hello" }] };
  const f = fakeIG({ media: [], convs: [{ id: "cv5", updated_time: ago(4) }], msgs }); const m = memStore();
  const r = await tick(work(PDF), f.ig, m.st, NOW);
  assertEquals(f.dms.length, 2); assertEquals(f.dms[1].message.attachment, { type: "file", payload: { url: PDF.pdf_url } });
  assertEquals([r.inbox.welcomed, r.inbox.pdf], [1, 1]); assertEquals(m.sends.filter((k) => k === "pdf").length, 1);
});

Deno.test("an older post still gets its new comments answered; posts with no comments are not read", async () => {
  const f = fakeIG({ media: [{ id: "m_new", timestamp: ago(60), comments_count: 0 }, { id: "m_old", timestamp: ago(30 * 1440), comments_count: 2 }],
                     comments: { m_old: [c("o1", "kabir", "fees kitni hai?", 20), c("o2", "old_one", "hi", 8 * 1440)] } });
  const m = memStore(); const r = await tick(work(), f.ig, m.st, NOW);
  assertEquals(r.sent, 1, "the 20-minute-old comment on a 30-day-old post is answered; the 8-day-old comment is too late");
  assert(!f.calls.includes("GET m_new/comments"), "a post with no comments is skipped");
});

Deno.test("custom texts: welcome for people who write first, brochure invite and brochure intro", async () => {
  const T = { ...PDF, pdf_name: "prospectus", welcome: "Namaste {name}! Ask us anything.", pdf_invite: "Reply YES for our {brochure}.", pdf_intro: "Our {brochure} 👇" };
  const f = fakeIG({ media, comments: { m1: [c("c1", "riya", "fees?")] } }); const m = memStore();
  await tick(work(T), f.ig, m.st, NOW);
  assert(f.dms[0].message.text.endsWith("\n\nReply YES for our prospectus."));
  const msgs = { cv1: [{ id: "m1x", created_time: ago(2), from: { id: "sid_c1", username: "riya" }, message: "yes" }] };
  const f2 = fakeIG({ media: [], convs: [{ id: "cv1", updated_time: ago(2) }], msgs }); await tick(work({ ...T, inbox_at: m.cfg.inbox_at }), f2.ig, m.st, NOW);
  assertEquals(f2.dms[0].message.text, "Our prospectus 👇");
  const f3 = fakeIG({ media: [], convs: [{ id: "cv9", updated_time: ago(3) }], msgs: { cv9: [{ id: "z1", created_time: ago(3), from: { id: "p9", username: "meera" }, message: "hello" }] } });
  await tick(work(T), f3.ig, memStore().st, NOW);
  assertEquals(f3.dms[0].message.text, "Namaste @meera! Ask us anything.");
});
