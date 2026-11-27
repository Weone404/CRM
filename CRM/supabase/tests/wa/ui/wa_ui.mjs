// WhatsApp UI checks in headless Chromium at phone (390), tablet (820) and laptop (1440) widths, against the fake API.
// Checks content, the phone list/chat switch, sending a message, the flow simulator, no sideways scrolling and no
// console errors. Screenshots go to /tmp/wa_ui_<width>_<screen>.png.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');
const BASE = 'http://localhost:5198/';
let fails = 0;
const ok = (c, name) => { if (c) console.log(`PASS ${name}`); else { fails++; console.log(`FAIL ${name}`); } };

const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
for (const [w, h, tag] of [[390, 844, 'phone'], [820, 1180, 'tablet'], [1440, 900, 'laptop']]) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Download the React DevTools|Failed to load resource/.test(m.text())) errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('response', (r) => { if (r.status() >= 400 && !/favicon/.test(r.url())) errors.push(`${r.status()} ${r.url().replace(/^https?:\/\/[^/]+/, '')}`); });
  const shot = (name) => page.screenshot({ path: `/tmp/wa_ui_${w}_${name}.png`, fullPage: false });
  // Nothing sticks out of the screen: no sideways scroll, and no visible element (outside a deliberate horizontal
  // scroller such as a table or a row of chips) whose right edge is past the screen's edge.
  const noSideScroll = async (where) => {
    const bad = await page.evaluate(() => {
      const scroller = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const o = getComputedStyle(p).overflowX; if (o === 'auto' || o === 'scroll') return true; } return false; };
      const out = [];
      if (document.documentElement.scrollWidth > innerWidth + 1) out.push(`page ${document.documentElement.scrollWidth}px`);
      for (const el of document.querySelectorAll('#root *')) {
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height || getComputedStyle(el).visibility === 'hidden') continue;
        if (r.right > innerWidth + 1 && !scroller(el)) { out.push(`${el.tagName.toLowerCase()} ${(el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 30)} → ${Math.round(r.right)}px`); if (out.length > 3) break; }
      }
      return out;
    });
    ok(bad.length === 0, `${tag}: nothing off-screen on ${where}${bad.length ? ` (${bad.join('; ')})` : ''}`);
  };

  await page.goto(`${BASE}#/whatsapp/inbox`);
  await page.getByText('Riya Sharma').first().waitFor({ timeout: 15000 });
  ok(await page.getByText('Test mode').first().isVisible(), `${tag}: header shows Test mode`);
  for (const n of ['Riya Sharma', 'Kabir Mehta', 'Vikram Jet Charters']) ok(await page.getByText(n).first().isVisible(), `${tag}: chat list shows ${n}`);
  await noSideScroll('Inbox'); await shot('inbox');

  await page.getByRole('button', { name: /Riya Sharma/ }).first().click();
  await page.getByText('Mohali').first().waitFor({ timeout: 10000 });
  ok(await page.getByText('Book free counselling').first().isVisible(), `${tag}: chat shows the bot's buttons`);
  ok(await page.getByText('Needs a person', { exact: true }).last().isVisible(), `${tag}: chat shows it needs a person`);
  if (w < 1024) ok(!(await page.getByPlaceholder('Search name or number').isVisible()), `${tag}: chat opens full width (list hidden)`);
  else ok(await page.getByPlaceholder('Search name or number').isVisible(), `${tag}: list and chat side by side`);
  await page.getByLabel('Message').fill('Hi Riya, I will call you at 5 pm today.');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByText('Hi Riya, I will call you at 5 pm today.').last().waitFor({ timeout: 10000 });
  ok(true, `${tag}: typed message sent and shown in the chat`);
  await noSideScroll('chat'); await shot('chat');
  if (w < 1024) { await page.getByLabel('Back to chats').click(); ok(await page.getByPlaceholder('Search name or number').isVisible(), `${tag}: back arrow returns to the list`); }

  await page.goto(`${BASE}#/whatsapp/inbox?f=human`);
  await page.getByText('Kabir Mehta').first().waitFor({ timeout: 10000 });
  const hidden = await page.getByText('Vikram Jet Charters').first().waitFor({ state: 'hidden', timeout: 10000 }).then(() => true, () => false);
  ok(hidden && await page.getByText('Riya Sharma').first().isVisible(), `${tag}: "Needs a person" filter shows only chats waiting for a person`);

  await page.goto(`${BASE}#/whatsapp/flow`);
  await page.getByText('Welcome (student or parent)').first().waitFor({ timeout: 10000 });
  await page.getByPlaceholder('Type as the lead').fill('fees kitna hai');
  await page.getByPlaceholder('Type as the lead').press('Enter');
  await page.getByText('A person takes over this chat now').first().waitFor({ timeout: 10000 });
  ok(true, `${tag}: Try it: fees question hands over to a person`);
  await page.getByPlaceholder('Type as the lead').fill('hi');
  await page.getByPlaceholder('Type as the lead').press('Enter');
  await page.getByRole('button', { name: "I'm a student" }).last().waitFor({ timeout: 10000 });
  await page.getByRole('button', { name: "I'm a student" }).last().click();
  await page.getByText(/Physics and Maths/).last().waitFor({ timeout: 10000 });
  ok(true, `${tag}: Try it: tapping a button moves the flow on`);
  await noSideScroll('Flow'); await shot('flow');

  await page.goto(`${BASE}#/whatsapp/templates`);
  await page.getByText('weone_followup_2').first().waitFor({ timeout: 10000 });
  ok(await page.getByText('Rejected').first().isVisible(), `${tag}: Templates shows Meta's status`);
  await noSideScroll('Templates');

  await page.goto(`${BASE}#/whatsapp/setup`);
  await page.getByText('10 of 11 done').first().waitFor({ timeout: 10000 });
  ok(await page.getByText('Callback URL', { exact: false }).first().isVisible(), `${tag}: Setup shows the Callback URL to copy`);
  await noSideScroll('Setup'); await shot('setup');

  await page.goto(`${BASE}#/whatsapp/settings`);
  await page.getByText('Which new leads get a welcome').first().waitFor({ timeout: 10000 });
  await page.getByRole('switch', { name: 'JustDial' }).click();
  await page.getByText('JustDial: on').first().waitFor({ timeout: 10000 });
  ok(true, `${tag}: a Settings switch saves at once`);
  await page.getByRole('switch', { name: 'JustDial' }).click();
  await noSideScroll('Settings'); await shot('settings');

  await page.goto(`${BASE}#/whatsapp/insights`);
  await page.getByText('By lead source').first().waitFor({ timeout: 10000 });
  ok(await page.getByText('Estimated Meta cost').first().isVisible(), `${tag}: Insights shows cost`);
  await noSideScroll('Insights');

  await page.goto(`${BASE}#/whatsapp/contacts`);
  await page.getByText('Ananya Rao').first().waitFor({ timeout: 10000 });
  ok(true, `${tag}: Contacts lists people`);
  await noSideScroll('Contacts');

  ok(errors.length === 0, `${tag}: no console errors${errors.length ? ` (${errors.slice(0, 2).join(' | ')})` : ''}`);
  await page.close();
}
// Lead window panel
{
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const lead = process.env.RIYA_LEAD;
  await page.goto(`${BASE}?lead=${lead}#/leads`);
  await page.getByTestId('lead-whatsapp').waitFor({ timeout: 10000 });
  ok(await page.getByText('Open chat').isVisible(), 'lead window: WhatsApp panel with Open chat');
  await page.screenshot({ path: '/tmp/wa_ui_390_leadpanel.png' });
  await page.close();
}
await browser.close();
console.log(fails ? `${fails} UI CHECK(S) FAILED` : 'ALL UI CHECKS PASSED');
process.exit(fails ? 1 : 0);
