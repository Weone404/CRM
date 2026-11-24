import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { navigate, useRoute } from '../utils/route';
import Icon from './icons';
import { Trend, TrendLegend, Spark, Columns, Share, HBars } from './website/charts';

// Google > Google My Business: how people find and contact the business on Google Search and Maps.
// Any number of profiles, from any number of Google logins. Every number is Google's own (Business Profile Performance
// API and reviews), collected by the crm-google-business Edge Function nightly and on Refresh. Nothing is estimated.
// Address: #/gbp/<section>?p=<profile id>&d=<days>

const fmt = (n) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: 0 }));
const short = (n) => (n == null ? '—' : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : fmt(Math.round(n)));
const pct = (a, b) => (a == null || !b ? null : Math.round((100 * (a - b)) / b));
const day = (d) => (d ? new Date(`${String(d).slice(0, 10)}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' }) : '');
const month = (d) => (d ? new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { month: 'long', year: 'numeric', timeZone: 'UTC' }) : '');
const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
};
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const PERIODS = [7, 28, 90];

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function edge(jobs, connection) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/crm-google-business`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify({ jobs, ...(connection ? { connection } : {}) }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || (res.status === 404 ? 'The Google My Business data service is not deployed yet' : `Request failed (${res.status})`));
  return out;
}

const cache = new Map();   // last answer per profile and period: reopening is instant, then it refreshes quietly

// ---------------------------------------------------------------- small pieces
const TONES = { good: ['rgba(30,123,52,0.10)', '#1E7B34'], warn: ['rgba(178,106,0,0.12)', '#8A5300'], bad: ['rgba(192,39,29,0.10)', '#A42219'], muted: ['var(--surface-sunken)', 'var(--label-2)'] };
const Chip = ({ tone = 'muted', children }) => { const [bg, fg] = TONES[tone]; return <span className="text-[12px] px-2.5 py-0.5 rounded-full whitespace-nowrap" style={{ background: bg, color: fg }}>{children}</span>; };
const STATE = {
  new: ['Not checked yet', 'muted'], connected: ['Connected', 'good'], waiting_google: ['Waiting for Google', 'warn'],
  needs_signin: ['Sign in again', 'bad'], api_off: ['API switched off', 'bad'], no_access: ['No access', 'bad'], error: ['Problem', 'bad'],
};
function Card({ title, value, note, tone, hint, onClick, spark, selected }) {
  const color = tone === 'good' ? '#1E7B34' : tone === 'bad' ? '#A42219' : 'var(--label-2)';
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag type={onClick ? 'button' : undefined} onClick={onClick} title={hint} aria-pressed={selected == null ? undefined : selected}
      className={`glass-card p-4 sm:p-5 flex flex-col gap-1 text-left ${onClick ? 'tile-link' : ''}`} style={selected ? { boxShadow: 'inset 0 0 0 2px var(--accent)' } : undefined}>
      <span className="block text-[13px] text-glass-secondary">{title}</span>
      <span className="block text-[26px] font-semibold leading-tight text-glass-primary">{value}</span>
      {note && <span className="block text-[13px]" style={{ color }}>{note}</span>}
      {spark}
    </Tag>
  );
}
const change = (cur, prev, havePrev, n) => {
  if (!havePrev || cur == null || prev == null) return {};
  if (!Number(prev)) return Number(cur) ? { note: `None in the ${n} days before`, tone: 'good' } : {};
  const c = pct(cur, prev);
  if (c === 0) return { note: `Same as the previous ${n} days` };
  return { note: `${c > 0 ? '↑' : '↓'} ${Math.abs(c)}% vs previous ${n} days`, tone: c > 0 ? 'good' : 'bad' };
};
const Stars = ({ n }) => (n ? <span aria-label={`${n} of 5 stars`} className="whitespace-nowrap tracking-tight" style={{ color: '#B26A00' }}>{'★'.repeat(n)}<span style={{ color: 'rgba(60,60,67,0.25)' }}>{'★'.repeat(5 - n)}</span></span>
  : <span className="text-glass-secondary text-[12px]">no rating</span>);
const Section = ({ title, hint, children, action, id }) => (
  <section className="glass-card p-5" data-section={id}>
    <div className="flex items-start justify-between gap-3 mb-3">
      <div><h2 className="m-0 text-base font-semibold text-glass-primary">{title}</h2>{hint && <p className="m-0 text-[13px] text-glass-secondary">{hint}</p>}</div>
      {action}
    </div>
    {children}
  </section>
);
const LinkBtn = ({ onClick, children }) => <button type="button" onClick={onClick} className="shrink-0 text-sm font-medium text-[var(--accent)] min-h-[36px]">{children}</button>;

