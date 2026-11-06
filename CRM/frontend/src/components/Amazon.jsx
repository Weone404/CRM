import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog } from './ui/dialogs';
import SectionNav from './SectionNav';
import Icon from './icons';
import { chars, utf8Bytes, inr, pct, diffRows, measureImage, STATUS_STYLE, ageText } from '../utils/amazon';

// CRM > Amazon (Nitaniya on Amazon.in). Admin, plus people Admin grants in Settings.
// Every read and write goes through api_amz_* database functions, which check access and run the guards
// (price floor, title limits, Legal Metrology fields, ...). Nothing here talks to Amazon directly:
// approved changes are sent by the amazon-execute Edge Function; Claude drafts into the same Change Queue.

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
const Stat = ({ label, value, sub, tone }) => (
  <div className="glass-card p-3">
    <div className="text-xs text-glass-muted">{label}</div>
    <div className="text-2xl font-bold" style={tone ? { color: tone } : undefined}>{value}</div>
    {sub && <div className="text-[11px] text-glass-muted mt-0.5">{sub}</div>}
  </div>
);
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const Err = ({ msg }) => (msg ? <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{msg}</div> : null);
const SEV = { blocker: { bg: 'rgba(255,59,48,0.12)', fg: '#C4261D' }, warning: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00' },
              confirm: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC' }, info: {} };
const NEEDS_BR = <Chip bg="rgba(118,118,128,0.12)" fg="#6E6E73">Needs Brand Registry</Chip>;

function GuardList({ g }) {
  if (!g) return null;
  const items = [...(g.blockers || []), ...(g.confirms || []), ...(g.warnings || [])];
  if (!items.length) return <div className="text-xs mt-2" style={{ color: '#1E7B34' }}>All checks pass.</div>;
  return (
    <ul className="mt-2 space-y-1">
      {items.map((i, n) => (
        <li key={n} className="text-xs flex gap-2 items-start">
          <Chip {...SEV[i.severity]}>{i.severity === 'confirm' ? 'confirm' : i.severity}</Chip><span className="text-glass-secondary">{i.message}</span>
        </li>
      ))}
    </ul>
  );
}

function Score({ s }) {
  if (!s) return null;
  const bar = (label, v) => (
    <div className="flex items-center gap-1.5" title={`${label}: ${v}/100 (CRM heuristic, not an Amazon score)`}>
      <span className="text-[10px] text-glass-muted w-16">{label}</span>
      <span className="h-1.5 w-14 rounded-full overflow-hidden" style={{ background: 'rgba(118,118,128,0.16)' }}>
        <span className="block h-full" style={{ width: `${v}%`, background: v >= 70 ? '#34C759' : v >= 40 ? '#FF9500' : '#FF3B30' }} />
      </span>
    </div>
  );
  return <div className="grid grid-cols-2 gap-x-3 gap-y-1">{bar('Index', s.index)}{bar('Intent', s.intent)}{bar('Conversion', s.conversion)}{bar('Compliance', s.compliance)}</div>;
}

// ---------------------------------------------------------------- Overview
function Overview({ access, go }) {
  const [o, load, err] = useLoad(() => rpc('api_amz_overview'));
  const [syncing, setSyncing] = useState(false);
  const sync = async () => {
    setSyncing(true);
    const r = await run(edge('amazon-sync', { jobs: ['listings', 'pricing'] }));
    setSyncing(false);
    if (r?.status === 'not-configured') showToast(r.detail, 'error');
    else if (r) showToast(r.results.map((x) => `${x.job}: ${x.status}`).join(' · '), r.results.some((x) => x.status === 'error') ? 'error' : 'success');
    load();
  };
  if (err) return <Err msg={err} />;
  if (!o) return <Empty>Loading…</Empty>;
  const h = o.health;
  const alerts = [];
  if (!o.connected) alerts.push({ tone: '#FF9500', text: 'Amazon is not connected yet. Admin: add the keys in Settings, then Test Connection.', to: access.is_admin ? 'settings' : null });
  else if (o.last_test && o.last_test !== 'Connected') alerts.push({ tone: '#FF3B30', text: `Last connection test: ${o.last_test}.`, to: access.is_admin ? 'settings' : null });
  if (o.rotation_alert) alerts.push({ tone: o.rotation_alert <= 7 ? '#FF3B30' : '#FF9500',
    text: `Amazon client secret expires in ${o.rotation_days_left} days. Rotate it in Seller Central and paste the new one in Settings.`, to: access.is_admin ? 'settings' : null });
  Object.entries(o.last_sync || {}).forEach(([job, r]) => { if (r.status === 'error') alerts.push({ tone: '#FF3B30', text: `Sync "${job}" failed ${ageText(r.at)}: ${r.detail}` }); });
  return (
    <div className="space-y-4">
      {alerts.map((a, i) => (
        <button key={i} type="button" disabled={!a.to} onClick={() => a.to && go(a.to)} className="w-full text-left flex items-center gap-3 px-4 py-3 rounded-2xl"
          style={{ background: `${a.tone}1A`, boxShadow: `inset 0 0 0 0.5px ${a.tone}59` }}>
          <span className="w-8 h-8 rounded-full grid place-items-center text-white shrink-0" style={{ background: a.tone }}><Icon name="alert" size={16} /></span>
          <span className="text-sm text-glass-primary">{a.text}</span>
        </button>
      ))}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat label="Sales today" value={inr(o.sales_today.revenue)} sub={`${o.sales_today.units} units`} />
        <Stat label="Last 7 days" value={inr(o.sales_7d.revenue)} sub={`${o.sales_7d.units} units`} />
        <Stat label="Waiting for approval" value={o.pending} tone={o.pending ? '#B25E00' : undefined} />
        <Stat label="Open problems" value={o.open_findings.blocker} sub={`${o.open_findings.warning} warnings`} tone={o.open_findings.blocker ? '#C4261D' : undefined} />
      </div>
      <div className="glass-card p-4">
        <div className="flex justify-between items-center mb-2">
          <h3 className="font-bold">Fix first</h3>
          <button className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => go('audit')}>All findings</button>
        </div>
        {o.top_findings.length === 0 ? <Empty>Nothing open.</Empty> : (
          <ul className="space-y-2">{o.top_findings.map((f) => (
            <li key={f.id} className="flex gap-2 items-start text-sm"><Chip {...SEV[f.severity]}>{f.severity}</Chip>
              <span><b className="text-glass-primary">{f.asin || 'Account'}</b> <span className="text-glass-secondary">{f.message}</span></span></li>))}</ul>
        )}
      </div>
      <div className="grid md:grid-cols-2 gap-3">
        <div className="glass-card p-4">
          <h3 className="font-bold mb-2">Account health</h3>
          {h ? (
            <div className="grid grid-cols-2 gap-2 text-sm">
              <div>Order defect rate <b>{pct(h.odr)}</b> <span className="text-glass-muted">(&lt;1%)</span></div>
              <div>Cancellation <b>{pct(h.cancel_rate)}</b> <span className="text-glass-muted">(&lt;2.5%)</span></div>
              <div>Late shipment <b>{pct(h.late_ship_rate)}</b> <span className="text-glass-muted">(&lt;4%)</span></div>
              <div>Valid tracking <b>{pct(h.valid_tracking_rate)}</b> <span className="text-glass-muted">(&gt;95%)</span></div>
            </div>
          ) : <div className="text-sm text-glass-muted">No health report yet (arrives with the hourly report sync).</div>}
        </div>
        <div className="glass-card p-4">
          <div className="flex justify-between items-center mb-2">
            <h3 className="font-bold">Data freshness</h3>
            {access.is_admin && <button disabled={syncing} onClick={sync} className="glass-btn px-3 py-1.5 text-sm inline-flex items-center gap-1.5"><Icon name="refresh" size={14} />{syncing ? 'Syncing…' : 'Sync now'}</button>}
          </div>
          <ul className="text-sm space-y-1">
            {['listings', 'pricing', 'reports', 'finances', 'execute'].map((j) => (
              <li key={j} className="flex justify-between"><span className="capitalize text-glass-secondary">{j}</span>
                <span>{o.last_sync?.[j] ? `${o.last_sync[j].status} · ${ageText(o.last_sync[j].at)}` : 'never'}</span></li>))}
          </ul>
          {o.waiting_requests > 0 && <div className="text-xs text-glass-muted mt-2">{o.waiting_requests} question(s) waiting for Claude.</div>}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Products & Listings
function Listings({ openStudio }) {
  const [rows, , err] = useLoad(() => rpc('api_amz_listings'));
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(null);
  const [detail, setDetail] = useState(null);
  useEffect(() => { if (open) rpc('api_amz_listing', { p_sku: open }).then(setDetail).catch((e) => showToast(e.message, 'error')); else setDetail(null); }, [open]);
  const list = useMemo(() => (rows || []).filter((r) => !q || `${r.sku} ${r.asin} ${r.title}`.toLowerCase().includes(q.toLowerCase())), [rows, q]);
  if (err) return <Err msg={err} />;
  return (
    <div className="space-y-3">
      <input className="glass-input w-full px-3 py-2 text-sm" placeholder="Search SKU, ASIN or title" value={q} onChange={(e) => setQ(e.target.value)} />
      {!rows ? <Empty>Loading…</Empty> : list.map((r) => (
        <div key={r.sku} className="glass-card p-3">
          <button className="w-full text-left" onClick={() => setOpen(open === r.sku ? null : r.sku)}>
            <div className="flex flex-wrap justify-between gap-2">
              <div className="min-w-0">
                <div className="font-semibold text-glass-primary text-sm">{r.title || '(no title)'}</div>
                <div className="text-xs text-glass-muted mt-0.5">{r.asin} · {r.sku}{r.is_parent ? ' · parent' : ''} · {r.status}</div>
              </div>
              <div className="flex flex-wrap gap-1.5 items-start">
                <Chip {...(r.title_chars > 75 ? SEV.blocker : {})}>{r.title_chars}/75</Chip>
                {r.price != null && <Chip>{inr(r.price)}</Chip>}
                {r.has_buybox === false && <Chip {...SEV.blocker}>Buy Box lost · {inr(r.buybox_price)}</Chip>}
                {r.has_buybox === true && <Chip bg="rgba(52,199,89,0.14)" fg="#1E7B34">Buy Box</Chip>}
                {r.has_buybox == null && !r.is_parent && <Chip {...SEV.warning}>No Buy Box</Chip>}
                {r.quantity != null && <Chip>{r.quantity} in stock</Chip>}
              </div>
            </div>
            <div className="mt-2"><Score s={r.score} /></div>
          </button>
          {open === r.sku && detail && (
            <div className="mt-3 pt-3 border-t space-y-2 text-sm" style={{ borderColor: 'var(--border-subtle)' }}>
              {detail.findings.length > 0 && <ul className="space-y-1">{detail.findings.map((f) => <li key={f.id} className="flex gap-2"><Chip {...SEV[f.severity]}>{f.severity}</Chip><span className="text-glass-secondary">{f.message}</span></li>)}</ul>}
              <div><span className="text-glass-muted">Bullets:</span> {(detail.bullets || []).length || 'none in the CRM yet'}</div>
              <div><span className="text-glass-muted">Country of origin / MRP / manufacturer / net quantity:</span> {[detail.country_of_origin, detail.mrp && inr(detail.mrp), detail.manufacturer, detail.net_quantity].map((v) => v || '—').join(' · ')}</div>
              <div><span className="text-glass-muted">Synced from Amazon:</span> {detail.synced_at ? ageText(detail.synced_at) : 'not yet (imported from your CSV)'}</div>
              <div><span className="text-glass-muted">Versions:</span> {detail.versions.map((v) => `v${v.version} ${v.source}`).join(', ')}</div>
              <button className="glass-btn px-3 py-1.5 text-sm" onClick={() => openStudio(r.sku)}>Edit in Content Studio</button>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- Audit
function Audit({ access }) {
  const [status, setStatus] = useState('open');
  const [rows, load, err] = useLoad(() => rpc('api_amz_findings', { p_status: status }), [status]);
  const dismiss = async (f) => {
    const reason = await promptDialog('Dismiss this finding?', { message: f.message, placeholder: 'Why (kept in the log)', required: true });
    if (reason) { await run(rpc('api_amz_finding_dismiss', { p_id: f.id, p_reason: reason }), 'Dismissed'); load(); }
  };
  const askFix = async (f) => {
    await run(rpc('api_amz_request_create', { p_question: `Draft a fix for finding #${f.id} on ${f.asin || 'the account'} (${f.sku || ''}): ${f.message}` }),
      'Sent to Claude. The draft will appear in the Change Queue after the next run.');
  };
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2 justify-between">
        <div className="flex gap-1 p-1 rounded-xl" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {['open', 'fixed', 'dismissed'].map((s) => <button key={s} onClick={() => setStatus(s)} className={`px-3 py-1.5 rounded-lg text-sm capitalize ${status === s ? 'bg-white font-semibold shadow-sm' : ''}`}>{s}</button>)}
        </div>
        <button className="glass-btn px-3 py-1.5 text-sm" onClick={async () => { const n = await run(rpc('api_amz_audit_run')); if (n !== undefined) showToast(`Audit done: ${n} failing checks`, 'success'); load(); }}>Run audit now</button>
      </div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No {status} findings.</Empty> : rows.map((f) => (
        <div key={f.id} className="glass-card p-3 text-sm">
          <div className="flex flex-wrap gap-2 items-center"><Chip {...SEV[f.severity]}>{f.severity}</Chip><b>{f.asin || 'Account'}</b><span className="text-glass-muted text-xs">{f.sku} · {f.rule_code} · {ageText(f.created_at)}</span></div>
          <div className="mt-1 text-glass-secondary">{f.message}</div>
          {f.dismiss_reason && <div className="text-xs text-glass-muted mt-1">Dismissed: {f.dismiss_reason}</div>}
          {status === 'open' && access.can_view && (
            <div className="flex gap-2 mt-2">
              <button className="glass-btn px-3 py-1 text-xs" onClick={() => askFix(f)}>Ask Claude to draft a fix</button>
              <button className="glass-btn-ghost px-3 py-1 text-xs" onClick={() => dismiss(f)}>Dismiss</button>
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
    const summary = await promptDialog('What does this change do?', { placeholder: 'e.g. Title to 75 chars, keyword "personalised diary 2027" first', required: true });
    if (!summary) return;
    const r = await run(rpc('api_amz_draft_create', { p_kind: 'listing', p_sku: sku, p_after: after, p_summary: summary }));
    if (r) { showToast(r.guard_result.ok ? 'Sent to the Change Queue for approval.' : 'Saved, but it has blockers; fix them before it can be approved.', r.guard_result.ok ? 'success' : 'error'); setTouched({}); }
  };
  const saveBrief = async () => {
    await run(rpc('api_amz_facts_set', { p_asin: base.asin, p_buyer: brief.buyer, p_use_cases: brief.use_cases,
      p_facts: brief.facts.split('\n').map((x) => x.trim()).filter(Boolean) }), 'Product Brief saved');
  };
  const inp = 'glass-input w-full px-3 py-2 text-sm';
  return (
    <div className="space-y-3">
      <select className={inp} value={sku} onChange={(e) => setSku(e.target.value)}>
        <option value="">Pick a listing…</option>{skus.map((s) => <option key={s.sku} value={s.sku}>{s.asin} · {s.sku} · {(s.title || '').slice(0, 60)}</option>)}
      </select>
      {base && (
        <div className="grid lg:grid-cols-[1fr_320px] gap-3">
          <div className="glass-card p-4 space-y-3">
            {base.is_parent && <div className="text-xs" style={{ color: '#7A2EA8' }}>Parent listing: changes affect all variations and need a second confirm.</div>}
            <Field label="Title" count={chars(f.title)} max={75}><input className={inp} value={f.title} onChange={(e) => set('title', e.target.value)} /></Field>
            <Field label="Item Highlights (shown under the title)" count={chars(f.item_highlights)} max={125}><input className={inp} value={f.item_highlights} onChange={(e) => set('item_highlights', e.target.value)} /></Field>
            {f.bullets.map((b, i) => (
              <Field key={i} label={`Bullet ${i + 1}`} count={chars(b)}><textarea rows={2} className={inp} value={b} onChange={(e) => set('bullets', f.bullets.map((x, j) => (j === i ? e.target.value : x)))} /></Field>
            ))}
            <Field label="Description" count={chars(f.description)}><textarea rows={4} className={inp} value={f.description} onChange={(e) => set('description', e.target.value)} /></Field>
            <Field label="Backend search terms" count={utf8Bytes(f.backend_terms)} max={249} unit="bytes"><textarea rows={2} className={inp} value={f.backend_terms} onChange={(e) => set('backend_terms', e.target.value)} /></Field>
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
              <h3 className="font-bold text-sm">Checks</h3>
              {Object.keys(after).length ? <GuardList g={guard} /> : <div className="text-xs text-glass-muted mt-1">Change a field to see the checks.</div>}
              <button className="glass-btn w-full mt-3 py-2 text-sm" disabled={!Object.keys(after).length} onClick={submit}>Send for approval</button>
              <div className="text-[11px] text-glass-muted mt-2">Nothing goes to Amazon until it is approved in the Change Queue. Item Highlights and net quantity are set by hand in Seller Central after approval.</div>
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
        <option value="">Pick a listing…</option>{skus.map((s) => <option key={s.sku} value={s.sku}>{s.asin} · {(s.title || '').slice(0, 70)}</option>)}
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

// ---------------------------------------------------------------- Change Queue
function ChangeQueue({ access }) {
  const [status, setStatus] = useState('open');
  const [rows, load, err] = useLoad(() => rpc('api_amz_queue', { p_status: status === 'all' ? null : status }), [status]);
  const [busy, setBusy] = useState('');
  const approve = async (c) => {
    let second = false;
    const d = diffRows(c.before, c.after);
    if (c.needs_second_confirm) {
      const msg = `${(c.guard_result.confirms || []).map((x) => x.message).join(' ')}\n\n${d.map((r) => `${r.label}: ${r.before} → ${r.after}`).join('\n')}`;
      if (!(await confirmDialog(msg, { title: 'Second confirmation', confirmText: 'Yes, approve', danger: true }))) return;
      second = true;
    } else if (!(await confirmDialog(`Approve "${c.summary || c.kind}" for ${c.asin || c.sku}?`, { confirmText: 'Approve' }))) return;
    setBusy(c.id);
    const a = await run(rpc('api_amz_approve', { p_id: c.id, p_second_confirm: second }));
    if (a?.status === 'stale') { showToast('The listing changed since this draft. Marked Stale: review and re-submit.', 'error'); setBusy(''); load(); return; }
    if (a) {
      const r = await run(edge('amazon-execute', { id: c.id }));
      if (r) showToast({ live: 'Live on Amazon.', executing: 'Sent. Amazon is still applying it; the CRM will confirm.', skipped: 'Already running.',
        failed: 'Amazon rejected it. See the reason on the card.', stale: 'Amazon changed this listing meanwhile. Nothing sent.',
        needs_manual: 'Done in part. One step is left for you (see the card).' }[r.status] || r.status, r.status === 'failed' ? 'error' : 'success');
    }
    setBusy(''); load();
  };
  const reject = async (c) => {
    const reason = await promptDialog('Why reject?', { message: 'Claude reads this before drafting again.', required: true });
    if (reason) { await run(rpc('api_amz_reject', { p_id: c.id, p_reason: reason }), 'Rejected'); load(); }
  };
  const act = async (fn, c, msg) => { await run(rpc(fn, { p_id: c.id }), msg); load(); };
  return (
    <div className="space-y-3">
      <div className="flex gap-1 p-1 rounded-xl overflow-x-auto" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {[['open', 'Open'], ['pending', 'Waiting'], ['live', 'Live'], ['rejected', 'Rejected'], ['all', 'All']].map(([s, l]) => (
          <button key={s} onClick={() => setStatus(s)} className={`px-3 py-1.5 rounded-lg text-sm whitespace-nowrap ${status === s ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
      </div>
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>Nothing here.</Empty> : rows.map((c) => {
        const st = STATUS_STYLE[c.status] || {};
        return (
          <div key={c.id} className="glass-card p-4 text-sm">
            <div className="flex flex-wrap justify-between gap-2">
              <div><div className="font-semibold text-glass-primary">{c.summary || c.kind}</div>
                <div className="text-xs text-glass-muted">{c.asin || '—'} · {c.sku || ''} · by {c.created_by_type} · {ageText(c.created_at)}{c.batch_id ? ' · batch' : ''}</div></div>
              <Chip bg={st.bg} fg={st.fg}>{st.label || c.status}</Chip>
            </div>
            <div className="mt-3 grid gap-2">
              {diffRows(c.before, c.after).map((r) => (
                <div key={r.key} className="grid sm:grid-cols-[130px_1fr_1fr] gap-1 sm:gap-3 text-xs">
                  <div className="text-glass-muted">{r.label}</div>
                  <div className="whitespace-pre-wrap line-through decoration-1 opacity-60">{r.before}</div>
                  <div className="whitespace-pre-wrap font-medium">{r.after}</div>
                </div>
              ))}
            </div>
            <GuardList g={c.guard_result} />
            {c.preview_result?.preview?.issues?.length > 0 && <div className="text-xs mt-2 text-glass-secondary">Amazon preview: {c.preview_result.preview.issues.map((i) => i.message).join(' | ')}</div>}
            {c.error && <div className="text-xs mt-2" style={{ color: c.status === 'needs_manual' ? '#7A2EA8' : '#C4261D' }}>{c.error}</div>}
            {c.reject_reason && <div className="text-xs mt-2 text-glass-muted">Rejected: {c.reject_reason}</div>}
            <div className="flex flex-wrap gap-2 mt-3">
              {c.status === 'pending' && access.can_approve && <button disabled={busy === c.id || !c.guard_result?.ok} className="glass-btn px-3 py-1.5 text-xs" onClick={() => approve(c)}>{busy === c.id ? 'Working…' : c.needs_second_confirm ? 'Approve (needs 2nd confirm)' : 'Approve & send'}</button>}
              {['pending', 'stale'].includes(c.status) && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => reject(c)}>Reject</button>}
              {['failed', 'stale'].includes(c.status) && <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => act('api_amz_resubmit', c, 'Back in the queue')}>Re-check & resubmit</button>}
              {c.status === 'needs_manual' && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => act('api_amz_manual_done', c, 'Marked done')}>I did it in Seller Central</button>}
              {['live', 'needs_manual'].includes(c.status) && c.kind !== 'ads_budget' && <button className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => act('api_amz_rollback', c, 'Rollback drafted: approve it to undo')}>Roll back</button>}
              {c.batch_id && ['pending', 'approved'].includes(c.status) && access.can_approve && <button className="glass-btn-ghost px-3 py-1.5 text-xs" style={{ color: '#C4261D' }}
                onClick={async () => { if (await confirmDialog('Cancel every waiting change in this batch?', { danger: true, confirmText: 'Cancel batch' })) { const n = await run(rpc('api_amz_cancel_batch', { p_batch: c.batch_id })); if (n !== undefined) showToast(`${n} cancelled`, 'success'); load(); } }}>Cancel batch</button>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------- Sales
function Sales() {
  const [days, setDays] = useState(30);
  const [d, , err] = useLoad(() => rpc('api_amz_sales', { p_days: days }), [days]);
  const max = Math.max(1, ...((d?.daily || []).map((x) => Number(x.revenue))));
  const total = (d?.daily || []).reduce((a, x) => ({ rev: a.rev + Number(x.revenue), units: a.units + Number(x.units) }), { rev: 0, units: 0 });
  return (
    <div className="space-y-3">
      <div className="flex gap-1 p-1 rounded-xl w-max" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {[7, 30, 90].map((n) => <button key={n} onClick={() => setDays(n)} className={`px-3 py-1.5 rounded-lg text-sm ${days === n ? 'bg-white font-semibold shadow-sm' : ''}`}>{n} days</button>)}
      </div>
      <Err msg={err} />
      {!d ? <Empty>Loading…</Empty> : d.daily.length === 0 ? <Empty>No sales data yet. It arrives with the hourly report sync (one day behind, IST days).</Empty> : (
        <>
          <div className="grid grid-cols-2 gap-3"><Stat label={`Revenue, ${days} days`} value={inr(total.rev)} /><Stat label="Units" value={total.units} /></div>
          <div className="glass-card p-4">
            <div className="text-xs text-glass-muted mb-2">Ordered revenue per day (IST)</div>
            <div className="flex items-end gap-[2px] h-32" role="img" aria-label="Revenue per day">
              {d.daily.map((x) => <div key={x.day} title={`${x.day}: ${inr(x.revenue)}, ${x.units} units`} className="flex-1 rounded-t" style={{ height: `${(Number(x.revenue) / max) * 100}%`, minHeight: 2, background: 'var(--accent)' }} />)}
            </div>
            <div className="flex justify-between text-[10px] text-glass-muted mt-1"><span>{d.daily[0].day}</span><span>{d.daily[d.daily.length - 1].day}</span></div>
          </div>
          <div className="glass-card overflow-x-auto">
            <table className="w-full text-sm"><thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">SKU</th><th className="p-2">ASIN</th><th className="p-2 text-right">Units</th><th className="p-2 text-right">Revenue</th><th className="p-2 text-right">Sessions</th><th className="p-2 text-right">Conversion</th></tr></thead>
              <tbody>{d.by_sku.map((r) => <tr key={r.sku} className="border-t" style={{ borderColor: 'var(--border-subtle)' }}><td className="p-2">{r.sku}</td><td className="p-2">{r.asin}</td><td className="p-2 text-right">{r.units}</td><td className="p-2 text-right">{inr(r.revenue)}</td><td className="p-2 text-right">{r.sessions ?? '—'}</td><td className="p-2 text-right">{pct(r.conversion_pct)}</td></tr>)}</tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Account health
function Health() {
  const [d, , err] = useLoad(() => rpc('api_amz_health', { p_days: 90 }));
  const rows = [['odr', 'Order defect rate', 1, false], ['cancel_rate', 'Cancellation rate', 2.5, false], ['late_ship_rate', 'Late shipment rate', 4, false], ['valid_tracking_rate', 'Valid tracking rate', 95, true]];
  const last = d?.days?.[d.days.length - 1];
  return (
    <div className="space-y-3">
      <Err msg={err} />
      {!d ? <Empty>Loading…</Empty> : !last ? <Empty>No health report yet.</Empty> : (
        <div className="grid md:grid-cols-2 gap-3">
          {rows.map(([k, label, limit, higherIsBetter]) => {
            const v = last[k]; const warn = d.warn?.[k];
            const bad = v != null && (higherIsBetter ? v <= warn : v >= warn);
            return <Stat key={k} label={`${label} (Amazon ${higherIsBetter ? 'min' : 'max'} ${limit}%, CRM warns at ${warn}%)`} value={pct(v)} tone={bad ? '#C4261D' : '#1E7B34'} sub={`as of ${last.day}`} />;
          })}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Inventory & Pricing
function Inventory() {
  const [rows, , err] = useLoad(() => rpc('api_amz_inventory'));
  const draftPrice = async (r) => {
    const v = await promptDialog(`New price for ${r.asin}`, { message: `Now ${inr(r.price)}${r.buybox_price ? `, Buy Box ${inr(r.buybox_price)}` : ''}. Never below the floor (₹299).`, placeholder: 'e.g. 349', required: true });
    if (!v) return;
    const c = await run(rpc('api_amz_draft_create', { p_kind: 'price', p_sku: r.sku, p_after: { price: Number(v) }, p_summary: `Price ${inr(r.price)} → ${inr(v)}` }));
    if (c) showToast(c.guard_result.ok ? 'Price change sent for approval' : `Blocked: ${c.guard_result.blockers.map((b) => b.message).join(' ')}`, c.guard_result.ok ? 'success' : 'error');
  };
  return (
    <div className="space-y-2">
      <Err msg={err} />
      {!rows ? <Empty>Loading…</Empty> : rows.map((r) => (
        <div key={r.sku} className="glass-card p-3 text-sm flex flex-wrap justify-between gap-2">
          <div className="min-w-0"><div className="font-semibold truncate max-w-[520px]">{r.title}</div><div className="text-xs text-glass-muted">{r.asin} · {r.sku} · {r.fulfillment}</div></div>
          <div className="flex flex-wrap gap-1.5 items-center">
            <Chip>{r.quantity ?? '—'} in stock</Chip>
            <Chip {...(r.days_of_cover != null && r.days_of_cover < 14 ? SEV.blocker : {})}>{r.days_of_cover != null ? `${r.days_of_cover} days of cover` : 'no sales yet'}</Chip>
            <Chip>{inr(r.price)}</Chip>
            {r.has_buybox === false && <Chip {...SEV.blocker}>Buy Box {inr(r.buybox_price)}</Chip>}
            <button className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => draftPrice(r)}>Change price</button>
          </div>
        </div>
      ))}
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
export default function Amazon({ access }) {
  const [view, setView] = useState('overview');
  const [studioSku, setStudioSku] = useState('');
  const [listings, reloadListings] = useLoad(() => rpc('api_amz_listings'));
  const [queue] = useLoad(() => rpc('api_amz_queue', { p_status: 'pending' }), [view]);
  const [findings] = useLoad(() => rpc('api_amz_findings', { p_status: 'open' }), [view]);
  useEffect(() => { if (view === 'listings') reloadListings(); }, [view, reloadListings]);
  const skus = (listings || []).map((l) => ({ sku: l.sku, asin: l.asin, title: l.title }));
  const myAsins = [...new Set(skus.map((s) => s.asin).filter(Boolean))];
  const go = (v) => { setView(v); window.scrollTo({ top: 0, behavior: 'smooth' }); };
  const GROUPS = [
    { label: 'Today', items: [
      { id: 'overview', label: 'Overview', hint: 'Sales, alerts, what to fix first', icon: 'chart' },
      { id: 'queue', label: 'Change Queue', hint: 'Approve before anything goes live', icon: 'check', count: queue?.length || 0 },
      { id: 'ask', label: 'Ask Claude', hint: 'Questions and tasks for Claude', icon: 'sparkles' },
    ] },
    { label: 'Listings', items: [
      { id: 'listings', label: 'Products & Listings', hint: 'Every SKU with its scorecard', icon: 'list' },
      { id: 'audit', label: 'Audit', hint: 'Rule failures by listing', icon: 'shield', count: (findings || []).filter((f) => f.severity === 'blocker').length },
      { id: 'content', label: 'Content Studio', hint: 'Title, bullets, backend terms, brief', icon: 'form' },
      { id: 'images', label: 'Images', hint: 'Main image checks', icon: 'image' },
    ] },
    { label: 'Growth', items: [
      { id: 'keywords', label: 'Keywords', hint: 'Keyword bank', icon: 'search' },
      { id: 'competitors', label: 'Competitors', hint: 'Rival ASINs side by side', icon: 'globe' },
      { id: 'inventory', label: 'Inventory & Pricing', hint: 'Buy Box, days of cover', icon: 'tag' },
      { id: 'strategy', label: 'Strategy & Calendar', hint: 'Plan and tasks', icon: 'calendar' },
    ] },
    { label: 'Results', items: [
      { id: 'sales', label: 'Sales', hint: 'Revenue and units by day and SKU', icon: 'chart' },
      { id: 'health', label: 'Account Health', hint: 'ODR, cancellations, late shipments', icon: 'heart' },
      { id: 'activity', label: 'Activity Log', hint: 'Who changed what', icon: 'clock' },
      access.is_admin && { id: 'settings', label: 'Settings', hint: 'Keys, guards, access', icon: 'settings' },
    ].filter(Boolean) },
  ];
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap justify-between items-center gap-2">
        <div><h2 className="text-xl font-bold text-glass-primary">Amazon</h2><div className="text-xs text-glass-muted">Nitaniya · Amazon.in · Easy Ship (FBM)</div></div>
      </div>
      <SectionNav groups={GROUPS} value={view} onChange={go} />
      {view === 'overview' && <Overview access={access} go={go} />}
      {view === 'listings' && <Listings openStudio={(sku) => { setStudioSku(sku); go('content'); }} />}
      {view === 'audit' && <Audit access={access} />}
      {view === 'keywords' && <Keywords />}
      {view === 'competitors' && <Competitors myAsins={myAsins} />}
      {view === 'content' && <ContentStudio skus={skus} initialSku={studioSku} />}
      {view === 'images' && <Images skus={skus} />}
      {view === 'queue' && <ChangeQueue access={access} />}
      {view === 'sales' && <Sales />}
      {view === 'health' && <Health />}
      {view === 'inventory' && <Inventory />}
      {view === 'strategy' && <Strategy />}
      {view === 'ask' && <AskClaude />}
      {view === 'activity' && <Activity />}
      {view === 'settings' && access.is_admin && <Settings />}
    </div>
  );
}
