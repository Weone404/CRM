import { useState } from 'react';
import { rpc, run, useLoad, Btn } from './adsKit';

// CRM > Meta Ads > Reports > Lead quality (migration 106): which Meta leads turn into qualified leads and admissions,
// by form, campaign, ad, platform, any form answer, time to first call, weekday and hour; plus the lead score.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF', grey: 'rgba(118,118,128,0.12)' };
const BAND = { hot: C.red, warm: C.amber, cold: '#6B7280' };
const fmt = (v) => (v === null || v === undefined ? '–' : Math.round(Number(v)).toLocaleString('en-IN'));
const pct = (v) => (v === null || v === undefined ? '–' : `${Number(v).toFixed(1)}%`);
const iso = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const back = (n) => iso(new Date(Date.now() - n * 86400000));
const PERIODS = [[30, 'Last 30 days'], [90, 'Last 90 days'], [180, 'Last 6 months'], [365, 'Last 12 months'], [1095, 'Last 3 years']];
const DIMS = [['form', 'Lead form'], ['campaign', 'Campaign'], ['adset', 'Ad set'], ['ad', 'Ad'], ['platform', 'Facebook / Instagram'],
  ['speed', 'Time to first call'], ['weekday', 'Weekday'], ['hour', 'Hour of day']];

export function ScoreChip({ s }) {
  if (!s) return null;
  return (
    <span data-testid="score-chip" title={(s.reasons || []).map((r) => r.why).join('\n')} className="text-[11px] font-bold px-1.5 py-0.5 rounded-md whitespace-nowrap"
      style={{ color: '#fff', background: BAND[s.band] }}>{s.score} {s.band}</span>);
}

function Rules({ onSaved }) {
  const [s, reload] = useLoad(() => rpc('api_ads_lead_score_settings'), []);
  const [d, setD] = useState(null);
  if (!s) return null;
  const v = d ?? { rules: s.rules, hot: s.hot, warm: s.warm };
  const setRule = (i, k, x) => setD({ ...v, rules: v.rules.map((r, j) => (j === i ? { ...r, [k]: x } : r)) });
  return (
    <details className="glass-card p-3 text-sm" data-testid="score-rules">
      <summary className="cursor-pointer font-semibold">Lead score settings</summary>
      <p className="text-xs text-glass-muted mt-1">The score (0-100) learns from how past leads with the same form, campaign, ad, platform and answers turned out
        ({fmt(s.followed_leads_365d)} followed leads in the last year; it needs 20). Your rules add or take away points on top.</p>
      <div className="space-y-1.5 mt-2">
        {v.rules.map((r, i) => (
          <div key={i} className="flex flex-wrap items-center gap-1.5">
            <input aria-label={`Rule ${i + 1} field`} className="glass-input px-2 py-1 text-sm w-44" placeholder="answer:city or form" value={r.field} onChange={(e) => setRule(i, 'field', e.target.value)} />
            <select aria-label={`Rule ${i + 1} match`} className="glass-input px-2 py-1 text-sm" value={r.op} onChange={(e) => setRule(i, 'op', e.target.value)}>
              <option value="equals">equals</option><option value="contains">contains</option></select>
            <input aria-label={`Rule ${i + 1} value`} className="glass-input px-2 py-1 text-sm w-36" value={r.value} onChange={(e) => setRule(i, 'value', e.target.value)} />
            <input aria-label={`Rule ${i + 1} points`} type="number" min="-50" max="50" className="glass-input px-2 py-1 text-sm w-20" value={r.points} onChange={(e) => setRule(i, 'points', e.target.value)} />
            <span className="text-xs">points</span>
            <button className="text-xs text-red-600" onClick={() => setD({ ...v, rules: v.rules.filter((_, j) => j !== i) })}>Remove</button>
          </div>))}
        <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={() => setD({ ...v, rules: [...v.rules, { field: 'answer:', op: 'equals', value: '', points: 10 }] })}>+ Add rule</button>
      </div>
      <div className="flex flex-wrap items-end gap-2 mt-2">
        <label className="text-xs">Hot from<input aria-label="Hot from" type="number" className="glass-input px-2 py-1 text-sm w-20 block" value={v.hot} onChange={(e) => setD({ ...v, hot: e.target.value })} /></label>
        <label className="text-xs">Warm from<input aria-label="Warm from" type="number" className="glass-input px-2 py-1 text-sm w-20 block" value={v.warm} onChange={(e) => setD({ ...v, warm: e.target.value })} /></label>
        <Btn disabled={!d} onClick={() => run(rpc('api_ads_lead_score_save', { p_rules: v.rules.map((r) => ({ ...r, points: Number(r.points) })), p_hot: Number(v.hot), p_warm: Number(v.warm) })
          .then((r) => { setD(null); reload(); onSaved?.(); return r; }), 'Saved, recent leads rescored')}>Save and rescore</Btn>
      </div>
    </details>);
}

