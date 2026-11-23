// Layout at 5 screen widths (360 / 390 phones, 768 tablet, 1024 / 1440 laptops) + Leads > Meta Leads.
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
const errors = [];
const rowOf = (els) => new Set(els.map((r) => Math.round(r.top))).size;
for (const width of [360, 390, 768, 1024, 1440]) {
  const phone = width < 768;
  const ctx = await browser.newContext({ viewport: { width, height: phone ? 800 : 900 }, deviceScaleFactor: 1, isMobile: phone, hasTouch: phone });
  await ctx.addInitScript(([s]) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('token', 'employee-token');
    localStorage.setItem('employee', JSON.stringify({ id: 'e1', name: 'Test Admin', department: 'Admin' }));
    localStorage.setItem('weone-crm-auth', JSON.stringify(s));
    localStorage.setItem('lead_segment', 'aviation');
  }, [session]);
  await ctx.route('https://www.gstatic.com/generate_204', (r) => r.fulfill({ status: 204, body: '' }));
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(`${width}: ${e}`));
  await mode('health=ok&token=ok&leads=ok');
  await page.goto(APP); await page.getByText('Needs your attention').waitFor({ timeout: 30000 });
  const fits = async () => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
  const tops = (sel) => page.locator(sel).evaluateAll((els) => els.map((e) => e.getBoundingClientRect()).map((r) => ({ top: r.top, w: r.width })));

  await page.goto(`${APP}#/leads`); await page.getByTestId('lead-segments').waitFor(); await page.waitForTimeout(1200);
  const seg = await page.getByTestId('lead-segments').getByRole('tab').allInnerTexts();
  ok(seg.length === 3 && /Meta/.test(seg[2]) && /\(2\)/.test(seg[2]), `RL01 ${width}: Leads has We One Aviation, Book My Charter and Meta Leads (with its count)`);
  ok(rowOf(await tops('[data-testid="lead-counters"] > *')) === 1, `RL02 ${width}: the three counters sit in one row`);
  if (phone) ok(rowOf(await tops('[data-testid="lead-filter-chips"] > button')) === 1, `RL03 ${width}: the filter chips are one swipeable row`);
  ok(await fits(), `RL04 ${width}: Leads fits the screen (no sideways page scroll)`);
  await page.screenshot({ path: `/tmp/resp_${width}_leads.png` });

  await page.getByTestId('lead-segments').getByRole('tab').nth(2).click(); await page.getByTestId('ads-lead-card').first().waitFor();
  const card = await page.getByTestId('ads-lead-card').first().innerText();
  ok(/Minali Sawhney/.test(card) && /Delhi/.test(card) && /Ad: Pilot after 12th/.test(card) && /Instagram/.test(card) && /FILLED BY|Filled by/i.test(card) && /Parent \/ guardian/.test(card) && /Funding/i.test(card),
    `RL05 ${width}: a Meta lead shows the ad, the app, the city and the answers in words`);
  const acts = page.getByTestId('ads-lead-actions').first();
  ok(await acts.getByRole('link', { name: 'Call' }).getAttribute('href') === 'tel:+919812345678' && await acts.getByRole('link', { name: 'WhatsApp' }).getAttribute('href') === 'https://wa.me/919812345678'
     && rowOf(await acts.locator('> *').evaluateAll((els) => els.map((e) => e.getBoundingClientRect()))) === 1, `RL06 ${width}: Call, WhatsApp and Update buttons in one row`);
  if (phone) ok(rowOf((await tops('[data-testid="ads-lead-answers"] > div')).slice(0, 2)) === 1, `RL07 ${width}: two answers per row on a phone`);
  ok(await fits(), `RL08 ${width}: Meta Leads fits the screen`);
  await page.screenshot({ path: `/tmp/resp_${width}_metaleads.png` });

  for (const [n, h] of [['metaads', '#/metaads'], ['campaigns', '#/metaads/campaigns']]) {
    await page.goto(`${APP}${h}`); await page.getByTestId('meta-tabs').waitFor(); await page.waitForTimeout(1200);
    const t = await tops('[data-testid="meta-tabs"] > button');
    ok(rowOf(t) === 1 && Math.min(...t.map((x) => x.w)) >= 70, `RL09 ${width} ${n}: Meta Ads tabs are one row, none squeezed`);
    const act = await page.evaluate(() => { const b = document.querySelector('[data-testid="meta-tabs"] [aria-selected="true"]'); const r = b.getBoundingClientRect(); const p = b.parentElement.getBoundingClientRect(); return r.left >= p.left - 1 && r.right <= p.right + 1; });
    ok(act, `RL10 ${width} ${n}: the open tab is in view`);
    ok(await fits(), `RL11 ${width} ${n}: fits the screen`);
    await page.screenshot({ path: `/tmp/resp_${width}_${n}.png` });
  }
  await ctx.close();
}
ok(errors.length === 0, `RL12 no page errors${errors.length ? ': ' + errors.slice(0, 2).join(' | ') : ''}`);
await browser.close();
console.log(failed ? `\n${failed} FAILED` : '\nALL RESPONSIVE CHECKS PASSED');
process.exit(failed ? 1 : 0);
