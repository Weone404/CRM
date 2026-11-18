// The real CRM app (main.jsx + App.jsx) against the stub server: new layout, Home as the start page,
// and "keep showing data when a refresh fails" instead of an error wall or a logout.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');
const APP = 'http://localhost:5198/app.html';
const STUB = 'http://localhost:54398';
let failed = 0;
const ok = (cond, name) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`); if (!cond) failed++; };
const mode = (q) => fetch(`${STUB}/__mode?${q}`);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = `${b64({ alg: 'HS256' })}.${b64({ sub: 'u1', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}.sig`;
const session = { access_token: jwt, refresh_token: 'r1', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, token_type: 'bearer', user: { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'a@b.c' } };

const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME, args: ['--no-sandbox'] } : {});
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
await ctx.addInitScript(([s]) => {
  if (sessionStorage.getItem('seeded')) return;
  sessionStorage.setItem('seeded', '1');
  localStorage.setItem('token', 'employee-token');
  localStorage.setItem('employee', JSON.stringify({ id: 'e1', name: 'Test Admin', department: 'Admin' }));
  localStorage.setItem('weone-crm-auth', JSON.stringify(s));
}, [session]);
await ctx.route('https://www.gstatic.com/generate_204', (r) => r.fulfill({ status: 204, body: '' }));
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
await mode('health=ok&token=ok&leads=ok');
await page.goto(APP);
await page.getByText('Needs your attention').waitFor({ timeout: 30000 });
const body = async () => { await page.waitForTimeout(400); return page.locator('body').innerText(); };
const nav = page.getByRole('navigation', { name: 'Main' });

let b = await body();
ok(/Good (morning|afternoon|evening), Test/.test(b), 'A01 Home is the start page');
ok(await nav.isVisible() && /PEOPLE[\s\S]*GROWTH[\s\S]*SETUP/i.test(await nav.innerText()), 'A02 grouped sidebar on a laptop');
ok(/1 lead not contacted yet/.test(b), 'A03 Home counts the live leads (1 not contacted)');
ok(await page.getByRole('button', { name: /^Connection:/ }).count() === 1, 'A04 signal indicator in the top bar');
await nav.getByRole('button', { name: /^Leads/ }).click();
await page.getByText('Test Lead Two').waitFor({ timeout: 10000 });
ok(page.url().endsWith('#/leads'), 'A05 sidebar opens Leads at its own address');

// A refresh that fails keeps the list on screen and says so, instead of an error wall
await mode('leads=down');
await page.getByRole('button', { name: /^Sync$/ }).click();
await page.getByText(/Couldn't refresh\. Showing leads from/).waitFor({ timeout: 15000 });
b = await body();
ok(/Test Lead Two/.test(b) && !/Couldn't load leads/.test(b), 'A06 failed refresh: leads stay visible with a quiet "showing saved data" note');
ok(await page.evaluate(() => !!localStorage.getItem('token')), 'A07 a failed refresh never signs the person out');
await mode('leads=ok');
await page.getByRole('button', { name: 'Retry now' }).click();
await page.waitForTimeout(1500);
ok(!/Couldn't refresh/.test(await body()), 'A08 retry succeeds: the note disappears');

// Offline: still signed in, data still visible
await ctx.setOffline(true);
await page.getByRole('button', { name: /^Sync$/ }).click(); await page.waitForTimeout(1200);
b = await body();
ok(/Test Lead Two/.test(b) && await page.evaluate(() => !!localStorage.getItem('token')), 'A09 offline: data stays, no logout');
ok(/Offline/.test(await page.getByRole('button', { name: /^Connection:/ }).innerText()), 'A09b signal shows Offline');
await ctx.setOffline(false); await page.waitForTimeout(1500);

// Old "Academy" links still work
await page.goto(`${APP}#/academy`); await page.waitForTimeout(1200);
ok(/#\/academy$/.test(page.url()) && await nav.getByRole('button', { name: /^Students/ }).getAttribute('aria-current') === 'page', 'A10 old #/academy link opens a People screen');

// Phone: bottom bar with Home first, grouped More sheet
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${APP}#/home`); await page.waitForTimeout(1000);
const bar = page.getByRole('navigation', { name: 'Sections' });
ok(await bar.isVisible() && /^Home/.test((await bar.innerText()).trim()), 'A11 phone: bottom bar starts with Home');
await bar.getByRole('button', { name: 'More' }).click();
const sheet = page.getByRole('dialog', { name: 'More' });
ok(/GROWTH|SETUP/i.test(await sheet.innerText()), 'A12 phone: More sheet is grouped');
ok(errors.length === 0, `A13 no page errors${errors.length ? ': ' + errors.slice(0, 2).join(' | ') : ''}`);
await browser.close();
console.log(failed ? `\n${failed} FAILED` : '\nALL PASSED');
process.exit(failed ? 1 : 0);
