// Headless checks for the CRM shell: grouped sidebar, signal indicator, Home numbers, section error guard,
// request time limits, offline handling and sign-in renewal. Prints PASS/FAIL lines.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');
const APP = 'http://localhost:5198/';
const STUB = 'http://localhost:54398';
let failed = 0;
const ok = (cond, name) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`); if (!cond) failed++; };
const mode = (q) => fetch(`${STUB}/__mode?${q}`);

const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME, args: ['--no-sandbox'] } : {});
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
const page = await ctx.newPage();
const errors = [];
let expectNetErrors = false;   // during the 'server unreachable' renewal test, supabase-js logs the failed fetch itself
page.on('console', (m) => { if (m.type() === 'error' && !/boom|section crashed|Failed to load resource|The above error/.test(m.text()) && !(expectNetErrors && /Failed to fetch/.test(m.text()))) errors.push(m.text()); });
page.on('pageerror', (e) => { if (!/boom/.test(String(e))) errors.push(String(e)); });
let internetUp = true;
await page.route('https://www.gstatic.com/generate_204', (r) => (internetUp ? r.fulfill({ status: 204, body: '' }) : r.abort()));
await mode('health=ok&token=ok');
await page.goto(APP);
await page.getByText('Needs your attention').waitFor({ timeout: 20000 });
const body = async () => { await page.waitForTimeout(300); return page.locator('body').innerText(); };
const pill = () => page.getByRole('button', { name: /^Connection:/ });

// Sidebar
const nav = page.getByRole('navigation', { name: 'Main' });
const navText = await nav.innerText();
ok(/PEOPLE[\s\S]*GROWTH[\s\S]*SETUP/i.test(navText), 'S01 sidebar shows People, Growth, Setup in order');
ok(/Settings[\s\S]*Brand new/.test(navText), 'S01b an unknown section is still listed (at the end), never hidden');
ok(await nav.getByRole('button', { name: /^Home/ }).getAttribute('aria-current') === 'page', 'S02 active section is marked aria-current');
ok(await nav.getByText('1', { exact: true }).count() === 1, 'S02b Leads shows its attention badge');
await nav.getByRole('button', { name: /^Leads/ }).click();
ok((await page.locator('#active').innerText()) === 'leads', 'S02c clicking a sidebar item opens it');
await nav.getByRole('button', { name: /^Home/ }).click();

// Section error guard
await page.locator('#crash').click();
let b = await body();
ok(/Test section hit a problem/.test(b) && (await nav.count()) === 1, 'S03 a crashing section shows a calm message; sidebar keeps working');
await nav.getByRole('button', { name: /^Tasks/ }).click(); await nav.getByRole('button', { name: /^Home/ }).click();
ok(!/hit a problem/.test(await body()), 'S03b switching section clears the error');

// Home numbers (pure) and screen
const n = await page.evaluate(() => window.__t.homeNumbers(window.__t.LEADS, [{ id: 'f' }]));
ok(n.week === 3 && n.prevWeek === 1 && n.notContacted === 1 && n.followupsDue === 1 && n.recentTotal === 5, 'S04 Home counts: week 3, last week 1, not contacted 1, follow-ups 1, 28-day 5');
ok(n.statuses[0].name === 'Not reachable' && n.statuses[0].n === 3 && n.sources[0].name === 'website' && n.sources[0].n === 4, 'S04b statuses and sources are tallied and sorted');
b = await body();
ok(/Leads this week\s*3\s*↑ 2 vs last week \(1\)/.test(b), 'S05 Leads this week with change vs last week');
ok(/1 lead not contacted yet/.test(b) && /1 follow-up is due/.test(b), 'S05b needs-attention lists uncontacted leads and due follow-ups');
ok(/GA4 is connected but sends no visitor data/.test(b) && /no Pixel yet/.test(b), 'S05c needs-attention lists GA4-no-data and missing Pixel');
ok(/Google clicks · 28 days\s*807\s*↑ 62% vs previous 28 days/.test(b), 'S05d Google clicks with 28-day change');
ok(!/spl full form/.test(b), 'S05e website details stay folded until opened');
await page.getByText('Website at a glance').click();
ok(/spl full form/.test(await body()), 'S05f opening the fold shows rising searches');

// Signal indicator
await page.evaluate(async () => { window.__t.net._reset(); await window.__t.net.checkNow(); });
await page.waitForTimeout(200);
ok(/Fast|Connected/.test(await pill().innerText()), 'S06 healthy server: green signal');
await mode('health=slow');
await page.evaluate(async () => { window.__t.net._reset(); for (let i = 0; i < 3; i++) await window.__t.net.checkNow(); });
ok(/Slow/.test(await pill().innerText()), 'S06b slow server (1.6 s): amber "Slow"');
await mode('health=down');
await page.evaluate(async () => { for (let i = 0; i < 2; i++) await window.__t.net.checkNow(); });
await page.waitForTimeout(400);
ok(/CRM not responding/.test(await pill().innerText()), 'S07 server failing while internet works: "CRM not responding"');
await pill().click();
b = await body();
ok(/Your internet works, but the CRM server is not answering/.test(b) && /CRM server\s*Not responding/.test(b) && /Check again/.test(b), 'S07b details say whose problem it is');
await page.keyboard.press('Escape');
internetUp = false;
await page.evaluate(async () => { window.__t.net._reset(); for (let i = 0; i < 2; i++) await window.__t.net.checkNow(); });
await page.waitForTimeout(600);
ok(/Offline/.test(await pill().innerText()), 'S07c server and internet both failing: "Offline"');
internetUp = true;
await mode('health=ok');
await page.evaluate(async () => { window.__t.net._reset(); await window.__t.net.checkNow(); });
await page.waitForTimeout(200);
ok(/Fast|Connected/.test(await pill().innerText()), 'S07d recovers to green on its own');
await ctx.setOffline(true); await page.waitForTimeout(300);
ok(/Offline/.test(await pill().innerText()), 'S08 browser goes offline: "Offline" immediately');

// Offline must not mean "signed out"
const offlineAns = await page.evaluate(async () => { const r = await window.__t.handleApiRequest('GET', '/api/leads', new URLSearchParams(), null); return [r.status, (await r.json()).detail]; });
ok(offlineAns[0] === 503 && /internet/.test(offlineAns[1]), 'S11 offline: API answers 503 "check your internet", not 401 (no forced logout)');
await ctx.setOffline(false); await page.waitForTimeout(300);
const signedOut = await page.evaluate(async () => (await window.__t.handleApiRequest('GET', '/api/leads', new URLSearchParams(), null)).status);
ok(signedOut === 401, 'S11b online with no session: still 401 (real sign-out unchanged)');

// Time limits
const t = await page.evaluate(async () => {
  window.__t.LIMITS.db = 800; const s = performance.now();
  try { await window.__t.timedFetch('http://localhost:54398/rest/v1/rpc/slow', { method: 'POST' }); return ['answered', 0]; }
  catch (e) { return [e.name, Math.round(performance.now() - s)]; } finally { window.__t.LIMITS.db = 25000; }
});
ok(t[0] === 'TimeoutError' && t[1] < 2000, `S09 a hung request ends with a clear time-out (${t[1]} ms) instead of spinning forever`);
const ab = await page.evaluate(async () => {
  const c = new AbortController(); setTimeout(() => c.abort(), 100);
  try { await window.__t.timedFetch('http://localhost:54398/rest/v1/rpc/slow', { method: 'POST', signal: c.signal }); return 'answered'; } catch (e) { return e.name; }
});
ok(ab === 'AbortError', 'S10 a screen can still cancel its own request');
const rpcDown = await page.evaluate(async () => {
  window.__t.LIMITS.db = 500;
  try { const r = await window.__t.supabase.rpc('slow'); return [r.status, r.error?.message || '']; } finally { window.__t.LIMITS.db = 25000; }
});
ok(rpcDown[0] === 0 && /long|Timeout|abort/i.test(rpcDown[1]), 'S10b database call over the limit returns an error (status 0) the app can show');

// Sign-in renewal before logout
const renew = async (m) => { await mode(`token=${m}`); return page.evaluate(async () => { window.__t._resetRenew(); return window.__t.renewSession(window.__t.supabase, 'r1'); }); };
ok(await renew('ok') === 'ok', 'S12 expired sign-in that renews: stays signed in, request retried');
ok(await renew('bad') === 'none', 'S12b refresh token rejected: really signed out');
expectNetErrors = true;
ok(await renew('down') === 'offline', 'S12c server unreachable during renewal: kept signed in (no logout)');
// supabase-js keeps retrying that refresh in the background for a while, so its fetch errors stay expected.
const shared = await page.evaluate(async () => { window.__t._resetRenew(); const a = window.__t.renewSession(window.__t.supabase, 'r1'); const b2 = window.__t.renewSession(window.__t.supabase, 'r1'); return a === b2; });
ok(shared, 'S12d many failing screens share one renewal');

// Phone width: sidebar hidden (bottom bar takes over in the app)
await page.setViewportSize({ width: 390, height: 844 });
ok(!(await nav.isVisible()), 'S13 sidebar hides on phones');
ok(/Leads this week/.test(await body()), 'S13b Home still readable at phone width');
ok(errors.length === 0, `S14 no unexpected console errors${errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''}`);
await browser.close();
console.log(failed ? `\n${failed} FAILED` : '\nALL PASSED');
process.exit(failed ? 1 : 0);
