import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import OverflowNav from './ui/OverflowNav';
import { useRoute, navigate } from '../utils/route';
import { ProductGallery, ProductEditor } from './AmazonEditor';
import { Decisions, ClaudeChat, MorningSummary, MacConnect, AlertEmails, MyStyle, Profit } from './AmazonDecisions';
import { syncPush } from './AppAlerts';
import { Keywords, Competitors, ReviewRequests } from './AmazonMarket';
import { inr, pct, ageText, dispatchText } from '../utils/amazon';

// CRM > Amazon (Nitaniya on Amazon.in). Admin, plus people Admin grants in Settings.
// Built for a non-technical seller: 4 tabs (Home, My Products, Approve Changes, Sales) and everything else under More.
// Every read and write goes through api_amz_* database functions, which check access and run the guards
// (price floor, title limits, Legal Metrology fields, ...). Nothing here talks to Amazon directly:
// approved changes are sent by the amazon-execute Edge Function; Claude drafts into the same approval list.

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function edge(name, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
const run = async (p, okMsg) => {
  try { const r = await p; if (okMsg) showToast(okMsg, 'success'); return r; }
  catch (e) { showToast(e.message, 'error'); return undefined; }
};

function useLoad(fn, deps = []) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const load = useCallback(async () => {
    try { setData(await fn()); setError(''); } catch (e) { setError(e.message); }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { load(); }, [load]);
  return [data, load, error];
}

const Chip = ({ children, bg = 'rgba(118,118,128,0.14)', fg = '#3C3C43' }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: bg, color: fg }}>{children}</span>
);
const Stat = ({ label, value, sub, tone, onClick }) => {
  const body = (
    <>
      <div className="text-xs text-glass-muted">{label}</div>
      <div className="text-2xl font-bold" style={tone ? { color: tone } : undefined}>{value}</div>
      {sub && <div className="text-[11px] text-glass-muted mt-0.5">{sub}</div>}
    </>
  );
  return onClick ? <button type="button" onClick={onClick} className="glass-card p-3 text-left w-full">{body}</button> : <div className="glass-card p-3">{body}</div>;
};
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const Err = ({ msg }) => (msg ? <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{msg}</div> : null);
const SEV = { blocker: { bg: 'rgba(255,59,48,0.12)', fg: '#C4261D' }, warning: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00' },
              confirm: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC' }, info: {} };
const NEEDS_BR = <Chip bg="rgba(118,118,128,0.12)" fg="#6E6E73">Needs Brand Registry</Chip>;
const Seg = ({ value, options, onChange, label }) => (
  <div className="flex gap-1 p-1 rounded-xl w-max max-w-full overflow-x-auto" role="group" aria-label={label} style={{ background: 'rgba(118,118,128,0.12)' }}>
    {options.map(([v, l]) => (
      <button key={v} type="button" onClick={() => onChange(v)} aria-pressed={value === v}
        className={`px-3 py-1.5 rounded-lg text-sm whitespace-nowrap ${value === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
  </div>
);

// Plain-words health verdict from Amazon's limits.
function healthVerdict(h) {
  if (!h) return null;
  const bad = [];
  if (h.odr != null && h.odr >= 1) bad.push('too many unhappy orders');
  if (h.cancel_rate != null && h.cancel_rate >= 2.5) bad.push('too many cancelled orders');
  if (h.late_ship_rate != null && h.late_ship_rate >= 4) bad.push('too many late dispatches');
  if (h.valid_tracking_rate != null && h.valid_tracking_rate <= 95) bad.push('tracking missing on orders');
  return bad;
}

// ---------------------------------------------------------------- Home: what to do today
function Home({ access, go, listings, reloadAll, openProduct }) {
  const [o, load, err] = useLoad(() => rpc('api_amz_overview'));
  const [syncing, setSyncing] = useState(false);
  const sync = async () => {
    setSyncing(true);
    const r = await run(edge('amazon-sync', { jobs: ['listings', 'pricing'] }));
    setSyncing(false);
    if (r?.status === 'not-configured') showToast(r.detail, 'error');
    else if (r) showToast(r.results.some((x) => x.status === 'error') ? 'Update finished with a problem. See History.' : 'Updated from Amazon.', r.results.some((x) => x.status === 'error') ? 'error' : 'success');
    load(); reloadAll();
  };
  if (err) return <Err msg={err} />;
  if (!o) return <Empty>Loading…</Empty>;
  const slow = (listings || []).filter((l) => !l.is_parent && (l.handling_days == null || Number(l.handling_days) !== 0)).length;
  const healthBad = healthVerdict(o.health);
  const todo = [];
  if (!o.connected) todo.push({ tone: '#FF9500', icon: 'lock', text: 'Amazon is not connected yet.', sub: access.is_admin ? 'Add the Amazon keys in Settings, then press Test Connection.' : 'Ask Admin to finish Settings.', btn: access.is_admin && 'Open Settings', to: 'settings' });
  else if (o.last_test && o.last_test !== 'Connected') todo.push({ tone: '#FF3B30', icon: 'alert', text: 'The link to Amazon is not working.', sub: `Last check said: ${o.last_test}.`, btn: access.is_admin && 'Open Settings', to: 'settings' });
  if (o.pending) todo.push({ tone: '#FF9500', icon: 'check', text: `${o.pending} decision${o.pending > 1 ? 's are' : ' is'} waiting for you.`, sub: 'Nothing goes to Amazon until you approve it.', btn: 'Review', to: 'decisions' });
  const probs = (o.open_findings?.blocker || 0) + (o.open_findings?.warning || 0);
  if (probs) todo.push({ tone: o.open_findings.blocker ? '#FF3B30' : '#FF9500', icon: 'shield', text: `${probs} thing${probs > 1 ? 's' : ''} to fix on your products.`, sub: 'Fixing them helps you show up in search and sell more.', btn: 'See them', to: 'decisions' });
  if (slow) todo.push({ tone: '#007AFF', icon: 'zap', text: `Fast delivery is not on for ${slow} product${slow > 1 ? 's' : ''}.`, sub: 'Same-day dispatch gives customers an earlier delivery date.', btn: 'Turn on', to: 'products' });
  if (healthBad?.length) todo.push({ tone: '#FF3B30', icon: 'heart', text: 'Your account health needs attention.', sub: `Problem: ${healthBad.join(', ')}.`, btn: 'See health', to: 'health' });
  if (o.rotation_alert) todo.push({ tone: o.rotation_alert <= 7 ? '#FF3B30' : '#FF9500', icon: 'lock', text: `Amazon password (client secret) expires in ${o.rotation_days_left} days.`, sub: 'Make a new one in Seller Central and paste it in Settings.', btn: access.is_admin && 'Open Settings', to: 'settings' });
  Object.entries(o.last_sync || {}).forEach(([job, r]) => { if (r.status === 'error') todo.push({ tone: '#FF3B30', icon: 'refresh', text: 'Getting data from Amazon failed.', sub: `${job}, ${ageText(r.at)}: ${r.detail}` }); });
  const lastAt = Object.values(o.last_sync || {}).map((r) => r.at).filter(Boolean).sort().pop();
  return (
    <div className="space-y-4">
      <MorningSummary go={go} openProduct={openProduct} />
      <div className="glass-card p-4">
        <h3 className="font-bold mb-3">What to do today</h3>
        {todo.length === 0 ? <div className="text-sm" style={{ color: '#1E7B34' }}>All good. Nothing needs you right now.</div> : (
          <ul className="space-y-2">
            {todo.map((a, i) => (
              <li key={i} className="flex items-center gap-3 p-3 rounded-2xl" style={{ background: `${a.tone}14`, boxShadow: `inset 0 0 0 0.5px ${a.tone}59` }}>
                <span className="w-9 h-9 rounded-full grid place-items-center text-white shrink-0" style={{ background: a.tone }}><Icon name={a.icon} size={17} /></span>
                <span className="flex-1 min-w-0"><span className="block text-sm font-semibold text-glass-primary">{a.text}</span>
                  {a.sub && <span className="block text-xs text-glass-secondary">{a.sub}</span>}</span>
                {a.btn && <button type="button" className="glass-btn px-3 py-1.5 text-sm shrink-0" onClick={() => go(a.to)}>{a.btn}</button>}
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-glass-muted px-1">
        <span>Data from Amazon updated {lastAt ? ageText(lastAt) : 'never'}{o.waiting_requests > 0 ? ` · ${o.waiting_requests} question(s) waiting for Claude` : ''}</span>
        {access.is_admin && <button disabled={syncing} onClick={sync} className="glass-btn-ghost px-3 py-1.5 text-xs inline-flex items-center gap-1.5"><Icon name="refresh" size={13} />{syncing ? 'Updating…' : 'Update now'}</button>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Delivery speed (all products)
function DeliverySpeed({ listings, go }) {
  const [days, setDays] = useState(0);
  const [busy, setBusy] = useState(false);
  const kids = (listings || []).filter((l) => !l.is_parent);
  const count = (fn) => kids.filter(fn).length;
  const apply = async () => {
    const word = dispatchText(days).toLowerCase();
    const ok = await confirmDialog(`Set ${word} dispatch for all ${kids.length} products?`, {
      message: days === 0
        ? 'You must pack and hand over every order on the day it comes in. Book the Easy Ship pickup before 12 noon. Late dispatches hurt your account.\n\nThis makes one change per product. You approve them in Approve Changes.'
        : 'This makes one change per product. You approve them in Approve Changes.',
      confirmText: 'Yes, prepare it' });
    if (!ok) return;
    setBusy(true);
    const r = await run(rpc('api_amz_dispatch_all', { p_days: days }));
    setBusy(false);
    if (!r) return;
    if (r.drafted === 0) showToast(`All products are already set to ${word} (or waiting for your OK).`, 'success');
    else { showToast(`${r.drafted} change${r.drafted > 1 ? 's' : ''} ready. Approve them to go live.`, 'success'); go('approve'); }
  };
  return (
    <div className="glass-card p-4 space-y-3">
      <div className="flex items-start gap-3">
        <span className="w-10 h-10 rounded-[12px] grid place-items-center text-white shrink-0" style={{ background: 'linear-gradient(160deg,#3D9BFF,#007AFF)' }}><Icon name="zap" size={20} /></span>
        <div className="min-w-0">
          <h3 className="font-bold">Delivery speed</h3>
          <p className="text-xs text-glass-secondary">How fast you hand orders to Easy Ship. Faster dispatch shows customers an earlier delivery date.</p>
        </div>
      </div>
      <div className="text-xs text-glass-secondary">Now: <b>{count((l) => Number(l.handling_days) === 0 && l.handling_days != null)}</b> same day · <b>{count((l) => Number(l.handling_days) === 1)}</b> next day · <b>{count((l) => l.handling_days != null && Number(l.handling_days) > 1)}</b> slower · <b>{count((l) => l.handling_days == null)}</b> not known yet</div>
      <div className="flex flex-wrap items-center gap-2">
        <Seg label="Dispatch time" value={days} onChange={setDays} options={[[0, 'Same day'], [1, 'Next day']]} />
        <button type="button" className="glass-btn px-4 py-2 text-sm" disabled={busy || !kids.length} onClick={apply}>{busy ? 'Preparing…' : 'Apply to all products'}</button>
      </div>
      <details className="text-xs text-glass-muted">
        <summary className="cursor-pointer">Good to know</summary>
        <ul className="list-disc pl-5 mt-1 space-y-1">
          <li>Amazon decides the delivery date the customer sees. Easy Ship usually delivers in 1 to 3 days; same-day or next-day delivery needs Amazon to offer it in that pin code.</li>
          <li>Same day: book the Easy Ship pickup before 12 noon. Pickups run 1 pm to 5 pm.</li>
          <li>Keep late dispatches under 4% or Amazon can limit your account.</li>
          <li>If Amazon does not allow same day for your account, it will say so here and nothing changes. Then pick Next day.</li>
        </ul>
      </details>
    </div>
  );
}

// ---------------------------------------------------------------- My Products (gallery + editor)
function Products({ access, listings, findings, go, reload, openSku, setOpenSku }) {
  const [q, setQ] = useState('');
  const open = (listings || []).find((l) => l.sku === openSku);
  if (open) return <ProductEditor key={open.sku + open.version} listing={open} access={access} onClose={() => setOpenSku('')} onSaved={reload} />;
  return (
    <div className="space-y-3">
      <DeliverySpeed listings={listings} go={go} />
      <input className="glass-input w-full px-3 py-2 text-sm" placeholder="Search your products" value={q} onChange={(e) => setQ(e.target.value)} />
      {!listings ? <Empty>Loading…</Empty> : <ProductGallery listings={listings} findings={findings} q={q} onOpen={setOpenSku} />}
    </div>
  );
}

// ---------------------------------------------------------------- Sales
function Sales({ listings }) {
  const [days, setDays] = useState(30);
  const [d, , err] = useLoad(() => rpc('api_amz_sales', { p_days: days }), [days]);
  const names = useMemo(() => Object.fromEntries((listings || []).map((l) => [l.sku, l.title])), [listings]);
  const max = Math.max(1, ...((d?.daily || []).map((x) => Number(x.revenue))));
  const total = (d?.daily || []).reduce((a, x) => ({ rev: a.rev + Number(x.revenue), units: a.units + Number(x.units) }), { rev: 0, units: 0 });
  return (
    <div className="space-y-3">
      <Seg label="Period" value={days} onChange={setDays} options={[[7, 'Last 7 days'], [30, 'Last 30 days'], [90, 'Last 90 days']]} />
      <Err msg={err} />
      {!d ? <Empty>Loading…</Empty> : d.daily.length === 0 ? <Empty>No sales yet in this period. Orders come from Amazon every hour.</Empty> : (
        <>
          <div className="grid grid-cols-2 gap-3"><Stat label="Money from sales" value={inr(total.rev)} /><Stat label="Items sold" value={total.units} /></div>
          <div className="glass-card p-4">
            <div className="text-xs text-glass-muted mb-2">Sales per day</div>
            <div className="flex items-end gap-[2px] h-32" role="img" aria-label="Sales per day">
              {d.daily.map((x) => <div key={x.day} title={`${x.day}: ${inr(x.revenue)}, ${x.units} sold`} className="flex-1 rounded-t" style={{ height: `${(Number(x.revenue) / max) * 100}%`, minHeight: 2, background: 'var(--accent)' }} />)}
            </div>
            <div className="flex justify-between text-[10px] text-glass-muted mt-1"><span>{d.daily[0].day}</span><span>{d.daily[d.daily.length - 1].day}</span></div>
          </div>
          <div className="glass-card divide-y" style={{ borderColor: 'var(--border-subtle)' }}>
            <div className="px-3 py-2 text-xs text-glass-muted">Best sellers</div>
            {d.by_sku.map((r) => (
              <div key={r.sku} className="px-3 py-2 text-sm flex items-center gap-3">
                <div className="flex-1 min-w-0"><div className="truncate font-medium">{names[r.sku] || r.sku}</div>
                  <div className="text-[11px] text-glass-muted">{r.sessions != null ? `${r.sessions} visitors · ${pct(r.conversion_pct)} bought` : r.asin}</div></div>
                <div className="text-right shrink-0"><div className="font-semibold">{inr(r.revenue)}</div><div className="text-[11px] text-glass-muted">{r.units} sold</div></div>
              </div>
            ))}
          </div>
        </>
      )}
      <Profit />
    </div>
  );
}

// ---------------------------------------------------------------- Account health
function Health() {
  const [d, , err] = useLoad(() => rpc('api_amz_health', { p_days: 90 }));
  const rows = [['odr', 'Unhappy orders (complaints, A-to-z claims)', 1, false], ['cancel_rate', 'Orders you cancelled', 2.5, false], ['late_ship_rate', 'Orders dispatched late', 4, false], ['valid_tracking_rate', 'Orders with tracking', 95, true]];
  const last = d?.days?.[d.days.length - 1];
  return (
    <div className="space-y-3">
      <Err msg={err} />
      {!d ? <Empty>Loading…</Empty> : !last ? <Empty>No health report yet. It comes from Amazon once connected.</Empty> : (
        <div className="grid md:grid-cols-2 gap-3">
          {rows.map(([k, label, limit, higherIsBetter]) => {
            const v = last[k]; const warn = d.warn?.[k];
            const bad = v != null && (higherIsBetter ? v <= warn : v >= warn);
            return <Stat key={k} label={`${label}: must be ${higherIsBetter ? 'above' : 'under'} ${limit}%`} value={pct(v)} tone={bad ? '#C4261D' : '#1E7B34'} sub={`as of ${last.day}`} />;
          })}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Strategy & Calendar
function Strategy() {
  const [rows, load, err] = useLoad(() => rpc('api_amz_tasks'));
  const [t, setT] = useState(''); const [due, setDue] = useState('');
  const save = async (args) => { await run(rpc('api_amz_task_set', args)); load(); };
  return (
    <div className="space-y-3">
      <form className="glass-card p-3 flex flex-wrap gap-2" onSubmit={async (e) => { e.preventDefault(); if (t.trim()) { await save({ p_id: null, p_title: t, p_due: due || null, p_status: null }); setT(''); setDue(''); } }}>
        <input className="glass-input flex-1 min-w-[180px] px-3 py-2 text-sm" placeholder="Add a task" value={t} onChange={(e) => setT(e.target.value)} />
        <input type="date" className="glass-input px-3 py-2 text-sm" value={due} onChange={(e) => setDue(e.target.value)} />
        <button className="glass-btn px-4 text-sm">Add</button>
      </form>
      <div className="glass-card p-3 text-xs text-glass-secondary flex flex-wrap gap-2 items-center">Not available without Brand Registry: A+ Content, Vine, Sponsored Brands, Brand Store {NEEDS_BR}</div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.map((x) => (
        <div key={x.id} className="glass-card p-3 text-sm flex gap-3 items-start">
          <input type="checkbox" className="mt-1" checked={x.status === 'done'} onChange={() => save({ p_id: x.id, p_title: null, p_due: null, p_status: x.status === 'done' ? 'open' : 'done' })} />
          <div className="min-w-0"><div className={`font-medium ${x.status === 'done' ? 'line-through opacity-60' : ''}`}>{x.title}</div>
            {x.detail && <div className="text-xs text-glass-secondary mt-0.5">{x.detail}</div>}
            <div className="text-[11px] text-glass-muted mt-0.5">{x.source}{x.due_on ? ` · due ${x.due_on}` : ''}</div></div>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- Activity Log
function Activity() {
  const [rows, , err] = useLoad(() => rpc('api_amz_activity', { p_limit: 300 }));
  return (
    <div className="glass-card divide-y text-sm" style={{ borderColor: 'var(--border-subtle)' }}>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No activity yet.</Empty> : rows.map((a) => (
        <div key={a.id} className="px-3 py-2 flex flex-wrap gap-2">
          <span className="text-glass-muted text-xs w-36">{new Date(a.at).toLocaleString('en-IN')}</span>
          <span className="font-medium">{a.actor_name || a.actor_type}</span>
          <span>{a.action.replace(/_/g, ' ')}</span>
          <span className="text-glass-muted">{a.entity} {a.entity_id}</span>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- Settings (Admin)
const SECRET_FIELDS = [
  ['AMZ_LWA_CLIENT_ID', 'LWA Client ID', 'amzn1.application-oa2-client.…'],
  ['AMZ_LWA_CLIENT_SECRET', 'LWA Client Secret', 'from Develop Apps > View'],
  ['AMZ_REFRESH_TOKEN', 'Refresh token', 'Atzr|… (from Authorize app)'],
  ['AMZ_SELLER_ID', 'Seller ID (merchant token)', 'Settings > Account Info > Merchant Token'],
];
const ADS_FIELDS = [['ADS_CLIENT_ID', 'Ads Client ID', ''], ['ADS_CLIENT_SECRET', 'Ads Client Secret', ''], ['ADS_REFRESH_TOKEN', 'Ads Refresh token', ''], ['ADS_PROFILE_ID', 'Ads Profile ID', '']];

function SecretRow({ name, label, hint, meta, onSaved }) {
  const [v, setV] = useState('');
  const save = async () => { const r = await run(rpc('api_amz_settings_save', { p_name: name, p_value: v }), 'Saved'); if (r) { setV(''); onSaved(); } };
  return (
    <div className="grid sm:grid-cols-[200px_1fr_auto] gap-2 items-center">
      <div><div className="text-sm font-medium">{label}</div><div className="text-[11px] text-glass-muted">{name}</div></div>
      <input type="password" autoComplete="new-password" className="glass-input px-3 py-2 text-sm" placeholder={meta?.set ? `Saved ••••${meta.last4} · ${ageText(meta.updated_at)} — paste to replace` : hint || 'Paste value'} value={v} onChange={(e) => setV(e.target.value)} />
      <button className="glass-btn px-4 py-2 text-sm" disabled={!v.trim()} onClick={save}>Save</button>
    </div>
  );
}

function Settings() {
  const [s, load, err] = useLoad(() => rpc('api_amz_settings'));
  const [testing, setTesting] = useState(false);
  const [rot, setRot] = useState('');
  const [people, loadPeople] = useLoad(() => rpc('api_amz_approvers'));
  const [rules, loadRules] = useLoad(() => rpc('api_amz_rules'));
  const test = async () => {
    setTesting(true);
    const r = await run(edge('amazon-settings', { action: 'test' }));
    setTesting(false);
    if (r) showToast(`${r.status}: ${r.detail}`, r.status === 'Connected' ? 'success' : 'error');
    load();
  };
  const setRule = async (code, value) => { await run(rpc('api_amz_rule_set', { p_code: code, p_value: value, p_active: null }), 'Rule saved'); loadRules(); };
  if (err) return <Err msg={err} />;
  if (!s) return <Empty>Loading…</Empty>;
  const r = Object.fromEntries((rules || []).map((x) => [x.code, x]));
  return (
    <div className="space-y-4">
      <MacConnect />
      <MyStyle />
      <AlertEmails />
      <ReviewRequests />
      <div className="glass-card p-4 space-y-3">
        <div className="flex flex-wrap justify-between items-center gap-2">
          <div><h3 className="font-bold">Environment variables</h3><p className="text-xs text-glass-muted">Stored in Supabase Vault. Never shown again in full; only the last 4 characters.</p></div>
          <button className="glass-btn px-4 py-2 text-sm" disabled={testing} onClick={test}>{testing ? 'Testing…' : 'Test Connection'}</button>
        </div>
        {s.last_test?.status && <div className="text-sm"><Chip {...(s.last_test.status === 'Connected' ? { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34' } : SEV.blocker)}>{s.last_test.status}</Chip> <span className="text-glass-secondary">{s.last_test.detail}</span> <span className="text-xs text-glass-muted">({ageText(s.last_test.at)})</span></div>}
        {SECRET_FIELDS.map(([n, l, h]) => <SecretRow key={n} name={n} label={l} hint={h} meta={s[n]} onSaved={load} />)}
        <div className="grid sm:grid-cols-[200px_1fr] gap-2 text-sm"><div className="font-medium">Marketplace <span className="block text-[11px] text-glass-muted">AMZ_MARKETPLACE_ID</span></div><div className="glass-input px-3 py-2 opacity-70">{s.AMZ_MARKETPLACE_ID} (Amazon.in, locked)</div></div>
        <div className="grid sm:grid-cols-[200px_1fr] gap-2 text-sm"><div className="font-medium">Region <span className="block text-[11px] text-glass-muted">AMZ_REGION</span></div><div className="glass-input px-3 py-2 opacity-70">{s.AMZ_REGION} (sellingpartnerapi-eu.amazon.com, locked)</div></div>
        <div className="grid sm:grid-cols-[200px_1fr_auto] gap-2 items-center">
          <div><div className="text-sm font-medium">Client secret created on</div><div className="text-[11px] text-glass-muted">AMZ_SECRET_ROTATED_ON</div></div>
          <input type="date" className="glass-input px-3 py-2 text-sm" value={rot || s.AMZ_SECRET_ROTATED_ON || ''} onChange={(e) => setRot(e.target.value)} />
          <button className="glass-btn px-4 py-2 text-sm" disabled={!rot} onClick={async () => { await run(rpc('api_amz_settings_save', { p_name: 'AMZ_SECRET_ROTATED_ON', p_value: rot }), 'Saved'); setRot(''); load(); }}>Save</button>
        </div>
        {s.rotation_days_left != null && <div className="text-xs" style={{ color: s.rotation_days_left <= 30 ? '#C4261D' : undefined }}>Amazon requires a new client secret every 180 days: due {s.rotation_due} ({s.rotation_days_left} days left). After rotating, the old secret keeps working for 7 days.</div>}
        <details className="text-sm"><summary className="cursor-pointer font-medium">Amazon Ads keys (optional)</summary><div className="space-y-2 mt-2">{ADS_FIELDS.map(([n, l, h]) => <SecretRow key={n} name={n} label={l} hint={h} meta={s[n]} onSaved={load} />)}</div></details>
      </div>

      <div className="glass-card p-4 space-y-3">
        <h3 className="font-bold">Guards</h3>
        {r.price_floor && <div className="flex flex-wrap gap-2 items-center text-sm"><span className="w-56">Lowest allowed price (₹)</span><input type="number" defaultValue={r.price_floor.value.min} className="glass-input px-3 py-1.5 w-28" onBlur={(e) => Number(e.target.value) !== r.price_floor.value.min && setRule('price_floor', { min: Number(e.target.value) })} /></div>}
        {r.price_change_confirm && <div className="flex flex-wrap gap-2 items-center text-sm"><span className="w-56">Second confirm above (% change)</span><input type="number" defaultValue={r.price_change_confirm.value.pct} className="glass-input px-3 py-1.5 w-28" onBlur={(e) => Number(e.target.value) !== r.price_change_confirm.value.pct && setRule('price_change_confirm', { pct: Number(e.target.value) })} /></div>}
        {r.ads_daily_budget && <div className="flex flex-wrap gap-2 items-center text-sm"><span className="w-56">Total daily ad budget (₹)</span>
          <input type="number" defaultValue={r.ads_daily_budget.value.min} className="glass-input px-3 py-1.5 w-24" onBlur={(e) => setRule('ads_daily_budget', { ...r.ads_daily_budget.value, min: Number(e.target.value) })} /> to
          <input type="number" defaultValue={r.ads_daily_budget.value.max} className="glass-input px-3 py-1.5 w-24" onBlur={(e) => setRule('ads_daily_budget', { ...r.ads_daily_budget.value, max: Number(e.target.value) })} /></div>}
        <div className="text-xs text-glass-muted">Amazon policy limits (title 75 characters, Item Highlights 125, hidden search words under 200 bytes on Amazon.in, main image rules) are rows too; change them only when Amazon changes its policy.</div>
      </div>

      <div className="glass-card p-4">
        <h3 className="font-bold mb-2">Who can use the Amazon section</h3>
        <div className="divide-y" style={{ borderColor: 'var(--border-subtle)' }}>
          {(people || []).filter((p) => p.department !== 'Admin').map((p) => (
            <div key={p.employee_id} className="flex flex-wrap items-center gap-3 py-2 text-sm">
              <span className="flex-1 min-w-[140px]">{p.name} <span className="text-xs text-glass-muted">{p.department}</span></span>
              <label className="flex gap-1.5 items-center text-xs"><input type="checkbox" checked={p.access} onChange={async (e) => { await run(rpc('api_amz_approver_set', { p_employee: p.employee_id, p_access: e.target.checked, p_can_approve: false })); loadPeople(); }} />Can view & draft</label>
              <label className="flex gap-1.5 items-center text-xs"><input type="checkbox" disabled={!p.access} checked={p.can_approve} onChange={async (e) => { await run(rpc('api_amz_approver_set', { p_employee: p.employee_id, p_access: true, p_can_approve: e.target.checked })); loadPeople(); }} />Can approve</label>
            </div>
          ))}
        </div>
        <div className="text-xs text-glass-muted mt-2">Admins always have full access.</div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- page
const TABS = [
  { id: 'home', label: 'Home', icon: 'chart' },
  { id: 'products', label: 'My Products', icon: 'list' },
  { id: 'decisions', label: 'Decisions', icon: 'check' },
  { id: 'sales', label: 'Sales', icon: 'tag' },
  { id: 'more', label: 'More', icon: 'more' },
];
const MORE = [
  { id: 'keywords', label: 'Keywords', hint: 'Ideas from top competitors; add to all or chosen products', icon: 'search' },
  { id: 'competitors', label: 'Competitors', hint: 'Every morning: who ranks above you', icon: 'globe' },
  { id: 'health', label: 'Account health', hint: 'Late dispatch, cancels, complaints', icon: 'heart' },
  { id: 'strategy', label: 'To-do list', hint: 'Plans and reminders', icon: 'calendar' },
  { id: 'activity', label: 'History', hint: 'Who changed what, and when', icon: 'clock' },
  { id: 'settings', label: 'Settings', hint: 'Amazon keys, limits, who can use this', icon: 'settings', admin: true },
];
// Old links keep working.
const ALIAS = { overview: 'home', listings: 'products', inventory: 'products', queue: 'decisions', approve: 'decisions', audit: 'decisions', ask: 'home', content: 'products', images: 'products' };

export default function Amazon({ access }) {
  const route = useRoute();
  const raw = (route.tab === 'amazon' && route.section) || 'home';
  const view = ALIAS[raw] || raw;
  const [openSku, setOpenSku] = useState('');
  const [chat, setChat] = useState(null);
  const [listings, reloadListings] = useLoad(() => rpc('api_amz_listings'));
  const [queue, reloadQueue] = useLoad(() => rpc('api_amz_queue', { p_status: 'pending' }), [view]);
  const [findings, reloadFindings] = useLoad(() => rpc('api_amz_findings', { p_status: 'open' }), [view]);
  useEffect(() => { if (view === 'products') reloadListings(); }, [view, reloadListings]);
  const reloadAll = () => { reloadListings(); reloadQueue(); reloadFindings(); };
  const skus = (listings || []).map((l) => ({ sku: l.sku, asin: l.asin, title: l.title }));
  const myAsins = [...new Set(skus.map((s) => s.asin).filter(Boolean))];
  const go = (v) => navigate('amazon', v);
  const openProduct = (sku) => { setOpenSku(sku); go('products'); };
  useEffect(() => { if (raw === 'ask' && access.can_approve) setChat({ text: '' }); }, [raw, access.can_approve]);
  useEffect(() => { syncPush(); }, []);
  const more = MORE.filter((m) => !m.admin || access.is_admin);
  const sub = more.find((m) => m.id === view);
  const tab = sub ? 'more' : (TABS.find((t) => t.id === view) ? view : 'home');
  const count = { decisions: queue?.length || 0 };
  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold text-glass-primary">Amazon</h2>
        <div className="text-xs text-glass-muted">Nitaniya · Amazon.in · Easy Ship</div>
      </div>
      {/* Computer: every Amazon page shows when it fits; the rest goes behind ⋯ */}
      <div className="hidden md:block amz-tabbar p-1">
        <OverflowNav ariaLabel="Amazon" activeId={view} onSelect={go}
          items={[...TABS.filter((t) => t.id !== 'more'), ...more].map((t) => ({ ...t, badge: count[t.id] || 0 }))}
          itemClass={(a) => `amz-tab ${a ? 'is-active' : ''}`}
          dotsClass={(a) => `nav-dots ${a ? 'is-active' : ''}`}
          renderItem={(t, a) => <><Icon name={t.icon} size={17} />{t.label}{t.badge > 0 && <span className="amz-badge" style={a ? { background: '#fff', color: '#007AFF' } : undefined}>{t.badge}</span>}</>} />
      </div>
      {/* Phone: four main pages and ⋯ */}
      <div role="tablist" aria-label="Amazon" className="md:hidden glass-card p-1 grid grid-cols-5 gap-1">
        {TABS.map((t) => {
          const active = tab === t.id;
          return (
            <button key={t.id} role="tab" aria-selected={active} aria-label={`${t.label}${count[t.id] ? ` ${count[t.id]}` : ''}`} onClick={() => go(t.id)}
              className="relative flex flex-col sm:flex-row items-center justify-center gap-0.5 sm:gap-1.5 rounded-xl py-2 px-1 text-[11px] sm:text-sm min-h-[52px]"
              style={active ? { background: '#007AFF', color: '#fff', fontWeight: 600 } : undefined}>
              {t.id === 'more' ? <Icon name="more" size={24} strokeWidth={2.4} /> : <>
                <Icon name={t.icon} size={18} />
                <span className="leading-tight text-center"><span className="sm:hidden">{t.short || t.label}</span><span className="hidden sm:inline">{t.label}</span></span></>}
              {count[t.id] > 0 && <span className="absolute top-1 right-1 sm:static min-w-[1.2rem] h-[1.2rem] px-1 rounded-full text-[10px] font-bold inline-flex items-center justify-center"
                style={{ background: active ? '#fff' : '#FF3B30', color: active ? '#007AFF' : '#fff' }}>{count[t.id]}</span>}
            </button>
          );
        })}
      </div>
      {sub && <button type="button" onClick={() => go('more')} className="md:hidden text-sm font-semibold inline-flex items-center gap-1" style={{ color: 'var(--accent)' }}><Icon name="chevronLeft" size={16} />Back</button>}
      {sub && <h3 className="text-lg font-bold text-glass-primary -mt-2">{sub.label}</h3>}
      {view === 'more' && (
        <div className="grid sm:grid-cols-2 gap-2">
          {more.map((m) => (
            <button key={m.id} type="button" onClick={() => go(m.id)} className="glass-card p-3 flex items-center gap-3 text-left min-h-[64px]">
              <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(0,122,255,0.12)', color: '#007AFF' }}><Icon name={m.icon} size={20} /></span>
              <span className="min-w-0 flex-1"><span className="block font-semibold text-glass-primary">{m.label}</span><span className="block text-xs text-glass-secondary">{m.hint}</span></span>
              <Icon name="chevronRight" size={16} />
            </button>
          ))}
        </div>
      )}
      {tab === 'home' && <Home access={access} go={go} listings={listings} reloadAll={reloadAll} openProduct={openProduct} />}
      {tab === 'products' && <Products access={access} listings={listings} findings={findings} go={go} reload={reloadAll} openSku={openSku} setOpenSku={setOpenSku} />}
      {tab === 'decisions' && <Decisions access={access} onChange={reloadAll} openProduct={openProduct} />}
      {tab === 'sales' && <Sales listings={listings} />}
      {view === 'keywords' && <Keywords goDecisions={() => go('decisions')} />}
      {view === 'competitors' && <Competitors myAsins={myAsins} />}
      {view === 'health' && <Health />}
      {view === 'strategy' && <Strategy />}
      {view === 'activity' && <Activity />}
      {view === 'settings' && access.is_admin && <Settings />}
      {access.can_approve && !chat && (
        <button type="button" onClick={() => setChat({ text: '' })} aria-label="Ask Claude"
          className="fab-above-bar fixed right-4 sm:right-5 z-30 rounded-full pl-3.5 pr-4 py-2.5 sm:pl-4 sm:pr-5 sm:py-3 text-sm sm:text-base text-white font-semibold shadow-lg inline-flex items-center gap-2"
          style={{ background: 'linear-gradient(160deg,#D97757,#C15F3C)' }}><Icon name="sparkles" size={18} />Ask Claude</button>
      )}
      <ClaudeChat open={!!chat} preset={chat} onClose={() => setChat(null)} goDecisions={() => go('decisions')} />
    </div>
  );
}
