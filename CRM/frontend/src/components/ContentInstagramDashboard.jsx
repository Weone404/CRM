import { useEffect, useMemo, useRef, useState } from 'react';
import { rpc, useLoad } from './adsKit';

// Content > Instagram > Dashboard (migration 138, api_ig_dm_dashboard). Comment-to-DM and the inbox, day by day (India days).
// Palette: the validated categorical slots 1-4 (blue, orange, aqua, yellow); aqua and yellow sit under 3:1 on the surface,
// so the legend, the tooltip and the table view always carry the values too.

const SERIES = [
  { key: 'comments', label: 'Comments', color: '#2a78d6' },
  { key: 'dms', label: 'DMs sent', color: '#eb6834' },
  { key: 'messages', label: 'Messages received', color: '#1baf7a' },
  { key: 'requests', label: 'Message requests', color: '#eda100' },
];
const TILES = [
  ['comments', 'Comments', 'on your posts'], ['dms', 'DMs sent', 'to commenters'], ['messages', 'Messages received', 'in your inbox'],
  ['requests', 'Message requests', 'from people who don’t follow you'], ['brochures', 'Brochures sent', 'PDF in the chat'], ['leads', 'CRM leads', 'from numbers sent'],
];
const HANDLED = { sent: 'DM sent', public: 'Had our DM already: reply only', imported: 'Answered before', spam: 'Spam: skipped',
  negative: 'Angry: left for the team', failed: 'Instagram refused', sending: 'Sending' };
const INK = { grid: 'rgba(0,0,0,0.08)', muted: 'rgba(0,0,0,0.55)' };
const fmt = (n) => Number(n || 0).toLocaleString('en-IN');
const dshort = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const dlong = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
const niceMax = (v) => { if (v <= 4) return 4; const p = 10 ** Math.floor(Math.log10(v)); const s = [1, 2, 2.5, 5, 10].find((k) => k * p >= v); return s * p; };

function Card({ title, sub, children, right, testid }) {
  return (
    <section className="glass-card p-5" data-testid={testid}>
      <div className="flex flex-wrap items-start gap-2 mb-3">
        <div className="flex-1 min-w-[200px]"><h3 className="m-0 text-base font-semibold">{title}</h3>{sub && <p className="m-0 text-[12px] text-glass-secondary">{sub}</p>}</div>
        {right}
      </div>
      {children}
    </section>);
}

function Tile({ label, hint, now, before, days }) {
  const diff = now - before;
  const pct = before ? Math.round((diff / before) * 100) : null;
  return (
    <div className="glass-card px-4 py-3">
      <div className="text-[12px] text-glass-secondary">{label}</div>
      <div className="text-[26px] font-semibold leading-tight text-glass-primary tabular-nums">{fmt(now)}</div>
      <div className="text-[11px] text-glass-secondary">{hint}</div>
      <div className="text-[11px] mt-0.5 text-glass-secondary">
        {before === 0 && now === 0 ? `none in the previous ${days} days either` : pct === null ? `new: none in the previous ${days} days`
          : `${diff >= 0 ? '▲' : '▼'} ${Math.abs(pct)}% vs previous ${days} days (${fmt(before)})`}</div>
    </div>);
}

