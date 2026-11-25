// Google Ads > Overview (migration 146). Run with: UI_SCRIPT=home_ui.mjs ./run_ui.sh
// The server's answers are replaced in the browser, so every state can be shown and every call is seen; the SQL is tested in ../home/.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');

const APP = 'http://localhost:5199/';
const API = 'http://localhost:54399';
const SHOTS = process.env.SHOTS || '/tmp';
const ADMIN = '10000000-0000-0000-0000-00000000000a';
let failed = 0;
const ok = (cond, name) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`); if (!cond) failed++; };
const as = (sub) => fetch(`${API}/__as/${sub}`);

const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME, args: ['--no-sandbox'] } : {});
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(String(e)));
const dlg = () => page.getByRole('alertdialog');
const txt = async (id) => (await page.getByTestId(id).innerText()).replace(/\s+/g, ' ');

// today's account, as the server answers it (25 Nov 2026: 0.09 left, two campaigns, nothing spent)
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const camps = [
  { id: '24283129095', name: 'We-Aviation-Search-sep-2026', label: 'Delhi NCR', daily_budget: 140, max_cpc: 20, primary_status: 'ELIGIBLE', reasons: [],
    income_excluded: ['INCOME_RANGE_0_50', 'INCOME_RANGE_50_60', 'INCOME_RANGE_60_70', 'INCOME_RANGE_70_80', 'INCOME_RANGE_UNDETERMINED'],
    slots: [{ start_hour: 0, end_hour: 6, bid_pct: -30 }, { start_hour: 6, end_hour: 24, bid_pct: 0 }],
    places: ['Faridabad,Haryana,India', 'Gurugram,Gurugram,Haryana,India', '110017,Delhi,India', '110049,Delhi,India', '201301,Uttar Pradesh,India', '110003,Delhi,India'],
    keywords_on: 18, keywords_paused: 7, examples: ['pilot training', 'commercial pilot', 'cpl training', 'dgca ground classes'] },
  { id: '24542430627', name: 'WOA | Search | Other cities | Online | Nov26', label: 'Punjab & Chandigarh (online)', daily_budget: 60, max_cpc: 20, primary_status: 'PENDING',
    reasons: ['MOST_ADS_UNDER_REVIEW'], income_excluded: ['INCOME_RANGE_0_50', 'INCOME_RANGE_50_60', 'INCOME_RANGE_60_70', 'INCOME_RANGE_70_80', 'INCOME_RANGE_UNDETERMINED'],
    slots: null, places: ['Punjab,India', 'Chandigarh,Chandigarh,Chandigarh,India'], keywords_on: 15, keywords_paused: 2, examples: ['pilot training', 'cpl ground classes'] },
];
const series = (n) => Array.from({ length: n }, (_, i) => ({ day: new Date(Date.now() - (n - 1 - i) * 86400000).toISOString().slice(0, 10), spend: i === n - 2 ? 180 : 0, clicks: i === n - 2 ? 12 : 0, enquiries: i === n - 2 ? 2 : 0 }));
const base = () => ({
  can_edit: true, is_admin: true, today: '2026-11-25',
  account: { name: 'We One', external_id: '6318538100', currency: 'INR', status: 'connected' },
  status: { state: 'no_money', likely: false, reviewing: ['Punjab & Chandigarh (online)'], today_spend: 0, today_clicks: 0, campaigns_on: 2 },
  money: { kind: 'prepaid', available: 0.09, checked_at: ago(3), error: null, asked_at: null, watching: false, daily: 200, days_left: 0, tax_pct: 18, add_30d: 7100, last_topup: null },
  budget: { daily: 200, monthly: 6080, actual: 200, min: 100, max: 5000, tax_pct: 18, month_spend: 0, change: null },
  campaigns: camps,
  areas_waiting: [{ name: 'Tier 2', places: 'Jaipur, Lucknow, Udaipur, Sonipat, Panipat' }, { name: 'Tier 3', places: 'Mumbai, Bengaluru, Hyderabad, Pune, Chennai, Kolkata, Ahmedabad' }],
  results: { days: 7, from: '2026-11-19', to: '2026-11-25', spend: 180, clicks: 12, impressions: 300, cpc: 15, enquiries: 2, cost_per_enquiry: 90, called: 1, called_15m: 1, waiting: 1, series: series(7) },
  needs: { ops: [
    { id: '11111111-1111-4111-8111-111111111111', kind: 'sitelink_add', summary: 'Add sitelink "Eligibility"', reason: 'Top Crew uses eligibility sitelinks; ours has none.', by: 'ai', warnings: [], created_at: ago(30) },
    { id: '22222222-2222-4222-8222-222222222222', kind: 'ad_schedule', summary: 'Bid 10% higher 6-10 pm', reason: null, by: 'you', warnings: [], created_at: ago(20) }],
    suggestions: 0, queue: 0 },
});
let answer = base();
const seen = [];
const reply = (r, body) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
await page.route('**/rpc/api_ads_google_home', async (r) => { seen.push({ fn: 'home', args: JSON.parse(r.request().postData() || '{}') }); await reply(r, typeof answer === 'function' ? answer() : answer); });
let refresh = { asked: true, wait: false };
await page.route('**/rpc/api_ads_google_balance_refresh', async (r) => { seen.push({ fn: 'refresh' }); await reply(r, refresh); });
let budgetReply = null;
await page.route('**/rpc/api_ads_google_budget_set', async (r) => { const a = JSON.parse(r.request().postData() || '{}'); seen.push({ fn: 'budget', args: a });
  if (budgetReply) return r.fulfill(budgetReply);
  await reply(r, { changed: true, daily: a.p_daily, monthly: Math.round(a.p_daily * 30.4), op: 'op1' }); });
await page.route('**/rpc/api_ads_google_op_decide', async (r) => { seen.push({ fn: 'decide', args: JSON.parse(r.request().postData() || '{}') }); await reply(r, { status: 'approved' }); });

await as(ADMIN);
await page.goto(`${APP}#/ads`); await page.getByTestId('g-home').waitFor({ timeout: 20000 }); await page.getByTestId('g-status').waitFor();
const tabs = (await page.getByRole('tablist', { name: 'ADS' }).innerText()).replace(/\s+/g, ' ');
ok(/Overview/.test(tabs) && /Ads Leads/.test(tabs) && /Advanced/.test(tabs) && !/Campaigns/.test(tabs) && !/Today/.test(tabs), `GH01 three tabs: Overview, Ads Leads, Advanced (${tabs})`);
ok(await page.locator('select[aria-label="Client"]').count() === 0 && await page.locator('select[aria-label="Period"]').count() === 0, 'GH02 no client or period pickers on the Overview');

