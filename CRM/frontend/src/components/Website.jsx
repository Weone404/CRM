import { useCallback, useEffect, useMemo, useState } from 'react';
import { showToast } from '../utils/toast';
import { navigate, useRoute } from '../utils/route';
import Icon from './icons';
import { Trend, TrendLegend, Spark, Columns, Share, HBars, OpportunityMap, Vital } from './website/charts';
import SitesHome, { rpc, edge, collect, useSites, SiteSheet, SiteMark, hostOf } from './website/Sites';

// Google > Website: #/website shows a card per website (website/Sites.jsx); #/website/<tab>?site=<id> opens one website in
// one calm screen (no site = the main website, so old links still work). Numbers come from Search Console, GA4, PageSpeed Insights,
// URL Inspection and a scan of the site itself (crm-website Edge Function, nightly and on Refresh). Each number says
// where it came from; nothing is estimated. Deep details stay folded until opened.

const fmt = (n) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN'));
const short = (n) => (n == null ? '—' : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : fmt(Math.round(n)));
const pct = (a, b) => (a == null || !b ? null : Math.round((100 * (a - b)) / b));
const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
};
const path = (u) => { try { const x = new URL(u); return `${x.pathname}${x.search}` || '/'; } catch { return u; } };
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const cache = new Map();   // last overview per website: reopening is instant, then it refreshes quietly
const tcache = new Map();  // last chart data per website, same idea

