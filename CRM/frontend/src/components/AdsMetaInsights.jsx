import { useMemo, useState } from 'react';
import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';
import { todayIn } from '../utils/ads';
import { findPatterns, whatIf, inr, costPer, GOAL_LABEL } from '../../../supabase/functions/_shared/meta_patterns.ts';

// CRM > Meta Ads > Insights: the account's history as a visual dashboard (read-only; migration 103).
// Numbers: api_ads_meta_insights. Patterns and what-if: meta_patterns.ts (the same code writes the monthly summary).

const PERIODS = [['30', 'Last 30 days'], ['90', 'Last 90 days'], ['182', 'Last 6 months'], ['365', 'Last 12 months'], ['1125', 'All history (37 months)']];
const C = { blue: '#0088FF', green: '#1E9E4A', red: '#D93025', amber: '#B25E00', grey: 'rgba(118,118,128,0.35)', ink: '#1C1C1E' };
const N = (v) => Number(v) || 0;
const fmt = (v) => Math.round(N(v)).toLocaleString('en-IN');
const addDays = (s, n) => new Date(Date.parse(`${s}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
const tone = (ratio) => (ratio === null ? C.grey : ratio <= 0.8 ? C.green : ratio >= 1.4 ? C.red : C.amber);
const short = (d) => (d ? new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: '2-digit', timeZone: 'UTC' }) : '–');

function Card({ title, sub, children, testid, right }) {
  return (
    <section className="glass-card p-4 space-y-3 break-inside-avoid" data-testid={testid}>
      {(title || right) && <div className="flex items-start gap-2"><div className="flex-1"><h3 className="font-bold text-glass-primary">{title}</h3>
        {sub && <div className="text-xs text-glass-muted">{sub}</div>}</div>{right}</div>}
      {children}
    </section>
  );
}

function Tiles({ d, goal }) {
  const c = d.current, p = d.previous;
  const t = [
    ['Spend', c.spend, p.spend, inr, false], ['Meta leads', c.meta_leads, p.meta_leads, fmt, true],
    ['Leads in CRM', c.crm_leads, p.crm_leads, fmt, true], ['Qualified', c.qualified, p.qualified, fmt, true],
    ['Admissions', c.customers, p.customers, fmt, true],
    ['Cost per lead', costPer(N(c.spend), N(c.meta_leads)), costPer(N(p.spend), N(p.meta_leads)), inr, false],
    ['Cost per qualified', costPer(N(c.spend), N(c.qualified)), costPer(N(p.spend), N(p.qualified)), inr, false],
    ['Cost per admission', costPer(N(c.spend), N(c.customers)), costPer(N(p.spend), N(p.customers)), inr, false],
  ];
  return (
    <div className="grid grid-cols-2 sm:grid-cols-4 gap-2" data-testid="insights-tiles">
      {t.map(([label, v, pv, f, upGood]) => {
        const ch = v !== null && pv ? (N(v) - N(pv)) / N(pv) : null;
        const good = ch === null ? null : label === 'Spend' ? null : (upGood ? ch >= 0 : ch <= 0);
        return (
          <div key={label} className="glass-card p-3">
            <div className="text-[11px] text-glass-muted">{label}{label === { customers: 'Cost per admission', qualified: 'Cost per qualified', meta_leads: 'Cost per lead' }[goal] ? ' ★ judged on' : ''}</div>
            <div className="text-xl font-bold text-glass-primary">{v === null ? '–' : f(v)}</div>
            {ch !== null && <div className="text-[11px]" style={{ color: good === null ? C.ink : good ? C.green : C.red }}>
              {ch >= 0 ? '▲' : '▼'} {Math.abs(Math.round(ch * 100))}% vs previous</div>}
          </div>);
      })}
    </div>
  );
}

function Funnel({ c }) {
  const steps = [['People saw ads (impressions)', c.impressions], ['Clicked', c.clicks], ['Meta leads', c.meta_leads],
    ['Leads in CRM', c.crm_leads], ['Qualified', c.qualified], ['Admitted', c.customers]];
  const max = Math.log10(Math.max(10, ...steps.map((s) => N(s[1]))));
  return (
    <Card title="Funnel" sub="Where people drop off (bar length on a log scale)" testid="insights-funnel">
      <div className="space-y-1.5">
        {steps.map(([label, v], i) => {
          const prev = i ? N(steps[i - 1][1]) : null;
          return (
            <div key={label} className="flex items-center gap-2 text-sm">
              <div className="w-44 shrink-0 text-glass-secondary">{label}</div>
              <div className="flex-1 h-5 rounded-md overflow-hidden" style={{ background: 'rgba(118,118,128,0.10)' }}>
                <div className="h-full rounded-md" style={{ width: `${N(v) > 0 ? Math.max(3, (Math.log10(N(v) + 1) / max) * 100) : 0}%`, background: C.blue, opacity: 1 - i * 0.12 }} /></div>
              <div className="w-24 text-right font-semibold">{fmt(v)}</div>
              <div className="w-16 text-right text-[11px] text-glass-muted">{prev ? `${((N(v) / prev) * 100).toFixed(N(v) / prev < 0.1 ? 1 : 0)}%` : ''}</div>
            </div>);
        })}
      </div>
    </Card>
  );
}

function Trend({ d, goal }) {
  const rows = d.trend || [];
  const [hover, setHover] = useState(null);
  if (!rows.length) return null;
  const W = 760, H = 220, P = 34, bw = Math.max(2, (W - 2 * P) / rows.length - 2);
  const maxS = Math.max(1, ...rows.map((r) => N(r.spend)));
  const costs = rows.map((r) => costPer(N(r.spend), N(r[goal])));
  const maxC = Math.max(1, ...costs.filter((x) => x !== null));
  const x = (i) => P + i * ((W - 2 * P) / rows.length);
  const pts = costs.map((c, i) => (c === null ? null : `${x(i) + bw / 2},${H - P - (c / maxC) * (H - 2 * P)}`)).filter(Boolean);
  const wk = (day) => rows.findIndex((r, i) => day >= r.week && (i === rows.length - 1 || day < rows[i + 1].week));
  const h = hover !== null ? rows[hover] : null;
  return (
    <Card title="Week by week" sub={`Bars: spend. Line: cost per ${GOAL_LABEL[goal].one}. Flags: your notes.`} testid="insights-trend">
      <svg viewBox={`0 0 ${W} ${H}`} className="w-full h-auto" role="img" aria-label="Weekly spend and cost">
        {rows.map((r, i) => <rect key={r.week} x={x(i)} y={H - P - (N(r.spend) / maxS) * (H - 2 * P)} width={bw} height={(N(r.spend) / maxS) * (H - 2 * P)}
          fill={hover === i ? C.blue : 'rgba(0,136,255,0.35)'} onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)} />)}
        {pts.length > 1 && <polyline points={pts.join(' ')} fill="none" stroke={C.amber} strokeWidth="2.5" />}
        {(d.notes || []).map((n) => { const i = wk(n.day); return i < 0 ? null : (
          <g key={n.id}><line x1={x(i) + bw / 2} x2={x(i) + bw / 2} y1={P - 6} y2={H - P} stroke={C.red} strokeDasharray="3 3" />
            <circle cx={x(i) + bw / 2} cy={P - 8} r="4" fill={C.red}><title>{`${short(n.day)}: ${n.text}`}</title></circle></g>); })}
        <text x={P} y={H - 8} fontSize="11" fill="#888">{short(rows[0].week)}</text>
        <text x={W - P} y={H - 8} fontSize="11" fill="#888" textAnchor="end">{short(rows[rows.length - 1].week)}</text>
        <text x={4} y={P} fontSize="11" fill="#888">{inr(maxS)}</text>
      </svg>
      <div className="text-xs text-glass-secondary min-h-[1rem]">{h ? `Week of ${short(h.week)}: ${inr(h.spend)} spent · ${fmt(h.meta_leads)} Meta leads · ${fmt(h.crm_leads)} in CRM · ${fmt(h.qualified)} qualified · ${fmt(h.customers)} admitted` : 'Hover a bar for the week.'}</div>
    </Card>
  );
}

function Badge({ proven }) {
  return <span className="text-[10px] font-semibold px-1.5 py-0.5 rounded-full" style={{ background: proven ? 'rgba(30,158,74,0.14)' : 'rgba(178,94,0,0.14)', color: proven ? C.green : C.amber }}>{proven ? 'Proven' : 'Early'}</span>;
}

function Board({ d, goal, baseline }) {
  const [lvl, setLvl] = useState('campaign');
  const PROVEN = { customers: 4, qualified: 8, meta_leads: 20 };
  const rows = (d.board?.[lvl] || []).filter((r) => N(r.spend) > 0).map((r) => ({ ...r, cost: costPer(N(r.spend), N(r[goal])) }))
    .sort((a, b) => (a.cost ?? Infinity) - (b.cost ?? Infinity) || N(b.spend) - N(a.spend));
  return (
    <Card title="Leaderboard" sub={`Ranked by cost per ${GOAL_LABEL[goal].one} (average ${inr(baseline)})`} testid="insights-board"
      right={<div className="flex gap-1">{[['campaign', 'Campaigns'], ['adset', 'Ad sets'], ['ad', 'Ads']].map(([k, l]) =>
        <button key={k} type="button" onClick={() => setLvl(k)} className="text-xs px-2 py-1 rounded-lg" style={lvl === k ? { background: C.blue, color: '#fff' } : { background: 'rgba(118,118,128,0.12)' }}>{l}</button>)}</div>}>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-[11px] text-glass-muted">{['Name', 'Spend', 'Meta leads', 'CRM', 'Qualified', 'Admitted', `Per ${GOAL_LABEL[goal].one}`, ''].map((h) => <th key={h} className="py-1 pr-3 font-medium whitespace-nowrap">{h}</th>)}</tr></thead>
          <tbody>
            {rows.slice(0, 25).map((r) => {
              const ratio = r.cost !== null && baseline ? r.cost / baseline : null;
              return (
                <tr key={r.ext} className="border-t border-black/5">
                  <td className="py-1.5 pr-3 max-w-[16rem] truncate" title={r.name}>{r.name}{r.status && r.status !== 'ACTIVE' ? <span className="text-[10px] text-glass-muted"> · {String(r.status).toLowerCase()}</span> : null}</td>
                  <td className="pr-3">{inr(r.spend)}</td><td className="pr-3">{fmt(r.meta_leads)}</td><td className="pr-3">{fmt(r.crm_leads)}</td>
                  <td className="pr-3">{fmt(r.qualified)}</td><td className="pr-3">{fmt(r.customers)}</td>
                  <td className="pr-3 font-semibold" style={{ color: tone(ratio) }}>{inr(r.cost)}</td>
                  <td>{(N(r[goal]) >= PROVEN[goal] && baseline && N(r.spend) >= 2 * baseline) ? <Badge proven /> : <Badge />}</td>
                </tr>);
            })}
            {!rows.length && <tr><td colSpan={8} className="py-4 text-center text-glass-muted">No spend in this period.</td></tr>}
          </tbody>
        </table>
      </div>
    </Card>
  );
}

function AdCard({ r, goal, baseline }) {
  const i = r.info || {};
  const ratio = r.cost !== null && baseline ? r.cost / baseline : null;
  const [broken, setBroken] = useState(false);
  return (
    <div className="glass-card p-2 flex gap-3">
      <div className="w-20 h-20 shrink-0 rounded-lg overflow-hidden flex items-center justify-center" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {i.thumbnail_url && !broken ? <img src={i.thumbnail_url} alt="" loading="lazy" referrerPolicy="no-referrer" className="w-full h-full object-cover" onError={() => setBroken(true)} /> : <Icon name="image" size={22} />}
      </div>
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold truncate" title={r.name}>{r.name}</div>
        <div className="text-[11px] text-glass-muted">{[i.format, i.cta && String(i.cta).replace(/_/g, ' ').toLowerCase()].filter(Boolean).join(' · ')}</div>
        {(i.title || i.body) && <div className="text-xs text-glass-secondary line-clamp-2">{i.title ? <b>{i.title} </b> : null}{i.body}</div>}
        <div className="text-xs mt-0.5"><b style={{ color: tone(ratio) }}>{r.cost === null ? `${inr(r.spend)}, no ${GOAL_LABEL[goal].many}` : `${inr(r.cost)} per ${GOAL_LABEL[goal].one}`}</b>
          <span className="text-glass-muted"> · {inr(r.spend)} spent · {fmt(r[goal])} {GOAL_LABEL[goal].many}</span></div>
      </div>
    </div>
  );
}

function Gallery({ d, goal, baseline }) {
  const ads = (d.board?.ad || []).filter((r) => N(r.spend) > 0).map((r) => ({ ...r, cost: costPer(N(r.spend), N(r[goal])) }));
  const best = ads.filter((r) => r.cost !== null).sort((a, b) => a.cost - b.cost).slice(0, 4);
  const worst = ads.filter((r) => !best.includes(r) && (r.cost === null || (baseline && r.cost > baseline)))
    .sort((a, b) => (b.cost ?? b.spend * 10) - (a.cost ?? a.spend * 10)).slice(0, 4);
  if (!ads.length) return null;
  return (
    <Card title="Creatives" sub="Best and worst ads by cost per result, with what they said" testid="insights-gallery">
      <div className="grid md:grid-cols-2 gap-4">
        <div className="space-y-2"><div className="text-xs font-semibold" style={{ color: C.green }}>Best</div>{best.map((r) => <AdCard key={r.ext} r={r} goal={goal} baseline={baseline} />)}</div>
        <div className="space-y-2"><div className="text-xs font-semibold" style={{ color: C.red }}>Worst</div>{worst.length ? worst.map((r) => <AdCard key={r.ext} r={r} goal={goal} baseline={baseline} />) : <div className="text-xs text-glass-muted">No clear losers.</div>}</div>
      </div>
    </Card>
  );
}

function Bars({ rows, label, base }) {
  const max = Math.max(1, ...rows.map((r) => N(r.spend)));
  return (
    <div className="space-y-1">
      {rows.map((r) => { const cpl = costPer(N(r.spend), N(r.leads)); const ratio = cpl !== null && base ? cpl / base : null; return (
        <div key={label(r)} className="flex items-center gap-2 text-xs">
          <div className="w-32 shrink-0 truncate" title={label(r)}>{label(r)}</div>
          <div className="flex-1 h-3.5 rounded" style={{ background: 'rgba(118,118,128,0.10)' }}><div className="h-full rounded" style={{ width: `${(N(r.spend) / max) * 100}%`, background: tone(ratio) }} /></div>
          <div className="w-28 text-right"><b>{inr(cpl)}</b><span className="text-glass-muted">/lead</span></div>
        </div>); })}
    </div>
  );
}

function Audience({ d }) {
  const b = d.breakdowns || {};
  const all = b.age_gender || [];
  const base = costPer(all.reduce((s, r) => s + N(r.spend), 0), all.reduce((s, r) => s + N(r.leads), 0));
  const ages = [...new Set(all.map((r) => r.k1))].sort();
  const genders = ['male', 'female', 'unknown'].filter((g) => all.some((r) => r.k2 === g));
  const cell = (a, g) => all.find((r) => r.k1 === a && r.k2 === g);
  const DOW = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const hours = Array.from({ length: 24 }, (_, h) => (b.hour || []).find((r) => Number(r.k1) === h) || { k1: String(h), spend: 0, leads: 0 });
  const maxH = Math.max(1, ...hours.map((r) => N(r.leads)));
  const m = d.breakdown_months;
  if (!all.length && !(d.weekday || []).length) return null;
  return (
    <Card title="Who and when" sub={`Whole account, Meta-counted leads, colour = cost per lead vs average ${inr(base)}${m?.from ? ` · ${short(m.from)} – ${short(m.to)}` : ''}`} testid="insights-audience">
      <div className="grid lg:grid-cols-2 gap-5">
        {!!all.length && <div><div className="text-xs font-semibold mb-1">Age × gender</div>
          <table className="text-xs"><thead><tr><th />{genders.map((g) => <th key={g} className="px-2 font-medium capitalize">{g}</th>)}</tr></thead>
            <tbody>{ages.map((a) => <tr key={a}><td className="pr-2 py-0.5">{a}</td>{genders.map((g) => { const r = cell(a, g); const cpl = r ? costPer(N(r.spend), N(r.leads)) : null; return (
              <td key={g} className="px-1 py-0.5"><div className="rounded-md px-2 py-1 text-center text-white font-semibold min-w-[5rem]" style={{ background: r ? tone(cpl !== null && base ? cpl / base : null) : 'transparent', color: r ? '#fff' : '#999' }}
                title={r ? `${inr(r.spend)} · ${fmt(r.leads)} leads` : ''}>{r ? (cpl === null ? '0 leads' : inr(cpl)) : '–'}</div></td>); })}</tr>)}</tbody></table></div>}
        {!!(b.region || []).length && <div><div className="text-xs font-semibold mb-1">Regions</div><Bars rows={(b.region || []).slice(0, 8)} label={(r) => r.k1} base={base} /></div>}
        {!!(b.placement || []).length && <div><div className="text-xs font-semibold mb-1">Placements</div><Bars rows={(b.placement || []).slice(0, 8)} label={(r) => `${r.k1} ${String(r.k2).replace(/_/g, ' ')}`} base={base} /></div>}
        {!!(b.device || []).length && <div><div className="text-xs font-semibold mb-1">Devices</div><Bars rows={b.device} label={(r) => r.k1} base={base} /></div>}
        {!!(d.weekday || []).length && <div><div className="text-xs font-semibold mb-1">Weekday</div>
          <Bars rows={d.weekday.map((r) => ({ ...r, leads: r.meta_leads }))} label={(r) => DOW[r.dow]} base={base || costPer(N(d.current.spend), N(d.current.meta_leads))} /></div>}
        {!!(b.hour || []).length && <div><div className="text-xs font-semibold mb-1">Hour of day (leads)</div>
          <div className="flex items-end gap-[2px] h-24">{hours.map((r) => { const cpl = costPer(N(r.spend), N(r.leads)); return (
            <div key={r.k1} className="flex-1 rounded-t" title={`${r.k1}:00 · ${fmt(r.leads)} leads · ${inr(cpl)}/lead`}
              style={{ height: `${Math.max(2, (N(r.leads) / maxH) * 100)}%`, background: tone(cpl !== null && base ? cpl / base : null) }} />); })}</div>
          <div className="flex justify-between text-[10px] text-glass-muted"><span>12 am</span><span>6 am</span><span>12 pm</span><span>6 pm</span><span>11 pm</span></div></div>}
      </div>
    </Card>
  );
}

function Fatigue({ d }) {
  const f = (d.fatigue || []).filter((w) => N(w.ads) >= 2);
  const fr = (d.breakdowns || {}).frequency || [];
  if (f.length < 2 && !fr.length) return null;
  const W = 360, H = 140, P = 24, maxI = Math.max(1.2, ...f.map((w) => N(w.ctr_index)));
  const x = (i) => P + (i * (W - 2 * P)) / Math.max(1, f.length - 1);
  const y = (v) => H - P - (v / maxI) * (H - 2 * P);
  const base = costPer(fr.reduce((s, r) => s + N(r.spend), 0), fr.reduce((s, r) => s + N(r.leads), 0));
  return (
    <Card title="Ad fatigue" sub="Click rate by week of an ad's life (1 = its first week) and cost by how often people saw your ads" testid="insights-fatigue">
      <div className="grid md:grid-cols-2 gap-4">
        {f.length >= 2 && <svg viewBox={`0 0 ${W} ${H}`} className="w-full h-auto" role="img" aria-label="Click rate by week of an ad's life">
          <line x1={P} x2={W - P} y1={y(1)} y2={y(1)} stroke="#ccc" strokeDasharray="4 4" />
          <polyline points={f.map((w, i) => `${x(i)},${y(N(w.ctr_index))}`).join(' ')} fill="none" stroke={C.blue} strokeWidth="2.5" />
          {f.map((w, i) => <circle key={w.week} cx={x(i)} cy={y(N(w.ctr_index))} r="3.5" fill={N(w.ctr_index) <= 0.8 ? C.red : C.blue}><title>{`Week ${w.week}: ${Math.round(N(w.ctr_index) * 100)}% of week 1 (${w.ads} ads)`}</title></circle>)}
          <text x={P} y={H - 6} fontSize="10" fill="#888">week 1</text><text x={W - P} y={H - 6} fontSize="10" fill="#888" textAnchor="end">week {f[f.length - 1].week}</text>
        </svg>}
        {!!fr.length && <div><div className="text-xs font-semibold mb-1">Times seen (last 6 months)</div><Bars rows={fr} label={(r) => `${r.k1}×`} base={base} /></div>}
      </div>
    </Card>
  );
}

function Patterns({ res }) {
  const wins = res.patterns.filter((p) => p.tone === 'win'), losses = res.patterns.filter((p) => p.tone === 'loss'), info = res.patterns.filter((p) => p.tone === 'info');
  const Item = ({ p }) => (
    <div className="glass-card p-3 space-y-1" data-testid="pattern">
      <div className="flex items-start gap-2"><span aria-hidden style={{ color: p.tone === 'win' ? C.green : p.tone === 'loss' ? C.red : C.blue }}>{p.tone === 'win' ? '▲' : p.tone === 'loss' ? '▼' : '●'}</span>
        <div className="flex-1 text-sm font-semibold">{p.title}</div>{p.confidence && <Badge proven={p.confidence === 'proven'} />}</div>
      <div className="text-xs text-glass-secondary pl-5">{p.detail}</div>
    </div>);
  return (
    <Card title="Proven patterns" sub={`Judged on cost per ${GOAL_LABEL[res.goal].one} (average ${inr(res.baseline)}). "Early" = promising, not enough data yet.`} testid="insights-patterns">
      {!res.patterns.length ? <div className="text-sm text-glass-muted">Nothing stands out in this view: no campaign, ad, audience or timing is clearly better or worse than average. Try a longer period or All campaigns.</div> : (
        <div className="grid md:grid-cols-2 gap-3">
          <div className="space-y-2"><div className="text-xs font-semibold" style={{ color: C.green }}>Do more of</div>{wins.map((p) => <Item key={p.id} p={p} />)}{!wins.length && <div className="text-xs text-glass-muted">None yet.</div>}</div>
          <div className="space-y-2"><div className="text-xs font-semibold" style={{ color: C.red }}>Do less of</div>{losses.map((p) => <Item key={p.id} p={p} />)}{!losses.length && <div className="text-xs text-glass-muted">None yet.</div>}
            {info.map((p) => <Item key={p.id} p={p} />)}</div>
        </div>)}
    </Card>
  );
}

function WhatIf({ d }) {
  const [amt, setAmt] = useState(5000);
  const r = useMemo(() => whatIf(d, amt), [d, amt]);
  return (
    <Card title="Budget what-if" sub="Move weekly budget from losing campaigns to proven winners, at their own past cost" testid="insights-whatif">
      <div className="flex items-center gap-3 text-sm">
        <span>Move</span><input aria-label="Weekly amount" type="range" min="1000" max="50000" step="1000" value={amt} onChange={(e) => setAmt(Number(e.target.value))} className="flex-1" />
        <b className="w-24 text-right">{inr(amt)}/week</b>
      </div>
      {r ? <div className="text-sm">Moving <b>{inr(r.moved)}/week</b> from {r.from.slice(0, 3).join(', ')} to {r.to.slice(0, 3).join(', ')}: about
        <b style={{ color: r.gain >= 0 ? C.green : C.red }}> {r.gain >= 0 ? '+' : ''}{r.gain.toFixed(1)} {GOAL_LABEL[r.goal].many} per week</b>
        <span className="text-glass-muted"> (winners cost {inr(r.winnerCost)} each). An estimate from your history; results can shift when budgets grow.</span></div>
        : <div className="text-sm text-glass-muted">Needs at least one proven winning and one losing campaign in this period.</div>}
    </Card>
  );
}

function Notes({ d, admin, reload }) {
  const [day, setDay] = useState(todayIn());
  const [text, setText] = useState('');
  return (
    <Card title="Timeline notes" sub="Exam dates, offers, price changes: shown as flags on the weekly chart" testid="insights-notes">
      <div className="space-y-1 text-sm">{(d.notes || []).map((n) => (
        <div key={n.id} className="flex items-center gap-2"><span className="text-glass-muted w-24">{short(n.day)}</span><span className="flex-1">{n.text}</span>
          {admin && <button type="button" aria-label="Delete note" onClick={() => run(rpc('api_ads_meta_note_delete', { p_id: n.id }).then(reload), 'Note removed')}><Icon name="trash" size={14} /></button>}</div>))}
        {!(d.notes || []).length && <div className="text-glass-muted text-xs">No notes in this period.</div>}</div>
      {admin && <div className="flex flex-wrap gap-2">
        <input aria-label="Note date" type="date" className="glass-input px-2 py-1.5 text-sm" value={day} onChange={(e) => setDay(e.target.value)} />
        <input aria-label="Note text" className="glass-input px-2 py-1.5 text-sm flex-1 min-w-[10rem]" maxLength={200} placeholder="e.g. DGCA exam results out" value={text} onChange={(e) => setText(e.target.value)} />
        <Btn disabled={!text.trim()} onClick={async () => { await rpc('api_ads_meta_note_save', { p_day: day, p_text: text }); setText(''); reload(); }}>Add note</Btn>
      </div>}
    </Card>
  );
}

function Reports({ admin }) {
  const [r, reload] = useLoad(() => rpc('api_ads_meta_reports'), []);
  const [emails, setEmails] = useState(null);
  const [open, setOpen] = useState(null);
  if (!r) return null;
  const list = emails ?? (r.emails || []).join(', ');
  return (
    <Card title="Monthly summaries" sub="Built on the 1st of each month from the month before" testid="insights-reports">
      <div className="space-y-1 text-sm">{(r.reports || []).map((m) => (
        <div key={m.month}>
          <button type="button" className="w-full flex items-center gap-2 text-left" onClick={() => setOpen(open === m.month ? null : m.month)}>
            <b className="w-32">{new Date(`${m.month}T00:00:00Z`).toLocaleString('en-IN', { month: 'long', year: 'numeric', timeZone: 'UTC' })}</b>
            <span className="flex-1 text-xs text-glass-muted">{inr(m.current?.spend)} · {fmt(m.current?.meta_leads)} leads · {fmt(m.current?.customers)} admitted</span>
            <span className="text-[11px]" style={{ color: m.emailed_at ? C.green : C.amber }}>{m.emailed_at ? 'emailed' : m.email_error || 'not emailed'}</span>
          </button>
          {open === m.month && <ul className="text-xs pl-4 list-disc">{(m.patterns || []).slice(0, 8).map((p, i) => <li key={i}>{p.title}</li>)}</ul>}
        </div>))}
        {!(r.reports || []).length && <div className="text-xs text-glass-muted">The first summary appears on the 1st of next month, once the history is collected.</div>}
      </div>
      {admin && <div className="space-y-1">
        <div className="text-xs">{r.email_ready ? 'Email it to:' : 'CRM email is not set up yet, so summaries are saved here only. Add recipients now and they get it once email works:'}</div>
        <div className="flex gap-2"><input aria-label="Summary recipients" className="glass-input px-2 py-1.5 text-sm flex-1" placeholder="name@weoneaviation.in, …" value={list} onChange={(e) => setEmails(e.target.value)} />
          <Btn ghost onClick={() => run(rpc('api_ads_meta_report_emails_save', { p_emails: list.split(/[,\s]+/).filter(Boolean) }).then(() => { setEmails(null); reload(); }), 'Saved')}>Save</Btn></div>
      </div>}
    </Card>
  );
}

export default function AdsMetaInsights({ access, edge }) {
  const today = todayIn();
  const [days, setDays] = useState('90');
  const [campaign, setCampaign] = useState('');
  const [form, setForm] = useState('');
  const [pipeline, setPipeline] = useState('');
  const from = addDays(today, -(Number(days) - 1));
  const [d, reload] = useLoad(() => rpc('api_ads_meta_insights', { p_from: from, p_to: today, p_campaign: campaign || null, p_form: form || null, p_pipeline: pipeline || null }, { timeout: 60000 }),
    [from, today, campaign, form, pipeline]);
  const res = useMemo(() => (d ? findPatterns(d) : null), [d]);
  const cov = d?.coverage || {};
  const empty = d && !cov.first_day;
  return (
    <div className="space-y-4" data-testid="meta-insights">
      <style>{`@media print { nav, header, [role=tablist], .no-print { display: none !important } .glass-card { box-shadow: none !important; break-inside: avoid } }`}</style>
      <div className="flex flex-wrap gap-2 items-center no-print">
        <select aria-label="Period" className="glass-input px-3 py-2 text-sm" value={days} onChange={(e) => setDays(e.target.value)}>{PERIODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
        <select aria-label="Campaign" className="glass-input px-3 py-2 text-sm max-w-[14rem]" value={campaign} onChange={(e) => setCampaign(e.target.value)}>
          <option value="">All campaigns</option>{(d?.options?.campaigns || []).map((c) => <option key={c.ext} value={c.ext}>{c.name || c.ext}</option>)}</select>
        <select aria-label="Lead form" className="glass-input px-3 py-2 text-sm max-w-[14rem]" value={form} onChange={(e) => setForm(e.target.value)}>
          <option value="">All lead forms</option>{(d?.options?.forms || []).map((f) => <option key={f.id} value={f.id}>{f.name || f.id}</option>)}</select>
        <select aria-label="Pipeline" className="glass-input px-3 py-2 text-sm" value={pipeline} onChange={(e) => setPipeline(e.target.value)}>
          <option value="">Pilot Training + Charter</option><option value="pilot_training">Pilot Training</option><option value="charter">Charter</option></select>
        <div className="flex-1" />
        <Btn ghost onClick={() => window.print()}><Icon name="external" size={14} />Download PDF</Btn>
      </div>
      <div className="text-xs text-glass-muted flex flex-wrap items-center gap-2 no-print" data-testid="insights-coverage">
        <span>{cov.first_day ? `History ${short(cov.first_day)} – ${short(cov.last_day)} · ${fmt(cov.ads)} ads` : 'History not collected yet'}
          {cov.done_at ? ' · complete, refreshed daily' : cov.cursor ? ` · collecting (up to ${short(cov.cursor)}), continues every hour` : ''}
          {cov.last_run ? ` · last run: ${cov.last_run.detail}` : ''}</span>
        {access.is_admin && edge && <Btn ghost onClick={() => run(edge({ jobs: ['meta_history'] }).then(reload), 'History updated')}><Icon name="refresh" size={14} />Refresh now</Btn>}
      </div>
      {!d ? <div className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</div>
        : empty ? <div className="glass-card p-6 text-center text-sm">Your Meta history is collected automatically within the hour (up to {cov.months} months back).{access.is_admin ? ' Or press Refresh now.' : ''}</div>
        : <>
          <Tiles d={d} goal={res.goal} />
          {N(d.crm_unplaced) > 0 && <div className="text-[11px] text-glass-muted">{d.crm_unplaced} CRM lead(s) from Meta ads without ad details are counted in the totals but not in the per-ad numbers.</div>}
          <Patterns res={res} />
          <div className="grid lg:grid-cols-2 gap-4"><Funnel c={d.current} /><WhatIf d={d} /></div>
          <Trend d={d} goal={res.goal} />
          <Board d={d} goal={res.goal} baseline={res.baseline} />
          <Gallery d={d} goal={res.goal} baseline={res.baseline} />
          <Audience d={d} />
          <Fatigue d={d} />
          <Notes d={d} admin={access.is_admin} reload={reload} />
        </>}
      <Reports admin={access.is_admin} />
    </div>
  );
}