export default function AdsMetaQuality({ access }) {
  const [days, setDays] = useState(90);
  const [dim, setDim] = useState('form');
  const [q] = useLoad(() => rpc('api_ads_meta_lead_quality', { p_from: back(days), p_to: iso(new Date()), p_dim: dim }), [days, dim]);
  const [leads, reloadLeads] = useLoad(() => rpc('api_ads_meta_scored_leads', { p_days: 7 }), []);
  const keys = q?.answer_keys || [];
  const rows = q?.rows || [];
  const max = Math.max(1, ...rows.map((r) => Number(r.q_rate) || 0));
  return (
    <div className="space-y-3" data-testid="lead-quality">
      <section className="glass-card p-3 space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <select aria-label="Quality period" className="glass-input px-3 py-2 text-sm" value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {PERIODS.map(([n, l]) => <option key={n} value={n}>{l}</option>)}</select>
          <select aria-label="Group by" className="glass-input px-3 py-2 text-sm" value={dim} onChange={(e) => setDim(e.target.value)}>
            {DIMS.map(([id, l]) => <option key={id} value={id}>{l}</option>)}
            {keys.length > 0 && <optgroup label="Lead form answer">{keys.map((k) => <option key={k.key} value={`answer:${k.key}`}>{k.key}</option>)}</optgroup>}
          </select>
          <div className="flex-1" />
          {q && <span className="text-xs text-glass-muted">{fmt(q.totals.leads)} Meta leads · {fmt(q.totals.known)} followed in the CRM · {fmt(q.totals.qualified)} qualified · {fmt(q.totals.customers)} admissions</span>}
        </div>
        <p className="text-xs text-glass-muted">Meta counts form fills; this shows which ones became real students. Rates are out of the leads the CRM could follow. Grey rows have fewer than 10 leads, so read them as a hint.</p>
      </section>
      <section className="glass-card p-0 overflow-x-auto">
        {!q ? <div className="p-6 text-center text-sm text-glass-muted">Loading…</div> : rows.length === 0 ? <div className="p-6 text-center text-sm text-glass-muted">No Meta leads in this period yet.</div> : (
          <table className="w-full text-sm" data-testid="quality-table">
            <thead><tr className="text-left text-xs text-glass-muted">
              <th className="p-2">{(DIMS.find((x) => x[0] === dim) || [, dim.replace('answer:', '')])[1]}</th>
              <th className="p-2 text-right">Leads</th><th className="p-2 text-right">Followed</th><th className="p-2 text-right">Qualified</th>
              <th className="p-2 w-40">Qualified rate</th><th className="p-2 text-right">Admissions</th><th className="p-2 text-right">Admission rate</th><th className="p-2 text-right">Median first call</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.value} className="border-t border-black/5" style={r.small ? { opacity: 0.55 } : undefined}>
                <td className="p-2 font-medium">{String(r.value).replace(/^\d\. /, '')}</td>
                <td className="p-2 text-right">{fmt(r.leads)}</td><td className="p-2 text-right">{fmt(r.known)}</td><td className="p-2 text-right">{fmt(r.qualified)}</td>
                <td className="p-2"><div className="flex items-center gap-1.5"><div className="h-2 rounded-full" style={{ width: `${(Number(r.q_rate) || 0) / max * 90}px`, background: C.green }} /><span>{pct(r.q_rate)}</span></div></td>
                <td className="p-2 text-right">{fmt(r.customers)}</td><td className="p-2 text-right">{pct(r.c_rate)}</td>
                <td className="p-2 text-right">{r.median_first_call_min === null ? '–' : `${fmt(r.median_first_call_min)} min`}</td>
              </tr>))}</tbody>
          </table>)}
      </section>
      <section className="glass-card p-3 space-y-2" data-testid="scored-leads">
        <h3 className="font-bold">Lead score: last 7 days</h3>
        <p className="text-xs text-glass-muted">Leads not called yet come first, highest score first. Hover a score to see why.</p>
        {(leads || []).length === 0 ? <div className="text-sm text-glass-muted">No scored leads yet.</div> : (
          <div className="space-y-1">{leads.slice(0, 30).map((l) => (
            <div key={l.archive_id} className="flex items-center gap-2 text-sm">
              <ScoreChip s={l} />
              <span className="flex-1 truncate"><b>{l.name}</b> <span className="text-xs text-glass-muted">{l.form || l.campaign || ''}</span></span>
              <span className="text-xs" style={{ color: l.called ? C.green : C.amber }}>{l.called ? 'called' : 'not called'}</span>
            </div>))}</div>)}
      </section>
      {access?.is_admin && <Rules onSaved={reloadLeads} />}
    </div>);
}
