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
const sub = async (name) => { await tab('More'); await page.getByRole('button', { name: new RegExp(`^${name}`) }).first().click(); await page.waitForTimeout(500); };

await as(ADMIN);
await page.goto(`${APP}#/ads/report?client=${CLIENT}&period=14d`);
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
ok(!/Test Lead Form/.test(t), 'UI09 Google Ads > Campaigns shows only Google campaigns');
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

await sub('Approvals');
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
await page.getByRole('button', { name: 'Save', exact: true }).click();
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

// ---- Meta lead sources (migration 100): in the Meta Ads section's Settings
await page.goto(`${APP}#/metaads/settings`);
await page.getByTestId('ads-meta-settings').waitFor({ timeout: 15000 });
t = await page.getByTestId('ads-meta-settings').innerText();
ok(/Meta lead forms/.test(t) && /Meta ad → your website/.test(t) && /WhatsApp ads/.test(t) && /Callback URL for Meta/.test(t)
  && /functions\/v1\/ads-meta-webhook/.test(t), 'UI120 Settings shows the three Meta lead sources and the webhook callback URL');
ok(/Emergency stop is on: nothing is sent to Meta/.test(t), 'UI121 the emergency stop is shown on the Meta panel too');
let ms = await rpc('api_ads_meta_settings');
ok(ms.sources.every((s) => !s.intake_enabled && !s.report_enabled), 'UI122 every Meta source starts switched off');
await page.getByRole('switch', { name: 'Meta lead forms: report' }).click();
t = await body();
ok(/Add the dataset ID before switching reporting on/.test(t), 'UI123 reporting cannot be switched on without a dataset ID (plain message)');
await page.getByTestId('meta-source-instant_form').getByRole('button', { name: /Dataset ID/ }).click();
await dlg().locator('input').fill('1122334455');
await dlg().getByRole('button', { name: 'Save' }).click();
await page.getByRole('switch', { name: 'Meta lead forms: intake' }).click();
await page.getByRole('switch', { name: 'Meta lead forms: report' }).click();
await page.waitForTimeout(600);
ms = await rpc('api_ads_meta_settings');
ok(ms.sources[0].source === 'instant_form' && ms.sources[0].intake_enabled && ms.sources[0].report_enabled && ms.sources[0].dataset_id === '1122334455',
  'UI124 Admin switches Meta lead forms on and saves the dataset ID from the dashboard');
await page.getByTestId('meta-source-instant_form').getByLabel('Consent rule').selectOption('required_if_collected');
await page.waitForTimeout(600);
ms = await rpc('api_ads_meta_settings');
ok(ms.sources[0].consent_mode === 'required_if_collected', 'UI125 the consent rule is changed from the dashboard');
await page.getByTestId('meta-source-ctwa').getByRole('button', { name: /stage → Meta event names/ }).click();
const wa = page.getByTestId('meta-source-ctwa').getByLabel('Lead Created event').first();
const opts = await wa.locator('option').allTextContents();
ok(opts.join() === 'LeadSubmitted,QualifiedLead', 'UI126 WhatsApp stages offer only the event names Meta accepts');
await wa.selectOption('QualifiedLead');
await page.waitForTimeout(600);
ms = await rpc('api_ads_meta_settings');
ok(ms.event_map.find((r) => r.source === 'ctwa' && r.pipeline === 'pilot_training' && r.stage === 'lead_created').meta_event_name === 'QualifiedLead',
  'UI127 a stage → event mapping is saved from the dashboard');
await page.screenshot({ path: `${SHOTS}/ads_settings_meta.png`, fullPage: true });
await rpc('api_ads_meta_source_save', { p_source: 'instant_form', p_data: { intake_enabled: false, report_enabled: false, consent_mode: 'required' } });
await rpc('api_ads_meta_event_map_save', { p_source: 'ctwa', p_pipeline: 'pilot_training', p_stage: 'lead_created', p_event: 'LeadSubmitted', p_enabled: true });

// ---- Meta Ads > Insights (migration 103)
await page.goto(`${APP}#/metaads/insights`);
await page.getByTestId('meta-insights').waitFor({ timeout: 15000 });
await page.getByTestId('insights-tiles').waitFor({ timeout: 20000 });
t = await page.getByTestId('insights-tiles').innerText();
ok(/Spend\s+₹[\d,]+/.test(t) && /Admissions\s+\d+/.test(t) && /Cost per admission/.test(t) && /vs previous/.test(t),
  'UI150 Insights shows spend, CRM results and cost per result with the change against the previous period');
t = await page.getByTestId('insights-patterns').innerText();
ok(/Do more of/.test(t) && /Do less of/.test(t) && /CPL Reels Delhi/.test(t) && /(Proven|Early)/.test(t),
  'UI151 proven patterns are listed as wins and losses with a confidence badge');
ok(await page.getByTestId('pattern').count() >= 3, 'UI151b several patterns are found in the sample history');
ok(/CPL Reels Delhi/.test(await page.getByTestId('insights-board').innerText()) && /Delhi 18-24/.test(await (async () => {
  await page.getByTestId('insights-board').getByRole('button', { name: 'Ad sets' }).click(); return page.getByTestId('insights-board').innerText(); })()),
  'UI152 the leaderboard ranks campaigns and ad sets');
