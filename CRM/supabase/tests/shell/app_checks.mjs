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


// Content (116)
await page.goto(`${APP}#/content`);
await page.getByRole('heading', { name: 'Content' }).waitFor({ timeout: 15000 });
await page.waitForTimeout(800);
b = await body();
ok(/GROWTH\s*Google\s*Content/i.test(await nav.innerText()), 'CN01 Content sits under Growth, after Google');
ok(/Reel Studio connected/.test(b) && /The plan for this week/.test(b) && /Fees and the path after class 12/.test(b) && /You asked: Push CPL fees/.test(b), 'CN02 the week shows the plan, the owner\'s note and whether Reel Studio is connected');
ok(/CPL cost, line by line/.test(b) && /Opens with: “Where does ₹45 lakh actually go\?”/.test(b) && /1,200 views · 30 sends · 2 enquiries/.test(b) && /Pilot after 12th: 6 steps/.test(b) && /AI presenter/.test(b), 'CN03 each day lists its items: hook, status, AI presenter, and for posts the views, sends and enquiries');
await page.getByText('Why and how').first().click(); await page.waitForTimeout(200);
ok(/Because: cpl fees in india, 900 seen/.test(await body()) && /Tracked link: https:\/\/weoneaviation\.in\/\?utm_source=instagram/.test(await body()), 'CN04 an item opens to its evidence and tracked link');
await page.getByRole('button', { name: 'Skip' }).first().click(); await page.waitForTimeout(500);
let cw2 = await calls();
ok(cw2.some((x) => x.fn === 'api_content_item_save' && x.args.p.action === 'skip' && x.args.p.id === 12), 'CN05 an approver skips a planned item');
await page.getByLabel('Anything to focus on').fill('More parents'); await page.getByTestId('content-plan-btn').click(); await page.waitForTimeout(500);
cw2 = await calls();
ok(cw2.some((x) => x.fn === 'api_content_plan' && x.args.p_note === 'More parents' && /^\d{4}-\d{2}-\d{2}$/.test(x.args.p_week)), 'CN06 Plan again sends the week and the focus note to the agents');
await page.screenshot({ path: '/tmp/content_week.png', fullPage: true });
await page.getByRole('tab', { name: 'Ideas' }).click(); await page.waitForTimeout(400);
ok(/What people want to know/.test(await body()) && /900 searches for cpl fees in india/.test(await body()) && /Nobody shows the cost breakdown/.test(await body()), 'CN07 Ideas shows the Demand Analyst\'s brief with evidence and gaps');
await page.getByRole('tab', { name: 'Ad creatives' }).click(); await page.waitForTimeout(500);
let sb = await body();
ok(/1 · Made/.test(sb) && /3 · Posted/.test(sb) && /7 leads/.test(sb) && /Learning · day 3 of 7/.test(sb) && /₹700\/day/.test(sb),
  'CN08 Ad creatives: the five stages, the campaign bar with budget and the 7-day learning lock');
await page.getByTestId('studio-approve').click(); await page.waitForTimeout(400);
let cs = await calls();
ok(cs.some((x) => x.fn === 'api_content_item_save' && x.args.p?.action === 'approve' && x.args.p.id === 31), 'CN11 a finished ad is approved with one button');
await page.getByTestId('studio-when').fill('2026-11-21T18:30'); await page.getByTestId('studio-schedule').click(); await page.waitForTimeout(400);
cs = await calls();
ok(cs.some((x) => x.fn === 'api_content_item_save' && x.args.p?.action === 'schedule' && x.args.p.id === 22 && new Date(x.args.p.post_at).getTime() === new Date('2026-11-21T18:30').getTime() && x.args.p.ai === true),
  'CN12 an approved ad is scheduled for Instagram with its time and the AI info label');
ok(/4,210/.test(sb) && /186/.test(sb) && /3 new/.test(sb), 'CN13 a posted ad shows views, likes, saves and new comments');
await page.getByTestId('studio-slot').first().selectOption('900:v2'); await page.getByTestId('studio-use').first().click(); await page.waitForTimeout(400);
cs = await calls();
ok(cs.some((x) => x.fn === 'api_content_item_save' && x.args.p?.action === 'use_in_ads' && x.args.p.id === 23 && x.args.p.strategy_id === 900 && x.args.p.creative_key === 'v2'),
  'CN14 "Use in ads" puts the posted ad into the chosen ad slot (only video slots are offered)');
await page.getByTestId('studio-comments-btn').click(); await page.waitForTimeout(500);
await page.getByLabel('Reply to parent_delhi').fill('Fee breakdown ke liye counselling book karein'); await page.getByRole('button', { name: 'Reply', exact: true }).click(); await page.waitForTimeout(400);
cs = await calls();
ok(/Fees kitni hai\?/.test(await body()) && cs.some((x) => x.fn === 'api_content_item_save' && x.args.p?.action === 'comments_seen')
  && cs.some((x) => x.fn === 'edge:ads-sync' && x.args.jobs?.[0] === 'ig_comment' && x.args.comment_id === '18000000000000001' && x.args.action === 'reply'),
  'CN15 comments open on the card, are marked read, and a reply goes to Instagram');
ok(/₹1,840/.test(sb) && /₹263/.test(sb) && /See its leads/.test(sb), 'CN16 an ad in Meta shows spend, leads, cost per lead and qualified leads');
{ const c25 = await page.locator('[data-testid="studio-card"]', { hasText: 'NIOS route to CPL' }).innerText();
  const c26 = await page.locator('[data-testid="studio-card"]', { hasText: 'Medical first' }).innerText();
  ok(/Reel Studio posts it/.test(c25) && /Reel Studio has it/.test(c25) && /Reply to comments in the Instagram app/.test(c26) && !/Reply to comments$/m.test(c26)
     && !(await page.getByTestId('studio-ig').count()),
    'CN17 an ad Reel Studio posts says so (and that it has it); its comments are answered in the Instagram app; no Instagram-key warning'); }
await page.screenshot({ path: '/tmp/content_studio.png', fullPage: true });
await page.getByRole('tab', { name: 'Results' }).click(); await page.waitForTimeout(400);
ok(/1,200 views and 2 website enquiries/.test(await body()), 'CN09 Results add up views and enquiries');
await page.setViewportSize({ width: 390, height: 844 }); await page.getByRole('tab', { name: 'This week' }).click(); await page.waitForTimeout(400);
ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'CN10 fits a phone screen');
await page.screenshot({ path: '/tmp/content_phone.png', fullPage: true });
await page.setViewportSize({ width: 1440, height: 900 });