const METRICS = [
  { k: 'views', label: 'Profile views', short: 'Views', hint: 'People who saw the profile on Google Search or Google Maps. Google counts a person once a day on each.' },
  { k: 'calls', label: 'Calls', short: 'Calls', hint: 'Taps on the Call button of the profile.' },
  { k: 'website', label: 'Website clicks', short: 'Website', hint: 'Taps on the Website button of the profile.' },
  { k: 'directions', label: 'Direction requests', short: 'Directions', hint: 'People who asked Google Maps for the way to you.' },
  { k: 'messages', label: 'Messages', short: 'Messages', hint: 'Chats started from the profile.' },
  { k: 'actions', label: 'All actions', short: 'All actions', hint: 'Calls, website clicks, direction requests, messages and bookings together.', chartOnly: true },
];

// ---------------------------------------------------------------- setup: what is still missing, in order
function Setup({ o, isAdmin }) {
  const s = o.setup || {};
  const approved = Number(s.connected) > 0 || s.has_data;
  const steps = [
    { done: !!s.client, title: 'The CRM\'s Google sign-in client is saved', todo: 'Save the Google OAuth client under Connections & keys.', go: isAdmin ? () => navigate('connections') : null, goLabel: 'Open Connections & keys' },
    { done: Number(s.connections) > 0, title: 'A Google login that owns or manages the profile is added', todo: isAdmin ? 'Add it under Profiles & logins.' : 'An Admin adds it under Profiles & logins.', go: () => navigate('gbp', 'manage'), goLabel: 'Open Profiles & logins' },
    { done: approved, wait: !approved && s.waiting_google, title: 'Google has approved the project for Business Profile data',
      todo: s.waiting_google ? 'Google still answers with a quota of 0. This clears by itself when Google\'s approval email arrives; nothing else to do here.'
        : 'One-time, free: Google\'s "Application for Basic API Access" form. The CRM checks the result each time it refreshes.' },
    { done: Number(s.tracked) > 0, title: 'The profiles to track are chosen', todo: 'Tick them under Profiles & logins. A login with a single profile is tracked by itself.', go: Number(s.locations) > 0 ? () => navigate('gbp', 'manage') : null, goLabel: 'Choose profiles' },
    { done: !!s.has_data, title: 'The first numbers are in', todo: 'Press Refresh. After that it updates every night.' },
  ];
  return (
    <Section id="setup" title="Getting Google My Business connected" hint={`${steps.filter((x) => x.done).length} of ${steps.length} done`}>
      <ol className="m-0 p-0 list-none">
        {steps.map((x, i) => (
          <li key={x.title} className="flex items-start gap-3 py-3 border-t border-[var(--hairline)] first:border-t-0">
            <span className="mt-0.5 h-6 w-6 rounded-full inline-flex items-center justify-center text-[12px] font-semibold shrink-0"
              style={x.done ? { background: 'rgba(30,123,52,0.12)', color: '#1E7B34' } : x.wait ? { background: 'rgba(178,106,0,0.14)', color: '#8A5300' } : { background: 'var(--surface-sunken)', color: 'var(--label-2)' }}>
              {x.done ? <Icon name="check" size={14} /> : x.wait ? <Icon name="clock" size={13} /> : i + 1}</span>
            <div className="min-w-0 flex-1">
              <div className="text-sm font-medium text-glass-primary">{x.title} {x.wait && <Chip tone="warn">Waiting for Google</Chip>}</div>
              {!x.done && <div className="text-[13px] text-glass-secondary">{x.todo}</div>}
            </div>
            {!x.done && x.go && <LinkBtn onClick={x.go}>{x.goLabel}</LinkBtn>}
          </li>
        ))}
      </ol>
    </Section>
  );
}