t = await page.getByTestId('insights-gallery').innerText();
ok(/Pilot banna hai\? Reel/.test(t) && /Best/.test(t) && /Worst/.test(t) && /Fees banner/.test(t), 'UI153 the creative gallery shows the best and worst ads with their text');
ok(await page.getByTestId('insights-trend').locator('rect').count() >= 8 && /Age × gender/.test(await page.getByTestId('insights-audience').innerText()),
  'UI154 weekly chart and audience charts are drawn');
t = await page.getByTestId('insights-whatif').innerText();
ok(/Moving ₹[\d,]+\/week from Broad India Static to CPL Reels Delhi: about \+[\d.]+ admissions per week/.test(t), 'UI155 the budget what-if estimates extra admissions from moving budget loser -> winner');
const c150 = (await calls()).filter((x) => x.fn === 'api_ads_meta_insights').length;
await page.getByLabel('Campaign').selectOption('7101');
await page.waitForTimeout(1200);
ok((await calls()).filter((x) => x.fn === 'api_ads_meta_insights').length > c150 && (await calls()).some((x) => x.fn === 'api_ads_meta_insights' && x.args.p_campaign === '7101'),
  'UI156 filters reload the numbers for one campaign');
await page.getByLabel('Note text').fill('DGCA exam results out');
await page.getByRole('button', { name: 'Add note' }).click();
await page.waitForTimeout(1200);
ok(/DGCA exam results out/.test(await page.getByTestId('insights-notes').innerText()), 'UI157 a timeline note is added');
ok(/Monthly summaries/.test(await page.getByTestId('insights-reports').innerText()) && /CRM email is not set up/.test(await page.getByTestId('insights-reports').innerText()),
  'UI158 monthly summaries say when CRM email is not set up');
await page.screenshot({ path: `${SHOTS}/ads_meta_insights.png`, fullPage: true });

// ---- Meta Ads > Strategy (migration 104)
await page.goto(`${APP}#/metaads/strategy`);
await page.getByTestId('meta-strategy').waitFor({ timeout: 15000 });
await page.getByTestId('strategy-card').first().waitFor({ timeout: 15000 });
t = await page.getByTestId('meta-strategy').innerText();
ok(/CPL admissions, Delhi NCR/.test(t) && /Ready for you/.test(t) && /₹30,400\/month → about 600 leads, 12 admissions/.test(t) && /The agents (are online|are stopped)/.test(t),
  'UI160 Strategy lists plans with their status and likely result, and says whether the agents are online');
await page.getByTestId('new-strategy').click();
await page.getByTestId('goal-form').waitFor();
await page.getByLabel('Monthly budget').fill('500');
await page.getByTestId('goal-submit').click();
await page.waitForTimeout(800);
ok(/at least ₹3,000/.test(await body()), 'UI161 the goal form explains what is wrong (budget limit too small)');
await page.getByLabel('Monthly budget').fill('25000');
await page.getByRole('button', { name: 'DGCA Ground Classes' }).click();
await page.getByLabel('Privacy policy').fill('https://weoneaviation.in/privacy-policy');
await page.getByLabel('Notes').fill('New batch starts 5 January');
await page.getByTestId('goal-submit').click();
await page.getByTestId('strategy-detail').waitFor({ timeout: 15000 });
await page.waitForTimeout(800);
t = await page.getByTestId('strategy-detail').innerText();
const created = (await calls()).filter((x) => x.fn === 'api_ads_meta_strategy_create').pop();
ok(/Agents working/.test(t) && /Waiting for the agents/.test(t) && /Researcher queued/.test(t) && created?.args.p_goal.courses.includes('DGCA Ground Classes')
  && created.args.p_goal.monthly_budget === '25000' && created.args.p_goal.locations[0] === 'Delhi NCR',
  'UI161b a new goal starts the agents (Researcher queued) and the page shows they are working');
await page.getByRole('button', { name: 'All strategies' }).click();
await page.getByText('CPL admissions, Delhi NCR').first().click();
await page.getByTestId('plan-forecast').waitFor({ timeout: 15000 });
t = await page.getByTestId('strategy-detail').innerText();
ok(/600 leads/.test(t) && /₹50 per lead/.test(t) && /12 admissions/.test(t) && /≈ ₹30,00,000 in admissions/.test(t) && /Your history/.test(t) && /Benchmark/.test(t) && /Your input/.test(t),
  'UI162 the plan shows low / likely / high outcomes with each assumption\'s source and the value of admissions');
ok(/₹30,400 a month/.test(t) && /Delhi NCR 18-24/.test(t) && /Delhi \+40 km · age 18-24/.test(t) && /Advantage\+ \(Meta picks\)/.test(t) && /Higher intent/.test(t)
  && /Finished class 12 with Physics and Maths\? \(Yes \/ Studying now \/ No\)/.test(t) && /Five steps from class 12/.test(t) && /Visual: Infographic/.test(t)
  && /When an ad set spends ₹150 with no lead → then pause it/.test(t) && /Reviewer approved this plan/.test(t) && /Lead forms with one qualifying question/.test(t),
  'UI162b budget, structure, audiences, lead form, ad text with visual brief, rules, review and research are all shown');
