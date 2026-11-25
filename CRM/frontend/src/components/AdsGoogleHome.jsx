// CRM > Google Ads > Overview: the one screen the owner needs (migration 146).
//   1 status in plain words, with the one thing to do next
//   2 money: the prepaid balance read from Google itself; "I added money" asks Google again (nothing to type)
//   3 daily budget: slider or typed amount, monthly cost with GST, how it is shared; one Save changes Google too
//   4 who sees the ads: who / where / when / which searches, per campaign, from what Google confirmed
//   5 results: spend, clicks, CRM enquiries, cost per enquiry, how fast enquiries were called
//   6 needs you: waiting changes, labelled "AI suggestion" or "Your change"
// Everything else is under Advanced. Reads api_ads_google_home; writes api_ads_google_budget_set,
// api_ads_google_balance_refresh and api_ads_google_op_decide.
import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './icons';
import { confirmDialog } from './ui/dialogs';
import { money, int } from '../utils/ads';
import { showToast } from '../utils/toast';
import { rpc, run, useLoad, Btn, Spinner } from './adsKit';

const BILLING = 'https://ads.google.com/aw/billing/summary';
const GREEN = '#1E7B34', RED = '#C4261D', ORANGE = '#B25E00', BLUE = '#007AFF';

const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - Date.parse(t)) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return `${Math.round(m / 1440)} d ago`;
};
const dayOf = (d) => (d ? new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' }) : '');
const hour = (h) => (h === 0 || h === 24 ? '12 am' : h === 12 ? '12 pm' : h < 12 ? `${h} am` : `${h - 12} pm`);
const rs = (v, cur) => money(v, cur, Number(v) >= 1000 || Number.isInteger(Number(v)) ? 0 : 2);

// Google's household-income groups, highest first, and how a person reads them.
const TIERS = [['INCOME_RANGE_90_UP', 'top 10%'], ['INCOME_RANGE_80_90', '11–20%'], ['INCOME_RANGE_70_80', '21–30%'],
  ['INCOME_RANGE_60_70', '31–40%'], ['INCOME_RANGE_50_60', '41–50%'], ['INCOME_RANGE_0_50', 'lower 50%']];
export function whoText(excluded) {
  const ex = new Set(Array.isArray(excluded) ? excluded : []);
  const inc = TIERS.filter(([k]) => !ex.has(k));
  if (inc.length === TIERS.length) return 'Everyone searching on Google';
  if (!inc.length) return 'Nobody (every income group is shut out)';
  const top = inc.every(([k], i) => k === TIERS[i][0]);
  return top ? `Only the top ${inc.length * 10}% of households by income (Google's estimate)`
    : `Households in these income groups: ${inc.map(([, l]) => l).join(', ')} (Google's estimate)`;
}
export function whenText(slots) {
  if (!Array.isArray(slots) || !slots.length) return 'All day, every day, same bid';
  const changed = slots.filter((s) => Number(s.bid_pct || 0) !== 0);
  if (!changed.length) return 'All day, every day, same bid';
  return `All day, every day. ${changed.map((s) => `${hour(s.start_hour)}–${hour(s.end_hour)}: bids ${Math.abs(s.bid_pct)}% ${s.bid_pct < 0 ? 'lower' : 'higher'}`).join('; ')}`;
}
// The same sharing rule as api_ads_google_budget_set: each campaign keeps its share, the largest takes the rounding.
export function shareBudget(total, camps) {
  const list = [...(camps || [])].sort((a, b) => (Number(b.daily_budget) || 0) - (Number(a.daily_budget) || 0) || String(a.id).localeCompare(String(b.id)));
  if (!list.length || !(total > 0)) return [];
  const sum = list.reduce((s, c) => s + (Number(c.daily_budget) || 0), 0);
  const step = total % 10 === 0 ? 10 : 1;
  const rest = list.slice(1).map((c) => ({ ...c, part: Math.max(10, Math.round((total * (sum > 0 ? (Number(c.daily_budget) || 0) / sum : 1 / list.length)) / step) * step) }));
  return [{ ...list[0], part: total - rest.reduce((s, c) => s + c.part, 0) }, ...rest];
}

const Card = ({ title, right, children, testid, tone }) => (
  <section className="glass-card p-4" data-testid={testid} style={tone ? { boxShadow: `inset 0 0 0 1px ${tone}` } : undefined}>
    {(title || right) && <div className="flex flex-wrap items-center justify-between gap-2 mb-3"><h3 className="font-bold text-glass-primary">{title}</h3>{right}</div>}
    {children}
  </section>
);
const LinkBtn = ({ href, children, tone = BLUE, testid }) => (
  <a href={href} target="_blank" rel="noreferrer" data-testid={testid}
    className="px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center justify-center gap-1.5 text-white" style={{ background: tone }}>
    {children} <Icon name="external" size={14} /></a>
);

// ------------------------------------------------------------------ 1 status
const STATES = {
  running: ['#34C759', 'Ads are running'],
  starting: ['#34C759', 'Money received. Ads are starting'],
  low_money: ['#FF9500', 'Ads are running, but money is low'],
  no_money: ['#FF3B30', 'Ads are off: the Google Ads balance is used up'],
  not_showing: ['#FF9500', 'Ads are switched on but not showing'],
  paused: ['#8E8E93', 'Google Ads is stopped in the CRM'],
  off: ['#8E8E93', 'No campaign is switched on'],
  not_connected: ['#FF3B30', 'Google Ads is not connected'],
};
function Status({ h, onAdded, checking, go }) {
  const s = h.status || {}; const m = h.money || {}; const cur = h.account?.currency || 'INR';
  const [dot, head] = STATES[s.state] || ['#8E8E93', 'Status unknown'];
  let line = null, act = null;
  if (s.state === 'running') line = `${rs(s.today_spend, cur)} spent today · ${int(s.today_clicks)} click${Number(s.today_clicks) === 1 ? '' : 's'}${m.days_left != null ? ` · money for about ${m.days_left} days` : ''}.`;
  if (s.state === 'starting') line = 'Google usually starts showing the ads within minutes of a payment; a card payment can take up to 24 hours.';
  if (s.state === 'low_money') { line = `About ${m.days_left} days of money left. Add about ${rs(m.add_30d, cur)} for 30 days at this budget (GST included).`; act = <LinkBtn href={BILLING} tone="#FF9500">Add money</LinkBtn>; }
  if (s.state === 'no_money') {
    line = s.likely ? `Most likely the prepaid balance is used up (the CRM has not read the balance from Google yet). Add about ${rs(m.add_30d, cur)} for 30 days, GST included.`
      : `${rs(m.available, cur)} left. Add about ${rs(m.add_30d, cur)} for 30 days at ${rs(m.daily, cur)} a day, GST included. The ads start again by themselves.`;
    act = <div className="flex flex-wrap gap-2"><LinkBtn href={BILLING} tone="#FF3B30" testid="add-money-link">Add money in Google Ads</LinkBtn>
      <Btn ghost onClick={onAdded} disabled={checking} data-testid="added-status">{checking ? <><Spinner />Checking…</> : 'I added money'}</Btn></div>;
  }
  if (s.state === 'not_showing') { line = `There is money in the account, but Google has shown the ads very little${s.since ? ` since ${dayOf(s.since)}` : ''}. Open the campaign in Google Ads to see why.`; act = <LinkBtn href="https://ads.google.com/aw/campaigns" tone="#FF9500">Open Google Ads</LinkBtn>; }
  if (s.state === 'paused') { line = 'Nothing is sent to Google until it is resumed.'; act = <Btn ghost onClick={() => go('settings')}>Open Settings</Btn>; }
  if (s.state === 'off') line = 'Switch a campaign on in Google Ads, or ask the AI team under Advanced.';
  if (s.state === 'not_connected') { line = 'Sign in to Google Ads again so the CRM can read and change it.'; act = h.is_admin && <Btn onClick={() => go('setup')}>Open Setup</Btn>; }
  return (
    <section className="glass-card p-4" data-testid="g-status" data-state={s.state}>
      <div className="flex flex-wrap items-center gap-3">
        <span className="relative h-3.5 w-3.5 shrink-0" aria-hidden>
          <span className="absolute inset-0 rounded-full" style={{ background: dot }} />
          {(s.state === 'running' || s.state === 'starting') && <span className="absolute inset-0 rounded-full animate-ping opacity-60" style={{ background: dot }} />}
        </span>
        <div className="flex-1 min-w-[14rem]">
          <div className="font-bold text-lg text-glass-primary leading-tight" data-testid="g-status-head">{head}</div>
          {line && <div className="text-sm text-glass-secondary mt-0.5">{line}</div>}
          {(s.reviewing || []).length > 0 && <div className="text-xs mt-1" style={{ color: ORANGE }}>Google is still checking the new ads in {s.reviewing.join(', ')}; they show once approved (usually within a day).</div>}
        </div>
        {act}
      </div>
    </section>
  );
}

// ------------------------------------------------------------------ 2 money
function Money({ h, onAdded, checking, note }) {
  const m = h.money || {}; const cur = h.account?.currency || 'INR';
  const known = m.kind === 'prepaid' && m.available != null;
  const low = known && (Number(m.days_left) < 3);
  return (
    <Card title="Money in Google Ads" testid="g-money" right={<a href={BILLING} target="_blank" rel="noreferrer" className="text-sm font-semibold inline-flex items-center gap-1" style={{ color: BLUE }}>Billing <Icon name="external" size={13} /></a>}>
      <div className="flex flex-wrap items-end gap-x-6 gap-y-2">
        <div>
          <div className="text-xs text-glass-secondary">Balance</div>
          <div className="text-3xl font-bold tabular-nums" data-testid="g-balance" style={{ color: !known ? undefined : low ? RED : 'var(--text-primary, #1C1C1E)' }}>
            {known ? rs(m.available, cur) : m.kind === 'no_limit' || m.kind === 'none' ? 'Not prepaid' : '—'}</div>
          <div className="text-[11px] text-glass-muted" data-testid="g-balance-when">
            {known ? <>Read from Google {ago(m.checked_at)}</> : m.kind ? 'Google reports no prepaid balance for this account' : 'Not read from Google yet'}
            {m.error && <span style={{ color: ORANGE }}> · last check failed {ago(m.error_at)}</span>}</div>
        </div>
        {known && <div><div className="text-xs text-glass-secondary">Lasts about</div>
          <div className="text-xl font-bold tabular-nums" style={{ color: low ? RED : undefined }}>{m.days_left != null ? `${m.days_left} days` : '—'}</div>
          <div className="text-[11px] text-glass-muted">at {rs(m.daily, cur)} a day</div></div>}
        {m.last_topup && <div><div className="text-xs text-glass-secondary">Last top-up seen</div>
          <div className="text-xl font-bold tabular-nums" style={{ color: GREEN }}>+{rs(m.last_topup.credit, cur)}</div>
          <div className="text-[11px] text-glass-muted">{ago(m.last_topup.seen_at)}, after GST</div></div>}
        <div className="ml-auto flex flex-wrap gap-2">
          <Btn onClick={onAdded} disabled={checking} data-testid="g-added">{checking ? <><Spinner />Checking with Google…</> : <><Icon name="refresh" size={15} />I added money</>}</Btn>
        </div>
      </div>
      {note && <div className="mt-3 text-sm rounded-xl p-2.5" data-testid="g-money-note" role="status"
        style={{ background: note.ok ? 'rgba(52,199,89,0.12)' : 'rgba(255,149,0,0.12)', color: note.ok ? GREEN : ORANGE }}>{note.text}</div>}
      <p className="text-[11px] text-glass-muted mt-3 mb-0">Add money in Google Ads (Billing), then tap “I added money”: the CRM asks Google for the new balance, nothing to type.
        18% GST comes out of each payment (on this account ₹1,000 paid gave ₹847 of ads). Card and UPI payments usually show within minutes; net banking can take up to a day. The CRM keeps checking every 5 minutes for 2 hours after you tap, and every 30 minutes otherwise.</p>
    </Card>
  );
}

// ------------------------------------------------------------------ 3 daily budget
function Budget({ h, reload }) {
  const b = h.budget || {}; const cur = h.account?.currency || 'INR'; const camps = h.campaigns || [];
  const saved = Number(b.daily) || Number(b.actual) || 200;
  const min = Number(b.min) || 100; const hardMax = Number(b.max) || 5000;
  const sliderMax = Math.min(hardMax, Math.max(2000, Math.ceil(saved / 500) * 500));
  const [v, setV] = useState(saved);
  const [txt, setTxt] = useState(String(saved));
  const dirty = useRef(false);
  useEffect(() => { if (!dirty.current) { setV(saved); setTxt(String(saved)); } }, [saved]);
  const set = (n) => { dirty.current = true; setV(n); setTxt(String(n)); };
  const valid = Number.isInteger(v) && v >= min && v <= hardMax;
  const tax = Number(b.tax_pct ?? 18);
  const month = Math.round(v * 30.4); const withTax = Math.round(month * (1 + tax / 100));
  const parts = useMemo(() => shareBudget(v, camps), [v, camps]);
  const chg = b.change; const saving = chg && ['approved', 'executing'].includes(chg.status);
  const actual = Number(b.actual) || 0;
  const days = h.money?.kind === 'prepaid' && h.money.available != null && v > 0 ? Math.round((h.money.available / v) * 10) / 10 : null;
  const save = async () => {
    if (!valid) return;
    const ok = await confirmDialog(`Set Google Ads to ${rs(v, cur)} a day?`, {
      message: `${parts.map((p) => `${p.label} ${rs(p.part, cur)}`).join(' · ')}. Monthly limit ${rs(month, cur)} (${rs(withTax, cur)} with GST). Google may spend up to twice this on a busy day, never more than the month's limit.`,
      confirmText: 'Save' });
    if (!ok) return;
    const r = await run(rpc('api_ads_google_budget_set', { p_daily: v }));
    if (r) { dirty.current = false; showToast(r.op ? 'Saved. Sending it to Google…' : 'Saved.', 'success'); await reload(); }
  };
  const status = saving ? <span className="inline-flex items-center gap-1.5" style={{ color: BLUE }}><Spinner size={12} />Saving to Google…</span>
    : chg?.status === 'verified' ? <span style={{ color: GREEN }}>✓ Google has {rs(chg.daily_total, cur)} a day ({ago(chg.created_at)})</span>
    : ['failed', 'stale', 'outcome_unknown'].includes(chg?.status) ? <span style={{ color: RED }}>The last change to {rs(chg.daily_total, cur)} did not go through{chg.error ? `: ${chg.error}` : ''}.</span>
    : actual > 0 && actual !== saved ? <span style={{ color: ORANGE }}>Google has {rs(actual, cur)} a day; the CRM limit is {rs(saved, cur)}.</span> : null;
  return (
    <Card title="Daily budget" testid="g-budget" right={status && <span className="text-xs font-semibold" data-testid="g-budget-status">{status}</span>}>
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-1 text-2xl font-bold">
          <span className="text-glass-secondary">₹</span>
          <input type="number" inputMode="numeric" aria-label="Daily budget in rupees" data-testid="g-budget-input" min={min} max={hardMax} step={10}
            className="glass-input w-28 px-2 py-1 text-2xl font-bold tabular-nums" value={txt} disabled={!h.can_edit || saving}
            onChange={(e) => { dirty.current = true; setTxt(e.target.value); const n = Number(e.target.value); if (e.target.value !== '' && Number.isFinite(n)) setV(n); }}
            onBlur={() => { const n = Math.round(Number(txt)); if (!Number.isFinite(n) || txt === '') set(v); else set(Math.min(hardMax, Math.max(min, n))); }} />
          <span className="text-base font-semibold text-glass-secondary">a day</span>
        </label>
        <div className="flex flex-wrap gap-1.5">{[150, 200, 300, 500].filter((p) => p >= min && p <= hardMax).map((p) => (
          <button key={p} type="button" disabled={!h.can_edit || saving} onClick={() => set(p)} aria-pressed={v === p}
            className="px-3 py-1.5 rounded-lg text-sm font-semibold disabled:opacity-40" style={v === p ? { background: BLUE, color: '#fff' } : { background: 'rgba(118,118,128,0.12)' }}>₹{p}</button>))}</div>
      </div>
      <input type="range" aria-label="Daily budget slider" data-testid="g-budget-slider" className="w-full mt-3 accent-[#007AFF]" min={min} max={sliderMax} step={10}
        value={Math.min(Math.max(v, min), sliderMax)} disabled={!h.can_edit || saving} onChange={(e) => set(Number(e.target.value))} />
      <div className="flex justify-between text-[11px] text-glass-muted -mt-0.5"><span>₹{min}</span><span>₹{sliderMax.toLocaleString('en-IN')}{sliderMax < hardMax ? ' (type more)' : ''}</span></div>
      {!valid && <div className="text-sm mt-2" style={{ color: RED }} data-testid="g-budget-error">Enter a whole amount from ₹{min} to ₹{hardMax.toLocaleString('en-IN')}.</div>}
      {valid && <div className="grid sm:grid-cols-3 gap-3 mt-3 text-sm" data-testid="g-budget-preview">
        <div><div className="text-xs text-glass-secondary">A month (30.4 days)</div><div className="font-bold tabular-nums">{rs(month, cur)} <span className="text-xs font-normal text-glass-muted">+ GST = {rs(withTax, cur)}</span></div></div>
        <div><div className="text-xs text-glass-secondary">Shared as now</div><div className="font-semibold">{parts.map((p) => `${p.label} ${rs(p.part, cur)}`).join(' · ') || '—'}</div></div>
        <div><div className="text-xs text-glass-secondary">Balance lasts</div><div className="font-bold tabular-nums" style={{ color: days != null && days < 3 ? RED : undefined }}>{days != null ? `about ${days} days` : '—'}</div></div>
      </div>}
      <div className="flex flex-wrap items-center gap-2 mt-3">
        {h.can_edit ? <Btn onClick={save} disabled={!valid || saving || (v === saved && v === actual)} busyText="Saving…" data-testid="g-budget-save">Save</Btn>
          : <span className="text-xs text-glass-muted">Only people who can approve ADS changes can change the budget.</span>}
        {h.can_edit && v !== saved && valid && <button type="button" className="text-sm font-semibold" style={{ color: BLUE }} onClick={() => { dirty.current = false; setV(saved); setTxt(String(saved)); }}>Undo</button>}
        <span className="text-[11px] text-glass-muted">One amount for all of Google Ads. The AI team works inside it and cannot raise it.</span>
      </div>
    </Card>
  );
}

// ------------------------------------------------------------------ 4 who sees the ads
const short = (p) => String(p).replace(/,India$/, '').split(',').filter((x, i, a) => i === 0 || x !== a[i - 1]).slice(0, 2).join(', ');
function Audience({ h }) {
  const cur = h.account?.currency || 'INR'; const camps = h.campaigns || [];
  if (!camps.length) return null;
  return (
    <Card title="Who sees the ads" testid="g-audience">
      <div className="space-y-4">{camps.map((c) => {
        const places = (c.places || []).map(short);
        return (
          <div key={c.id} className="rounded-2xl p-3" style={{ background: 'rgba(118,118,128,0.07)' }} data-testid={`g-camp-${c.id}`}>
            <div className="flex flex-wrap items-baseline justify-between gap-2 mb-2">
              <div className="font-bold text-glass-primary">{c.label}</div>
              <div className="text-xs text-glass-secondary">{rs(c.daily_budget, cur)} a day{c.max_cpc ? ` · at most ${rs(c.max_cpc, cur)} a click` : ''}</div>
            </div>
            <dl className="grid grid-cols-[4.5rem_1fr] gap-x-3 gap-y-1.5 text-sm m-0">
              <dt className="text-glass-muted">Who</dt><dd className="m-0">{whoText(c.income_excluded)}</dd>
              <dt className="text-glass-muted">Where</dt><dd className="m-0">{places.length === 0 ? '—' : places.length <= 4 ? places.join(' · ') : (
                <details><summary className="cursor-pointer">{places.length} areas: {places.slice(0, 4).join(' · ')} <span style={{ color: BLUE }}>+{places.length - 4} more</span></summary>
                  <div className="text-xs text-glass-secondary mt-1">{places.join(' · ')}</div></details>)}</dd>
              <dt className="text-glass-muted">When</dt><dd className="m-0">{whenText(c.slots)}</dd>
              <dt className="text-glass-muted">Searches</dt><dd className="m-0">{int(c.keywords_on)} phrases{(c.examples || []).length ? `, e.g. “${c.examples.slice(0, 4).join('”, “')}”` : ''}
                {Number(c.keywords_paused) > 0 && <span className="text-glass-muted"> · {c.keywords_paused} general phrases paused</span>}</dd>
            </dl>
          </div>);
      })}</div>
      {(h.areas_waiting || []).length > 0 && <div className="text-xs text-glass-secondary mt-3" data-testid="g-areas-waiting">
        <b>Not switched on yet:</b> {h.areas_waiting.map((a) => `${a.name} (${a.places})`).join('; ')}. The AI team suggests the next areas once these bring enough enquiries.</div>}
    </Card>
  );
}

// ------------------------------------------------------------------ 5 results
function Results({ h, days, setDays, go }) {
  const r = h.results || {}; const cur = h.account?.currency || 'INR';
  const series = r.series || [];
  const max = Math.max(1, ...series.map((d) => Number(d.spend) || 0));
  const Tile = ({ label, value, sub, tone, testid }) => (
    <div className="rounded-2xl p-3" style={{ background: 'rgba(118,118,128,0.07)' }} data-testid={testid}>
      <div className="text-xs text-glass-secondary">{label}</div>
      <div className="text-xl font-bold tabular-nums" style={tone ? { color: tone } : undefined}>{value}</div>
      {sub && <div className="text-[11px] text-glass-muted">{sub}</div>}
    </div>);
  const speedTone = r.enquiries > 0 ? (r.called_15m === r.enquiries ? GREEN : RED) : undefined;
  return (
    <Card title="Results" testid="g-results" right={
      <div className="flex gap-1 p-1 rounded-xl" role="group" aria-label="Period" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {[7, 30, 90].map((d) => <button key={d} type="button" aria-pressed={days === d} onClick={() => setDays(d)}
          className={`px-3 py-1.5 rounded-lg text-sm ${days === d ? 'bg-white font-semibold shadow-sm' : ''}`}>{d} days</button>)}
      </div>}>
      <div className="grid grid-cols-2 lg:grid-cols-5 gap-2">
        <Tile label="Spent" value={rs(r.spend, cur)} sub="Google's figure, before GST" testid="g-r-spend" />
        <Tile label="Clicks" value={int(r.clicks)} sub={r.cpc != null ? `${rs(r.cpc, cur)} a click` : 'no clicks yet'} testid="g-r-clicks" />
        <Tile label="Enquiries" value={int(r.enquiries)} sub="from these ads, in the CRM" testid="g-r-enq" />
        <Tile label="Cost per enquiry" value={r.cost_per_enquiry != null ? rs(r.cost_per_enquiry, cur) : '—'} sub="spent ÷ enquiries" testid="g-r-cpe" />
        <Tile label="Called within 15 min" value={r.enquiries > 0 ? `${r.called_15m} of ${r.enquiries}` : '—'} tone={speedTone} sub="of the enquiries in this period" testid="g-r-speed" />
      </div>
      {Number(r.waiting) > 0 && <div className="mt-3 flex flex-wrap items-center gap-2 rounded-xl p-2.5 text-sm" style={{ background: 'rgba(255,59,48,0.08)', color: RED }} data-testid="g-waiting">
        <Icon name="phone" size={15} /><b>{r.waiting} enquir{r.waiting === 1 ? 'y' : 'ies'} from ads not called yet.</b>
        <Btn ghost onClick={() => go('adsleads')}>Open Leads</Btn></div>}
      {series.length > 0 && <div className="mt-3">
        <div className="text-xs font-semibold text-glass-secondary mb-1">Spend per day · <span style={{ color: GREEN }}>●</span> enquiries</div>
        <div className="flex items-end gap-[2px] h-24" role="img" aria-label={`Spend per day for the last ${days} days`}>
          {series.map((d) => (
            <div key={d.day} className="flex-1 flex flex-col items-center justify-end h-full min-w-0" title={`${dayOf(d.day)}: ${rs(d.spend, cur)} · ${d.clicks} clicks · ${d.enquiries} enquiries`}>
              {Number(d.enquiries) > 0 && <span className="text-[9px] font-bold leading-none mb-0.5" style={{ color: GREEN }}>{days <= 30 ? d.enquiries : '●'}</span>}
              <div className="w-full rounded-t-[3px]" style={{ height: `${Math.max(Number(d.spend) > 0 ? 3 : 1, (Number(d.spend) / max) * 100)}%`, background: Number(d.spend) > 0 ? BLUE : 'rgba(118,118,128,0.25)' }} />
            </div>))}
        </div>
        <div className="flex justify-between text-[10px] text-glass-muted mt-0.5"><span>{dayOf(r.from)}</span><span>{dayOf(r.to)}</span></div>
      </div>}
    </Card>
  );
}

// ------------------------------------------------------------------ 6 needs you
const BY = { ai: ['AI suggestion', '#5856D6'], you: ['Your change', BLUE], team: ['A colleague\'s change', '#8E8E93'] };
function Needs({ h, reload, go }) {
  const n = h.needs || {}; const ops = n.ops || [];
  const decide = async (op, approve) => {
    if (!approve && !(await confirmDialog('Decline this change?', { message: op.summary, confirmText: 'Decline', danger: true }))) return;
    if (await run(rpc('api_ads_google_op_decide', { p_id: op.id, p_approve: approve, p_reason: approve ? null : 'Declined on the Overview' }), approve ? 'Approved. It is sent to Google within 5 minutes.' : 'Declined.')) reload();
  };
  const extra = Number(n.suggestions) + Number(n.queue);
  return (
    <Card title="Needs you" testid="g-needs" right={(ops.length + extra) > 0 && <span className="text-xs font-semibold rounded-full px-2 py-0.5" style={{ background: '#FF3B30', color: '#fff' }}>{ops.length + extra}</span>}>
      {ops.length + extra === 0 ? <div className="text-sm text-glass-secondary">Nothing is waiting for you.</div> : (
        <ul className="space-y-2 m-0 p-0 list-none">
          {ops.map((op) => {
            const [label, tone] = BY[op.by] || BY.team;
            return (
              <li key={op.id} className="flex flex-wrap items-start gap-3 p-3 rounded-2xl" style={{ background: 'rgba(118,118,128,0.07)' }} data-testid="g-need">
                <div className="flex-1 min-w-[12rem]">
                  <span className="text-[11px] font-bold rounded-full px-2 py-0.5 mr-1.5 align-middle" style={{ background: `${tone}1F`, color: tone }}>{label}</span>
                  <span className="text-sm font-semibold text-glass-primary">{op.summary || op.kind}</span>
                  {op.reason && <div className="text-xs text-glass-secondary mt-1">{op.reason}</div>}
                </div>
                {h.can_edit && <div className="flex gap-2">
                  <Btn tone="#248A3D" scope={`gop-${op.id}`} busyText="Approving…" onClick={() => decide(op, true)}>Approve</Btn>
                  <Btn ghost scope={`gop-${op.id}`} onClick={() => decide(op, false)}>Decline</Btn></div>}
              </li>);
          })}
          {Number(n.suggestions) > 0 && <li className="flex flex-wrap items-center gap-3 p-3 rounded-2xl" style={{ background: 'rgba(118,118,128,0.07)' }}>
            <span className="flex-1 text-sm"><b>{n.suggestions}</b> AI suggestion{n.suggestions > 1 ? 's' : ''} to look at.</span><Btn ghost onClick={() => go('today')}>Review</Btn></li>}
          {Number(n.queue) > 0 && <li className="flex flex-wrap items-center gap-3 p-3 rounded-2xl" style={{ background: 'rgba(118,118,128,0.07)' }}>
            <span className="flex-1 text-sm"><b>{n.queue}</b> budget / status change{n.queue > 1 ? 's' : ''} waiting for approval.</span><Btn ghost onClick={() => go('approvals')}>Review</Btn></li>}
        </ul>)}
    </Card>
  );
}

// ------------------------------------------------------------------ the screen
export default function AdsGoogleHome({ go }) {
  const [days, setDays] = useState(7);
  const [h, load, err, loading] = useLoad(() => rpc('api_ads_google_home', { p_days: days }), [days], { refreshMs: 60000 });
  const [checking, setChecking] = useState(null);       // { at, before, asked }
  const [note, setNote] = useState(null);
  const hRef = useRef(h); hRef.current = h;

  // after "I added money": refresh until Google's answer is in (or 60 seconds pass)
  useEffect(() => {
    if (!checking) return undefined;
    const t = setInterval(async () => {
      await load();
      const m = hRef.current?.money || {};
      const answered = [m.checked_at, m.error_at].some((x) => x && Date.parse(x) >= checking.at - 2000);
      const timeUp = Date.now() - checking.at > 60000;
      if (!answered && !timeUp) return;
      clearInterval(t);
      const cur = hRef.current?.account?.currency || 'INR';
      if (answered && m.checked_at && Date.parse(m.checked_at) >= checking.at - 2000) {
        const gain = Number(m.available ?? 0) - Number(checking.before ?? 0);
        setNote(gain >= 1 ? { ok: true, text: `Google shows the new money: ${rs(m.available, cur)} in the account now. The ads start by themselves.` }
          : m.kind === 'prepaid' ? { ok: false, text: `Google still shows ${rs(m.available, cur)}. If you paid just now, it can take a few minutes (card, UPI) or up to a day (net banking). The CRM keeps checking every 5 minutes for 2 hours.` }
          : { ok: false, text: 'Google reports no prepaid balance for this account.' });
      } else {
        setNote({ ok: false, text: m.error ? `Google did not answer (${m.error}). The CRM tries again within 5 minutes.` : 'Google has not answered yet. The CRM keeps checking every 5 minutes for 2 hours.' });
      }
      setChecking(null);
    }, 3000);
    return () => clearInterval(t);
  }, [checking, load]);

  // while a budget change is being saved to Google, look again every 5 seconds
  const saving = ['approved', 'executing'].includes(h?.budget?.change?.status);
  useEffect(() => {
    if (!saving) return undefined;
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, [saving, load]);

  const added = async () => {
    setNote(null);
    const before = h?.money?.available;
    try {
      const r = await rpc('api_ads_google_balance_refresh');
      if (r?.wait) { showToast('Already checking. One moment…', 'info'); return; }
      if (r && r.asked === false) { setNote({ ok: false, text: 'The CRM could not reach Google just now. It checks again by itself within 5 minutes.' }); return; }
      setChecking({ at: Date.now(), before });
    } catch (e) { showToast(e.message, 'error'); }
  };

  if (!h) return (
    <div className="glass-card p-6 text-sm text-glass-secondary" data-testid="g-home">
      {err ? <><div style={{ color: RED }}>{err}</div><Btn ghost className="mt-2" onClick={load}>Try again</Btn></> : <span className="inline-flex items-center gap-2"><Spinner />Loading…</span>}
    </div>);
  return (
    <div className="space-y-4" data-testid="g-home">
      {err && <div className="text-xs" style={{ color: RED }}>{err} (showing what was loaded {loading ? '…' : 'last'})</div>}
      <Status h={h} onAdded={added} checking={!!checking} go={go} />
      {h.status?.state !== 'not_connected' && <>
        <Needs h={h} reload={load} go={go} />
        <div className="grid lg:grid-cols-2 gap-4 items-start">
          <Money h={h} onAdded={added} checking={!!checking} note={note} />
          <Budget h={h} reload={load} />
        </div>
        <Results h={h} days={days} setDays={setDays} go={go} />
        <Audience h={h} />
        <button type="button" onClick={() => go('more')} className="glass-card p-3 w-full flex items-center gap-3 text-left" data-testid="g-advanced">
          <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(118,118,128,0.12)' }}><Icon name="settings" size={20} /></span>
          <span className="flex-1"><span className="block font-semibold text-glass-primary">Advanced</span><span className="block text-xs text-glass-secondary">Full report, campaigns, AI team, approvals, settings</span></span>
          <Icon name="chevronRight" size={16} /></button>
      </>}
    </div>
  );
}
