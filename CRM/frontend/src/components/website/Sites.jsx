// Google > Website, home: one card per website (We One Aviation, Flying Star, Book My Charter, ...) with its Google
// clicks, visitors, speed and the one thing worth doing next; a side-by-side comparison; the searches your websites
// share; and "Add website" in three short steps (address, pick it in Google, check). Numbers come from api_web_sites
// (migration 148); the Google lists and checks from the crm-website Edge Function. Tap a card to open that website.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../../backend/supabaseClient';
import { showToast } from '../../utils/toast';
import { navigate, setParams, useRoute } from '../../utils/route';
import { modalProps } from '../ui/overlay';
import Icon from '../icons';
import { Spark } from './charts';
import '../leads/leads.css';
import './sites.css';

// ---------------------------------------------------------------- data
export async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
export async function edge(body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/crm-website`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || (res.status === 404 ? 'The website data service is not deployed yet' : `Request failed (${res.status})`));
  return out;
}
// The three collection steps for one website, in order. Returns the problems met (empty when all went well).
export const STEPS = [[['search', 'visitors'], 'Google Search and visitors'], [['scan'], 'Site check'], [['speed', 'index'], 'Speed and indexing']];
export async function collect(site, onStep) {
  const problems = [];
  for (const [jobs, label] of STEPS) {
    onStep?.(label);
    try {
      const r = await edge({ jobs, site });
      Object.values(r.results || {}).forEach((x) => { if (x.status === 'error') problems.push(x.detail); });
    } catch (e) { problems.push(`${label}: ${e.message}`); }
  }
  return problems;
}

let sitesCache = null;  // reopening the section is instant, then it refreshes quietly
export function useSites() {
  const [d, setD] = useState(sitesCache);
  const [err, setErr] = useState('');
  const load = useCallback(async () => {
    try { const x = await rpc('api_web_sites'); sitesCache = x; setD(x); setErr(''); } catch (e) { setErr(e.message); }
  }, []);
  useEffect(() => { load(); }, [load]);
  return { d, err, load };
}

// ---------------------------------------------------------------- helpers
const fmt = (n) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: 0 }));
const short = (n) => (n == null ? '—' : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : fmt(Math.round(n)));
const pct = (a, b) => (a == null || !b ? null : Math.round((100 * (a - b)) / b));
export const hostOf = (u) => { try { return new URL(String(u).includes('://') ? u : `https://${u}`).hostname.replace(/^www\./, '').toLowerCase(); } catch { return ''; } };
const cleanDomain = (v) => String(v || '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/[/?#].*$/, '');
const DOMAIN_OK = /^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/;
const ago = (t) => {
  if (!t) return 'not yet';
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
};
const nameFromDomain = (d) => (d.replace(/^www\./, '').split('.')[0] || '').split(/[-_]/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(' ');
export const COLORS = ['#0A63CE', '#6E3FC9', '#0E7C6B', '#C2410C', '#8A5300', '#BE185D', '#1F2937', '#0891B2'];

// One line per website: the most useful thing to do or know now. go: where the button takes you.
export function tipFor(s) {
  const h = s.health || {}, q = s.queries || {}, se = s.search || {};
  const home = h.home?.status;
  if (!s.url) return { tone: 'muted', text: 'Add the web address to start tracking this website.', act: 'edit' };
  if (s.runs?.running) return { tone: 'info', text: 'Collecting the first numbers. This takes a minute or two.' };
  if (home != null && (home === 0 || home >= 400)) return { tone: 'bad', text: home ? `The home page answers with error ${home}.` : 'The home page did not load in the last check.', go: ['health'] };
  if (h.noindex > 0) return { tone: 'bad', text: `${h.noindex} page${h.noindex === 1 ? ' is' : 's are'} hidden from Google (noindex).`, go: ['health'] };
  if (h.not_indexed > 0) return { tone: 'bad', text: `${h.not_indexed} key page${h.not_indexed === 1 ? ' is' : 's are'} not in Google's index.`, go: ['health'] };
  const errs = s.runs?.errors || [];
  const core = errs.find((e) => e.job !== 'speed' && e.job !== 'index');
  if (core) return { tone: 'bad', text: `Last ${core.job === 'search' ? 'Google Search' : core.job === 'visitors' ? 'GA4' : 'site check'} refresh failed: ${String(core.detail || '').slice(0, 110)}`, act: /access|property|not found|scope/i.test(core.detail || '') ? 'edit' : undefined };
  if (!s.gsc_url) return { tone: 'warn', text: 'Connect Search Console to see what people search to find it.', act: 'edit' };
  const c = pct(se.clicks, se.clicks_prev);
  if (c != null && c <= -20 && Number(se.clicks_prev) >= 10) return { tone: 'bad', text: `Clicks from Google are down ${-c}%. See which searches dropped.`, go: ['searches', { f: 'dropping' }] };
  if (h.broken > 0) return { tone: 'warn', text: `Fix ${h.broken} broken link${h.broken === 1 ? '' : 's'} on the site.`, go: ['health'] };
  if (s.speed?.score != null && s.speed.score < 50) return { tone: 'warn', text: `Slow on phones (speed score ${s.speed.score} of 100).`, go: ['health'] };
  const sp = errs.find((e) => e.job === 'speed');
  if (sp && /quota/i.test(sp.detail || '')) return { tone: 'warn', text: 'The speed test hit Google’s free daily limit. Add a free PageSpeed key in Shared settings.', act: 'prefs' };
  if (q.almost > 0) return { tone: 'good', text: `${q.almost} search${q.almost === 1 ? ' is' : 'es are'} almost on page 1. A small push wins them.`, go: ['searches', { f: 'almost' }] };
  if (!s.ga4_property) return { tone: 'warn', text: 'Connect GA4 to count visitors and AI visits.', act: 'edit' };
  if (q.top) return { tone: 'good', text: `Most clicked search: “${q.top}”.`, go: ['searches', { q: q.top }] };
  if (!se.days) return { tone: 'muted', text: 'No Google numbers yet. Press Refresh.' };
  return { tone: 'good', text: 'All looks healthy.' };
}
export function statusOf(s, busy) {
  if (!s.url) return ['Add address', 'muted'];
  if (busy || s.runs?.running) return ['Collecting…', 'info'];
  if ((s.runs?.errors || []).some((e) => e.job !== 'speed' && e.job !== 'index')) return ['Check needed', 'warn'];
  if (!s.gsc_url && !s.ga4_property) return ['Connect Google', 'warn'];
  if (Number(s.search?.days) > 0 || Number(s.visitors?.days) > 0) return ['Live', 'good'];
  return ['Waiting for data', 'muted'];
}
const TONE = { good: ['rgba(30,123,52,0.10)', '#1E7B34'], warn: ['rgba(178,106,0,0.12)', '#8A5300'], bad: ['rgba(192,39,29,0.10)', '#A42219'],
  info: ['rgba(10,99,206,0.10)', '#0A63CE'], muted: ['var(--surface-sunken)', 'var(--label-2)'] };
const Pill = ({ tone = 'muted', children, className = '' }) => {
  const [bg, fg] = TONE[tone] || TONE.muted;
  return <span className={`ws-pill ${className}`} style={{ background: bg, color: fg }}>{children}</span>;
};
function Delta({ cur, prev, lowerIsBetter = false }) {
  const c = pct(cur, prev);
  if (c == null) return null;
  if (c === 0) return <span className="ws-delta" style={{ color: 'var(--label-2)' }}>same</span>;
  const good = (c > 0) !== lowerIsBetter;
  return <span className="ws-delta" style={{ color: good ? '#1E7B34' : '#A42219' }}>{c > 0 ? '↑' : '↓'}{Math.abs(c)}%</span>;
}
export function SiteMark({ s, size = 40 }) {
  const [bad, setBad] = useState(false);
  const host = s.url ? hostOf(s.url) : '';
  return (
    <span className="ws-mark" style={{ width: size, height: size, background: `${s.color}1A`, color: s.color }} aria-hidden="true">
      {host && !bad ? <img src={`https://www.google.com/s2/favicons?domain=${host}&sz=64`} alt="" width={size * 0.55} height={size * 0.55} loading="lazy" onError={() => setBad(true)} />
        : <b style={{ fontSize: size * 0.42 }}>{(s.name || '?').trim()[0]}</b>}
    </span>
  );
}

// ---------------------------------------------------------------- card
function SiteCard({ s, busy, info, onEdit, onRefresh, onRemove }) {
  const [menu, setMenu] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!menu) return undefined;
    const off = (e) => { if (!ref.current?.contains(e.target)) setMenu(false); };
    document.addEventListener('pointerdown', off);
    return () => document.removeEventListener('pointerdown', off);
  }, [menu]);
  const [label, tone] = statusOf(s, busy);
  const tip = tipFor(busy ? { ...s, runs: { ...s.runs, running: true } } : s);
  const se = s.search || {}, vi = s.visitors || {};
  const open = (tab, params) => navigate('website', tab || '', { site: s.id, ...(params || {}) });
  const act = () => {
    if (tip.act === 'edit') return onEdit(s);
    if (tip.act === 'prefs') { const el = document.getElementById('web-prefs'); if (el) { el.open = true; el.scrollIntoView({ behavior: 'smooth', block: 'center' }); } return undefined; }
    return tip.go ? open(tip.go[0], tip.go[1]) : open();
  };
  const canOpen = Boolean(s.url);
  return (
    <article className={`glass-card ws-card ${canOpen ? 'tile-link' : 'ws-card-setup'}`} data-testid="site-card" style={{ '--site': s.color }}
      role={canOpen ? 'link' : undefined} tabIndex={canOpen ? 0 : undefined} aria-label={canOpen ? `Open ${s.name}` : undefined}
      onClick={() => (canOpen ? open() : onEdit(s))} onKeyDown={(e) => { if (canOpen && e.key === 'Enter' && e.target === e.currentTarget) open(); }}>
      <header className="flex items-start gap-3 min-w-0">
        <SiteMark s={s} />
        <div className="min-w-0 flex-1">
          <h3 className="m-0 text-[17px] font-semibold leading-tight text-glass-primary truncate" title={s.name}>{s.name}</h3>
          <div className="mt-0.5 flex items-center gap-2 min-w-0"><span className="text-[13px] text-glass-secondary truncate">{s.url ? hostOf(s.url) : 'No web address yet'}</span><Pill tone={tone}>{label}</Pill></div>
        </div>
        {(info?.can_run || info?.is_admin) && (
          <div className="relative" ref={ref}>
            <button type="button" className="ws-iconbtn" aria-label={`More for ${s.name}`} aria-expanded={menu} aria-haspopup="menu"
              onClick={(e) => { e.stopPropagation(); setMenu(!menu); }}><Icon name="more" size={18} /></button>
            {menu && (
              <div role="menu" className="ws-menu lp-reveal" onClick={(e) => e.stopPropagation()}>
                {canOpen && <button role="menuitem" type="button" onClick={() => { setMenu(false); open(); }}><Icon name="chart" size={15} />Open</button>}
                {canOpen && info?.can_run && <button role="menuitem" type="button" disabled={busy} onClick={() => { setMenu(false); onRefresh(s); }}><Icon name="refresh" size={15} />Refresh now</button>}
                {info?.is_admin && <button role="menuitem" type="button" onClick={() => { setMenu(false); onEdit(s); }}><Icon name="settings" size={15} />Edit</button>}
                {s.url && <a role="menuitem" href={s.url} target="_blank" rel="noreferrer noopener" onClick={() => setMenu(false)}><Icon name="external" size={15} />Visit site</a>}
                {info?.is_admin && !s.is_primary && <button role="menuitem" type="button" className="ws-danger" onClick={() => { setMenu(false); onRemove(s); }}><Icon name="trash" size={15} />Remove</button>}
              </div>)}
          </div>)}
      </header>

      {s.url ? (<>
        <div className="grid grid-cols-3 gap-2 mt-4">
          <div className="min-w-0"><div className="ws-k">Clicks</div><div className="ws-v">{fmt(se.clicks)}</div><Delta cur={se.clicks} prev={se.clicks_prev} /></div>
          <div className="min-w-0"><div className="ws-k">Visitors</div><div className="ws-v">{Number(vi.days) ? fmt(vi.users) : '—'}</div><Delta cur={vi.users} prev={vi.users_prev} /></div>
          <div className="min-w-0"><div className="ws-k">Position</div><div className="ws-v">{se.position ?? '—'}</div><Delta cur={se.position} prev={se.position_prev} lowerIsBetter /></div>
        </div>
        <div className="mt-1 min-h-[28px]" style={{ color: s.color }}>{(se.spark || []).length > 1 ? <Spark values={se.spark} color={s.color} /> : null}</div>
      </>) : (
        <p className="m-0 mt-4 text-sm text-glass-secondary">Add its address and pick it in your Google account. It takes about a minute.</p>
      )}

      <button type="button" className={`ws-tip ws-tip-${tip.tone}`} onClick={(e) => { e.stopPropagation(); act(); }} disabled={!tip.go && !tip.act}>
        <span className="min-w-0">{tip.text}</span>{(tip.go || tip.act) && <Icon name="chevronRight" size={15} />}
      </button>

      <footer className="mt-3 flex flex-wrap items-center gap-1.5 text-[12px]">
        <span className={`ws-src ${s.gsc_url ? 'on' : ''}`} title={s.gsc_url || 'Search Console not connected'}><Icon name={s.gsc_url ? 'check' : 'close'} size={12} />Search Console</span>
        <span className={`ws-src ${s.ga4_property ? 'on' : ''}`} title={s.ga4_property ? `GA4 property ${s.ga4_property}` : 'GA4 not connected'}><Icon name={s.ga4_property ? 'check' : 'close'} size={12} />GA4</span>
        {s.speed?.score != null && <span className="ws-src on" title="PageSpeed score on phones">Speed {s.speed.score}</span>}
        {s.leads && <span className="ws-src on" title="Enquiries from this website in the last 28 days">{fmt(s.leads.cur)} leads</span>}
        <span className="ml-auto text-glass-secondary">{s.url ? `Updated ${ago(s.runs?.at)}` : ''}</span>
      </footer>
    </article>
  );
}