// 1 status + 2 money: today's real state
let s = await txt('g-status');
ok(/Ads are off: the Google Ads balance is used up/.test(s) && /₹0\.09 left\. Add about ₹7,100 for 30 days at ₹200 a day, GST included/.test(s), `GH03 status says the ads are off and why, with what to add (${s.slice(0, 160)})`);
ok(await page.getByTestId('add-money-link').getAttribute('href') === 'https://ads.google.com/aw/billing/summary', 'GH04 "Add money in Google Ads" opens Google Ads billing');
ok(/Google is still checking the new ads in Punjab & Chandigarh \(online\)/.test(s), 'GH05 the campaign still under Google\'s review is named');
let m = await txt('g-money');
ok(/Balance ₹0\.09/.test(m) && /Read from Google 3 min ago/.test(m) && /0 days/.test(m), `GH06 the balance is Google's own figure with when it was read (${m.slice(0, 120)})`);
ok(await page.getByTestId('g-money').locator('input').count() === 0, 'GH07 nothing to type for the balance');

// "I added money": asks Google, waits for the answer, says what it found
answer = () => { const a = base(); a.money = { ...a.money, available: 5084.84, checked_at: new Date().toISOString(), days_left: 25.4, add_30d: 1100, last_topup: { credit: 5084.75, seen_at: new Date().toISOString() } };
  a.status = { ...a.status, state: 'starting' }; return a; };
await page.getByTestId('g-added').click();
await page.getByTestId('g-money-note').waitFor({ timeout: 15000 });
m = await txt('g-money');
ok(seen.filter((c) => c.fn === 'refresh').length === 1, 'GH08 "I added money" asks the server once');
ok(/Google shows the new money: ₹5,085 in the account now/.test(m) && /\+₹5,085/.test(m) && /25\.4 days/.test(m), `GH09 the new balance appears by itself, with the top-up after GST (${m.slice(0, 200)})`);
s = await txt('g-status');
ok(/Money received\. Ads are starting/.test(s), 'GH10 status changes to "starting"');
await page.screenshot({ path: `${SHOTS}/g_home_after_topup.png`, fullPage: true });

