// Test-only stand-in for PostgREST + the ads-sync Edge Function, backed by the local Postgres test DB.
// POST /rest/v1/rpc/<fn>  -> SELECT public.<fn>(name => value, ...) as role `authenticated`, as the current test user.
// GET  /__as/<auth uid>   -> switch the current test user.
// POST /functions/v1/amazon-settings | amazon-execute | amazon-sync -> canned answers (Amazon is not called in UI tests).
import http from 'node:http';
import { createRequire } from 'node:module';
const require = createRequire(process.env.PG_MODULE_DIR + '/');
const { Pool } = require('pg');
const pool = new Pool({ max: 8, host: process.env.PGHOST, port: Number(process.env.PGPORT), user: 'postgres', database: process.env.PGDATABASE });
let sub = process.env.AS_USER || '';
const calls = [];
const send = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204);
  const url = new URL(req.url, 'http://x');
  if (url.pathname.startsWith('/__as/')) { sub = url.pathname.slice(6); return send(res, 200, { sub }); }
  if (url.pathname === '/__calls') return send(res, 200, calls);
  let raw = ''; for await (const c of req) raw += c;
  const args = raw ? JSON.parse(raw) : {};
  if (url.pathname.startsWith('/functions/v1/')) {
    const fn = url.pathname.split('/').pop(); calls.push({ fn, args });
    if (fn === 'ads-sync') {
      const jobs = args.jobs || [];
      const results = {};
      if (jobs.includes('test')) results.test = { google: { job: 'test_google', status: 'error', detail: 'Not configured (UI test stub)' }, meta: { job: 'test_meta', status: 'error', detail: 'Not configured (UI test stub)' } };
      if (jobs.includes('discover')) results.discover = {
        google: { ok: true, accounts: [
          { platform: 'google', external_id: '1112223333', name: 'Test Google', currency: 'INR', timezone: 'Asia/Kolkata', status: 'ENABLED', active: true, login_customer_id: null },
          { platform: 'google', external_id: '7778889999', name: 'Pilot School Search', currency: 'INR', timezone: 'Asia/Kolkata', status: 'ENABLED', active: true, login_customer_id: '9998887777' }] },
        meta: { ok: true, accounts: [
          { platform: 'meta', external_id: '5554443', name: 'Pilot School Meta', currency: 'INR', timezone: 'Asia/Kolkata', status: 'ACTIVE', active: true, business: 'Test Biz' }] },
        known: [{ platform: 'google', external_id: '1112223333', client: 'Test Client A' }] };
      if (jobs.includes('sync')) results.sync = { job: 'sync', status: 'ok', items: 0, detail: 'UI test stub: platforms not called' };
      if (jobs.includes('execute')) results.execute = { job: 'execute', status: 'ok', items: 0, detail: '0 change(s) processed (UI test stub)' };
      return send(res, 200, { results });
    }
    return send(res, 404, { detail: 'no such function' });
  }
  const m = /^\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(url.pathname);
  if (!m) return send(res, 404, { message: 'not found' });
  const fn = m[1]; calls.push({ fn, args });
  const keys = Object.keys(args);
  const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k]) ? JSON.stringify(args[k])
    : Array.isArray(args[k]) ? `{${args[k].map((x) => JSON.stringify(String(x))).join(',')}}` : args[k]));
  const sql = `SELECT to_jsonb(public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})) AS r`;
  const db = await pool.connect();   // one connection per request: role and user are per transaction
  try {
    await db.query('BEGIN');
    await db.query('SET LOCAL ROLE authenticated');
    await db.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [sub]);
    const r = await db.query(sql, vals);
    await db.query('COMMIT');
    return send(res, 200, r.rows[0].r);
  } catch (e) {
    await db.query('ROLLBACK').catch(() => {});
    return send(res, 400, { code: e.code, message: e.message, details: null, hint: null });
  } finally { db.release(); }
}).listen(54399, () => console.log('fake api on 54399'));