// Website (Phase 3)
await page.goto(`${APP}#/website`);
await page.getByRole('heading', { name: 'Website' }).waitFor({ timeout: 15000 });
await page.waitForTimeout(1200);
b = await body();
ok(/GROWTH\s*Google/i.test(await nav.innerText()) && !/Website|Google Ads/.test(await nav.innerText()) && await nav.getByRole('button', { name: 'Google' }).getAttribute('aria-current') === 'page'
  && await page.getByTestId('google-crumb').getByRole('button', { name: 'Website' }).getAttribute('aria-current') === 'page', 'WS01 the old Website address still opens it, with Google highlighted and the Google strip above');
ok(/Clicks from Google\s*807\s*↑ 62% vs previous 28 days/.test(b) && /Seen on Google\s*231\.7K/.test(b) && /Average position\s*8\.3\s*Better · was 8\.9/.test(b), 'WS02 headline numbers with their change');
ok(/Visitors\s*—\s*GA4 has no visits yet: fix/.test(b), 'WS02b visitors card says GA4 needs fixing instead of showing 0');
ok(/On the site now\s*3\s*Most on CPL Course/.test(b), 'WS10 live visitors from GA4 realtime');
const fix = page.locator('[data-section="actions"]');
ok(/What to fix first/.test(await fix.innerText()) && (await fix.innerText()).includes('GA4 sends no visitor data') && /1 more/.test(await fix.innerText()), 'WS03 ranked fix list: top 5, the rest folded');
ok(!/dgca-pariksha/.test(await page.locator('[data-fold="pages"]').innerText()) || !(await page.locator('[data-fold="pages"]').getAttribute('open')), 'WS03b top pages folded by default');
await page.setViewportSize({ width: 1440, height: 1500 }); await page.waitForTimeout(900);
const trend = page.locator('[data-section="trend"]');
ok(/Google, day by day/.test(await trend.innerText()) && /Clicks up \d+% vs the 28 days before/.test(await trend.innerText()) && /Last 28 days\s*The 28 days before/.test(await trend.innerText())
  && await trend.locator('svg[aria-label="Clicks per day"] path').count() >= 3, 'WS11 day-by-day chart: this period against the one before, with a one-line takeaway');
