// Test-only stand-in for PostgREST + the wa-admin Edge Function, backed by the local Postgres test DB.
// POST /rest/v1/rpc/<fn>   -> SELECT public.<fn>(...) as role `authenticated`, as the test user (Admin by default).
// POST /functions/v1/wa-admin -> "simulate" runs the real flow engine (wa.ts); "send" queues through api_wa_send and
//                                marks it sent the way wa-worker would; Meta-facing actions return canned answers.
import http from 'node:http';
import { createRequire } from 'node:module';
import { decide, describe } from '../../../functions/_shared/wa.ts';
const require = createRequire(process.env.PG_MODULE_DIR + '/');
const { Pool } = require('pg');
const pool = new Pool({ max: 8, host: process.env.PGHOST, port: Number(process.env.PGPORT), user: 'postgres', database: process.env.PGDATABASE });
const sub = process.env.AS_USER || '10000000-0000-0000-0000-00000000000a';
const send = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
async function asUser(fn, args) {
  const keys = Object.keys(args);
  const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && (!Array.isArray(args[k]) || args[k].some((x) => x !== null && typeof x === 'object')) ? JSON.stringify(args[k])
    : Array.isArray(args[k]) ? `{${args[k].map((x) => JSON.stringify(String(x))).join(',')}}` : args[k]));
  const db = await pool.connect();
  try {
    await db.query('BEGIN'); await db.query('SET LOCAL ROLE authenticated');
    await db.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [sub]);
    const r = await db.query(`SELECT to_jsonb(public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})) AS r`, vals);
    await db.query('COMMIT');
    return r.rows[0].r;
  } catch (e) { await db.query('ROLLBACK').catch(() => {}); throw e; } finally { db.release(); }
}
let n = 0;
http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204);
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/auth/v1/health') return send(res, 200, { ok: true });   // the CRM's connection signal pings this
  let raw = ''; for await (const c of req) raw += c;
  const args = raw ? JSON.parse(raw) : {};
  try {
    if (url.pathname === '/functions/v1/wa-admin') {
      const a = args.action;
      if (a === 'simulate') {
        const flow = await asUser('api_wa_flow', { p_brand: args.brand || 'aviation' });
        return send(res, 200, decide({ conversation: { status: 'bot', current_step: args.step ?? null, miss_count: Number(args.miss || 0) }, contact: { opted_out: !!args.opted_out },
          steps: flow.steps, rules: flow.rules, vars: flow.vars, brochure: flow.brochure, bot_on: true },
          { wamid: 'sim', from: '0', kind: args.button ? 'button' : 'text', text: args.text, button_title: args.button }));
      }
      if (a === 'send') {
        const id = await asUser('api_wa_send', { p_conv: args.conversation, p_item: args.item });
        const claimed = (await pool.query('SELECT public.svc_wa_claim($1::bigint[]) r', [[id]])).rows[0].r;
        for (const c of claimed) await pool.query('SELECT public.svc_wa_result($1, true, $2, NULL, NULL, false, $3)', [c.id, `wamid.ui${++n}`, describe(c.item, c.template, c.vars)]);
        return send(res, 200, { queued: id, sent: claimed.length, failed: 0 });
      }
      if (a === 'checks') return send(res, 200, { results: { token: { ok: false, detail: 'UI test stub: Meta not called' } } });
      return send(res, 200, { ok: true, submitted: 0, results: [], detail: 'UI test stub' });
    }
    const m = /^\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(url.pathname);
    if (!m) return send(res, 404, { message: 'not found' });
    return send(res, 200, await asUser(m[1], args));
  } catch (e) {
    return send(res, 400, { code: e.code, message: e.message, detail: e.message, details: null, hint: null });
  }
}).listen(54398, () => console.log('fake api on 54398'));
