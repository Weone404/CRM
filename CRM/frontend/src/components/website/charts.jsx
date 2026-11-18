import { useEffect, useMemo, useRef, useState } from 'react';

// Website charts: hand-drawn SVG, no chart library (keeps the CRM light). One accent series, the period before in
// dashed grey, recessive grid, hover/focus tooltips on every mark, and the numbers are always also in a table nearby.

export const C = { accent: '#0A63CE', accentSoft: 'rgba(10,99,206,0.10)', prev: '#A1A1AA', grid: 'rgba(60,60,67,0.10)', ink2: 'rgba(0,0,0,0.60)',
  cat: ['#0A63CE', '#eb6834', '#1baf7a'], good: '#1E7B34', warn: '#B26A00', bad: '#C0271D' };
const nf = (n, d = 0) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: d }));
const DAY = 86400000;

export function toDate(d) {
  const s = String(d || '');
  const iso = /^\d{8}$/.test(s) ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s;
  return new Date(`${iso}T00:00:00Z`);
}
export const dayLabel = (t) => new Date(t).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' });

function useWidth() {
  const ref = useRef(null);
  const [w, setW] = useState(0);
  useEffect(() => {
    if (!ref.current) return undefined;
    const ro = new ResizeObserver(([e]) => setW(Math.round(e.contentRect.width)));
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

function ticks(min, max, n = 4) {
  if (max === min) return [min];
  const raw = (max - min) / n, mag = 10 ** Math.floor(Math.log10(raw)), step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) || raw;
  const out = [];
  for (let v = Math.floor(min / step) * step; v < max + step - 1e-9; v += step) out.push(+v.toFixed(6));
  return out;
}

function Tip({ x, w, children, side }) {
  const left = side ? (x > w / 2 ? Math.max(0, x - 192) : Math.min(x + 12, Math.max(0, w - 180))) : Math.min(Math.max(x - 90, 0), Math.max(0, w - 180));
  return (
    <div role="status" className="absolute top-1 z-10 pointer-events-none w-[180px] rounded-xl bg-white/95 border border-[var(--hairline)] shadow-[0_6px_24px_rgba(0,0,0,0.10)] px-3 py-2 text-[12px] leading-snug"
      style={{ left }}>{children}</div>
  );
}
const Key = ({ color, dashed }) => <svg width="18" height="8" aria-hidden="true" className="shrink-0"><line x1="1" y1="4" x2="17" y2="4" stroke={color} strokeWidth="2" strokeDasharray={dashed ? '4 3' : undefined} strokeLinecap="round" /></svg>;

// ---------------------------------------------------------------- trend: this 28 days vs the 28 before, aligned by date
export function Trend({ cur = [], prev = [], value, format = (v) => nf(v), invert = false, height = 220, label, onPick }) {
  const [ref, w] = useWidth();
  const [hi, setHi] = useState(null);
  const pts = useMemo(() => {
    const p = new Map(prev.map((r) => [toDate(r.d).getTime() + 28 * DAY, r]));
    return cur.map((r) => { const t = toDate(r.d).getTime(); return { t, v: value(r), pv: p.has(t) ? value(p.get(t)) : null, pd: t - 28 * DAY }; })
      .filter((x) => x.v != null && !Number.isNaN(x.v));
  }, [cur, prev, value]);
  if (!pts.length) return <div ref={ref} className="h-[120px] grid place-items-center text-sm text-glass-secondary">No days to draw yet.</div>;
  const pad = { l: 44, r: 12, t: 14, b: 26 }, W = Math.max(w, 280), H = height, iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
  const all = pts.flatMap((p) => [p.v, p.pv]).filter((v) => v != null);
  let lo = Math.min(...all), hiV = Math.max(...all);
  if (!invert) lo = Math.min(0, lo);
  if (lo === hiV) hiV = lo + 1;
  const ys = ticks(lo, hiV), y0 = Math.min(lo, ys[0]), y1 = Math.max(hiV, ys[ys.length - 1]);
  const X = (i) => pad.l + (pts.length === 1 ? iw / 2 : (i * iw) / (pts.length - 1));
  const Y = (v) => pad.t + (invert ? ((v - y0) / (y1 - y0)) * ih : ih - ((v - y0) / (y1 - y0)) * ih);
  const line = (k) => pts.map((p, i) => (p[k] == null ? null : `${X(i)},${Y(p[k])}`)).filter(Boolean).join(' L');
  const area = `M${X(0)},${Y(invert ? y1 : y0)} L${line('v')} L${X(pts.length - 1)},${Y(invert ? y1 : y0)} Z`;
  const pick = (clientX) => {
    const box = ref.current.getBoundingClientRect();
    const i = Math.round(((clientX - box.left - pad.l) / iw) * (pts.length - 1));
    setHi(Math.min(Math.max(i, 0), pts.length - 1));
  };
  const step = Math.max(1, Math.ceil(pts.length / Math.max(2, Math.floor(iw / 70))));
  const p = hi != null ? pts[hi] : null;
  const gradId = `g${label?.replace(/\W/g, '') || 'trend'}`;
  return (
    <div ref={ref} className="relative select-none">
      <svg width="100%" height={H} viewBox={`0 0 ${W} ${H}`} role="img" aria-label={label} tabIndex={0} className="block outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] rounded-lg"
        onPointerMove={(e) => pick(e.clientX)} onPointerLeave={() => setHi(null)} onClick={() => p && onPick?.(p)}
        onKeyDown={(e) => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); setHi((h) => Math.min(Math.max((h ?? (e.key === 'ArrowRight' ? -1 : pts.length)) + (e.key === 'ArrowRight' ? 1 : -1), 0), pts.length - 1)); } }}
        onBlur={() => setHi(null)}>
        <defs><linearGradient id={gradId} x1="0" x2="0" y1={invert ? '1' : '0'} y2={invert ? '0' : '1'}><stop offset="0" stopColor={C.accent} stopOpacity="0.16" /><stop offset="1" stopColor={C.accent} stopOpacity="0" /></linearGradient></defs>
        {ys.map((v) => <g key={v}><line x1={pad.l} x2={W - pad.r} y1={Y(v)} y2={Y(v)} stroke={C.grid} /><text x={pad.l - 8} y={Y(v)} dy="0.32em" textAnchor="end" fontSize="11" fill={C.ink2}>{format(v, true)}</text></g>)}
        {pts.map((q, i) => (pts.length - 1 - i) % step === 0 &&
          <text key={q.t} x={X(i)} y={H - 6} textAnchor={i === pts.length - 1 ? 'end' : X(i) - pad.l < 24 ? 'start' : 'middle'} fontSize="11" fill={C.ink2}>{dayLabel(q.t)}</text>)}
        <path d={area} fill={`url(#${gradId})`} className="wv-fade" />
        {pts.some((q) => q.pv != null) && <path d={`M${line('pv')}`} fill="none" stroke={C.prev} strokeWidth="1.5" strokeDasharray="4 4" strokeLinejoin="round" />}
        <path key={label} d={`M${line('v')}`} pathLength="1" fill="none" stroke={C.accent} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" className="wv-draw" />
        {p && <g>
          <line x1={X(hi)} x2={X(hi)} y1={pad.t} y2={pad.t + ih} stroke="rgba(0,0,0,0.25)" />
          {p.pv != null && <circle cx={X(hi)} cy={Y(p.pv)} r="4" fill="#fff" stroke={C.prev} strokeWidth="2" />}
          <circle cx={X(hi)} cy={Y(p.v)} r="5" fill={C.accent} stroke="#fff" strokeWidth="2" />
        </g>}
      </svg>
      {p && <Tip x={X(hi)} w={W} side>
        <div className="text-glass-secondary">{dayLabel(p.t)}</div>
        <div className="flex items-center gap-2"><Key color={C.accent} /><b className="text-[14px] text-glass-primary">{format(p.v)}</b></div>
        {p.pv != null && <div className="flex items-center gap-2 text-glass-secondary"><Key color={C.prev} dashed />{format(p.pv)} <span>on {dayLabel(p.pd)}</span></div>}
      </Tip>}
    </div>
  );
}
export function TrendLegend({ prevShown = true }) {
  return (
    <div className="flex flex-wrap gap-4 text-[12px] text-glass-secondary">
      <span className="inline-flex items-center gap-1.5"><Key color={C.accent} />Last 28 days</span>
      {prevShown && <span className="inline-flex items-center gap-1.5"><Key color={C.prev} dashed />The 28 days before</span>}
    </div>
  );
}