await page.screenshot({ path: '/tmp/wv_overview.png', fullPage: true });
const tsvg = trend.locator('svg[aria-label="Clicks per day"]'); const tb = await tsvg.boundingBox();
await page.mouse.move(tb.x + tb.width * 0.6, tb.y + tb.height / 2); await page.waitForTimeout(200);
const tipT = (await trend.locator('[role="status"]').innerText()).replace(/\s+/g, ' ');
ok(/\d+ [A-Z][a-z]+ \d+ \d+ ?on \d+ [A-Z][a-z]+/.test(tipT), 'WS11b hover shows the day, its value and the same day of the period before');
await page.screenshot({ path: '/tmp/wv_hover.png', clip: { x: tb.x - 30, y: tb.y - 90, width: tb.width + 60, height: tb.height + 140 } });
await page.getByRole('button', { name: /Seen on Google/ }).click(); await page.waitForTimeout(300);
ok(await page.getByRole('tab', { name: 'Seen' }).getAttribute('aria-selected') === 'true' && await trend.locator('svg[aria-label="Seen per day"]').count() === 1, 'WS11c a headline card charts its own number');
await page.getByRole('tab', { name: 'Position' }).click(); await page.waitForTimeout(300);
ok(/Average position \d+\.\d, [\d.]+ places better/.test(await trend.innerText()), 'WS11d position charted (lower is better) with plain-language change');
ok(await page.locator('svg[aria-label="Searches by position"] [role="button"]').count() === 5 && /Top 3[\s\S]*50\+/.test(await page.locator('svg[aria-label="Searches by position"]').textContent()), 'WS12 searches by position: five bands with the period before');
await page.locator('svg[aria-label="Searches by position"] [role="button"]').nth(2).click(); await page.waitForTimeout(700);
ok(/#\/website\/searches\?f=almost$/.test(page.url()), 'WS12b the page-2 band opens the almost-page-1 searches');
await page.goto(`${APP}#/website`); await page.waitForTimeout(900);
await page.getByRole('button', { name: /11\s*Almost on page 1/ }).click(); await page.waitForTimeout(900);
let cw = await calls();
ok(/#\/website\/searches\?f=almost$/.test(page.url()) && cw.some((x) => x.fn === 'api_web_queries' && x.args.p_filter === 'almost'), 'WS04 an opportunity opens the Searches list already filtered');
ok(await page.getByRole('button', { name: 'Almost page 1' }).getAttribute('aria-pressed') === 'true', 'WS04b the matching filter is selected');
await page.getByText('egca login').first().click(); await page.waitForTimeout(300);
ok(/\/blogs\/egca-login\s*4,000 seen · pos 12/.test(await body()), 'WS05 a search opens to show the pages competing for it');
await page.getByRole('button', { name: 'All', exact: true }).click(); await page.waitForTimeout(700);
const map = page.locator('svg[aria-label="Searches by Google position and times seen"]');
ok(await map.locator('circle').count() >= 60, 'WS13 opportunity map: every search as a dot');
await page.screenshot({ path: '/tmp/wv_searches.png', fullPage: false });
const dot = await map.locator('circle').nth(20).boundingBox();
await page.mouse.move(dot.x + dot.width / 2, dot.y + dot.height / 2); await page.waitForTimeout(150);
const tipText = await page.locator('[role="status"]').first().innerText();
await page.mouse.click(dot.x + dot.width / 2, dot.y + dot.height / 2); await page.waitForTimeout(600);
ok(/Position\s*[\d.]+/.test(tipText) && /Click for its pages/.test(tipText) && /Page details appear after the next refresh/.test(await body()), 'WS13b hover names the search; clicking opens it in the list');
await page.getByRole('tab', { name: 'AI visibility' }).click(); await page.waitForTimeout(700);
b = await body();
ok(/ChatGPT\s*9\s*3\s*1/.test(b) && /\/cpl\s*6 · ChatGPT/.test(b), 'WS06 AI visits by assistant and their landing pages');
ok(/GPTBot\s*Blocked/.test(b) && /llms\.txt: Not found \(optional\)/.test(b) && /80 of 92/.test(b), 'WS06b AI readiness: crawlers, llms.txt, structured data');
await page.locator('input[type=file]').setInputFiles({ name: 'grounding.csv', mimeType: 'text/csv', buffer: Buffer.from('Grounding Query,Citations\n"pilot training, delhi",12\ncpl cost,3\n') });
await page.waitForTimeout(900);
cw = await calls();
ok(cw.some((x) => x.fn === 'api_web_copilot_upload' && x.args.p_kind === 'query' && x.args.p_rows.length === 2 && x.args.p_rows[0].k === 'pilot training, delhi' && x.args.p_rows[0].citations === 12), 'WS06c Copilot CSV is read in the browser and saved');
await page.getByRole('tab', { name: 'Speed & health' }).click(); await page.waitForTimeout(700);
b = await body();
await page.screenshot({ path: '/tmp/wv_health.png', fullPage: true });
ok(/Phone\s*Poor\s*· score 41/.test(b) && /Main content shows \(LCP\)\s*4\.1 s/.test(b) && /Reacts to taps \(INP\)\s*180 ms/.test(b) && /Layout stays still \(CLS\)\s*0\.05/.test(b) && /Fix first: Reduce unused JavaScript/.test(b), 'WS07 real-user speed per key page with the first fix');
ok(/Submitted and indexed/.test(b) && /Pages\s*92\s*Errors\s*1/.test(b) && /Title over ~60 characters/.test(b), 'WS07b indexing and site check');
await page.locator('[data-fold="broken"] summary').click();
ok(/\/old\s*404\s*3/.test(await body()), 'WS07c broken links fold');
await page.getByRole('tab', { name: 'Leads from website' }).click(); await page.waitForTimeout(500);
ok(/Website leads · 28 days\s*23\s*↑ 28%/.test(await body()), 'WS08 leads from the website with change');
await page.getByRole('button', { name: 'Refresh' }).click();
await page.getByText('Website data is up to date').waitFor({ timeout: 10000 });
cw = (await calls()).filter((x) => x.fn === 'edge:crm-website' && !(x.args.jobs.length === 1 && x.args.jobs[0] === 'live')).map((x) => x.args.jobs.join('+'));
ok(cw.join(',') === 'search+visitors,scan,speed+index', 'WS09 Refresh runs search+visitors, then the site check, then speed+indexing');

// Meta Ads > Overview: money and live campaign (121)
await page.goto(`${APP}#/metaads`); await page.waitForTimeout(1500);
{ const w = await page.getByTestId('meta-wallet').innerText();
  ok(/Available to spend\s*₹480/.test(w) && /About 4 days at ₹100\/day \+ GST/.test(w) && /Prepaid balance ₹566/.test(w) && /Spending limit left ₹480/.test(w)
     && /raise or reset the spending limit/.test(w)
     && /asset_id=564511644492586/.test(await page.getByTestId('wallet-add').getAttribute('href')),
    'ML-UI1 the wallet shows money left, days at the budget with GST, both limits, the spending-limit hint and an Add funds link'); }
{ const c = await page.getByTestId('meta-campaign').innerText();
  ok(/CPL leads Delhi NCR/.test(c) && /Running/.test(c) && /day 3 of 30/.test(c) && /₹312 of ₹3,000/.test(c) && /Spent today\s*₹104/.test(c) && /Cost per lead\s*₹52/.test(c)
     && /Qualified\s*2/.test(c) && /Pilot after 12th\s*₹180\s*4,120\s*4\s*₹45/.test(c),
    'ML-UI2 the campaign shows budget used against the total, today, leads, cost per lead, qualified and a row per ad');
  ok(/Rohit S · Student \(18\+\) · In 1-3 months\s*Not called · 12 min/.test(c) && /Meena K · Parent \/ guardian\s*Called in 4 min/.test(c),
    'ML-UI3 latest responses show the answers in plain words and how fast each lead was called'); }
await page.getByTestId('meta-campaign').getByRole('button', { name: 'Pause' }).click(); await page.waitForTimeout(600);
{ const cs = await calls();
  ok(cs.some((x) => x.fn === 'api_ads_meta_action_request' && x.args.p_kind === 'pause' && x.args.p_object_id === '7101')
     && cs.some((x) => x.fn === 'api_ads_meta_action_decide' && x.args.p_id === 77) && cs.some((x) => x.fn === 'edge:ads-sync' && x.args.jobs?.[0] === 'meta_actions'),
    'ML-UI4 Pause asks Meta to pause the campaign (approved and sent at once)'); }
await page.screenshot({ path: '/tmp/meta_money.png', fullPage: false });
await page.getByRole('tab', { name: /Campaigns/ }).first().click(); await page.waitForTimeout(800);
{ const secs = await page.getByTestId('camp-sections').innerText(); const b = await body();
  ok(/Currently running\s*1/.test(secs) && /Upcoming\s*1/.test(secs) && /Past\s*2/.test(secs) && /WOA Leads CPL Nov26/.test(b) && !/WhatsApp 2023/.test(b),
    'CS01 campaigns are split into Currently running, Upcoming and Past; running opens first'); }
await page.getByRole('tab', { name: /Upcoming/ }).click(); await page.waitForTimeout(300);
{ const b = await body(); ok(/Parents test Dec/.test(b) && /Starting/.test(b) && !/WOA Leads CPL Nov26/.test(b) && /waiting for the platform's review/.test(b), 'CS02 Upcoming: switched on, nothing spent yet'); }
await page.getByRole('tab', { name: /^Past/ }).click(); await page.waitForTimeout(300);
{ const b = await body(); ok(/WhatsApp 2023/.test(b) && /Engagement 2024/.test(b) && !/Parents test Dec/.test(b), 'CS03 Past: paused or ended'); }
await page.getByLabel('Search campaigns').fill('parents'); await page.waitForTimeout(300);
ok(/Parents test Dec/.test(await body()), 'CS04 a search looks through all three sections');


// Old "Academy" links still work
await page.goto(`${APP}#/academy`); await page.waitForTimeout(1200);
ok(/#\/academy$/.test(page.url()) && await nav.getByRole('button', { name: /^Students/ }).getAttribute('aria-current') === 'page', 'A10 old #/academy link opens a People screen');

// Google: one menu item, three cards, and Google My Business (139)
await page.setViewportSize({ width: 1280, height: 900 });
await mode('gbp=data');
await nav.getByRole('button', { name: 'Google' }).click();
await page.getByTestId('google-hub').waitFor({ timeout: 15000 }); await page.waitForTimeout(700);
b = await body();
ok(page.url().endsWith('#/google') && await page.getByTestId('google-hub').getByRole('button').count() === 3, 'GG01 Google opens a page with three cards');
ok(/Website[\s\S]*Clicks from Google\s*807\s*↑ 62%[\s\S]*Seen on Google\s*231\.7K/.test(b), 'GG02 Website card: clicks with their change, and how often the site was seen');
ok(/Google My Business\s*Connected[\s\S]*Profile views[\s\S]*Calls[\s\S]*Rating\s*4\.7 ★[\s\S]*213 reviews · 1 profile/.test(b), 'GG03 Business Profile card: views, calls, rating and reviews');
ok(/Google Ads\s*No spend since 15 Nov[\s\S]*Spend\s*₹847/.test(b), 'GG04 Google Ads card says plainly when the ads stopped spending');
await page.screenshot({ path: '/tmp/google_hub.png', fullPage: true });
const errsBefore = errors.length;
await page.getByTestId('google-card-ads').click(); await page.waitForTimeout(900);
ok(/#\/ads$/.test(page.url()) && await page.getByTestId('google-crumb').getByRole('button', { name: 'Google Ads' }).getAttribute('aria-current') === 'page'
  && await nav.getByRole('button', { name: 'Google' }).getAttribute('aria-current') === 'page', 'GG05 a card opens its section at the old address; Google stays highlighted');
ok(/Google Ads hit a problem/.test(await body()) && await page.getByTestId('google-crumb').isVisible(), 'GG05b if a section crashes (this stub gives Google Ads no data), the strip back to Google stays');
await page.getByTestId('google-crumb').getByRole('button', { name: 'Google', exact: true }).click(); await page.waitForTimeout(500);
ok(page.url().endsWith('#/google'), 'GG06 the strip leads back to the three cards');
await page.goBack(); await page.waitForTimeout(500);
ok(/#\/ads$/.test(page.url()), 'GG06b the browser Back button works across them');
await page.getByTestId('google-crumb').getByRole('button', { name: 'Google My Business' }).click(); await page.waitForTimeout(300);
errors.length = errsBefore;      // the Google Ads crash was the point of GG05b; it is not counted by A13
await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(900);
b = await body();
const g = page.getByTestId('gbp');
ok(/#\/gbp$/.test(page.url()) && /We One Aviation · last 28 days vs the 28 before/.test(b), 'GG07 Google My Business names the profile and the period');
ok(/Profile views\s*\d[\d,.K]*\s*[↑↓] \d+% vs previous 28 days/.test(b) && /Calls\s*\d+/.test(b) && /Website clicks\s*\d+/.test(b) && /Direction requests\s*\d+/.test(b) && /Messages\s*\d+/.test(b), 'GG08 five headline numbers, each with its change');
const gt = g.locator('[data-section="trend"]');
ok(/Day by day/.test(await gt.innerText()) && /Profile views (up|down) \d+% vs the 28 days before/.test(await gt.innerText()) && /Latest day: 21 Nov/.test(await gt.innerText())
  && await gt.locator('svg[aria-label="Profile views per day"] path').count() >= 3, 'GG09 day-by-day chart against the period before, with a one-line takeaway and the latest day Google has');
await page.getByRole('button', { name: /^Calls/ }).click(); await page.waitForTimeout(300);
ok(await gt.getByRole('tab', { name: 'Calls' }).getAttribute('aria-selected') === 'true' && await gt.locator('svg[aria-label="Calls per day"]').count() === 1, 'GG09b a headline card charts its own number');
ok(/of every 100\s*people who saw the profile/.test(b) && /Google search\s*70%/i.test(b) && /Google maps\s*30%/i.test(b) && /Phone\s*80%/.test(b) && /Computer\s*20%/.test(b), 'GG10 Search vs Maps, phone vs computer, and how many acted');
ok(/What people did next[\s\S]*Called[\s\S]*Opened the website[\s\S]*Asked for directions/.test(b) && await g.locator('svg[aria-label="Views by weekday"] [role="button"]').count() === 7, 'GG11 what people did, and the busiest weekdays');
ok(/Words people searched[\s\S]*October 2026[\s\S]*pilot training in delhi/.test(b) && !/flying school near me/.test(await g.locator('[data-section="words"]').innerText()), 'GG12 top search words of the latest month (rare words stay in the full list)');
ok(/4\.7 of 5[\s\S]*213 reviews · 2 new in 28 days · 2 without a reply/.test(await g.locator('[data-section="reviews"]').innerText().then((x) => x.replace(/\s+/g, ' '))), 'GG13 reviews: rating, total, new, waiting for a reply');
await page.setViewportSize({ width: 1280, height: 2400 }); await page.waitForTimeout(500);
await page.screenshot({ path: '/tmp/gbp_overview.png', fullPage: true });
await page.setViewportSize({ width: 1280, height: 900 });
await page.getByRole('button', { name: '7 days' }).click(); await page.waitForTimeout(800);
ok(/#\/gbp\?d=7$/.test(page.url()) && (await calls()).some((x) => x.fn === 'api_gbp_overview' && x.args.p_days === 7) && /last 7 days vs the 7 before/.test(await body())
  && /The 7 days before/.test(await gt.innerText()), 'GG14 the period is in the address and reaches the server; the chart compares 7 days with 7');
await page.getByRole('tab', { name: 'Search words' }).click(); await page.waitForTimeout(500);
b = await body();
ok(/#\/gbp\/words\?d=7$/.test(page.url()) && /flying school near me\s*fewer than 15/.test(b) && /pilot training in delhi\s*148\s*90\s*↑ 64%/.test(b) && /cpl course fees\s*20\s*—\s*new/.test(b), 'GG15 search words: counts, last month, change; rare words as "fewer than"');
await page.getByLabel('Find a search word').fill('DGCA'); await page.waitForTimeout(200);
ok(/dgca ground classes/.test(await body()) && !/pilot training in delhi/.test(await g.locator('table').innerText()), 'GG15b the list can be searched (any letter case)');
await page.getByLabel('Find a search word').fill('zzz'); await page.waitForTimeout(200);
ok(/No search word matches/.test(await body()), 'GG15c a search with no match says so');
await page.getByRole('tab', { name: 'Reviews' }).click(); await page.waitForTimeout(700);
b = await body();
ok(/Asha Verma[\s\S]*Great faculty[\s\S]*Your reply · 21 Nov\s*Thank you, Asha\./.test(b) && /Rating only, no text\./.test(b) && /No reply yet/.test(b), 'GG16 reviews with stars, text and your reply; rating-only reviews say so');
ok(/<img src=x onerror=alert\(1\)> Nobody picked up/.test(b) && await page.locator('img[src="x"]').count() === 0, 'GG16b review text is shown as text, never run as HTML');
// Review replies are built but not in use (141): the tab is a plain list, nothing to press, nothing sent
ok(await g.locator('[data-section="replies"]').count() === 0 && await g.locator('textarea').count() === 0 && await g.getByRole('tab', { name: 'Waiting for you' }).count() === 0
  && await g.getByRole('button', { name: /Send reply|Send again|Skip|Hold it back|Write a reply|Ask the AI|Reply settings/ }).count() === 0
  && /Replies are written outside the CRM/.test(await body()) && /Your reply · 17 Nov\s*Thank you, Sana/.test(await g.locator('[data-review="r6"]').innerText())
  && !/sent by the AI|Waiting for you|Sending shortly|AI is writing/.test(await body()), 'RV00 with review replies switched off (as shipped): a read-only list, no drafts, no buttons');
await page.goto(`${APP}#/gbp/reviews?d=7&f=waiting`); await page.waitForTimeout(800);
ok(await g.getByRole('tab', { name: 'All' }).getAttribute('aria-selected') === 'true' && (await calls()).filter((x) => x.fn === 'api_gbp_reviews').pop().args.p_filter === 'all', 'RV00b an old "waiting for you" link falls back to all reviews');
await mode('gbpReplies=on');
await page.goto(`${APP}#/gbp/reviews?d=7`); await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1200);
// Replies to reviews (140), switched on
const rep = g.locator('[data-section="replies"]');
ok(/The AI answers 4 and 5 star reviews by itself, at most 10 a day\. 1 to 3 star reviews are drafted and wait for you\./.test(await rep.innerText())
  && /4 waiting for you\s*1 sending shortly\s*1 with the AI\s*4 sent in 7 days\s*2 of 10 automatic today/.test(await rep.innerText()) && !/AI helper/.test(await rep.innerText()),
  'RV01 one sentence says how reviews are answered; counts of what waits, what is going out and what was sent');
const card = (id) => g.locator(`[data-review="${id}"]`);
ok(/Waiting for you/.test(await card('r2').innerText()) && (await card('r2').locator('textarea').inputValue()).startsWith('We are sorry nobody picked up your call') && /Second AI's note: Calm and specific\./.test(await card('r2').innerText()),
  'RV02 a 2-star review: the AI draft sits in a box you can change, with the second AI\'s note');
ok(/Sending shortly/.test(await card('r4').innerText()) && /Written and checked by the AI · goes to Google within 10 minutes\s*Thank you, Meera/.test(await card('r4').innerText()), 'RV03 a 5-star reply on its way says who wrote it and when it goes');
ok(/Your reply · 17 Nov · sent by the AI\s*Thank you, Sana/.test(await card('r6').innerText()) && !/sent by the AI/.test(await card('r1').innerText()), 'RV04 a sent reply says whether the AI sent it');
ok(/The AI left this to you: A money dispute: this needs a person\./.test(await card('r5').innerText()) && await card('r5').getByRole('button', { name: 'Send reply' }).isDisabled(), 'RV05 a review the AI would not answer: its reason, and nothing to send until you write');
ok(/Google did not take the reply: Reply violates the content policy\. <img src=y/.test(await card('r7').innerText()) && await page.locator('img[src="y"]').count() === 0 && await card('r7').getByRole('button', { name: 'Send again' }).isVisible(),
  'RV06 a reply Google refused: Google\'s reason as plain text, and a way to send again');
ok(/AI is writing a reply/.test(await card('r8').innerText()) && /The AI's draft was stopped:\s*Offers money, a gift or a discount/.test(await card('r9').innerText()), 'RV07 "AI is writing"; and a draft stopped by the rules says which rule');
let c0 = (await calls()).length;
await card('r2').getByRole('button', { name: 'Send reply' }).click(); await page.waitForTimeout(1300);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_reply_action' && x.args.p_id === 102 && x.args.p_action === 'send') && cw.some((x) => x.fn === 'edge:crm-google-business' && x.args.jobs.join() === 'reply')
  && /Reply sent to Google/.test(await body()), 'RV08 Send on an unchanged draft approves it and pushes it to Google at once');
c0 = (await calls()).length;
await card('r9').locator('textarea').fill('Thank you for telling us, Om. Please visit the centre so we can talk it through.');
await card('r9').getByRole('button', { name: 'Send reply' }).click(); await page.waitForTimeout(1300);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_reply_write' && x.args.p_review === 'r9' && x.args.p_send === true && x.args.p_text.startsWith('Thank you for telling us, Om')) && !cw.some((x) => x.fn === 'api_gbp_reply_action'),
  'RV09 a draft you changed goes out as your own words');
c0 = (await calls()).length;
await card('r4').getByRole('button', { name: 'Hold it back' }).click(); await page.waitForTimeout(900);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_reply_action' && x.args.p_id === 104 && x.args.p_action === 'cancel') && !cw.some((x) => x.fn === 'edge:crm-google-business'), 'RV10 an automatic reply can be held back before it goes');
c0 = (await calls()).length;
await card('r3').getByRole('button', { name: 'Ask the AI to write one' }).click();
await card('r3').getByLabel(/Anything the AI should know/).fill('Keep it to one line');
await card('r3').getByRole('button', { name: 'Ask the AI', exact: true }).click(); await page.waitForTimeout(900);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_reply_request' && x.args.p_review === 'r3' && x.args.p_note === 'Keep it to one line'), 'RV11 any unanswered review can be handed to the AI, with a note');
c0 = (await calls()).length;
await card('r3').getByRole('button', { name: 'Write a reply' }).click();
ok(await card('r3').getByRole('button', { name: 'Send reply' }).isDisabled(), 'RV12 an empty reply cannot be sent');
await card('r3').locator('textarea').fill('Thank you for the rating, Ravi.');
await card('r3').getByRole('button', { name: 'Send reply' }).click(); await page.waitForTimeout(1300);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_reply_write' && x.args.p_review === 'r3' && x.args.p_text === 'Thank you for the rating, Ravi.'), 'RV12b or you write it yourself');
await mode('gbpSend=waiting');
await card('r7').getByRole('button', { name: 'Send again' }).click(); await page.waitForTimeout(1300);
ok(/Saved\. Not on Google yet: .*Google has not approved this Cloud project yet/.test(await body()), 'RV13 if Google is not ready the reply is kept and the screen says why, it does not claim it was sent');
await mode('gbpSend=ok');
c0 = (await calls()).length;
await card('r5').getByRole('button', { name: 'Skip' }).click(); await page.waitForTimeout(800);
ok((await calls()).slice(c0).some((x) => x.fn === 'api_gbp_reply_action' && x.args.p_id === 105 && x.args.p_action === 'skip'), 'RV14 a review can be skipped');
await rep.getByRole('button', { name: 'Reply settings' }).click();
const set = page.getByTestId('reply-settings');
ok(await set.getByRole('button', { name: 'Save settings' }).isDisabled() && await set.getByLabel(/Send replies to good reviews automatically/).isChecked(), 'RV15 settings open with the saved values; nothing to save until something changes');
await set.getByLabel(/Automatic replies a day/).fill('99');
c0 = (await calls()).length;
await set.getByRole('button', { name: 'Save settings' }).click(); await page.waitForTimeout(500);
ok(await set.getByLabel(/Automatic replies a day/).evaluate((el) => el.validity.rangeOverflow) && !(await calls()).slice(c0).some((x) => x.fn === 'api_gbp_reply_settings_save'), 'RV16 99 automatic replies a day is stopped in the form (1 to 50)');
await set.getByLabel(/Automatic replies a day/).fill('10');
await set.getByLabel(/Send replies to good reviews automatically/).uncheck();
await set.getByLabel(/Signature/).fill('Team We One Aviation');
c0 = (await calls()).length;
await set.getByRole('button', { name: 'Save settings' }).click(); await page.waitForTimeout(800);
cw = (await calls()).slice(c0).filter((x) => x.fn === 'api_gbp_reply_settings_save');
ok(cw.length === 1 && JSON.stringify(cw[0].args.p) === JSON.stringify({ auto: false, signature: 'Team We One Aviation' }) && /Reply settings saved/.test(await body()), 'RV17 only what changed is sent to be saved');
await page.getByRole('tab', { name: 'Waiting for you' }).click(); await page.waitForTimeout(700);
ok(/[?&]f=waiting/.test(page.url()) && (await calls()).some((x) => x.fn === 'api_gbp_reviews' && x.args.p_filter === 'waiting') && await g.locator('[data-review]').count() === 4 && !/Asha Verma/.test(await body()),
  'RV18 "Waiting for you" lists only the reviews that need a person');
await mode('gbpHelper=never');
await page.goto(`${APP}#/gbp/reviews`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(900);
ok(/The AI helper has not run yet, so no reply is being written\./.test(await rep.innerText()), 'RV19 if the AI helper has never run, the screen says so instead of looking busy');
await mode('gbpHelper=old');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1200);
ok(/The AI helper last ran 3 days ago/.test(await rep.innerText()), 'RV19b or when it last ran, if that was long ago');
await mode('gbpHelper=ok'); await mode('gbpRole=viewer');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1200);
ok(await g.getByRole('button', { name: /Send reply|Send again|Skip|Hold it back|Write a reply|Ask the AI|Reply settings/ }).count() === 0 && await g.locator('textarea').count() === 0
  && /We are sorry nobody picked up your call/.test(await card('r2').innerText()), 'RV20 a viewer sees the drafts and states but has nothing to press');
await mode('gbpRole=admin');
await page.setViewportSize({ width: 390, height: 844 });
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1200);
await rep.getByRole('button', { name: 'Reply settings' }).click(); await page.waitForTimeout(300);
ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'RV21 replies, drafts and settings fit a phone screen');
await page.screenshot({ path: '/tmp/gbp_reviews_phone.png', fullPage: true });
await page.setViewportSize({ width: 1280, height: 900 });
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1200);
await page.screenshot({ path: '/tmp/gbp_reviews.png', fullPage: true });
await page.goto(`${APP}#/gbp/reviews?d=7`); await page.waitForTimeout(900);
await page.getByRole('tab', { name: '1 to 3 stars' }).click(); await page.waitForTimeout(600);
ok(/[?&]f=low/.test(page.url()) && (await calls()).some((x) => x.fn === 'api_gbp_reviews' && x.args.p_filter === 'low') && !/Asha Verma/.test(await body()), 'GG17 low-star filter is in the address and asks the server');
// Health check, posts, photos (143)
await page.goto(`${APP}#/gbp/health`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(900);
b = await body();
const hs = g.locator('[data-section="health"]');
ok(/We One Aviation\s*5 of 9 in order · read from Google 2 h ago/.test(b) && await hs.getByRole('link', { name: /Edit on Google/ }).getAttribute('href') === 'https://business.google.com/locations', 'HC01 health check: how many items are in order, when it was read, and a link to edit on Google');
let t = (await hs.locator('ul').first().innerText()).replace(/\s+/g, ' ');
ok(/^Website link Basic .*Opening hours Basic .*At least 10 photos of your own Good practice You have 4; customers added 31\. A post in the last 30 days Good practice Last post on 2 Sep 2026\.$/.test(t),
  'HC02 what is missing comes first, basics before advice, each with what Google has now');
ok(/<img src=z onerror=alert\(3\)>/.test(t) && await page.locator('img[src="z"]').count() === 0 && /advice, not rules set by Google/.test(b), 'HC03 text from Google is shown as text; advice is labelled as advice');
await hs.locator('summary').click();
ok(/5 in order/.test(await hs.locator('summary').innerText()) && /Verified on Google\s*Google has verified that you own this business\./.test(await hs.innerText()), 'HC04 what is in order is folded away, one click to see');
await mode('gbpHealth=basic');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
ok(/Only the basics are checked so far\. Hours, description, photos and posts are read on the next refresh\./.test(await body()), 'HC05 before the detailed read it says so, instead of calling things missing');
await mode('gbpHealth=full');
await page.getByRole('tab', { name: 'Posts' }).click(); await page.waitForTimeout(800);
b = await body();
ok(/#\/gbp\/posts/.test(page.url()) && /Live\s*20 Nov\s*New DGCA batch from 1 December\.\s*Weekday and weekend timings\.\s*Button: Learn more → https:\/\/weoneaviation\.in\/dgca\s*View on Google/.test(b)
  && /Rejected by Google\s*2 Sept?\s*<b>Call now<\/b> 98110/.test(b) && /Google no longer reports how many people saw a post/.test(b), 'PO01 posts with their state, text, button and a link to see them on Google; no invented view counts');
ok(await g.locator('[data-post="p1"] img').getAttribute('src') === 'https://lh3.googleusercontent.com/p1' && await g.locator('[data-post="p2"] img').count() === 0 && !/javascript:/.test(await g.locator('[data-post="p2"]').innerHTML()),
  'PO02 a picture is shown only from an https link; a script link from the data is never put in the page');
const np = g.locator('[data-section="new-post"]');
ok(await np.getByRole('button', { name: 'Publish on Google' }).isDisabled() && /0 of 1,500/.test(await np.innerText()), 'PO03 nothing to publish until something is written; the length is counted');
await np.getByLabel(/What do you want to tell people/).fill('Open day this Sunday at the Dwarka centre.');
await np.locator('select').selectOption('BOOK');
ok(await np.getByLabel(/Where the button leads/).isVisible(), 'PO04 a button asks for its link');
await np.locator('select').selectOption('CALL');
ok(await np.getByLabel(/Where the button leads/).count() === 0 && /calls the phone number on your profile/.test(await np.innerText()), 'PO04b a Call button needs no link and says which number it calls');
await np.locator('select').selectOption('LEARN_MORE'); await np.getByLabel(/Where the button leads/).fill('https://weoneaviation.in/open-day');
c0 = (await calls()).length;
await np.getByRole('button', { name: 'Publish on Google' }).click(); await page.waitForTimeout(1500);
cw = (await calls()).slice(c0);
ok(cw.some((x) => x.fn === 'api_gbp_post_create' && x.args.p_summary === 'Open day this Sunday at the Dwarka centre.' && x.args.p_cta_type === 'LEARN_MORE' && x.args.p_cta_url === 'https://weoneaviation.in/open-day' && x.args.p_photo_url === null && x.args.p_location === '11111111-1111-4111-8111-111111111111')
  && cw.some((x) => x.fn === 'edge:crm-google-business' && x.args.jobs.join() === 'post') && /Published on Google/.test(await body()) && await np.getByLabel(/What do you want to tell people/).inputValue() === '',
  'PO05 Publish saves the post, sends it to Google at once, says so and clears the form');
await np.getByLabel(/What do you want to tell people/).fill('already posted today');
c0 = (await calls()).length;
await np.getByRole('button', { name: 'Publish on Google' }).click(); await page.waitForTimeout(900);
ok(/already published on this profile in the last 24 hours/.test(await body()) && !(await calls()).slice(c0).some((x) => x.fn === 'edge:crm-google-business') && await np.getByLabel(/What do you want to tell people/).inputValue() === 'already posted today',
  'PO06 a refused post shows the reason, is not sent, and the text stays in the box');
await mode('gbpPostSend=fail');
await np.getByLabel(/What do you want to tell people/).fill('Call 98110 00000 today');
await np.getByRole('button', { name: 'Publish on Google' }).click(); await page.waitForTimeout(1500);
ok(/Not published: .*Summary contains a phone number\./.test(await body()) && await np.getByLabel(/What do you want to tell people/).inputValue() === 'Call 98110 00000 today', 'PO07 when Google refuses, the screen says "not published" with Google\'s reason and keeps the text');
await mode('gbpPostSend=ok'); await mode('gbpWaiting=yes');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
const wp = g.locator('[data-section="waiting-posts"]');
ok(/Not on Google[\s\S]*Not published\s*24 Nov\s*Open day this Sunday\.\s*Google did not confirm this post\. Check the profile on Google before publishing it again\./.test(await wp.innerText()), 'PO08 a post whose outcome is unknown is listed with what to check first');
c0 = (await calls()).length;
await wp.getByRole('button', { name: 'Remove' }).click(); await page.waitForTimeout(700);
ok((await calls()).slice(c0).some((x) => x.fn === 'api_gbp_post_cancel' && x.args.p_id === 9) && !(await calls()).slice(c0).some((x) => x.fn === 'api_gbp_post_create'), 'PO09 it can be removed without sending anything');
await mode('gbpWaiting=no'); await mode('gbpPost=no');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
ok(await g.locator('[data-section="new-post"]').count() === 0 && /Google does not allow posts on this profile\./.test(await body()), 'PO10 a profile Google does not allow posts on has no form, and says why');
await mode('gbpPost=yes'); await mode('gbpRole=viewer');
await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
ok(await g.locator('[data-section="new-post"]').count() === 0 && /New DGCA batch/.test(await body()), 'PO11 a viewer reads the posts but cannot publish');
await mode('gbpRole=admin');
await page.getByRole('tab', { name: 'Photos' }).click(); await page.waitForTimeout(800);
b = await body();
ok(/#\/gbp\/photos/.test(page.url()) && /4 of your own · 31 from customers · your last one added 14 Aug\. Google no longer reports how many people saw a photo\./.test(b) && /Cover 1/.test(b) && /Inside 2/.test(b) && /Logo 1/.test(b),
  'PH01 photos: yours, customers\', when you last added one, and how many of each kind');
ok(await g.locator('[data-photo]').count() === 3 && await g.locator('[data-photo="m1"] img').getAttribute('src') === 'https://lh3.googleusercontent.com/t1' && await g.locator('a[data-photo="m1"]').getAttribute('href') === 'https://lh3.googleusercontent.com/g1'
  && await g.locator('a[data-photo="m2"]').count() === 0 && /Video/.test(await g.locator('[data-photo="m2"]').innerText()) && /From a customer · 2 Nov/.test(await g.locator('[data-photo="customers/c1"]').innerText()),
  'PH02 each photo opens on Google; a video without a preview says so; a script link is never made clickable');
await page.getByRole('tab', { name: 'From customers' }).click(); await page.waitForTimeout(300);
ok(await g.locator('[data-photo]').count() === 1, 'PH03 "From customers" shows only those');
await mode('gbp=waiting');
await page.goto(`${APP}#/gbp/health?x=1`); await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
ok(/Getting Google My Business connected/.test(await body()) && await g.locator('[data-section="health"]').count() === 0, 'HC06 with no tracked profile the three new tabs show the setup steps, not empty lists');
await mode('gbp=data');
await page.setViewportSize({ width: 390, height: 844 });
for (const [h, name] of [['#/gbp/health', 'health check'], ['#/gbp/posts', 'posts'], ['#/gbp/photos', 'photos']]) {
  await page.goto(`${APP}${h}`); await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1100);
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), `HC07 fits a phone screen: ${name}`);
  await page.screenshot({ path: `/tmp/gbp_${h.split('/').pop()}_phone.png`, fullPage: true });
}
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto(`${APP}#/gbp/posts`); await page.reload(); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(1000);
await page.screenshot({ path: '/tmp/gbp_posts.png', fullPage: true });
await page.goto(`${APP}#/gbp/health`); await page.waitForTimeout(1000);
await page.screenshot({ path: '/tmp/gbp_health.png', fullPage: true });
await page.goto(`${APP}#/gbp/manage`); await page.waitForTimeout(900);
await page.getByRole('tab', { name: 'Profiles & logins' }).click(); await page.waitForTimeout(600);
b = await body();
ok(/We One Aviation\s*Connected[\s\S]*Book My Charter\s*Sign in again[\s\S]*Google no longer accepts this sign-in/.test(b), 'GG18 every Google login with its own state and what to do');
ok(/Business Profiles[\s\S]*We One Aviation[\s\S]*4\.7 ★ · 213 reviews[\s\S]*Flight school · Dwarka, New Delhi/.test(b) && /Book My Charter\s*Not verified on Google/.test(b)
  && await page.getByLabel('Track We One Aviation').isChecked() && !(await page.getByLabel('Track Book My Charter').isChecked()), 'GG19 every profile, with which ones are tracked');
