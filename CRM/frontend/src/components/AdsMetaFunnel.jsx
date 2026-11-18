import { useState } from 'react';
import { rpc, run, useLoad, Btn } from './adsKit';
import { showToast } from '../utils/toast';

// CRM > Meta Ads > Funnel (migration 107): the funnel map, the audience library kept in Meta, and where to aim location.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF', grey: 'rgba(118,118,128,0.12)' };
const fmt = (v) => (v === null || v === undefined ? '–' : Math.round(Number(v)).toLocaleString('en-IN'));
const inr = (v) => (v === null || v === undefined ? '–' : `₹${Number(v).toLocaleString('en-IN', { maximumFractionDigits: Number(v) < 100 ? 2 : 0 })}`);
const pct = (v) => (v === null || v === undefined ? '–' : `${Number(v) < 1 ? Number(v).toFixed(2) : Number(v).toFixed(1)}%`);
const iso = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const back = (n) => iso(new Date(Date.now() - n * 86400000));
const PERIODS = [[30, 'Last 30 days'], [90, 'Last 90 days'], [180, 'Last 6 months'], [365, 'Last 12 months']];
const STAGE = { hot: ['Hot', C.red], engaged: ['Warm', C.amber], lead: ['Lead', C.blue], qualified: ['Qualified', C.green], customer: ['Admission', '#6B21A8'] };
const USE = { retarget: 'Retarget', exclude: 'Exclude', seed: 'Lookalike seed', reengage: 'Re-engage' };
const VERDICT = { focus: [C.green, 'Focus'], keep: ['#6B7280', 'Keep'], reduce: [C.amber, 'Reduce'], cut: [C.red, 'Cut'], 'too few leads': ['#9CA3AF', 'Too few leads'] };
const size = (a) => (a.size_high ? (a.size_low && a.size_low !== a.size_high ? `${fmt(a.size_low)}-${fmt(a.size_high)}` : fmt(a.size_high)) : '–');

function FunnelMap({ days }) {
  const [f] = useLoad(() => rpc('api_ads_meta_funnel', { p_from: back(days), p_to: iso(new Date()) }), [days]);
  if (!f) return <section className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</section>;
  const max = Math.max(1, ...f.stages.map((s) => Number(s.n) || 0));
  return (
    <section className="glass-card p-4 space-y-3" data-testid="funnel-map">
      <div className="flex flex-wrap items-baseline gap-2">
        <h3 className="font-bold flex-1">Funnel map</h3>
        <span className="text-xs text-glass-muted">Spend {inr(f.spend)} · median first call {f.first_call_min === null ? '–' : `${fmt(f.first_call_min)} min`} · lead to qualified {f.qualify_days === null ? '–' : `${f.qualify_days} days`}</span>
      </div>
      <div className="space-y-1.5">
        {f.stages.map((s) => (
          <div key={s.key} className="grid grid-cols-[7.5rem_1fr_auto] sm:grid-cols-[9rem_1fr_7rem_6rem] items-center gap-2 text-sm" data-testid={`stage-${s.key}`}>
            <span className="font-medium">{s.label}</span>
            <div className="h-5 rounded-md overflow-hidden" style={{ background: C.grey }}>
              <div className="h-full rounded-md" style={{ width: `${Math.max(Number(s.n) ? 1.5 : 0, (Math.log10((Number(s.n) || 0) + 1) / Math.log10(max + 1)) * 100)}%`, background: C.blue }} />
            </div>
            <span className="text-right font-semibold">{fmt(s.n)}{s.from_prev !== null && s.from_prev !== undefined && <span className="text-xs text-glass-muted font-normal"> · {pct(s.from_prev)}</span>}</span>
            <span className="hidden sm:block text-right text-xs text-glass-muted">{s.cost ? `${inr(s.cost)} each` : ''}</span>
          </div>))}
      </div>
      <p className="text-[11px] text-glass-muted">Bars use a log scale so the small stages stay visible. % is how many of the stage above moved on. "Became a lead" counts Meta leads that reached the CRM{f.stages[2]?.meta_count ? ` (Meta counted ${fmt(f.stages[2].meta_count)})` : ''}.</p>
      {f.warm.length > 0 && <div className="flex flex-wrap gap-1.5">{f.warm.map((a) => (
        <span key={a.key} className="text-xs px-2 py-1 rounded-lg" style={{ background: C.grey }}>
          <b style={{ color: STAGE[a.stage]?.[1] }}>{STAGE[a.stage]?.[0]}</b> {a.name}: {a.status === 'ready' ? size(a) : 'not in Meta yet'}</span>))}</div>}
      {f.notes.length > 0 && <ul className="text-sm space-y-1" data-testid="funnel-notes">{f.notes.map((n) => <li key={n} className="flex gap-2"><span style={{ color: C.amber }}>●</span><span>{n}</span></li>)}</ul>}
    </section>);
}