// no new money yet
answer = () => { const a = base(); a.money = { ...a.money, checked_at: new Date().toISOString() }; return a; };
await page.reload(); await page.getByTestId('g-added').waitFor();
await page.getByTestId('g-added').click();
await page.getByTestId('g-money-note').waitFor({ timeout: 15000 });
ok(/Google still shows ₹0\.09\. If you paid just now, it can take a few minutes \(card, UPI\) or up to a day \(net banking\)/.test(await txt('g-money-note')),
  'GH11 no new money yet: says so, how long payments take, and that the CRM keeps checking');
refresh = { asked: false, wait: false };
await page.getByTestId('g-added').click(); await page.getByTestId('g-money-note').waitFor(); await page.waitForTimeout(400);
ok(/could not reach Google just now/.test(await txt('g-money-note')), 'GH12 Google not reachable: says the CRM will check again by itself');
refresh = { asked: true, wait: false };

// 3 daily budget: slider, typed amount, preview, save
answer = base();
await page.reload(); await page.getByTestId('g-budget').waitFor();
let b = await txt('g-budget');
ok(/₹6,080 \+ GST = ₹7,174/.test(b) && /Delhi NCR ₹140 · Punjab & Chandigarh \(online\) ₹60/.test(b), `GH13 budget shows the month with GST and how it is shared (${b.slice(0, 220)})`);
ok(await page.getByTestId('g-budget-save').isDisabled(), 'GH14 Save is off until something changes');
await page.getByTestId('g-budget-slider').fill('300');
b = await txt('g-budget');
ok(await page.getByTestId('g-budget-input').inputValue() === '300' && /₹9,120 \+ GST = ₹10,762/.test(b) && /Delhi NCR ₹210 · Punjab & Chandigarh \(online\) ₹90/.test(b),
  'GH15 the slider moves the typed amount, the month and the split together (300: 9,120 a month, 210 / 90)');
await page.getByTestId('g-budget-input').fill('255');
b = await txt('g-budget');
ok(/Delhi NCR ₹178 · Punjab & Chandigarh \(online\) ₹77/.test(b) && /₹7,752 \+ GST = ₹9,147/.test(b) && ['250', '260'].includes(await page.getByTestId('g-budget-slider').inputValue()),
  `GH16 a typed amount works too, split to the rupee exactly as the server will (178 + 77) [${b.slice(0, 260)} | slider ${await page.getByTestId('g-budget-slider').inputValue()}]`);
await page.getByTestId('g-budget-input').fill('50');
ok(await page.getByTestId('g-budget-error').isVisible() && await page.getByTestId('g-budget-save').isDisabled(), 'GH17 below ₹100 a day: a plain error and no Save');
await page.getByTestId('g-budget-input').blur();
ok(await page.getByTestId('g-budget-input').inputValue() === '100', 'GH18 leaving the box puts it back inside the allowed range');
await page.getByTestId('g-budget-input').fill('2500');
ok(await page.getByTestId('g-budget-slider').inputValue() === '2000' && !(await page.getByTestId('g-budget-error').count()), 'GH19 amounts above the slider can be typed');
await page.getByTestId('g-budget-input').fill('300');
await page.getByTestId('g-budget-save').click();
await dlg().waitFor();
const dtext = (await dlg().innerText()).replace(/\s+/g, ' ');
ok(/Set Google Ads to ₹300 a day\?/.test(dtext) && /Delhi NCR ₹210/.test(dtext) && /Monthly limit ₹9,120 \(₹10,762 with GST\)/.test(dtext) && /up to twice this on a busy day/.test(dtext),
  'GH20 Save asks once, in plain words, with the split, the month and Google\'s busy-day rule');