// ---------------------------------------------------------------- mini line for stat tiles
export function Spark({ values = [], invert = false, color = C.accent }) {
  const v = values.filter((x) => x != null && !Number.isNaN(x));
  if (v.length < 2) return null;
  const lo = Math.min(...v), hi = Math.max(...v), r = hi - lo || 1;
  const d = v.map((x, i) => `${(i * 100) / (v.length - 1)},${invert ? 2 + ((x - lo) / r) * 24 : 26 - ((x - lo) / r) * 24}`).join(' L');
  return (
    <svg viewBox="0 0 100 28" preserveAspectRatio="none" className="w-full h-7 mt-1" aria-hidden="true">
      <path d={`M${d}`} fill="none" stroke={color} strokeWidth="1.6" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
    </svg>
  );
}

// ---------------------------------------------------------------- columns with the earlier period as a ghost bar
export function Columns({ items = [], height = 210, format = (v) => nf(v), onPick, label, prevLabel = 'Before' }) {
  const [ref, w] = useWidth();
  const [hi, setHi] = useState(null);
  if (!items.length) return <div ref={ref} />;
  const pad = { l: 8, r: 8, t: 18, b: 34 }, W = Math.max(w, 260), H = height, iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
  const max = Math.max(1, ...items.flatMap((x) => [x.v, x.pv || 0]));
  const slot = iw / items.length, bw = Math.min(56, slot * 0.56);
  const hasPrev = items.some((x) => x.pv != null);
  return (
    <div ref={ref} className="relative">
      <svg width="100%" height={H} viewBox={`0 0 ${W} ${H}`} role="img" aria-label={label} className="block">
        <line x1={pad.l} x2={W - pad.r} y1={pad.t + ih} y2={pad.t + ih} stroke={C.grid} />
        {items.map((x, i) => {
          const cx = pad.l + slot * i + slot / 2, h = (ih * x.v) / max, ph = (ih * (x.pv || 0)) / max, on = hi === i;
          return (
            <g key={x.k} tabIndex={0} role="button" aria-label={`${x.k}: ${format(x.v)}${x.pv != null ? `, ${prevLabel.toLowerCase()} ${format(x.pv)}` : ''}`}
              onPointerEnter={() => setHi(i)} onPointerLeave={() => setHi(null)} onFocus={() => setHi(i)} onBlur={() => setHi(null)}
              onClick={() => onPick?.(x)} onKeyDown={(e) => { if (e.key === 'Enter') onPick?.(x); }} className={onPick ? 'cursor-pointer outline-none' : 'outline-none'}>
              <rect x={cx - slot / 2} y={pad.t} width={slot} height={ih + pad.b} fill={on ? 'rgba(118,118,128,0.06)' : 'transparent'} rx="8" />
              {hasPrev && <rect x={cx - bw / 2 - 5} y={pad.t + ih - ph} width={bw} height={ph} rx="4" fill="none" stroke={C.prev} strokeDasharray="3 3" />}
              <rect x={cx - bw / 2} y={pad.t + ih - h} width={bw} height={Math.max(h, x.v ? 2 : 0)} rx="4" fill={C.accent} opacity={hi == null || on ? 1 : 0.55} className="wv-grow" style={{ transformOrigin: `${cx}px ${pad.t + ih}px` }} />
              <text x={cx} y={pad.t + ih - h - 6} textAnchor="middle" fontSize="12" fontWeight="600" fill="rgba(0,0,0,0.85)">{format(x.v, true)}</text>
              <text x={cx} y={H - 16} textAnchor="middle" fontSize="12" fill="rgba(0,0,0,0.85)">{x.k}</text>
              {x.sub && <text x={cx} y={H - 3} textAnchor="middle" fontSize="10.5" fill={C.ink2}>{x.sub}</text>}
            </g>);
        })}
      </svg>
      {hi != null && <Tip x={pad.l + slot * hi + slot / 2} w={W}>
        <div className="text-glass-secondary">{items[hi].k}{items[hi].sub ? ` · ${items[hi].sub}` : ''}</div>
        <div className="flex items-center gap-2"><Key color={C.accent} /><b className="text-[14px] text-glass-primary">{format(items[hi].v)}</b></div>
        {items[hi].pv != null && <div className="flex items-center gap-2 text-glass-secondary"><Key color={C.prev} dashed />{format(items[hi].pv)} {prevLabel.toLowerCase()}</div>}
        {items[hi].hint && <div className="mt-1 text-[var(--accent)]">{items[hi].hint}</div>}
      </Tip>}
    </div>
  );
}

