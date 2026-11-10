// Headless run of CRM > ADS against the real SQL (via fake_api.mjs). Prints PASS/FAIL lines.
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

await as(ADMIN);
await page.goto(`${APP}#/ads/home?client=${CLIENT}&period=14d`);
await page.getByText('What needs attention').waitFor({ timeout: 20000 });
let t = await body();
ok(/Ad spend/.test(t) && /₹9,000/.test(t), 'UI01 Home shows platform spend for the last 14 days (10 days × ₹900)');
ok(/Leads \(CRM\)\s*CRM\s*6/.test(t), 'UI02 Home shows 6 CRM leads, labelled CRM');
ok(/Cost per lead\s*Calculated\s*₹1,500/.test(t), 'UI03 CPL = 9000 / 6 = ₹1,500, labelled Calculated');
ok(/ROAS \(platform-attributed\)\s*Platform\s*0\.00×/.test(t), "UI04 platform ROAS is platform value ÷ spend (0 value -> 0.00×), separate from CRM");
ok(/Meta Test Meta \(Test Client A\): Sign-in needed/.test(t) && /Session has expired/.test(t), 'UI05 disconnected Meta account is shown, never as synced');
ok(/time zone Asia\/Kolkata/.test(t), 'UI06 period and time zone are visible');
await page.screenshot({ path: `${SHOTS}/ads_home.png`, fullPage: true });

await page.getByRole('button', { name: /Sync now/ }).click();
t = await body();
ok((await calls()).some((c) => c.fn === 'ads-sync' && c.args.jobs?.includes('sync')), 'UI07 Sync now calls ads-sync');

await tab('Campaigns');
await page.getByText('Test Search').waitFor();
t = await body();
ok(/Test Search/.test(t) && /6 · 3/.test(t), 'UI08 campaign row shows CRM leads · qualified (6 · 3)');
ok(/not linked/.test(t), 'UI09 campaign without UTM mapping says CRM is not linked');
await page.screenshot({ path: `${SHOTS}/ads_campaigns.png`, fullPage: true });

// budget +50% -> needs second confirm
await page.getByRole('button', { name: 'Change budget' }).first().click();
await dlg().locator('input').fill('1500');
await dlg().getByRole('button', { name: 'OK' }).click();
await dlg().getByText(/second confirm/).waitFor();
await dlg().getByRole('button', { name: 'Send for approval' }).click();
t = await body();
ok(/Sent for approval/.test(t), 'UI10 budget change drafted into Approvals');
// a blocked change never reaches approvals
await page.getByRole('button', { name: 'Change budget' }).first().click();
await dlg().locator('input').fill('9000');
await dlg().getByRole('button', { name: 'OK' }).click();
t = await body();
ok(/max daily budget|more than the 100%/.test(t), 'UI11 a blocked budget is refused with the reason');

await tab('Approvals');
await page.getByText(/daily budget ₹1,000 → ₹1,500/i).first().waitFor();
t = await body();
ok(/Double-check/.test(t), 'UI12 approval card shows the guard result');
await page.getByRole('button', { name: 'Approve and send' }).click();
await dlg().getByRole('button', { name: 'Yes, approve' }).click();
t = await body();
ok(/Approved/.test(t) && (await calls()).some((c) => c.fn === 'ads-sync' && c.args.jobs?.includes('execute')), 'UI13 approve with second confirm, then execute is called');
const q = await rpc('api_ads_queue', {});
ok(q[0]?.status === 'approved' && q[0]?.second_confirmed === true, 'UI14 queue row approved with second confirm recorded');
await page.screenshot({ path: `${SHOTS}/ads_approvals.png`, fullPage: true });

await tab('Leads');
await page.getByText('Leads from ads').waitFor();
t = await body();
ok((t.match(/Test Lead \d/g) || []).length >= 6, 'UI15 ad leads listed');
await page.getByLabel(/Amount/).fill('125000');
await page.getByRole('button', { name: 'Add' }).click();
t = await body();
ok(/Recorded/.test(t) && /₹1,25,000/.test(t), 'UI16 confirmed revenue recorded');

await tab('More');
await page.getByRole('button', { name: /^Research/ }).click();
await page.getByRole('button', { name: /Add finding/ }).click();
await page.getByLabel('Topic').fill('Fees');
await page.getByLabel('Observation').fill('Competitor lists a fee');
await page.getByRole('button', { name: 'Save' }).click();
t = await body();
ok(/needs a source URL/.test(t), 'UI17 a verified fact without a source is refused');

await page.goto(`${APP}#/ads/settings`);
await page.getByText('Emergency stop').waitFor();
await page.getByRole('button', { name: 'Add' }).first().click();
await dlg().locator('input').fill('test-developer-token-1234');
await dlg().getByRole('button', { name: 'Save' }).click();
t = await body();
ok(/••••1234/.test(t) && !/test-developer-token/.test(t), 'UI18 secret saved, only last 4 shown');
await page.getByRole('button', { name: /Test connection/ }).click();
t = await body();
ok(/Not configured/.test(t), 'UI19 Test connection reports the honest result');
await page.getByRole('button', { name: 'Stop everything' }).click();
await dlg().getByRole('button', { name: 'Stop everything' }).click();
t = await body();
ok(/ON: nothing is being sent/.test(t), 'UI20 emergency stop turns on');
await page.screenshot({ path: `${SHOTS}/ads_settings.png`, fullPage: true });

await page.goto(`${APP}#/ads/clients`);
await page.getByRole('button', { name: /Add client/ }).click();
await page.getByLabel('Business name').fill('Second Test Client');
await page.getByLabel('Target CPL').fill('abc');
await page.getByRole('button', { name: 'Save' }).click();
t = await body();
ok(/positive number/.test(t), 'UI21 bad economics refused');
await page.getByLabel('Target CPL').fill('650');
await page.getByRole('button', { name: 'Save' }).click();
t = await body();
ok(/Second Test Client/.test(t) && /Saved/.test(t), 'UI22 client created');

// phone width: no horizontal page scroll on Home
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${APP}#/ads/home?client=${CLIENT}`);
await page.getByText('What needs attention').waitFor();
const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(overflow <= 1, `UI23 phone width has no horizontal page scroll (${overflow}px)`);
await page.screenshot({ path: `${SHOTS}/ads_phone.png`, fullPage: true });

await as(SALES);
await page.goto(APP); await page.waitForTimeout(1200);
ok(await page.locator('#denied').count() === 1, 'UI24 sales user without access is denied');
ok(errors.length === 0, `UI25 no console errors${errors.length ? `: ${errors.slice(0, 3).join(' | ')}` : ''}`);
await browser.close();
console.log(failed ? `${failed} UI CHECK(S) FAILED` : 'ALL ADS UI CHECKS PASSED');
process.exit(failed ? 1 : 0);
