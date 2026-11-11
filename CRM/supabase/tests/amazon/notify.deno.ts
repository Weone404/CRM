// Unit tests for business-email (SMTP) and phone-notification pieces (Deno, not bun). Run: deno test -A supabase/tests/amazon/notify.deno.ts
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { buildMessage, smtpSend } from "../../functions/_shared/smtp.ts";
import { alertEmail, alertPushes, digestEmail, replyPush } from "../../functions/_shared/notify_text.ts";

const cfg = { host: "mail.test", port: 465, username: "info@weoneaviation.in", password: "p@ss word", fromName: "Nitaniya Alerts" };

// A scripted fake mail server: answers each command, records what the client sent.
function fakeServer(opts: { authOk?: boolean } = {}) {
  const sent: string[] = [];
  const out: string[] = ["220 mail.test ESMTP\r\n"];
  let inData = false, data = "";
  const enc = new TextEncoder(), dec = new TextDecoder();
  const conn = {
    closed: false,
    async read(p: Uint8Array) {
      if (!out.length) return null;
      const b = enc.encode(out.shift()!);
      p.set(b); return b.length;
    },
    async write(p: Uint8Array) {
      const s = dec.decode(p);
      sent.push(s);
      if (inData) { data += s; if (data.endsWith("\r\n.\r\n")) { inData = false; out.push("250 2.0.0 queued\r\n"); } return p.length; }
      const c = s.trim().split(" ")[0].toUpperCase();
      if (c === "EHLO") out.push("250-mail.test\r\n250-AUTH LOGIN PLAIN\r\n250 SIZE 52428800\r\n");
      else if (c === "AUTH") out.push("334 VXNlcm5hbWU6\r\n");
      else if (sent.length === 3) out.push("334 UGFzc3dvcmQ6\r\n");
      else if (sent.length === 4) out.push(opts.authOk === false ? "535 5.7.8 Authentication failed\r\n" : "235 ok\r\n");
      else if (c === "MAIL" || c === "RCPT") out.push("250 ok\r\n");
      else if (c === "DATA") { inData = true; out.push("354 go\r\n"); }
      else if (c === "QUIT") out.push("221 bye\r\n");
      return p.length;
    },
    close() { this.closed = true; },
  };
  return { conn, sent, data: () => data };
}

Deno.test("SMTP: logs in, sends to every recipient, dot-stuffs the body", async () => {
  const f = fakeServer();
  await smtpSend(cfg, { to: ["a@x.in", "b@y.in"], subject: "🛒 New order", text: "line\n.starts with dot", html: "<p>hi</p>" }, async () => f.conn);
  const all = f.sent.join("");
  assertStringIncludes(all, "EHLO ");
  assertEquals(f.sent[2].trim(), btoa("info@weoneaviation.in"));
  assertEquals(f.sent[3].trim(), btoa("p@ss word"));
  assertStringIncludes(all, "RCPT TO:<a@x.in>");
  assertStringIncludes(all, "RCPT TO:<b@y.in>");
  assert(f.data().endsWith("\r\n.\r\n"));
  assert(f.conn.closed);
});

Deno.test("SMTP: wrong password gives a plain message", async () => {
  const f = fakeServer({ authOk: false });
  await assertRejects(() => smtpSend(cfg, { to: ["a@x.in"], subject: "s", text: "t", html: "h" }, async () => f.conn), Error, "Wrong email or password");
});

Deno.test("SMTP: unreachable server names host and port", async () => {
  await assertRejects(() => smtpSend(cfg, { to: ["a@x.in"], subject: "s", text: "t", html: "h" }, () => Promise.reject(new Error("Connection refused"))),
    Error, "Could not reach mail.test:465");
});

