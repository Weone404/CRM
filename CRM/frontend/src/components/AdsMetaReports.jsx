import { useEffect, useMemo, useState } from 'react';
import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';
import { BREAKDOWNS, derived, sumRows } from '../../../supabase/functions/_shared/meta_report.ts';
import { showToast } from '../utils/toast';

// CRM > Meta Ads > Reports (migration 105): Ads Manager-style reporting. Numbers come live from Meta's Insights API through
// ads-sync (cached 3 h for recent days, 7 days for old ones); CRM results are joined per campaign / ad set / ad.

const C = { blue: '#0088FF', green: '#1E9E4A', red: '#D93025', grey: 'rgba(118,118,128,0.12)' };
const num = (v) => { if (v === null || v === undefined || v === '') return null; const x = Number(v); return Number.isFinite(x) ? x : null; };
const F = {
  inr: (v) => (num(v) === null ? '–' : `₹${Math.round(v).toLocaleString('en-IN')}`),
  inr2: (v) => (num(v) === null ? '–' : `₹${Number(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`),
  int: (v) => (num(v) === null ? '–' : Math.round(v).toLocaleString('en-IN')),
  dec2: (v) => (num(v) === null ? '–' : Number(v).toFixed(2)),
  pct: (v) => (num(v) === null ? '–' : `${Number(v).toFixed(2)}%`),
  rank: (v) => (v ? String(v).replace(/_/g, ' ').toLowerCase().replace('below average', 'below avg').replace('above average', 'above avg') : '–'),
};
export const METRICS = [
  { id: 'spend', label: 'Amount spent', fmt: 'inr', group: 'Performance', neutral: true },
  { id: 'leads', label: 'Leads (Meta)', fmt: 'int', group: 'Performance' },
  { id: 'cpl', label: 'Cost per lead', fmt: 'inr', group: 'Performance', low: true },
  { id: 'reach', label: 'Reach', fmt: 'int', group: 'Delivery' },
  { id: 'impressions', label: 'Impressions', fmt: 'int', group: 'Delivery', neutral: true },
  { id: 'frequency', label: 'Frequency', fmt: 'dec2', group: 'Delivery', neutral: true },
  { id: 'cpm', label: 'CPM (per 1,000 impressions)', fmt: 'inr2', group: 'Delivery', low: true },
  { id: 'cpr', label: 'Cost per 1,000 people reached', fmt: 'inr2', group: 'Delivery', low: true },
  { id: 'clicks', label: 'Clicks (all)', fmt: 'int', group: 'Engagement' },
  { id: 'ctr', label: 'CTR (all)', fmt: 'pct', group: 'Engagement' },
  { id: 'cpc', label: 'CPC (all)', fmt: 'inr2', group: 'Engagement', low: true },
  { id: 'link_clicks', label: 'Link clicks', fmt: 'int', group: 'Engagement' },
  { id: 'link_ctr', label: 'Link CTR', fmt: 'pct', group: 'Engagement' },
  { id: 'cplc', label: 'Cost per link click', fmt: 'inr2', group: 'Engagement', low: true },
  { id: 'lead_rate', label: 'Lead rate (leads ÷ link clicks)', fmt: 'pct', group: 'Engagement' },
  { id: 'video_3s', label: '3-second video plays', fmt: 'int', group: 'Video' },
  { id: 'hook', label: 'Hook rate (3-s plays ÷ impressions)', fmt: 'pct', group: 'Video' },
  { id: 'p25', label: 'Video plays at 25%', fmt: 'int', group: 'Video' },
  { id: 'p50', label: 'Video plays at 50%', fmt: 'int', group: 'Video' },
  { id: 'p75', label: 'Video plays at 75%', fmt: 'int', group: 'Video' },
  { id: 'p100', label: 'Video plays at 100%', fmt: 'int', group: 'Video' },
  { id: 'thruplay', label: 'ThruPlays', fmt: 'int', group: 'Video' },
  { id: 'hold', label: 'Hold rate (ThruPlays ÷ 3-s plays)', fmt: 'pct', group: 'Video' },
  { id: 'quality', label: 'Quality ranking', fmt: 'rank', group: 'Ad relevance (ads only)' },
  { id: 'engagement', label: 'Engagement rate ranking', fmt: 'rank', group: 'Ad relevance (ads only)' },
  { id: 'conversion', label: 'Conversion rate ranking', fmt: 'rank', group: 'Ad relevance (ads only)' },
  { id: 'crm', label: 'Leads in CRM', fmt: 'int', group: 'CRM results' },
  { id: 'qualified', label: 'Qualified leads', fmt: 'int', group: 'CRM results' },
  { id: 'customers', label: 'Admissions', fmt: 'int', group: 'CRM results' },
  { id: 'cpq', label: 'Cost per qualified lead', fmt: 'inr', group: 'CRM results', low: true },
  { id: 'cpa', label: 'Cost per admission', fmt: 'inr', group: 'CRM results', low: true },
];
const M = Object.fromEntries(METRICS.map((m) => [m.id, m]));
export const PRESETS = {
  performance: { label: 'Performance', cols: ['spend', 'leads', 'cpl', 'reach', 'impressions', 'frequency', 'cpm', 'link_clicks', 'link_ctr'] },
  leads_crm: { label: 'Leads and CRM results', cols: ['spend', 'leads', 'cpl', 'crm', 'qualified', 'customers', 'cpq', 'cpa', 'lead_rate'] },
  delivery: { label: 'Delivery', cols: ['spend', 'reach', 'impressions', 'frequency', 'cpm', 'cpr'] },
  engagement: { label: 'Engagement', cols: ['impressions', 'clicks', 'ctr', 'cpc', 'link_clicks', 'link_ctr', 'cplc'] },
  video: { label: 'Video engagement', cols: ['spend', 'impressions', 'video_3s', 'hook', 'p25', 'p50', 'p75', 'p100', 'thruplay', 'hold'] },
  relevance: { label: 'Ad relevance', cols: ['spend', 'leads', 'cpl', 'quality', 'engagement', 'conversion'] },
};
const STATUS_OPTS = [['ACTIVE', 'Active'], ['PAUSED', 'Paused'], ['CAMPAIGN_PAUSED', 'Campaign paused'], ['ADSET_PAUSED', 'Ad set paused'],
  ['ARCHIVED', 'Archived'], ['DISAPPROVED', 'Rejected'], ['WITH_ISSUES', 'With issues'], ['PENDING_REVIEW', 'In review']];