function Audiences({ access, edge }) {
  const [a, reload] = useLoad(() => rpc('api_ads_meta_audiences'), []);
  const [busy, setBusy] = useState(false);
  if (!a) return null;
  const admin = access?.is_admin;
  const sync = async () => {
    setBusy(true);
    const r = await edge({ jobs: ['meta_audiences'] }).catch((e) => ({ error: e.message }));
    const res = r?.results?.meta_audiences;
    showToast(res?.detail || r?.error || 'Done', res?.status === 'error' || r?.error ? 'error' : 'success');
    setBusy(false); reload();
  };
  return (
    <section className="glass-card p-4 space-y-3" data-testid="audience-library">
      <div className="flex flex-wrap items-start gap-2">
        <div className="flex-1 min-w-[14rem]"><h3 className="font-bold">Audience library</h3>
          <p className="text-xs text-glass-muted">Kept in Meta and refreshed every night. Meta treats only location, minimum age, languages and these exclusions as hard limits; everything else is a hint, so exclusions are the main control. CRM lists are sent hashed, and only people whose consent rule allows it.</p></div>
        {admin && <label className="text-sm flex items-center gap-1.5 font-semibold"><input type="checkbox" aria-label="Keep audiences in Meta" checked={a.on}
          onChange={(e) => run(rpc('api_ads_meta_audiences_on', { p_on: e.target.checked }).then(reload), e.target.checked ? 'Audiences on' : 'Audiences off')} />Keep audiences in Meta</label>}
        {(admin || access?.can_approve) && a.on && <Btn ghost disabled={busy} onClick={sync}>{busy ? 'Updating…' : 'Update now'}</Btn>}
      </div>
      {a.last?.at && <div className="text-xs text-glass-muted">Last update {new Date(a.last.at).toLocaleString('en-IN')}: {a.last.ok ?? 0} up to date{a.last.errors ? `, ${a.last.errors} with a problem` : ''}{a.last.detail ? `. ${a.last.detail}` : ''}</div>}
      <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="audience-table">
        <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">Audience</th><th className="p-2">Stage</th><th className="p-2">Use</th>
          <th className="p-2 text-right">Size in Meta</th><th className="p-2">Status</th>{admin && <th className="p-2">On</th>}<th className="p-2" title="Kept out of new-people ad sets the Strategy builds">Exclude from new-people ads</th></tr></thead>
        <tbody>{a.audiences.map((x) => (
          <tr key={x.key} className="border-t border-black/5 align-top" style={x.enabled ? undefined : { opacity: 0.5 }}>
            <td className="p-2"><div className="font-medium">{x.name}</div><div className="text-[11px] text-glass-muted">{x.why}</div>
              {x.kind === 'crm' && <div className="text-[11px] text-glass-muted">{fmt(x.eligible)} people can be sent{x.members !== null && x.members !== undefined ? ` · ${fmt(x.members)} sent last time` : ''}</div>}</td>
            <td className="p-2 whitespace-nowrap"><b style={{ color: STAGE[x.stage]?.[1] }}>{STAGE[x.stage]?.[0]}</b></td>
            <td className="p-2 whitespace-nowrap">{USE[x.use_as]}</td>
            <td className="p-2 text-right whitespace-nowrap">{x.status === 'ready' ? size(x) : '–'}</td>
            <td className="p-2 text-xs"><span style={{ color: x.status === 'ready' ? C.green : x.status === 'error' ? C.red : '#6B7280' }}>{x.status === 'planned' ? 'not in Meta yet' : x.status}</span>
              {x.detail && <div className="text-[11px] text-glass-muted max-w-[16rem] break-words">{x.detail}</div>}</td>
            {admin && <td className="p-2"><input type="checkbox" aria-label={`Use ${x.name}`} checked={x.enabled}
              onChange={(e) => run(rpc('api_ads_meta_audience_save', { p_key: x.key, p_enabled: e.target.checked, p_exclude_default: null }).then(reload), 'Saved')} /></td>}
            <td className="p-2"><input type="checkbox" aria-label={`Exclude ${x.name} from new-people ads`} checked={x.exclude_default} disabled={!admin}
              onChange={(e) => run(rpc('api_ads_meta_audience_save', { p_key: x.key, p_enabled: null, p_exclude_default: e.target.checked }).then(reload), 'Saved')} /></td>
          </tr>))}</tbody></table></div>
      {!a.on && <p className="text-xs text-glass-muted">{admin ? 'Turn on "Keep audiences in Meta" to create these audiences in the ad account (Meta may first ask you to accept its Custom Audience terms; the CRM shows the link).' : 'Admin can turn audiences on.'}</p>}
    </section>);
}