// ---------------------------------------------------------------- small pieces
function Card({ title, value, note, tone, hint, onClick, dashed, spark, selected }) {
  const color = tone === 'good' ? '#1E7B34' : tone === 'bad' ? '#A42219' : 'var(--label-2)';
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag type={onClick ? 'button' : undefined} onClick={onClick} title={hint}
      aria-pressed={selected == null ? undefined : selected}
      className={`glass-card p-4 sm:p-5 flex flex-col gap-1 text-left ${onClick ? 'tile-link' : ''}`}
      style={{ ...(dashed ? { borderStyle: 'dashed' } : {}), ...(selected ? { boxShadow: 'inset 0 0 0 2px var(--accent)' } : {}) }}>
      <span className="flex flex-col gap-1 w-full">
        <span className="block text-[13px] text-glass-secondary">{title}</span>
        <span className="block text-[26px] font-semibold leading-tight text-glass-primary">{value}</span>
        {note && <span className="block text-[13px]" style={{ color }}>{note}</span>}
        {spark}
      </span>
    </Tag>
  );
}
const change = (cur, prev, { lowerIsBetter = false, suffix = '%' } = {}) => {
  if (cur == null || prev == null) return { note: null };
  if (suffix === '%') {
    const c = pct(cur, prev);
    if (c == null) return { note: null };
    return { note: `${c >= 0 ? '↑' : '↓'} ${Math.abs(c)}% vs previous 28 days`, tone: (c >= 0) !== lowerIsBetter ? 'good' : 'bad' };
  }
  const d = Math.round((cur - prev) * 10) / 10;
  if (!d) return { note: `Same as before (${prev})`, tone: 'muted' };
  const better = lowerIsBetter ? d < 0 : d > 0;
  return { note: `${better ? 'Better' : 'Worse'} · was ${prev}`, tone: better ? 'good' : 'bad' };
};
function Fold({ title, hint, children, open: start = false, id }) {
  return (
    <details className="glass-card group" open={start} data-fold={id}>
      <summary className="flex items-center justify-between gap-3 px-5 min-h-[52px] cursor-pointer list-none">
        <span className="font-semibold text-glass-primary">{title}{hint && <span className="font-normal text-glass-secondary"> · {hint}</span>}</span>
        <span className="text-[13px] text-[var(--accent)] group-open:hidden">Show</span>
        <span className="text-[13px] text-[var(--accent)] hidden group-open:inline">Hide</span>
      </summary>
      <div className="px-5 pb-5 pt-1 border-t border-[var(--hairline)]">{children}</div>
    </details>
  );
}
function Rows({ rows, cols, empty = 'Nothing yet.' }) {
  if (!rows?.length) return <p className="m-0 py-3 text-sm text-glass-secondary">{empty}</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm border-collapse min-w-[480px]">
        <thead><tr className="text-left text-xs text-glass-secondary">{cols.map((c) => <th key={c.k} className={`font-medium py-2 ${c.right ? 'text-right' : ''}`}>{c.label}</th>)}</tr></thead>
        <tbody>{rows.map((r, i) => (
          <tr key={i} className="border-t border-[var(--hairline)]">
            {cols.map((c) => <td key={c.k} className={`py-2.5 pr-2 ${c.right ? 'text-right' : ''} ${c.mono ? 'font-mono text-[13px]' : ''}`}>{c.render ? c.render(r) : r[c.k]}</td>)}
          </tr>))}</tbody>
      </table>
    </div>
  );
}
function PosChange({ pos, prev }) {
  if (pos == null) return '—';
  if (prev == null) return <span className="text-[12px] px-2 py-0.5 rounded-full" style={{ background: 'rgba(10,99,206,0.10)', color: '#0A63CE' }}>new</span>;
  const d = Math.round((prev - pos) * 10) / 10;
  if (!d) return <span className="text-[12px] px-2 py-0.5 rounded-full bg-[var(--surface-sunken)] text-glass-secondary">same</span>;
  return <span className="text-[12px] px-2 py-0.5 rounded-full" style={d > 0 ? { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' } : { background: 'rgba(192,39,29,0.10)', color: '#A42219' }}>{d > 0 ? '↑' : '↓'} {Math.abs(d)}</span>;
}
const Bars = (props) => <HBars {...props} />;
const rating = (r) => (r === 'fast' ? ['Good', '#1E7B34', 'rgba(30,123,52,0.10)'] : r === 'average' ? ['Needs work', '#8A5300', 'rgba(178,106,0,0.12)'] : r === 'slow' ? ['Poor', '#A42219', 'rgba(192,39,29,0.10)'] : ['No data', 'var(--label-2)', 'var(--surface-sunken)']);
const Chip = ({ r, children }) => { const [t, fg, bg] = rating(r); return <span className="text-[12px] px-2 py-0.5 rounded-full whitespace-nowrap" style={{ color: fg, background: bg }}>{children || t}</span>; };
const ISSUE = { no_title: 'No title', long_title: 'Title over ~60 characters', short_title: 'Very short title', no_description: 'No description',
  long_description: 'Description over ~160 characters', short_description: 'Short description', no_h1: 'No H1 heading', many_h1: 'More than one H1',
  no_canonical: 'No canonical link', noindex: 'Hidden from Google (noindex)', no_schema: 'No structured data', bad_schema: 'Broken structured data', unreachable: 'Did not load' };

// ---------------------------------------------------------------- tabs
const METRICS = [
  { k: 'clicks', label: 'Clicks', v: (r) => r.clicks, f: (v) => fmt(Math.round(v)) },
  { k: 'impressions', label: 'Seen', v: (r) => r.impressions, f: (v, axis) => (axis ? short(v) : fmt(Math.round(v))) },
  { k: 'ctr', label: 'Click rate', v: (r) => (r.ctr == null ? null : r.ctr * 100), f: (v) => `${Number(v).toFixed(axis2(v))}%` },
  { k: 'position', label: 'Position', v: (r) => r.position, f: (v) => Number(v).toFixed(1), invert: true },
];
function axis2(v) { return Math.abs(v) < 10 ? 1 : 0; }
const sum = (rows, k) => (rows || []).reduce((n, r) => n + (Number(r[k]) || 0), 0);
function periodValue(rows, k) {
  if (!rows?.length) return null;
  if (k === 'ctr') { const i = sum(rows, 'impressions'); return i ? (100 * sum(rows, 'clicks')) / i : null; }
  if (k === 'position') { const i = sum(rows, 'impressions'); return i ? rows.reduce((n, r) => n + (Number(r.position) || 0) * (Number(r.impressions) || 0), 0) / i : null; }
  return sum(rows, k);
}
function takeaway(m, cur, prev) {
  const a = periodValue(cur, m.k), b = periodValue(prev, m.k);
  if (a == null) return '';
  const best = [...(cur || [])].filter((r) => m.v(r) != null).sort((x, y) => (m.invert ? m.v(x) - m.v(y) : m.v(y) - m.v(x)))[0];
  const bestTxt = best ? ` Best day: ${new Date(`${best.d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' })} (${m.f(m.v(best))}).` : '';
  if (b == null || !b) return `Last 28 days: ${m.f(a)}.${bestTxt}`;
  if (m.k === 'position') { const d = Math.round((b - a) * 10) / 10; return `Average position ${a.toFixed(1)}, ${d > 0 ? `${d} places better` : d < 0 ? `${-d} places worse` : 'the same as'} than the 28 days before.${bestTxt}`; }
  if (m.k === 'ctr') { const d = Math.round((a - b) * 100) / 100; return `${a.toFixed(2)}% of people who saw you clicked, ${d >= 0 ? 'up' : 'down'} ${Math.abs(d).toFixed(2)} points.${bestTxt}`; }
  const c = Math.round((100 * (a - b)) / b);
  return `${m.label} ${c >= 0 ? 'up' : 'down'} ${Math.abs(c)}% vs the 28 days before (${m.f(b)} → ${m.f(a)}).${bestTxt}`;
}
const RANKS = [['top3', 'Top 3', 'great spot'], ['p1', '4–10', 'page 1'], ['p2', '11–20', 'page 2'], ['p3_5', '21–50', 'pages 3–5'], ['beyond', '50+', 'far back']];

function Overview({ o, t, live, go }) {
  const s = o.search || {}, v = o.visitors || {};
  const [metric, setMetric] = useState('clicks');
  const clicks = change(s.cur?.clicks, s.prev?.clicks), seen = change(s.cur?.impressions, s.prev?.impressions);
  const pos = change(s.cur?.position, s.prev?.position, { lowerIsBetter: true, suffix: '' });
  const users = change(v.cur?.users, v.prev?.users);
  const gaReady = Number(v.cur?.days || 0) > 0;
  const c = s.counts || {};
  const g = t?.gsc || {}, ga = t?.ga || {};
  const m = METRICS.find((x) => x.k === metric);
  const ranks = t?.ranks?.cur;
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
        <Card title="Clicks from Google" value={fmt(s.cur?.clicks)} {...clicks} hint="Search Console, last 28 days. Click to chart it." onClick={() => setMetric('clicks')} selected={metric === 'clicks'}
          spark={<Spark values={(g.cur || []).map((r) => r.clicks)} />} />
        <Card title="Seen on Google" value={short(s.cur?.impressions)} {...seen} hint="Times a page of yours showed in Google results. Click to chart it." onClick={() => setMetric('impressions')} selected={metric === 'impressions'}
          spark={<Spark values={(g.cur || []).map((r) => r.impressions)} />} />
        <Card title="Average position" value={s.cur?.position ?? '—'} {...pos} hint="Weighted by how often each result was seen; lower is better. Click to chart it." onClick={() => setMetric('position')} selected={metric === 'position'}
          spark={<Spark values={(g.cur || []).map((r) => r.position)} invert />} />
        <Card title="Visitors" value={gaReady ? fmt(v.cur?.users) : '—'} {...(gaReady ? users : { note: o.configured?.ga4 ? 'GA4 has no visits yet: fix' : 'Connect GA4: fix', tone: 'bad' })}
          dashed={!gaReady} onClick={gaReady ? undefined : () => go('edit')} hint="GA4 active users" spark={gaReady ? <Spark values={(ga.cur || []).map((r) => r.users)} /> : null} />
        <Card title="On the site now" value={live?.total ? fmt(live.total[0]?.users ?? 0) : '—'} note={live?.page?.[0] ? `Most on ${live.page[0].k}` : (gaReady ? 'Last 30 minutes' : 'Needs GA4')} tone="muted" />
      </div>

      <section className="glass-card p-5" data-section="trend">
        <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
          <div>
            <h2 className="m-0 text-base font-semibold text-glass-primary">Google, day by day</h2>
            <p className="m-0 text-[13px] text-glass-secondary">{t ? takeaway(m, g.cur, g.prev) : 'Loading…'}</p>
          </div>
          <div role="tablist" aria-label="What to chart" className="inline-flex p-0.5 rounded-[10px] bg-[var(--surface-sunken)]">
            {METRICS.map((x) => (
              <button key={x.k} role="tab" aria-selected={metric === x.k} type="button" onClick={() => setMetric(x.k)}
                className={`min-h-[32px] px-3 rounded-[8px] text-[13px] transition-colors ${metric === x.k ? 'bg-white shadow-sm font-semibold text-glass-primary' : 'text-glass-secondary'}`}>{x.label}</button>
            ))}
          </div>
        </div>
        <div className="mt-3"><Trend cur={g.cur} prev={g.prev} value={m.v} format={m.f} invert={m.invert} label={`${m.label} per day`} /></div>
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <TrendLegend prevShown={(g.prev || []).length > 0} />
          <span className="text-[12px] text-glass-secondary">{m.invert ? 'Higher on the chart = better position. ' : ''}Search Console runs about 3 days behind.</span>
        </div>
      </section>

      {(o.actions || []).length > 0 && (
        <section className="glass-card p-5" data-section="actions">
          <h2 className="m-0 mb-1 text-base font-semibold text-glass-primary">What to fix first</h2>
          {(o.actions || []).slice(0, 5).map((a) => (
            <div key={a.title} className="flex items-start justify-between gap-3 py-3 border-t border-[var(--hairline)] first-of-type:border-t-0">
              <div className="min-w-0"><div className="text-sm font-medium text-glass-primary">{a.title}</div><div className="text-[13px] text-glass-secondary">{a.detail}</div></div>
              <button type="button" className="shrink-0 text-sm font-medium text-[var(--accent)] min-h-[36px]" onClick={() => go(a.go, a.q)}>Open</button>
            </div>
          ))}
          {(o.actions || []).length > 5 && <Fold title={`${o.actions.length - 5} more`} id="more-actions">{o.actions.slice(5).map((a) => (
            <div key={a.title} className="py-2 text-sm"><span className="font-medium">{a.title}</span> <span className="text-glass-secondary">· {a.detail}</span></div>))}</Fold>}
        </section>
      )}

      <div className="grid gap-5" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))' }}>
        <section className="glass-card p-5">
          <h2 className="m-0 text-base font-semibold text-glass-primary">Where your searches rank</h2>
          <p className="m-0 mb-2 text-[13px] text-glass-secondary">How many searches show you at each position. Dashed outline = the 28 days before. Page 2 is the quickest win.</p>
          {ranks ? <Columns label="Searches by position" items={RANKS.map(([k, l, sub]) => ({ k: l, sub, v: Number(ranks[k] || 0), pv: t?.ranks?.prev ? Number(t.ranks.prev[k] || 0) : null,
            hint: k === 'p2' ? 'Click to see them' : 'Click to open searches', key: k }))}
            format={(x) => fmt(x)} prevLabel="Before" onPick={(x) => go('searches', null, x.key === 'p2' ? 'almost' : undefined)} />
            : <p className="m-0 text-sm text-glass-secondary">No Search Console data yet. Press Refresh.</p>}
        </section>
        <section className="glass-card p-5">
          <h2 className="m-0 mb-3 text-base font-semibold text-glass-primary">Best opportunities in Google</h2>
          <div className="grid gap-2.5" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))' }}>
            {[['almost', 'Almost on page 1', 'Position 8–20, seen 50+ times'], ['low_ctr', 'Seen a lot, rarely clicked', 'Top 10 but under 2% clicks'],
              ['dropping', 'Dropped 3+ places', 'vs the 28 days before'], ['new', 'New searches', 'Not seen before'], ['cannibal', 'Two pages competing', 'Same search, two of your pages']].map(([k, tt, h]) => (
              <button key={k} type="button" onClick={() => go('searches', null, k)} className="tile-link text-left rounded-xl border border-[var(--hairline)] p-3.5 bg-white/60">
                <div className="text-2xl font-semibold">{fmt(c[k])}</div><div className="text-sm font-medium">{tt}</div><div className="text-[12px] text-glass-secondary">{h}</div>
              </button>))}
          </div>
        </section>
      </div>

      <section className="glass-card p-5">
        <div className="flex items-baseline justify-between"><h2 className="m-0 text-base font-semibold text-glass-primary">What people search on Google</h2>
          <button type="button" className="text-sm text-[var(--accent)] min-h-[36px]" onClick={() => go('searches')}>See all {fmt(c.queries)}</button></div>
        <Rows rows={s.top_queries} empty="No Search Console data yet. Press Refresh." cols={[
          { k: 'query', label: 'Search', render: (r) => <button type="button" className="text-left hover:text-[var(--accent)]" onClick={() => go('searches', r.query)}>{r.query}</button> },
          { k: 'clicks', label: 'Clicks', right: true, render: (r) => fmt(r.clicks) },
          { k: 'impressions', label: 'Seen', right: true, render: (r) => fmt(r.impressions) }, { k: 'pos', label: 'Position', right: true },
          { k: 'chg', label: 'Change', right: true, render: (r) => <PosChange pos={r.pos} prev={r.prev_pos} /> }]} />
      </section>

      <Fold title="Top pages" hint="from Google" id="pages">
        <Rows rows={s.top_pages} cols={[{ k: 'page', label: 'Page', mono: true, render: (r) => path(r.page) }, { k: 'clicks', label: 'Clicks', right: true, render: (r) => fmt(r.clicks) },
          { k: 'pos', label: 'Position', right: true }, { k: 'chg', label: 'Change', right: true, render: (r) => <PosChange pos={r.pos} prev={r.prev_pos} /> }]} />
      </Fold>
      <Fold title="Visitors" hint={gaReady ? 'GA4, last 28 days' : 'waiting for GA4'} id="visitors">
        {!gaReady ? <p className="text-sm text-glass-secondary m-0 py-2">GA4 has not sent visits yet. Check the GA4 property in Connections &amp; keys.</p> : (
          <div className="flex flex-col gap-6 pt-2">
            <div><Trend cur={ga.cur} prev={ga.prev} value={(r) => r.users} format={(x) => fmt(Math.round(x))} label="Visitors per day" /><div className="mt-2"><TrendLegend prevShown={(ga.prev || []).length > 0} /></div></div>
            <div className="grid gap-6" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))' }}>
              <div><div className="text-[13px] text-glass-secondary mb-2">How they arrived</div><Bars items={v.channels || []} valueKey="sessions" labelKey="k" /></div>
              <div><div className="text-[13px] text-glass-secondary mb-2">Cities</div><Bars items={(v.cities || []).slice(0, 6)} valueKey="users" labelKey="city" /></div>
              <div className="text-sm flex flex-col gap-3">
                <div><div className="text-[13px] text-glass-secondary mb-2">Devices</div><Share items={(v.devices || []).slice(0, 3).map((d) => ({ k: d.k, v: d.users }))} unit="visitors" label="Visitors by device" /></div>
                <div><span className="text-glass-secondary">Engaged visits:</span> {v.cur?.engaged_rate ?? '—'}%</div>
                <div><span className="text-glass-secondary">Time on site per visitor:</span> {v.cur?.avg_engagement_s != null ? `${Math.floor(v.cur.avg_engagement_s / 60)}m ${v.cur.avg_engagement_s % 60}s` : '—'}</div>
                <div><span className="text-glass-secondary">New / returning:</span> {fmt(v.newret?.new)} / {fmt(v.newret?.returning)}</div>
                <div><span className="text-glass-secondary">Busiest:</span> {(v.busiest || []).map((b) => `${DOW[b.dow] || b.dow} ${b.hour}:00`).join(', ') || '—'}</div>
                <div><span className="text-glass-secondary">Actions taken:</span> {(v.events || []).slice(0, 4).map((e) => `${e.event} ${fmt(e.count)}`).join(' · ') || '—'}</div>
              </div>
            </div>
          </div>)}
      </Fold>
      <Fold title="Where Google shows you" hint="devices, countries, result types" id="where">
        <div className="flex flex-col gap-6 pt-2">
          <div><div className="text-[13px] text-glass-secondary mb-2">Clicks by device</div><Share items={(s.devices || []).slice(0, 3).map((d) => ({ k: d.k, v: d.clicks }))} unit="clicks" label="Clicks by device" /></div>
          <div className="grid gap-6" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))' }}>
            <div><div className="text-[13px] text-glass-secondary mb-2">Countries (clicks)</div><Bars items={s.countries || []} valueKey="clicks" labelKey="k" sub={(x) => `${short(x.impressions)} seen`} /></div>
            <div><div className="text-[13px] text-glass-secondary mb-2">Result types (times seen)</div>{(s.appearance || []).length ? <Bars items={s.appearance} valueKey="impressions" labelKey="k" /> : <p className="m-0 text-sm text-glass-secondary">Plain results only.</p>}</div>
          </div>
        </div>
      </Fold>
    </div>
  );
}