// ---------------------------------------------------------------- overview
function takeaway(m, o) {
  const n = o.period.days, a = Number(o.totals[m.k] || 0), b = Number(o.prev[m.k] || 0), havePrev = Number(o.prev.days) > 0;
  const best = [...(o.days || [])].sort((x, y) => (y[m.k] || 0) - (x[m.k] || 0))[0];
  const bestTxt = best && best[m.k] > 0 ? ` Best day: ${day(best.d)} (${fmt(best[m.k])}).` : '';
  if (!havePrev || !b) return `Last ${n} days: ${fmt(a)}.${bestTxt}`;
  const c = Math.round((100 * (a - b)) / b);
  if (c === 0) return `${m.label}: ${fmt(a)}, the same as the ${n} days before.${bestTxt}`;
  return `${m.label} ${c >= 0 ? 'up' : 'down'} ${Math.abs(c)}% vs the ${n} days before (${fmt(b)} → ${fmt(a)}).${bestTxt}`;
}
function Overview({ o, go }) {
  const [metric, setMetric] = useState('views');
  const t = o.totals || {}, p = o.prev || {}, n = o.period.days, havePrev = Number(p.days) > 0;
  const m = METRICS.find((x) => x.k === metric);
  const value = useCallback((r) => r[metric], [metric]);
  const rate = Number(t.views) > 0 ? (100 * Number(t.actions || 0)) / Number(t.views) : null;
  const kw = o.keywords || {}, rv = o.reviews || {};
  const week = [1, 2, 3, 4, 5, 6, 0].map((d) => { const w = (o.weekdays || []).find((x) => x.dow === d); return { k: DOW[d], v: Number(w?.views || 0), hint: w ? `${fmt(w.actions)} calls, clicks and other actions` : undefined }; });
  const did = [['Called', t.calls], ['Opened the website', t.website], ['Asked for directions', t.directions], ['Messaged', t.messages], ['Booked', t.bookings]]
    .map(([k, v]) => ({ k, v: Number(v || 0) })).filter((x) => x.v > 0);
  const words = (kw.rows || []).filter((r) => r.v != null).slice(0, 8);
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))' }}>
        {METRICS.filter((x) => !x.chartOnly).map((x) => (
          <Card key={x.k} title={x.label} value={x.k === 'views' ? short(t[x.k]) : fmt(t[x.k])} {...change(t[x.k], p[x.k], havePrev, n)} hint={`${x.hint} Click to chart it.`}
            onClick={() => setMetric(x.k)} selected={metric === x.k} spark={<Spark values={(o.days || []).map((r) => r[x.k])} />} />
        ))}
      </div>

      <section className="glass-card p-5" data-section="trend">
        <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
          <div>
            <h2 className="m-0 text-base font-semibold text-glass-primary">Day by day</h2>
            <p className="m-0 text-[13px] text-glass-secondary">{takeaway(m, o)}</p>
          </div>
          <div role="tablist" aria-label="What to chart" className="inline-flex flex-wrap p-0.5 rounded-[10px] bg-[var(--surface-sunken)]">
            {METRICS.map((x) => (
              <button key={x.k} role="tab" aria-selected={metric === x.k} type="button" onClick={() => setMetric(x.k)}
                className={`min-h-[32px] px-3 rounded-[8px] text-[13px] transition-colors ${metric === x.k ? 'bg-white shadow-sm font-semibold text-glass-primary' : 'text-glass-secondary'}`}>{x.short}</button>
            ))}
          </div>
        </div>
        <div className="mt-3"><Trend cur={o.days} prev={havePrev ? o.prev_days : []} value={value} format={(v, axis) => (axis ? (Number.isInteger(v) ? short(v) : '') : fmt(v))} label={`${m.label} per day`} gap={n} /></div>
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <TrendLegend prevShown={havePrev} days={n} />
          <span className="text-[12px] text-glass-secondary">Google publishes these numbers a few days late. Latest day: {day(o.period.last_day)}.</span>
        </div>
      </section>

      {rate != null && (
        <p className="m-0 glass-card px-5 py-4 text-sm text-glass-primary" data-section="rate">
          <b>{rate < 10 ? rate.toFixed(1) : Math.round(rate)} of every 100</b> people who saw the profile called, opened the website, asked for directions, messaged or booked
          <span className="text-glass-secondary"> ({fmt(t.actions)} actions from {fmt(t.views)} views).</span>
        </p>
      )}

      <div className="grid gap-5" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 320px), 1fr))' }}>
        <Section id="where" title="Where people saw you" hint="Google Search results or the Google Maps app and site.">
          <Share label="Search or Maps" unit="views" items={[{ k: 'Google Search', v: Number(t.search || 0) }, { k: 'Google Maps', v: Number(t.maps || 0) }]} />
          <h3 className="m-0 mt-5 mb-2 text-sm font-semibold text-glass-primary">On a phone or a computer</h3>
          <Share label="Phone or computer" unit="views" items={[{ k: 'Phone', v: Number(t.mobile || 0) }, { k: 'Computer', v: Number(t.desktop || 0) }]} />
        </Section>
        <Section id="did" title="What people did next" hint="Taps on the buttons of the profile.">
          {did.length ? <HBars items={did} format={(v) => fmt(v)} /> : <p className="m-0 text-sm text-glass-secondary">No calls, clicks or direction requests in these {n} days.</p>}
        </Section>
        <Section id="week" title="Busiest days of the week" hint={`Profile views by weekday, last ${n} days.`}>
          {Number(t.views) > 0 ? <Columns label="Views by weekday" items={week} format={(v, axis) => (axis ? short(v) : fmt(v))} height={190} /> : <p className="m-0 text-sm text-glass-secondary">No views yet.</p>}
        </Section>
        <Section id="words" title="Words people searched" hint={kw.month ? `Searches that showed the profile in ${month(kw.month)}.` : 'Google reports these month by month.'}
          action={Number(kw.count) > 0 ? <LinkBtn onClick={() => go('words')}>All {fmt(kw.count)}</LinkBtn> : null}>
          {words.length ? <HBars items={words} format={(v) => fmt(v)} sub={(x) => (x.pv != null ? `${fmt(x.pv)} the month before` : 'new this month')} />
            : <p className="m-0 text-sm text-glass-secondary">{Number(kw.count) > 0 ? 'Every search word was used too rarely for Google to give a count. Open the full list.' : 'No search words from Google yet.'}</p>}
        </Section>
        <Section id="reviews" title="Reviews" hint="From Google, newest first." action={<LinkBtn onClick={() => go('reviews')}>All reviews</LinkBtn>}>
          <div className="flex flex-wrap items-end gap-x-6 gap-y-2 mb-3">
            <div><span className="text-[34px] font-semibold leading-none text-glass-primary">{rv.rating != null ? Number(rv.rating).toFixed(1) : '—'}</span><span className="text-glass-secondary text-sm"> of 5</span></div>
            <div className="text-[13px] text-glass-secondary">{fmt(rv.total)} reviews · {fmt(rv.new)} new in {n} days{Number(rv.unreplied) > 0 ? <> · <button type="button" className="text-[var(--accent)] font-medium" onClick={() => go('reviews', { f: 'unreplied' })}>{fmt(rv.unreplied)} without a reply</button></> : ''}</div>
          </div>
          {Number(rv.stored) > 0 && <HBars items={[5, 4, 3, 2, 1].map((s) => ({ k: `${s} star${s === 1 ? '' : 's'}`, v: Number(rv.by_star?.[s] || 0) }))} format={(v) => fmt(v)} />}
          {(rv.latest || []).slice(0, 3).map((r) => (
            <div key={r.review_id} className="pt-3 mt-3 border-t border-[var(--hairline)] text-sm">
              <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5"><Stars n={r.stars} /><span className="font-medium text-glass-primary">{r.reviewer || 'A Google user'}</span><span className="text-[12px] text-glass-secondary">{day(r.created_at)}</span></div>
              {r.comment && <p className="m-0 mt-1 text-glass-secondary" style={{ display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>{r.comment}</p>}
            </div>
          ))}
          {!Number(rv.stored) && <p className="m-0 text-sm text-glass-secondary">No reviews collected yet.</p>}
        </Section>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- search words
function Words({ o }) {
  const [q, setQ] = useState('');
  const kw = o.keywords || {};
  const rows = useMemo(() => (kw.rows || []).filter((r) => !q.trim() || r.k.includes(q.trim().toLowerCase())), [kw.rows, q]);
  if (!kw.month) return <Section id="words" title="Words people searched"><p className="m-0 text-sm text-glass-secondary">No search words from Google yet. They arrive month by month after the first refresh.</p></Section>;
  return (
    <Section id="words" title={`Words people searched · ${month(kw.month)}`} hint={`The searches on Google Search and Maps that showed the profile. Google gives these for complete months only, and only "fewer than" for rare words.${Number(kw.count) > (kw.rows || []).length ? ` Top ${(kw.rows || []).length} of ${fmt(kw.count)}.` : ''}`}>
      <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find a word" aria-label="Find a search word" className="glass-input min-h-[38px] px-3 text-sm w-full sm:w-72 mb-2" />
      {rows.length ? (
        <div className="overflow-x-auto">
          <table className="w-full text-sm border-collapse min-w-[420px]">
            <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-2">Search</th><th className="font-medium py-2 text-right">Times it showed you</th><th className="font-medium py-2 text-right">{month(kw.prev_month)}</th><th className="font-medium py-2 text-right">Change</th></tr></thead>
            <tbody>{rows.map((r) => {
              const c = r.v != null && r.pv ? pct(r.v, r.pv) : null;
              return (
                <tr key={r.k} className="border-t border-[var(--hairline)]">
                  <td className="py-2.5 pr-2 text-glass-primary">{r.k}</td>
                  <td className="py-2.5 pr-2 text-right">{r.v != null ? fmt(r.v) : <span className="text-glass-secondary">fewer than {fmt(r.below)}</span>}</td>
                  <td className="py-2.5 pr-2 text-right text-glass-secondary">{r.pv != null ? fmt(r.pv) : '—'}</td>
                  <td className="py-2.5 text-right">{c != null ? <Chip tone={c >= 0 ? 'good' : 'bad'}>{c >= 0 ? '↑' : '↓'} {Math.abs(c)}%</Chip> : r.v != null && r.pv == null ? <Chip tone="muted">new</Chip> : ''}</td>
                </tr>);
            })}</tbody>
          </table>
        </div>
      ) : <p className="m-0 py-3 text-sm text-glass-secondary">No search word matches “{q}”.</p>}
    </Section>
  );
}

// ---------------------------------------------------------------- reviews
const FILTERS = [['all', 'All'], ['unreplied', 'Without a reply'], ['low', '1 to 3 stars']];
function Reviews({ o, filter, go }) {
  const f = FILTERS.some(([k]) => k === filter) ? filter : 'all';
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState('');
  const many = (o.locations || []).filter((l) => l.tracked).length > 1 && !o.selected;
  useEffect(() => {
    let stop = false; setRows(null);
    rpc('api_gbp_reviews', { p_location: o.selected || null, p_filter: f, p_limit: 200 }).then((d) => { if (!stop) { setRows(d || []); setErr(''); } }).catch((e) => { if (!stop) setErr(e.message); });
    return () => { stop = true; };
  }, [o.selected, f]);
  const rv = o.reviews || {};
  return (
    <Section id="reviews" title="Reviews" hint={`${rv.rating != null ? `${Number(rv.rating).toFixed(1)} of 5 · ` : ''}${fmt(rv.total)} on Google · ${fmt(rv.unreplied)} without a reply. Replies are written on Google for now; automatic replies are not switched on yet.`}>
      <div role="tablist" aria-label="Which reviews" className="inline-flex flex-wrap p-0.5 rounded-[10px] bg-[var(--surface-sunken)] mb-2">
        {FILTERS.map(([k, l]) => (
          <button key={k} role="tab" aria-selected={f === k} type="button" onClick={() => go('reviews', { f: k === 'all' ? undefined : k })}
            className={`min-h-[34px] px-3 rounded-[8px] text-[13px] ${f === k ? 'bg-white shadow-sm font-semibold text-glass-primary' : 'text-glass-secondary'}`}>{l}</button>
        ))}
      </div>
      {err && <p role="alert" className="m-0 py-2 text-sm">{err}</p>}
      {!rows && !err && <p className="m-0 py-3 text-sm text-glass-secondary">Loading…</p>}
      {rows && !rows.length && <p className="m-0 py-3 text-sm text-glass-secondary">{f === 'all' ? 'No reviews collected yet.' : 'None. Nothing is waiting here.'}</p>}
      {(rows || []).map((r) => (
        <article key={`${r.location_id}${r.review_id}`} className="py-3.5 border-t border-[var(--hairline)] text-sm">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
            <Stars n={r.stars} /><span className="font-medium text-glass-primary">{r.reviewer || 'A Google user'}</span>
            <span className="text-[12px] text-glass-secondary">{day(r.created_at)}{many ? ` · ${r.profile}` : ''}</span>
            {!r.reply && <Chip tone={r.stars && r.stars <= 3 ? 'bad' : 'warn'}>No reply yet</Chip>}
          </div>
          {r.comment ? <p className="m-0 mt-1.5 text-glass-primary whitespace-pre-line break-words">{r.comment}</p> : <p className="m-0 mt-1.5 text-glass-secondary">Rating only, no text.</p>}
          {r.reply && <div className="mt-2 ml-3 pl-3 border-l-2 border-[var(--hairline)]"><div className="text-[12px] text-glass-secondary">Your reply{r.reply_at ? ` · ${day(r.reply_at)}` : ''}</div><p className="m-0 text-glass-secondary whitespace-pre-line break-words">{r.reply}</p></div>}
        </article>
      ))}
    </Section>
  );
}

// ---------------------------------------------------------------- profiles and Google logins
function TokenForm({ withName, busy, onSave, onCancel }) {
  const [name, setName] = useState('');
  const [tok, setTok] = useState('');
  return (
    <form className="grid gap-2.5 max-w-xl" onSubmit={(e) => { e.preventDefault(); onSave(name.trim(), tok.trim()); }}>
      {withName && <label className="text-[13px] text-glass-secondary flex flex-col gap-1">Name for this login (for example the business or the Google user)
        <input className="glass-input min-h-[40px] px-3 text-sm" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} required placeholder="We One Aviation" /></label>}
      <label className="text-[13px] text-glass-secondary flex flex-col gap-1">Google refresh token (starts with 1//). It is stored encrypted and never shown again.
        <input type="password" autoComplete="off" spellCheck={false} className="glass-input min-h-[40px] px-3 text-sm font-mono" value={tok} onChange={(e) => setTok(e.target.value)} required placeholder="1//…" /></label>
      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="glass-btn min-h-[40px] px-4 text-sm">{busy ? 'Checking with Google…' : withName ? 'Add login' : 'Save new token'}</button>
        {onCancel && <button type="button" className="glass-btn-ghost min-h-[40px] px-3 text-sm" onClick={onCancel}>Cancel</button>}
      </div>
    </form>
  );
}
function Manage({ o, reload }) {
  const a = o.access || {};
  const [busy, setBusy] = useState('');
  const [adding, setAdding] = useState(false);
  const [replace, setReplace] = useState(null);
  const [removing, setRemoving] = useState(null);
  const check = async (id, label) => {
    setBusy(id || 'all');
    try {
      const r = await edge(['discover'], id);
      const d = r.results?.discover;
      showToast(d?.detail || `${label} checked`, d?.status === 'ok' ? 'success' : 'error');
    } catch (e) { showToast(e.message, 'error'); }
    await reload(); setBusy('');
  };
  const add = async (name, tok) => {
    setBusy('add');
    try {
      const r = await rpc('api_gbp_connection_add', { p_label: name, p_refresh_token: tok });
      setAdding(false);
      await check(r.id, name);
    } catch (e) { showToast(e.message, 'error'); setBusy(''); }
  };
  const saveToken = async (id, tok, label) => {
    setBusy(id);
    try { await rpc('api_gbp_connection_token', { p_id: id, p_refresh_token: tok }); setReplace(null); await check(id, label); }
    catch (e) { showToast(e.message, 'error'); setBusy(''); }
  };
  const remove = async (id) => {
    setBusy(id);
    try { await rpc('api_gbp_connection_remove', { p_id: id }); showToast('Login removed', 'success'); cache.clear(); } catch (e) { showToast(e.message, 'error'); }
    setRemoving(null); await reload(); setBusy('');
  };
  const track = async (l, on) => {
    setBusy(l.id);
    try { await rpc('api_gbp_location_track', { p_id: l.id, p_on: on }); cache.clear(); showToast(on ? `${l.title} is tracked. Press Refresh to collect its numbers.` : `${l.title} is no longer tracked`, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
    await reload(); setBusy('');
  };
  const conns = o.connections || [], locs = o.locations || [];
  return (
    <div className="flex flex-col gap-5">
      <Section id="logins" title="Google logins" hint="Each login is a Google user who owns or manages one or more Business Profiles. Add as many as you need."
        action={a.is_admin && !adding ? <button type="button" className="glass-btn min-h-[36px] px-3.5 text-[13px] inline-flex items-center gap-1.5" onClick={() => setAdding(true)}><Icon name="plus" size={14} />Add a Google login</button> : null}>
        {adding && <div className="pb-4"><TokenForm withName busy={busy === 'add'} onSave={add} onCancel={() => setAdding(false)} />
          <p className="m-0 mt-2 text-[12px] text-glass-secondary max-w-xl">The token must be made with the CRM's own Google OAuth client, by a Google user who is an owner or manager of the profile, with the permission <span className="font-mono">https://www.googleapis.com/auth/business.manage</span>.</p></div>}
        {!conns.length && !adding && <p className="m-0 text-sm text-glass-secondary">No Google login yet.{a.is_admin ? ' Add the one that owns or manages your Business Profile.' : ' An Admin can add one.'}</p>}
        {conns.map((c) => {
          const [label, tone] = STATE[c.status] || STATE.error;
          return (
            <div key={c.id} className="py-3.5 border-t border-[var(--hairline)] first:border-t-0" data-login={c.label}>
              <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2"><span className="font-medium text-glass-primary">{c.label}</span><Chip tone={tone}>{label}</Chip></div>
                  <div className="text-[13px] text-glass-secondary">{c.email ? `${c.email} · ` : ''}{c.locations} profile{c.locations === 1 ? '' : 's'}, {c.tracked} tracked · checked {ago(c.checked_at)}</div>
                </div>
                <div className="flex flex-wrap items-center gap-2 text-[13px]">
                  {a.can_run && <button type="button" disabled={!!busy} className="glass-btn-ghost min-h-[36px] px-3" onClick={() => check(c.id, c.label)}>{busy === c.id ? 'Checking…' : 'Check now'}</button>}
                  {a.is_admin && <button type="button" className="glass-btn-ghost min-h-[36px] px-3" onClick={() => setReplace(replace === c.id ? null : c.id)}>New token</button>}
                  {a.is_admin && (removing === c.id
                    ? <><button type="button" disabled={!!busy} className="min-h-[36px] px-3 rounded-[10px] text-white" style={{ background: '#C0271D' }} onClick={() => remove(c.id)}>Remove with its data</button><button type="button" className="glass-btn-ghost min-h-[36px] px-3" onClick={() => setRemoving(null)}>Keep</button></>
                    : <button type="button" className="glass-btn-ghost min-h-[36px] px-3 text-red-600" onClick={() => setRemoving(c.id)}>Remove</button>)}
                </div>
              </div>
              {c.error && <p className="m-0 mt-1.5 text-[13px]" style={{ color: tone === 'warn' ? '#8A5300' : '#A42219' }}>{c.error}</p>}
              {removing === c.id && <p className="m-0 mt-1.5 text-[13px] text-glass-secondary">This deletes the login, its saved token, its {c.locations} profile{c.locations === 1 ? '' : 's'} and every number and review collected for them. Nothing changes on Google.</p>}
              {replace === c.id && <div className="mt-3"><TokenForm busy={busy === c.id} onSave={(_, tok) => saveToken(c.id, tok, c.label)} onCancel={() => setReplace(null)} /></div>}
            </div>
          );
        })}
      </Section>

      <Section id="profiles" title="Business Profiles" hint="Every profile the logins above can manage. Tracked profiles are collected every night; untracked ones keep what they already have.">
        {!locs.length && <p className="m-0 text-sm text-glass-secondary">{conns.length ? 'No profile found yet. Press "Check now" on a login once Google has approved the project.' : 'Profiles appear here after a Google login is added.'}</p>}
        {locs.map((l) => {
          const login = conns.find((c) => c.id === l.connection_id);
          return (
            <div key={l.id} className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 py-3.5 border-t border-[var(--hairline)] first:border-t-0" data-profile={l.title}>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2"><span className="font-medium text-glass-primary">{l.title}</span>
                  {l.verified === false && <Chip tone="warn">Not verified on Google</Chip>}
                  {l.rating != null && <span className="text-[13px] text-glass-secondary">{Number(l.rating).toFixed(1)} ★ · {fmt(l.reviews_total)} reviews</span>}</div>
                <div className="text-[13px] text-glass-secondary">{[l.category, l.address].filter(Boolean).join(' · ') || 'No address on the profile'}{conns.length > 1 && login ? ` · via ${login.label}` : ''}</div>
                {l.maps_uri && /^https:\/\//.test(l.maps_uri) && <a href={l.maps_uri} target="_blank" rel="noopener noreferrer" className="text-[13px] text-[var(--accent)] inline-flex items-center gap-1">Open on Google Maps<Icon name="external" size={12} /></a>}
              </div>
              <label className={`inline-flex items-center gap-2 text-sm min-h-[40px] ${a.can_run ? 'cursor-pointer' : 'opacity-60'}`}>
                <input type="checkbox" className="h-5 w-5 accent-[var(--accent)]" checked={!!l.tracked} disabled={!a.can_run || !!busy} onChange={(e) => track(l, e.target.checked)} aria-label={`Track ${l.title}`} />
                {l.tracked ? 'Tracked' : 'Track'}
              </label>
            </div>
          );
        })}
      </Section>
    </div>
  );
}

// ---------------------------------------------------------------- page
const TABS = [['overview', 'Overview'], ['words', 'Search words'], ['reviews', 'Reviews'], ['manage', 'Profiles & logins']];
export default function GoogleBusiness() {
  const route = useRoute();
  const tab = TABS.some(([k]) => k === route.section) ? route.section : 'overview';
  const days = PERIODS.includes(Number(route.params.d)) ? Number(route.params.d) : 28;
  const loc = /^[0-9a-f-]{36}$/i.test(route.params.p || '') ? route.params.p : null;
  const key = `${loc || ''}|${days}`;
  const [o, setO] = useState(cache.get(key) || null);
  const [err, setErr] = useState('');
  const [running, setRunning] = useState('');
  const load = useCallback(async () => {
    try { const d = await rpc('api_gbp_overview', { p_location: loc, p_days: days }); cache.set(key, d); setO(d); setErr(''); }
    catch (e) { setErr(e.message); }
  }, [loc, days, key]);
  useEffect(() => { setO(cache.get(key) || null); load(); }, [key, load]);
  const go = (section, extra) => navigate('gbp', section === 'overview' ? '' : section, { p: loc || undefined, d: days === 28 ? undefined : days, ...(extra || {}) });
  const refresh = async () => {
    const problems = [];
    for (const [job, label] of [['discover', 'Checking the Google logins'], ['sync', 'Collecting numbers and reviews']]) {
      setRunning(label);
      try { const r = await edge([job]); Object.values(r.results || {}).forEach((x) => { if (x.status !== 'ok') problems.push(x.detail); }); cache.clear(); await load(); }
      catch (e) { problems.push(e.message); break; }
    }
    setRunning('');
    showToast(problems.length ? problems[0] : 'Google My Business is up to date', problems.length ? 'error' : 'success');
  };
  const tracked = (o?.locations || []).filter((l) => l.tracked);
  const current = tracked.find((l) => l.id === o?.selected);
  const lastRun = o ? Object.values(o.runs || {}).map((r) => r.at).sort().pop() : null;
  const s = o?.setup || {};
  const who = current ? current.title : tracked.length === 1 ? tracked[0].title : tracked.length ? `All ${tracked.length} profiles` : 'No profile yet';
  return (
    <div className="flex flex-col gap-4" data-testid="gbp">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0">
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Google My Business</h1>
          <p className="m-0 text-sm text-glass-secondary">{who} · last {days} days vs the {days} before · updated {ago(lastRun)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-[13px]">
          {tracked.length > 1 && (
            <select aria-label="Profile" value={o?.selected || ''} onChange={(e) => navigate('gbp', tab === 'overview' ? '' : tab, { p: e.target.value || undefined, d: days === 28 ? undefined : days })} className="glass-input min-h-[36px] px-2.5 text-[13px] max-w-[220px]">
              <option value="">All {tracked.length} profiles</option>
              {tracked.map((l) => <option key={l.id} value={l.id}>{l.title}</option>)}
            </select>
          )}
          <div role="group" aria-label="Period" className="inline-flex p-0.5 rounded-[10px] bg-[var(--surface-sunken)]">
            {PERIODS.map((n) => (
              <button key={n} type="button" aria-pressed={days === n} onClick={() => navigate('gbp', tab === 'overview' ? '' : tab, { p: loc || undefined, d: n === 28 ? undefined : n })}
                className={`min-h-[32px] px-3 rounded-[8px] ${days === n ? 'bg-white shadow-sm font-semibold text-glass-primary' : 'text-glass-secondary'}`}>{n} days</button>
            ))}
          </div>
          {o?.access?.can_run && Number(s.connections) > 0 && <button type="button" disabled={!!running} onClick={refresh} className="glass-btn min-h-[36px] px-3.5 inline-flex items-center gap-1.5"><Icon name="refresh" size={14} />{running ? `${running}…` : 'Refresh'}</button>}
        </div>
      </div>
      <div role="tablist" aria-label="Google My Business sections" className="flex flex-wrap gap-1 border-b border-[var(--hairline)]">
        {TABS.map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} type="button" onClick={() => go(k)}
            className={`min-h-[42px] px-3.5 -mb-px border-b-2 text-sm ${tab === k ? 'border-[var(--accent)] text-[var(--accent)] font-semibold' : 'border-transparent text-glass-secondary'}`}>{l}</button>
        ))}
      </div>
      {err && !o && <div role="alert" className="glass-card p-5 text-sm">{err} <button type="button" className="text-[var(--accent)] font-medium ml-2" onClick={load}>Try again</button></div>}
      {!o && !err && <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>}
      {o && tab !== 'manage' && !s.has_data && <Setup o={o} isAdmin={o.access?.is_admin} />}
      {o && tab === 'overview' && s.has_data && <Overview o={o} go={go} />}
      {o && tab === 'words' && s.has_data && <Words o={o} />}
      {o && tab === 'reviews' && s.has_data && <Reviews o={o} filter={route.params.f} go={go} />}
      {o && tab === 'manage' && <Manage o={o} reload={load} />}
      <p className="m-0 text-xs text-glass-secondary">Source: Google Business Profile (Performance API and reviews). Google reports people, not page loads, and publishes with a delay of a few days.</p>
    </div>
  );
}
