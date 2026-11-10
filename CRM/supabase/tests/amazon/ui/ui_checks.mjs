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

const more = async (label) => { await nav('More'); await page.getByRole('button', { name: new RegExp('^' + label) }).first().click(); await page.waitForTimeout(500); };
const dlg = () => page.getByRole('alertdialog');

await as(ADMIN);
await page.goto(APP);
await page.getByText('What to do today').waitFor({ timeout: 15000 });
await page.getByText(/Fast delivery is not on/).waitFor({ timeout: 5000 }).catch(() => {});
const overview = await page.locator('body').innerText();
ok(/Another seller is winning the "Add to Cart" button/.test(overview), 'UI01 Home explains Buy Box losses in plain words under Fix these first');
ok(/Amazon is not connected yet/.test(overview), 'UI02 Home says Amazon is not connected yet');
ok(/Fast delivery is not on for \d+ product/.test(overview), 'UI02b Home suggests turning on fast delivery');
ok((await page.getByRole('tab').count()) === 5, 'UI02c only 5 tabs: Home, My Products, Approve Changes, Sales, More');
await page.screenshot({ path: `${SHOTS}/amz_overview.png`, fullPage: true });

await nav('My Products');
await page.getByText('Delivery speed').waitFor();
ok((await page.locator('[data-sku]').count()) === 20, 'UI03 My Products shows all 20 SKUs');
ok(/Ships: Not known yet/.test(await page.locator('body').innerText()), 'UI03b each product shows its dispatch time');
await page.screenshot({ path: `${SHOTS}/amz_listings.png`, fullPage: false });

await more('Edit name & text');
await page.locator('select').first().selectOption('69-E0DG-L8W8');
const title = page.locator('label:has-text("Product name") input').first();
await title.waitFor();
await title.fill('Nitaniya B5 PU Leather Diary 2027 Light Tan with Pen Holder and Ribbon Marks');   // 76 chars
await page.getByText(/Title is 76 characters/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI04 76-character title flagged as blocker while typing'))
  .catch(() => ok(false, 'UI04 76-character title flagged as blocker while typing'));
await title.fill('Nitaniya B5 PU Leather Diary 2027, Light Tan, Pen Holder, 160 Pages');
await page.waitForTimeout(800);
ok(!(await page.locator('body').innerText()).includes('Title is'), 'UI05 compliant title clears the blocker');
await page.getByRole('button', { name: 'Send for approval' }).click();
await page.locator('input[aria-label="What does this change do?"]').fill('Title to 75 chars');
await dlg().getByRole('button', { name: 'OK' }).click();
ok(/Sent to Approve Changes/.test(await toast()), 'UI06 draft sent for approval');
await page.screenshot({ path: `${SHOTS}/amz_studio.png`, fullPage: false });

await nav('Approve Changes');
await page.getByText('Title to 75 chars').waitFor();
await page.screenshot({ path: `${SHOTS}/amz_queue.png`, fullPage: false });
await page.locator('.glass-card', { hasText: 'Title to 75 chars' }).getByRole('button', { name: 'Approve', exact: true }).click();
await dlg().getByRole('button', { name: 'Approve', exact: true }).click();
await page.waitForTimeout(1200);
let calls = await (await fetch(`${API}/__calls`)).json();
ok(calls.some((c) => c.fn === 'api_amz_approve') && calls.some((c) => c.fn === 'amazon-execute'), 'UI07 Approve calls api_amz_approve then amazon-execute');
let q = await rpcAs('api_amz_queue', { p_status: 'approved' });
ok(q.length === 1 && q[0].summary === 'Title to 75 chars', 'UI08 change is approved in the database');

// Delivery speed for all products
await nav('My Products');
await page.getByRole('button', { name: 'Apply to all products' }).click();
await dlg().getByRole('button', { name: 'Yes, prepare it' }).click();
await page.getByText('Same-day dispatch').first().waitFor({ timeout: 5000 }).catch(() => {});
let pend = (await rpcAs('api_amz_queue', { p_status: 'pending' })).filter((c) => c.kind === 'dispatch');
const kids = (await rpcAs('api_amz_listings')).filter((l) => !l.is_parent).length;
ok(pend.length === kids && pend.every((c) => c.after.handling_days === 0), `UI18 "Apply to all products" drafts same-day dispatch for every product (${pend.length}/${kids})`);
ok(/Approve Changes/.test(await page.locator('[role=tab][aria-selected=true]').innerText()), 'UI19 it opens Approve Changes');
await page.screenshot({ path: `${SHOTS}/amz_dispatch.png`, fullPage: false });
await page.getByRole('button', { name: /^Approve all \(\d+\)$/ }).click();
await dlg().getByRole('button', { name: 'Approve all' }).click();
await page.waitForTimeout(1500 + kids * 250);
q = (await rpcAs('api_amz_queue', { p_status: 'approved' })).filter((c) => c.kind === 'dispatch');
calls = await (await fetch(`${API}/__calls`)).json();
ok(q.length === kids && calls.filter((c) => c.fn === 'amazon-execute').length >= kids + 1, 'UI20 "Approve all" approves and sends every dispatch change');

await nav('Sales');
await nav('Home');
await page.getByRole('button', { name: 'Review' }).count().then((n) => ok(n === 0, 'UI21 Home no longer asks to review once all are approved'));

await more('Settings');
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

await nav('My Products');
await page.locator('[data-sku="69-E0DG-L8W8"] button[aria-expanded]').click();
await page.getByRole('button', { name: 'Change price' }).first().click();
await page.locator('input[aria-label^="New price for"]').fill('298');
await dlg().getByRole('button', { name: 'OK' }).click();
ok(/below the floor of ₹299/.test(await toast()), 'UI09 ₹298 price change blocked in the UI');

for (const label of ['Things to fix', 'Search words', 'Competitors', 'Photos', 'Account health', 'To-do list', 'Ask Claude', 'History']) {
  await more(label);
}
await nav('More');
await page.screenshot({ path: `${SHOTS}/amz_more.png`, fullPage: false });
ok(consoleErrors.length === 0, `UI14 no console errors across all screens${consoleErrors.length ? ': ' + consoleErrors.slice(0, 3).join(' | ') : ''}`);

// phone
const phone = await browser.newPage({ viewport: { width: 390, height: 844 } });
await phone.goto(APP);
await phone.getByText('What to do today').waitFor();
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
