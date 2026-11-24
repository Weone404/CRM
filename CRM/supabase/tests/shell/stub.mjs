// Tiny stand-in for the Supabase server, for the CRM shell tests. Modes are switched with GET /__mode?key=value.
import http from 'node:http';
const mode = { health: 'ok', token: 'ok', leads: 'ok' };
const calls = [];
// ---- Google hub + Google My Business (139)
const gDay = (i, base) => { const d = new Date(Date.UTC(2026, 10, 21) - (base + 27 - i) * 86400000).toISOString().slice(0, 10);
  const views = 20 + ((i * 7) % 13) + (base ? 0 : 6), calls = i % 4 === 0 ? 2 : 1, website = (i % 3) + 1, directions = i % 5 === 0 ? 1 : 0, messages = i % 9 === 0 ? 1 : 0;
  return { d, views, search: Math.round(views * 0.7), maps: views - Math.round(views * 0.7), calls, website, directions, messages, actions: calls + website + directions + messages }; };
const gSum = (rows) => { const t = { views: 0, search: 0, maps: 0, calls: 0, website: 0, directions: 0, messages: 0, actions: 0 }; rows.forEach((r) => Object.keys(t).forEach((k) => { t[k] += r[k]; }));
  return { ...t, mobile: Math.round(t.views * 0.8), desktop: t.views - Math.round(t.views * 0.8), bookings: 0, days: rows.length }; };
const G_CUR = Array.from({ length: 28 }, (_, i) => gDay(i, 0)), G_PREV = Array.from({ length: 28 }, (_, i) => gDay(i, 28));
const G_LOCS = [
  { id: '11111111-1111-4111-8111-111111111111', connection_id: 'c1c1c1c1-1111-4111-8111-111111111111', title: 'We One Aviation', address: 'Dwarka, New Delhi', category: 'Flight school', phone: '+91 98110 00000', website: 'https://weoneaviation.in/', maps_uri: 'https://maps.google.com/?cid=1', verified: true, tracked: true, rating: 4.7, reviews_total: 213, synced_at: new Date().toISOString() },
  { id: '22222222-2222-4222-8222-222222222222', connection_id: 'c2c2c2c2-2222-4222-8222-222222222222', title: 'Book My Charter', address: 'Mumbai', category: 'Aircraft charter', verified: false, tracked: false, rating: null, reviews_total: null, synced_at: null }];
const G_REVIEWS = [
  { review_id: 'r1', location_id: G_LOCS[0].id, profile: 'We One Aviation', reviewer: 'Asha Verma', stars: 5, comment: 'Great faculty and honest guidance.', created_at: '2026-11-20T10:00:00Z', reply: 'Thank you, Asha.', reply_at: '2026-11-21T05:00:00Z' },
  { review_id: 'r2', location_id: G_LOCS[0].id, profile: 'We One Aviation', reviewer: 'A Google user', stars: 2, comment: '<img src=x onerror=alert(1)> Nobody picked up my call.', created_at: '2026-11-12T10:00:00Z', reply: null, reply_at: null },
  { review_id: 'r3', location_id: G_LOCS[0].id, profile: 'We One Aviation', reviewer: 'Ravi', stars: 4, comment: '', created_at: '2026-10-30T10:00:00Z', reply: null, reply_at: null }];