const DIM_LABEL = { period: 'Date', age: 'Age', gender: 'Gender', country: 'Country', region: 'Region', platform: 'Platform', placement: 'Placement',
  device: 'Device', hour: 'Hour', frequency: 'Times seen' };
const LEVEL = { campaign: 'Campaigns', adset: 'Ad sets', ad: 'Ads', account: 'Whole account' };

const iso = (d) => d.toISOString().slice(0, 10);
const shift = (s, n) => iso(new Date(Date.parse(`${s}T00:00:00Z`) + n * 86400e3));
export function presetRange(id, today) {
  const m0 = `${today.slice(0, 8)}01`;
  switch (id) {
    case 'today': return [today, today];
    case 'yesterday': return [shift(today, -1), shift(today, -1)];
    case 'last_7': return [shift(today, -7), shift(today, -1)];
    case 'last_14': return [shift(today, -14), shift(today, -1)];
    case 'last_28': return [shift(today, -28), shift(today, -1)];
    case 'last_30': return [shift(today, -30), shift(today, -1)];
    case 'last_90': return [shift(today, -90), shift(today, -1)];
    case 'this_month': return [m0, today];
    case 'last_month': { const end = shift(m0, -1); return [`${end.slice(0, 8)}01`, end]; }
    case 'last_365': return [shift(today, -365), shift(today, -1)];
    case 'maximum': return [shift(today, -1125), today];
    default: return null;
  }
}
const DATE_PRESETS = [['today', 'Today'], ['yesterday', 'Yesterday'], ['last_7', 'Last 7 days'], ['last_14', 'Last 14 days'], ['last_28', 'Last 28 days'],
  ['last_30', 'Last 30 days'], ['last_90', 'Last 90 days'], ['this_month', 'This month'], ['last_month', 'Last month'], ['last_365', 'Last 12 months'],
  ['maximum', 'Maximum (37 months)'], ['custom', 'Custom']];