// ---------------------------------------------------------------- share of a whole (devices): one bar, 2px gaps, labelled
export function Share({ items = [], unit = '', label }) {
  const [hi, setHi] = useState(null);
  const total = items.reduce((n, x) => n + (Number(x.v) || 0), 0);
  if (!total) return <p className="m-0 text-sm text-glass-secondary">No data yet.</p>;
  return (
    <div aria-label={label}>
      <div className="flex h-3.5 gap-[2px] rounded-full overflow-hidden">
        {items.map((x, i) => (
          <div key={x.k} title={`${x.k}: ${nf(x.v)} ${unit} (${Math.round((100 * x.v) / total)}%)`} onPointerEnter={() => setHi(i)} onPointerLeave={() => setHi(null)}
            style={{ width: `${(100 * x.v) / total}%`, background: C.cat[i % 3], opacity: hi == null || hi === i ? 1 : 0.45, transition: 'opacity .15s' }} />
        ))}
      </div>
      <div className="mt-2.5 flex flex-wrap gap-x-5 gap-y-1.5 text-[13px]">
        {items.map((x, i) => (
          <span key={x.k} className="inline-flex items-center gap-1.5" onPointerEnter={() => setHi(i)} onPointerLeave={() => setHi(null)}>
            <span className="w-2.5 h-2.5 rounded-[3px]" style={{ background: C.cat[i % 3] }} />
            <span className="text-glass-primary capitalize">{String(x.k).toLowerCase()}</span>
            <b className="text-glass-primary">{Math.round((100 * x.v) / total)}%</b>
            <span className="text-glass-secondary">{nf(x.v)}{unit ? ` ${unit}` : ''}</span>
          </span>))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- horizontal bars that answer on hover and can be clicked
export function HBars({ items = [], valueKey = 'v', labelKey = 'k', format = (v) => nf(v), onPick, sub }) {
  const [hi, setHi] = useState(null);
  const max = Math.max(1, ...items.map((x) => Number(x[valueKey]) || 0));
  const total = items.reduce((n, x) => n + (Number(x[valueKey]) || 0), 0) || 1;
  const Tag = onPick ? 'button' : 'div';
  return (
    <div className="flex flex-col gap-1">
      {items.map((x, i) => (
        <Tag key={i} type={onPick ? 'button' : undefined} onClick={onPick ? () => onPick(x) : undefined} onPointerEnter={() => setHi(i)} onPointerLeave={() => setHi(null)}
          className={`text-left flex flex-col gap-1 rounded-lg px-1.5 py-1 -mx-1.5 ${hi === i ? 'bg-[rgba(118,118,128,0.06)]' : ''}`}>
          <div className="flex justify-between gap-3 text-sm">
            <span className="truncate text-glass-primary">{x[labelKey]}</span>
            <span className="shrink-0 text-glass-secondary">{hi === i ? <><b className="text-glass-primary">{format(x[valueKey])}</b> · {Math.round((100 * x[valueKey]) / total)}%{sub ? ` · ${sub(x)}` : ''}</> : format(x[valueKey])}</span>
          </div>
          <div className="h-1.5 rounded bg-[var(--surface-sunken)] overflow-hidden">
            <div className="h-1.5 rounded wv-bar" style={{ width: `${(100 * (Number(x[valueKey]) || 0)) / max}%`, background: C.accent, opacity: hi == null || hi === i ? 1 : 0.5 }} />
          </div>
        </Tag>))}
    </div>
  );
}

// ---------------------------------------------------------------- opportunity map: every search by position and how often it was seen
export function OpportunityMap({ rows = [], onPick, selected }) {
  const [ref, w] = useWidth();
  const [hi, setHi] = useState(null);
  const pts = rows.filter((r) => r.pos != null && Number(r.impressions) > 0);
  if (!pts.length) return <div ref={ref} />;
  const pad = { l: 46, r: 14, t: 14, b: 34 }, W = Math.max(w, 300), H = 300, iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
  const MAXP = 40, maxI = Math.max(10, ...pts.map((r) => Number(r.impressions)));
  const lmax = Math.log10(maxI) + 0.18, lmin = 0.7;
  const X = (p) => pad.l + ((Math.min(p, MAXP) - 1) / (MAXP - 1)) * iw;
  const Y = (i) => pad.t + ih - ((Math.log10(Math.max(i, 5)) - lmin) / (lmax - lmin)) * ih;
  const maxC = Math.max(1, ...pts.map((r) => Number(r.clicks) || 0));
  const R = (c) => 4 + 10 * Math.sqrt((Number(c) || 0) / maxC);
  const yt = [10, 100, 1000, 10000, 100000].filter((v) => v <= maxI * 1.2);
  const near = (e) => {
    const b = ref.current.getBoundingClientRect(), mx = e.clientX - b.left, my = e.clientY - b.top;
    let best = null, bd = 28 * 28;
    pts.forEach((r, i) => { const d = (X(r.pos) - mx) ** 2 + (Y(r.impressions) - my) ** 2; if (d < bd) { bd = d; best = i; } });
    setHi(best);
  };
  const h = hi != null ? pts[hi] : null;
  return (
    <div ref={ref} className="relative select-none">
      <svg width="100%" height={H} viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Searches by Google position and times seen" className="block"
        onPointerMove={near} onPointerLeave={() => setHi(null)} onClick={() => h && onPick?.(h)} style={{ cursor: h ? 'pointer' : 'default' }}>
        <rect x={X(8)} y={pad.t} width={X(20) - X(8)} height={ih} fill={C.accentSoft} rx="6" />
        <text x={(X(8) + X(20)) / 2} y={pad.t + 14} textAnchor="middle" fontSize="11" fontWeight="600" fill={C.accent}>Almost page 1</text>
        <line x1={X(10.5)} x2={X(10.5)} y1={pad.t} y2={pad.t + ih} stroke={C.grid} strokeDasharray="3 3" />
        <text x={X(10.5) + 4} y={pad.t + ih - 6} fontSize="10.5" fill={C.ink2}>page 2 →</text>
        {yt.map((v) => <g key={v}><line x1={pad.l} x2={W - pad.r} y1={Y(v)} y2={Y(v)} stroke={C.grid} /><text x={pad.l - 8} y={Y(v)} dy="0.32em" textAnchor="end" fontSize="11" fill={C.ink2}>{v >= 1000 ? `${v / 1000}K` : v}</text></g>)}
        {[1, 5, 10, 20, 30, 40].map((p) => <text key={p} x={X(p)} y={pad.t + ih + 16} textAnchor="middle" fontSize="11" fill={C.ink2}>{p === 40 ? '40+' : p}</text>)}
        <text x={pad.l + iw / 2} y={H - 3} textAnchor="middle" fontSize="11" fill={C.ink2}>Position in Google (1 = top)</text>
        <text transform={`translate(11 ${pad.t + ih / 2}) rotate(-90)`} textAnchor="middle" fontSize="11" fill={C.ink2}>Times seen</text>
        {pts.map((r, i) => (
          <circle key={r.query} cx={X(r.pos)} cy={Y(r.impressions)} r={R(r.clicks)} fill={r.brand ? C.cat[1] : C.cat[0]} fillOpacity={hi === i || selected === r.query ? 0.95 : 0.42}
            stroke="#fff" strokeWidth="1.5" />))}
        {h && <circle cx={X(h.pos)} cy={Y(h.impressions)} r={R(h.clicks) + 3} fill="none" stroke="rgba(0,0,0,0.6)" strokeWidth="1.5" />}
      </svg>
      {h && <Tip x={X(h.pos)} w={W} side>
        <div className="font-semibold text-glass-primary break-words">{h.query}</div>
        <div className="text-glass-secondary">Position <b className="text-glass-primary">{h.pos}</b>{h.prev_pos != null ? ` (was ${h.prev_pos})` : ' · new'}</div>
        <div className="text-glass-secondary">Seen <b className="text-glass-primary">{nf(h.impressions)}</b> · clicks <b className="text-glass-primary">{nf(h.clicks)}</b></div>
        <div className="mt-1 text-[var(--accent)]">Click for its pages</div>
      </Tip>}
      <div className="mt-1 flex flex-wrap gap-4 text-[12px] text-glass-secondary">
        <span className="inline-flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-full" style={{ background: C.cat[0] }} />Other searches</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-full" style={{ background: C.cat[1] }} />Your brand</span>
        <span>Bigger dot = more clicks</span>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Core Web Vital on its good / needs work / poor scale
export function Vital({ name, value, good, poor, unit, digits = 0 }) {
  if (value == null) return <div className="text-[13px] text-glass-secondary">{name} —</div>;
  const end = poor * 1.6, at = Math.min(value / end, 1) * 100;
  const tone = value <= good ? C.good : value <= poor ? C.warn : C.bad;
  return (
    <div title={`${name}: ${nf(value, digits)}${unit}. Good under ${good}${unit}, poor over ${poor}${unit}.`}>
      <div className="flex justify-between text-[12px]"><span className="text-glass-secondary">{name}</span><b style={{ color: tone }}>{nf(value, digits)}{unit}</b></div>
      <div className="relative mt-1 h-1.5 flex gap-[2px]">
        <div className="h-full rounded-l-full" style={{ width: `${(good / end) * 100}%`, background: 'rgba(30,123,52,0.35)' }} />
        <div className="h-full" style={{ width: `${((poor - good) / end) * 100}%`, background: 'rgba(178,106,0,0.35)' }} />
        <div className="h-full flex-1 rounded-r-full" style={{ background: 'rgba(192,39,29,0.30)' }} />
        <div className="absolute -top-1 w-1 h-3.5 rounded-full" style={{ left: `calc(${at}% - 2px)`, background: tone, boxShadow: '0 0 0 2px #fff' }} />
      </div>
    </div>
  );
}