Deno.test("SMTP message: UTF-8 subject/name encoded, no header injection, body decodes", () => {
  const m = buildMessage({ ...cfg, fromName: "Nitaniya\r\nBcc: evil@x.com" }, { to: ["a@x.in"], subject: "नया ऑर्डर\r\nBcc: evil@x.com", text: "नमस्ते", html: "<b>hi</b>" });
  const head = m.split("\r\n\r\n")[0];
  assert(!/^Bcc:/m.test(head), "no injected header");
  assertStringIncludes(head, "Subject: =?UTF-8?B?");
  assertStringIncludes(head, "From: \"Nitaniya Bcc: evil@x.com\" <info@weoneaviation.in>");
  const textPart = m.split("Content-Transfer-Encoding: base64\r\n\r\n")[1].split("\r\n--")[0].replace(/\r\n/g, "");
  assertEquals(new TextDecoder().decode(Uint8Array.from(atob(textPart), (c) => c.charCodeAt(0))), "नमस्ते");
  assert(m.split("\r\n").every((l) => l.length <= 998));
});

Deno.test("Alert email escapes HTML and keeps only https links", () => {
  const e = alertEmail([{ id: 1, kind: "feedback", title: "1-star <script>", body: "bad & late", link: "javascript:alert(1)" },
    { id: 2, kind: "new_order", title: "New order", body: null, link: "https://sellercentral.amazon.in/orders-v3/order/1" }]);
  assert(!e.html.includes("<script>"));
  assert(!e.html.includes("javascript:"));
  assertStringIncludes(e.html, "https://sellercentral.amazon.in/orders-v3/order/1");
  assertStringIncludes(e.subject, "2 Amazon alerts");
});

Deno.test("Digest email links each decision", () => {
  const e = digestEmail([{ summary: "Same-day dispatch", why: "faster", product: "Diary", link: "https://crm.weoneaviation.in/#/amazon/decisions?open=5" }], 25);
  assertStringIncludes(e.subject, "25 Amazon decisions waiting");
  assertStringIncludes(e.html, "open=5");
});

Deno.test("Pushes: up to 3 alerts one by one, more become one summary", () => {
  const a = (i: number) => ({ id: i, kind: "new_order", title: `Order ${i}`, body: "Ship by Mon" });
  assertEquals(alertPushes([a(1), a(2), a(3)]).length, 3);
  const many = alertPushes([1, 2, 3, 4, 5].map(a));
  assertEquals(many.length, 1);
  assertStringIncludes(many[0].title, "5 new Amazon alerts");
  assertEquals(replyPush({ id: 9, kind: "fix", asked_by: "u", answer: "done" }).url, "/#/amazon/decisions");
  assertEquals(replyPush({ id: 9, kind: "chat", asked_by: "u", answer: "hi" }).url, "/#/amazon/ask");
});

Deno.test("Web Push: keys round-trip through Vault JSON and a push is signed and encrypted", async () => {
  const keys = await webpush.generateVapidKeys({ extractable: true });
  const pub = await webpush.exportApplicationServerKey(keys);
  assert(/^[A-Za-z0-9_-]{80,100}$/.test(pub), "public key fits the SQL check");
  const stored = JSON.stringify(await webpush.exportVapidKeys(keys));
  const as = await webpush.ApplicationServer.new({ contactInformation: "mailto:info@weoneaviation.in",
    vapidKeys: await webpush.importVapidKeys(JSON.parse(stored), { extractable: false }) });
  // A browser-like subscription: P-256 public key + 16-byte auth secret.
  const ua = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  let got: Request | null = null, status = 201;
  const srv = Deno.serve({ port: 0, onListen() {} }, async (r) => { got = r.clone(); await r.arrayBuffer(); return new Response(null, { status }); });
  const endpoint = `http://localhost:${srv.addr.port}/push/abc`;
  const sub = as.subscribe({ endpoint, keys: { p256dh: b64u(raw), auth: b64u(crypto.getRandomValues(new Uint8Array(16))) } });
  await sub.pushTextMessage(JSON.stringify({ title: "t" }), { ttl: 60, urgency: webpush.Urgency.High });
  assertEquals(got!.headers.get("content-encoding"), "aes128gcm");
  assertStringIncludes(got!.headers.get("authorization")!, `k=${pub}`);
  assertEquals(got!.headers.get("urgency"), "high");
  status = 410;
  const err = await sub.pushTextMessage("x", {}).catch((e) => e);
  assert(err instanceof webpush.PushMessageError && err.response.status === 410, "gone subscriptions are detected");
  await srv.shutdown();
});