function Trend({ rows, shown, setShown }) {
  const [hover, setHover] = useState(null);
  const [table, setTable] = useState(false);
  const ref = useRef(null);
  const wrap = useRef(null);
  const [cw, setCw] = useState(760);
  useEffect(() => {                         // draw at the real width: text stays 11px and the chart keeps its height on phones
    const el = wrap.current; if (!el) return undefined;
    const ro = new ResizeObserver(([e]) => setCw(Math.max(280, Math.round(e.contentRect.width))));
    ro.observe(el); return () => ro.disconnect();
  }, [table]);
  const narrow = cw < 520;
  const W = cw, H = narrow ? 220 : 260, L = 30, R = 10, T = 12, B = 28;
  const active = SERIES.filter((s) => shown[s.key]);
  const max = niceMax(Math.max(1, ...rows.flatMap((r) => active.map((s) => Number(r[s.key]) || 0))));
  const step = rows.length > 1 ? (W - L - R) / (rows.length - 1) : 0;
  const x = (i) => L + i * step;
  const y = (v) => T + (1 - v / max) * (H - T - B);
  const ticks = [0, max / 2, max];
  const every = Math.ceil(rows.length / (narrow ? 4 : 7));
  const pick = (e) => {
    const box = ref.current.getBoundingClientRect();
    const px = ((e.clientX - box.left) / box.width) * W;
    setHover(Math.max(0, Math.min(rows.length - 1, Math.round((px - L) / (step || 1)))));
  };
  const h = hover !== null ? rows[hover] : null;
  const key = (e) => {
    if (e.key === 'ArrowRight') setHover((v) => Math.min(rows.length - 1, (v ?? -1) + 1));
    if (e.key === 'ArrowLeft') setHover((v) => Math.max(0, (v ?? rows.length) - 1));
  };
  return (
    <Card title="Day by day" sub="Tap a name to hide or show it. Hover or use the arrow keys for a day."
      testid="igd-trend" right={<button type="button" className="text-[13px] text-[var(--accent)] min-h-[32px]" onClick={() => setTable(!table)}>{table ? 'Show the chart' : 'Show as a table'}</button>}>
      <div className="flex flex-wrap gap-2 mb-2" role="group" aria-label="Series">
        {SERIES.map((s) => (
          <button key={s.key} type="button" aria-pressed={!!shown[s.key]} onClick={() => setShown({ ...shown, [s.key]: !shown[s.key] })}
            className="inline-flex items-center gap-1.5 px-2.5 min-h-[32px] rounded-full text-[12px] border"
            style={{ borderColor: shown[s.key] ? 'rgba(0,0,0,0.18)' : 'rgba(0,0,0,0.08)', opacity: shown[s.key] ? 1 : 0.45 }}>
            <span className="inline-block rounded-full" style={{ width: 10, height: 10, background: s.color }} />{s.label}
          </button>))}
      </div>
      {table ? (
        <div className="overflow-x-auto max-h-[320px]"><table className="w-full text-sm border-collapse min-w-[480px]">
          <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-1.5">Day</th>{SERIES.map((s) => <th key={s.key} className="font-medium text-right">{s.label}</th>)}</tr></thead>
          <tbody>{[...rows].reverse().map((r) => (
            <tr key={r.day} className="border-t border-[var(--hairline)]"><td className="py-1.5">{dlong(r.day)}</td>{SERIES.map((s) => <td key={s.key} className="text-right tabular-nums">{fmt(r[s.key])}</td>)}</tr>))}</tbody>
        </table></div>
      ) : (
        <div className="relative" ref={wrap}>
          <svg ref={ref} viewBox={`0 0 ${W} ${H}`} className="w-full h-auto touch-none select-none outline-none" role="img" tabIndex={0}
            aria-label={`Daily comments, DMs, messages and requests, ${dshort(rows[0].day)} to ${dshort(rows[rows.length - 1].day)}`}
            onPointerMove={pick} onPointerDown={pick} onPointerLeave={() => setHover(null)} onKeyDown={key} onBlur={() => setHover(null)}>
            {ticks.map((t) => <g key={t}><line x1={L} x2={W - R} y1={y(t)} y2={y(t)} stroke={INK.grid} strokeWidth="1" />
              <text x={L - 6} y={y(t) + 4} fontSize="11" textAnchor="end" fill={INK.muted}>{fmt(t)}</text></g>)}
            {rows.map((r, i) => (i % every === 0 || i === rows.length - 1) && (i === rows.length - 1 || rows.length - 1 - i >= every * 0.75) &&
              <text key={r.day} x={x(i)} y={H - 8} fontSize="11" textAnchor={i === 0 ? 'start' : i === rows.length - 1 ? 'end' : 'middle'} fill={INK.muted}>{dshort(r.day)}</text>)}
            {active.map((s) => <path key={s.key} d={rows.map((r, i) => `${i ? 'L' : 'M'}${x(i)},${y(Number(r[s.key]) || 0)}`).join(' ')}
              fill="none" stroke={s.color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />)}
            {active.map((s) => { const v = Number(rows[rows.length - 1][s.key]) || 0; return <circle key={s.key} cx={x(rows.length - 1)} cy={y(v)} r="4" fill={s.color} stroke="#fcfcfb" strokeWidth="2" />; })}
            {h && <g><line x1={x(hover)} x2={x(hover)} y1={T} y2={H - B} stroke="rgba(0,0,0,0.35)" strokeWidth="1" />
              {active.map((s) => <circle key={s.key} cx={x(hover)} cy={y(Number(h[s.key]) || 0)} r="4.5" fill={s.color} stroke="#fcfcfb" strokeWidth="2" />)}</g>}
          </svg>
          {h && (
            <div className={`${narrow ? 'mt-2' : 'absolute top-1'} pointer-events-none rounded-xl border border-[var(--hairline)] px-3 py-2 text-[12px] shadow-lg`} role="status"
              style={narrow ? { background: '#fff' } : { background: '#fff', left: `${(x(hover) / W) * 100}%`, transform: hover > rows.length / 2 ? 'translateX(calc(-100% - 10px))' : 'translateX(10px)', minWidth: 170 }}>
              <div className="font-semibold mb-1">{dlong(h.day)}</div>
              {SERIES.map((s) => (
                <div key={s.key} className="flex items-center gap-2" style={{ opacity: shown[s.key] ? 1 : 0.5 }}>
                  <span className="inline-block rounded-full" style={{ width: 8, height: 8, background: s.color }} />
                  <b className="tabular-nums">{fmt(h[s.key])}</b><span className="text-glass-secondary">{s.label}</span>
                </div>))}
              {(Number(h.brochures) > 0 || Number(h.leads) > 0) && <div className="mt-1 text-glass-secondary">{fmt(h.brochures)} {Number(h.brochures) === 1 ? 'brochure' : 'brochures'} · {fmt(h.leads)} {Number(h.leads) === 1 ? 'lead' : 'leads'}</div>}
            </div>)}
        </div>)}
    </Card>);
}

function Bars({ items, testid }) {   // one hue: magnitude only
  const max = Math.max(1, ...items.map((i) => Number(i.n) || 0));
  return (
    <div className="space-y-2" data-testid={testid}>
      {items.map((it) => (
        <div key={it.label} className="flex items-center gap-3 text-[13px]">
          <div className="w-[42%] sm:w-48 shrink-0">{it.label}{it.hint && <div className="text-[11px] text-glass-secondary">{it.hint}</div>}</div>
          <div className="flex-1 h-[18px] rounded-r bg-[rgba(118,118,128,0.08)]" title={`${it.label}: ${fmt(it.n)}`}>
            <div className="h-full rounded-r" style={{ width: `${(Number(it.n) / max) * 100}%`, minWidth: Number(it.n) ? 3 : 0, background: '#2a78d6', borderRadius: '0 4px 4px 0' }} />
          </div>
          <div className="w-16 text-right tabular-nums"><b>{fmt(it.n)}</b>{it.pct != null && <span className="text-[11px] text-glass-secondary"> {it.pct}%</span>}</div>
        </div>))}
    </div>);
}

export default function ContentInstagramDashboard() {
  const [days, setDays] = useState(30);
  const [shown, setShown] = useState({ comments: true, dms: true, messages: true, requests: true });
  const [d] = useLoad(() => rpc('api_ig_dm_dashboard', { p_days: days }), [days], { refreshMs: 60000 });
  const funnel = useMemo(() => {
    const f = d?.funnel || []; const top = Number(f[0]?.n) || 0;
    return f.map((s, i) => ({ label: s.step, n: s.n, pct: i && top ? Math.round((Number(s.n) / top) * 100) : null }));
  }, [d]);
  if (!d) return <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>;
  const tot = (k) => d.totals?.[k] || { now: 0, before: 0 };
  const split = d.inbox_split || {};
  const handled = Object.entries(d.handled || {}).map(([k, n]) => ({ label: HANDLED[k] || k, n })).sort((a, b) => b.n - a.n);
  return (
    <div className="space-y-3" data-testid="ig-dashboard">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[13px] text-glass-secondary flex-1">{dlong(d.from)} to {dlong(d.to)} · India time · updates every minute</span>
        <div role="radiogroup" aria-label="Period" className="inline-flex rounded-full p-0.5" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[7, 30, 90].map((n) => <button key={n} type="button" role="radio" aria-checked={days === n} onClick={() => setDays(n)}
            className="px-3 min-h-[30px] rounded-full text-[13px]" style={days === n ? { background: '#fff', fontWeight: 600, boxShadow: '0 1px 3px rgba(0,0,0,0.12)' } : {}}>{n} days</button>)}
        </div>
      </div>
      <div className="grid grid-cols-2 lg:grid-cols-3 gap-3">
        {TILES.map(([k, l, h]) => <Tile key={k} label={l} hint={h} now={Number(tot(k).now)} before={Number(tot(k).before)} days={days} />)}
      </div>
      <Trend rows={d.series || []} shown={shown} setShown={setShown} />
      <div className="grid lg:grid-cols-2 gap-3">
        <Card title="From comment to lead" sub="People in this period; % of comments." testid="igd-funnel"><Bars items={funnel} /></Card>
        <Card title="Who is messaging" sub="New chats and replies to our DM in this period." testid="igd-inbox">
          <Bars items={[
            { label: 'Followers writing first', hint: 'land in your inbox', n: split.inbox },
            { label: 'Message requests', hint: 'not following you yet', n: split.requests },
            { label: 'Commenters replying', hint: 'answered our DM', n: split.commenters }]} />
        </Card>
        <Card title="How comments were handled" testid="igd-handled">
          {handled.length ? <Bars items={handled} /> : <div className="text-sm text-glass-secondary">No comments in this period.</div>}
        </Card>
        <Card title="Posts bringing comments" testid="igd-posts">
          {!(d.posts || []).length ? <div className="text-sm text-glass-secondary">No comments in this period.</div> : (
            <table className="w-full text-sm border-collapse">
              <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-1.5">Post</th><th className="font-medium text-right">Comments</th><th className="font-medium text-right">DMs</th></tr></thead>
              <tbody>{d.posts.map((p, i) => (
                <tr key={p.media_id} className="border-t border-[var(--hairline)]">
                  <td className="py-1.5">{p.permalink ? <a href={p.permalink} target="_blank" rel="noreferrer">{p.permalink.includes('/reel/') ? 'Reel' : 'Post'} {i + 1}</a> : `Post ${i + 1}`}</td>
                  <td className="text-right tabular-nums">{fmt(p.comments)}</td><td className="text-right tabular-nums">{fmt(p.dms)}</td></tr>))}</tbody>
            </table>)}
        </Card>
      </div>
      <p className="m-0 text-[11px] text-glass-secondary">Messages and requests are counted from {dlong('2026-11-24')}, when the inbox log started.</p>
    </div>);
}
