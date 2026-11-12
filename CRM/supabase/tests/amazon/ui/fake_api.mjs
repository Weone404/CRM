// Test-only stand-in for PostgREST + the amazon-* Edge Functions, backed by the local Postgres test DB.
// POST /rest/v1/rpc/<fn>  -> SELECT public.<fn>(name => value, ...) as role `authenticated`, as the current test user.
// GET  /__as/<auth uid>   -> switch the current test user.
// POST /functions/v1/amazon-settings | amazon-execute | amazon-sync -> canned answers (Amazon is not called in UI tests).
import http from 'node:http';
import { createRequire } from 'node:module';
const PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
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
  const chunks = []; for await (const c of req) chunks.push(Buffer.from(c));
  const buf = Buffer.concat(chunks); const raw = buf.toString('utf8');
  let form = null;
  if ((req.headers['content-type'] || '').startsWith('multipart/form-data')) {
    try { form = await new Response(buf, { headers: { 'content-type': req.headers['content-type'] } }).formData(); } catch { form = null; }
  }
  let args = {}; try { args = raw ? JSON.parse(raw) : {}; } catch { args = { multipart: raw.length }; }
  if (url.pathname.startsWith('/functions/v1/')) {
    const fn = url.pathname.split('/').pop(); calls.push({ fn, args });
    if (fn === 'amazon-settings') return send(res, 200, { status: 'Connected', detail: 'All good (UI test stub).' });
    if (fn === 'amazon-execute') return send(res, 200, { status: 'executing' });
    if (fn === 'amazon-upload') return send(res, 200, { url: `https://example.invalid/amazon-images/test/${calls.length}.png` });
    if (fn === 'amazon-sync') return send(res, 200, { status: 'ok', results: [{ job: 'listings', status: 'ok' }] });
    if (fn === 'amazon-studio') {
      if (args.action === 'urls') return send(res, 200, Object.fromEntries((args.ids || []).map((id) => [id, PIXEL])));
      if (args.action === 'bg_search') return send(res, 200, { page: 1, photos: [1, 2, 3].map((i) => ({ id: i, alt: `Wooden desk ${i}`, width: 4000, height: 4000, thumb: PIXEL, preview: PIXEL,
        url: `https://images.pexels.com/photos/${i}/pexels-photo-${i}.jpeg?auto=compress&cs=tinysrgb&w=2400`, credit: { name: `Photographer ${i}`, url: 'https://www.pexels.com/@p', photo: `https://www.pexels.com/photo/${i}/` } })) });
      if (args.action === 'study') {
        const db = await pool.connect();
        try {
          await db.query('BEGIN'); await db.query('SET LOCAL ROLE service_role');
          const items = [1, 2, 3].map((i) => ({ asin: `B0TEST000${i}`, title: `Competitor diary ${i}`, images: [{ variant: 'MAIN', url: `https://m.media-amazon.com/images/I/c${i}.jpg` }, { variant: 'PT01', url: `https://m.media-amazon.com/images/I/c${i}b.jpg` }] }));
          const r = await db.query('SELECT public.svc_amz_studio_study($1, $2, $3::jsonb, NULL) AS r', [args.sku, args.keyword, JSON.stringify(items)]);
          await db.query('COMMIT'); return send(res, 200, r.rows[0].r);
        } catch (e) { await db.query('ROLLBACK'); return send(res, 422, { detail: e.message }); } finally { db.release(); }
      }
      if (args.action === 'send') {
        const db = await pool.connect();
        try {
          await db.query('BEGIN'); await db.query('SET LOCAL ROLE service_role');
          const r = await db.query('SELECT public.svc_amz_studio_send($1, $2, $3, NULL) AS r', [args.asset, args.slot, 'https://example.invalid/amazon-images/studio.jpg']);
          await db.query('COMMIT'); return send(res, 200, r.rows[0].r);
        } catch (e) { await db.query('ROLLBACK'); return send(res, 422, { detail: e.message }); } finally { db.release(); }
      }
      if (form && form.get('design') === '1') {
        const db = await pool.connect();
        try {
          await db.query('BEGIN'); await db.query('SET LOCAL ROLE service_role');
          const r = await db.query('SELECT public.svc_amz_studio_design($1, $2, 2000, 2000, $3, $4::jsonb, $5::uuid, $6::jsonb, NULL) AS r',
            [form.get('sku'), `${form.get('sku')}/design/t.jpg`, (form.get('file')?.size) || 0, form.get('layers') || '[]', form.get('parent') || null, form.get('checks') || '[]']);
          await db.query('COMMIT'); calls.push({ fn: 'studio-design', bytes: form.get('file')?.size || 0 }); return send(res, 200, r.rows[0].r);
        } catch (e) { await db.query('ROLLBACK'); return send(res, 422, { detail: e.message }); } finally { db.release(); }
      }
      return send(res, 200, { id: null });
    }
    return send(res, 404, { detail: 'no such function' });
  }
  // Test-only: run a service function as service_role (stands in for the Mac helper / Edge Functions).
  const sv = /^\/__svc\/(svc_[a-z_0-9]+)$/.exec(url.pathname);
  if (sv) {
    const ks = Object.keys(args);
    const st = (await pool.query(`SELECT unnest(proargnames) n, unnest(proargtypes::regtype[]::text[]) t FROM pg_proc
                                   WHERE proname = $1 AND pronamespace = 'public'::regnamespace LIMIT 50`, [sv[1]])).rows;
    const sOf = (k) => (st.find((r) => r.n === k) || {}).t;
    const vs = ks.map((k) => (Array.isArray(args[k]) && sOf(k) === 'text[]' ? `{${args[k].map((x) => JSON.stringify(String(x))).join(',')}}`
      : args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
    const db = await pool.connect();
    try {
      await db.query('BEGIN'); await db.query('SET LOCAL ROLE service_role');
      const r = await db.query(`SELECT to_jsonb(public.${sv[1]}(${ks.map((k, i) => `${k} => $${i + 1}`).join(', ')})) AS r`, vs);
      await db.query('COMMIT'); return send(res, 200, r.rows[0].r);
    } catch (e) { await db.query('ROLLBACK'); return send(res, 400, { message: e.message }); } finally { db.release(); }
  }
  const m = /^\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(url.pathname);
  if (!m) return send(res, 404, { message: 'not found' });
  const fn = m[1]; calls.push({ fn, args });
  const keys = Object.keys(args);
  // arrays: a Postgres array for text[] parameters, JSON for jsonb parameters (like PostgREST)
  const types = (await pool.query(`SELECT unnest(proargnames) n, unnest(proargtypes::regtype[]::text[]) t FROM pg_proc
                                     WHERE proname = $1 AND pronamespace = 'public'::regnamespace LIMIT 50`, [fn])).rows;
  const tOf = (k) => (types.find((r) => r.n === k) || {}).t;
  const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k]) ? JSON.stringify(args[k])
    : Array.isArray(args[k]) ? (tOf(k) === 'jsonb' ? JSON.stringify(args[k]) : `{${args[k].map((x) => JSON.stringify(String(x))).join(',')}}`) : args[k]));
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
