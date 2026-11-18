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

// Meta Ads > Reports (UI test stub): rows shaped like ads-sync's parsed Insights rows, two per level, split when asked.
const ENT = { campaign: [['7101', 'CPL Reels Delhi', 800, 4], ['7102', 'Broad India Static', 2200, 2]],
  adset: [['8101', 'Delhi 18-24', 800, 4], ['8102', 'India 25-45', 2200, 2]], ad: [['9101', 'Pilot banna hai? Reel', 800, 4], ['9102', 'Fees banner', 2200, 2]],
  account: [[null, 'Whole account', 3000, 6]] };
const SPLITS = { age: [['age', '18-24', 0.6], ['age', '25-34', 0.4]], gender: [['gender', 'female', 0.3], ['gender', 'male', 0.7]],
  placement: [['platform', 'instagram', 0.7, 'placement', 'reels'], ['platform', 'facebook', 0.3, 'placement', 'feed']], country: [['country', 'IN', 1]] };
function fakeRows(p, k) {
  const ents = (ENT[p.level] || ENT.campaign).filter(([id]) => !(p.campaign_ids || []).length || p.level !== 'campaign' || (p.campaign_ids || []).includes(id));
  const out = [];
  for (const [id, name, spend, leads] of ents) for (const sp of (SPLITS[p.breakdown] || [[null, null, 1]])) {
    const share = sp[2] * k, dims = {};
    if (sp[0]) dims[sp[0]] = sp[1]; if (sp[3]) dims[sp[3]] = sp[4];
    out.push({ key: [id ?? 'account', ...Object.values(dims)].join('|'), label: name, id, dims, campaign_id: '7101', campaign_name: 'CPL Reels Delhi',
      spend: spend * share, impressions: 10000 * share, reach: p.breakdown === 'placement' ? 7000 * share : 6000 * share, frequency: 1.6,
      clicks: 200 * share, link_clicks: 120 * share, leads: Math.round(leads * share), video_3s: 3000 * share, p25: 2000 * share, p50: 1500 * share,
      p75: 900 * share, p100: 500 * share, thruplay: 600 * share, ...(p.level === 'ad' && !p.breakdown ? { quality: 'ABOVE_AVERAGE', engagement: 'AVERAGE', conversion: 'BELOW_AVERAGE_35' } : {}) });
  }
  return out;
}
const sum = (rows) => rows.reduce((t, r) => { for (const k of ['spend', 'impressions', 'reach', 'clicks', 'link_clicks', 'leads', 'video_3s', 'p25', 'p50', 'p75', 'p100', 'thruplay']) t[k] = (t[k] || 0) + r[k]; return t; }, {});
function fakeReport(p) {
  const rows = fakeRows(p, 1), cmp = p.compare ? fakeRows(p, 0.8) : null;
  return { params: p, currency: 'INR', rows, totals: sum(fakeRows({ ...p, breakdown: null, level: 'account' }, 1)), compare_rows: cmp,
    compare_totals: cmp ? sum(fakeRows({ ...p, breakdown: null, level: 'account' }, 0.8)) : null, truncated: false,
    disjoint: !['placement', 'platform', 'device', 'platform_device', 'hour'].includes(p.breakdown), notes: [], fetched_at: new Date().toISOString(), cached: false };
}

http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204);
  const url = new URL(req.url, 'http://x');
  if (url.pathname.startsWith('/__as/')) { sub = url.pathname.slice(6); return send(res, 200, { sub }); }
  if (url.pathname === '/__calls') return send(res, 200, calls);
  if (url.pathname.startsWith('/__schema/')) {   // test-only: pretend the database is at another ADS version
    await pool.query("UPDATE public.ads_config SET value = $1 WHERE key = 'ads_schema'", [url.pathname.slice(10)]);
    return send(res, 200, { ok: true });
  }
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
      if (jobs.includes('setup')) results.setup = { build: '2026-11-18.meta9', functions: { 'ads-sync': 'current', 'ads-intake': 'current', 'ads-meta-webhook': 'current', 'ads-agents': 'current' } };
      if (jobs.includes('meta_report')) results.meta_report = fakeReport(args.report || {});
      if (jobs.includes('meta_audiences')) {
        await pool.query("UPDATE public.ads_meta_audience SET status = 'ready', meta_id = '23850000000077', size_low = 1500, size_high = 1800, synced_at = now() WHERE key = 'form_dropoff_30'");
        await pool.query("UPDATE public.ads_config SET value = jsonb_build_object('ok', 1, 'errors', 0, 'at', now())::text WHERE key = 'meta_audiences_last'");
        results.meta_audiences = { job: 'meta_audiences', status: 'ok', items: 1, detail: '1 audience(s) up to date (UI test stub)' };
      }
      if (jobs.includes('site_signals')) {
        await pool.query("UPDATE public.ads_config SET value = jsonb_build_object('gsc_rows', 5, 'ga_rows', 4, 'notes', '[]'::jsonb, 'at', now())::text WHERE key = 'site_signals_last'");
        results.site_signals = { job: 'site_signals', status: 'ok', items: 9, detail: 'Search Console 5 rows, GA4 4 rows; Meta Pixel firing (UI test stub)' };
      }
      if (jobs.includes('meta_health')) results.meta_health = { job: 'meta_health', status: 'ok', items: 0, detail: 'Score 64; 0 warning(s) (UI test stub)' };
      if (jobs.includes('execute')) results.execute = { job: 'execute', status: 'ok', items: 0, detail: '0 change(s) processed (UI test stub)' };
      return send(res, 200, { results });
    }
    return send(res, 404, { detail: 'no such function' });
  }
  const m = /^\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(url.pathname);
  if (!m) return send(res, 404, { message: 'not found' });
  const fn = m[1]; calls.push({ fn, args });
  const keys = Object.keys(args);
  const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && (!Array.isArray(args[k]) || args[k].some((x) => x !== null && typeof x === 'object')) ? JSON.stringify(args[k])
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