// ---------------------------------------------------------------- research: compare and shared searches
function Compare({ sites }) {
  const live = sites.filter((s) => s.url);
  const cols = [
    ['Clicks', (s) => s.search?.clicks, (s) => <>{fmt(s.search?.clicks)} <Delta cur={s.search?.clicks} prev={s.search?.clicks_prev} /></>],
    ['Seen on Google', (s) => s.search?.impressions, (s) => short(s.search?.impressions)],
    ['Avg position', (s) => (s.search?.position == null ? null : -s.search.position), (s) => s.search?.position ?? '—'],
    ['Visitors', (s) => (Number(s.visitors?.days) ? s.visitors?.users : null), (s) => (Number(s.visitors?.days) ? fmt(s.visitors?.users) : '—')],
    ['AI visits', (s) => (Number(s.visitors?.days) ? s.ai_visits : null), (s) => (Number(s.visitors?.days) ? fmt(s.ai_visits) : '—')],
    ['Phone speed', (s) => s.speed?.score, (s) => (s.speed?.score != null ? `${s.speed.score}/100` : '—')],
    ['Pages', (s) => s.health?.pages, (s) => (s.health?.pages ? fmt(s.health.pages) : '—')],
    ['Leads', (s) => s.leads?.cur, (s) => (s.leads ? fmt(s.leads.cur) : '—')],
  ];
  const best = cols.map(([, v]) => { const xs = live.map(v).filter((x) => x != null && Number(x) > -Infinity); return xs.length > 1 ? Math.max(...xs.map(Number)) : null; });
  if (live.length < 2) return null;
  return (
    <section className="glass-card p-4 sm:p-5" data-testid="sites-compare">
      <h2 className="m-0 text-base font-semibold text-glass-primary">Side by side</h2>
      <p className="m-0 mb-2 text-[13px] text-glass-secondary">Last 28 days. The best value in each column is marked.</p>
      <div className="overflow-x-auto -mx-1 px-1">
        <table className="w-full text-sm border-collapse min-w-[720px]">
          <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-2">Website</th>{cols.map(([l]) => <th key={l} className="font-medium py-2 text-right">{l}</th>)}</tr></thead>
          <tbody>{live.map((s) => (
            <tr key={s.id} className="border-t border-[var(--hairline)] cursor-pointer hover:bg-[rgba(118,118,128,0.05)]" onClick={() => navigate('website', '', { site: s.id })}>
              <td className="py-2.5 pr-2"><span className="inline-flex items-center gap-2"><span className="ws-dot" style={{ background: s.color }} />{s.name}</span></td>
              {cols.map(([l, v, r], i) => <td key={l} className="py-2.5 text-right whitespace-nowrap" style={best[i] != null && Number(v(s)) === best[i] ? { fontWeight: 700, color: '#1E7B34' } : undefined}>{r(s)}</td>)}
            </tr>))}</tbody>
        </table>
      </div>
    </section>
  );
}