function withDerived(r) {
  const d = derived(r);
  return { ...r, ...d, cpq: r.qualified > 0 ? r.spend / r.qualified : null, cpa: r.customers > 0 ? r.spend / r.customers : null };
}
const delta = (a, b, low, neutral) => {
  if (num(a) === null || num(b) === null || b === 0) return null;
  const p = ((a - b) / Math.abs(b)) * 100;
  if (Math.abs(p) < 0.5) return null;
  return { p, good: low ? p < 0 : p > 0, neutral };
};
const dColor = (d) => (d.neutral ? 'rgba(60,60,67,0.6)' : d.good ? C.green : C.red);

function Multi({ label, options, value, onChange, testid }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const shown = options.filter((o) => !q || o.label.toLowerCase().includes(q.toLowerCase())).slice(0, 200);
  return (
    <div className="relative" data-testid={testid}>
      <button type="button" onClick={() => setOpen(!open)} className="glass-input px-3 py-2 text-sm whitespace-nowrap" aria-expanded={open}>
        {label}{value.length ? ` (${value.length})` : ''} ▾</button>
      {open && <div className="absolute z-30 mt-1 w-72 max-h-80 overflow-auto rounded-xl p-2 shadow-lg space-y-1" style={{ background: 'var(--glass-bg, #fff)', border: '1px solid rgba(0,0,0,0.08)' }}>
        {options.length > 8 && <input aria-label={`Search ${label}`} className="glass-input w-full px-2 py-1 text-xs" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search" />}
        {shown.map((o) => (
          <label key={o.value} className="flex items-center gap-2 text-xs py-0.5"><input type="checkbox" checked={value.includes(o.value)}
            onChange={() => onChange(value.includes(o.value) ? value.filter((x) => x !== o.value) : [...value, o.value])} />
            <span className="truncate">{o.label}</span></label>))}
        <div className="flex gap-2 pt-1"><Btn ghost onClick={() => onChange([])}>Clear</Btn><Btn ghost onClick={() => setOpen(false)}>Done</Btn></div>
      </div>}
    </div>);
}

function Bars({ rows, metric, label }) {
  const m = M[metric];
  const top = rows.filter((r) => num(r[metric]) !== null).sort((a, b) => (m.low ? a[metric] - b[metric] : b[metric] - a[metric])).slice(0, 15);
  const max = Math.max(1e-9, ...top.map((r) => Math.abs(r[metric])));
  return (
    <div className="space-y-1" data-testid="report-chart">{top.map((r) => (
      <div key={r.key} className="flex items-center gap-2 text-xs"><div className="w-56 shrink-0 truncate" title={label(r)}>{label(r)}</div>
        <div className="flex-1 h-3 rounded" style={{ background: C.grey }}><div className="h-full rounded" style={{ width: `${(Math.abs(r[metric]) / max) * 100}%`, background: C.blue }} /></div>
        <div className="w-24 text-right font-semibold">{F[m.fmt](r[metric])}</div></div>))}</div>);
}

export default function AdsMetaReports({ edge }) {
  const [opts, reloadOpts] = useLoad(() => rpc('api_ads_meta_report_options'), []);
  const today = opts?.today || iso(new Date());
  const [level, setLevel] = useState('campaign');
  const [datePreset, setDatePreset] = useState('last_30');
  const [range, setRange] = useState(null);
  const [compare, setCompare] = useState(false);
  const [breakdown, setBreakdown] = useState('');
  const [f, setF] = useState({ campaign_ids: [], adset_ids: [], ad_ids: [], statuses: [], name: '' });
  const [vf, setVf] = useState({});
  const [colPreset, setColPreset] = useState('performance');
  const [cols, setCols] = useState(PRESETS.performance.cols);
  const [customize, setCustomize] = useState(false);
  const [sort, setSort] = useState({ id: 'spend', dir: -1 });
  const [sel, setSel] = useState([]);
  const [chart, setChart] = useState(null);
  const [data, setData] = useState(null);
  const [crm, setCrm] = useState({});
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState('');
  const [limit, setLimit] = useState(200);
  const [viewName, setViewName] = useState('');
  const [viewId, setViewId] = useState(null);
  const [shared, setShared] = useState(false);
  const [from, to] = range || presetRange(datePreset, today) || [shift(today, -30), shift(today, -1)];

  const params = useMemo(() => ({ level, from, to, compare: compare ? 'previous' : null, breakdown: breakdown || null, ...f }), [level, from, to, compare, breakdown, f]);
  const load = async (force = false) => {
    if (!opts?.account) return;
    setLoading(true); setErr('');
    try {
      const r = await edge({ jobs: ['meta_report'], report: params, force });
      const rep = r?.results?.meta_report;
      if (!rep?.rows) throw new Error(rep?.detail || 'No answer from Meta');
      setData(rep); setLimit(200);
      setCrm(level !== 'account' && !breakdown ? await rpc('api_ads_meta_report_crm', { p_from: from, p_to: to, p_level: level }) : {});
    } catch (e) { setErr(e.message || String(e)); } finally { setLoading(false); }
  };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(false); }, [params, opts?.account?.id]);

  const dims = data?.rows?.length ? Object.keys(data.rows[0].dims || {}) : [];
  const dimValues = useMemo(() => Object.fromEntries(dims.map((d) => [d, [...new Set((data?.rows || []).map((r) => r.dims[d]))].sort()])), [data]); // eslint-disable-line
  const cmp = useMemo(() => new Map((data?.compare_rows || []).map((r) => [r.key, withDerived(r)])), [data]);
  const rows = useMemo(() => {
    const out = (data?.rows || []).filter((r) => dims.every((d) => !(vf[d] || []).length || vf[d].includes(r.dims[d])))
      .map((r) => { const c = (!breakdown && r.id && crm[r.id]) || {}; return withDerived({ ...r, crm: c.crm ?? (breakdown ? null : 0), qualified: c.qualified ?? (breakdown ? null : 0), customers: c.customers ?? (breakdown ? null : 0) }); });
    return out.sort((a, b) => {
      const x = a[sort.id], y = b[sort.id];
      if (sort.id === 'label') return String(a.label).localeCompare(String(b.label)) * sort.dir;
      if (num(x) === null) return 1; if (num(y) === null) return -1;
      return (x - y) * sort.dir;
    });
  }, [data, vf, crm, sort, breakdown]); // eslint-disable-line
  const filteredByValue = dims.some((d) => (vf[d] || []).length);
  const totals = useMemo(() => {
    if (!data) return null;
    const base = filteredByValue || !data.totals ? sumRows(rows, data.disjoint) : data.totals;
    const c = breakdown ? { crm: null, qualified: null, customers: null } : Object.values(crm).reduce((a, x) => ({ crm: a.crm + x.crm, qualified: a.qualified + x.qualified, customers: a.customers + x.customers }), { crm: 0, qualified: 0, customers: 0 });
    return withDerived({ ...base, ...c });
  }, [data, rows, crm, filteredByValue, breakdown]); // eslint-disable-line
  const ctot = data?.compare_totals ? withDerived(data.compare_totals) : null;

  const label = (r) => [level === 'account' ? 'Whole account' : r.label, ...dims.map((d) => r.dims[d])].join(' · ');
  const opt = (list) => (list || []).map((x) => ({ value: x.id, label: `${x.name || x.id}${x.status ? ` (${String(x.status).toLowerCase()})` : ''}` }));
  const adsetOpts = (opts?.adsets || []).filter((a) => !f.campaign_ids.length || f.campaign_ids.includes(a.campaign));
  const adOpts = (opts?.ads || []).filter((a) => (!f.campaign_ids.length || f.campaign_ids.includes(a.campaign)) && (!f.adset_ids.length || f.adset_ids.includes(a.adset)));

  const drill = () => {
    if (!sel.length) return;
    if (level === 'campaign') { setF({ ...f, campaign_ids: sel }); setLevel('adset'); }
    else if (level === 'adset') { setF({ ...f, adset_ids: sel }); setLevel('ad'); }
    setSel([]);
  };
  const exportCsv = () => {
    const head = ['Name', ...dims.map((d) => DIM_LABEL[d] || d), ...cols.map((c) => M[c].label)];
    const cell = (v) => { const s = String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
    const lines = [head, ...rows.map((r) => [level === 'account' ? 'Whole account' : r.label, ...dims.map((d) => r.dims[d]), ...cols.map((c) => (typeof r[c] === 'number' ? Math.round(r[c] * 100) / 100 : r[c] ?? ''))])];
    const url = URL.createObjectURL(new Blob([`﻿${lines.map((l) => l.map(cell).join(',')).join('\n')}`], { type: 'text/csv' }));
    Object.assign(document.createElement('a'), { href: url, download: `meta-report-${level}-${from}-${to}.csv` }).click();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  };
  const applyView = (v) => {
    const r = v.params?.report || {}, u = v.params?.ui || {};
    setLevel(r.level || 'campaign'); setBreakdown(r.breakdown || ''); setCompare(!!r.compare);
    setF({ campaign_ids: r.campaign_ids || [], adset_ids: r.adset_ids || [], ad_ids: r.ad_ids || [], statuses: r.statuses || [], name: r.name || '' });
    setDatePreset(u.datePreset || 'last_30'); setRange(u.datePreset === 'custom' ? [r.from, r.to] : null);
    setColPreset(u.colPreset || 'custom'); setCols(u.cols || PRESETS.performance.cols); setVf(u.vf || {}); setSort(u.sort || { id: 'spend', dir: -1 });
    setViewId(v.id); setViewName(v.name); setShared(!!v.shared);
  };
  const saveView = async (asNew) => {
    const name = viewName.trim();
    if (!name) { showToast('Give the view a name', 'error'); return; }
    const r = await run(rpc('api_ads_meta_report_view_save', { p_id: asNew ? null : viewId, p_name: name, p_shared: shared,
      p_params: { report: { ...params, compare: compare ? 'previous' : null }, ui: { datePreset, colPreset, cols, vf, sort } } }), 'View saved');
    if (r?.id) { setViewId(r.id); reloadOpts(); }
  };

  if (!opts) return <div className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</div>;
  if (!opts.account) return <div className="glass-card p-6 text-center text-sm">Connect the Meta ad account first (Meta Ads → Setup).</div>;
  const visibleCols = cols.filter((c) => M[c] && (level === 'ad' || !['quality', 'engagement', 'conversion'].includes(c)));

  return (
    <div className="space-y-3" data-testid="meta-reports">
      <style>{'@media print { nav, header, [role=tablist], .no-print { display: none !important } .glass-card { box-shadow: none !important } }'}</style>
      <section className="glass-card p-3 space-y-2 no-print">
        <div className="flex flex-wrap items-center gap-2">
          <div role="tablist" aria-label="Level" className="flex rounded-xl overflow-hidden" style={{ background: C.grey }}>
            {['campaign', 'adset', 'ad', 'account'].map((l) => (
              <button key={l} role="tab" aria-selected={level === l} onClick={() => { setLevel(l); setSel([]); }} className="px-3 py-1.5 text-sm font-semibold"
                style={level === l ? { background: C.blue, color: '#fff' } : {}}>{LEVEL[l]}</button>))}
          </div>
          <select aria-label="Date range" className="glass-input px-3 py-2 text-sm" value={datePreset} onChange={(e) => { setDatePreset(e.target.value); setRange(e.target.value === 'custom' ? [from, to] : null); }}>
            {DATE_PRESETS.map(([id, l]) => <option key={id} value={id}>{l}</option>)}</select>
          {datePreset === 'custom' && <>
            <input aria-label="From" type="date" className="glass-input px-2 py-1.5 text-sm" value={from} max={to} onChange={(e) => setRange([e.target.value, to])} />
            <input aria-label="To" type="date" className="glass-input px-2 py-1.5 text-sm" value={to} max={today} onChange={(e) => setRange([from, e.target.value])} /></>}
          <label className="text-sm flex items-center gap-1.5"><input type="checkbox" aria-label="Compare" checked={compare} onChange={(e) => setCompare(e.target.checked)} />Compare to previous period</label>
          <div className="flex-1" />
          <span className="text-xs text-glass-muted">{from} → {to}</span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Multi label="Campaigns" testid="f-campaigns" options={opt(opts.campaigns)} value={f.campaign_ids} onChange={(v) => setF({ ...f, campaign_ids: v, adset_ids: [], ad_ids: [] })} />
          <Multi label="Ad sets" testid="f-adsets" options={opt(adsetOpts)} value={f.adset_ids} onChange={(v) => setF({ ...f, adset_ids: v, ad_ids: [] })} />
          <Multi label="Ads" testid="f-ads" options={opt(adOpts)} value={f.ad_ids} onChange={(v) => setF({ ...f, ad_ids: v })} />
          <Multi label="Delivery" testid="f-status" options={STATUS_OPTS.map(([value, l]) => ({ value, label: l }))} value={f.statuses} onChange={(v) => setF({ ...f, statuses: v })} />
          <input aria-label="Name contains" className="glass-input px-3 py-2 text-sm w-40" placeholder="Name contains" defaultValue={f.name}
            onKeyDown={(e) => { if (e.key === 'Enter') setF({ ...f, name: e.currentTarget.value }); }} onBlur={(e) => e.target.value !== f.name && setF({ ...f, name: e.target.value })} />
          <select aria-label="Breakdown" className="glass-input px-3 py-2 text-sm" value={breakdown} onChange={(e) => { setBreakdown(e.target.value); setVf({}); }}>
            <option value="">Breakdown: none</option>
            {['Time', 'Demographics', 'Geography', 'Delivery'].map((g) => (
              <optgroup key={g} label={g}>{Object.entries(BREAKDOWNS).filter(([, b]) => b.group === g).map(([id, b]) => <option key={id} value={id}>{b.label}</option>)}</optgroup>))}
          </select>
          {dims.filter((d) => d !== 'period').map((d) => (
            <Multi key={d} label={DIM_LABEL[d] || d} testid={`vf-${d}`} options={(dimValues[d] || []).map((v) => ({ value: v, label: v }))} value={vf[d] || []}
              onChange={(v) => setVf({ ...vf, [d]: v })} />))}
          {(f.campaign_ids.length || f.adset_ids.length || f.ad_ids.length || f.statuses.length || f.name || breakdown) ? (
            <Btn ghost onClick={() => { setF({ campaign_ids: [], adset_ids: [], ad_ids: [], statuses: [], name: '' }); setBreakdown(''); setVf({}); }}>Clear filters</Btn>) : null}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <select aria-label="Columns" className="glass-input px-3 py-2 text-sm" value={colPreset} onChange={(e) => { setColPreset(e.target.value); if (PRESETS[e.target.value]) setCols(PRESETS[e.target.value].cols); }}>
            {Object.entries(PRESETS).map(([id, p]) => <option key={id} value={id}>Columns: {p.label}</option>)}<option value="custom">Columns: Custom</option></select>
          <Btn ghost onClick={() => setCustomize(!customize)}><Icon name="list" size={14} />Customize columns</Btn>
          <Btn ghost onClick={() => setChart(chart ? null : (visibleCols.find((c) => c !== 'spend') || 'spend'))}><Icon name="chart" size={14} />{chart ? 'Hide chart' : 'Chart'}</Btn>
          {sel.length > 0 && level !== 'ad' && level !== 'account' && <Btn onClick={drill} data-testid="drill">View {level === 'campaign' ? 'ad sets' : 'ads'} of {sel.length} selected</Btn>}
          <div className="flex-1" />
          <Btn ghost onClick={exportCsv} disabled={!rows.length}><Icon name="external" size={14} />Export CSV</Btn>
          <Btn ghost onClick={() => window.print()}>Print / PDF</Btn>
          <Btn ghost onClick={() => load(true)} disabled={loading}><Icon name="refresh" size={14} />Refresh</Btn>
        </div>
        {customize && <div className="rounded-xl p-3 grid sm:grid-cols-2 lg:grid-cols-4 gap-3" style={{ background: 'rgba(118,118,128,0.06)' }} data-testid="customize">
          {[...new Set(METRICS.map((m) => m.group))].map((g) => (
            <div key={g} className="space-y-0.5"><div className="text-xs font-semibold">{g}</div>
              {METRICS.filter((m) => m.group === g).map((m) => (
                <label key={m.id} className="flex items-center gap-1.5 text-xs"><input type="checkbox" checked={cols.includes(m.id)}
                  onChange={() => { setColPreset('custom'); setCols(cols.includes(m.id) ? cols.filter((x) => x !== m.id) : [...cols, m.id]); }} />{m.label}</label>))}
            </div>))}
          <div className="sm:col-span-2 lg:col-span-4 flex flex-wrap gap-1 text-xs">Order: {cols.map((c, i) => (
            <span key={c} className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full" style={{ background: C.grey }}>
              <button aria-label={`Move ${M[c]?.label} left`} disabled={!i} onClick={() => { const n = [...cols]; [n[i - 1], n[i]] = [n[i], n[i - 1]]; setCols(n); setColPreset('custom'); }}>‹</button>
              {M[c]?.label}
              <button aria-label={`Move ${M[c]?.label} right`} disabled={i === cols.length - 1} onClick={() => { const n = [...cols]; [n[i + 1], n[i]] = [n[i], n[i + 1]]; setCols(n); setColPreset('custom'); }}>›</button></span>))}</div>
        </div>}
        <div className="flex flex-wrap items-center gap-2 text-sm" data-testid="views">
          <select aria-label="Saved views" className="glass-input px-3 py-2 text-sm" value={viewId || ''} onChange={(e) => { const v = opts.views.find((x) => String(x.id) === e.target.value); if (v) applyView(v); }}>
            <option value="">Saved views…</option>{opts.views.map((v) => <option key={v.id} value={v.id}>{v.name}{v.shared ? ' (shared)' : ''}</option>)}</select>
          <input aria-label="View name" className="glass-input px-3 py-2 text-sm w-44" placeholder="View name" value={viewName} onChange={(e) => setViewName(e.target.value)} />
          {opts.can_admin && <label className="text-xs flex items-center gap-1"><input type="checkbox" checked={shared} onChange={(e) => setShared(e.target.checked)} />Share with everyone</label>}
          <Btn ghost onClick={() => saveView(!viewId)}>{viewId ? 'Update view' : 'Save view'}</Btn>
          {viewId && <Btn ghost onClick={() => saveView(true)}>Save as new</Btn>}
          {viewId && <Btn ghost onClick={() => run(rpc('api_ads_meta_report_view_delete', { p_id: viewId }).then(() => { setViewId(null); setViewName(''); reloadOpts(); }), 'View deleted')}>Delete view</Btn>}
        </div>
      </section>

      <div className="text-xs text-glass-muted flex flex-wrap gap-2" data-testid="report-source">
        <span>Live from Meta{data?.fetched_at ? ` · ${data.cached ? 'saved' : 'read'} ${new Date(data.fetched_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}` : ''}{data?.cached ? ' (press Refresh for the newest numbers)' : ''}</span>
        {(data?.notes || []).map((n) => <span key={n}>· {n}</span>)}
        {breakdown && <span>· CRM results are per campaign / ad set / ad, so they are not split by {(BREAKDOWNS[breakdown]?.label || '').toLowerCase()}.</span>}
      </div>
      {err && <div className="glass-card p-3 text-sm" style={{ color: C.red }}>{err}</div>}
      {loading && !data && <div className="glass-card p-6 text-center text-sm text-glass-muted">Reading from Meta…</div>}

      {data && totals && <section className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-6 gap-2" data-testid="report-totals">
        {visibleCols.filter((c) => M[c].fmt !== 'rank').slice(0, 6).map((c) => { const d = ctot ? delta(totals[c], ctot[c], M[c].low, M[c].neutral) : null; return (
          <div key={c} className="glass-card p-3"><div className="text-[11px] text-glass-muted">{M[c].label}</div><div className="text-lg font-bold">{F[M[c].fmt](totals[c])}</div>
            {d && <div className="text-[11px] font-semibold" style={{ color: dColor(d) }}>{d.p > 0 ? '▲' : '▼'} {Math.abs(d.p).toFixed(0)}% vs previous</div>}</div>); })}
      </section>}

      {chart && data && <section className="glass-card p-3 space-y-2"><div className="flex items-center gap-2 text-sm"><b>Chart</b>
        <select aria-label="Chart metric" className="glass-input px-2 py-1 text-sm" value={chart} onChange={(e) => setChart(e.target.value)}>
          {visibleCols.filter((c) => M[c].fmt !== 'rank').map((c) => <option key={c} value={c}>{M[c].label}</option>)}</select>
        <span className="text-xs text-glass-muted">top 15 rows</span></div><Bars rows={rows} metric={chart} label={label} /></section>}

      {data && <section className="glass-card overflow-x-auto" data-testid="report-table">
        <table className="w-full text-sm min-w-[720px]">
          <thead><tr className="text-left text-xs text-glass-muted border-b border-black/5">
            {level !== 'account' && level !== 'ad' && <th className="p-2 w-8 no-print" />}
            <th className="p-2 cursor-pointer" onClick={() => setSort({ id: 'label', dir: sort.id === 'label' ? -sort.dir : 1 })}>{LEVEL[level]}</th>
            {dims.map((d) => <th key={d} className="p-2">{DIM_LABEL[d] || d}</th>)}
            {visibleCols.map((c) => <th key={c} className="p-2 text-right cursor-pointer whitespace-nowrap" onClick={() => setSort({ id: c, dir: sort.id === c ? -sort.dir : -1 })}>
              {M[c].label}{sort.id === c ? (sort.dir < 0 ? ' ↓' : ' ↑') : ''}</th>)}
          </tr></thead>
          <tbody>
            {rows.slice(0, limit).map((r) => { const c = cmp.get(r.key); return (
              <tr key={r.key} className="border-b border-black/5 align-top">
                {level !== 'account' && level !== 'ad' && <td className="p-2 no-print"><input type="checkbox" aria-label={`Select ${r.label}`} checked={sel.includes(r.id)}
                  onChange={() => setSel(sel.includes(r.id) ? sel.filter((x) => x !== r.id) : [...sel, r.id])} /></td>}
                <td className="p-2 max-w-[260px]"><div className="truncate font-semibold" title={r.label}>{level === 'account' ? 'Whole account' : r.label}</div>
                  {level !== 'campaign' && r.campaign_name && level !== 'account' && <div className="text-[11px] text-glass-muted truncate">{r.campaign_name}{level === 'ad' && r.adset_name ? ` › ${r.adset_name}` : ''}</div>}</td>
                {dims.map((d) => <td key={d} className="p-2 whitespace-nowrap">{r.dims[d]}</td>)}
                {visibleCols.map((k) => { const dd = c && M[k].fmt !== 'rank' ? delta(r[k], c[k], M[k].low, M[k].neutral) : null; return (
                  <td key={k} className="p-2 text-right whitespace-nowrap">{F[M[k].fmt](r[k])}
                    {dd && <div className="text-[10px]" style={{ color: dColor(dd) }}>{dd.p > 0 ? '▲' : '▼'}{Math.abs(dd.p).toFixed(0)}%</div>}</td>); })}
              </tr>); })}
            {!rows.length && <tr><td colSpan={99} className="p-6 text-center text-glass-muted">No delivery in this period with these filters.</td></tr>}
          </tbody>
          {totals && rows.length > 0 && <tfoot><tr className="font-bold">
            {level !== 'account' && level !== 'ad' && <td className="no-print" />}
            <td className="p-2">Total ({rows.length} rows{filteredByValue ? ', filtered' : ''})</td>{dims.map((d) => <td key={d} />)}
            {visibleCols.map((k) => <td key={k} className="p-2 text-right whitespace-nowrap">{M[k].fmt === 'rank' ? '' : F[M[k].fmt](totals[k])}</td>)}</tr></tfoot>}
        </table>
        {rows.length > limit && <div className="p-2 text-center"><Btn ghost onClick={() => setLimit(limit + 200)}>Show more ({rows.length - limit} left)</Btn></div>}
        {data.truncated && <div className="p-2 text-xs text-glass-muted">Showing the first 5,000 rows; narrow the filters to see the rest.</div>}
      </section>}
    </div>);
}
