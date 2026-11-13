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
{ const d = await page.getByTestId('delivery').allInnerTexts();
  ok(d.length === 1 && /Limited/.test(d[0]) && /Budget limits delivery/.test(d[0]) && /Keywords have low search volume/.test(d[0]),
    'UI09b enabled campaign shows Google delivery status and reasons in plain words'); }
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

await tab('More');                                    // Leads & Revenue lives under More since the Ads Leads tab
await page.getByRole('button', { name: /^Leads & Revenue/ }).click();
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
await dlg().locator('input').fill('test9876.apps.googleusercontent.com');
await dlg().getByRole('button', { name: 'Save' }).click();
t = await body();
ok(/••••\.com/.test(t) && !/test9876/.test(t), 'UI18 secret saved, only last 4 shown');
await page.getByRole('button', { name: /Test connection/ }).click();
t = await body();
ok(/Not configured/.test(t), 'UI19 Test connection reports the honest result');
await page.getByRole('button', { name: 'Stop everything' }).click();
await dlg().getByRole('button', { name: 'Stop everything' }).click();
t = await body();
ok(/ON: nothing is being sent/.test(t), 'UI20 emergency stop turns on');
await page.screenshot({ path: `${SHOTS}/ads_settings.png`, fullPage: true });

await page.goto(`${APP}#/ads/clients`);
await page.getByRole('button', { name: /^New client/ }).click();
await page.getByRole('button', { name: /^Next/ }).click();
t = await body();
ok(/Pick Google Ads, Meta or both/.test(t), 'UI21 step 1 asks Google, Meta or both first');
await page.getByRole('button', { name: /Google Ads/ }).first().click();
await page.getByRole('button', { name: /^M Meta/ }).click();
await page.getByRole('button', { name: /^Next/ }).click();
await page.getByLabel('Business name').fill('Wizard Client');
await page.getByLabel('Website').fill('weone');
await page.getByRole('button', { name: /^Next/ }).click();
t = await body();
ok(/full address/.test(t) && /Platforms/.test(t), 'UI22 step 2 checks the website as you type');
await page.getByLabel('Website').fill('https://example.org');
await page.getByLabel('Industry').selectOption('education');
await page.getByRole('button', { name: /^Next/ }).click();
await page.getByText('Campaign types').waitFor();
const gSec = page.getByRole('region', { name: 'Google Ads setup' });
const mSec = page.getByRole('region', { name: 'Meta setup' });
ok(await gSec.getByLabel('Campaign objective').inputValue() === 'LEADS' && await mSec.getByLabel('Campaign objective').inputValue() === 'OUTCOME_LEADS',
  'UI23 education preset pre-fills Leads on Google and Meta');
ok(await gSec.getByRole('button', { name: 'App' }).isDisabled() && !(await gSec.getByRole('button', { name: 'Display' }).isDisabled()),
  'UI24 campaign types Google does not offer for Leads (App) cannot be picked');
ok((await gSec.locator('option').allInnerTexts()).includes('YouTube reach, views, and engagements'), 'UI25 Google objectives use Google\'s own names');
await page.getByRole('button', { name: 'Create client' }).click();
t = await body();
ok(/special ad category|Answer this/i.test(t), 'UI26 Meta special ad category question must be answered');
await mSec.getByLabel(/Social issues/).check();
t = await body();
ok(/limits targeting/.test(t) && /Country these ads run in/.test(t), 'UI27 special category shows Meta\'s targeting warning and country');
await mSec.getByLabel(/Social issues/).uncheck();
await mSec.getByLabel('None').check();
await page.getByRole('button', { name: 'Create client' }).click();
t = await body();
ok(/Client saved/.test(t) && /Wizard Client/.test(t), 'UI28 client created through the wizard');
const wc = (await rpc('api_ads_clients')).find((c) => c.name === 'Wizard Client');
ok(wc && wc.platforms.join() === 'google,meta' && wc.google_settings.objective === 'LEADS' && wc.google_settings.campaign_types.includes('SEARCH')
  && wc.meta_settings.special_ad_categories[0] === 'NONE' && wc.preset === 'education', 'UI29 saved with both platforms\' settings');

await page.getByRole('button', { name: /^New client/ }).click();
await page.getByRole('button', { name: /Google Ads/ }).first().click();
await page.getByRole('button', { name: /^Next/ }).click();
await page.getByLabel('Business name').fill('Draft Client');
await page.getByRole('button', { name: 'Save draft' }).click();
t = await body();
ok(/Draft saved/.test(t) && /Setup not finished/.test(t), 'UI30 save as draft, marked "Setup not finished"');

await page.getByRole('button', { name: /Import existing accounts/ }).click();
await page.getByRole('button', { name: /Find my accounts/ }).click();
await page.getByText('Pilot School Search').waitFor();
t = await body();
ok(/already in CRM \(Test Client A\)/.test(t) && /via manager 999-888-7777/.test(t), 'UI31 found accounts show what is already imported and the manager account');
await page.getByLabel(/Pilot School Search/).check();
await page.getByLabel(/Pilot School Meta/).check();
ok(await page.getByLabel('Client name').inputValue() === 'Pilot School Search', 'UI32 new client name suggested from the account');
await page.getByLabel('Client name').fill('Pilot School');
await page.getByRole('button', { name: /^Import 2 accounts/ }).click();
await page.getByText(/Finish setting up Pilot School/).waitFor({ timeout: 8000 });
t = await body();
ok(/Imported 2 accounts/.test(t), 'UI33 import adds both accounts and opens the wizard to finish setup');
const acc = await rpc('api_ads_accounts', { p_client: null });
ok(acc.some((a) => a.external_id === '7778889999' && a.login_customer_id === '9998887777') && acc.some((a) => a.external_id === '5554443'),
  'UI34 imported accounts stored with their manager account');
