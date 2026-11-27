// wa-gateway: a free Cloudflare Worker in front of the CRM's wa-webhook (Supabase Edge Function).
//
// Meta -> this Worker -> wa-webhook. It checks Meta's signature, keeps a copy of every delivery in Cloudflare D1, answers
// Meta at once, and forwards. If the CRM is down or paused, the copy is sent again every minute (with back-off) for up
// to 7 days, so no WhatsApp message is lost. If D1 itself fails, it forwards straight away and lets Meta retry.
// Meta's signature header is passed through unchanged, so wa-webhook still verifies every delivery itself.
//
// Settings (wrangler.toml / wrangler secret):
//   TARGETS     comma-separated URLs to forward to (first one also answers Meta's GET verification)
//   APP_SECRET  the Meta App Secret (secret: `npx wrangler secret put APP_SECRET`)
//   DB          D1 database binding (schema.sql)
const DAY = 86_400_000;

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const targets = targetsOf(env);
    if (!targets.length) return text(500, "TARGETS not set");
    if (req.method === "GET") {
      if (url.pathname === "/health") {
        const row = await env.DB.prepare("SELECT count(*) AS n FROM events WHERE done_at IS NULL").first().catch(() => null);
        return Response.json({ ok: true, waiting: row ? row.n : null, targets: targets.length });
      }
      const t = new URL(targets[0]);                       // Meta's verification: the CRM checks the verify token
      t.search = url.search;
      const r = await fetch(t.toString(), { headers: { "x-wa-gateway": "1" } });
      return text(r.status, await r.text());
    }
    if (req.method !== "POST") return text(405, "Method not allowed");
    const raw = await req.text();
    if (raw.length > 3_500_000) return text(413, "Too large");
    const sig = req.headers.get("x-hub-signature-256") || "";
    if (!(await validSignature(env.APP_SECRET, raw, sig))) return text(403, "Invalid signature");
    let id;
    try {
      const row = await env.DB.prepare("INSERT INTO events (body, sig, received_at) VALUES (?, ?, ?) RETURNING id").bind(raw, sig, Date.now()).first();
      id = row.id;
    } catch (e) {
      const res = await forwardAll(targets, raw, sig, []);  // no copy possible: forward now, Meta retries if this fails
      return res.allOk ? text(200, "EVENT_RECEIVED") : text(500, "Try again");
    }
    ctx.waitUntil(deliver(env, targets, { id, body: raw, sig, done: "[]", attempts: 0 }));
    return text(200, "EVENT_RECEIVED");
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(retryDue(env));
  },
};

export async function retryDue(env, now = Date.now()) {
  const targets = targetsOf(env);
  const rows = await env.DB.prepare(
    "SELECT id, body, sig, done, attempts FROM events WHERE done_at IS NULL AND received_at > ? AND (next_at IS NULL OR next_at <= ?) ORDER BY id LIMIT 25",
  ).bind(now - 7 * DAY, now).all();
  let sent = 0;
  for (const r of rows.results || []) if (await deliver(env, targets, r, now)) sent++;
  await env.DB.prepare("DELETE FROM events WHERE (done_at IS NOT NULL AND done_at < ?) OR received_at < ?").bind(now - 3 * DAY, now - 8 * DAY).run();
  return { tried: (rows.results || []).length, sent };
}

async function deliver(env, targets, ev, now = Date.now()) {
  const res = await forwardAll(targets, ev.body, ev.sig, JSON.parse(ev.done || "[]"));
  const attempts = (ev.attempts || 0) + 1;
  if (res.allOk) {
    await env.DB.prepare("UPDATE events SET done_at = ?, done = ?, attempts = ?, last_error = NULL WHERE id = ?").bind(now, JSON.stringify(res.done), attempts, ev.id).run();
    return true;
  }
  const wait = Math.min(60 * 60_000, 60_000 * 2 ** Math.min(attempts - 1, 6));   // 1, 2, 4 ... 60 minutes
  await env.DB.prepare("UPDATE events SET done = ?, attempts = ?, next_at = ?, last_error = ? WHERE id = ?")
    .bind(JSON.stringify(res.done), attempts, now + wait, res.error, ev.id).run();
  return false;
}

export async function forwardAll(targets, raw, sig, done) {
  const out = [...done];
  let error = null;
  for (let i = 0; i < targets.length; i++) {
    if (out.includes(i)) continue;                       // each target gets each delivery once
    try {
      const r = await fetch(targets[i], { method: "POST", body: raw,
        headers: { "Content-Type": "application/json", "x-hub-signature-256": sig, "x-wa-gateway": "1" } });
      if (r.status === 200) out.push(i); else error = `target ${i + 1}: HTTP ${r.status}`;
    } catch (e) {
      error = `target ${i + 1}: ${String(e && e.message || e).slice(0, 120)}`;
    }
  }
  return { allOk: out.length === targets.length, done: out, error };
}

export async function validSignature(secret, raw, header) {
  const m = /^sha256=([0-9a-fA-F]{64})$/.exec((header || "").trim());
  if (!secret || !m) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const want = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  const got = m[1].toLowerCase();
  let d = 0;
  for (let i = 0; i < 64; i++) d |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return d === 0;
}

const targetsOf = (env) => String(env.TARGETS || "").split(",").map((s) => s.trim()).filter((s) => /^https:\/\//.test(s));
const text = (status, body) => new Response(body, { status, headers: { "Content-Type": "text/plain" } });
