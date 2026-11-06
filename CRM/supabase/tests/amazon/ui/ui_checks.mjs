// Headless-Chrome run of CRM > Amazon against the real SQL (via fake_api.mjs). Prints PASS/FAIL lines.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');

const APP = 'http://localhost:5199/';
const API = 'http://localhost:54399';
const SHOTS = process.env.SHOTS || '/tmp';
const ADMIN = '10000000-0000-0000-0000-00000000000a';
const SALES = '10000000-0000-0000-0000-00000000000b';
let failed = 0;
const ok = (cond, name) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`); if (!cond) failed++; };
const as = (sub) => fetch(`${API}/__as/${sub}`);
const rpcAs = async (fn, args = {}) => (await fetch(`${API}/rest/v1/rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) })).json();

const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const consoleErrors = [];
page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) consoleErrors.push(m.text()); });
page.on('pageerror', (e) => consoleErrors.push(String(e)));
const nav = async (label) => { await page.getByRole('tab', { name: new RegExp('^' + label.replace(/[.*+?^${}()|[\]\\&]/g, '\\$&') + '( \\d+)?$') }).first().click(); await page.waitForTimeout(500); };
const toast = async () => { await page.waitForTimeout(700); return (await page.locator('body').innerText()); };

await as(ADMIN);
await page.goto(APP);
await page.getByText('Fix first').waitFor({ timeout: 15000 });
const overview = await page.locator('body').innerText();
ok(/Buy Box lost/.test(overview) && /B0GGHDXNY1|B0GGH95CVH/.test(overview), 'UI01 Overview shows Buy Box losses under Fix first');
ok(/Amazon is not connected yet/.test(overview), 'UI02 Overview warns that keys are not set');
await page.screenshot({ path: `${SHOTS}/amz_overview.png`, fullPage: true });

await nav('Products & Listings');
await page.getByText('121/75', { exact: true }).waitFor();
ok((await page.locator('span').filter({ hasText: /^\d+\/75$/ }).count()) === 20, 'UI03 Products shows all 20 SKUs');
await page.screenshot({ path: `${SHOTS}/amz_listings.png`, fullPage: false });

await nav('Content Studio');
await page.locator('select').first().selectOption('69-E0DG-L8W8');
const title = page.locator('label:has-text("Title") input').first();
await title.waitFor();
await title.fill('Nitaniya B5 PU Leather Diary 2027 Light Tan with Pen Holder and Ribbon Marks');   // 76 chars
await page.getByText(/Title is 76 characters/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI04 76-character title flagged as blocker while typing'))
  .catch(() => ok(false, 'UI04 76-character title flagged as blocker while typing'));
await title.fill('Nitaniya B5 PU Leather Diary 2027, Light Tan, Pen Holder, 160 Pages');
await page.waitForTimeout(800);
ok(!(await page.locator('body').innerText()).includes('Title is'), 'UI05 compliant title clears the blocker');
await page.getByRole('button', { name: 'Send for approval' }).click();
await page.locator('input[aria-label="What does this change do?"]').fill('Title to 75 chars');
await page.getByRole('button', { name: 'OK' }).click();
ok(/Change Queue for approval/.test(await toast()), 'UI06 draft sent to the Change Queue');
await page.screenshot({ path: `${SHOTS}/amz_studio.png`, fullPage: false });

await nav('Change Queue');
await page.getByText('Title to 75 chars').waitFor();
await page.screenshot({ path: `${SHOTS}/amz_queue.png`, fullPage: false });
await page.getByRole('button', { name: /^Approve/ }).first().click();
await page.getByRole('button', { name: 'Approve', exact: true }).click();
await page.waitForTimeout(1200);
const calls = await (await fetch(`${API}/__calls`)).json();
ok(calls.some((c) => c.fn === 'api_amz_approve') && calls.some((c) => c.fn === 'amazon-execute'), 'UI07 Approve calls api_amz_approve then amazon-execute');
const q = await rpcAs('api_amz_queue', { p_status: 'approved' });
ok(q.length === 1 && q[0].summary === 'Title to 75 chars', 'UI08 change is approved in the database');

await nav('Inventory & Pricing');
await page.getByText('Change price').first().waitFor();
await page.getByText('Change price').first().click();
await page.locator('input[aria-label^="New price for"]').fill('298');
await page.getByRole('button', { name: 'OK' }).click();
ok(/below the floor of ₹299/.test(await toast()), 'UI09 ₹298 price change blocked in the UI');

await nav('Settings');
const rt = page.locator('input[placeholder^="Atzr|"]');
await rt.fill('abc');
await rt.locator('xpath=../button').click();
ok(/must start with Atzr/.test(await toast()), 'UI10 malformed refresh token rejected');
await rt.fill('Atzr|UITESTVALUE9876');
await rt.locator('xpath=../button').click();
await page.waitForTimeout(800);
ok((await page.locator('input[placeholder*="••••9876"]').count()) === 1, 'UI11 saved key shows only the last 4 characters');
ok(!(await page.content()).includes('UITESTVALUE'), 'UI12 full key never appears in the page');
await page.getByRole('button', { name: 'Test Connection' }).click();
await page.getByText(/Connected: All good/).first().waitFor({ timeout: 5000 }).then(() => ok(true, 'UI13 Test Connection result shown'))
  .catch(() => ok(false, 'UI13 Test Connection result shown'));
await page.screenshot({ path: `${SHOTS}/amz_settings.png`, fullPage: true });

for (const label of ['Audit', 'Keywords', 'Competitors', 'Images', 'Sales', 'Account Health', 'Strategy & Calendar', 'Ask Claude', 'Activity Log']) {
  await nav(label);
}
ok(consoleErrors.length === 0, `UI14 no console errors across all 15 screens${consoleErrors.length ? ': ' + consoleErrors.slice(0, 3).join(' | ') : ''}`);

// phone
const phone = await browser.newPage({ viewport: { width: 390, height: 844 } });
await phone.goto(APP);
await phone.getByText('Fix first').waitFor();
const overflow = await phone.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(overflow <= 1, `UI15 no sideways scroll on a phone (overflow ${overflow}px)`);
await phone.screenshot({ path: `${SHOTS}/amz_phone.png`, fullPage: false });

// non-admin
await as(SALES);
await page.goto(APP);
await page.waitForTimeout(1500);
ok((await page.locator('#denied').count()) === 1, 'UI16 Sales user without a grant has no Amazon section');
const s = await rpcAs('api_amz_settings');
ok(/Only Admin/.test(s.message || ''), 'UI17 Sales user cannot read Settings through the API');

await browser.close();
console.log(failed ? `${failed} UI CHECK(S) FAILED` : 'ALL UI TESTS PASSED');
process.exit(failed ? 1 : 0);
