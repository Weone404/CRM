// Headless check of CRM > ADS > Ads Leads against the real SQL (fake_api.mjs). Prints PASS/FAIL lines.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');
const APP = 'http://localhost:5199/', API = 'http://localhost:54399', SHOTS = process.env.SHOTS || '/tmp';
const ADMIN = '10000000-0000-0000-0000-00000000000a', SALES = '10000000-0000-0000-0000-00000000000b';
const RAVI = '40000000-0000-0000-0000-000000000001';
let failed = 0;
const ok = (c, n, i = '') => { console.log(`${c ? 'PASS' : 'FAIL'} ${n}${i ? ' -- ' + i : ''}`); if (!c) failed++; };
const as = (sub) => fetch(`${API}/__as/${sub}`);
const rpc = async (fn, args = {}) => (await fetch(`${API}/rest/v1/rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) })).json();
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(String(e)));
const body = async () => { await page.waitForTimeout(700); return page.locator('body').innerText(); };
const dlg = () => page.getByRole('alertdialog');

await as(SALES);
await page.goto(`${APP}#/ads/home`); await page.waitForTimeout(1500);
const tabs = await page.getByRole('tablist', { name: 'ADS' }).innerText();
ok(/Ads Leads/.test(tabs) && !/Leads & Revenue/.test(tabs), 'ADS tabs: Ads Leads in the bar, Leads & Revenue not', tabs.replace(/\n/g, ' | '));
await page.getByRole('tab', { name: /Ads Leads/ }).click();
let b = await body();
ok(/Ravi Kumar/.test(b) && /Neha Sharma/.test(b), 'Pilot Training list shows the ad leads');
ok(!/Jet Client/.test(b) && !/Bot Spam/.test(b), 'Charter and quarantined leads are not in the Pilot list');
ok(/Not called · 40 min/.test(b) && /Not called · 5 min/.test(b), 'speed-to-lead timer on uncalled leads');
ok(/Google · cpl-delhi/.test(b) && /Meta · ppl-meta/.test(b), 'source and campaign shown');
ok(/98222 00002/.test(b) && !/\+91/.test(b), 'phones shown as 10 digits, no +91');
ok(/New today\s*2/.test(b) && /Not called yet\s*2/.test(b), 'counts at the top', b.split('\n').slice(0, 12).join(' | '));
await page.screenshot({ path: `${SHOTS}/ads_leads_list.png`, fullPage: true });

await page.getByRole('tab', { name: 'Charter' }).click(); b = await body();
ok(/Jet Client/.test(b) && /Delhi → Goa/.test(b) && !/Ravi Kumar/.test(b), 'Charter tab shows only charter leads with route');
await page.getByRole('tab', { name: 'Pilot Training' }).click(); await page.waitForTimeout(500);
await page.getByRole('button', { name: /Quarantine/ }).first().click(); b = await body();
ok(/Bot Spam/.test(b) && /honeypot_filled/.test(b), 'Quarantine view shows the spam lead and why');
await page.getByRole('button', { name: /Quarantine/ }).first().click(); await page.waitForTimeout(400);

await page.getByLabel('Search').fill('ravi'); b = await body();
ok(/Ravi Kumar/.test(b) && !/Neha Sharma/.test(b), 'search by name');
await page.getByLabel('Search').fill('98111'); b = await body();
ok(/Neha Sharma/.test(b) && !/Ravi Kumar/.test(b), 'search by phone digits');
await page.getByLabel('Search').fill('');
await page.waitForTimeout(500);

// Lead page
await page.getByText('Ravi Kumar').click(); await page.waitForTimeout(800);
const panel = page.getByRole('dialog', { name: 'Ads lead' });
b = await panel.innerText();
ok(/Google Ads click/.test(b) && /cpl-delhi/.test(b) && /weoneaviation\.in\/cpl/.test(b), 'lead page: came from (click, campaign, landing page)');
ok(await panel.getByRole('link', { name: 'WhatsApp' }).getAttribute('href').then((h) => h.startsWith('https://wa.me/919822200002')), 'WhatsApp opens the right number');
ok(await panel.getByRole('link', { name: 'Call' }).getAttribute('href').then((h) => h === 'tel:9822200002'), 'Call link');
await panel.getByRole('button', { name: 'Connected' }).click(); await page.waitForTimeout(900);
b = await panel.innerText();
ok(/Contacted/.test(b) && /Call: Connected/.test(b) && /Lead Created → Contacted/.test(b), 'logging a connected call moves to Contacted and shows in history');
await panel.getByLabel('Assigned to').selectOption({ label: 'Test Sales' }); await page.waitForTimeout(900);
ok(/Assigned to Test Sales/.test(await panel.innerText()), 'assign is recorded in history');
await panel.getByRole('button', { name: 'Interested' }).click(); await page.waitForTimeout(900);
await panel.getByRole('button', { name: 'Qualified Lead' }).click(); await page.waitForTimeout(400);
await panel.getByRole('button', { name: 'Mark Qualified' }).click(); await page.waitForTimeout(500);
ok(!/Interested → Qualified/.test(await panel.innerText()), 'Qualified refused with no answers');
await panel.getByLabel('Class 12 with Physics & Maths').selectOption('Yes');
await panel.getByLabel('Planned start').fill('Jan 2027');
await panel.getByRole('button', { name: 'Mark Qualified' }).click(); await page.waitForTimeout(900);
b = await panel.innerText();
ok(/Interested → Qualified Lead/.test(b) && /pcm: Yes/.test(b) && /start: Jan 2027/.test(b), 'Qualified with answers, answers kept in history');
await page.screenshot({ path: `${SHOTS}/ads_leads_panel.png`, fullPage: true });
await panel.getByRole('button', { name: 'Lost' }).click(); await page.waitForTimeout(300);
await dlg().getByRole('textbox').fill('Chose another academy'); await dlg().getByRole('button', { name: 'Mark Lost' }).click(); await page.waitForTimeout(900);
b = await panel.innerText();
ok(/Qualified Lead → Lost/.test(b) && /Chose another academy/.test(b) && !(await panel.getByRole('button', { name: 'Reopen' }).count()), 'Lost with reason; counsellor cannot reopen');
await page.keyboard.press('Escape'); await page.waitForTimeout(400);
ok(!(await page.getByRole('dialog', { name: 'Ads lead' }).count()), 'Esc closes the lead page');
const db = await rpc('api_ads_lead', { p_lead: RAVI });
ok(db.stage === 'lost' && db.contacts?.length === 1 && db.assignments?.length === 1 && db.stages?.length === 5, 'database matches what the screen shows', `${db.stage} c${db.contacts?.length} a${db.assignments?.length} s${db.stages?.length}`);

// Admin can reopen; viewer is read-only
await as(ADMIN); await page.reload(); await page.waitForTimeout(1500);
await page.getByRole('tab', { name: /Ads Leads/ }).click(); await page.waitForTimeout(800);
await page.getByText('Ravi Kumar').click(); await page.waitForTimeout(800);
ok(await page.getByRole('dialog', { name: 'Ads lead' }).getByRole('button', { name: 'Reopen' }).count() === 1, 'Admin sees Reopen on a finished lead');
await page.keyboard.press('Escape');

// Mobile layout
await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(600);
const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(overflow <= 1, 'no sideways scroll on a phone', String(overflow));
await page.screenshot({ path: `${SHOTS}/ads_leads_mobile.png`, fullPage: true });

// Leads & Revenue still reachable under More
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/ads/more`); await page.waitForTimeout(900);
ok(/Leads & Revenue/.test(await body()), 'Leads & Revenue is in More');
ok(!errors.length, 'no browser errors', errors.slice(0, 3).join(' | '));
console.log(failed ? `FAILED ${failed}` : 'ALL ADS LEADS UI CHECKS PASSED');
await browser.close(); process.exit(failed ? 1 : 0);
