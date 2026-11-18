// Tiny stand-in for the Supabase server, for the CRM shell tests. Modes are switched with GET /__mode?key=value.
import http from 'node:http';
const mode = { health: 'ok', token: 'ok', leads: 'ok' };
const calls = [];
const VAULT = {
  ads: { GOOGLE_ADS_CLIENT_ID: { set: true, last4: '.com', value: '820644-abc.apps.googleusercontent.com', updated_at: new Date().toISOString() },
         GOOGLE_ADS_CLIENT_SECRET: { set: true, last4: 'Xy12' }, GOOGLE_ADS_DEVELOPER_TOKEN: { set: false }, GOOGLE_ADS_REFRESH_TOKEN: { set: true, last4: 'ab34' },
         GOOGLE_ADS_LOGIN_CUSTOMER_ID: { set: false }, GOOGLE_SITE_REFRESH_TOKEN: { set: true, last4: 'si77' },
         META_APP_ID: { set: true, last4: '4321', value: '1234567894321' }, META_APP_SECRET: { set: true, last4: 'ms11' },
         META_ACCESS_TOKEN: { set: true, last4: '9876' }, META_PAGE_TOKEN: { set: false }, META_WEBHOOK_VERIFY_TOKEN: { set: true, last4: 'wv00' } },
  ads_status: { tests: { test_google: { status: 'ok', at: new Date().toISOString() }, test_meta: { status: 'ok', at: new Date().toISOString() } },
    site: { gsc_url: 'sc-domain:weoneaviation.in', ga4_property: '430628737', last: { ga_rows: 0, gsc_rows: 2400 }, pixel: { id: null, firing: false } } },
  amz: { AMZ_LWA_CLIENT_ID: { set: true, last4: 'c1d2', value: 'amzn1.application-oa2-client.c1d2' }, AMZ_LWA_CLIENT_SECRET: { set: true, last4: 'zz99' },
         AMZ_REFRESH_TOKEN: { set: true, last4: 'rt55' }, AMZ_SELLER_ID: { set: true, last4: 'ER42', value: 'A1SELLER42' }, ADS_CLIENT_ID: { set: false },
         ADS_CLIENT_SECRET: { set: false }, ADS_REFRESH_TOKEN: { set: false }, ADS_PROFILE_ID: { set: false }, PEXELS_API_KEY: { set: true, last4: 'px01' } },
  amz_status: { last_test: { status: 'ok', at: new Date().toISOString() }, rotated_on: new Date().toISOString().slice(0, 10), smtp: { host: 'mail.x.com', port: 465, username: 'a@x.com', enabled: true }, smtp_password: { set: true, last4: 'pw88' } },
  ai: [{ provider: 'groq', last4: 'Gq12', enabled: true }], fb: [{ name: 'tavily_api_key', last4: 'tv99', last_test_ok: true, last_test_message: 'OK' }],
  inbound: { charter: { set: true, last4: 'abcd' }, hikvision: { set: true, last4: 'hk11' }, partner: { set: false } },
  activity: [{ at: new Date().toISOString(), who: 'Test Admin', action: 'secret_saved', what: 'META_ACCESS_TOKEN', area: 'ads' }],
};
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
  if (u.pathname === '/__calls') return send(res, 200, calls);
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
    let body = ''; req.on('data', (c) => { body += c; });
    return req.on('end', () => {
      try { calls.push({ fn, args: body ? JSON.parse(body) : {} }); } catch { calls.push({ fn, args: body }); }
      answer(fn);
    });
  }
  function answer(fn) {
    if (fn === 'api_vault_overview') return send(res, 200, VAULT);
    if (fn === 'api_connection_token') return send(res, 200, 'full-charter-token-xyz');
    if (/_save$|_set$|_delete$|_remove$|_rotate$|_toggle$/.test(fn)) return send(res, 200, { saved: true, removed: true, last4: 'new1' });
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