await page.screenshot({ path: `${SHOTS}/ads_wizard_finish.png`, fullPage: true });

// Autopilot (093)
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/ads/home?client=${CLIENT}`);
await page.getByText('What needs attention').waitFor();
await tab('Autopilot');
await page.getByTestId('autopilot').waitFor();
t = await body();
ok(/Emergency stop is ON|Autopilot is flying/.test(t) && /Spend limits/.test(t) && /Tell the agents/.test(t), 'UI40 Autopilot tab shows state, limits and the instruction box');
ok(await page.getByLabel('Daily limit').inputValue() === '5000', 'UI41 the saved daily limit is shown');
await page.getByRole('button', { name: /500\/day/ }).click();
ok(await page.getByLabel('Monthly limit').inputValue() === '15200', 'UI42 a quick pick fills the monthly limit (x30.4)');
await page.getByTestId('ap-limits').getByRole('button', { name: 'Save' }).click(); await page.waitForTimeout(800);
let ap = await rpc('api_ads_autopilot');
ok(Number(ap.caps.daily) === 500 && Number(ap.caps.monthly) === 15200, 'UI43 limits saved to the database');
const sug = page.getByTestId('ap-suggestion').first();
ok(await sug.getByRole('checkbox').nth(0).isChecked() && !(await sug.getByRole('checkbox').nth(1).isChecked()), 'UI44 suggested options come pre-picked as the agents advised');
await sug.getByRole('button', { name: /Accept \(1\)/ }).click(); await page.waitForTimeout(900);
const gops = await rpc('api_ads_google_ops', { p_status: null, p_limit: 20 });
ok(gops.filter((o) => o.kind === 'campaign_geo').length === 2 && !gops.some((o) => o.payload?.add?.[0] === '1007826'), 'UI45 accepting creates only the picked city plus the shared change');
await page.getByLabel('Instruction for the agents').fill('Focus on DGCA ground classes this month');
await page.getByTestId('ap-tell').getByRole('button', { name: 'Send' }).click(); await page.waitForTimeout(800);
ok(/Focus on DGCA ground classes this month/.test(await body()), 'UI46 a typed instruction is sent and listed');
await page.getByRole('button', { name: 'Stopped' }).click(); await page.waitForTimeout(400);
t = await body();
ok(/Rejected by Reviewer/.test(t) && !/Went live \(checked\)/.test(t), 'UI47 "Stopped" shows the Reviewer\'s rejections');
await page.getByRole('button', { name: 'Went live' }).click(); await page.waitForTimeout(400);
ok(/Weekend Batches/.test(await body()), 'UI48 "Went live" shows verified changes');
await page.getByRole('button', { name: 'I added money' }).click();
await dlg().getByRole('textbox').fill('20000'); await dlg().getByRole('button', { name: 'OK' }).click(); await page.waitForTimeout(800);
ok(/left/.test(await page.getByTestId('ap-funds').innerText()), 'UI49 recording a top-up shows the balance estimate');
ok(/Emergency stop is ON/.test(await body()), 'UI50 the stop pressed in Settings shows on Autopilot too');
await page.getByRole('button', { name: 'Resume' }).click(); await page.waitForTimeout(800);
ok(!(await rpc('api_ads_autopilot')).stopped && /Autopilot is flying/.test(await body()), 'UI51 resume');
await page.getByRole('button', { name: 'Stop everything' }).click();
await dlg().getByRole('button', { name: 'Stop everything' }).click(); await page.waitForTimeout(800);
ok((await rpc('api_ads_autopilot')).stopped, 'UI51b emergency stop from the Autopilot tab');
await page.getByRole('button', { name: 'Resume' }).click(); await page.waitForTimeout(800);
await page.screenshot({ path: `${SHOTS}/ads_autopilot.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(500);
const apOver = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(apOver <= 1, `UI52 Autopilot has no horizontal scroll at phone width (${apOver}px)`);
await page.screenshot({ path: `${SHOTS}/ads_autopilot_phone.png`, fullPage: true });

// phone width: no horizontal page scroll on Home
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${APP}#/ads/home?client=${CLIENT}`);
await page.getByText('What needs attention').waitFor();
const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(overflow <= 1, `UI35 phone width has no horizontal page scroll (${overflow}px)`);
await page.screenshot({ path: `${SHOTS}/ads_phone.png`, fullPage: true });

await as(SALES);
await page.goto(APP); await page.waitForTimeout(1200);
ok(await page.locator('#denied').count() === 1, 'UI36 sales user without access is denied');
ok(errors.length === 0, `UI37 no console errors${errors.length ? `: ${errors.slice(0, 3).join(' | ')}` : ''}`);
await browser.close();
console.log(failed ? `${failed} UI CHECK(S) FAILED` : 'ALL ADS UI CHECKS PASSED');
process.exit(failed ? 1 : 0);