const FILTERS = [['all', 'All'], ['almost', 'Almost page 1'], ['low_ctr', 'Seen, not clicked'], ['dropping', 'Dropping'], ['new', 'New'],
  ['questions', 'Questions & costs'], ['nonbrand', 'Non-brand'], ['brand', 'Brand'], ['cannibal', 'Two pages competing']];
function Searches({ initialFilter, initialQ, siteId }) {
  const [filter, setFilter] = useState(initialFilter || 'all');
  const [q, setQ] = useState(initialQ || '');
  const [data, setData] = useState(null);
  const [openRow, setOpenRow] = useState('');
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => rpc('api_web_queries', { p_filter: filter, p_q: q.trim() || null, p_limit: 300, p_site: siteId }).then((d) => { if (live) setData(d); }).catch((e) => showToast(e.message, 'error')), q ? 250 : 0);
    return () => { live = false; clearTimeout(t); };
  }, [filter, q, siteId]);
  return (
    <section className="glass-card p-5 flex flex-col gap-3">
      <div className="flex flex-wrap gap-2" role="group" aria-label="Filter searches">
        {FILTERS.map(([k, l]) => (
          <button key={k} type="button" aria-pressed={filter === k} onClick={() => setFilter(k)}
            className={`min-h-[34px] px-3 rounded-full text-[13px] border ${filter === k ? 'bg-[#1C1C1E] text-white border-[#1C1C1E]' : 'bg-white border-[var(--border-default)] text-glass-primary'}`}>{l}</button>
        ))}
      </div>
      <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search the searches" aria-label="Search the searches" className="glass-input min-h-[38px] px-3 text-sm max-w-sm" />
      <div className="text-[13px] text-glass-secondary">{data ? `${fmt(data.total)} searches${data.total > (data.rows || []).length ? `, top ${fmt((data.rows || []).length)} shown` : ''}` : 'Loading…'} · Search Console, last 28 days vs the 28 before. Google hides very rare searches.</div>
      {(data?.rows || []).length > 1 && (
        <details open className="group rounded-xl border border-[var(--hairline)] bg-white/50">
          <summary className="flex items-center justify-between gap-3 px-4 min-h-[44px] cursor-pointer list-none">
            <span className="text-sm font-semibold text-glass-primary">Opportunity map <span className="font-normal text-glass-secondary">· each dot is a search; the shaded band is where a small push reaches page 1</span></span>
            <span className="text-[13px] text-[var(--accent)] group-open:hidden">Show</span><span className="text-[13px] text-[var(--accent)] hidden group-open:inline">Hide</span>
          </summary>
          <div className="px-4 pb-4"><OpportunityMap rows={data.rows} selected={openRow} onPick={(r) => {
            setOpenRow(r.query);
            requestAnimationFrame(() => document.getElementById(`q-${encodeURIComponent(r.query)}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' }));
          }} /></div>
        </details>)}
      <div className="overflow-x-auto">
        <table className="w-full text-sm border-collapse min-w-[560px]">
          <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-2">Search</th><th className="font-medium text-right">Clicks</th><th className="font-medium text-right">Seen</th><th className="font-medium text-right">Click rate</th><th className="font-medium text-right">Position</th><th className="font-medium text-right">Change</th></tr></thead>
          <tbody>{(data?.rows || []).map((r) => (
            <FragmentRow key={r.query} r={r} open={openRow === r.query} onToggle={() => setOpenRow(openRow === r.query ? '' : r.query)} />
          ))}</tbody>
        </table>
      </div>
    </section>
  );
}
function FragmentRow({ r, open, onToggle }) {
  const flags = [r.almost && 'almost page 1', r.low_ctr && 'low clicks', r.dropping && 'dropping', r.pages >= 2 && `${r.pages} pages`].filter(Boolean);
  return (<>
    <tr id={`q-${encodeURIComponent(r.query)}`} className={`border-t border-[var(--hairline)] cursor-pointer hover:bg-[rgba(118,118,128,0.05)] ${open ? 'bg-[rgba(10,99,206,0.05)]' : ''}`} onClick={onToggle}>
      <td className="py-2.5 pr-2"><span className="text-glass-primary">{r.query}</span>{flags.length > 0 && <span className="ml-2 text-[11px] text-glass-secondary">{flags.join(' · ')}</span>}</td>
      <td className="text-right">{fmt(r.clicks)}</td><td className="text-right text-glass-secondary">{fmt(r.impressions)}</td>
      <td className="text-right">{r.ctr != null ? `${(r.ctr * 100).toFixed(1)}%` : '—'}</td><td className="text-right">{r.pos}</td>
      <td className="text-right"><PosChange pos={r.pos} prev={r.prev_pos} /></td>
    </tr>
    {open && (
      <tr><td colSpan={6} className="pb-3 pt-1 text-[13px] text-glass-secondary">
        {(r.page_list || []).length ? (r.page_list || []).map((p) => <div key={p.page} className="flex justify-between gap-3 py-0.5"><span className="font-mono truncate">{path(p.page)}</span><span className="shrink-0">{fmt(p.impressions)} seen · pos {p.position}</span></div>)
          : 'Page details appear after the next refresh.'}
        {r.prev_clicks != null && <div className="mt-1">Before: {fmt(r.prev_clicks)} clicks, {fmt(r.prev_impressions)} seen, position {r.prev_pos}</div>}
      </td></tr>)}
  </>);
}

function Ai({ o, canRun, reload, siteId }) {
  const ai = o.ai || {}, bots = ai.robots?.bots || {};
  const [busy, setBusy] = useState(false);
  const upload = async (file) => {
    if (!file) return;
    setBusy(true);
    try {
      const { copilotRows } = await import('../utils/csv');
      const parsed = copilotRows(await file.text());
      if (!parsed.rows.length) throw new Error('No rows found. Use the CSV exported from Bing Webmaster Tools > AI Performance.');
      const r = await rpc('api_web_copilot_upload', { p_kind: parsed.kind, p_rows: parsed.rows, p_site: siteId });
      showToast(`${fmt(r.saved)} ${parsed.kind === 'page' ? 'pages' : 'grounding queries'} saved`, 'success'); reload();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const total = (ai.tools || []).reduce((n, t) => n + Number(t.sessions || 0), 0);
  return (
    <div className="flex flex-col gap-5">
      <section className="glass-card p-5">
        <h2 className="m-0 mb-1 text-base font-semibold">Visits from AI assistants</h2>
        <p className="m-0 mb-3 text-[13px] text-glass-secondary">People who clicked a link to the site inside ChatGPT, Perplexity, Gemini, Copilot, Claude and others (GA4). No AI tool shares what people typed.</p>
        {(ai.tools || []).length === 0 ? <p className="m-0 text-sm text-glass-secondary">{Number(o.visitors?.cur?.days || 0) ? 'No AI visits in the last 28 days.' : 'Waiting for GA4 data.'}</p> : (<>
          <div className="text-[28px] font-semibold mb-2">{fmt(total)} <span className="text-sm font-normal text-glass-secondary">visits</span></div>
          <Rows rows={ai.tools} cols={[{ k: 'tool', label: 'Assistant' }, { k: 'sessions', label: 'Visits', right: true, render: (r) => fmt(r.sessions) },
            { k: 'prev_sessions', label: 'Before', right: true, render: (r) => fmt(r.prev_sessions) }, { k: 'key_events', label: 'Actions', right: true, render: (r) => fmt(r.key_events) }]} />
          {(ai.pages || []).length > 0 && <div className="mt-3"><div className="text-[13px] text-glass-secondary mb-1">Pages they landed on</div>
            {ai.pages.map((p) => <div key={p.page} className="flex justify-between gap-3 py-1 text-sm"><span className="font-mono truncate">{p.page}</span><span className="text-glass-secondary shrink-0">{fmt(p.sessions)} · {p.tools}</span></div>)}</div>}
        </>)}
      </section>

      <section className="glass-card p-5">
        <h2 className="m-0 mb-1 text-base font-semibold">Microsoft Copilot citations</h2>
        <p className="m-0 mb-3 text-[13px] text-glass-secondary">From Bing Webmaster Tools &gt; AI Performance. Bing has no API for this yet, so upload its CSV export (Grounding queries or Pages). Grounding queries are the searches Copilot ran, not what people typed.</p>
        {canRun && (
          <label className="inline-flex items-center gap-2 min-h-[38px] px-3 rounded-[9px] border border-[var(--border-default)] bg-white text-[13px] cursor-pointer">
            <Icon name="plus" size={15} />{busy ? 'Reading…' : 'Upload CSV'}
            <input type="file" accept=".csv,text/csv" className="sr-only" onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ''; }} />
          </label>)}
        {ai.copilot?.uploaded_at && <div className="mt-3 text-[13px] text-glass-secondary">Uploaded {ago(ai.copilot.uploaded_at)} · {fmt(ai.copilot.total)} citations</div>}
        {(ai.copilot?.queries || []).length > 0 && <div className="mt-2"><Bars items={ai.copilot.queries} valueKey="citations" labelKey="k" /></div>}
        {(ai.copilot?.pages || []).length > 0 && <div className="mt-4"><div className="text-[13px] text-glass-secondary mb-1">Most cited pages</div><Bars items={ai.copilot.pages.map((p) => ({ ...p, k: path(p.k) }))} valueKey="citations" labelKey="k" /></div>}
      </section>

      <section className="glass-card p-5">
        <h2 className="m-0 mb-1 text-base font-semibold">Google AI Overviews and AI Mode</h2>
        <p className="m-0 text-[13px] text-glass-secondary">Search Console shows how often your pages appeared in Google's AI answers (views only, no clicks or queries). These views are already included in "Seen on Google".</p>
        <a className="inline-block mt-2 text-sm font-medium" href="https://search.google.com/search-console/performance/search-analytics" target="_blank" rel="noreferrer">Open the report in Search Console</a>
      </section>

      <Fold title="Ready for AI search?" hint="crawlers, llms.txt, structured data" open id="ai-ready">
        {!ai.robots ? <p className="m-0 py-2 text-sm text-glass-secondary">Not checked yet. Press Refresh.</p> : (<>
          <div className="text-[13px] text-glass-secondary mb-2">robots.txt rules for each crawler</div>
          <div className="grid gap-2" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))' }}>
            {Object.entries(bots).map(([b, st]) => <div key={b} className="flex items-center justify-between gap-2 text-sm py-1"><span>{b}</span><Chip r={st === 'allowed' ? 'fast' : 'slow'}>{st === 'allowed' ? 'Allowed' : 'Blocked'}</Chip></div>)}
          </div>
          <div className="mt-3 text-sm flex flex-col gap-1">
            <div><span className="text-glass-secondary">llms.txt:</span> {ai.llms?.status === 'found' ? 'Found' : 'Not found (optional)'}</div>
            <div><span className="text-glass-secondary">Pages with structured data:</span> {ai.schema ? `${fmt(ai.schema.with_schema)} of ${fmt(ai.schema.pages)}` : '—'}{(ai.schema?.types || []).length > 0 && <span className="text-glass-secondary"> ({ai.schema.types.slice(0, 8).join(', ')})</span>}</div>
          </div>
        </>)}
      </Fold>
    </div>
  );
}

function Health({ o }) {
  const h = o.health || {}, scan = h.scan || {};
  const bySpeed = useMemo(() => {
    const m = new Map();
    for (const r of o.speed || []) { if (!m.has(r.url)) m.set(r.url, {}); m.get(r.url)[r.strategy] = r; }
    return [...m.entries()];
  }, [o.speed]);
  return (
    <div className="flex flex-col gap-5">
      <section className="glass-card p-5">
        <h2 className="m-0 mb-1 text-base font-semibold">Speed for real visitors</h2>
        <p className="m-0 mb-3 text-[13px] text-glass-secondary">Chrome users' 75th percentile (PageSpeed Insights). Good: LCP under 2.5 s, INP under 200 ms, CLS under 0.1.</p>
        {bySpeed.length === 0 ? <p className="m-0 text-sm text-glass-secondary">Not checked yet. Press Refresh.</p> : bySpeed.map(([url, st]) => (
          <div key={url} className="py-3 border-t border-[var(--hairline)] first-of-type:border-t-0">
            <div className="font-mono text-[13px] mb-2">{path(url)}</div>
            <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))' }}>
              {['mobile', 'desktop'].map((k) => { const r = st[k]; if (!r) return null; return (
                <div key={k} className="text-sm flex flex-col gap-1">
                  <div className="flex items-center gap-2"><span className="font-medium capitalize">{k === 'mobile' ? 'Phone' : 'Computer'}</span><Chip r={r.overall}>{r.overall ? undefined : 'No real-user data'}</Chip>
                    {r.scores?.performance != null && <span className="text-glass-secondary">· score {r.scores.performance}</span>}</div>
                  <div className="grid gap-2 mt-1">
                    <Vital name="Main content shows (LCP)" value={r.field?.lcp ? r.field.lcp.p75 / 1000 : null} good={2.5} poor={4} unit=" s" digits={1} />
                    <Vital name="Reacts to taps (INP)" value={r.field?.inp?.p75 ?? null} good={200} poor={500} unit=" ms" />
                    <Vital name="Layout stays still (CLS)" value={r.field?.cls?.p75 ?? null} good={0.1} poor={0.25} unit="" digits={2} />
                  </div>
                  {(r.fixes || []).length > 0 && <div className="text-[13px] text-glass-secondary">Fix first: {r.fixes.slice(0, 2).map((f) => f.title).join('; ')}</div>}
                </div>); })}
            </div>
          </div>))}
      </section>

      <section className="glass-card p-5">
        <h2 className="m-0 mb-3 text-base font-semibold">In Google's index</h2>
        <Rows rows={h.index} empty="Not checked yet. Press Refresh." cols={[
          { k: 'url', label: 'Key page', mono: true, render: (r) => path(r.url) },
          { k: 'coverage', label: 'Google says', render: (r) => <span style={{ color: r.verdict === 'PASS' ? '#1E7B34' : '#8A5300' }}>{r.coverage || r.verdict || '—'}</span> },
          { k: 'last_crawl', label: 'Last visit by Google', render: (r) => (r.last_crawl ? ago(r.last_crawl) : '—') },
          { k: 'rich', label: 'Rich results', render: (r) => (r.rich?.types?.length ? r.rich.types.join(', ') : '—') }]} />
        {(h.sitemaps?.list || []).length > 0 && <div className="mt-3 text-[13px] text-glass-secondary">Sitemaps: {h.sitemaps.list.map((s) => `${path(s.path)} (${fmt(s.submitted)} pages${s.errors ? `, ${s.errors} errors` : ''})`).join(' · ')}</div>}
      </section>

      <section className="glass-card p-5">
        <h2 className="m-0 mb-1 text-base font-semibold">Site check</h2>
        <p className="m-0 mb-3 text-[13px] text-glass-secondary">Every page in the sitemap, read like a search engine would.{scan.scanned_at ? ` Last checked ${ago(scan.scanned_at)}.` : ''}</p>
        {!scan.pages ? <p className="m-0 text-sm text-glass-secondary">Not checked yet. Press Refresh.</p> : (<>
          <div className="grid gap-3 mb-3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))' }}>
            <div><div className="text-[13px] text-glass-secondary">Pages</div><div className="text-xl font-semibold">{fmt(scan.pages)}</div></div>
            <div><div className="text-[13px] text-glass-secondary">Errors</div><div className="text-xl font-semibold" style={{ color: scan.errors ? '#A42219' : undefined }}>{fmt(scan.errors)}</div></div>
            <div><div className="text-[13px] text-glass-secondary">Slow (over 2 s)</div><div className="text-xl font-semibold">{fmt(scan.slow)}</div></div>
            <div><div className="text-[13px] text-glass-secondary">Home page</div><div className="text-xl font-semibold">{h.home ? `${h.home.status} · ${h.home.ms} ms` : '—'}</div></div>
          </div>
          {Object.keys(scan.issues || {}).length > 0 && <Bars items={Object.entries(scan.issues).map(([k, n]) => ({ k: ISSUE[k] || k, n })).sort((a, b) => b.n - a.n)} valueKey="n" labelKey="k" />}
        </>)}
      </section>
      {(scan.broken || []).length > 0 && <Fold title="Broken links" hint={`${scan.broken.length} targets`} id="broken">
        <Rows rows={scan.broken} cols={[{ k: 'url', label: 'Link to', mono: true, render: (r) => path(r.url) }, { k: 'status', label: 'Answer', right: true, render: (r) => r.status || 'no answer' },
          { k: 'on_pages', label: 'On pages', right: true }, { k: 'example', label: 'e.g. on', mono: true, render: (r) => path(r.example) }]} /></Fold>}
      {(scan.pages_with_issues || []).length > 0 && <Fold title="Pages to fix" hint={`${scan.pages_with_issues.length} pages`} id="page-issues">
        {scan.pages_with_issues.map((p) => <div key={p.url} className="py-2 border-t border-[var(--hairline)] first-of-type:border-t-0 text-sm">
          <div className="font-mono text-[13px]">{path(p.url)} {p.status >= 400 && <span style={{ color: '#A42219' }}>· {p.status}</span>}</div>
          <div className="text-glass-secondary text-[13px]">{(p.issues || []).map((i) => ISSUE[i] || i).join(' · ')}</div></div>)}</Fold>}
    </div>
  );
}

function Leads({ o }) {
  const l = o.leads;
  if (!l) return (
    <section className="glass-card p-5 text-sm text-glass-secondary">
      <h2 className="m-0 mb-1 text-base font-semibold text-glass-primary">No enquiry form linked yet</h2>
      Leads show here when this website's enquiry form sends enquiries to the CRM. Then add the form's source name under Edit website › More options › Lead source names.
    </section>);
  const c = change(l.cur, l.prev);
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
        <Card title="Website leads · 28 days" value={fmt(l.cur)} {...c} />
        <Card title="Admissions from them" value={fmt(l.admissions)} note="Marked as admission in Leads" tone="muted" />
        <Card title="Visitors who became leads" value={o.visitors?.cur?.users ? `${((100 * l.cur) / o.visitors.cur.users).toFixed(1)}%` : '—'} note={o.visitors?.cur?.users ? 'Leads ÷ GA4 visitors' : 'Needs GA4'} tone="muted" />
      </div>
      <section className="glass-card p-5"><h2 className="m-0 mb-3 text-base font-semibold">Where they came from</h2><Bars items={l.by_source || []} valueKey="n" labelKey="source" /></section>
      <section className="glass-card p-5"><h2 className="m-0 mb-1 text-base font-semibold">Per week</h2><p className="m-0 mb-2 text-[13px] text-glass-secondary">Website leads by the week they arrived.</p>
        {(l.weekly || []).length ? <Columns label="Website leads per week" items={(l.weekly || []).map((w) => ({ k: new Date(w.week).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }), sub: 'week of', v: Number(w.n) || 0 }))} />
          : <p className="m-0 text-sm text-glass-secondary">No website leads yet.</p>}</section>
      <p className="m-0 text-[13px] text-glass-secondary">To see which page and which Google search brought each lead, the website form needs to send the page address and UTM tags with the enquiry.</p>
    </div>
  );
}

// ---------------------------------------------------------------- page
const TABS = [['overview', 'Overview'], ['searches', 'Google searches'], ['ai', 'AI visibility'], ['health', 'Speed & health'], ['leads', 'Leads']];

// #/website = all websites; #/website/<tab>?site=<id> = one website (an old link without a site opens the main website).
export default function Website() {
  const route = useRoute();
  const one = Boolean(route.params.site) || TABS.some(([k]) => k === route.section);
  return one ? <SiteDetail key={route.params.site || 'main'} siteId={route.params.site || null} route={route} /> : <SitesHome />;
}

function SiteDetail({ siteId, route }) {
  const key = siteId || 'main';
  const tab = TABS.some(([k]) => k === route.section) ? route.section : 'overview';
  const { d: list, load: loadList } = useSites();
  const [o, setO] = useState(cache.get(key) || null);
  const [t, setT] = useState(tcache.get(key) || null);
  const [err, setErr] = useState('');
  const [access, setAccess] = useState(null);
  const [live, setLive] = useState(null);
  const [running, setRunning] = useState('');
  const [editing, setEditing] = useState(false);
  const load = useCallback(async () => {
    rpc('api_web_trend', { p_site: siteId }).then((d) => { tcache.set(key, d); setT(d); }).catch(() => {});   // charts are extra: the page works without them
    try { const d = await rpc('api_web_overview', { p_site: siteId }); cache.set(key, d); setO(d); setErr(''); } catch (e) { setErr(e.message); }
  }, [siteId, key]);
  useEffect(() => { load(); rpc('api_web_access').then(setAccess).catch(() => {}); }, [load]);
  // On the site now: GA4 realtime, every minute while this screen is visible.
  useEffect(() => {
    if (!o?.configured?.ga4) return undefined;
    let stop = false;
    const tick = () => { if (document.visibilityState === 'visible') edge({ jobs: ['live'], site: o.site_id }).then((r) => { if (!stop) setLive(r.live); }).catch(() => {}); };
    tick(); const iv = setInterval(tick, 60000);
    return () => { stop = true; clearInterval(iv); };
  }, [o?.configured?.ga4, o?.site_id]);
  const go = (to, q, filter) => {
    if (to === 'connections' || to === 'edit') { if (access?.is_admin && me) setEditing(true); else navigate('connections'); return; }
    if (to === 'speed') to = 'health';
    navigate('website', to, { site: siteId || undefined, ...(q ? { q } : {}), ...(filter ? { f: filter } : {}) });
  };
  const refresh = async () => {
    const problems = await collect(o?.site_id || siteId, (label) => setRunning(label));
    await load(); loadList();
    setRunning('');
    if (problems.length) showToast(problems[0], 'error'); else showToast('Website data is up to date', 'success');
  };
  const lastRun = o ? Object.values(o.runs || {}).map((r) => r.at).sort().pop() : null;
  const sites = list?.sites || [];
  const me = sites.find((x) => x.id === (o?.site_id || siteId)) || (o ? { id: o.site_id, name: o.site_name, url: o.site, color: '#0A63CE' } : null);
  const ga = Number(o?.visitors?.cur?.days || 0);

  return (
    <div className="flex flex-col gap-4" data-testid="site-detail">
      <nav className="flex items-center gap-2 min-w-0" aria-label="Websites">
        <button type="button" onClick={() => navigate('website')} className="inline-flex items-center gap-1 min-h-[34px] pr-1 text-[13px] font-medium text-[var(--accent)] shrink-0"><Icon name="chevronLeft" size={15} />All websites</button>
        {sites.length > 1 && <div className="ws-switch min-w-0" role="list">{sites.filter((x) => x.url).map((x) => (
          <button key={x.id} type="button" role="listitem" aria-current={x.id === me?.id ? 'page' : undefined} onClick={() => navigate('website', tab === 'overview' ? '' : tab, { site: x.id })}>
            <span className="ws-dot" style={{ background: x.color }} />{x.name}</button>))}</div>}
      </nav>
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          {me && <SiteMark s={me} size={44} />}
          <div className="min-w-0">
            <h1 className="m-0 text-[24px] sm:text-[26px] font-semibold tracking-tight text-glass-primary truncate">{o?.site_name || me?.name || 'Website'}</h1>
            <p className="m-0 text-sm text-glass-secondary">{o?.site ? <a href={o.site} target="_blank" rel="noreferrer noopener" className="text-glass-secondary hover:underline">{hostOf(o.site)}</a> : '—'} · last 28 days vs the 28 before · updated {ago(lastRun)}</p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
          {o && <span className="px-2.5 py-1 rounded-full" style={o.configured?.gsc ? { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' } : { background: 'rgba(178,106,0,0.12)', color: '#8A5300' }}>Search Console {o.configured?.gsc ? 'connected' : 'not connected'}</span>}
          {o && <span className="px-2.5 py-1 rounded-full" style={ga ? { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' } : { background: 'rgba(178,106,0,0.12)', color: '#8A5300' }}>GA4 {ga ? 'connected' : o.configured?.ga4 ? 'no data' : 'not connected'}</span>}
          {access?.is_admin && me && <button type="button" onClick={() => setEditing(true)} className="glass-btn-ghost min-h-[36px] px-3 text-[13px] inline-flex items-center gap-1.5"><Icon name="settings" size={14} />Edit website</button>}
          {access?.can_run && <button type="button" disabled={!!running} onClick={refresh} className="glass-btn min-h-[36px] px-3.5 text-[13px] inline-flex items-center gap-1.5"><Icon name="refresh" size={14} />{running ? `${running}…` : 'Refresh'}</button>}
        </div>
      </div>
      <div role="tablist" aria-label="Website sections" className="flex gap-1 border-b border-[var(--hairline)] overflow-x-auto" style={{ scrollbarWidth: 'none' }}>
        {TABS.map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} type="button" onClick={() => navigate('website', k === 'overview' ? '' : k, { site: siteId || undefined })}
            className={`min-h-[42px] px-3.5 -mb-px border-b-2 text-sm whitespace-nowrap ${tab === k ? 'border-[var(--accent)] text-[var(--accent)] font-semibold' : 'border-transparent text-glass-secondary'}`}>{l}</button>
        ))}
      </div>
      {err && !o && <div role="alert" className="glass-card p-5 text-sm">{err} <button type="button" className="text-[var(--accent)] font-medium ml-2" onClick={load}>Try again</button></div>}
      {!o && !err && <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>}
      {o && !o.configured?.gsc && !o.configured?.ga4 && tab === 'overview' && (
        <div className="glass-card p-4 text-sm flex flex-wrap items-center justify-between gap-3" style={{ background: 'rgba(255,149,0,0.08)' }}>
          <span className="min-w-0">Search Console and GA4 are not connected for this website yet, so only the site check and speed are shown.</span>
          {access?.is_admin && <button type="button" className="lp-btn lp-btn-sm lp-btn-primary" onClick={() => setEditing(true)}>Connect Google</button>}
        </div>)}
      {o && tab === 'overview' && <Overview o={o} t={t} live={live} go={go} />}
      {o && tab === 'searches' && <Searches key={`${route.params.f || ''}|${route.params.q || ''}`} siteId={siteId} initialFilter={route.params.f} initialQ={route.params.q} />}
      {o && tab === 'ai' && <Ai o={o} canRun={access?.can_run} reload={load} siteId={siteId} />}
      {o && tab === 'health' && <Health o={o} />}
      {o && tab === 'leads' && <Leads o={o} />}
      <p className="m-0 text-xs text-glass-secondary">Sources: Google Search Console, Google Analytics 4, PageSpeed Insights (Chrome UX Report + Lighthouse), Search Console URL Inspection, Bing Webmaster Tools export, and a direct check of the site.</p>
      {editing && me && <SiteSheet site={me} info={list} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); showToast('Saved', 'success'); load(); loadList(); }} />}
    </div>
  );
}
