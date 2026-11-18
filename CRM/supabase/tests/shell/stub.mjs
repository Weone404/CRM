// Tiny stand-in for the Supabase server, for the CRM shell tests. Modes are switched with GET /__mode?key=value.
import http from 'node:http';
const mode = { health: 'ok', token: 'ok', leads: 'ok' };
const DAY = 86400000;
const ago = (d) => new Date(Date.now() - d * DAY).toISOString();
const LEADS = [
  { id: '00000000-0000-0000-0000-000000000001', name: 'Test Lead One', phone: '9000000001', status: 'new', utm_source: 'website', created_at: ago(0.2), first_contacted_at: null },
  { id: '00000000-0000-0000-0000-000000000002', name: 'Test Lead Two', phone: '9000000002', status: 'Interested', utm_source: 'website', created_at: ago(2), first_contacted_at: ago(1) },
];
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = () => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}.sig`;
const send = (res, status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/__mode') { for (const [k, v] of u.searchParams) mode[k] = v; return send(res, 200, mode); }
  if (u.pathname === '/auth/v1/health') {
    if (mode.health === 'down') return send(res, 503, { msg: 'down' });
    if (mode.health === 'hang') return;                       // never answers
    const wait = mode.health === 'slow' ? 1600 : 5;
    return setTimeout(() => send(res, 200, { name: 'GoTrue' }), wait);
  }
  if (u.pathname === '/auth/v1/token') {
    if (mode.token === 'down') return req.socket.destroy();
    if (mode.token === 'bad') return send(res, 400, { error: 'invalid_grant', error_description: 'Refresh Token Not Found' });
    return send(res, 200, { access_token: jwt(), refresh_token: 'r2', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, token_type: 'bearer', user: { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'a@b.c' } });
  }
  if (u.pathname === '/rest/v1/rpc/slow') return setTimeout(() => send(res, 200, 1), 3000);
  if (u.pathname === '/rest/v1/rpc/api_ads_site_signals') {
    return send(res, 200, { configured: { gsc: true, ga4: true }, last: { ga_rows: 0, gsc_rows: 2400 }, pixel: { id: null, firing: false },
      totals: { clicks: 807, clicks_prev: 497, impressions: 231714, queries: 1000 }, rising: [{ query: 'spl full form', impressions: 2570, clicks: 2, position: 9.1 }] });
  }
  const rpc = /^\/rest\/v1\/rpc\/(\w+)$/.exec(u.pathname);
  if (rpc) {
    const fn = rpc[1];
    if (fn === 'api_leads') return mode.leads === 'down' ? req.socket.destroy() : send(res, 200, LEADS);
    if (fn === 'api_followups_pending') return mode.leads === 'down' ? req.socket.destroy() : send(res, 200, []);
    if (fn === 'api_ads_access') return send(res, 200, { can_view: true, can_edit: true, role: 'admin' });
    if (fn === 'api_amz_access') return send(res, 200, { can_view: false });
    return send(res, 200, []);
  }
  if (u.pathname.startsWith('/rest/v1/')) return send(res, 200, []);
  if (u.pathname === '/auth/v1/user') return send(res, 200, { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'a@b.c' });
  send(res, 404, { message: 'not stubbed', path: u.pathname });
}).listen(54398, () => console.log('stub on 54398'));