function Locations({ days }) {
  const [g] = useLoad(() => rpc('api_ads_meta_geo', { p_from: back(days), p_to: iso(new Date()) }), [days]);
  if (!g) return null;
  return (
    <section className="glass-card p-4 space-y-3" data-testid="location-focus">
      <h3 className="font-bold">Location focus</h3>
      <p className="text-xs text-glass-muted">{g.tip} Average qualified rate {g.avg_q_rate === null ? '–' : `${g.avg_q_rate}%`}.{g.unknown_location ? ` ${fmt(g.unknown_location)} lead(s) gave no city or state: add a City or State question to the form.` : ''}</p>
      {g.regions.length === 0 ? <div className="text-sm text-glass-muted">No location data yet.</div> : (
        <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="region-table">
          <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">State</th><th className="p-2 text-right">Spend</th><th className="p-2 text-right">Meta leads</th>
            <th className="p-2 text-right">Cost per lead</th><th className="p-2 text-right">Qualified</th><th className="p-2 text-right">Admissions</th><th className="p-2 text-right">Qualified rate</th>
            <th className="p-2 text-right">Cost per qualified</th><th className="p-2">Verdict</th></tr></thead>
          <tbody>{g.regions.map((r) => (
            <tr key={r.region} className="border-t border-black/5">
              <td className="p-2 font-medium">{r.region}</td><td className="p-2 text-right">{inr(r.spend)}</td><td className="p-2 text-right">{fmt(r.meta_leads)}</td>
              <td className="p-2 text-right">{inr(r.cpl)}</td><td className="p-2 text-right">{fmt(r.qualified)}</td><td className="p-2 text-right">{fmt(r.customers)}</td>
              <td className="p-2 text-right">{pct(r.q_rate)}</td><td className="p-2 text-right">{inr(r.cost_per_qualified)}</td>
              <td className="p-2"><b style={{ color: VERDICT[r.verdict]?.[0] }}>{VERDICT[r.verdict]?.[1]}</b></td></tr>))}</tbody></table></div>)}
      {g.cities.length > 0 && <details className="text-sm"><summary className="cursor-pointer text-xs font-semibold">Cities ({g.cities.length})</summary>
        <div className="flex flex-wrap gap-1.5 mt-2">{g.cities.map((c) => (
          <span key={c.city} className="text-xs px-2 py-1 rounded-lg" style={{ background: C.grey, opacity: c.small ? 0.6 : 1 }}>{c.city}: {fmt(c.leads)} leads · {pct(c.q_rate)} qualified</span>))}</div></details>}
    </section>);
}

export default function AdsMetaFunnel({ access, edge }) {
  const [days, setDays] = useState(90);
  return (
    <div className="space-y-3" data-testid="meta-funnel">
      <div className="flex items-center gap-2">
        <select aria-label="Funnel period" className="glass-input px-3 py-2 text-sm" value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {PERIODS.map(([n, l]) => <option key={n} value={n}>{l}</option>)}</select>
        <span className="text-xs text-glass-muted">Funnel targeting: find new people broadly, bring warm and hot people back with their own message, keep paying customers and fresh leads out.</span>
      </div>
      <FunnelMap days={days} />
      <Audiences access={access} edge={edge} />
      <Locations days={days} />
    </div>);
}