const gbpOverview = (args) => {
  const access = { can_view: true, can_run: true, is_admin: true };
  const empty = { access, setup: { client: true, connections: 0, connected: 0, waiting_google: false, locations: 0, tracked: 0, has_data: false }, connections: [], locations: [], selected: null,
    period: { days: 28, from: '2026-10-25', to: '2026-11-21', last_day: null }, totals: gSum([]), prev: gSum([]), days: [], prev_days: [], weekdays: [], keywords: { month: null, count: 0, rows: [] },
    reviews: { total: 0, rating: null, stored: 0, by_star: {}, unreplied: 0, new: 0, new_prev: 0, latest: [] }, runs: {} };
  if (mode.gbp === 'empty') return empty;
  const conns = [{ id: 'c1c1c1c1-1111-4111-8111-111111111111', label: 'We One Aviation', email: 'Nikhil', status: mode.gbp === 'waiting' ? 'waiting_google' : 'connected',
    error: mode.gbp === 'waiting' ? 'Google has not approved this Cloud project for the Business Profile APIs yet (the quota is 0).' : null, last_ok_at: null, checked_at: new Date().toISOString(), locations: 1, tracked: 1 },
    { id: 'c2c2c2c2-2222-4222-8222-222222222222', label: 'Book My Charter', email: null, status: 'needs_signin', error: 'Google no longer accepts this sign-in. Sign in again and save the new token.', last_ok_at: null, checked_at: null, locations: 1, tracked: 0 }];
  if (mode.gbp === 'waiting') return { ...empty, connections: conns, locations: [], setup: { client: true, connections: 2, connected: 0, waiting_google: true, locations: 0, tracked: 0, has_data: false } };
  const n = [7, 28, 90].includes(args.p_days) ? args.p_days : 28;
  const cur = G_CUR.slice(-Math.min(n, 28)), prev = n === 7 ? G_CUR.slice(-14, -7) : G_PREV;
  return { access, setup: { client: true, connections: 2, connected: 1, waiting_google: false, locations: 2, tracked: 1, has_data: true }, connections: conns, locations: G_LOCS,
    selected: args.p_location === G_LOCS[0].id ? G_LOCS[0].id : null, period: { days: n, from: cur[0].d, to: '2026-11-21', last_day: '2026-11-21' },
    totals: gSum(cur), prev: gSum(prev), days: cur, prev_days: prev,
    weekdays: [0, 1, 2, 3, 4, 5, 6].map((dow) => ({ dow, views: 90 + dow * 11, actions: 10 + dow })),
    keywords: { month: '2026-10-01', prev_month: '2026-09-01', count: 4, rows: [{ k: 'pilot training in delhi', v: 148, below: null, pv: 90 }, { k: 'dgca ground classes', v: 60, below: null, pv: 75 },
      { k: 'cpl course fees', v: 20, below: null, pv: null }, { k: 'flying school near me', v: null, below: 15, pv: null }] },
    reviews: { total: 213, rating: 4.7, stored: 3, by_star: { 1: 0, 2: 1, 3: 0, 4: 1, 5: 1 }, unreplied: 2, new: 2, new_prev: 1, latest: G_REVIEWS },
    runs: { sync: { status: 'ok', detail: 'ok', at: new Date(Date.now() - 3 * 3600000).toISOString() } } };
};


// Chart data: 28 days and the 28 before, deterministic so screenshots stay stable.
const wave = (i, a, b) => Math.round(a + b * (0.5 + 0.5 * Math.sin(i / 2.3)) + ((i * 37) % 11));
const day = (base, i) => new Date(Date.UTC(2026, base, 19 + i)).toISOString().slice(0, 10);
const TREND = {
  gsc: {
    cur: Array.from({ length: 28 }, (_, i) => { const c = wave(i, 18, 22) + Math.round(i / 3), im = 6000 + wave(i, 0, 2400) * 1; return { d: day(9, i), clicks: c, impressions: im, ctr: c / im, position: +(9.4 - i * 0.04 + ((i * 7) % 5) / 10).toFixed(1) }; }),
    prev: Array.from({ length: 28 }, (_, i) => { const c = wave(i + 4, 12, 14), im = 5200 + wave(i, 0, 1800); return { d: day(8, i + 2), clicks: c, impressions: im, ctr: c / im, position: +(9.8 + ((i * 3) % 4) / 10).toFixed(1) }; }),
  },
  ga: { cur: [], prev: [] },
  ranks: { cur: { top3: 118, p1: 402, p2: 515, p3_5: 611, beyond: 354 }, prev: { top3: 96, p1: 371, p2: 548, p3_5: 590, beyond: 402 } },
};
const MORE_Q = Array.from({ length: 60 }, (_, i) => {
  const pos = +(1 + ((i * 17) % 45) + ((i * 7) % 10) / 10).toFixed(1), im = Math.round(20 * 10 ** (((i * 29) % 30) / 10));
  const clicks = Math.max(0, Math.round(im * (pos < 4 ? 0.08 : pos < 11 ? 0.012 : 0.002)));
  return { query: `${['cpl', 'dgca', 'pilot', 'egca', 'atpl', 'ppl'][i % 6]} ${['fees', 'exam', 'course delhi', 'medical', 'syllabus', 'salary', 'eligibility', 'books', 'login', 'result'][i % 10]} ${i}`,
    clicks, impressions: im, ctr: clicks / im, pos, prev_pos: i % 5 ? +(pos + ((i % 3) - 1) * 1.5).toFixed(1) : null, brand: i % 13 === 0, pages: 1, page_list: [] };
});