await page.getByTestId('approve').click();
await page.waitForTimeout(1200);
t = await page.getByTestId('strategy-detail').innerText();
ok(/Approved/.test(t) && /Version 1 \(approved\)/.test(await page.getByLabel('Version').innerText()) && (await page.getByTestId('plan-build').count()) === 1
  && /everything PAUSED/.test(await page.getByTestId('plan-build').innerText()) && (await page.getByTestId('plan-tracking').count()) === 1
  && (await page.getByLabel('Picture for Image: steps to CPL').count()) === 1 && (await page.getByLabel('Picture for Reel: a day at ground classes').count()) === 0,
  'UI163 approving a version offers Create in Meta (paused), picture uploads for image ads and plan vs actual');
await page.getByLabel('Meta campaign for WOA Leads CPL').selectOption({ index: 1 });
await page.getByRole('button', { name: 'Save links' }).click();
await page.waitForTimeout(800);
ok((await calls()).some((x) => x.fn === 'api_ads_meta_strategy_link' && Object.keys(x.args.p_links).includes('c1')), 'UI164 plan campaigns can be linked to existing Meta campaigns');
await page.getByLabel('Change request').fill('Keep it under ₹20,000 and add a Hindi video ad');
await page.getByTestId('change-send').click();
await page.waitForTimeout(1200);
t = await page.getByTestId('strategy-detail').innerText();
ok(/Agents working/.test(t) && (await calls()).some((x) => x.fn === 'api_ads_meta_strategy_change' && /Hindi video/.test(x.args.p_request))
  && (await rpc('api_ads_meta_strategy', { p_id: 900 })).strategy.approved_version === 1,
  'UI165 a change request goes to the agents; the approved version stays until another is approved');
