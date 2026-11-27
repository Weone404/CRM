// Unit test for wa-gateway (no Cloudflare needed): node tools/wa-gateway/test.mjs
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker, { retryDue, validSignature } from "./src/index.js";

// In-memory stand-in for D1 (only the statements the Worker uses).
function fakeD1({ failInsert = false } = {}) {
  const rows = []; let seq = 0;
  const stmt = (sql) => ({ args: [], bind(...a) { this.args = a; return this; },
    async first() {
      if (sql.startsWith("INSERT")) { if (failInsert) throw new Error("D1 limit"); const r = { id: ++seq, body: this.args[0], sig: this.args[1], received_at: this.args[2], done: "[]", attempts: 0, done_at: null, next_at: null }; rows.push(r); return { id: r.id }; }
      if (sql.startsWith("SELECT count")) return { n: rows.filter((r) => r.done_at == null).length };
    },
    async all() { const [since, now] = this.args; return { results: rows.filter((r) => r.done_at == null && r.received_at > since && (r.next_at == null || r.next_at <= now)) }; },
    async run() {
      const a = this.args;
      if (sql.startsWith("UPDATE events SET done_at")) Object.assign(rows.find((r) => r.id === a[3]), { done_at: a[0], done: a[1], attempts: a[2] });
      else if (sql.startsWith("UPDATE events SET done =")) Object.assign(rows.find((r) => r.id === a[4]), { done: a[0], attempts: a[1], next_at: a[2], last_error: a[3] });
    } });
  return { rows, prepare: stmt };
}
const SECRET = "app-secret";
const body = JSON.stringify({ entry: [{ changes: [{ field: "messages", value: {} }] }] });
const sig = "sha256=" + createHmac("sha256", SECRET).update(body).digest("hex");
const req = (s = sig) => new Request("https://gw.example/", { method: "POST", body, headers: { "x-hub-signature-256": s } });
let crmUp = true; const hits = [];
globalThis.fetch = async (url, init) => { hits.push({ url, sig: init.headers["x-hub-signature-256"], body: init.body }); return new Response("ok", { status: crmUp ? 200 : 503 }); };
const waits = []; const ctx = { waitUntil: (p) => waits.push(p) };
const flush = () => Promise.all(waits.splice(0));

const env = { DB: fakeD1(), APP_SECRET: SECRET, TARGETS: "https://crm.example/wa-webhook" };
assert.equal(await validSignature(SECRET, body, sig), true);
assert.equal(await validSignature("other", body, sig), false);
assert.equal((await worker.fetch(req("sha256=" + "0".repeat(64)), env, ctx)).status, 403); console.log("PASS G01 wrong signature refused");
let r = await worker.fetch(req(), env, ctx); await flush();
assert.equal(r.status, 200); assert.equal(hits.length, 1); assert.equal(hits[0].sig, sig); assert.equal(hits[0].body, body);
assert.ok(env.DB.rows[0].done_at); console.log("PASS G02 stored, answered 200, forwarded byte-for-byte with Meta's signature");
crmUp = false; hits.length = 0;
r = await worker.fetch(req(), env, ctx); await flush();
assert.equal(r.status, 200); assert.equal(env.DB.rows[1].done_at, null); assert.ok(env.DB.rows[1].next_at > Date.now()); console.log("PASS G03 CRM down: Meta still gets 200, copy kept for later");
crmUp = true;
let res = await retryDue(env, Date.now() + 2 * 60_000);
assert.equal(res.sent, 1); assert.ok(env.DB.rows[1].done_at); console.log("PASS G04 copy re-sent when the CRM is back");
res = await retryDue(env, Date.now() + 10 * 60_000); assert.equal(res.tried, 0); console.log("PASS G05 never sent twice");
const two = { ...env, DB: fakeD1(), TARGETS: "https://crm.example/a,https://crm.example/b" };
let n = 0; globalThis.fetch = async (url) => { n++; return new Response("", { status: url.endsWith("/b") && n < 3 ? 500 : 200 }); };
await worker.fetch(req(), two, ctx); await flush();
assert.equal(two.DB.rows[0].done, "[0]");
await retryDue(two, Date.now() + 2 * 60_000);
assert.equal(n, 3); assert.ok(two.DB.rows[0].done_at); console.log("PASS G06 two targets: only the one that failed is retried");
const broken = { ...env, DB: fakeD1({ failInsert: true }) };
globalThis.fetch = async () => new Response("", { status: 503 });
assert.equal((await worker.fetch(req(), broken, ctx)).status, 500); console.log("PASS G07 D1 and CRM both down: 500 so Meta retries");
globalThis.fetch = async () => new Response("", { status: 200 });
assert.equal((await worker.fetch(req(), broken, ctx)).status, 200); console.log("PASS G08 D1 down, CRM up: forwarded directly");
console.log("ALL GATEWAY TESTS PASSED");