// Growth > Content (migration 116): one planned week, the analyst's brief, an ad picture and results.
const wk = (() => { const d = new Date(); const w = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() - w); return d.toISOString().slice(0, 10); })();
const at = (n, hm) => `${new Date(Date.parse(`${wk}T00:00:00Z`) + n * 864e5).toISOString().slice(0, 10)}T${hm}:00+05:30`;
const CONTENT = {
  week_start: wk, can_edit: true,
  plan: { id: 1, status: 'ready', summary: 'Fees and the path after class 12 lead this week; one post for parents.', note: 'Push CPL fees',
    demand: { summary: 'People search fees and the path after 12th most.', demand: [{ topic: 'CPL cost, line by line', why: '900 searches for cpl fees in india', persona: 'parent', priority: 1,
      evidence: [{ signal: 'search', detail: 'cpl fees in india, 900 seen' }] }], questions: ['How much does CPL cost?'], objections: ['Is a loan possible?'], gaps: ['Nobody shows the cost breakdown'],
      season: [{ when: '2027-05-15', what: 'CBSE class 12 results', source: 'https://cbse.gov.in' }] } },
  items: [
    { id: 11, kind: 'reel', source: 'planner', title: 'CPL cost, line by line', slot: at(0, '13:30'), status: 'posted', brief: { hook: 'Where does ₹45 lakh actually go?', persona: 'parent', angle: 'cost', format: 'presenter_studio',
      evidence: [{ signal: 'search', detail: 'cpl fees in india, 900 seen' }], outline: ['Ground classes', 'Flying hours'] }, media: { permalink: 'https://www.instagram.com/reel/abc/' },
      stats: { views: 1200, shares: 30 }, leads: 2, link: 'https://weoneaviation.in/?utm_source=instagram&utm_medium=reel&utm_campaign=content_11' },
    { id: 12, kind: 'carousel', source: 'planner', title: 'Pilot after 12th: 6 steps', slot: at(1, '13:30'), status: 'planned', brief: { hook: 'The whole path on one swipe', evidence: [] }, stats: {}, leads: 0, link: 'x' }],
  ad_creatives: [
    { id: 31, kind: 'ad_video', source: 'studio', title: 'Myth: no science means no pilot', stage: 'made', status: 'ready', video_path: 'ad/31/video.mp4', thumb_path: 'ad/31/thumb.jpg', paths: {}, brief: { visual_brief: 'AI pilot presenter, myth vs fact' }, caption: 'x', ig: {} },
    { id: 22, kind: 'ad_video', source: 'studio', title: 'Pilot after 12th: check this first', stage: 'approved', status: 'ready', video_path: 'ad/22/video.mp4', thumb_path: 'ad/22/thumb.jpg',
      paths: {}, brief: {}, caption: '12th ke baad pilot banna hai? Free career counselling, no commitment.', approved_at: '2026-11-19T10:00:00Z', post_at: null, ig: {} },
    { id: 23, kind: 'ad_video', source: 'studio', title: 'Parents: 3 questions before fees', stage: 'posted', status: 'posted', video_path: 'ad/23/video.mp4', thumb_path: 'ad/23/thumb.jpg', paths: {}, brief: {},
      caption: 'Beta pilot banna chahta hai?', ig: { media_id: '17950000000000001', permalink: 'https://www.instagram.com/reel/abc/', posted_at: new Date(Date.now() - 2 * 864e5).toISOString(), stats: { views: 4210, likes: 186, saves: 41, comments: 9 } }, new_comments: 3 },
    { id: 24, kind: 'ad_video', source: 'studio', title: '200 hours: the right order', stage: 'results', status: 'posted', video_path: 'ad/24/video.mp4', thumb_path: 'ad/24/thumb.jpg', paths: {}, brief: {},
      strategy_id: 900, creative_key: 'v3', ig: { media_id: '17950000000000002', permalink: 'https://www.instagram.com/reel/def/', stats: {} }, results: { spend: 1840, leads: 7, cpl: 263, qualified: 3 }, new_comments: 0 },
    { id: 25, kind: 'ad_video', source: 'studio', title: 'NIOS route to CPL', stage: 'approved', status: 'ready', video_path: 'ad/25/video.mp4', thumb_path: 'ad/25/thumb.jpg', paths: {}, brief: {},
      caption: 'Arts ya Commerce? Pilot ka sapna mat chhodo.', approved_at: '2026-11-20T10:00:00Z', post_at: '2026-11-22T13:00:00Z', post_ai: true, via_studio: true, studio_state: 'scheduled', ig: { studio_state: 'scheduled' } },
    { id: 26, kind: 'ad_video', source: 'studio', title: 'Medical first', stage: 'posted', status: 'posted', video_path: 'ad/26/video.mp4', thumb_path: 'ad/26/thumb.jpg', paths: {}, brief: {}, via_studio: true,
      caption: 'Medical pehle.', ig: { media_id: '17950000000000003', via: 'studio', permalink: 'https://www.instagram.com/reel/ghi/', posted_at: new Date(Date.now() - 864e5).toISOString(), stats: { views: 777 } }, new_comments: 0 }],
  ad_slots: [{ strategy_id: 900, strategy: 'CPL admissions, Delhi NCR', approved: true, key: 'v2', name: 'Parents', format: 'video', taken: false },
             { strategy_id: 900, strategy: 'CPL admissions, Delhi NCR', approved: true, key: 'i1', name: 'Cost card', format: 'image', taken: false }],
  campaigns: [{ strategy_id: 900, title: 'CPL leads · Delhi NCR', daily_budget: 700, videos: 3, pictures: 2, learning_day: 3, campaigns: [{ id: '7001', status: 'ACTIVE' }] }],
  instagram: { user_id: '17841400000000001', username: 'we_one_aviation', checked_at: new Date().toISOString(), problem: null },
  strategies: [{ id: 900, title: 'CPL admissions, Delhi NCR', approved_version: 1 }],
  results: [{ id: 11, kind: 'reel', title: 'CPL cost, line by line', slot: at(0, '13:30'), stats: { views: 1200, shares: 30, saves: 12 }, leads: 2, permalink: 'https://www.instagram.com/reel/abc/' }],
  studio: { last_seen: new Date().toISOString(), autoplan: 'on' },
};
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
  if (u.pathname === '/functions/v1/crm-google-business') {
    let body = ''; req.on('data', (c) => { body += c; });
    return req.on('end', () => {
      const b = JSON.parse(body || '{}'); calls.push({ fn: 'edge:crm-google-business', args: b });
      return send(res, 200, { results: Object.fromEntries((b.jobs || []).map((j) => [j, { status: 'ok', detail: j === 'discover' ? 'We One Aviation: 1 profile(s) in 1 account(s)' : 'We One Aviation: 1 profile(s), 300 day-numbers' }])) });
    });
  }
  if (u.pathname === '/functions/v1/ads-sync') {
    let body = ''; req.on('data', (c) => { body += c; });
    return req.on('end', () => {
      const b = JSON.parse(body || '{}'); calls.push({ fn: 'edge:ads-sync', args: b });
      return send(res, 200, { results: Object.fromEntries((b.jobs || []).map((j) => [j, { ok: true }])) });
    });
  }
  if (u.pathname.startsWith('/storage/v1/object/sign/')) return send(res, 200, { signedURL: `/storage/v1/object/public/x?f=${encodeURIComponent(u.pathname.split('/').slice(-1)[0])}` });
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
    // Meta Ads > Overview > Budget split (129)
    if (fn === 'api_ads_meta_budget_split') return send(res, 200, { ready: true, total: 100, step: 10, min: 30, can_approve: true, items: [
      { id: '8201', name: 'India | f2', nios: false, label: 'CPL ads', daily: 70, today_spend: 41, leads_7d: 6, cpl_7d: 58, waiting: false },
      { id: '8301', name: 'India | NIOS route', nios: true, label: 'NIOS ads', daily: 30, today_spend: 17, leads_7d: 3, cpl_7d: 49, waiting: false }] });
    if (fn === 'api_ads_meta_budget_split_save') return send(res, 200, { ids: [91, 92], guard: ['A 33% change is a big edit: Meta may restart the learning phase for this ad set.'], self_approve: true });
    if (fn === 'api_ads_meta_actions') return send(res, 200, { items: [{ id: 91, status: 'done', error: null },
      { id: 92, status: 'failed', error: 'Stub: Meta refused this budget as too low for the ad set' }] });
    if (fn === 'api_vault_overview') return send(res, 200, VAULT);
    if (fn === 'api_google_hub') return send(res, 200, { website: { clicks: 807, clicks_prev: 497, impressions: 231714, visitors: null, at: new Date().toISOString() },
      ads: { spend: 847.37, clicks: 61, impressions: 2210, last_spend_day: '2026-11-15', account_status: 'connected' },
      gbp: mode.gbp === 'empty' ? { connections: 0, tracked: 0, waiting_google: false, last_day: null, totals: null, prev: null, rating: null, reviews: 0 }
        : mode.gbp === 'waiting' ? { connections: 2, tracked: 0, waiting_google: true, last_day: null, totals: null, prev: null, rating: null, reviews: 0 }
        : { connections: 2, tracked: 1, waiting_google: false, last_day: '2026-11-21', totals: gSum(G_CUR), prev: gSum(G_PREV), rating: 4.7, reviews: 213 } });
    if (fn === 'api_gbp_overview') return send(res, 200, gbpOverview(calls[calls.length - 1].args || {}));
    if (fn === 'api_gbp_reviews') { const a = calls[calls.length - 1].args || {};
      return send(res, 200, G_REVIEWS.filter((r) => (a.p_filter === 'unreplied' ? !r.reply : a.p_filter === 'low' ? r.stars <= 3 : true))); }
    if (fn === 'api_gbp_connection_add') { const a = calls[calls.length - 1].args || {};
      return /^1\/\//.test(a.p_refresh_token || '') ? send(res, 200, { id: 'c3c3c3c3-3333-4333-8333-333333333333' }) : send(res, 400, { code: 'PT422', message: 'That is not a Google refresh token (it starts with 1// and has no spaces)' }); }
    if (fn === 'api_gbp_location_track') return send(res, 200, { tracked: true });
    if (fn === 'api_gbp_connection_remove') return send(res, 200, { removed: true });
    if (fn === 'api_web_access') return send(res, 200, { can_view: true, can_run: true, is_admin: true });
    if (fn === 'api_web_overview') return send(res, 200, WEB);
    if (fn === 'api_content_overview') return send(res, 200, CONTENT);
    if (fn === 'api_content_comments') return send(res, 200, [{ id: '18000000000000001', username: 'parent_delhi', body: 'Fees kitni hai?', at: new Date().toISOString(), seen: false, hidden: false }]);
    if (fn === 'api_content_item_save') return send(res, 200, { id: 1, stage: 'approved' });
    if (fn === 'api_content_plan') return send(res, 200, { plan_id: 1 });
    if (fn === 'api_content_item_save') return send(res, 200, { id: 12 });
    if (fn === 'api_web_trend') return send(res, 200, TREND);
    if (fn === 'api_web_settings') return send(res, 200, { site_url: 'https://weoneaviation.in/', key_pages: '', psi_key: null });
    if (fn === 'api_web_queries') return send(res, 200, { total: 2, rows: [
      { query: 'egca login', clicks: 10, impressions: 13778, ctr: 0.0007, pos: 8.7, prev_clicks: 3, prev_impressions: 9000, prev_pos: 9.2, almost: true, pages: 2,
        page_list: [{ page: 'https://weoneaviation.in/egca', impressions: 9000, position: 8 }, { page: 'https://weoneaviation.in/blogs/egca-login', impressions: 4000, position: 12 }] },
      { query: 'spl full form', clicks: 2, impressions: 2570, ctr: 0.0008, pos: 9.1, prev_pos: null, almost: true, pages: 1, page_list: [] }, ...(calls[calls.length - 1]?.args?.p_filter === 'almost' ? [] : MORE_Q)] });
    if (fn === 'api_web_copilot_upload') return send(res, 200, { saved: 2 });
    if (fn === 'api_connection_token') return send(res, 200, 'full-charter-token-xyz');
    if (/_save$|_set$|_delete$|_remove$|_rotate$|_toggle$/.test(fn)) return send(res, 200, { saved: true, removed: true, last4: 'new1' });
    if (fn === 'api_leads') return mode.leads === 'down' ? req.socket.destroy() : send(res, 200, LEADS);
    if (fn === 'api_followups_pending') return mode.leads === 'down' ? req.socket.destroy() : send(res, 200, []);
    if (fn === 'api_ads_access') return send(res, 200, { can_view: true, can_edit: true, can_approve: true, is_admin: true, role: 'admin' });
    if (fn === 'api_ads_meta_live') return send(res, 200, { live: true, numbers_at: new Date(Date.now() - 6 * 60000).toISOString(),
      wallet: { available: 479.79, prepaid: 566.13, cap_left: 479.79, account: '564511644492586', daily_budget: 100, days_left: 4, low: false, checked_at: new Date(Date.now() - 5 * 60000).toISOString() },
      campaigns: [{ id: '7101', name: 'CPL leads Delhi NCR', status: 'ACTIVE', budget_total: 3000, horizon_days: 30, day: 3, used: 312, today: 104, meta_leads: 6, qualified: 2, cpl: 52,
        ads: [{ id: '9101', name: 'Pilot after 12th', status: 'ACTIVE', spend: 180, impressions: 4120, leads: 4, post: 'https://www.instagram.com/reel/A1/' },
              { id: '9102', name: 'Parents: 3 questions', status: 'ACTIVE', spend: 132, impressions: 2960, leads: 2 }],
        latest: [{ name: 'Rohit S', answers: [{ q: 'who_is_filling_this_form?', a: 'student_(18+)' }, { q: 'when?', a: 'in_1-3_months' }], wait_min: 12, called_at: null },
                 { name: 'Meena K', answers: [{ q: 'who', a: 'parent_/_guardian' }], wait_min: 4, called_at: new Date().toISOString() }] }] });
    if (fn === 'api_ads_lead_alerts') return send(res, 200, { waiting: [], settings: { on: true, minutes: 5, escalate_minutes: 15, from: '09:00', to: '20:00', phones: 1, email_ready: true }, median_first_call_min_30d: 4 });
    if (fn === 'api_ads_meta_settings') return send(res, 200, { sources: [], config: { webhook_last_at: null, execution_paused: false } });
    if (fn === 'api_ads_campaigns') return send(res, 200, [
      { id: 'c1', platform: 'meta', name: 'WOA Leads CPL Nov26', client: 'We One', account: 'A', status: 'ENABLED', spend: 312, currency: 'INR', crm: {}, account_status: 'connected', synced_at: new Date().toISOString() },
      { id: 'c2', platform: 'meta', name: 'Parents test Dec', client: 'We One', account: 'A', status: 'ENABLED', spend: 0, currency: 'INR', crm: {}, account_status: 'connected' },
      { id: 'c3', platform: 'meta', name: 'WhatsApp 2023', client: 'We One', account: 'A', status: 'PAUSED', spend: 0, currency: 'INR', crm: {}, account_status: 'connected' },
      { id: 'c4', platform: 'meta', name: 'Engagement 2024', client: 'We One', account: 'A', status: 'PAUSED', spend: 0, currency: 'INR', crm: {}, account_status: 'connected' }]);
    if (fn === 'api_ads_lead_board') return send(res, 200, { role: 'admin', stats: { total: 2, new_today: 1, not_contacted: 1, quarantined: 0, qualified_month: 0, customers_month: 0, nios: 1 },
      stages: [{ stage: 'lead_created', label: 'New' }, { stage: 'contacted', label: 'Contacted' }],
      rows: calls[calls.length - 1]?.args?.p_limit === 1 ? [] : [
        { id: 'al1', name: 'Minali Sawhney', phone_e164: '+919812345678', stage: 'lead_created', created_at: new Date(Date.now() - 40 * 60000).toISOString(), platforms: ['meta'], app: 'Instagram',
          ad_name: 'Pilot after 12th: check this before paying fees', first_touch: { ad_id: '9101' },
          answers: [{ q: 'City', a: 'Delhi' }, { q: 'Who is filling this form?', a: 'Parent / guardian' }, { q: 'Class 12 status?', a: 'Passed with Physics & Maths' }, { q: 'When do you want to start?', a: 'Within 1 month' }, { q: 'How do you plan to fund the training?', a: 'Family + education loan' }] },
        { id: 'al2', name: 'Raj', phone_e164: '+919811111111', stage: 'contacted', first_response_at: new Date().toISOString(), created_at: new Date(Date.now() - 26 * 3600000).toISOString(), platforms: ['meta'], app: 'Instagram', owner_name: 'Asha',
          ad_name: 'Parents: 3 questions before paying pilot training fees', track: 'nios', answers: [{ q: 'Who is filling this form?', a: 'Student (18+)' }, { q: 'Class 12 status?', a: 'Passed with other subjects' }] }]
        .filter((r) => !calls[calls.length - 1]?.args?.p_track || r.track === calls[calls.length - 1].args.p_track) });
    if (fn === 'api_ads_staff') return send(res, 200, []);
    if (fn === 'api_ads_meta_action_request') return send(res, 200, { id: 77, guard: [], self_approve: true });
    if (fn === 'api_amz_access') return send(res, 200, { can_view: false });
    return send(res, 200, []);
  }
  if (u.pathname.startsWith('/rest/v1/')) return send(res, 200, []);
  if (u.pathname === '/auth/v1/user') return send(res, 200, { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'a@b.c' });
  send(res, 404, { message: 'not stubbed', path: u.pathname });
}).listen(54398, () => console.log('stub on 54398'));
