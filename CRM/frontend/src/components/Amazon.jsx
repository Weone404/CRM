import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog } from './ui/dialogs';
import Icon from './icons';
import { useRoute, navigate } from '../utils/route';
import { chars, utf8Bytes, inr, pct, diffRows, measureImage, STATUS_STYLE, ageText, dispatchText, plain } from '../utils/amazon';

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

const GREEN = { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34' };
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
const SEV_WORD = { blocker: 'Must fix', warning: 'Heads up', confirm: 'Double-check' };
const NEEDS_BR = <Chip bg="rgba(118,118,128,0.12)" fg="#6E6E73">Needs Brand Registry</Chip>;
const Seg = ({ value, options, onChange, label }) => (
  <div className="flex gap-1 p-1 rounded-xl w-max max-w-full overflow-x-auto" role="group" aria-label={label} style={{ background: 'rgba(118,118,128,0.12)' }}>
    {options.map(([v, l]) => (
      <button key={v} type="button" onClick={() => onChange(v)} aria-pressed={value === v}
        className={`px-3 py-1.5 rounded-lg text-sm whitespace-nowrap ${value === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
  </div>
);

function GuardList({ g }) {
  if (!g) return null;
  const items = [...(g.blockers || []), ...(g.confirms || []), ...(g.warnings || [])];
  if (!items.length) return <div className="text-xs mt-2" style={{ color: '#1E7B34' }}>All checks pass.</div>;
  return (
    <ul className="mt-2 space-y-1">
      {items.map((i, n) => (
        <li key={n} className="text-xs flex gap-2 items-start">
          <Chip {...SEV[i.severity]}>{SEV_WORD[i.severity] || i.severity}</Chip><span className="text-glass-secondary">{i.message}</span>
        </li>
      ))}
    </ul>
  );
}

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
function Home({ access, go, listings, reloadAll }) {
  const [o, load, err] = useLoad(() => rpc('api_amz_overview'));
  const [syncing, setSyncing] = useState(false);
  const names = useMemo(() => Object.fromEntries((listings || []).map((l) => [l.sku, l.title])), [listings]);
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
  if (o.pending) todo.push({ tone: '#FF9500', icon: 'check', text: `${o.pending} change${o.pending > 1 ? 's are' : ' is'} waiting for your OK.`, sub: 'Nothing goes to Amazon until you approve it.', btn: 'Review', to: 'approve' });
  const probs = (o.open_findings?.blocker || 0) + (o.open_findings?.warning || 0);
  if (probs) todo.push({ tone: o.open_findings.blocker ? '#FF3B30' : '#FF9500', icon: 'shield', text: `${probs} thing${probs > 1 ? 's' : ''} to fix on your products.`, sub: 'Fixing them helps you show up in search and sell more.', btn: 'See them', to: 'audit' });
  if (slow) todo.push({ tone: '#007AFF', icon: 'zap', text: `Fast delivery is not on for ${slow} product${slow > 1 ? 's' : ''}.`, sub: 'Same-day dispatch gives customers an earlier delivery date.', btn: 'Turn on', to: 'products' });
  if (healthBad?.length) todo.push({ tone: '#FF3B30', icon: 'heart', text: 'Your account health needs attention.', sub: `Problem: ${healthBad.join(', ')}.`, btn: 'See health', to: 'health' });
  if (o.rotation_alert) todo.push({ tone: o.rotation_alert <= 7 ? '#FF3B30' : '#FF9500', icon: 'lock', text: `Amazon password (client secret) expires in ${o.rotation_days_left} days.`, sub: 'Make a new one in Seller Central and paste it in Settings.', btn: access.is_admin && 'Open Settings', to: 'settings' });
  Object.entries(o.last_sync || {}).forEach(([job, r]) => { if (r.status === 'error') todo.push({ tone: '#FF3B30', icon: 'refresh', text: 'Getting data from Amazon failed.', sub: `${job}, ${ageText(r.at)}: ${r.detail}` }); });
  const lastAt = Object.values(o.last_sync || {}).map((r) => r.at).filter(Boolean).sort().pop();
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3">
        <Stat label="Sold today" value={inr(o.sales_today.revenue)} sub={`${o.sales_today.units} item${o.sales_today.units === 1 ? '' : 's'}`} onClick={() => go('sales')} />
        <Stat label="Sold in last 7 days" value={inr(o.sales_7d.revenue)} sub={`${o.sales_7d.units} item${o.sales_7d.units === 1 ? '' : 's'}`} onClick={() => go('sales')} />
      </div>
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
      {o.top_findings.length > 0 && (
        <div className="glass-card p-4">
          <div className="flex justify-between items-center mb-2">
            <h3 className="font-bold">Fix these first</h3>
            <button className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => go('audit')}>See all</button>
          </div>
          <ul className="space-y-3">{o.top_findings.map((f) => {
            const [what, how] = plain(f.rule_code, f.message);
            return (
              <li key={f.id} className="text-sm">
                <div className="font-semibold text-glass-primary">{what}</div>
                <div className="text-xs text-glass-secondary truncate">{f.sku ? (names[f.sku] || f.asin) : 'Whole account'}</div>
                {how && <div className="text-xs text-glass-muted">{how}</div>}
              </li>
            );
          })}</ul>
        </div>
      )}
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

// ---------------------------------------------------------------- My Products
function Products({ listings, findings, go, openStudio, reload }) {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(null);
  const bySku = useMemo(() => {
    const m = {};
    (findings || []).forEach((f) => { if (f.sku) (m[f.sku] = m[f.sku] || []).push(f); });
    return m;
  }, [findings]);
  const list = useMemo(() => (listings || []).filter((r) => !q || `${r.sku} ${r.asin} ${r.title}`.toLowerCase().includes(q.toLowerCase())), [listings, q]);
  const draftPrice = async (r) => {
    const v = await promptDialog(`New price for ${r.asin}`, { message: `Now ${inr(r.price)}${r.buybox_price ? `. The seller winning "Add to Cart" asks ${inr(r.buybox_price)}` : ''}. Never below ₹299.`, placeholder: 'e.g. 349', required: true });
    if (!v) return;
    const c = await run(rpc('api_amz_draft_create', { p_kind: 'price', p_sku: r.sku, p_after: { price: Number(v) }, p_summary: `Price ${inr(r.price)} → ${inr(v)}` }));
    if (c) showToast(c.guard_result.ok ? 'Price change ready. Approve it in Approve Changes.' : `Not allowed: ${c.guard_result.blockers.map((b) => b.message).join(' ')}`, c.guard_result.ok ? 'success' : 'error');
  };
  const draftDispatch = async (r, d) => {
    const c = await run(rpc('api_amz_draft_create', { p_kind: 'dispatch', p_sku: r.sku, p_after: { handling_days: d }, p_summary: `${dispatchText(d)} dispatch` }));
    if (c) showToast(c.guard_result.ok ? 'Ready. Approve it in Approve Changes.' : `Not allowed: ${c.guard_result.blockers.map((b) => b.message).join(' ')}`, c.guard_result.ok ? 'success' : 'error');
    reload();
  };
  return (
    <div className="space-y-3">
      <DeliverySpeed listings={listings} go={go} />
      <input className="glass-input w-full px-3 py-2 text-sm" placeholder="Search your products" value={q} onChange={(e) => setQ(e.target.value)} />
      {!listings ? <Empty>Loading…</Empty> : list.length === 0 ? <Empty>No products found.</Empty> : list.map((r) => {
        const probs = bySku[r.sku] || [];
        const selling = r.status === 'Active';
        return (
          <div key={r.sku} className="glass-card p-3" data-sku={r.sku}>
            <button className="w-full text-left" onClick={() => setOpen(open === r.sku ? null : r.sku)} aria-expanded={open === r.sku}>
              <div className="font-semibold text-glass-primary text-sm">{r.title || '(no name)'}</div>
              <div className="flex flex-wrap gap-1.5 mt-2">
                {r.is_parent ? <Chip>Group of sizes / colours</Chip> : <>
                  {r.price != null && <Chip>{inr(r.price)}</Chip>}
                  {r.quantity != null && <Chip {...(r.quantity < 3 ? SEV.warning : {})}>{r.quantity} in stock</Chip>}
                  <Chip {...(Number(r.handling_days) === 0 && r.handling_days != null ? GREEN : {})}>Ships: {dispatchText(r.handling_days)}</Chip>
                  {r.synced_at && <Chip {...(selling ? GREEN : SEV.blocker)}>{selling ? 'Selling' : 'Not selling'}</Chip>}
                  {r.has_buybox === true && <Chip {...GREEN}>You win "Add to Cart"</Chip>}
                  {r.has_buybox === false && <Chip {...SEV.blocker}>Another seller wins "Add to Cart"</Chip>}
                </>}
                {probs.length > 0 && <Chip {...SEV.warning}>{probs.length} to fix</Chip>}
              </div>
            </button>
            {open === r.sku && (
              <div className="mt-3 pt-3 border-t space-y-3 text-sm" style={{ borderColor: 'var(--border-subtle)' }}>
                {probs.length > 0 && <ul className="space-y-1.5">{probs.map((f) => { const [what, how] = plain(f.rule_code, f.message); return <li key={f.id}><b className="text-glass-primary">{what}.</b> <span className="text-glass-secondary">{how}</span></li>; })}</ul>}
                {!r.is_parent && (
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-xs text-glass-muted">Dispatch time:</span>
                    <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => draftDispatch(r, 0)}>Same day</button>
                    <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => draftDispatch(r, 1)}>Next day</button>
                  </div>
                )}
                <div className="flex flex-wrap gap-2">
                  {!r.is_parent && <button className="glass-btn px-3 py-1.5 text-sm" onClick={() => draftPrice(r)}>Change price</button>}
                  <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => openStudio(r.sku)}>Edit name & text</button>
                  <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => go('images')}>Photos</button>
                </div>
                <div className="text-[11px] text-glass-muted">{r.asin} · {r.sku}{r.synced_at ? ` · updated ${ageText(r.synced_at)}` : ' · not yet updated from Amazon'}</div>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------- Approve Changes
const DONE_MSG = { live: 'Live on Amazon.', executing: 'Sent. Amazon is still applying it.', skipped: 'Already running.',
  failed: 'Amazon said no. See the reason on the card.', stale: 'Amazon changed this product meanwhile. Nothing sent.',
  needs_manual: 'Done in part. One step is left for you (see the card).' };

function Approve({ access, onChange }) {
  const [status, setStatus] = useState('open');
  const [rows, load, err] = useLoad(() => rpc('api_amz_queue', { p_status: status === 'all' ? null : status }), [status]);
  const [busy, setBusy] = useState('');
  const refresh = () => { load(); onChange?.(); };
  const send = async (c) => {
    const a = await run(rpc('api_amz_approve', { p_id: c.id, p_second_confirm: !!c._second }));
    if (a?.status === 'stale') { showToast('This product changed on Amazon after the change was made. Marked "Out of date".', 'error'); return 'stale'; }
    if (!a) return 'error';
    const r = await run(edge('amazon-execute', { id: c.id }));
    return r?.status || 'approved';
  };
  const approve = async (c) => {
    const d = diffRows(c.before, c.after);
    if (c.needs_second_confirm) {
      const msg = `${(c.guard_result.confirms || []).map((x) => x.message).join(' ')}\n\n${d.map((r) => `${r.label}: ${r.before} → ${r.after}`).join('\n')}`;
      if (!(await confirmDialog(msg, { title: 'Please check again', confirmText: 'Yes, approve', danger: true }))) return;
      c._second = true;
    } else if (!(await confirmDialog(`Approve "${c.summary || c.kind}"?`, { message: 'It goes live on Amazon right away.', confirmText: 'Approve' }))) return;
    setBusy(c.id);
    const st = await send(c);
    if (DONE_MSG[st]) showToast(DONE_MSG[st], st === 'failed' ? 'error' : 'success');
    setBusy(''); refresh();
  };
  const ready = (rows || []).filter((c) => c.status === 'pending' && c.guard_result?.ok && !c.needs_second_confirm);
  const approveAll = async () => {
    if (!(await confirmDialog(`Approve all ${ready.length} changes?`, { message: 'Each one goes live on Amazon. Changes that need a second look are skipped.', confirmText: 'Approve all' }))) return;
    setBusy('all');
    const res = {};
    for (let i = 0; i < ready.length; i++) {
      showToast(`Sending ${i + 1} of ${ready.length}…`, 'info');
      const st = await send(ready[i]); res[st] = (res[st] || 0) + 1;
    }
    setBusy('');
    showToast(Object.entries(res).map(([k, n]) => `${n} ${(STATUS_STYLE[k]?.label || k).toLowerCase()}`).join(', '), res.failed ? 'error' : 'success');
    refresh();
  };
  const reject = async (c) => {
    const reason = await promptDialog('Why say no?', { message: 'Claude reads this before suggesting again.', required: true });
    if (reason) { await run(rpc('api_amz_reject', { p_id: c.id, p_reason: reason }), 'Rejected'); refresh(); }
  };
  const act = async (fn, c, msg) => { await run(rpc(fn, { p_id: c.id }), msg); refresh(); };
  return (
    <div className="space-y-3">
      <div className="glass-card p-3 text-xs text-glass-secondary">Nothing changes on Amazon until you approve it here. You can undo a live change any time.</div>
      <div className="flex flex-wrap justify-between gap-2 items-center">
        <Seg label="Show" value={status} onChange={setStatus} options={[['open', 'To do'], ['live', 'Done'], ['rejected', 'Said no'], ['all', 'All']]} />
        {access.can_approve && ready.length > 1 && status !== 'live' && status !== 'rejected' && (
          <button className="glass-btn px-4 py-2 text-sm" disabled={!!busy} onClick={approveAll}>{busy === 'all' ? 'Sending…' : `Approve all (${ready.length})`}</button>)}
      </div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>{status === 'open' ? 'Nothing waiting. All done.' : 'Nothing here.'}</Empty> : rows.map((c) => {
        const st = STATUS_STYLE[c.status] || {};
        return (
          <div key={c.id} className="glass-card p-4 text-sm">
            <div className="flex flex-wrap justify-between gap-2">
              <div className="min-w-0"><div className="font-semibold text-glass-primary">{c.summary || c.kind}</div>
                <div className="text-xs text-glass-muted truncate">{c.before?.title || c.asin || '—'} · suggested by {c.created_by_type === 'claude' ? 'Claude' : c.created_by_type === 'system' ? 'the CRM' : 'you'} · {ageText(c.created_at)}</div></div>
              <Chip bg={st.bg} fg={st.fg}>{st.label || c.status}</Chip>
            </div>
            <div className="mt-3 grid gap-2">
              {diffRows(c.before, c.after).map((r) => (
                <div key={r.key} className="grid sm:grid-cols-[130px_1fr_1fr] gap-1 sm:gap-3 text-xs">
                  <div className="text-glass-muted">{r.label}</div>
                  <div className="whitespace-pre-wrap line-through decoration-1 opacity-60"><span className="sr-only">Now: </span>{r.before}</div>
                  <div className="whitespace-pre-wrap font-medium"><span className="sr-only">New: </span>{r.after}</div>
                </div>
              ))}
            </div>
            <GuardList g={c.guard_result} />
            {c.preview_result?.preview?.issues?.length > 0 && <div className="text-xs mt-2 text-glass-secondary">Amazon says: {c.preview_result.preview.issues.map((i) => i.message).join(' | ')}</div>}
            {c.error && <div className="text-xs mt-2" style={{ color: c.status === 'needs_manual' ? '#7A2EA8' : '#C4261D' }}>{c.error}</div>}
            {c.reject_reason && <div className="text-xs mt-2 text-glass-muted">Said no: {c.reject_reason}</div>}
            <div className="flex flex-wrap gap-2 mt-3">
              {c.status === 'pending' && access.can_approve && <button disabled={!!busy || !c.guard_result?.ok} className="glass-btn px-4 py-1.5 text-sm" onClick={() => approve(c)}>{busy === c.id ? 'Sending…' : 'Approve'}</button>}
              {['pending', 'stale'].includes(c.status) && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => reject(c)}>Say no</button>}
              {['failed', 'stale'].includes(c.status) && <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => act('api_amz_resubmit', c, 'Checked again and put back in the list')}>Check again</button>}
              {c.status === 'needs_manual' && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => act('api_amz_manual_done', c, 'Marked done')}>I did it in Seller Central</button>}
              {['live', 'needs_manual'].includes(c.status) && c.kind !== 'ads_budget' && <button className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => act('api_amz_rollback', c, 'Undo prepared: approve it to undo')}>Undo</button>}
              {c.batch_id && ['pending', 'approved'].includes(c.status) && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-sm" style={{ color: '#C4261D' }}
                onClick={async () => { if (await confirmDialog('Cancel every waiting change in this group?', { danger: true, confirmText: 'Cancel group' })) { const n = await run(rpc('api_amz_cancel_batch', { p_batch: c.batch_id })); if (n !== undefined) showToast(`${n} cancelled`, 'success'); refresh(); } }}>Cancel group</button>}
            </div>
          </div>
        );
      })}
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
      {!d ? <Empty>Loading…</Empty> : d.daily.length === 0 ? <Empty>No sales data yet. It comes from Amazon every hour (yesterday's sales show today).</Empty> : (
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
    </div>
  );
}

// ---------------------------------------------------------------- Audit
function Audit({ access }) {
  const [status, setStatus] = useState('open');
  const [rows, load, err] = useLoad(() => rpc('api_amz_findings', { p_status: status }), [status]);
  const dismiss = async (f) => {
    const reason = await promptDialog('Ignore this?', { message: f.message, placeholder: 'Why (kept in the log)', required: true });
    if (reason) { await run(rpc('api_amz_finding_dismiss', { p_id: f.id, p_reason: reason }), 'Ignored'); load(); }
  };
  const askFix = async (f) => {
    await run(rpc('api_amz_request_create', { p_question: `Draft a fix for finding #${f.id} on ${f.asin || 'the account'} (${f.sku || ''}): ${f.message}` }),
      'Sent to Claude. The fix will show up in Approve Changes after Claude\'s next run.');
  };
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2 justify-between">
        <div className="flex gap-1 p-1 rounded-xl" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[['open', 'To fix'], ['fixed', 'Fixed'], ['dismissed', 'Ignored']].map(([s, l]) => <button key={s} onClick={() => setStatus(s)} className={`px-3 py-1.5 rounded-lg text-sm ${status === s ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>)}
        </div>
        <button className="glass-btn px-3 py-1.5 text-sm" onClick={async () => { const n = await run(rpc('api_amz_audit_run')); if (n !== undefined) showToast(`Checked: ${n} thing(s) to fix`, 'success'); load(); }}>Check again now</button>
      </div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>{status === 'open' ? 'Nothing to fix. Well done.' : 'Nothing here.'}</Empty> : rows.map((f) => (
        <div key={f.id} className="glass-card p-3 text-sm">
          <div className="flex flex-wrap gap-2 items-center"><Chip {...SEV[f.severity]}>{SEV_WORD[f.severity] || f.severity}</Chip><b>{plain(f.rule_code, f.message)[0]}</b></div>
          {plain(f.rule_code)[1] && <div className="mt-1 text-glass-primary">{plain(f.rule_code)[1]}</div>}
          <div className="mt-1 text-xs text-glass-secondary">{f.message}</div>
          <div className="text-[11px] text-glass-muted mt-0.5">{f.asin || 'Whole account'} · {f.sku} · {ageText(f.created_at)}</div>
          {f.dismiss_reason && <div className="text-xs text-glass-muted mt-1">Dismissed: {f.dismiss_reason}</div>}
          {status === 'open' && access.can_view && (
            <div className="flex gap-2 mt-2">
              <button className="glass-btn px-3 py-1 text-xs" onClick={() => askFix(f)}>Ask Claude to fix it</button>
              <button className="glass-btn-ghost px-3 py-1 text-xs" onClick={() => dismiss(f)}>Ignore</button>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- Keywords
function Keywords() {
  const [rows, load, err] = useLoad(() => rpc('api_amz_keywords'));
  const [kw, setKw] = useState('');
  const set = async (keyword, status) => { await run(rpc('api_amz_keyword_set', { p_keyword: keyword, p_status: status })); load(); };
  return (
    <div className="space-y-3">
      <div className="glass-card p-3 text-sm text-glass-secondary flex flex-wrap gap-2 items-center">
        Keyword volume and conversion by search term (Search Query Performance, Top Search Terms) {NEEDS_BR}. Until then the bank is built from
        your listings, competitor titles and Sponsored Products search terms.
      </div>
      <form className="flex gap-2" onSubmit={async (e) => { e.preventDefault(); if (kw.trim()) { await set(kw, 'pinned'); setKw(''); } }}>
        <input className="glass-input flex-1 px-3 py-2 text-sm" placeholder="Add a keyword, e.g. personalised diary 2027" value={kw} onChange={(e) => setKw(e.target.value)} />
        <button className="glass-btn px-4 text-sm">Add</button>
      </form>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No keywords yet. Claude adds candidates on its runs.</Empty> : (
        <div className="glass-card divide-y" style={{ borderColor: 'var(--border-subtle)' }}>
          {rows.map((k) => (
            <div key={k.id} className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
              <span className="font-medium flex-1 min-w-[160px]">{k.keyword}</span>
              <Chip>{k.source}</Chip>{k.placement && <Chip>{k.placement}</Chip>}
              <Chip {...(k.status === 'pinned' ? { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34' } : k.status === 'rejected' ? {} : SEV.confirm)}>{k.status}</Chip>
              {k.status !== 'pinned' && <button className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => set(k.keyword, 'pinned')}>Pin</button>}
              {k.status !== 'rejected' && <button className="text-xs text-glass-muted" onClick={() => set(k.keyword, 'rejected')}>Reject</button>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Competitors
function Competitors({ myAsins }) {
  const [rows, load, err] = useLoad(() => rpc('api_amz_competitors'));
  const [asin, setAsin] = useState('');
  const [mine, setMine] = useState('');
  const add = async (e) => {
    e.preventDefault();
    await run(rpc('api_amz_competitor_set', { p_asin: asin, p_my_asin: mine || null, p_active: true }), 'Added. Price and rank arrive with the next sync.');
    setAsin(''); load();
  };
  return (
    <div className="space-y-3">
      <form className="glass-card p-3 flex flex-wrap gap-2" onSubmit={add}>
        <input className="glass-input px-3 py-2 text-sm flex-1 min-w-[140px]" placeholder="Rival ASIN (B0…)" value={asin} onChange={(e) => setAsin(e.target.value.toUpperCase())} />
        <select className="glass-input px-3 py-2 text-sm" value={mine} onChange={(e) => setMine(e.target.value)}>
          <option value="">Compare with…</option>{myAsins.map((a) => <option key={a} value={a}>{a}</option>)}
        </select>
        <button className="glass-btn px-4 text-sm" disabled={!/^B0[A-Z0-9]{8}$/.test(asin)}>Track</button>
      </form>
      <div className="text-xs text-glass-muted">Amazon does not share rivals' sales, ad spend or conversion. Shown: title, Buy Box price and seller, best-seller rank, image count.</div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No rivals tracked yet.</Empty> : rows.map((c) => (
        <div key={c.asin} className="glass-card p-3 text-sm flex flex-wrap justify-between gap-2">
          <div className="min-w-0"><div className="font-semibold">{c.title || c.asin}</div><div className="text-xs text-glass-muted">{c.asin} · vs {c.my_asin || '—'} · updated {ageText(c.updated_at)}</div></div>
          <div className="flex gap-1.5 flex-wrap items-start">
            <Chip>{inr(c.price)}</Chip>{c.bsr && <Chip>BSR #{c.bsr}</Chip>}{c.image_count != null && <Chip>{c.image_count} images</Chip>}
            <button className="text-xs text-glass-muted" onClick={async () => { await run(rpc('api_amz_competitor_set', { p_asin: c.asin, p_my_asin: c.my_asin, p_active: false })); load(); }}>Remove</button>
          </div>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- Content Studio (+ Product Brief)
function Field({ label, children, count, max, unit = 'characters' }) {
  return (
    <label className="block">
      <span className="flex justify-between text-xs text-glass-secondary mb-1"><span>{label}</span>
        {count != null && <span style={{ color: max && count > max ? '#C4261D' : undefined }}>{count}{max ? `/${max}` : ''} {unit}</span>}</span>
      {children}
    </label>
  );
}

function ContentStudio({ skus, initialSku }) {
  const [sku, setSku] = useState(initialSku || '');
  const [base, setBase] = useState(null);
  const [f, setF] = useState({});
  const [touched, setTouched] = useState({});
  const [guard, setGuard] = useState(null);
  const [brief, setBrief] = useState({ buyer: '', use_cases: '', facts: '' });
  const timer = useRef(null);
  useEffect(() => { if (initialSku) setSku(initialSku); }, [initialSku]);
  useEffect(() => {
    setTouched({}); setGuard(null);
    if (!sku) { setBase(null); return; }
    rpc('api_amz_listing', { p_sku: sku }).then((l) => {
      setBase(l);
      setF({ title: l.title || '', item_highlights: l.item_highlights || '', bullets: [...(l.bullets || []), '', '', '', '', ''].slice(0, 5),
             description: l.description || '', backend_terms: l.backend_terms || '', country_of_origin: l.country_of_origin || '',
             manufacturer: l.manufacturer || '', net_quantity: l.net_quantity || '', mrp: l.mrp ?? '', claims: '' });
      setBrief({ buyer: l.facts?.buyer || '', use_cases: l.facts?.use_cases || '', facts: (l.facts?.facts || []).join('\n') });
    }).catch((e) => showToast(e.message, 'error'));
  }, [sku]);
  const after = useMemo(() => {
    const a = {};
    Object.keys(touched).forEach((k) => {
      if (k === 'bullets') a.bullets = f.bullets.map((b) => b.trim()).filter(Boolean);
      else if (k === 'claims') a.claims = f.claims.split('\n').map((c) => c.trim()).filter(Boolean);
      else a[k] = typeof f[k] === 'string' ? f[k].trim() : f[k];
    });
    return a;
  }, [f, touched]);
  useEffect(() => {
    clearTimeout(timer.current);
    if (!sku || !Object.keys(after).length) { setGuard(null); return undefined; }
    timer.current = setTimeout(() => rpc('api_amz_check', { p_kind: 'listing', p_sku: sku, p_after: after }).then(setGuard).catch(() => {}), 350);
    return () => clearTimeout(timer.current);
  }, [after, sku]);
  const set = (k, v) => { setF((x) => ({ ...x, [k]: v })); setTouched((t) => ({ ...t, [k]: true })); };
  const submit = async () => {
    const summary = await promptDialog('What does this change do?', { placeholder: 'e.g. Shorter product name with "personalised diary 2027" first', required: true });
    if (!summary) return;
    const r = await run(rpc('api_amz_draft_create', { p_kind: 'listing', p_sku: sku, p_after: after, p_summary: summary }));
    if (r) { showToast(r.guard_result.ok ? 'Sent to Approve Changes.' : 'Saved, but something must be fixed before it can be approved.', r.guard_result.ok ? 'success' : 'error'); setTouched({}); }
  };
  const saveBrief = async () => {
    await run(rpc('api_amz_facts_set', { p_asin: base.asin, p_buyer: brief.buyer, p_use_cases: brief.use_cases,
      p_facts: brief.facts.split('\n').map((x) => x.trim()).filter(Boolean) }), 'Product Brief saved');
  };
  const inp = 'glass-input w-full px-3 py-2 text-sm';
  return (
    <div className="space-y-3">
      <select className={inp} value={sku} onChange={(e) => setSku(e.target.value)}>
        <option value="">Pick a product…</option>{skus.map((s) => <option key={s.sku} value={s.sku}>{(s.title || s.sku).slice(0, 70)} · {s.sku}</option>)}
      </select>
      {base && (
        <div className="grid lg:grid-cols-[1fr_320px] gap-3">
          <div className="glass-card p-4 space-y-3">
            {base.is_parent && <div className="text-xs" style={{ color: '#7A2EA8' }}>Parent listing: changes affect all variations and need a second confirm.</div>}
            <Field label="Product name" count={chars(f.title)} max={75}><input className={inp} value={f.title} onChange={(e) => set('title', e.target.value)} /></Field>
            <Field label="Short highlight (shown under the name)" count={chars(f.item_highlights)} max={125}><input className={inp} value={f.item_highlights} onChange={(e) => set('item_highlights', e.target.value)} /></Field>
            {f.bullets.map((b, i) => (
              <Field key={i} label={`Key point ${i + 1}`} count={chars(b)}><textarea rows={2} className={inp} value={b} onChange={(e) => set('bullets', f.bullets.map((x, j) => (j === i ? e.target.value : x)))} /></Field>
            ))}
            <Field label="Description" count={chars(f.description)}><textarea rows={4} className={inp} value={f.description} onChange={(e) => set('description', e.target.value)} /></Field>
            <Field label="Hidden search words (buyers don't see these)" count={utf8Bytes(f.backend_terms)} max={249} unit="bytes"><textarea rows={2} className={inp} value={f.backend_terms} onChange={(e) => set('backend_terms', e.target.value)} /></Field>
            <div className="grid sm:grid-cols-2 gap-3">
              <Field label="MRP (₹)"><input type="number" className={inp} value={f.mrp} onChange={(e) => set('mrp', e.target.value)} /></Field>
              <Field label="Country of origin (e.g. IN)"><input className={inp} value={f.country_of_origin} onChange={(e) => set('country_of_origin', e.target.value.toUpperCase())} /></Field>
              <Field label="Manufacturer name & address"><input className={inp} value={f.manufacturer} onChange={(e) => set('manufacturer', e.target.value)} /></Field>
              <Field label="Net quantity (e.g. 1 diary)"><input className={inp} value={f.net_quantity} onChange={(e) => set('net_quantity', e.target.value)} /></Field>
            </div>
            <Field label="Claims this text makes (one per line; each must be in the Product Brief)"><textarea rows={2} className={inp} value={f.claims} onChange={(e) => set('claims', e.target.value)} /></Field>
          </div>
          <div className="space-y-3">
            <div className="glass-card p-4">
              <h3 className="font-bold text-sm">Amazon rules check</h3>
              {Object.keys(after).length ? <GuardList g={guard} /> : <div className="text-xs text-glass-muted mt-1">Change a field to see the checks.</div>}
              <button className="glass-btn w-full mt-3 py-2 text-sm" disabled={!Object.keys(after).length} onClick={submit}>Send for approval</button>
              <div className="text-[11px] text-glass-muted mt-2">Nothing goes to Amazon until it is approved in Approve Changes. The short highlight and quantity in the box are set by hand in Seller Central after approval.</div>
            </div>
            <div className="glass-card p-4 space-y-2">
              <h3 className="font-bold text-sm">Product Brief · {base.asin}</h3>
              <div className="text-[11px] text-glass-muted">Claude may only claim what is listed here.</div>
              <input className={inp} placeholder="Who buys it" value={brief.buyer} onChange={(e) => setBrief({ ...brief, buyer: e.target.value })} />
              <input className={inp} placeholder="Uses / occasions (office, gifting, students…)" value={brief.use_cases} onChange={(e) => setBrief({ ...brief, use_cases: e.target.value })} />
              <textarea rows={6} className={inp} placeholder={'Facts, one per line:\n160 lined pages\nPU leather cover\nName printed on cover'} value={brief.facts} onChange={(e) => setBrief({ ...brief, facts: e.target.value })} />
              <button className="glass-btn-ghost w-full py-2 text-sm" onClick={saveBrief}>Save brief</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Images
function Images({ skus }) {
  const [sku, setSku] = useState('');
  const [l, setL] = useState(null);
  const [meta, setMeta] = useState(null);
  const [url, setUrl] = useState('');
  const [noText, setNoText] = useState(false);
  useEffect(() => { setMeta(null); setUrl(''); setNoText(false); if (sku) rpc('api_amz_listing', { p_sku: sku }).then(setL); else setL(null); }, [sku]);
  const pick = async (e) => {
    const file = e.target.files?.[0]; if (!file) return;
    try { setMeta(await measureImage(file)); } catch { showToast('Could not read that image', 'error'); }
  };
  const main = useMemo(() => (meta ? { ...meta, has_text: noText ? false : null, url: url.trim() || undefined } : null), [meta, noText, url]);
  const [guard, setGuard] = useState(null);
  useEffect(() => {
    if (!sku || !main) { setGuard(null); return; }
    rpc('api_amz_check', { p_kind: 'listing', p_sku: sku, p_after: { main_image: main } }).then(setGuard).catch(() => {});
  }, [sku, main]);
  const submit = async () => {
    const r = await run(rpc('api_amz_draft_create', { p_kind: 'listing', p_sku: sku, p_after: { main_image: main }, p_summary: 'New main image' }));
    if (r) showToast(r.guard_result.ok ? 'Sent for approval' : 'Saved with blockers', r.guard_result.ok ? 'success' : 'error');
  };
  return (
    <div className="space-y-3">
      <select className="glass-input w-full px-3 py-2 text-sm" value={sku} onChange={(e) => setSku(e.target.value)}>
        <option value="">Pick a product…</option>{skus.map((s) => <option key={s.sku} value={s.sku}>{(s.title || s.sku).slice(0, 70)}</option>)}
      </select>
      {l && (
        <>
          <div className="glass-card p-3">
            <div className="text-sm font-semibold mb-2">On Amazon now</div>
            {(l.images || []).length === 0 ? <div className="text-xs text-glass-muted">No images in the CRM yet (arrive with the first sync).</div> : (
              <div className="flex gap-2 overflow-x-auto">{l.images.map((im) => <div key={im.slot} className="text-center"><img src={im.url} alt={im.slot} className="h-20 w-20 object-contain rounded-lg bg-white" /><div className="text-[10px] text-glass-muted">{im.slot}</div></div>)}</div>
            )}
          </div>
          <div className="glass-card p-4 space-y-2 text-sm">
            <div className="font-semibold">Check a new main image</div>
            <input type="file" accept="image/jpeg,image/png" onChange={pick} />
            {meta && <div className="text-xs">{meta.width}×{meta.height} px · border {meta.white_bg ? 'pure white' : <b style={{ color: '#C4261D' }}>not pure white</b>}</div>}
            <label className="flex gap-2 items-center text-xs"><input type="checkbox" checked={noText} onChange={(e) => setNoText(e.target.checked)} />No text, logo, watermark or props that aren't included</label>
            <input className="glass-input w-full px-3 py-2 text-sm" placeholder="Public https link to the image (needed to send it to Amazon)" value={url} onChange={(e) => setUrl(e.target.value)} />
            {main && <GuardList g={guard} />}
            <button className="glass-btn px-4 py-2 text-sm" disabled={!meta} onClick={submit}>Send for approval</button>
          </div>
        </>
      )}
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

// ---------------------------------------------------------------- Ask Claude
function AskClaude() {
  const [rows, load, err] = useLoad(() => rpc('api_amz_requests'));
  const [q, setQ] = useState('');
  return (
    <div className="space-y-3">
      <div className="glass-card p-3 text-xs text-glass-secondary">Claude answers on its next scheduled run (not instantly). Answers and any drafts appear here and in the Change Queue.</div>
      <form className="space-y-2" onSubmit={async (e) => { e.preventDefault(); if (q.trim().length >= 3) { await run(rpc('api_amz_request_create', { p_question: q }), 'Queued for Claude'); setQ(''); load(); } }}>
        <textarea rows={3} className="glass-input w-full px-3 py-2 text-sm" placeholder="e.g. Why did B0GGHDXNY1 lose the Buy Box, and what should we do without going below ₹299?" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="glass-btn px-4 py-2 text-sm">Ask</button>
      </form>
      <Err msg={err} />
      {(rows || []).map((r) => (
        <div key={r.id} className="glass-card p-3 text-sm">
          <div className="flex justify-between gap-2"><div className="font-medium">{r.question}</div><Chip {...(r.status === 'answered' ? { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34' } : r.status === 'waiting' ? SEV.warning : {})}>{r.status}</Chip></div>
          {r.answer && <div className="mt-2 whitespace-pre-wrap text-glass-secondary">{r.answer}</div>}
          <div className="text-[11px] text-glass-muted mt-1">{ageText(r.created_at)}{r.status === 'waiting' && <button className="ml-2" onClick={async () => { await run(rpc('api_amz_request_cancel', { p_id: r.id })); load(); }}>Cancel</button>}</div>
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
        <div className="text-xs text-glass-muted">Amazon policy limits (title 75 characters, Item Highlights 125, backend 249 bytes, main image rules) are rows too; change them only when Amazon changes its policy.</div>
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
  { id: 'approve', label: 'Approve Changes', short: 'Approve', icon: 'check' },
  { id: 'sales', label: 'Sales', icon: 'tag' },
  { id: 'more', label: 'More', icon: 'more' },
];
const MORE = [
  { id: 'audit', label: 'Things to fix', hint: 'Every problem on your products', icon: 'shield' },
  { id: 'content', label: 'Edit name & text', hint: 'Product name, key points, description', icon: 'form' },
  { id: 'images', label: 'Photos', hint: 'Check a new main photo', icon: 'image' },
  { id: 'keywords', label: 'Search words', hint: 'Words buyers type on Amazon', icon: 'search' },
  { id: 'competitors', label: 'Competitors', hint: 'Watch other sellers\' prices', icon: 'globe' },
  { id: 'health', label: 'Account health', hint: 'Late dispatch, cancels, complaints', icon: 'heart' },
  { id: 'strategy', label: 'To-do list', hint: 'Plans and reminders', icon: 'calendar' },
  { id: 'ask', label: 'Ask Claude', hint: 'Ask a question, get an answer later', icon: 'sparkles' },
  { id: 'activity', label: 'History', hint: 'Who changed what, and when', icon: 'clock' },
  { id: 'settings', label: 'Settings', hint: 'Amazon keys, limits, who can use this', icon: 'settings', admin: true },
];
// Old links keep working.
const ALIAS = { overview: 'home', listings: 'products', inventory: 'products', queue: 'approve' };

export default function Amazon({ access }) {
  const route = useRoute();
  const raw = (route.tab === 'amazon' && route.section) || 'home';
  const view = ALIAS[raw] || raw;
  const [studioSku, setStudioSku] = useState('');
  const [listings, reloadListings] = useLoad(() => rpc('api_amz_listings'));
  const [queue, reloadQueue] = useLoad(() => rpc('api_amz_queue', { p_status: 'pending' }), [view]);
  const [findings, reloadFindings] = useLoad(() => rpc('api_amz_findings', { p_status: 'open' }), [view]);
  useEffect(() => { if (view === 'products') reloadListings(); }, [view, reloadListings]);
  const reloadAll = () => { reloadListings(); reloadQueue(); reloadFindings(); };
  const skus = (listings || []).map((l) => ({ sku: l.sku, asin: l.asin, title: l.title }));
  const myAsins = [...new Set(skus.map((s) => s.asin).filter(Boolean))];
  const go = (v) => navigate('amazon', v);
  const more = MORE.filter((m) => !m.admin || access.is_admin);
  const sub = more.find((m) => m.id === view);
  const tab = sub ? 'more' : (TABS.find((t) => t.id === view) ? view : 'home');
  const count = { approve: queue?.length || 0 };
  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold text-glass-primary">Amazon</h2>
        <div className="text-xs text-glass-muted">Nitaniya · Amazon.in · Easy Ship</div>
      </div>
      <div role="tablist" aria-label="Amazon" className="glass-card p-1 grid grid-cols-5 gap-1">
        {TABS.map((t) => {
          const active = tab === t.id;
          return (
            <button key={t.id} role="tab" aria-selected={active} aria-label={`${t.label}${count[t.id] ? ` ${count[t.id]}` : ''}`} onClick={() => go(t.id)}
              className="relative flex flex-col sm:flex-row items-center justify-center gap-0.5 sm:gap-1.5 rounded-xl py-2 px-1 text-[11px] sm:text-sm min-h-[52px]"
              style={active ? { background: '#007AFF', color: '#fff', fontWeight: 600 } : undefined}>
              <Icon name={t.icon} size={18} />
              <span className="leading-tight text-center"><span className="sm:hidden">{t.short || t.label}</span><span className="hidden sm:inline">{t.label}</span></span>
              {count[t.id] > 0 && <span className="absolute top-1 right-1 sm:static min-w-[1.2rem] h-[1.2rem] px-1 rounded-full text-[10px] font-bold inline-flex items-center justify-center"
                style={{ background: active ? '#fff' : '#FF3B30', color: active ? '#007AFF' : '#fff' }}>{count[t.id]}</span>}
            </button>
          );
        })}
      </div>
      {sub && <button type="button" onClick={() => go('more')} className="text-sm font-semibold inline-flex items-center gap-1" style={{ color: 'var(--accent)' }}><Icon name="chevronLeft" size={16} />More</button>}
      {sub && <h3 className="text-lg font-bold text-glass-primary -mt-2">{sub.label}</h3>}
      {view === 'more' && (
        <div className="grid sm:grid-cols-2 gap-2">
          {more.map((m) => (
            <button key={m.id} type="button" onClick={() => go(m.id)} className="glass-card p-3 flex items-center gap-3 text-left min-h-[64px]">
              <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(0,122,255,0.12)', color: '#007AFF' }}><Icon name={m.icon} size={20} /></span>
              <span className="min-w-0 flex-1"><span className="block font-semibold text-glass-primary">{m.label}</span><span className="block text-xs text-glass-secondary">{m.hint}</span></span>
              {m.id === 'audit' && (findings || []).length > 0 && <Chip {...SEV.warning}>{findings.length}</Chip>}
              <Icon name="chevronRight" size={16} />
            </button>
          ))}
        </div>
      )}
      {tab === 'home' && <Home access={access} go={go} listings={listings} reloadAll={reloadAll} />}
      {tab === 'products' && <Products listings={listings} findings={findings} go={go} reload={reloadAll} openStudio={(s) => { setStudioSku(s); go('content'); }} />}
      {tab === 'approve' && <Approve access={access} onChange={reloadAll} />}
      {tab === 'sales' && <Sales listings={listings} />}
      {view === 'audit' && <Audit access={access} />}
      {view === 'keywords' && <Keywords />}
      {view === 'competitors' && <Competitors myAsins={myAsins} />}
      {view === 'content' && <ContentStudio skus={skus} initialSku={studioSku} />}
      {view === 'images' && <Images skus={skus} />}
      {view === 'health' && <Health />}
      {view === 'strategy' && <Strategy />}
      {view === 'ask' && <AskClaude />}
      {view === 'activity' && <Activity />}
      {view === 'settings' && access.is_admin && <Settings />}
    </div>
  );
}