answer = () => { const a = base(); a.budget = { ...a.budget, daily: 300, monthly: 9120, change: { id: 'op1', status: 'approved', daily_total: 300, previous_total: 200, created_at: new Date().toISOString() } }; return a; };
await dlg().getByRole('button', { name: 'Save' }).click();
await page.getByTestId('g-budget-status').waitFor({ timeout: 8000 });
ok(seen.some((c) => c.fn === 'budget' && c.args.p_daily === 300), 'GH21 one call with the amount');
ok(/Saving to Google/.test(await txt('g-budget-status')) && await page.getByTestId('g-budget-slider').isDisabled(), 'GH22 while Google is being changed the budget shows "Saving to Google…" and is locked');
answer = () => { const a = base(); a.budget = { ...a.budget, daily: 300, monthly: 9120, actual: 300, change: { id: 'op1', status: 'verified', daily_total: 300, previous_total: 200, created_at: new Date().toISOString() } }; return a; };
await page.waitForFunction(() => /Google has/.test(document.querySelector('[data-testid="g-budget-status"]')?.innerText || ''), null, { timeout: 12000 });
ok(/✓ Google has ₹300 a day/.test(await txt('g-budget-status')), 'GH23 it confirms only when Google has the new budget (checked again by itself)');
answer = () => { const a = base(); a.budget = { ...a.budget, change: { id: 'op1', status: 'failed', daily_total: 300, error: 'Google rejected it in the pre-check (nothing changed): BUDGET_ERROR', created_at: new Date().toISOString() } }; return a; };
await page.reload(); await page.getByTestId('g-budget-status').waitFor();
ok(/did not go through: Google rejected it/.test(await txt('g-budget-status')), 'GH24 a refused change says so, with Google\'s reason');
answer = base();
budgetReply = { status: 400, contentType: 'application/json', body: JSON.stringify({ code: 'PT409', message: 'The last budget change is still being saved to Google. Try again in a minute.' }) };
await page.reload(); await page.getByTestId('g-budget-input').fill('400'); await page.getByTestId('g-budget-save').click(); await dlg().getByRole('button', { name: 'Save' }).click();
await page.waitForTimeout(1200);
ok(/still being saved to Google/.test(await page.locator('body').innerText()) && await page.getByTestId('g-budget-input').inputValue() === '400', 'GH25 a refusal is shown in plain words and the typed amount is kept');
budgetReply = null;