await page.getByLabel('Track Book My Charter').click(); await page.waitForTimeout(900);   // the stub keeps answering "not tracked", so click, not check()
ok((await calls()).some((x) => x.fn === 'api_gbp_location_track' && x.args.p_on === true && x.args.p_id === '22222222-2222-4222-8222-222222222222'), 'GG20 ticking a profile starts tracking it');
await page.getByRole('button', { name: 'Add a Google login' }).click();
await page.getByLabel(/Name for this login/).fill('Second business'); await page.getByLabel(/Google refresh token/).fill('not-a-token');
ok(await page.getByLabel(/Google refresh token/).getAttribute('type') === 'password', 'GG21 the token box hides what is typed');
await page.getByRole('button', { name: 'Add login' }).click(); await page.waitForTimeout(700);
ok(/not a Google refresh token/.test(await body()) && !(await calls()).some((x) => x.fn === 'edge:crm-google-business' && x.args.connection), 'GG21b a wrong token is refused with the reason; Google is not called');
await page.getByLabel(/Google refresh token/).fill('1//0gSTUBstubSTUBstubSTUBstubSTUBstubSTUB');
await page.getByRole('button', { name: 'Add login' }).click(); await page.waitForTimeout(1200);
cw = await calls();
ok(cw.some((x) => x.fn === 'api_gbp_connection_add' && x.args.p_label === 'Second business') && cw.some((x) => x.fn === 'edge:crm-google-business' && x.args.connection === 'c3c3c3c3-3333-4333-8333-333333333333' && x.args.jobs.join() === 'discover')
  && /1 profile\(s\) in 1 account/.test(await body()), 'GG22 a new login is saved and checked with Google at once');