await page.screenshot({ path: `${SHOTS}/ads_meta_strategy.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.waitForTimeout(600);
const ovs = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(ovs <= 1, `UI166 the plan fits a phone screen (${ovs}px)`);
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/metaads`);
await page.getByTestId('speed-alerts').waitFor({ timeout: 15000 });
t = await page.getByTestId('speed-alerts').innerText() + await page.getByTestId('lead-archive').innerText();
ok(/Speed to lead/.test(t) && /Alerts after 5 min \(owner\), 15 min \(Admin\)/.test(t) && /Meta lead archive/.test(t) && /deletes form answers after 90 days/.test(t),
  'UI167 the Overview shows waiting leads (speed to lead) and the Meta lead archive');
const csv = 'id,created_time,ad_id,ad_name,campaign_id,campaign_name,form_id,form_name,is_organic,platform,which_course_are_you_interested_in?,full_name,phone_number,email\n'
  + 'l:4000000000000001,2024-01-05T10:00:00+0530,ag:1,Reel,c:7101,"CPL, Delhi",f:1,Form,false,ig,CPL,Asha Rao,p:+919811477701,asha@example.com\n'
  + 'l:4000000000000002,2024-01-06T10:00:00+0530,ag:1,Reel,c:7101,"CPL, Delhi",f:1,Form,false,fb,"DGCA ""ground"" classes",Ravi,p:+919811477702,\n';
await page.getByLabel('Meta leads CSV').setInputFiles({ name: 'leads.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
await page.waitForTimeout(1500);
const imp = (await calls()).filter((x) => x.fn === 'api_ads_meta_leads_import').pop();
ok(/2 added/.test(await body()) && imp?.args.p_rows.length === 2 && imp.args.p_rows[0].campaign_name === 'CPL, Delhi' && imp.args.p_rows[1].answers['which_course_are_you_interested_in?'] === 'DGCA "ground" classes'
  && imp.args.p_rows[0].name === 'Asha Rao' && imp.args.p_rows[0].phone === 'p:+919811477701' && !('full_name' in imp.args.p_rows[0].answers),
  'UI168 an old Meta CSV imports (quotes, commas, answers kept; contact fields separate)');
ok(/^2$/m.test(await page.getByTestId('lead-archive').innerText()) || /2 imported/.test(await page.getByTestId('lead-archive').innerText()), 'UI168b the archive count updates');
await page.getByText('Alert settings').click();
await page.getByLabel('First alert minutes').fill('10');
await page.getByLabel('Admin alert minutes').fill('5');
await page.getByTestId('speed-alerts').getByRole('button', { name: 'Save' }).click();
await page.waitForTimeout(800);
ok(/after the first alert/.test(await body()), 'UI169 alert settings explain a wrong order');
await page.getByLabel('Admin alert minutes').fill('30');
await page.getByTestId('speed-alerts').getByRole('button', { name: 'Save' }).click();
await page.waitForTimeout(800);
ok(/Alerts after 10 min \(owner\), 30 min \(Admin\)/.test(await page.getByTestId('speed-alerts').innerText()), 'UI169b alert settings are saved');
await page.screenshot({ path: `${SHOTS}/ads_meta_overview.png`, fullPage: true });

// ---- Meta Ads > Reports and account health (migration 105)
await page.goto(`${APP}#/metaads/reports`);
await page.getByTestId('report-table').waitFor({ timeout: 15000 });
await page.waitForTimeout(600);
t = await page.getByTestId('meta-reports').innerText();
const rep0 = (await calls()).filter((x) => x.fn === 'ads-sync' && (x.args.jobs || []).includes('meta_report')).pop();
ok(/CPL Reels Delhi/.test(t) && /Broad India Static/.test(t) && /Live from Meta/.test(t) && /Total \(2 rows\)/.test(t) && /₹3,000/.test(t)
  && rep0?.args.report.level === 'campaign' && /^\d{4}-\d{2}-\d{2}$/.test(rep0.args.report.from),
  'UI170 Reports reads live from Meta: campaigns, totals and the period');
await page.getByLabel('Breakdown').selectOption('age');
await page.waitForTimeout(900);
t = await page.getByTestId('report-table').innerText();
ok(/Age/.test(t) && /18-24/.test(t) && /25-34/.test(t) && /Total \(4 rows\)/.test(t), 'UI171 a breakdown splits every row (Age)');
await page.getByTestId('vf-age').getByRole('button').first().click();
await page.getByTestId('vf-age').getByLabel('18-24').check();
await page.getByTestId('vf-age').getByRole('button', { name: 'Done' }).click();
await page.waitForTimeout(500);
t = await page.getByTestId('report-table').innerText();
ok(!/25-34/.test(t) && /Total \(2 rows, filtered\)/.test(t) && /₹1,800/.test(t), 'UI171b filtering an age group narrows rows and totals (₹3,000 × 60%)');
await page.getByLabel('Breakdown').selectOption('');
await page.getByLabel('Compare').check();
await page.waitForTimeout(900);
ok(/▲ 25% vs previous/.test(await page.getByTestId('report-totals').innerText()) && /▲25%/.test(await page.getByTestId('report-table').innerText()),
  'UI172 compare shows the change against the previous period for totals and rows');
await page.getByLabel('Columns').selectOption('video');
await page.waitForTimeout(400);
t = await page.getByTestId('report-table').innerText();
ok(/Hook rate/.test(t) && /ThruPlays/.test(t) && /Hold rate/.test(t) && /30\.00%/.test(t), 'UI173 the Video engagement preset shows hook rate, quartiles, ThruPlays and hold rate');
await page.getByLabel('Columns').selectOption('leads_crm');
await page.getByLabel('Select CPL Reels Delhi').check();
await page.getByTestId('drill').click();
await page.waitForTimeout(900);
const rep1 = (await calls()).filter((x) => x.fn === 'ads-sync' && (x.args.jobs || []).includes('meta_report')).pop();
ok(rep1.args.report.level === 'adset' && rep1.args.report.campaign_ids.join() === '7101' && /Delhi 18-24/.test(await page.getByTestId('report-table').innerText())
  && /Cost per admission/.test(await page.getByTestId('report-table').innerText()),
  'UI174 selecting a campaign and "View ad sets" drills down like Ads Manager; CRM columns are shown');
await page.getByRole('tab', { name: 'Ads', exact: true }).click();
await page.getByLabel('Columns').selectOption('relevance');
await page.waitForTimeout(900);
t = await page.getByTestId('report-table').innerText();
ok(/Quality ranking/.test(t) && /above avg/.test(t) && /below avg 35/.test(t), 'UI175 ads show Meta\'s quality, engagement and conversion rankings');
await page.getByRole('button', { name: 'Customize columns' }).click();
await page.getByTestId('customize').getByLabel('Cost per 1,000 people reached').check();
ok(/Cost per 1,000 people reached/.test(await page.getByTestId('report-table').innerText()) && await page.getByLabel('Columns').inputValue() === 'custom',
  'UI176 columns can be added (custom preset)');
await page.getByLabel('View name').fill('Ads relevance check');
await page.getByRole('button', { name: 'Save view' }).click();
await page.waitForTimeout(800);
ok((await rpc('api_ads_meta_report_options')).views.some((v) => v.name === 'Ads relevance check' && v.params.ui.cols.includes('cpr') && v.params.report.level === 'ad'),
  'UI177 a view (filters, level, columns) is saved');
const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 5000 }).catch(() => null), page.getByRole('button', { name: 'Export CSV' }).click()]);
ok(!!dl && /meta-report-ad-/.test(dl.suggestedFilename()), 'UI178 the table exports as CSV');
await page.screenshot({ path: `${SHOTS}/ads_meta_reports.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.waitForTimeout(500);
const ovr = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
ok(ovr <= 1, `UI180 Reports fit a phone screen; the table scrolls inside its box (${ovr}px)`);
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/metaads`);
await page.getByTestId('meta-health').waitFor({ timeout: 15000 });
t = await page.getByTestId('meta-health').innerText();
ok(/Account health/.test(t) && /64/.test(t) && /Warnings \(2\)/.test(t) && /Ad rejected: Pilot banna hai\? Reel/.test(t) && /₹420 \/ ₹1,000/.test(t)
  && /Meta's recommendations \(1\)/.test(t), 'UI179 the Overview shows Opportunity Score, pacing, warnings and Meta\'s recommendations');
await page.getByTestId('meta-warnings').getByRole('button', { name: 'Dismiss' }).first().click();
await page.waitForTimeout(800);
ok(/dismissed/.test(await page.getByTestId('meta-warnings').innerText()), 'UI179b Admin can dismiss a warning');

// ---- Two sections: Google Ads and Meta Ads, each with its own Setup checklist and stop
await page.goto(`${APP}#/metaads`);
await page.getByTestId('meta-ads').waitFor({ timeout: 15000 });
t = await body();
ok(/Meta Ads/.test(t) && ['Overview', 'Campaigns', 'Leads', 'Setup', 'Settings'].every((x) => t.includes(x)) && !/Rules and limits/.test(t),
  'UI130 Meta Ads is its own section with Overview, Campaigns, Leads, Setup and Settings');
await page.getByTestId('setup-banner-meta').waitFor({ timeout: 15000 });
ok(/Meta Ads setup: \d+ steps? left/.test(await page.getByTestId('setup-banner-meta').innerText()), 'UI131 a highlighted banner says how many Meta setup steps are left');
await page.getByTestId('setup-banner-meta').click();
await page.getByTestId('setup-meta').waitFor({ timeout: 15000 });
await page.waitForTimeout(800);
ok(await page.getByTestId('step-meta-db').getAttribute('data-done') === 'yes' && await page.getByTestId('step-meta-fns').getAttribute('data-done') === 'yes',
  'UI132 Continue opens Setup; database and Edge Function steps show done when Check now finds them');
let c0 = (await calls()).filter((x) => x.fn === 'ads-sync' && (x.args.jobs || []).join() === 'setup').length;
await page.getByRole('button', { name: 'Check all now' }).click();
await page.waitForTimeout(800);
ok((await calls()).filter((x) => x.fn === 'ads-sync' && (x.args.jobs || []).join() === 'setup').length > c0 && (await calls()).some((x) => x.fn === 'api_ads_setup_status' && x.args.p_platform === 'meta'),
  'UI133 Check now asks the server (setup status + deployed functions)');
await fetch(`${API}/__schema/100`);                           // a database that still needs 101
await page.getByRole('button', { name: 'Check all now' }).click();
await page.waitForTimeout(800);
ok(await page.getByTestId('step-meta-db').getAttribute('data-done') === 'no' && /A database update is waiting/.test(await page.getByTestId('step-meta-db').innerText()),
  'UI134 an older database shows "A database update is waiting"');
await page.getByTestId('step-meta-db').getByRole('button').first().click();
await page.getByTestId('sql-101').waitFor({ timeout: 15000 });
await page.waitForTimeout(800);
t = await page.getByTestId('sql-101').innerText();
ok(/101: Meta lead forms, part 2/.test(t) && (await page.locator('[data-testid="sql-102"]').count()) === 1 && (await page.locator('[data-testid="sql-103"]').count()) === 1
  && (await page.locator('[data-testid="sql-104"]').count()) === 1 && (await page.locator('[data-testid="sql-105"]').count()) === 1 && /INSERT INTO public\.ads_config \(key, value\) VALUES \('ads_schema', '101'\)/.test(t)
  && !(await page.locator('[data-testid="sql-100"]').count()) && /supabase\.com\/dashboard\/project\/.+\/sql\/new/.test(await page.getByTestId('step-meta-db').innerHTML()),
  'UI134b only the missing files (101-105) are shown, complete and ready to copy, with a link to the SQL editor');
await fetch(`${API}/__schema/105`);
await page.getByRole('button', { name: 'Check all now' }).click();
await page.waitForTimeout(800);
ok(await page.getByTestId('step-meta-db').getAttribute('data-done') === 'yes', 'UI134c after the update the database step is done again');
await page.getByTestId('step-meta-fns').getByRole('button').first().click();
t = await page.getByTestId('deploy-cmds').innerText();
ok(/^cd ~\/Desktop\/CRM\/CRM\/CRM$/m.test(t) && ['ads-sync', 'ads-intake', 'ads-meta-webhook', 'ads-agents'].every((f) =>
    new RegExp(`^npx -y supabase@latest functions deploy ${f} --no-verify-jwt --use-api --remote=\\S+ --yes$`, 'm').test(t)),
  'UI135 exact deploy commands for Supabase CLI 3 are shown (--remote, --use-api, --yes; JWT check as deployed)');
await page.getByTestId('step-meta-hook').getByRole('button').first().click();
ok(/functions\/v1\/ads-meta-webhook/.test(await page.getByTestId('hook-url').innerText()), 'UI136 the webhook step gives the callback URL to paste in Meta');
t = await page.getByTestId('step-meta-lead').innerText();
ok(/\d+ delivered: \d+ to Ads Leads, \d+ without an ad to Leads, \d+ test/.test(t) && /Meta has not sent a lead to the webhook yet/.test(t),
  'UI136b the test-lead step says what happened to delivered leads and whether the webhook has delivered one');
await page.getByTestId('step-meta-event').getByRole('button').first().click();
t = await page.getByTestId('step-meta-event').innerText();
ok(/Send for Meta's Verification Lead/.test(t) && /channel CRM/.test(t) && /starting with TEST/.test(t),
  'UI136c the test-event step handles Meta\'s CRM check (no code) and still accepts a TEST code');
await page.screenshot({ path: `${SHOTS}/ads_meta_setup.png`, fullPage: true });
await page.goto(`${APP}#/metaads/campaigns`);
await page.getByText('Test Lead Form').waitFor({ timeout: 15000 });
t = await body();
ok(!/Test Search/.test(t) && /not linked/.test(t), 'UI09c Meta Ads > Campaigns shows only Meta campaigns; one without UTM mapping says CRM is not linked');
await page.goto(`${APP}#/metaads/leads`);
await page.waitForTimeout(1500);
ok((await calls()).some((x) => x.fn === 'api_ads_lead_board' && x.args.p_platform === 'meta'), 'UI137 Meta Ads > Leads lists only leads that came through Meta');
await page.goto(`${APP}#/metaads/settings`);
await page.getByTestId('stop-meta').waitFor({ timeout: 15000 });
ok(!(await page.locator('[data-testid="stop-google"]').count()) && !/Google Ads API/.test(await body()), 'UI138 Meta settings show only Meta keys and the Meta stop');
const ex0 = (await rpc('api_ads_settings')).config.execution_paused;
await page.getByTestId('stop-meta').getByRole('button', { name: 'Stop' }).click();
await page.waitForTimeout(400);
if (await dlg().count()) { await dlg().getByRole('button', { name: /Stop|Yes|Confirm/ }).first().click(); await page.waitForTimeout(600); }
let cfgNow = (await rpc('api_ads_settings')).config;
ok(cfgNow.meta_paused === 'true' && cfgNow.google_paused !== 'true' && cfgNow.execution_paused === ex0, 'UI139 Stop Meta Ads only stops Meta; Google and the emergency stop are untouched');
await rpc('api_ads_platform_pause', { p_platform: 'meta', p_on: false });
await page.goto(`${APP}#/ads/settings`);
await page.getByTestId('stop-google').waitFor({ timeout: 15000 });
t = await body();
ok(/Google Ads/.test(t) && !(await page.locator('[data-testid="ads-meta-settings"]').count()) && /Rules and limits/.test(t), 'UI140 Google Ads settings have no Meta panel and keep the Google rules');
await page.goto(`${APP}#/ads/adsleads`);
await page.waitForTimeout(1500);
ok((await calls()).some((x) => x.fn === 'api_ads_lead_board' && x.args.p_platform === 'google'), 'UI141 Google Ads > Leads lists only leads that came through Google');

await page.goto(`${APP}#/ads/clients`);
await page.getByRole('button', { name: /^New client/ }).click();
await page.getByRole('button', { name: /^Next/ }).click();
t = await body();
ok(/Pick Google Ads, Meta or both/.test(t), 'UI21 step 1 asks Google, Meta or both first');
await page.locator('button[aria-pressed]', { hasText: 'Google Ads' }).first().click();   // the setup banner above also says Google Ads
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
await page.locator('button[aria-pressed]', { hasText: 'Google Ads' }).first().click();
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
await page.goto(`${APP}#/ads/report?client=${CLIENT}`);
await page.getByText('What needs attention').waitFor();
await sub('Autopilot');
await page.getByTestId('autopilot').waitFor();
t = await body();
ok(/Emergency stop is ON|Autopilot is flying/.test(t) && /Spend limits/.test(t) && /Tell the agents/.test(t), 'UI40 Autopilot tab shows state, limits and the instruction box');
ok(await page.getByLabel('Daily limit').inputValue() === '5000', 'UI41 the saved daily limit is shown');
await page.getByRole('button', { name: /500\/day/ }).click();
ok(await page.getByLabel('Monthly limit').inputValue() === '15200', 'UI42 a quick pick fills the monthly limit (x30.4)');
await page.getByTestId('ap-limits').getByRole('button', { name: 'Save' }).click(); await page.waitForTimeout(800);
let ap = await rpc('api_ads_autopilot');
ok(Number(ap.caps.daily) === 500 && Number(ap.caps.monthly) === 15200, 'UI43 limits saved to the database');
const sug = page.getByTestId('ap-suggestion').filter({ hasText: 'Target these cities' });
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

// stage 4: agents badge, daily report, playbook
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/ads/autopilot`); await page.getByTestId('autopilot').waitFor(); await page.waitForTimeout(800);
ok(/Agents online/.test(await page.getByTestId('ap-agents').innerText()), 'UI80 the agents badge says online when the Mac helper checked in');
ok(/450 per lead/.test(await page.getByTestId('ap-report').innerText()), 'UI81 the daily report is shown at the top');
await page.getByTestId('ap-playbook').getByRole('button').click();
ok(/website source next to every fact/.test(await page.getByTestId('ap-playbook').innerText()), 'UI82 what the agents learned opens with the evidence');
// ---- the team and the 24-hour rule (099)
{
  const ap = await rpc('api_ads_autopilot');
  const auto = ap.suggestions.find((x) => x.title === 'Block air hostess searches');
  const card = page.getByTestId('ap-suggestion').filter({ hasText: 'Block air hostess searches' });
  const txt = await card.innerText();
  ok(ap.mode !== 'auto' || !!auto.auto_at, 'UI100 in Automatic mode the server gives a Reviewer-approved suggestion a time to be applied by itself');
  ok(auto.auto_at ? /recommended option is applied by itself in 2[0-4] hours/.test(txt) && (await card.getByTestId('ap-sugg-auto').count()) === 1
                  : /waits for you/.test(txt), 'UI101 the suggestion card says in plain words when it will be applied if nobody answers');
  const manual = page.getByTestId('ap-suggestion').filter({ hasText: 'Slow server test' });
  ok(/This one waits for you\. It is never applied by itself/.test(await manual.innerText()), 'UI102 a suggestion the Reviewer did not approve says it waits for the owner');
  await page.getByTestId('ap-team').getByRole('button').click();
  const team = await page.getByTestId('ap-team').innerText();
  ok(await page.getByTestId('ap-team-member').count() === 14 && /Your ads team \(14\)/.test(team), 'UI103 the team list opens with all 14 members');
  ok(/Search Terms/.test(team) && /Bids & Budget/.test(team) && /Compliance Reviewer/.test(team) && /AI specialist/.test(team) && /Always on/.test(team)
    && /Nothing goes live without its approval/.test(team), 'UI104 each member shows its name, whether it is an AI specialist or always on, and what it does');
  ok(/Last worked .*Approved 0 change\(s\) and 1 suggestion/.test(team) && /Has not worked yet/.test(team), 'UI105 ... and when it last worked, or that it has not worked yet');
  await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(300);
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'UI106 the team list and the 24-hour note fit a phone without sideways scrolling');
  await page.screenshot({ path: `${SHOTS}/ads_team_phone.png`, fullPage: true });
  await page.setViewportSize({ width: 1280, height: 900 });
}

// ---- worst cases: a person with zero knowledge, two people at once, the server failing
await page.setViewportSize({ width: 1280, height: 900 });
const dialogs = [];
page.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss(); });
const toastSeen = async (re) => { for (let i = 0; i < 20; i++) { if (re.test(await page.locator('body').innerText())) return true; await page.waitForTimeout(150); } return false; };
await page.reload(); await page.getByTestId('autopilot').waitFor();
await page.getByRole('button', { name: 'Stop everything' }).click();
await dlg().getByRole('button', { name: 'Cancel' }).click(); await page.waitForTimeout(500);
ok(!(await rpc('api_ads_autopilot')).stopped, 'UI60 pressing Stop and then Cancel changes nothing');
const fundsBefore = (await rpc('api_ads_autopilot')).funds.added;
for (const bad of ['-500', 'abc', '0', '1.2.3', '10000 rupees please']) {
  await page.getByRole('button', { name: 'I added money' }).click();
  await dlg().getByRole('textbox').fill(bad); await dlg().getByRole('button', { name: 'OK' }).click();
  await page.waitForTimeout(300);
}
ok(Number((await rpc('api_ads_autopilot')).funds.added) === Number(fundsBefore) && await toastSeen(/Enter the amount you added as a number/),
  'UI61 nonsense top-ups (-500, abc, 0, 1.2.3, words) are refused with a plain message and nothing is saved');
await page.getByRole('button', { name: 'I added money' }).click();
await dlg().getByRole('textbox').fill('₹ 10,000'); await dlg().getByRole('button', { name: 'OK' }).click(); await page.waitForTimeout(800);
ok(Number((await rpc('api_ads_autopilot')).funds.added) === Number(fundsBefore) + 10000, 'UI62 "₹ 10,000" (with symbol and comma) is understood as 10000');
await page.getByLabel('Daily limit').fill('');
await page.getByLabel('Daily limit').pressSequentially('abc-5x');
ok(await page.getByLabel('Daily limit').inputValue() === '5', 'UI63 letters and minus signs cannot be typed into a limit');
await page.getByLabel('Daily limit').fill('');
await page.getByTestId('ap-limits').getByRole('button', { name: 'Save' }).click();
ok(await toastSeen(/daily limit of at least 1/) && Number((await rpc('api_ads_autopilot')).caps.daily) === 500, 'UI64 saving an empty limit explains why and keeps the old limit');
await page.getByLabel('Monthly limit').fill('100'); await page.getByLabel('Daily limit').fill('500');
await page.getByTestId('ap-limits').getByRole('button', { name: 'Save' }).dblclick(); await page.waitForTimeout(800);
ok(await toastSeen(/cannot be below the daily limit/) && Number((await rpc('api_ads_autopilot')).caps.monthly) === 15200, 'UI65 monthly below daily (double-clicked Save) is refused, nothing changes');
await page.reload(); await page.getByTestId('autopilot').waitFor();
await page.getByLabel('Instruction for the agents').fill('     ');
ok(await page.getByTestId('ap-tell').getByRole('button', { name: 'Send' }).isDisabled(), 'UI66 Send stays off for spaces only');
await page.getByLabel('Instruction for the agents').fill('<img src=x onerror=alert(1)> <b>bold</b>');
await page.getByTestId('ap-tell').getByRole('button', { name: 'Send' }).click(); await page.waitForTimeout(900);
ok(dialogs.length === 0 && (await page.getByTestId('ap-tell').innerText()).includes('<img src=x onerror=alert(1)>'), 'UI67 HTML typed by a user is shown as text and never runs');
await page.addInitScript(() => { delete window.webkitSpeechRecognition; delete window.SpeechRecognition; });   // e.g. Firefox
await page.reload(); await page.getByTestId('autopilot').waitFor();
await page.getByRole('button', { name: 'Speak' }).click();
ok(await toastSeen(/cannot take voice input/), 'UI68 Speak on a browser without voice input explains what to do');
// two people accept the same suggestion: the second gets a clear message
const page2 = await browser.newPage({ viewport: { width: 1280, height: 900 } });
await page2.goto(`${APP}#/ads/autopilot`); await page2.getByTestId('autopilot').waitFor();
await page.reload(); await page.getByTestId('autopilot').waitFor();
await page.getByTestId('ap-suggestion').filter({ hasText: 'Add a callout' }).getByRole('button', { name: /^Accept/ }).click(); await page.waitForTimeout(800);
await page2.getByTestId('ap-suggestion').filter({ hasText: 'Add a callout' }).getByRole('button', { name: /^Accept/ }).click(); await page2.waitForTimeout(800);
ok(/already accepted/.test(await page2.locator('body').innerText()) && (await rpc('api_ads_google_ops', { p_status: null, p_limit: 50 })).filter((o) => o.summary === 'Callout Online Classes').length === 1,
  'UI70 two people accepting the same suggestion at once: one change only, the second person is told');
await page2.close();
// the server fails: the tab says so instead of going blank
await page.route('**/rpc/api_ads_autopilot', (r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"Database is down (test)"}' }));
await page.reload(); await page.waitForTimeout(1500);
ok(/Database is down \(test\)/.test(await page.locator('body').innerText()), 'UI71 when the server fails, the tab shows the reason, not a blank page');
await page.unroute('**/rpc/api_ads_autopilot');
// a viewer who cannot approve
await as('10000000-0000-0000-0000-00000000000c');
await page.reload(); await page.getByTestId('autopilot').waitFor();
ok(await page.getByLabel('Daily limit').isDisabled() && /Only people who can approve ADS changes can edit these/.test(await page.getByTestId('ap-limits').innerText()),
  'UI72 a viewer sees the limits but cannot change them');
await page.getByRole('button', { name: 'Stop everything' }).click();
await dlg().getByRole('button', { name: 'Stop everything' }).click(); await page.waitForTimeout(800);
ok((await rpc('api_ads_autopilot')).stopped && await page.getByRole('button', { name: 'Resume' }).isDisabled(), 'UI73 a viewer can stop everything in an emergency, but cannot resume');
await as(ADMIN);
await rpc('api_ads_autopilot_stop', { p_stop: false });

// ---- Today page (everything in one place) and production-grade behaviour
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/ads/home?client=${CLIENT}`);
await page.getByTestId('today').waitFor({ timeout: 20000 });
t = await page.getByTestId('today').innerText();
ok(/Autopilot is flying|asks before acting|Emergency stop/.test(t) && /Spent this month/.test(t) && /Needs you/.test(t) && /Results/.test(t)
  && /Campaign health/.test(t) && /What changed/.test(t) && /Tell the agents/.test(t), 'UI90 Today shows status, needs, results, health, changes and the ask box on one page');
await page.screenshot({ path: `${SHOTS}/ads_today.png`, fullPage: true });
ok(await page.getByRole('tab').count() === 4, 'UI91 four tabs: Today, Campaigns, Ads Leads, More');
ok(/Brought results/.test(t) && /Cost money, brought nothing/.test(t), 'UI92 best and wasted searches are shown in plain words');
ok(/Test Search/.test(await page.getByTestId('health').innerText()), 'UI93 each running campaign shows its health');
const needsTxt = await page.getByTestId('needs').innerText();
ok(/not connected/.test(needsTxt) && /Accept/.test(needsTxt), 'UI94 "Needs you" lists the disconnected account and open suggestions, each with a button');
// a slow server: the button shows it is working, cannot be pressed twice, and the action happens once
let slowCalls = 0;
await page.route('**/rpc/api_ads_suggestion_decide', async (r) => { slowCalls++; await new Promise((res) => setTimeout(res, 2500)); await r.continue(); });
const sugBox = page.getByTestId('needs').getByTestId('ap-suggestion').filter({ hasText: 'Slow server test' });
const accBtn = sugBox.getByRole('button', { name: /^Accept/ });
await accBtn.click();
await page.waitForTimeout(300);
ok(await sugBox.getByRole('button', { name: 'Dismiss' }).isDisabled() && await page.getByTestId('working-bar').count() === 1,
  'UI95 while saving: the other buttons of the same item are locked and a "working" bar shows');
await accBtn.click({ force: true }).catch(() => {}); await accBtn.click({ force: true }).catch(() => {});
await page.waitForTimeout(3500);
ok(slowCalls === 1, `UI96 tapping again while it works does nothing (server called ${slowCalls} time)`);
await page.unroute('**/rpc/api_ads_suggestion_decide');
// the server never answers: the person gets a clear message instead of an endless spinner
await page.route('**/rpc/api_ads_agent_instruct', () => {});   // hang
await page.getByLabel('Instruction for the agents').fill('Pause nothing, just testing');
const sendBtn = page.getByTestId('ap-tell').getByRole('button', { name: 'Send' });
await page.evaluate(() => { window.__adsTimeoutTest = true; });
await sendBtn.click();
ok(await sendBtn.isDisabled(), 'UI97 Send is locked while it waits for the server');
await page.unroute('**/rpc/api_ads_agent_instruct');
await page.context().setOffline(true); await page.waitForTimeout(400);
ok(/You are offline/.test(await page.locator('body').innerText()), 'UI98 losing the internet shows a clear offline notice');
await page.context().setOffline(false); await page.waitForTimeout(800);
ok(!/You are offline/.test(await page.locator('body').innerText()), 'UI99 the notice goes away when the internet is back');

// phone width: no horizontal page scroll on Today
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${APP}#/ads/home?client=${CLIENT}`);
await page.getByTestId('today').waitFor();
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
