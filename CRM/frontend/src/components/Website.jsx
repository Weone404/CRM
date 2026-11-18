import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { navigate, useRoute } from '../utils/route';
import Icon from './icons';

// Growth > Website: weoneaviation.in in one calm screen. Numbers come from Search Console, GA4, PageSpeed Insights,
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

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function edge(jobs) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/crm-website`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify({ jobs }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || (res.status === 404 ? 'The website data service is not deployed yet' : `Request failed (${res.status})`));
  return out;
}

let cache = null;   // last overview: reopening the section is instant, then it refreshes quietly

// ---------------------------------------------------------------- small pieces
function Card({ title, value, note, tone, hint, onClick, dashed }) {
  const color = tone === 'good' ? '#1E7B34' : tone === 'bad' ? '#A42219' : 'var(--label-2)';
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag type={onClick ? 'button' : undefined} onClick={onClick} title={hint}
      className={`glass-card p-4 sm:p-5 flex flex-col gap-1 text-left ${onClick ? 'tile-link' : ''}`} style={dashed ? { borderStyle: 'dashed' } : undefined}>
      <span className="text-[13px] text-glass-secondary">{title}</span>
      <span className="text-[26px] font-semibold leading-tight text-glass-primary">{value}</span>
      {note && <span className="text-[13px]" style={{ color }}>{note}</span>}
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
function Bars({ items, valueKey, labelKey, max }) {
  const m = max || Math.max(1, ...items.map((x) => Number(x[valueKey]) || 0));
  return (
    <div className="flex flex-col gap-2">{items.map((x, i) => (
      <div key={i} className="flex flex-col gap-1">
        <div className="flex justify-between gap-3 text-sm"><span className="truncate text-glass-primary">{x[labelKey]}</span><span className="text-glass-secondary shrink-0">{fmt(x[valueKey])}</span></div>
        <div className="h-1.5 rounded bg-[var(--surface-sunken)] overflow-hidden"><div className="h-1.5 rounded bg-[var(--accent)]" style={{ width: `${Math.round((100 * (Number(x[valueKey]) || 0)) / m)}%` }} /></div>
      </div>))}</div>
  );
}
function Spark({ points, k }) {
  if (!points?.length) return null;
  const vals = points.map((p) => Number(p[k]) || 0), max = Math.max(1, ...vals), w = 100 / vals.length;
  return (
    <svg viewBox="0 0 100 24" preserveAspectRatio="none" className="w-full h-12" role="img" aria-label={`Daily ${k}`}>
      {vals.map((v, i) => <rect key={i} x={i * w + w * 0.15} width={w * 0.7} y={24 - (22 * v) / max} height={(22 * v) / max} rx="0.6" fill="var(--accent)" opacity="0.75" />)}
    </svg>
  );
}
const rating = (r) => (r === 'fast' ? ['Good', '#1E7B34', 'rgba(30,123,52,0.10)'] : r === 'average' ? ['Needs work', '#8A5300', 'rgba(178,106,0,0.12)'] : r === 'slow' ? ['Poor', '#A42219', 'rgba(192,39,29,0.10)'] : ['No data', 'var(--label-2)', 'var(--surface-sunken)']);
const Chip = ({ r, children }) => { const [t, fg, bg] = rating(r); return <span className="text-[12px] px-2 py-0.5 rounded-full whitespace-nowrap" style={{ color: fg, background: bg }}>{children || t}</span>; };
const ISSUE = { no_title: 'No title', long_title: 'Title over ~60 characters', short_title: 'Very short title', no_description: 'No description',
  long_description: 'Description over ~160 characters', short_description: 'Short description', no_h1: 'No H1 heading', many_h1: 'More than one H1',
  no_canonical: 'No canonical link', noindex: 'Hidden from Google (noindex)', no_schema: 'No structured data', bad_schema: 'Broken structured data', unreachable: 'Did not load' };

// ---------------------------------------------------------------- tabs
function Overview({ o, live, go }) {
  const s = o.search || {}, v = o.visitors || {};
  const clicks = change(s.cur?.clicks, s.prev?.clicks), seen = change(s.cur?.impressions, s.prev?.impressions);
  const pos = change(s.cur?.position, s.prev?.position, { lowerIsBetter: true, suffix: '' });
  const users = change(v.cur?.users, v.prev?.users);
  const gaReady = Number(v.cur?.days || 0) > 0;
  const c = s.counts || {};
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
        <Card title="Clicks from Google" value={fmt(s.cur?.clicks)} {...clicks} hint="Search Console, last 28 days" />
        <Card title="Seen on Google" value={short(s.cur?.impressions)} {...seen} hint="Times a page of yours showed in Google results" />
        <Card title="Average position" value={s.cur?.position ?? '—'} {...pos} hint="Weighted by how often each result was seen; lower is better" />
        <Card title="Visitors" value={gaReady ? fmt(v.cur?.users) : '—'} {...(gaReady ? users : { note: o.configured?.ga4 ? 'GA4 has no visits yet: fix' : 'Connect GA4: fix', tone: 'bad' })}
          dashed={!gaReady} onClick={gaReady ? undefined : () => navigate('connections')} hint="GA4 active users" />
        <Card title="On the site now" value={live?.total ? fmt(live.total[0]?.users ?? 0) : '—'} note={live?.page?.[0] ? `Most on ${live.page[0].k}` : (gaReady ? 'Last 30 minutes' : 'Needs GA4')} tone="muted" />
      </div>

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

      <section className="glass-card p-5">
        <h2 className="m-0 mb-3 text-base font-semibold text-glass-primary">Best opportunities in Google</h2>
        <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
          {[['almost', 'Almost on page 1', 'Position 8–20, seen 50+ times'], ['low_ctr', 'Seen a lot, rarely clicked', 'Top 10 but under 2% clicks'],
            ['dropping', 'Dropped 3+ places', 'vs the 28 days before'], ['new', 'New searches', 'Not seen before'], ['cannibal', 'Two pages competing', 'Same search, two of your pages']].map(([k, t, h]) => (
            <button key={k} type="button" onClick={() => go('searches', null, k)} className="tile-link text-left rounded-xl border border-[var(--hairline)] p-4 bg-white/60">
              <div className="text-2xl font-semibold">{fmt(c[k])}</div><div className="text-sm font-medium">{t}</div><div className="text-[12px] text-glass-secondary">{h}</div>
            </button>))}
        </div>
      </section>

      <section className="glass-card p-5">
        <div className="flex items-baseline justify-between"><h2 className="m-0 text-base font-semibold text-glass-primary">What people search on Google</h2>
          <button type="button" className="text-sm text-[var(--accent)] min-h-[36px]" onClick={() => go('searches')}>See all {fmt(c.queries)}</button></div>
        <Rows rows={s.top_queries} empty="No Search Console data yet. Press Refresh." cols={[
          { k: 'query', label: 'Search' }, { k: 'clicks', label: 'Clicks', right: true, render: (r) => fmt(r.clicks) },
          { k: 'impressions', label: 'Seen', right: true, render: (r) => fmt(r.impressions) }, { k: 'pos', label: 'Position', right: true },
          { k: 'chg', label: 'Change', right: true, render: (r) => <PosChange pos={r.pos} prev={r.prev_pos} /> }]} />
        {s.daily?.length > 0 && <div className="mt-3"><div className="text-[12px] text-glass-secondary mb-1">Clicks per day</div><Spark points={s.daily} k="clicks" /></div>}
      </section>

      <Fold title="Top pages" hint="from Google" id="pages">
        <Rows rows={s.top_pages} cols={[{ k: 'page', label: 'Page', mono: true, render: (r) => path(r.page) }, { k: 'clicks', label: 'Clicks', right: true, render: (r) => fmt(r.clicks) },
          { k: 'pos', label: 'Position', right: true }, { k: 'chg', label: 'Change', right: true, render: (r) => <PosChange pos={r.pos} prev={r.prev_pos} /> }]} />
      </Fold>
      <Fold title="Visitors" hint={gaReady ? 'GA4, last 28 days' : 'waiting for GA4'} id="visitors">
        {!gaReady ? <p className="text-sm text-glass-secondary m-0 py-2">GA4 has not sent visits yet. Check the GA4 property in Connections &amp; keys.</p> : (
          <div className="grid gap-6" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))' }}>
            <div><div className="text-[13px] text-glass-secondary mb-2">How they arrived</div><Bars items={v.channels || []} valueKey="sessions" labelKey="k" /></div>
            <div><div className="text-[13px] text-glass-secondary mb-2">Cities</div><Bars items={(v.cities || []).slice(0, 6)} valueKey="users" labelKey="city" /></div>
            <div className="text-sm flex flex-col gap-1.5">
              <div><span className="text-glass-secondary">Engaged visits:</span> {v.cur?.engaged_rate ?? '—'}%</div>
              <div><span className="text-glass-secondary">Time on site per visitor:</span> {v.cur?.avg_engagement_s != null ? `${Math.floor(v.cur.avg_engagement_s / 60)}m ${v.cur.avg_engagement_s % 60}s` : '—'}</div>
              <div><span className="text-glass-secondary">New / returning:</span> {fmt(v.newret?.new)} / {fmt(v.newret?.returning)}</div>
              <div><span className="text-glass-secondary">Devices:</span> {(v.devices || []).map((d) => `${d.k} ${fmt(d.users)}`).join(' · ') || '—'}</div>
              <div><span className="text-glass-secondary">Busiest:</span> {(v.busiest || []).map((b) => `${DOW[b.dow] || b.dow} ${b.hour}:00`).join(', ') || '—'}</div>
              <div><span className="text-glass-secondary">Actions taken:</span> {(v.events || []).slice(0, 4).map((e) => `${e.event} ${fmt(e.count)}`).join(' · ') || '—'}</div>
            </div>
          </div>)}
      </Fold>
      <Fold title="Where Google shows you" hint="devices, countries, result types" id="where">
        <div className="grid gap-6" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))' }}>
          <div><div className="text-[13px] text-glass-secondary mb-2">Devices (clicks)</div><Bars items={s.devices || []} valueKey="clicks" labelKey="k" /></div>
          <div><div className="text-[13px] text-glass-secondary mb-2">Countries (clicks)</div><Bars items={s.countries || []} valueKey="clicks" labelKey="k" /></div>
          <div><div className="text-[13px] text-glass-secondary mb-2">Result types</div>{(s.appearance || []).length ? <Bars items={s.appearance} valueKey="impressions" labelKey="k" /> : <p className="m-0 text-sm text-glass-secondary">Plain results only.</p>}</div>
        </div>
      </Fold>
    </div>
  );
}

const FILTERS = [['all', 'All'], ['almost', 'Almost page 1'], ['low_ctr', 'Seen, not clicked'], ['dropping', 'Dropping'], ['new', 'New'],
  ['questions', 'Questions & costs'], ['nonbrand', 'Non-brand'], ['brand', 'Brand'], ['cannibal', 'Two pages competing']];
function Searches({ initialFilter, initialQ }) {
  const [filter, setFilter] = useState(initialFilter || 'all');
  const [q, setQ] = useState(initialQ || '');
  const [data, setData] = useState(null);
  const [openRow, setOpenRow] = useState('');
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => rpc('api_web_queries', { p_filter: filter, p_q: q.trim() || null, p_limit: 300 }).then((d) => { if (live) setData(d); }).catch((e) => showToast(e.message, 'error')), q ? 250 : 0);
    return () => { live = false; clearTimeout(t); };
  }, [filter, q]);
  return (
    <section className="glass-card p-5 flex flex-col gap-3">
      <div className="flex flex-wrap gap-2" role="group" aria-label="Filter searches">
        {FILTERS.map(([k, l]) => (
          <button key={k} type="button" aria-pressed={filter === k} onClick={() => setFilter(k)}
            className={`min-h-[34px] px-3 rounded-full text-[13px] border ${filter === k ? 'bg-[#1C1C1E] text-white border-[#1C1C1E]' : 'bg-white border-[var(--border-default)] text-glass-primary'}`}>{l}</button>
        ))}
      </div>
      <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search the searches" aria-label="Search the searches" className="glass-input min-h-[38px] px-3 text-sm max-w-sm" />
      <div className="text-[13px] text-glass-secondary">{data ? `${fmt(data.total)} searches` : 'Loading…'} · Search Console, last 28 days vs the 28 before. Google hides very rare searches.</div>
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
    <tr className="border-t border-[var(--hairline)] cursor-pointer hover:bg-[rgba(118,118,128,0.05)]" onClick={onToggle}>
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

function Ai({ o, canRun, reload }) {
  const ai = o.ai || {}, bots = ai.robots?.bots || {};
  const [busy, setBusy] = useState(false);
  const upload = async (file) => {
    if (!file) return;
    setBusy(true);
    try {
      const { copilotRows } = await import('../utils/csv');
      const parsed = copilotRows(await file.text());
      if (!parsed.rows.length) throw new Error('No rows found. Use the CSV exported from Bing Webmaster Tools > AI Performance.');
      const r = await rpc('api_web_copilot_upload', { p_kind: parsed.kind, p_rows: parsed.rows });
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
                  <div className="text-glass-secondary">LCP {r.field?.lcp ? `${(r.field.lcp.p75 / 1000).toFixed(1)} s` : '—'} · INP {r.field?.inp ? `${r.field.inp.p75} ms` : '—'} · CLS {r.field?.cls ? r.field.cls.p75 : '—'}</div>
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
  if (!l) return <section className="glass-card p-5 text-sm text-glass-secondary">Leads are not available here.</section>;
  const c = change(l.cur, l.prev);
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
        <Card title="Website leads · 28 days" value={fmt(l.cur)} {...c} />
        <Card title="Admissions from them" value={fmt(l.admissions)} note="Marked as admission in Leads" tone="muted" />
        <Card title="Visitors who became leads" value={o.visitors?.cur?.users ? `${((100 * l.cur) / o.visitors.cur.users).toFixed(1)}%` : '—'} note={o.visitors?.cur?.users ? 'Leads ÷ GA4 visitors' : 'Needs GA4'} tone="muted" />
      </div>
      <section className="glass-card p-5"><h2 className="m-0 mb-3 text-base font-semibold">Where they came from</h2><Bars items={l.by_source || []} valueKey="n" labelKey="source" /></section>
      <section className="glass-card p-5"><h2 className="m-0 mb-3 text-base font-semibold">Per week</h2><Bars items={(l.weekly || []).map((w) => ({ ...w, label: `Week of ${new Date(w.week).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}` }))} valueKey="n" labelKey="label" /></section>
      <p className="m-0 text-[13px] text-glass-secondary">To see which page and which Google search brought each lead, the website form needs to send the page address and UTM tags with the enquiry.</p>
    </div>
  );
}

function Settings({ reload }) {
  const [st, setSt] = useState(null);
  const [site, setSite] = useState(''); const [pages, setPages] = useState(''); const [key, setKey] = useState('');
  useEffect(() => { rpc('api_web_settings').then((s) => { setSt(s); setSite(s.site_url || ''); setPages(s.key_pages || ''); }).catch(() => {}); }, []);
  if (!st) return null;
  const save = async (psi) => {
    try { await rpc('api_web_settings_save', { p_site_url: site, p_key_pages: pages, p_psi_key: psi }); setKey(''); showToast('Saved', 'success'); reload(); setSt(await rpc('api_web_settings')); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <Fold title="Website settings" hint="site, key pages, PageSpeed key" id="settings">
      <div className="flex flex-col gap-3 max-w-xl py-2">
        <label className="text-[13px] text-glass-secondary flex flex-col gap-1">Site address<input className="glass-input min-h-[38px] px-3 text-sm" value={site} onChange={(e) => setSite(e.target.value)} /></label>
        <label className="text-[13px] text-glass-secondary flex flex-col gap-1">Key pages for speed and indexing checks (one path per line; empty = home + top 5 from Google)
          <textarea className="glass-input px-3 py-2 text-sm font-mono" rows={4} value={pages} onChange={(e) => setPages(e.target.value)} placeholder={'/cpl-course\n/ppl-course'} /></label>
        <label className="text-[13px] text-glass-secondary flex flex-col gap-1">PageSpeed Insights API key (optional, free; raises the daily limit) · {st.psi_key?.set ? `saved •••• ${st.psi_key.last4}` : 'not saved'}
          <input type="password" autoComplete="off" className="glass-input min-h-[38px] px-3 text-sm" value={key} onChange={(e) => setKey(e.target.value)} placeholder="AIza…" /></label>
        <div className="flex gap-2">
          <button type="button" className="glass-btn min-h-[38px] px-4 text-sm" onClick={() => save(key.trim() ? key.trim() : null)}>Save</button>
          {st.psi_key?.set && <button type="button" className="glass-btn-ghost min-h-[38px] px-3 text-sm" onClick={() => save('')}>Remove key</button>}
        </div>
        <p className="m-0 text-[12px] text-glass-secondary">Search Console site, GA4 property and the Google sign-in are in Connections &amp; keys.</p>
      </div>
    </Fold>
  );
}

// ---------------------------------------------------------------- page
const TABS = [['overview', 'Overview'], ['searches', 'Google searches'], ['ai', 'AI visibility'], ['health', 'Speed & health'], ['leads', 'Leads from website']];
export default function Website() {
  const route = useRoute();
  const tab = TABS.some(([k]) => k === route.section) ? route.section : 'overview';
  const [o, setO] = useState(cache);
  const [err, setErr] = useState('');
  const [access, setAccess] = useState(null);
  const [live, setLive] = useState(null);
  const [running, setRunning] = useState('');
  const load = useCallback(async () => {
    try { const d = await rpc('api_web_overview'); cache = d; setO(d); setErr(''); } catch (e) { setErr(e.message); }
  }, []);
  useEffect(() => { load(); rpc('api_web_access').then(setAccess).catch(() => {}); }, [load]);
  // On the site now: GA4 realtime, every minute while this screen is visible.
  useEffect(() => {
    if (!o?.configured?.ga4) return undefined;
    let stop = false;
    const tick = () => { if (document.visibilityState === 'visible') edge(['live']).then((r) => { if (!stop) setLive(r.live); }).catch(() => {}); };
    tick(); const t = setInterval(tick, 60000);
    return () => { stop = true; clearInterval(t); };
  }, [o?.configured?.ga4]);
  const go = (t, q, filter) => {
    if (t === 'connections') { navigate('connections'); return; }
    if (t === 'speed') t = 'health';
    navigate('website', t, { ...(q ? { q } : {}), ...(filter ? { f: filter } : {}) });
  };
  const refresh = async () => {
    const steps = [[['search', 'visitors'], 'Google Search and visitors'], [['scan'], 'Site check'], [['speed', 'index'], 'Speed and indexing']];
    const problems = [];
    for (const [jobs, label] of steps) {
      setRunning(label);
      try {
        const r = await edge(jobs);
        Object.values(r.results || {}).forEach((x) => { if (x.status !== 'ok') problems.push(x.detail); });
        await load();
      } catch (e) { problems.push(`${label}: ${e.message}`); }
    }
    setRunning('');
    if (problems.length) showToast(problems[0], 'error'); else showToast('Website data is up to date', 'success');
  };
  const lastRun = o ? Object.values(o.runs || {}).map((r) => r.at).sort().pop() : null;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Website</h1>
          <p className="m-0 text-sm text-glass-secondary">{o?.site ? new URL(o.site).host : 'weoneaviation.in'} · last 28 days vs the 28 before · updated {ago(lastRun)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
          {o && <span className="px-2.5 py-1 rounded-full" style={o.configured?.gsc ? { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' } : { background: 'rgba(178,106,0,0.12)', color: '#8A5300' }}>Search Console {o.configured?.gsc ? 'connected' : 'not set'}</span>}
          {o && <span className="px-2.5 py-1 rounded-full" style={Number(o.visitors?.cur?.days || 0) ? { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' } : { background: 'rgba(178,106,0,0.12)', color: '#8A5300' }}>GA4 {Number(o.visitors?.cur?.days || 0) ? 'connected' : 'no data'}</span>}
          {access?.can_run && <button type="button" disabled={!!running} onClick={refresh} className="glass-btn min-h-[36px] px-3.5 text-[13px] inline-flex items-center gap-1.5"><Icon name="refresh" size={14} />{running ? `${running}…` : 'Refresh'}</button>}
        </div>
      </div>
      <div role="tablist" aria-label="Website sections" className="flex flex-wrap gap-1 border-b border-[var(--hairline)]">
        {TABS.map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} type="button" onClick={() => navigate('website', k === 'overview' ? '' : k)}
            className={`min-h-[42px] px-3.5 -mb-px border-b-2 text-sm ${tab === k ? 'border-[var(--accent)] text-[var(--accent)] font-semibold' : 'border-transparent text-glass-secondary'}`}>{l}</button>
        ))}
      </div>
      {err && !o && <div role="alert" className="glass-card p-5 text-sm">{err} <button type="button" className="text-[var(--accent)] font-medium ml-2" onClick={load}>Try again</button></div>}
      {!o && !err && <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>}
      {o && tab === 'overview' && <Overview o={o} live={live} go={go} />}
      {o && tab === 'searches' && <Searches key={`${route.params.f || ''}|${route.params.q || ''}`} initialFilter={route.params.f} initialQ={route.params.q} />}
      {o && tab === 'ai' && <Ai o={o} canRun={access?.can_run} reload={load} />}
      {o && tab === 'health' && <Health o={o} />}
      {o && tab === 'leads' && <Leads o={o} />}
      {o && access?.is_admin && <Settings reload={load} />}
      <p className="m-0 text-xs text-glass-secondary">Sources: Google Search Console, Google Analytics 4, PageSpeed Insights (Chrome UX Report + Lighthouse), Search Console URL Inspection, Bing Webmaster Tools export, and a direct check of the site.</p>
    </div>
  );
}
