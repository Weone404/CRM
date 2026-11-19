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
ok(/GROWTH\s*Website\s*Content/i.test(await nav.innerText()), 'CN01 Content sits under Growth, after Website');
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
await page.getByRole('tab', { name: 'Ad creatives' }).click(); await page.waitForTimeout(400);
ok(/Cost card/.test(await body()) && /Use in Meta/.test(await body()) && /CPL admissions, Delhi NCR \(v1\)/.test(await body()), 'CN08 Ad creatives lists approved strategies and finished pictures to use in Meta');
ok(/Pilot after 12th: check this first/.test(await body()) && /Reel Studio/.test(await body()) && /Watch the ad video/.test(await body())
  && await page.getByTestId('content-video-meta').count() === 0, 'CN11 a finished Reel Studio ad video shows with its cover and link, not sendable before it is attached');
await page.getByTestId('content-attach').selectOption('900:v1'); await page.waitForTimeout(400);
let cv = await calls();
ok(cv.some((x) => x.fn === 'api_content_item_save' && x.args.p?.action === 'attach' && x.args.p.id === 22 && x.args.p.strategy_id === 900 && x.args.p.creative_key === 'v1'),
  'CN12 attaching sends the item, strategy and video creative');
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
ok(/GROWTH\s*Website/i.test(await nav.innerText()), 'WS01 Website is first under Growth');
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
