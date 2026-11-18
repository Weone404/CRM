import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { navigate, useRoute } from '../utils/route';
import { rpc, run, useLoad, Btn } from './adsKit';
import { edge } from './Ads';
import Icon from './icons';

// Growth > Content (migration 116). The Demand Analyst reads what people search, ask and object to; the Content Planner turns it
// into the week's reels and carousels; Reel Studio (office Mac) makes and posts them with its 5-minute rule. Ad pictures and videos
// for approved Meta strategies are made the same way and wait here until you use them in Meta (ads always stay paused).

const C = { blue: '#0A63CE', green: '#1E7B34', amber: '#8A5300', red: '#A42219', grey: 'rgba(118,118,128,0.12)', muted: 'rgba(0,0,0,0.6)' };
const STATUS = {
  planned: ['Planned', C.muted], queued: ['Sent to Reel Studio', C.blue], producing: ['Being made', C.blue], ready: ['Ready', C.green],
  posted: ['Posted', C.green], held: ['Held for you', C.amber], skipped: ['Skipped', C.muted], failed: ['Failed', C.red],
};
const KIND = { reel: 'Reel', carousel: 'Carousel', ad_image: 'Ad picture', ad_video: 'Ad video' };
const fmt = (n) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN'));
const day = (d) => new Date(d).toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Asia/Kolkata' });
const time = (d) => new Date(d).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' });
const iso = (d) => d.toISOString().slice(0, 10);
const monday = (d) => { const x = new Date(`${iso(d)}T00:00:00Z`); const w = (x.getUTCDay() + 6) % 7; x.setUTCDate(x.getUTCDate() - w); return x; };
const ago = (t) => { if (!t) return 'never'; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 2 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`; };

const Chip = ({ children, color = C.muted, bg = C.grey }) => <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ color, background: bg }}>{children}</span>;
const Status = ({ s }) => { const [l, c] = STATUS[s] || [s, C.muted]; return <Chip color={c}>{l}</Chip>; };
function Fold({ title, children, open: start = false }) {
  return (
    <details className="group" open={start}>
      <summary className="list-none cursor-pointer text-[13px] text-[var(--accent)] min-h-[28px] inline-flex items-center gap-1">
        <span className="group-open:hidden">{title}</span><span className="hidden group-open:inline">Hide</span></summary>
      <div className="pt-1">{children}</div>
    </details>);
}

// ---------------------------------------------------------------- this week
function Item({ it, canEdit, reload }) {
  const b = it.brief || {};
  const act = (action) => run(rpc('api_content_item_save', { p: { action, id: it.id } }), action === 'skip' ? 'Skipped' : 'Back in the plan').then(reload);
  return (
    <div className="py-3 border-t border-[var(--hairline)] first:border-t-0" data-testid="content-item">
      <div className="flex flex-wrap items-center gap-1.5">
        <Chip color={C.blue} bg="rgba(10,99,206,0.08)">{KIND[it.kind]}</Chip>
        <span className="text-[12px] text-glass-secondary">{time(it.slot)}</span>
        <Status s={it.status} />
        {it.source === 'manual' && <Chip>Your idea</Chip>}
        <div className="flex-1" />
        {canEdit && ['planned', 'queued', 'held', 'failed'].includes(it.status) && <button type="button" className="text-[12px] text-glass-secondary min-h-[28px]" onClick={() => act('skip')}>Skip</button>}
        {canEdit && ['skipped', 'failed', 'held'].includes(it.status) && <button type="button" className="text-[12px] text-[var(--accent)] min-h-[28px]" onClick={() => act('restore')}>Put back</button>}
      </div>
      <div className="mt-1 font-medium text-glass-primary">{it.title}</div>
      {b.hook && <div className="text-[13px] text-glass-secondary">Opens with: “{b.hook}”</div>}
      {it.status === 'posted' && <div className="mt-1 text-[13px]">{it.media?.permalink && <a href={it.media.permalink} target="_blank" rel="noreferrer">See the post</a>}
        <span className="text-glass-secondary"> · {fmt(it.stats?.views)} views · {fmt(it.stats?.shares)} sends · {fmt(it.leads)} enquiries</span></div>}
      {it.note && <div className="text-[12px]" style={{ color: it.status === 'failed' ? C.red : C.amber }}>{it.note}</div>}
      <Fold title="Why and how">
        <div className="text-[13px] space-y-1">
          {(b.evidence || []).length > 0 && <div><span className="text-glass-secondary">Because:</span> {b.evidence.map((e) => e.detail || e.signal).join('; ')}</div>}
          {b.angle && <div><span className="text-glass-secondary">Angle:</span> {b.angle}{b.persona ? ` · for ${b.persona.replace(/_/g, ' ')}` : ''}</div>}
          {(b.outline || []).length > 0 && <ol className="m-0 pl-5 list-decimal">{b.outline.map((o, i) => <li key={i}>{o}</li>)}</ol>}
          {(b.facts_to_verify || []).length > 0 && <div><span className="text-glass-secondary">Reel Studio checks:</span> {b.facts_to_verify.join('; ')}</div>}
          {(b.visual_ideas || []).length > 0 && <div><span className="text-glass-secondary">Shots:</span> {b.visual_ideas.join('; ')}</div>}
          {b.cta && <div><span className="text-glass-secondary">Ends with:</span> {b.cta}</div>}
          <div className="text-[12px] text-glass-secondary break-all">Tracked link: {it.link}</div>
        </div>
      </Fold>
    </div>);
}

function AddIdea({ week, onDone }) {
  const [f, setF] = useState({ kind: 'reel', title: '', hook: '', when: `${iso(week)}T13:30` });
  const save = async () => {
    const r = await run(rpc('api_content_item_save', { p: { action: 'add', kind: f.kind, title: f.title, hook: f.hook, slot: `${f.when}:00+05:30` } }), 'Added to the week');
    if (r) onDone();
  };
  const inp = 'glass-input w-full px-3 py-2 text-sm';
  return (
    <div className="grid gap-2 sm:grid-cols-[120px_1fr_200px] items-end pt-2" data-testid="content-add">
      <label className="text-xs text-glass-secondary">Type<select className={inp} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="reel">Reel</option><option value="carousel">Carousel</option></select></label>
      <label className="text-xs text-glass-secondary">Topic<input className={inp} value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} placeholder="e.g. A day at ground school" /></label>
      <label className="text-xs text-glass-secondary">When (India)<input type="datetime-local" className={inp} value={f.when} onChange={(e) => setF({ ...f, when: e.target.value })} /></label>
      <label className="text-xs text-glass-secondary sm:col-span-2">Opening line (optional)<input className={inp} value={f.hook} onChange={(e) => setF({ ...f, hook: e.target.value })} /></label>
      <div className="flex gap-2 justify-end"><Btn ghost onClick={onDone}>Cancel</Btn><Btn disabled={f.title.trim().length < 5} onClick={save}>Add</Btn></div>
    </div>);
}

function Week({ d, week, reload, go }) {
  const [note, setNote] = useState('');
  const [adding, setAdding] = useState(false);
  const p = d.plan;
  const byDay = useMemo(() => {
    const m = new Map();
    for (let i = 0; i < 7; i++) { const x = new Date(week); x.setUTCDate(x.getUTCDate() + i); m.set(iso(x), []); }
    for (const it of d.items || []) { const k = new Date(it.slot).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }); if (m.has(k)) m.get(k).push(it); }
    return [...m.entries()];
  }, [d.items, week]);
  const plan = () => run(rpc('api_content_plan', { p_week: iso(week), p_note: note || null }), 'The agents are planning the week (about 10-20 minutes)').then(() => { setNote(''); reload(); });
  const working = p?.status === 'working';
  return (
    <div className="space-y-4">
      <section className="glass-card p-5 space-y-2" data-testid="content-plan">
        <div className="flex flex-wrap items-start gap-3">
          <div className="flex-1 min-w-[220px]">
            <h2 className="m-0 text-base font-semibold">{p ? (working ? 'The agents are planning this week' : p.status === 'failed' ? 'Planning stopped' : 'The plan for this week') : 'No plan for this week yet'}</h2>
            <p className="m-0 text-[13px] text-glass-secondary">{working ? p.working_note : p?.status === 'failed' ? p.working_note : p?.summary
              || 'The Demand Analyst reads Google searches, lead answers and competitors; the Content Planner turns them into reels and carousels. Next week is planned every Sunday evening.'}</p>
          </div>
          {d.can_edit && !working && <div className="flex flex-wrap gap-2 items-center w-full sm:w-auto">
            <input aria-label="Anything to focus on" className="glass-input px-3 py-2 text-sm flex-1 sm:w-64" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Anything to focus on? (optional)" />
            <Btn onClick={plan} data-testid="content-plan-btn">{p ? 'Plan again' : 'Plan this week'}</Btn></div>}
        </div>
        {p?.note && <div className="text-[12px] text-glass-secondary">You asked: {p.note}</div>}
      </section>
      <section className="glass-card p-5" data-testid="content-week">
        {byDay.map(([k, items]) => (
          <div key={k} className="py-2 border-t border-[var(--hairline)] first:border-t-0">
            <div className="text-[13px] font-semibold text-glass-secondary">{day(`${k}T12:00:00+05:30`)}</div>
            {items.length ? items.map((it) => <Item key={it.id} it={it} canEdit={d.can_edit} reload={reload} />) : <div className="text-[13px] text-glass-secondary py-1">Nothing planned.</div>}
          </div>))}
        {d.can_edit && (adding ? <AddIdea week={week} onDone={() => { setAdding(false); reload(); }} />
          : <div className="pt-2"><Btn ghost onClick={() => setAdding(true)}><Icon name="plus" size={14} />Add your own idea</Btn></div>)}
      </section>
      {p?.demand && <button type="button" className="text-sm text-[var(--accent)]" onClick={() => go('ideas')}>Why these topics? See what people are asking</button>}
    </div>);
}

// ---------------------------------------------------------------- ideas (the Demand Analyst's brief)
function Ideas({ d }) {
  const a = d.plan?.demand;
  if (!a) return <section className="glass-card p-5 text-sm text-glass-secondary">The Demand Analyst's brief appears here once a week is planned.</section>;
  const list = (title, xs) => (xs || []).length > 0 && <section className="glass-card p-5"><h3 className="m-0 mb-2 text-base font-semibold">{title}</h3>
    <ul className="m-0 pl-5 list-disc text-sm space-y-1">{xs.map((x, i) => <li key={i}>{typeof x === 'string' ? x : `${x.when}: ${x.what}`}{x?.source && <> · <a href={x.source} target="_blank" rel="noreferrer">source</a></>}</li>)}</ul></section>;
  return (
    <div className="space-y-4" data-testid="content-ideas">
      <section className="glass-card p-5">
        <h3 className="m-0 mb-1 text-base font-semibold">What people want to know</h3>
        <p className="m-0 mb-3 text-[13px] text-glass-secondary whitespace-pre-line">{a.summary}</p>
        {(a.demand || []).sort((x, y) => (x.priority || 9) - (y.priority || 9)).map((t, i) => (
          <div key={i} className="py-2.5 border-t border-[var(--hairline)] first-of-type:border-t-0">
            <div className="flex flex-wrap items-center gap-1.5"><b className="text-sm">{t.topic}</b>{t.persona && <Chip>{t.persona.replace(/_/g, ' ')}</Chip>}{t.priority && <Chip color={t.priority <= 2 ? C.green : C.muted}>priority {t.priority}</Chip>}</div>
            <div className="text-[13px] text-glass-secondary">{t.why}</div>
            {(t.evidence || []).length > 0 && <div className="text-[12px] text-glass-secondary">{t.evidence.map((e) => `${e.signal}: ${e.detail}`).join(' · ')}</div>}
          </div>))}
      </section>
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))' }}>
        {list('Questions people ask', a.questions)}{list('Worries to answer', a.objections)}{list('Gaps competitors leave', a.gaps)}{list('Dates that matter', a.season)}{list('Stop doing', a.avoid)}
      </div>
    </div>);
}

// ---------------------------------------------------------------- ad creatives
function Picture({ path }) {
  const [url, setUrl] = useState(null);
  useEffect(() => { let on = true; supabase.storage.from('content').createSignedUrl(path, 3600).then(({ data }) => { if (on) setUrl(data?.signedUrl || null); }); return () => { on = false; }; }, [path]);
  return url ? <img src={url} alt="" className="h-40 rounded-lg border border-[var(--hairline)] object-cover" /> : <div className="h-40 w-32 rounded-lg bg-[var(--surface-sunken)]" />;
}
function AdCreatives({ d, reload }) {
  const [sid, setSid] = useState('');
  const order = () => run(rpc('api_content_from_strategy', { p_strategy_id: Number(sid) }), 'Sent to Reel Studio: it makes each ad picture and video').then(reload);
  const useInMeta = async (it) => {
    const path = it.paths?.['1080x1350'] || Object.values(it.paths || {})[0];
    const { data, error } = await supabase.storage.from('content').download(path);
    if (error) { showToast(error.message, 'error'); return; }
    const b64 = await new Promise((res, rej) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result)); fr.onerror = rej; fr.readAsDataURL(data); });
    await run(edge({ jobs: ['meta_image'], strategy_id: it.strategy_id, creative_key: it.creative_key, image_base64: b64, filename: path.split('/').pop() }), 'Picture added to the ad in Meta (still paused)');
  };
  return (
    <div className="space-y-4" data-testid="content-ads">
      <section className="glass-card p-5 space-y-2">
        <h3 className="m-0 text-base font-semibold">Ad pictures and videos</h3>
        <p className="m-0 text-[13px] text-glass-secondary">Reel Studio makes every image and video ad of an approved Meta strategy from its visual brief, in feed and Story sizes. Pictures come back here; “Use in Meta” adds one to its ad, which stays paused until you switch it on in Ads Manager.</p>
        {d.can_edit && ((d.strategies || []).length ? <div className="flex flex-wrap gap-2">
          <select aria-label="Strategy" className="glass-input px-3 py-2 text-sm flex-1 min-w-[220px]" value={sid} onChange={(e) => setSid(e.target.value)}>
            <option value="">Pick an approved strategy</option>{d.strategies.map((s) => <option key={s.id} value={s.id}>{s.title} (v{s.approved_version})</option>)}</select>
          <Btn disabled={!sid} onClick={order} data-testid="content-order">Make its ads</Btn></div>
          : <div className="text-[13px] text-glass-secondary">Approve a strategy in Meta Ads &gt; Strategy first.</div>)}
      </section>
      <section className="glass-card p-5">
        {!(d.ad_creatives || []).length ? <div className="text-sm text-glass-secondary">Nothing ordered yet.</div> : d.ad_creatives.map((it) => (
          <div key={it.id} className="py-3 border-t border-[var(--hairline)] first:border-t-0 space-y-1.5" data-testid="content-ad">
            <div className="flex flex-wrap items-center gap-1.5"><Chip color={C.blue} bg="rgba(10,99,206,0.08)">{KIND[it.kind]}</Chip><Status s={it.status} /><b className="text-sm">{it.title}</b></div>
            {it.brief?.visual_brief && <div className="text-[13px] text-glass-secondary">{it.brief.visual_brief}</div>}
            {Object.keys(it.paths || {}).length > 0 && <div className="flex flex-wrap gap-2">{Object.entries(it.paths).map(([size, path]) => <div key={size}><Picture path={path} /><div className="text-[11px] text-glass-secondary">{size}</div></div>)}</div>}
            {it.video && <a className="text-[13px]" href={it.video} target="_blank" rel="noreferrer">Watch the ad video</a>}
            {it.note && <div className="text-[12px]" style={{ color: C.amber }}>{it.note}</div>}
            {d.can_edit && it.kind === 'ad_image' && it.has_picture && <Btn ghost onClick={() => useInMeta(it)}>Use in Meta</Btn>}
          </div>))}
      </section>
    </div>);
}

// ---------------------------------------------------------------- results
function Results({ d }) {
  const rows = d.results || [];
  const tot = rows.reduce((a, r) => ({ views: a.views + (Number(r.stats?.views) || 0), leads: a.leads + (Number(r.leads) || 0) }), { views: 0, leads: 0 });
  return (
    <section className="glass-card p-5" data-testid="content-results">
      <h3 className="m-0 mb-1 text-base font-semibold">What the posts brought</h3>
      <p className="m-0 mb-3 text-[13px] text-glass-secondary">Last {rows.length} posts: {fmt(tot.views)} views and {fmt(tot.leads)} website enquiries through their own links. The planner reads this every week.</p>
      {!rows.length ? <div className="text-sm text-glass-secondary">Nothing posted through the plan yet.</div> : (
        <div className="overflow-x-auto"><table className="w-full text-sm border-collapse min-w-[520px]">
          <thead><tr className="text-left text-xs text-glass-secondary"><th className="font-medium py-2">Post</th><th className="font-medium text-right">Views</th><th className="font-medium text-right">Sends</th><th className="font-medium text-right">Saves</th><th className="font-medium text-right">Enquiries</th></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.id} className="border-t border-[var(--hairline)]">
              <td className="py-2.5 pr-2">{r.permalink ? <a href={r.permalink} target="_blank" rel="noreferrer">{r.title}</a> : r.title}<div className="text-[12px] text-glass-secondary">{KIND[r.kind]} · {day(r.slot)}</div></td>
              <td className="text-right">{fmt(r.stats?.views)}</td><td className="text-right">{fmt(r.stats?.shares)}</td><td className="text-right">{fmt(r.stats?.saves)}</td><td className="text-right font-semibold">{fmt(r.leads)}</td>
            </tr>))}</tbody></table></div>)}
    </section>);
}

// ---------------------------------------------------------------- page
const TABS = [['week', 'This week'], ['ideas', 'Ideas'], ['ads', 'Ad creatives'], ['results', 'Results']];
export default function Content() {
  const route = useRoute();
  const tab = TABS.some(([k]) => k === route.section) ? route.section : 'week';
  const [week, setWeek] = useState(() => monday(new Date()));
  const [d, reload] = useLoad(() => rpc('api_content_overview', { p_week: iso(week) }), [iso(week)], { refreshMs: 30000 });
  const go = (t) => navigate('content', t === 'week' ? '' : t);
  const shift = (n) => { const x = new Date(week); x.setUTCDate(x.getUTCDate() + 7 * n); setWeek(x); };
  const seen = d?.studio?.last_seen;
  const online = seen && Date.now() - Date.parse(seen) < 15 * 60e3;
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Content</h1>
          <p className="m-0 text-sm text-glass-secondary">Reels, carousels and ad creatives, planned from what people search and ask · made by Reel Studio</p>
        </div>
        <div className="flex items-center gap-2 text-[12px]">
          <span className="px-2.5 py-1 rounded-full" style={online ? { background: 'rgba(30,123,52,0.10)', color: C.green } : { background: 'rgba(178,106,0,0.12)', color: C.amber }}>
            Reel Studio {online ? 'connected' : seen ? `last seen ${ago(seen)}` : 'not connected yet'}</span>
        </div>
      </div>
      <div role="tablist" aria-label="Content sections" className="flex flex-wrap gap-1 border-b border-[var(--hairline)]">
        {TABS.map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} type="button" onClick={() => go(k)}
            className={`min-h-[42px] px-3.5 -mb-px border-b-2 text-sm ${tab === k ? 'border-[var(--accent)] text-[var(--accent)] font-semibold' : 'border-transparent text-glass-secondary'}`}>{l}</button>))}
      </div>
      {(tab === 'week' || tab === 'ideas') && (
        <div className="flex items-center gap-2 text-sm">
          <button type="button" aria-label="Previous week" className="glass-btn-ghost min-h-[34px] px-2" onClick={() => shift(-1)}><span style={{ display: 'inline-flex', transform: 'rotate(90deg)' }}><Icon name="chevronDown" size={16} /></span></button>
          <b>Week of {week.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' })}</b>
          <button type="button" aria-label="Next week" className="glass-btn-ghost min-h-[34px] px-2" onClick={() => shift(1)}><span style={{ display: 'inline-flex', transform: 'rotate(-90deg)' }}><Icon name="chevronDown" size={16} /></span></button>
        </div>)}
      {!d ? <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div> : <>
        {tab === 'week' && <Week d={d} week={week} reload={reload} go={go} />}
        {tab === 'ideas' && <Ideas d={d} />}
        {tab === 'ads' && <AdCreatives d={d} reload={reload} />}
        {tab === 'results' && <Results d={d} />}
      </>}
    </div>);
}
