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
ok(/Good (morning|afternoon|evening)/.test(overview) && /Decisions waiting/.test(overview) && /Orders to ship/.test(overview), 'UI01 Home opens with a short morning summary');
ok(/Amazon is not connected yet/.test(overview), 'UI02 Home says Amazon is not connected yet');
ok(/Fast delivery is not on for \d+ product/.test(overview), 'UI02b Home suggests turning on fast delivery');
ok((await page.getByRole('tab').count()) === 5, 'UI02c only 5 tabs: Home, My Products, Decisions, Sales, More');
await page.screenshot({ path: `${SHOTS}/amz_overview.png`, fullPage: true });

await nav('My Products');
await page.getByText('Delivery speed').waitFor();
ok((await page.locator('[data-sku]').count()) === 20, 'UI03 My Products shows all 20 products as cards');
ok(/Ships not known yet/.test(await page.locator('body').innerText()), 'UI03b each card shows its dispatch time');
await page.screenshot({ path: `${SHOTS}/amz_listings.png`, fullPage: false });

// Editor: name & text with AI ideas
await page.locator('[data-sku="69-E0DG-L8W8"]').click();
await page.getByRole('tab', { name: 'Name & text' }).click();
const title = page.getByLabel('Product name', { exact: true });
await title.fill('Nitaniya B5 PU Leather Diary 2027 Light Tan with Pen Holder and Ribbon Marks');   // 76 chars
await page.getByText(/Title is 76 characters/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI04 76-character name flagged while typing'))
  .catch(() => ok(false, 'UI04 76-character name flagged while typing'));
ok(await page.getByRole('button', { name: 'Save & publish' }).isDisabled(), 'UI04b Save is disabled while a rule fails');
await page.getByRole('button', { name: 'Generate with AI' }).first().click();
const ideas = page.getByRole('region', { name: 'AI ideas' });
await ideas.waitFor();
const n = await ideas.getByRole('button', { name: 'Use this' }).count();
ok(n >= 3 && n <= 5, `UI22 Generate with AI gives 3-5 ideas (${n})`);
await ideas.getByLabel('Idea i0').fill('Nitaniya B5 PU Leather Diary 2027, Light Tan, Pen Holder, 160 Pages');
await ideas.getByRole('button', { name: 'Use this' }).first().click();
ok((await title.inputValue()) === 'Nitaniya B5 PU Leather Diary 2027, Light Tan, Pen Holder, 160 Pages', 'UI23 an edited idea is used in the field');
await page.waitForTimeout(800);
ok(!(await page.locator('body').innerText()).includes('Title is'), 'UI05 compliant name clears the problem');
await page.getByRole('button', { name: 'Generate with AI' }).first().click();
await ideas.getByRole('button', { name: 'Ask Claude for better ideas' }).click();
await page.waitForTimeout(600);
ok((await rpcAs('api_amz_suggestions', { p_sku: '69-E0DG-L8W8' })).some((r) => r.field === 'title' && r.status === 'waiting'), 'UI24 Ask Claude queues a request for this field');
await ideas.getByRole('button', { name: 'Close' }).click();
await page.screenshot({ path: `${SHOTS}/amz_studio.png`, fullPage: false });
await page.getByRole('button', { name: 'Save & publish' }).click();
await page.waitForTimeout(1500);
let calls = await (await fetch(`${API}/__calls`)).json();
ok(calls.some((c) => c.fn === 'api_amz_publish') && calls.some((c) => c.fn === 'amazon-execute'), 'UI06 Admin Save & publish sends the change to Amazon');
let q = await rpcAs('api_amz_queue', { p_status: 'approved' });
ok(q.length === 1 && q[0].after.title === 'Nitaniya B5 PU Leather Diary 2027, Light Tan, Pen Holder, 160 Pages', 'UI07 change is approved in the database');

// Photos: upload a white 1200px photo as the new cover
await page.getByRole('tab', { name: 'Photos' }).click();
const b64 = await page.evaluate(() => { const c = document.createElement('canvas'); c.width = 1200; c.height = 1200; const x = c.getContext('2d');
  x.fillStyle = '#fff'; x.fillRect(0, 0, 1200, 1200); x.fillStyle = '#8B5A2B'; x.fillRect(300, 200, 600, 800); return c.toDataURL('image/png').split(',')[1]; });
await page.getByLabel('Upload photos').setInputFiles({ name: 'cover.png', mimeType: 'image/png', buffer: Buffer.from(b64, 'base64') });
await page.getByAltText('Photo 1').waitFor({ timeout: 5000 }).catch(() => {});
ok((await page.getByRole('button', { name: /^Remove photo/ }).count()) >= 1 && (await fetch(`${API}/__calls`).then((r) => r.json())).some((c) => c.fn === 'amazon-upload'),
  'UI25 a photo is uploaded and shown');
await page.getByText(/pure white background/).first().click();
await page.getByRole('button', { name: 'Save & publish' }).click();
await page.waitForTimeout(1500);
q = (await rpcAs('api_amz_queue', { p_status: 'approved' })).filter((c) => c.after.images);
ok(q.length === 1 && q[0].after.images[0].white_bg === true && q[0].after.images[0].has_text === false, 'UI26 new cover published with its checks');
await page.screenshot({ path: `${SHOTS}/amz_photos.png`, fullPage: false });

// Price below the floor is refused in the editor
await page.getByRole('tab', { name: 'Price & stock' }).click();
await page.getByLabel('Price').fill('298');
await page.getByText(/below the floor of ₹299/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI09 ₹298 price is refused in the editor'))
  .catch(() => ok(false, 'UI09 ₹298 price is refused in the editor'));
await page.getByRole('tab', { name: 'Details' }).click();
await page.getByRole('button', { name: 'All products' }).click();
await page.waitForTimeout(400);

// Delivery speed for all products
await nav('My Products');
await page.getByRole('button', { name: 'Apply to all products' }).click();
await dlg().getByRole('button', { name: 'Yes, prepare it' }).click();
await page.getByText('Same-day dispatch').first().waitFor({ timeout: 5000 }).catch(() => {});
let pend = (await rpcAs('api_amz_queue', { p_status: 'pending' })).filter((c) => c.kind === 'dispatch');
const kids = (await rpcAs('api_amz_listings')).filter((l) => !l.is_parent).length;
ok(pend.length === kids && pend.every((c) => c.after.handling_days === 0), `UI18 "Apply to all products" drafts same-day dispatch for every product (${pend.length}/${kids})`);
ok(/Decisions/.test(await page.locator('[role=tab][aria-selected=true]').innerText()), 'UI19 it opens Decisions');
await page.locator('[data-change]').first().waitFor();
await page.screenshot({ path: `${SHOTS}/amz_dispatch.png`, fullPage: false });
// Change one suggestion before approving
const card1 = page.locator('[data-change]').filter({ hasText: 'Same-day dispatch' }).nth(0);
await card1.getByRole('button', { name: 'Change', exact: true }).click();
await card1.getByLabel('Dispatch time').selectOption('1');
await card1.getByRole('button', { name: 'Approve my version' }).click();
await page.waitForTimeout(1500);
calls = await (await fetch(`${API}/__calls`)).json();
ok(calls.some((c) => c.fn === 'api_amz_revise'), 'UI27 Change lets you edit a suggestion and approve your version');
// Reject one with a quick reason
const card2 = page.locator('[data-change]').filter({ hasText: 'Same-day dispatch' }).filter({ has: page.getByRole('button', { name: 'Reject' }) }).nth(0);
await card2.getByRole('button', { name: 'Reject', exact: true }).click();
await card2.getByRole('button', { name: 'Not now' }).click();
await page.waitForTimeout(1000);
ok((await rpcAs('api_amz_queue', { p_status: 'rejected' })).some((c) => c.kind === 'dispatch' && c.reject_reason === 'Not now'), 'UI28 Reject with one tap and a quick reason');
await page.getByRole('button', { name: /^Approve all safe \(\d+\)$/ }).click();
await dlg().getByRole('button', { name: 'Approve all' }).click();
await page.waitForTimeout(1500 + kids * 250);
q = (await rpcAs('api_amz_queue', { p_status: 'approved' })).filter((c) => c.kind === 'dispatch');
ok(q.length === kids - 1 && q.filter((c) => c.after.handling_days === 1).length === 1, `UI20 "Approve all safe" sends the rest (${q.length}/${kids - 1})`);
await page.screenshot({ path: `${SHOTS}/amz_queue.png`, fullPage: false });

// Fix All + ranked choices in a pop-up
const svc = async (fn, args) => (await fetch(`${API}/__svc/${fn}`, { method: 'POST', body: JSON.stringify(args) })).json();
await nav('Home'); await nav('Decisions');
await page.getByRole('button', { name: 'Fix All with Claude' }).click();
await dlg().getByRole('button', { name: 'Fix all with Claude' }).click();
await page.getByText(/Claude is fixing \d+ product/).first().waitFor({ timeout: 5000 }).then(() => ok(true, 'UI33 Fix All hands every problem to Claude and shows progress'))
  .catch(() => ok(false, 'UI33 Fix All hands every problem to Claude and shows progress'));
const job = await svc('svc_amz_bridge_claim', { p_by: 'mac' });
const prob = job.context.problems.find((p) => p.sku === job.job.sku);
await svc('svc_amz_bridge_answer', { p_id: job.job.id, p_answer: 'Fixed.', p_options: null, p_by: 'mac', p_drafts: [
  { kind: 'listing', sku: job.job.sku, after: { description: 'Choice one text.' }, summary: 'Clearer description', reason: 'Fixes the problem', group: String(prob.id), rank: 1, rank_reason: 'Keeps your main search words and reads naturally.', finding_id: prob.id },
  { kind: 'listing', sku: job.job.sku, after: { description: 'Choice two text.' }, summary: 'Shorter description', reason: 'Fixes the problem', group: String(prob.id), rank: 2, rank_reason: 'Shorter, but drops one search word.', finding_id: prob.id }] });
await nav('Home'); await nav('Decisions');
await page.getByRole('button', { name: /See 1 other choice ranked/ }).waitFor({ timeout: 5000 });
ok((await page.getByText('Shorter description').count()) === 0, 'UI34 only the best choice shows as a card; others are one tap away');
await page.getByRole('button', { name: /See 1 other choice ranked/ }).click();
const pop = page.getByRole('dialog').last();
await pop.getByText("What's wrong now").waitFor();
ok((await pop.getByText('#1').count()) === 1 && (await pop.getByText('#2').count()) === 1, 'UI35 pop-up shows what is wrong next to ranked solutions');
await page.screenshot({ path: `${SHOTS}/amz_problem.png`, fullPage: false });
await pop.getByRole('button', { name: 'Why this rank?' }).first().click();
await page.getByText('Keeps your main search words and reads naturally.').waitFor({ timeout: 3000 }).then(() => ok(true, 'UI36 Why this rank? explains the ranking'))
  .catch(() => ok(false, 'UI36 Why this rank? explains the ranking'));
await page.screenshot({ path: `${SHOTS}/amz_why.png`, fullPage: false });
await page.getByRole('button', { name: 'Close pop-up' }).last().click();
await pop.getByRole('button', { name: 'Use this' }).first().click();
await page.waitForTimeout(1500);
const alts = (await rpcAs('api_amz_decisions', { p_status: 'all' })).filter((c) => c.finding_id === prob.id);
ok(alts.find((c) => c.alt_rank === 1)?.status === 'approved' && alts.find((c) => c.alt_rank === 2)?.status === 'cancelled', 'UI37 using one choice approves it and closes the other');
await page.locator('[data-problem]').first().click();
await page.getByRole('dialog').last().getByText("What's wrong now").waitFor({ timeout: 4000 }).then(() => ok(true, 'UI38 each problem card opens its own pop-up'))
  .catch(() => ok(false, 'UI38 each problem card opens its own pop-up'));
await page.keyboard.press('Escape');

await nav('Home');
await page.waitForTimeout(800);
await page.getByRole('button', { name: 'Review', exact: true }).count().then((n) => ok(n === 0, 'UI21 Home no longer asks to review once all are decided'));

// Live Claude chat
await page.getByRole('button', { name: 'Ask Claude' }).click();
const chatBox = page.getByRole('dialog', { name: 'Claude chat' });
await chatBox.getByText(/Not connected|offline/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI29 chat shows honestly that the Mac is not connected'))
  .catch(() => ok(false, 'UI29 chat shows honestly that the Mac is not connected'));
await chatBox.getByLabel('Message to Claude').fill('Which diary sells most?');
await chatBox.getByRole('button', { name: 'Send' }).click();
await chatBox.getByText(/Waiting\. Claude answers when your Mac is online/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI30 a message waits with a clear note when the Mac is offline'))
  .catch(() => ok(false, 'UI30 a message waits with a clear note when the Mac is offline'));
ok((await chatBox.getByRole('button', { name: 'Speak' }).count()) === 1, 'UI31 a mic button is there for voice');
await page.screenshot({ path: `${SHOTS}/amz_chat.png`, fullPage: false });
await chatBox.getByRole('button', { name: 'Close', exact: true }).click();

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
await page.getByRole('button', { name: 'Connect my Mac' }).click();
await page.getByText(/^nitb_[0-9a-f]{60,}$/).waitFor({ timeout: 5000 }).then(() => ok(true, 'UI32 Settings makes a one-time Mac connection code'))
  .catch(() => ok(false, 'UI32 Settings makes a one-time Mac connection code'));
await page.getByLabel('Add alert email').fill('owner@example.com');
await page.getByRole('button', { name: 'Add', exact: true }).click();
await page.getByRole('button', { name: 'Remove owner@example.com' }).waitFor({ timeout: 4000 }).then(() => ok(true, 'UI39 alert emails can be added (and removed) in Settings'))
  .catch(async () => ok(false, 'UI39 alert emails can be added (and removed) in Settings ' + await toast()));
await page.getByRole('button', { name: 'Test Connection' }).click();
await page.getByText(/Connected: All good/).first().waitFor({ timeout: 5000 }).then(() => ok(true, 'UI13 Test Connection result shown'))
  .catch(() => ok(false, 'UI13 Test Connection result shown'));
await page.screenshot({ path: `${SHOTS}/amz_settings.png`, fullPage: true });

for (const label of ['Search words', 'Competitors', 'Account health', 'To-do list', 'History']) {
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