// 4 who sees the ads
const au = await txt('g-audience');
ok(/Delhi NCR ₹140 a day · at most ₹20 a click/.test(au) && /Only the top 20% of households by income/.test(au), 'GH26 who: top 20% by household income, with budget and click limit');
ok(/6 areas: Faridabad, Haryana · Gurugram, Haryana · 110017, Delhi · 110049, Delhi \+2 more/.test(au), `GH27 where: the areas, short, with the rest one tap away (${au.slice(0, 300)})`);
ok(/12 am–6 am: bids 30% lower/.test(au) && /All day, every day, same bid/.test(au), 'GH28 when: night bids 30% lower on Delhi NCR, same bid all day elsewhere');
ok(/18 phrases, e\.g\. “pilot training”/.test(au) && /7 general phrases paused/.test(au), 'GH29 searches: how many phrases, examples, and what is paused');
ok(/Not switched on yet: Tier 2 \(Jaipur/.test(au) && /Tier 3 \(Mumbai/.test(au), 'GH30 areas not opened yet are listed');

// 5 results
const rs_ = await txt('g-results');
ok(/Spent ₹180/.test(rs_) && /Clicks 12/.test(rs_) && /₹15 a click/.test(rs_) && /Enquiries 2/.test(rs_) && /Cost per enquiry ₹90/.test(rs_) && /Called within 15 min 1 of 2/.test(rs_),
  `GH31 results: spent, clicks, CRM enquiries, cost per enquiry, calls within 15 minutes (${rs_.slice(0, 260)})`);
ok(/1 enquiry from ads not called yet/.test(rs_), 'GH32 an enquiry not called yet is flagged with a way to it');
await page.getByTestId('g-results').getByRole('button', { name: '30 days' }).click(); await page.waitForTimeout(800);
ok(seen.some((c) => c.fn === 'home' && c.args.p_days === 30), 'GH33 the period switch asks for 30 days');

// 6 needs you: who made each change
const nd = await txt('g-needs');
ok(/AI suggestion ?Add sitelink "Eligibility"/.test(nd) && /Top Crew uses eligibility sitelinks/.test(nd) && /Your change ?Bid 10% higher 6-10 pm/.test(nd) && !/agent change/i.test(nd),
  `GH34 waiting changes say who made them: "AI suggestion" or "Your change", with the reason (${nd})`);
await page.getByTestId('g-need').first().getByRole('button', { name: 'Approve' }).click(); await page.waitForTimeout(800);
ok(seen.some((c) => c.fn === 'decide' && c.args.p_id === '11111111-1111-4111-8111-111111111111' && c.args.p_approve === true), 'GH35 Approve sends the decision for that change');

// other states
for (const [state, re, name] of [
  [{ state: 'running', today_spend: 55, today_clicks: 4 }, /Ads are running.*₹55 spent today · 4 clicks/, 'GH36 running: today\'s spend and clicks'],
  [{ state: 'low_money' }, /Ads are running, but money is low/, 'GH37 low money'],
  [{ state: 'not_showing', since: '2026-11-20' }, /switched on but not showing.*since 20 Nov/, 'GH38 not showing although there is money'],
  [{ state: 'no_money', likely: true }, /Most likely the prepaid balance is used up \(the CRM has not read the balance from Google yet\)/, 'GH39 before the first read from Google: "most likely", never a made-up balance'],
  [{ state: 'paused' }, /stopped in the CRM/, 'GH40 stopped in the CRM'],
]) {
  answer = () => { const a = base(); a.status = { ...a.status, reviewing: [], ...state }; if (state.state === 'running') a.money.days_left = 25; if (state.state === 'low_money') a.money.days_left = 2.5; return a; };
  await page.reload(); await page.getByTestId('g-status').waitFor(); await page.waitForTimeout(300);
  ok(re.test(await txt('g-status')), name);
}
answer = () => ({ status: { state: 'not_connected' }, can_edit: true, is_admin: true, account: { currency: 'INR' } });
await page.reload(); await page.getByTestId('g-status').waitFor(); await page.waitForTimeout(300);
ok(/not connected/.test(await txt('g-status')) && await page.getByTestId('g-money').count() === 0, 'GH41 not connected: only the status and the way to Setup');
answer = () => { const a = base(); a.can_edit = false; a.status.reviewing = []; return a; };
await page.reload(); await page.getByTestId('g-budget').waitFor();
ok(await page.getByTestId('g-budget-slider').isDisabled() && await page.getByTestId('g-budget-save').count() === 0 && /Only people who can approve/.test(await txt('g-budget'))
  && await page.getByTestId('g-needs').getByRole('button', { name: 'Approve' }).count() === 0, 'GH42 view-only: budget locked and no Approve buttons');

// Advanced keeps everything that was there
answer = base();
await page.reload(); await page.getByTestId('g-advanced').click(); await page.waitForTimeout(600);
const adv = await page.locator('body').innerText();
ok(/Today \(detailed\)/.test(adv) && /Campaigns/.test(adv) && /Autopilot/.test(adv) && /Approvals/.test(adv) && /Full report/.test(adv) && /Settings/.test(adv), 'GH43 Advanced lists the detailed Today, Campaigns and every page that was under More');
await page.getByRole('button', { name: /^Today \(detailed\)/ }).click(); await page.getByTestId('today').waitFor({ timeout: 10000 });
ok(/#\/ads\/today/.test(page.url()), 'GH44 the detailed Today page has its own address');
ok(errors.length === 0, `GH45 no console errors${errors.length ? `: ${errors.slice(0, 3).join(' | ')}` : ''}`);

// phone
await page.setViewportSize({ width: 390, height: 844 });
answer = base();
await page.goto(`${APP}#/ads/home`); await page.getByTestId('g-budget').waitFor(); await page.waitForTimeout(800);
ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'GH46 the Overview fits a phone screen (no sideways scroll)');
await page.screenshot({ path: `${SHOTS}/g_home_phone.png`, fullPage: true });
await page.setViewportSize({ width: 1280, height: 900 });
await page.reload(); await page.getByTestId('g-budget').waitFor(); await page.waitForTimeout(800);
await page.screenshot({ path: `${SHOTS}/g_home_desktop.png`, fullPage: true });
await browser.close();
console.log(failed ? `${failed} UI CHECK(S) FAILED` : 'ALL GOOGLE HOME UI CHECKS PASSED');
process.exit(failed ? 1 : 0);
