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
await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: 'http://localhost:5198' });
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


// Connections & keys (Phase 2)
const calls = async () => (await fetch(`${STUB}/__calls`)).json();
const clip = () => page.evaluate(() => navigator.clipboard.readText());
await nav.getByRole('button', { name: /^Connections & keys/ }).click();
await page.getByRole('heading', { name: 'Connections & keys' }).waitFor({ timeout: 15000 });
b = await body();
ok(/SETUP[\s\S]*Connections & keys/i.test(await nav.innerText()) && page.url().endsWith('#/connections'), 'V01 Connections & keys sits under Setup with its own address');
ok(/Google, Meta need attention/.test(b), 'V02 banner names the groups that need attention (GA4 no data, no Pixel)');
const google = page.locator('[data-group="google"]');
ok(/820644-abc\.apps\.googleusercontent\.com/.test(await google.innerText()) && /•••• ab34/.test(await google.innerText()), 'V03 IDs in full, secrets as •••• + last 4');
ok(!/EAA|secret-value/.test(b), 'V03b no secret value on the page');
ok(/Connected but returns no visitor data/.test(await google.innerText()), 'V03c GA4 row explains the problem');
ok(!(await page.locator('[data-group="amazon"] [data-item]').count()), 'V03d healthy groups stay folded');
await page.locator('[data-item="ads:GOOGLE_ADS_CLIENT_ID"]').getByRole('button', { name: 'Copy' }).click();
ok(await clip() === '820644-abc.apps.googleusercontent.com', 'V04 Copy puts the full ID on the clipboard');
const tok = page.locator('[data-item="ads:META_ACCESS_TOKEN"]');
await tok.getByRole('button', { name: 'Replace' }).click();
ok(await tok.locator('input').getAttribute('type') === 'password', 'V05 new secret is typed into a hidden field');
await tok.locator('input').fill('EAAnewTokenValue1234');
await tok.getByRole('button', { name: 'Save' }).click(); await page.waitForTimeout(800);
let c = await calls();
ok(c.some((x) => x.fn === 'api_ads_settings_save' && x.args.p_name === 'META_ACCESS_TOKEN' && x.args.p_value === 'EAAnewTokenValue1234'), 'V05b saved through the ADS module’s own function');
ok(!(await tok.locator('input').count()) && !/EAAnewTokenValue1234/.test(await body()), 'V05c after saving, the value is gone from the screen');
await page.locator('[data-group="amazon"] > button').click();
await page.locator('[data-item="amz:PEXELS_API_KEY"]').getByRole('button', { name: 'Remove' }).click();
await page.getByRole('alertdialog').getByRole('button', { name: 'Remove' }).click(); await page.waitForTimeout(800);
c = await calls();
ok(c.some((x) => x.fn === 'api_vault_amz_remove' && x.args.p_name === 'PEXELS_API_KEY'), 'V06 Remove asks first, then removes the Amazon key');
await page.getByRole('searchbox', { name: 'Search keys' }).fill('pexels'); await page.waitForTimeout(300);
ok(await page.locator('[data-item]').count() === 1, 'V07 search narrows to the matching key');
await page.getByRole('searchbox', { name: 'Search keys' }).fill('');
await page.locator('[data-group="inbound"] > button').click();
const ch = page.locator('[data-item="charter"]');
await ch.getByRole('button', { name: 'Copy token' }).click(); await page.waitForTimeout(600);
c = await calls();
ok(c.some((x) => x.fn === 'api_connection_token' && x.args.p_id === 'charter') && await clip() === 'full-charter-token-xyz', 'V08 shared token: copied through the audited function');
await ch.getByRole('button', { name: 'Replace' }).click();
ok(/stops working at once/.test(await page.getByRole('alertdialog').innerText()), 'V08b replacing a shared token warns first');
await page.getByRole('alertdialog').getByRole('button', { name: 'Cancel' }).click();
await page.locator('[data-group="ai"] > button').click();
await page.locator('[data-item="ai:groq"]').getByRole('button', { name: 'Switch off' }).click(); await page.waitForTimeout(600);
c = await calls();
ok(c.some((x) => x.fn === 'ai_integration_toggle' && x.args.provider === 'groq' && x.args.enabled === false), 'V09 AI key can be switched off');
await page.getByText('Activity').click();
ok(/secret saved · META_ACCESS_TOKEN/.test(await body()), 'V10 activity shows who changed which key (name only)');
await nav.getByRole('button', { name: /^Settings/ }).click(); await page.waitForTimeout(1000);
ok(/Now all in one place: Setup > Connections & keys/.test(await body()), 'V11 Settings points to Connections & keys');

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
