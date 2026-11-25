// ADS > Today: the "Google Ads stopped showing" warning (migration 142). Run with: UI_SCRIPT=delivery_ui.mjs ./run_ui.sh
// The server's answer is replaced in the browser, so every state can be shown; the SQL itself is tested in ../delivery/.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');

const APP = 'http://localhost:5199/';
const API = 'http://localhost:54399';
const SHOTS = process.env.SHOTS || '/tmp';
const ADMIN = '10000000-0000-0000-0000-00000000000a';
const SALES = '10000000-0000-0000-0000-00000000000b';
const CLIENT = '30000000-0000-0000-0000-000000000001';
let failed = 0;
const ok = (cond, name) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`); if (!cond) failed++; };
const as = (sub) => fetch(`${API}/__as/${sub}`);
const rpc = async (fn, args = {}) => (await fetch(`${API}/rest/v1/rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) })).json();
const calls = async () => (await fetch(`${API}/__calls`)).json();

const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME, args: ['--no-sandbox'] } : {});
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(String(e)));
const body = async () => { await page.waitForTimeout(600); return page.locator('body').innerText(); };
const tab = async (name) => { await page.getByRole('tab', { name: new RegExp(`^${name}`) }).first().click(); await page.waitForTimeout(500); };
const dlg = () => page.getByRole('alertdialog');
const sub = async (name) => { await tab('Advanced'); await page.getByRole('button', { name: new RegExp(`^${name}`) }).first().click(); await page.waitForTimeout(500); };


await as(ADMIN);
// Google Ads stopped showing (142): the Today page names it, says the likely reason and shows the evidence
{
  const stopped = { stopped: true, cause: 'funds', since: '2026-11-16', last_spend_day: '2026-11-15', quiet_days: 9, usual_impressions: 468, recent_impressions: 3, daily_budget: 200, currency: 'INR', tax_pct: 18,
    run: { from: '2026-11-13', spend: 847.37, with_tax: 999.9, payment: 1000, matches_payment: true }, has_ledger: false, estimate: null, crm_changes: 0, topup_30d: 7100,
    evidence: ['It was shown about 468 times a day before; since then about 3.', 'A campaign is switched on with INR 200 a day, and Google gives no reason for the stop.',
      'Spend from 13 Nov to 15 Nov is INR 847.37. With 18% tax that is 999.90, almost exactly one payment of INR 1,000.', 'The CRM changed nothing in the account on 15 Nov or the day after. <img src=x onerror=alert(1)>'] };
  let answer = stopped;
  await page.route('**/rpc/api_ads_delivery', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(answer) }));
  await page.goto(`${APP}#/ads/today`); await page.reload(); await page.getByTestId('today').waitFor(); await page.waitForTimeout(1500);
  const box = page.getByTestId('ads-stopped');
  let t = (await box.innerText()).replace(/\s+/g, ' ');
  ok(/Google Ads stopped showing on 16 Nov \(9 days ago\)\./.test(t) && /Most likely the prepaid balance is used up\. Add money in Google Ads; about ₹7,100 covers 30 days at this budget, tax included\. The ads start again by themselves\./.test(t),
    'UI110 Today says when Google Ads stopped, the likely reason and how much to add');
  ok(await box.getByRole('link', { name: /Add funds/ }).getAttribute('href') === 'https://ads.google.com/aw/billing/summary' && await page.getByTestId('needs').getByTestId('ads-stopped').count() === 1,
    'UI111 it sits under "Needs you" with a link straight to Google Ads billing');
  await box.locator('summary').click();
  t = (await box.innerText()).replace(/\s+/g, ' ');
  ok(/Why the CRM thinks so/.test(t) && /847\.37\. With 18% tax that is 999\.90, almost exactly one payment of INR 1,000\./.test(t) && /Google does not tell the CRM the balance of a prepaid account/.test(t)
    && /<img src=x onerror=alert\(1\)>/.test(t) && await page.locator('img[src="x"]').count() === 0, 'UI112 the evidence is one click away, says it is worked out (not Google\'s figure), and is shown as plain text');
  ok(await page.getByTestId('needs').getByTestId('ap-funds').count() === 1 && /I added money/.test(await page.getByTestId('needs').getByTestId('ap-funds').innerText()), 'UI113 the balance card is shown with it, so the top-up gets recorded');
  answer = { ...stopped, cause: 'unknown', evidence: stopped.evidence.slice(0, 2) };
  await page.reload(); await page.getByTestId('today').waitFor(); await page.waitForTimeout(1500);
  t = (await page.getByTestId('ads-stopped').innerText()).replace(/\s+/g, ' ');
  ok(/The CRM cannot see why\. Open Google Ads and look at the campaign's status and at Billing\./.test(t) && /What the CRM checked/.test(t) && !/balance is used up/.test(t)
    && await page.getByTestId('ads-stopped').getByRole('link', { name: /Open Google Ads/ }).count() === 1, 'UI114 when the reason is not visible it says so and does not guess');
  answer = { stopped: false };
  await page.reload(); await page.getByTestId('today').waitFor(); await page.waitForTimeout(1500);
  ok(await page.getByTestId('ads-stopped').count() === 0, 'UI115 ads running: no warning');
  await page.route('**/rpc/api_ads_delivery', (r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom"}' }));
  await page.reload(); await page.getByTestId('today').waitFor(); await page.waitForTimeout(1500);
  ok(await page.getByTestId('ads-stopped').count() === 0 && await page.getByTestId('needs').isVisible(), 'UI116 if the check itself fails, the rest of Today still works');
  await page.unroute('**/rpc/api_ads_delivery');
}
ok(errors.length === 0, `UI117 no console errors${errors.length ? `: ${errors.slice(0, 3).join(' | ')}` : ''}`);
await page.setViewportSize({ width: 390, height: 844 });
await page.route('**/rpc/api_ads_delivery', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ stopped: true, cause: 'funds', since: '2026-11-16', quiet_days: 9, currency: 'INR', topup_30d: 7100,
  evidence: ['Spend from 13 Nov to 15 Nov is INR 847.37. With 18% tax that is 999.90, almost exactly one payment of INR 1,000.'] }) }));
await page.reload(); await page.getByTestId('today').waitFor(); await page.waitForTimeout(1500);
await page.getByTestId('ads-stopped').locator('summary').click();
ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'UI118 the warning fits a phone screen');
await page.screenshot({ path: `${SHOTS}/ads_stopped_phone.png`, fullPage: false });
await browser.close();
console.log(failed ? `${failed} UI CHECK(S) FAILED` : 'ALL DELIVERY UI CHECKS PASSED');
process.exit(failed ? 1 : 0);