ok(!(await page.content()).includes('1//0gSTUB'), 'GG22b the token is gone from the page after saving');
await page.locator('[data-login="Book My Charter"]').getByRole('button', { name: 'Remove' }).click(); await page.waitForTimeout(200);
ok(/This deletes the login, its saved token, its 1 profile and every number and review/.test(await body()) && !(await calls()).some((x) => x.fn === 'api_gbp_connection_remove'), 'GG23 removing asks first and says exactly what goes');
await page.locator('[data-login="Book My Charter"]').getByRole('button', { name: 'Keep' }).click();
await page.goto(`${APP}#/gbp`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(600);
const before = (await calls()).length;
await page.getByRole('button', { name: 'Refresh' }).click(); await page.waitForTimeout(1500);
cw = (await calls()).slice(before).filter((x) => x.fn === 'edge:crm-google-business').map((x) => x.args.jobs.join());
ok(cw.join('|') === 'discover|sync' && /Google My Business is up to date/.test(await body()), 'GG24 Refresh checks the logins, then collects, and says when it is done');
await mode('gbp=waiting');
await page.goto(`${APP}#/gbp?d=90`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(900);
b = await body();
ok(/Getting Google My Business connected\s*2 of 5 done/.test(b) && /Google has approved the project for Business Profile data\s*Waiting for Google/.test(b) && /clears by itself when Google's approval email arrives/.test(b)
  && !/Profile views/.test(b), 'GG25 while Google has not approved the project: a checklist that says so, no empty charts');
await page.screenshot({ path: '/tmp/gbp_waiting.png', fullPage: true });
await page.goto(`${APP}#/google`); await page.getByTestId('google-hub').waitFor(); await page.waitForTimeout(600);
ok(/Google My Business\s*Waiting for Google[\s\S]*Nothing can be read until its approval email arrives/.test(await body()), 'GG25b the hub card says the same');
await mode('gbp=empty');
await page.goto(`${APP}#/gbp/reviews`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(900);
b = await body();
ok(/0 of 5 done|1 of 5 done/.test(b) && /A Google login that owns or manages the profile is added/.test(b) && !(await page.getByRole('button', { name: 'Refresh' }).count()), 'GG26 nothing connected: the checklist on every tab, no Refresh to press');
await page.goto(`${APP}#/gbp/nonsense?p=%27%3B+drop&d=abc`); await page.getByTestId('gbp').waitFor(); await page.waitForTimeout(700);
cw = await calls();
ok(cw[cw.length - 1].fn === 'api_gbp_overview' && cw[cw.length - 1].args.p_location === null && cw[cw.length - 1].args.p_days === 28 && await page.getByRole('tab', { name: 'Overview' }).getAttribute('aria-selected') === 'true',
  'GG27 a mangled address falls back to the overview, all profiles, 28 days');
await mode('gbp=data');
await page.setViewportSize({ width: 390, height: 844 });
for (const [h, name] of [['#/google', 'hub'], ['#/gbp', 'overview'], ['#/gbp/words', 'search words'], ['#/gbp/reviews', 'reviews'], ['#/gbp/manage', 'profiles & logins'], ['#/website', 'website with the strip']]) {
  await page.goto(`${APP}${h}`); await page.waitForTimeout(1100);
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), `GG28 fits a phone screen: ${name}`);
  if (h === '#/gbp') await page.screenshot({ path: '/tmp/gbp_phone.png', fullPage: true });
  if (h === '#/google') await page.screenshot({ path: '/tmp/google_hub_phone.png', fullPage: true });
}
const small = await page.evaluate(() => [...document.querySelectorAll('[data-testid="gbp"] button, [data-testid="google-crumb"] button')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && r.height < 32; }).map((e) => e.innerText.slice(0, 20)));
ok(small.length === 0, `GG29 every button is tall enough to tap${small.length ? ': ' + small.join(', ') : ''}`);
await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'More' }).click();
const gsheet = page.getByRole('dialog', { name: 'More' });
ok(/GROWTH\s*Google\s*Content/i.test(await gsheet.innerText()) && !/Website|Google Ads/.test(await gsheet.innerText()), 'GG30 phone: Google is one item in the More sheet');
await gsheet.getByRole('button', { name: 'Google' }).click(); await page.getByTestId('google-hub').waitFor();
ok(page.url().endsWith('#/google') && await page.getByTestId('google-hub').getByRole('button').count() === 3, 'GG30b phone: it opens the three cards');
await page.setViewportSize({ width: 1280, height: 900 });

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