function Shared({ sites }) {
  const [rows, setRows] = useState(null);
  const [all, setAll] = useState(false);
  const withGsc = sites.filter((s) => s.gsc_url && Number(s.search?.days) > 0).length;
  useEffect(() => { if (withGsc >= 2) rpc('api_web_shared', { p_limit: 60 }).then(setRows).catch(() => setRows([])); }, [withGsc]);
  if (withGsc < 2) return (
    <section className="glass-card p-4 sm:p-5">
      <h2 className="m-0 text-base font-semibold text-glass-primary">Searches your websites share</h2>
      <p className="m-0 text-[13px] text-glass-secondary">When two or more websites have Search Console connected, this shows the searches where they appear together, so they help each other instead of competing.</p>
    </section>);
  if (!rows) return null;
  const shown = all ? rows : rows.slice(0, 6);
  return (
    <section className="glass-card p-4 sm:p-5" data-testid="sites-shared">
      <h2 className="m-0 text-base font-semibold text-glass-primary">Searches your websites share</h2>
      <p className="m-0 mb-2 text-[13px] text-glass-secondary">{rows.length ? `${rows.length} search${rows.length === 1 ? '' : 'es'} where more than one of your websites shows up. Pick one main page for each and link the other site to it.` : 'None: each website reaches its own searches.'}</p>
      {shown.map((r) => (
        <div key={r.query} className="py-2.5 border-t border-[var(--hairline)] first-of-type:border-t-0">
          <div className="flex items-baseline justify-between gap-3"><span className="text-sm font-medium text-glass-primary min-w-0 break-words">{r.query}</span><span className="text-[12px] text-glass-secondary shrink-0">{short(r.impressions)} seen</span></div>
          <div className="mt-1 flex flex-wrap gap-1.5">{r.sites.map((x) => (
            <button key={x.id} type="button" className="ws-share" onClick={() => navigate('website', 'searches', { site: x.id, q: r.query })}>
              <span className="ws-dot" style={{ background: x.color }} />{x.name}<b>#{Math.round(x.position)}</b></button>))}</div>
        </div>))}
      {rows.length > 6 && <button type="button" className="lp-link mt-2" onClick={() => setAll(!all)}>{all ? 'Show fewer' : `Show all ${rows.length}`}</button>}
    </section>
  );
}

// ---------------------------------------------------------------- add / edit website, in 3 steps
const STEP_NAMES = ['Website', 'Google', 'Check'];
function Help({ host, email, isAdmin, onEmail, onAgain, busy }) {
  const [e, setE] = useState('');
  const who = email ? <b className="break-all">{email}</b> : 'the Google account connected in Connections & keys';
  const copy = async () => { try { await navigator.clipboard.writeText(email); showToast('E-mail copied', 'success'); } catch { /* clipboard blocked */ } };
  return (
    <div className="ws-help lp-reveal" data-testid="site-help">
      <div className="text-sm font-semibold text-glass-primary">Not in the list? Give the CRM read access ({'<'}1 minute each)</div>
      <p className="m-0 mt-1 text-[13px] text-glass-secondary">The CRM reads Google with {who}.{email && <button type="button" className="lp-link ml-2" onClick={copy}>Copy</button>}</p>
      {!email && isAdmin && (
        <div className="mt-2 flex gap-2"><input className="glass-input min-h-[38px] px-3 text-sm flex-1 min-w-0" type="email" placeholder="name@gmail.com (optional, to show it here)" value={e} onChange={(x) => setE(x.target.value)} aria-label="Connected Google e-mail" />
          <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" disabled={!e.includes('@')} onClick={() => onEmail(e)}>Save</button></div>)}
      <div className="grid gap-3 mt-3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 240px), 1fr))' }}>
        <ol className="ws-howto"><li className="font-semibold">Search Console</li>
          <li>Open <a href="https://search.google.com/search-console/users" target="_blank" rel="noreferrer noopener">Search Console</a> and choose {host || 'the site'}.</li>
          <li>Settings › Users and permissions › <b>Add user</b>.</li>
          <li>Enter the e-mail above, permission <b>Restricted</b>, Add.</li></ol>
        <ol className="ws-howto"><li className="font-semibold">Google Analytics (GA4)</li>
          <li>Open <a href="https://analytics.google.com/analytics/web/#/admin" target="_blank" rel="noreferrer noopener">GA4 Admin</a> and choose the property of {host || 'the site'}.</li>
          <li>Property access management › <b>+</b> › Add users.</li>
          <li>Enter the e-mail above, role <b>Viewer</b>, Add.</li></ol>
      </div>
      <button type="button" className="lp-btn lp-btn-sm lp-btn-soft mt-3" onClick={onAgain} disabled={busy}><Icon name="refresh" size={14} />{busy ? 'Looking…' : 'I did it, look again'}</button>
    </div>
  );
}

function Pick({ title, hint, items, value, onPick, render, empty, testid }) {
  const [all, setAll] = useState(false);
  const shown = all ? items : items.slice(0, 5);
  return (
    <fieldset className="m-0 p-0 border-0" data-testid={testid}>
      <legend className="lp-label">{title}{hint && <span className="font-normal text-glass-secondary"> · {hint}</span>}</legend>
      <div className="grid gap-2">
        {shown.map((x) => {
          const [main, sub, match] = render(x);
          return (
            <button key={x.key} type="button" role="radio" aria-checked={value === x.key} className={`lp-choice ws-choice ${value === x.key ? 'lp-choice-on' : ''}`} onClick={() => onPick(x.key)}>
              <span className="flex items-center gap-2 w-full min-w-0"><span className={`ws-radio ${value === x.key ? 'on' : ''}`} /><span className="text-sm font-semibold text-glass-primary truncate">{main}</span>
                {match && <span className="lp-badge ml-auto shrink-0" style={{ background: 'rgba(52,199,89,0.16)', color: '#1E7B34' }}>Matches</span>}</span>
              {sub && <span className="text-[12px] text-glass-secondary pl-6 truncate max-w-full">{sub}</span>}
            </button>);
        })}
        {!items.length && <p className="m-0 text-[13px] text-glass-secondary">{empty}</p>}
        <button type="button" role="radio" aria-checked={value === ''} className={`lp-choice ws-choice ${value === '' ? 'lp-choice-on' : ''}`} onClick={() => onPick('')}>
          <span className="flex items-center gap-2"><span className={`ws-radio ${value === '' ? 'on' : ''}`} /><span className="text-sm text-glass-secondary">Not now</span></span>
        </button>
      </div>
      {items.length > 5 && <button type="button" className="lp-link mt-2" onClick={() => setAll(!all)}>{all ? 'Show fewer' : `Show all ${items.length}`}</button>}
    </fieldset>
  );
}

export function SiteSheet({ site, info, onClose, onSaved }) {
  const editing = Boolean(site?.id);
  const [step, setStep] = useState(0);
  const [f, setF] = useState({ name: site?.name || '', url: site?.url ? cleanDomain(site.url) : '',
    color: site?.color || COLORS[(Date.now() / 1000 | 0) % COLORS.length], gsc: site?.gsc_url || '', ga4: site?.ga4_property || '',
    key_pages: '', brand_terms: '', lead_sources: '' });
  const [nameTouched, setNameTouched] = useState(editing);
  const [lists, setLists] = useState(null);
  const [listBusy, setListBusy] = useState(false);
  const [check, setCheck] = useState(null);
  const [saving, setSaving] = useState(false);
  const [email, setEmail] = useState(info?.google_email || '');
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));
  const domain = cleanDomain(f.url);
  const host = hostOf(domain);
  const okDomain = DOMAIN_OK.test(domain);

  // editing: bring in the settings that are not on the card (key pages, brand words, lead sources)
  useEffect(() => {
    if (!editing) return;
    rpc('api_web_settings', { p_site: site.id }).then((s) => setF((x) => ({ ...x, key_pages: s.key_pages || '', brand_terms: s.brand_terms || '',
      lead_sources: (s.lead_sources || []).join(', '), gsc: s.gsc_url || x.gsc, ga4: s.ga4_property || x.ga4 }))).catch(() => {});
  }, [editing, site?.id]);

  const matchGsc = (x) => x.host === host;
  const matchGa = (x) => (x.hosts || []).includes(host);
  const loadLists = useCallback(async () => {
    setListBusy(true);
    try {
      const l = await edge({ action: 'google_lists' });
      setLists(l);
      setF((x) => ({ ...x,
        gsc: x.gsc || (l.gsc.filter((g) => g.host === host).sort((a, b) => (a.site.startsWith('sc-domain:') ? -1 : 1) - (b.site.startsWith('sc-domain:') ? -1 : 1))[0]?.site || ''),
        ga4: x.ga4 || (l.ga4.find((g) => (g.hosts || []).includes(host))?.property || '') }));
    } catch (e) { setLists({ gsc: [], ga4: [], errors: { all: e.message } }); }
    finally { setListBusy(false); }
  }, [host]);
  useEffect(() => { if (step === 1 && !lists) loadLists(); }, [step, lists, loadLists]);
  useEffect(() => {
    if (step !== 2) return;
    setCheck(null);
    edge({ action: 'check', url: `https://${domain}/`, gsc_url: f.gsc, ga4_property: f.ga4 }).then((r) => setCheck(r.check)).catch((e) => setCheck({ error: e.message }));
  }, [step]); // eslint-disable-line react-hooks/exhaustive-deps

  const gscItems = useMemo(() => (lists?.gsc || []).map((g) => ({ ...g, key: g.site })).sort((a, b) => Number(matchGsc(b)) - Number(matchGsc(a))), [lists, host]); // eslint-disable-line react-hooks/exhaustive-deps
  const gaItems = useMemo(() => (lists?.ga4 || []).map((g) => ({ ...g, key: g.property })).sort((a, b) => Number(matchGa(b)) - Number(matchGa(a))), [lists, host]); // eslint-disable-line react-hooks/exhaustive-deps
  const noMatch = lists && !listBusy && (!gscItems.some(matchGsc) || (!lists.errors?.ga4 && !gaItems.some(matchGa)));

  const saveEmail = async (e) => { try { await rpc('api_web_prefs_save', { p_google_email: e }); setEmail(e.trim().toLowerCase()); showToast('Saved', 'success'); } catch (x) { showToast(x.message, 'error'); } };
  const save = async () => {
    setSaving(true);
    try {
      const r = await rpc('api_web_site_save', { p_id: site?.id || null, p_name: f.name.trim(), p_url: domain, p_gsc_url: f.gsc || '', p_ga4_property: f.ga4 || '',
        p_key_pages: f.key_pages, p_brand_terms: editing || f.brand_terms.trim() ? f.brand_terms : null,
        p_lead_sources: f.lead_sources.split(',').map((x) => x.trim()).filter(Boolean), p_color: f.color });
      onSaved(r.id, !editing);
    } catch (e) { showToast(e.message, 'error'); setSaving(false); }
  };
  const next = () => {
    if (step === 0) {
      if (!f.name.trim()) { showToast('Give the website a name', 'error'); return; }
      if (!okDomain) { showToast('Type the address like flystar.co.in', 'error'); return; }
    }
    setStep(step + 1);
  };
  const row = (k, label, r) => (
    <li key={k} className="ws-check">
      <span className={`ws-check-ico ${r?.ok === true ? 'ok' : r?.ok === false ? 'bad' : 'off'}`}><Icon name={r?.ok === true ? 'check' : r?.ok === false ? 'alert' : 'more'} size={14} /></span>
      <span className="min-w-0"><span className="block text-sm font-semibold text-glass-primary">{label}</span><span className="block text-[13px] text-glass-secondary break-words">{r ? r.detail : 'Checking…'}</span></span>
    </li>);

  return (
    <div className="fixed inset-0 glass-overlay z-50 flex items-end sm:items-center justify-center sm:p-4" data-nosheet="" {...modalProps(onClose, { guard: true })}>
      <div className="lp-sheet ws-sheet" role="dialog" aria-modal="true" aria-label={editing ? `Edit ${site.name}` : 'Add a website'} data-testid="site-sheet">
        <div className="lp-grab" />
        <header className="flex items-center gap-3 px-4 sm:px-6 pt-3 sm:pt-5">
          <SiteMark s={{ name: f.name || '?', url: okDomain ? `https://${domain}/` : '', color: f.color }} size={36} />
          <h2 className="m-0 flex-1 min-w-0 text-[19px] font-semibold text-glass-primary truncate">{editing ? `Edit ${site.name}` : 'Add a website'}</h2>
          <button type="button" className="ws-iconbtn" aria-label="Close" onClick={onClose}><Icon name="close" size={18} /></button>
        </header>
        <ol className="lp-steps px-4 sm:px-6 mt-3" aria-label="Steps">
          {STEP_NAMES.map((n, i) => <li key={n} data-on={i <= step ? '' : undefined} data-cur={i === step ? '' : undefined}><span>{i < step ? '✓' : i + 1}</span>{n}</li>)}
        </ol>
        <div className="flex-1 overflow-y-auto px-4 sm:px-6 pb-4 min-h-0">
          {step === 0 && (
            <div className="flex flex-col gap-4 lp-reveal">
              <label className="flex flex-col gap-1.5"><span className="lp-label m-0">Web address</span>
                <span className="ws-url"><span className="text-glass-secondary">https://</span>
                  <input autoFocus inputMode="url" autoCapitalize="none" autoCorrect="off" spellCheck={false} placeholder="flystar.co.in" value={f.url} aria-label="Web address"
                    onChange={(e) => { const v = e.target.value; set('url', v); if (!nameTouched) set('name', nameFromDomain(cleanDomain(v))); }} /></span>
                <span className="text-[12px]" style={{ color: f.url && !okDomain ? '#A42219' : 'var(--label-2)' }}>{f.url && !okDomain ? 'Type just the address, like flystar.co.in' : 'Only the address; the CRM finds the pages itself.'}</span></label>
              <label className="flex flex-col gap-1.5"><span className="lp-label m-0">Name</span>
                <input className="glass-input min-h-[44px] px-3 text-[15px]" value={f.name} maxLength={60} placeholder="Flying Star" onChange={(e) => { setNameTouched(true); set('name', e.target.value); }} /></label>
              <div><div className="lp-label">Colour</div>
                <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Colour">{COLORS.map((c) => (
                  <button key={c} type="button" role="radio" aria-checked={f.color === c} aria-label={c} className={`ws-swatch ${f.color === c ? 'on' : ''}`} style={{ background: c }} onClick={() => set('color', c)} />))}</div></div>
            </div>)}

          {step === 1 && (
            <div className="flex flex-col gap-5 lp-reveal">
              <p className="m-0 text-[14px] text-glass-secondary">Pick <b className="text-glass-primary">{host}</b> in your Google account. Matching entries are chosen for you.</p>
              {!lists || listBusy ? <div className="ws-loading"><span className="ws-spin" />Looking in your Google account…</div>
                : lists.errors?.all ? <p className="m-0 text-sm" style={{ color: '#A42219' }}>{lists.errors.all}</p> : (<>
                  <Pick testid="pick-gsc" title="Search Console" hint="searches and clicks" value={f.gsc} onPick={(v) => set('gsc', v)} items={gscItems}
                    empty={lists.errors?.gsc || 'No Search Console sites are shared with the CRM yet.'}
                    render={(x) => [x.site.replace(/^sc-domain:/, ''), x.site.startsWith('sc-domain:') ? 'Whole domain (best)' : 'One address prefix', matchGsc(x)]} />
                  {lists.errors?.ga4 ? (
                    <label className="flex flex-col gap-1.5"><span className="lp-label m-0">GA4 property number</span>
                      <span className="text-[12px] text-glass-secondary">{lists.errors.ga4}</span>
                      <input className="glass-input min-h-[44px] px-3 text-[15px]" inputMode="numeric" placeholder="e.g. 430628737" value={f.ga4} onChange={(e) => set('ga4', e.target.value.replace(/[^\d]/g, ''))} /></label>
                  ) : (
                    <Pick testid="pick-ga4" title="Google Analytics (GA4)" hint="visitors and AI visits" value={f.ga4} onPick={(v) => set('ga4', v)} items={gaItems}
                      empty="No GA4 properties are shared with the CRM yet."
                      render={(x) => [x.name || `Property ${x.property}`, [x.account, (x.hosts || []).join(', ') || `#${x.property}`].filter(Boolean).join(' · '), matchGa(x)]} />)}
                </>)}
              {lists && !listBusy && (noMatch ? <Help host={host} email={email} isAdmin={info?.is_admin} onEmail={saveEmail} onAgain={loadLists} busy={listBusy} />
                : <details className="ws-more"><summary className="lp-link">Website not listed?</summary><Help host={host} email={email} isAdmin={info?.is_admin} onEmail={saveEmail} onAgain={loadLists} busy={listBusy} /></details>)}
            </div>)}

          {step === 2 && (
            <div className="flex flex-col gap-4 lp-reveal">
              {check?.error ? <p className="m-0 text-sm" style={{ color: '#A42219' }}>{check.error}</p> : (
                <ul className="m-0 p-0 list-none flex flex-col gap-2" data-testid="site-check">
                  {row('site', host, check?.site)}{row('gsc', 'Search Console', check?.gsc)}{row('ga4', 'Google Analytics (GA4)', check?.ga4)}
                </ul>)}
              <p className="m-0 text-[13px] text-glass-secondary">{editing ? 'Saving keeps the numbers unless the address or a Google connection changed.' : 'After saving, the CRM collects the first numbers in the background, then refreshes every night.'}</p>
              <details className="ws-more" open={editing}>
                <summary className="lp-link">More options</summary>
                <div className="flex flex-col gap-3 mt-3">
                  <label className="flex flex-col gap-1 text-[13px] text-glass-secondary">Words that mean your brand (comma separated; these searches count as “brand”)
                    <input className="glass-input min-h-[40px] px-3 text-sm" value={f.brand_terms} placeholder={`${(f.name || 'brand').toLowerCase()}, ${host.split('.')[0] || ''}`} onChange={(e) => set('brand_terms', e.target.value)} /></label>
                  <label className="flex flex-col gap-1 text-[13px] text-glass-secondary">Key pages to test for speed and indexing (one path per line; empty = home + top pages)
                    <textarea className="glass-input px-3 py-2 text-sm font-mono" rows={3} value={f.key_pages} placeholder={'/cpl-course\n/contact'} onChange={(e) => set('key_pages', e.target.value)} /></label>
                  <label className="flex flex-col gap-1 text-[13px] text-glass-secondary">Lead source names from its enquiry form (the “source” the form sends, comma separated)
                    <input className="glass-input min-h-[40px] px-3 text-sm" value={f.lead_sources} placeholder="e.g. flying star website" onChange={(e) => set('lead_sources', e.target.value)} /></label>
                </div>
              </details>
            </div>)}
        </div>
        <footer className="ws-sheet-foot">
          {step > 0 ? <button type="button" className="lp-btn lp-btn-soft" onClick={() => setStep(step - 1)}>Back</button> : <button type="button" className="lp-btn lp-btn-soft" onClick={onClose}>Cancel</button>}
          {step < 2 ? <button type="button" className="lp-btn lp-btn-primary" onClick={next} disabled={step === 1 && listBusy}>{step === 1 && !f.gsc && !f.ga4 ? 'Skip Google for now' : 'Next'}</button>
            : <button type="button" className="lp-btn lp-btn-green" onClick={save} disabled={saving}>{saving ? 'Saving…' : editing ? 'Save changes' : 'Add website'}</button>}
        </footer>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- home
export default function SitesHome() {
  const { d, err, load } = useSites();
  const [busy, setBusy] = useState({});
  const [sheet, setSheet] = useState(null);       // null | {} (add) | site (edit)
  const route = useRoute();
  // #/website?add=1 (the Google page's "Add website") opens the add steps straight away
  useEffect(() => { if (route.params.add && d?.is_admin) { setSheet({}); setParams({ add: undefined }); } }, [route.params.add, d?.is_admin]);
  const [allBusy, setAllBusy] = useState(false);
  const sites = d?.sites || [];
  const refreshSite = useCallback(async (s, { quiet = false } = {}) => {
    setBusy((b) => ({ ...b, [s.id]: true }));
    const problems = await collect(s.id);
    setBusy((b) => { const n = { ...b }; delete n[s.id]; return n; });
    await load();
    if (!quiet) showToast(problems.length ? `${s.name}: ${problems[0]}` : `${s.name} is up to date`, problems.length ? 'error' : 'success');
    return problems;
  }, [load]);
  const refreshAll = async () => {
    setAllBusy(true);
    const list = sites.filter((s) => s.url);
    const res = await Promise.all(list.map((s) => refreshSite(s, { quiet: true })));
    setAllBusy(false);
    const bad = res.filter((p) => p.length).length;
    showToast(bad ? `${list.length - bad} of ${list.length} websites updated; open the others to see what needs a look` : 'All websites are up to date', bad ? 'error' : 'success');
  };
  const remove = async (s) => {
    const { confirmDialog } = await import('../ui/dialogs');
    if (!(await confirmDialog(`Remove ${s.name}?`, { message: 'Its numbers in the CRM are deleted too. The website itself is not touched. You can add it again later.', confirmText: 'Remove', danger: true }))) return;
    try { await rpc('api_web_site_remove', { p_id: s.id }); showToast(`${s.name} removed`, 'success'); load(); } catch (e) { showToast(e.message, 'error'); }
  };
  const saved = async (id, isNew) => {
    setSheet(null);
    await load();
    const s = (sitesCache?.sites || []).find((x) => x.id === id);
    showToast(isNew ? `${s?.name || 'Website'} added. Collecting its first numbers…` : 'Saved', 'success');
    if (s?.url && (isNew || !s.search?.days)) refreshSite(s, { quiet: !isNew });
  };

  const tot = sites.reduce((a, s) => ({
    clicks: a.clicks + Number(s.search?.clicks || 0), clicksPrev: a.clicksPrev + Number(s.search?.clicks_prev || 0),
    users: a.users + Number(s.visitors?.users || 0), usersPrev: a.usersPrev + Number(s.visitors?.users_prev || 0),
    ai: a.ai + Number(s.ai_visits || 0), leads: a.leads + Number(s.leads?.cur || 0), leadsPrev: a.leadsPrev + Number(s.leads?.prev || 0),
  }), { clicks: 0, clicksPrev: 0, users: 0, usersPrev: 0, ai: 0, leads: 0, leadsPrev: 0 });
  const needs = sites.filter((s) => ['bad', 'warn'].includes(tipFor(s).tone)).length;
  const hasGa = sites.some((s) => Number(s.visitors?.days) > 0);

  return (
    <div className="flex flex-col gap-5" data-testid="sites-home">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0">
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Websites</h1>
          <p className="m-0 text-sm text-glass-secondary">{d ? `${sites.length} website${sites.length === 1 ? '' : 's'}${needs ? ` · ${needs} need${needs === 1 ? 's' : ''} a look` : ''} · last 28 days vs the 28 before` : 'Loading…'}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {d?.can_run && <button type="button" className="glass-btn min-h-[40px] px-3.5 text-[13px] inline-flex items-center gap-1.5" disabled={allBusy || !sites.some((s) => s.url)} onClick={refreshAll}>
            <Icon name="refresh" size={14} />{allBusy ? 'Refreshing all…' : 'Refresh all'}</button>}
          {d?.is_admin && <button type="button" className="lp-btn lp-btn-primary lp-btn-sm" onClick={() => setSheet({})} data-testid="add-site"><Icon name="plus" size={15} />Add website</button>}
        </div>
      </div>
      {err && !d && <div role="alert" className="glass-card p-5 text-sm">{err} <button type="button" className="lp-link ml-2" onClick={load}>Try again</button></div>}

      {d && (
        <div className="ws-totals" data-testid="sites-totals">
          {[['Clicks from Google', fmt(tot.clicks), tot.clicks, tot.clicksPrev], ['Visitors', hasGa ? fmt(tot.users) : '—', tot.users, hasGa ? tot.usersPrev : null],
            ['Visits from AI assistants', hasGa ? fmt(tot.ai) : '—'], ['Website leads', fmt(tot.leads), tot.leads, tot.leadsPrev]].map(([k, v, c, p]) => (
            <div key={k} className="ws-total"><div className="ws-k">{k}</div><div className="text-[22px] font-semibold text-glass-primary leading-tight">{v}</div>{p != null ? <Delta cur={c} prev={p} /> : <span className="ws-delta">&nbsp;</span>}</div>))}
        </div>)}

      <div className="ws-grid">
        {!d && !err && [0, 1, 2].map((i) => <div key={i} className="glass-card ws-card ws-skel" aria-hidden="true" />)}
        {sites.map((s) => <SiteCard key={s.id} s={s} info={d} busy={Boolean(busy[s.id])} onEdit={(x) => setSheet(x)} onRefresh={(x) => refreshSite(x)} onRemove={remove} />)}
        {d?.is_admin && (
          <button type="button" className="ws-add" onClick={() => setSheet({})}>
            <span className="ws-add-plus"><Icon name="plus" size={22} /></span>
            <span className="text-[16px] font-semibold text-glass-primary">Add a website</span>
            <span className="text-[13px] text-glass-secondary">3 quick steps: address, pick it in Google, check.</span>
          </button>)}
      </div>

      {d && <Compare sites={sites} />}
      {d && <Shared sites={sites} />}
      {d?.is_admin && <PrefsFold info={d} reload={load} />}
      <p className="m-0 text-xs text-glass-secondary">Sources: Google Search Console, Google Analytics 4, PageSpeed Insights, Search Console URL Inspection and a direct check of each site. Search Console runs about 3 days behind. Every website refreshes each night.</p>
      {sheet && <SiteSheet site={sheet.id ? sheet : null} info={d} onClose={() => setSheet(null)} onSaved={saved} />}
    </div>
  );
}

// Shared by every website: the PageSpeed key and the connected Google e-mail (shown in the add steps).
function PrefsFold({ info, reload }) {
  const [st, setSt] = useState(null);
  const [key, setKey] = useState('');
  const [email, setEmail] = useState(info.google_email || '');
  const load = () => rpc('api_web_settings').then(setSt).catch(() => {});
  const save = async (psi) => {
    try { await rpc('api_web_prefs_save', { p_psi_key: psi, p_google_email: email.trim() }); setKey(''); showToast('Saved', 'success'); load(); reload(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <details id="web-prefs" className="glass-card group" onToggle={(e) => { if (e.currentTarget.open && !st) load(); }}>
      <summary className="flex items-center justify-between gap-3 px-5 min-h-[52px] cursor-pointer list-none">
        <span className="font-semibold text-glass-primary">Shared settings<span className="font-normal text-glass-secondary"> · Google account, PageSpeed key</span></span>
        <span className="text-[13px] text-[var(--accent)] group-open:hidden">Show</span><span className="text-[13px] text-[var(--accent)] hidden group-open:inline">Hide</span>
      </summary>
      <div className="px-5 pb-5 pt-2 border-t border-[var(--hairline)] flex flex-col gap-3 max-w-xl">
        <p className="m-0 text-[13px] text-glass-secondary">Google sign-in: {info.google_signin ? 'saved' : 'not saved'} (Setup › Connections & keys). Every website is read with this one account.</p>
        <label className="text-[13px] text-glass-secondary flex flex-col gap-1">E-mail of that Google account (shown in the “Add website” steps)
          <input type="email" className="glass-input min-h-[38px] px-3 text-sm" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@gmail.com" /></label>
        <label className="text-[13px] text-glass-secondary flex flex-col gap-1">PageSpeed Insights API key (optional, free; raises the daily limit) · {st?.psi_key?.set ? `saved •••• ${st.psi_key.last4}` : 'not saved'}
          <input type="password" autoComplete="off" className="glass-input min-h-[38px] px-3 text-sm" value={key} onChange={(e) => setKey(e.target.value)} placeholder="AIza…" /></label>
        <div className="flex gap-2">
          <button type="button" className="glass-btn min-h-[38px] px-4 text-sm" onClick={() => save(key.trim() ? key.trim() : null)}>Save</button>
          {st?.psi_key?.set && <button type="button" className="glass-btn-ghost min-h-[38px] px-3 text-sm" onClick={() => save('')}>Remove key</button>}
        </div>
      </div>
    </details>
  );
}
