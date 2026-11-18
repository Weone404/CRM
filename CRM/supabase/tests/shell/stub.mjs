// Tiny stand-in for the Supabase server, for the CRM shell tests. Modes are switched with GET /__mode?key=value.
import http from 'node:http';
const mode = { health: 'ok', token: 'ok', leads: 'ok' };
const calls = [];
const WEB = {
  site: 'https://weoneaviation.in/', configured: { gsc: true, ga4: true },
  runs: { search: { status: 'ok', at: new Date().toISOString() }, visitors: { status: 'ok', detail: 'GA4 answered with no visits', at: new Date().toISOString() } },
  search: {
    cur: { clicks: 807, impressions: 231714, ctr: 0.0035, position: 8.3, days: 28 }, prev: { clicks: 497, impressions: 193096, position: 8.9, days: 28 },
    daily: [{ d: '2026-11-01', clicks: 20, impressions: 7000 }, { d: '2026-11-02', clicks: 35, impressions: 9000 }],
    devices: [{ k: 'MOBILE', clicks: 700, impressions: 200000, position: 8 }], countries: [{ k: 'ind', clicks: 790, impressions: 220000 }], appearance: [],
    counts: { queries: 1000, almost: 11, low_ctr: 4, dropping: 134, new: 529, questions: 80, brand_clicks: 21, nonbrand_clicks: 786, cannibal: 3 },
    examples: { almost: [{ query: 'egca login', impressions: 13778, pos: 8.7 }], low_ctr: [], dropping: [], new: [], cannibal: [] },
    top_queries: [{ query: 'dgca pariksha', clicks: 121, impressions: 47530, ctr: 0.0025, pos: 3.8, prev_clicks: 51, prev_pos: 5.1, brand: false },
      { query: 'cpl full form', clicks: 33, impressions: 4404, ctr: 0.0075, pos: 2.5, prev_clicks: 22, prev_pos: 4.8, brand: false }],
    top_pages: [{ page: 'https://weoneaviation.in/dgca-pariksha', clicks: 185, impressions: 93208, pos: 4.6, prev_clicks: 70, prev_pos: 5.9 }] },
  visitors: { cur: { days: 0 }, prev: { days: 0 }, daily: [], channels: [], sources: [], devices: [], newret: {}, cities: [], busiest: [], landing: [], events: [] },
  ai: { tools: [{ tool: 'ChatGPT', sessions: 9, prev_sessions: 3, key_events: 1 }], pages: [{ page: '/cpl', sessions: 6, tools: 'ChatGPT' }],
    copilot: { queries: [], pages: [], uploaded_at: null, total: 0 }, robots: { bots: { GPTBot: 'blocked', ClaudeBot: 'allowed' } }, llms: { status: 'missing' },
    schema: { pages: 92, with_schema: 80, types: ['Organization', 'FAQPage'] } },
  speed: [{ url: 'https://weoneaviation.in/', strategy: 'mobile', overall: 'slow', scores: { performance: 41 }, field: { lcp: { p75: 4100, rating: 'slow' }, inp: { p75: 180 }, cls: { p75: 0.05 } }, fixes: [{ title: 'Reduce unused JavaScript', saves_ms: 900 }] },
    { url: 'https://weoneaviation.in/', strategy: 'desktop', overall: 'fast', scores: { performance: 92 }, field: {} }],
  health: { home: { status: 200, ms: 380 }, sitemaps: { list: [{ path: 'https://weoneaviation.in/sitemap.xml', submitted: 92, errors: 0 }] },
    index: [{ url: 'https://weoneaviation.in/', verdict: 'PASS', coverage: 'Submitted and indexed', last_crawl: new Date().toISOString(), rich: { types: ['FAQ'] } }],
    scan: { pages: 92, ok: 91, errors: 1, slow: 2, avg_ms: 600, scanned_at: new Date().toISOString(), issues: { long_title: 12, no_schema: 12 },
      broken: [{ url: 'https://weoneaviation.in/old', status: 404, on_pages: 3, example: 'https://weoneaviation.in/' }], pages_with_issues: [{ url: 'https://weoneaviation.in/x', status: 200, issues: ['long_title'] }] } },
  leads: { cur: 23, prev: 18, admissions: 1, by_source: [{ source: 'website', n: 20 }, { source: 'Book My Charter website', n: 3 }], weekly: [{ week: '2026-11-09', n: 6 }] },
  actions: [
    { p: 100, area: 'setup', title: 'GA4 sends no visitor data', detail: 'Check the property.', go: 'connections' },
    { p: 90, area: 'ai', title: 'robots.txt blocks 1 search or AI answer crawler(s)', detail: 'x', go: 'ai' },
    { p: 85, area: 'health', title: 'Fix 1 broken link(s) on the site', detail: 'x', go: 'health' },
    { p: 80, area: 'speed', title: 'Speed up 1 page(s) on mobile', detail: 'x', go: 'speed' },
    { p: 74, area: 'search', title: 'Push "egca login" onto page 1', detail: 'x', go: 'searches', q: 'egca login' },
    { p: 69, area: 'search', title: 'Rewrite the title for "pariksha dgca"', detail: 'x', go: 'searches', q: 'pariksha dgca' }],
};
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
  if (u.pathname === '/functions/v1/crm-website') {
    let body = ''; req.on('data', (c) => { body += c; });
    return req.on('end', () => {
      const b = JSON.parse(body || '{}'); calls.push({ fn: 'edge:crm-website', args: b });
      if ((b.jobs || []).length === 1 && b.jobs[0] === 'live') return send(res, 200, { live: { total: [{ k: 'total', users: 3 }], page: [{ k: 'CPL Course', users: 2 }] } });
      return send(res, 200, { results: Object.fromEntries((b.jobs || []).map((j) => [j, { status: 'ok', detail: `${j} done` }])) });
    });
  }
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
    if (fn === 'api_web_access') return send(res, 200, { can_view: true, can_run: true, is_admin: true });
    if (fn === 'api_web_overview') return send(res, 200, WEB);
    if (fn === 'api_web_settings') return send(res, 200, { site_url: 'https://weoneaviation.in/', key_pages: '', psi_key: null });
    if (fn === 'api_web_queries') return send(res, 200, { total: 2, rows: [
      { query: 'egca login', clicks: 10, impressions: 13778, ctr: 0.0007, pos: 8.7, prev_clicks: 3, prev_impressions: 9000, prev_pos: 9.2, almost: true, pages: 2,
        page_list: [{ page: 'https://weoneaviation.in/egca', impressions: 9000, position: 8 }, { page: 'https://weoneaviation.in/blogs/egca-login', impressions: 4000, position: 12 }] },
      { query: 'spl full form', clicks: 2, impressions: 2570, ctr: 0.0008, pos: 9.1, prev_pos: null, almost: true, pages: 1, page_list: [] }] });
    if (fn === 'api_web_copilot_upload') return send(res, 200, { saved: 2 });
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
