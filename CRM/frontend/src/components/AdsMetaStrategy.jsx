import { useState } from 'react';
import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';
import { inr } from '../../../supabase/functions/_shared/meta_patterns.ts';
import { showToast } from '../utils/toast';
import AdsMetaCompetitors from './AdsMetaCompetitors';

// CRM > Meta Ads > Strategy (migration 104). The owner sets a goal; the ADS agents (Researcher -> Strategist -> Reviewer)
// write a full plan from the account's 37-month history, the CRM's results and current research. Every change is a new
// version. Approve a version, then optionally Create in Meta (everything paused) and follow plan vs actual each week.

const C = { blue: '#0088FF', green: '#1E9E4A', red: '#D93025', amber: '#B25E00', grey: 'rgba(118,118,128,0.14)', ink: '#1C1C1E' };
const N = (v) => Number(v) || 0;
const fmt = (v) => Math.round(N(v)).toLocaleString('en-IN');
const COURSES = ['CPL', 'PPL', 'ATPL', 'DGCA Ground Classes', 'Type Rating', 'Cabin Crew', 'Charter flights'];
const LANGS = ['English', 'Hinglish', 'Hindi'];
const STATUS = {
  working: ['Agents working', C.blue], ready: ['Ready for you', C.green], needs_review: ['Needs your review', C.amber],
  failed: ['Stopped', C.red], approved: ['Approved', C.green], archived: ['Archived', 'rgba(60,60,67,0.6)'],
};
const ROLE = { meta_researcher: 'Researcher', meta_strategist: 'Strategist', meta_reviewer: 'Reviewer' };
const SRC = { history: ['Your history', C.green], benchmark: ['Benchmark', C.amber], owner: ['Your input', C.blue], research: ['Research', C.amber] };
const ago = (t) => { if (!t) return ''; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };

const Chip = ({ children, color = C.ink, testid }) => (
  <span data-testid={testid} className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: C.grey, color }}>{children}</span>);
function Card({ title, sub, children, testid, right }) {
  return (
    <section className="glass-card p-4 space-y-3 break-inside-avoid" data-testid={testid}>
      {(title || right) && <div className="flex items-start gap-2"><div className="flex-1"><h3 className="font-bold text-glass-primary">{title}</h3>
        {sub && <div className="text-xs text-glass-muted">{sub}</div>}</div>{right}</div>}
      {children}
    </section>);
}
const Field = ({ label, children, hint, group }) => (group
  ? <div role="group" aria-label={label} className="block text-sm space-y-1"><span className="font-semibold">{label}</span>{children}{hint && <span className="block text-[11px] text-glass-muted">{hint}</span>}</div>
  : <label className="block text-sm space-y-1"><span className="font-semibold">{label}</span>{children}{hint && <span className="block text-[11px] text-glass-muted">{hint}</span>}</label>);

// ---------------------------------------------------------------- goal form
function GoalForm({ initial, onSubmit, submit, onCancel }) {
  const g0 = initial || {};
  const [g, setG] = useState({
    objective: g0.objective || 'admissions', target_per_month: g0.target_per_month ?? '', monthly_budget: g0.monthly_budget ?? '',
    courses: g0.courses || ['CPL'], locations: (g0.locations || ['Delhi NCR']).join(', '), languages: g0.languages || ['English', 'Hinglish'],
    start_date: g0.start_date || '', months: g0.months || 1, lead_to_admission_pct: g0.lead_to_admission_pct ?? '', admission_value: g0.admission_value ?? '',
    pipeline: g0.pipeline || 'pilot_training', website_url: g0.website_url || 'https://weoneaviation.in', privacy_url: g0.privacy_url || '', notes: g0.notes || '',
  });
  const set = (k) => (e) => setG({ ...g, [k]: e.target.value });
  const toggle = (k, v) => setG({ ...g, [k]: g[k].includes(v) ? g[k].filter((x) => x !== v) : [...g[k], v] });
  const body = () => ({ ...g, locations: g.locations.split(',').map((s) => s.trim()).filter(Boolean) });
  return (
    <div className="space-y-3" data-testid="goal-form">
      <div className="grid sm:grid-cols-3 gap-3">
        <Field label="Aim for">
          <select aria-label="Aim for" className="glass-input w-full px-3 py-2 text-sm" value={g.objective} onChange={set('objective')}>
            <option value="admissions">Admissions</option><option value="qualified">Qualified leads</option><option value="leads">Leads</option></select></Field>
        <Field label="Target per month" hint="Optional if you set a budget">
          <input aria-label="Target per month" inputMode="numeric" className="glass-input w-full px-3 py-2 text-sm" value={g.target_per_month} onChange={set('target_per_month')} placeholder="e.g. 10" /></Field>
        <Field label="Monthly budget limit (₹)" hint="Leave empty to let the agents suggest one">
          <input aria-label="Monthly budget" inputMode="numeric" className="glass-input w-full px-3 py-2 text-sm" value={g.monthly_budget} onChange={set('monthly_budget')} placeholder="e.g. 30000" /></Field>
      </div>
      <Field label="Courses" group>
        <div className="flex flex-wrap gap-1.5">{COURSES.map((c) => (
          <button key={c} type="button" aria-pressed={g.courses.includes(c)} onClick={() => toggle('courses', c)} className="px-2.5 py-1 rounded-full text-xs font-semibold"
            style={g.courses.includes(c) ? { background: C.blue, color: '#fff' } : { background: C.grey }}>{c}</button>))}</div></Field>
      <div className="grid sm:grid-cols-2 gap-3">
        <Field label="Where" hint="Cities, states or India, separated by commas">
          <input aria-label="Locations" className="glass-input w-full px-3 py-2 text-sm" value={g.locations} onChange={set('locations')} /></Field>
        <Field label="Ad language" group>
          <div className="flex gap-1.5">{LANGS.map((l) => (
            <button key={l} type="button" aria-pressed={g.languages.includes(l)} onClick={() => toggle('languages', l)} className="px-2.5 py-1 rounded-full text-xs font-semibold"
              style={g.languages.includes(l) ? { background: C.blue, color: '#fff' } : { background: C.grey }}>{l}</button>))}</div></Field>
      </div>
      <div className="grid sm:grid-cols-4 gap-3">
        <Field label="Start"><input aria-label="Start date" type="date" className="glass-input w-full px-3 py-2 text-sm" value={g.start_date} onChange={set('start_date')} /></Field>
        <Field label="Plan length">
          <select aria-label="Plan length" className="glass-input w-full px-3 py-2 text-sm" value={g.months} onChange={set('months')}>
            {[1, 2, 3, 6].map((m) => <option key={m} value={m}>{m} month{m > 1 ? 's' : ''}</option>)}</select></Field>
        <Field label="Leads that join (%)" hint="Optional: from your experience">
          <input aria-label="Lead to admission percent" inputMode="decimal" className="glass-input w-full px-3 py-2 text-sm" value={g.lead_to_admission_pct} onChange={set('lead_to_admission_pct')} placeholder="e.g. 2" /></Field>
        <Field label="Value of one admission (₹)" hint="Optional">
          <input aria-label="Admission value" inputMode="numeric" className="glass-input w-full px-3 py-2 text-sm" value={g.admission_value} onChange={set('admission_value')} /></Field>
      </div>
      <div className="grid sm:grid-cols-3 gap-3">
        <Field label="Pipeline">
          <select aria-label="Pipeline" className="glass-input w-full px-3 py-2 text-sm" value={g.pipeline} onChange={set('pipeline')}>
            <option value="pilot_training">Pilot Training</option><option value="charter">Charter</option></select></Field>
        <Field label="Website"><input aria-label="Website" className="glass-input w-full px-3 py-2 text-sm" value={g.website_url} onChange={set('website_url')} /></Field>
        <Field label="Privacy policy link" hint="Meta needs it on lead forms">
          <input aria-label="Privacy policy" className="glass-input w-full px-3 py-2 text-sm" value={g.privacy_url} onChange={set('privacy_url')} placeholder="https://weoneaviation.in/privacy-policy" /></Field>
      </div>
      <Field label="Anything the agents should know" hint="Offers, batch dates, what to avoid, facts they can use">
        <textarea aria-label="Notes" rows={3} maxLength={2000} className="glass-input w-full px-3 py-2 text-sm" value={g.notes} onChange={set('notes')} /></Field>
      <div className="flex gap-2 justify-end">
        {onCancel && <Btn ghost onClick={onCancel}>Cancel</Btn>}
        <Btn onClick={() => onSubmit(body())} data-testid="goal-submit">{submit}</Btn>
      </div>
    </div>);
}

// ---------------------------------------------------------------- plan sections
function Forecast({ p, goal }) {
  const f = p.forecast || {}, s = f.scenarios || {};
  const col = (k, label, color) => {
    const x = s[k] || {};
    return (
      <div className="glass-card p-3" style={{ borderTop: `3px solid ${color}` }} data-testid={`scenario-${k}`}>
        <div className="text-[11px] text-glass-muted">{label}</div>
        <div className="text-xl font-bold">{fmt(x.leads)} leads</div>
        <div className="text-xs">{inr(x.cpl)} per lead · {inr(x.spend)} spend</div>
        <div className="text-xs text-glass-secondary">{x.qualified !== undefined && `${fmt(x.qualified)} qualified`}{x.admissions !== undefined && ` · ${fmt(x.admissions)} admissions`}</div>
        {goal?.admission_value && x.admissions ? <div className="text-[11px] text-glass-muted">≈ {inr(x.admissions * goal.admission_value)} in admissions</div> : null}
      </div>);
  };
  return (
    <Card title="Expected outcome" sub={`Over ${f.horizon_days || 30} days. Ranges, not promises: every assumption says where it comes from.`} testid="plan-forecast">
      <div className="grid sm:grid-cols-3 gap-2">{col('low', 'If it goes badly', C.red)}{col('likely', 'Most likely', C.blue)}{col('high', 'If it goes well', C.green)}</div>
      {f.math && <div className="text-xs text-glass-secondary whitespace-pre-wrap"><b>Maths: </b>{f.math}</div>}
      <table className="w-full text-xs"><tbody>{(f.assumptions || []).map((a, i) => (
        <tr key={i} className="border-t border-black/5"><td className="py-1 pr-2 font-semibold">{a.name}</td><td className="py-1 pr-2">{a.value}</td>
          <td className="py-1 pr-2"><Chip color={(SRC[a.source] || [])[1]}>{(SRC[a.source] || [a.source])[0]}</Chip></td><td className="py-1 text-glass-muted">{a.note}</td></tr>))}</tbody></table>
    </Card>);
}

function Budget({ p }) {
  const b = p.budget || {};
  const sets = (p.campaigns || []).flatMap((c) => (c.budget_level === 'campaign'
    ? [{ name: `${c.name} (campaign budget)`, daily: N(c.daily_budget) }]
    : (c.adsets || []).map((a) => ({ name: a.name, daily: N(a.daily_budget) }))));
  const max = Math.max(1, ...sets.map((x) => x.daily));
  return (
    <Card title="Budget" sub={`${inr(b.monthly_total)} a month · ${inr(b.daily_total)} a day`} testid="plan-budget">
      <div className="space-y-1">{sets.map((x, i) => (
        <div key={i} className="flex items-center gap-2 text-sm"><div className="w-48 shrink-0 truncate">{x.name}</div>
          <div className="flex-1 h-4 rounded" style={{ background: C.grey }}><div className="h-full rounded" style={{ width: `${(x.daily / max) * 100}%`, background: C.blue }} /></div>
          <div className="w-24 text-right font-semibold">{inr(x.daily)}/day</div></div>))}</div>
      {(b.phases || []).length > 0 && <table className="w-full text-xs"><tbody>{b.phases.map((ph, i) => (
        <tr key={i} className="border-t border-black/5"><td className="py-1 pr-2 font-semibold">{ph.name}</td><td className="py-1 pr-2">Days {ph.days}</td>
          <td className="py-1 pr-2">{inr(ph.daily)}/day</td><td className="py-1 text-glass-muted">{ph.focus}</td></tr>))}</tbody></table>}
    </Card>);
}

const audienceText = (au = {}) => [
  (au.locations || []).map((l) => `${l.name}${l.radius_km ? ` +${l.radius_km} km` : ''}`).join(', '),
  `age ${au.age_min ?? 18}-${au.age_max ?? 65}`, au.genders && au.genders !== 'all' ? au.genders : null,
  (au.interests || []).length ? `interests: ${au.interests.join(', ')}` : null, au.advantage_audience ? 'Advantage+ audience' : 'set audience',
].filter(Boolean).join(' · ');

function Structure({ p }) {
  const cr = Object.fromEntries((p.creatives || []).map((c) => [c.key, c]));
  const fm = Object.fromEntries((p.forms || []).map((f) => [f.key, f]));
  return (
    <Card title="Campaign structure" sub="Campaign → ad sets (who sees it, budget) → ads" testid="plan-structure">
      {(p.campaigns || []).map((c) => (
        <div key={c.key} className="space-y-2">
          <div className="font-semibold">{c.name} <Chip>{c.objective === 'OUTCOME_LEADS' ? 'Leads (instant form)' : c.objective}</Chip>
            {c.budget_level === 'campaign' && <Chip>{inr(c.daily_budget)}/day for the campaign</Chip>}</div>
          {c.reason && <div className="text-xs text-glass-secondary">{c.reason}</div>}
          <div className="grid md:grid-cols-2 gap-2">{(c.adsets || []).map((a) => (
            <div key={a.key} className="rounded-xl p-3 space-y-1" style={{ background: 'rgba(118,118,128,0.06)' }}>
              <div className="font-semibold text-sm">{a.name} {c.budget_level !== 'campaign' && <span className="text-glass-muted font-normal">· {inr(a.daily_budget)}/day</span>}</div>
              <div className="text-xs">{audienceText(a.audience)}</div>
              <div className="text-xs text-glass-secondary">Placements: {a.placements === 'advantage' ? 'Advantage+ (Meta picks)' : (a.placements || []).join(', ')}
                {' · '}Optimise for {a.optimization === 'QUALITY_LEAD' ? 'qualified leads' : 'leads'}</div>
              <div className="text-xs">Form: <b>{fm[a.form]?.name || a.form}</b> · Ads: {(a.ads || []).map((k) => cr[k]?.name || k).join(', ')}</div>
              {a.reason && <div className="text-[11px] text-glass-muted">{a.reason}</div>}
            </div>))}</div>
        </div>))}
    </Card>);
}

function Forms({ p }) {
  return (
    <Card title="Lead forms" testid="plan-forms">
      <div className="grid md:grid-cols-2 gap-2">{(p.forms || []).map((f) => (
        <div key={f.key} className="rounded-xl p-3 space-y-1 text-sm" style={{ background: 'rgba(118,118,128,0.06)' }}>
          <div className="font-semibold">{f.name} <Chip>{f.type === 'higher_intent' ? 'Higher intent' : 'More volume'}</Chip></div>
          {f.headline && <div className="text-xs"><b>{f.headline}</b> {f.intro}</div>}
          <ol className="text-xs list-decimal pl-5">{(f.questions || []).map((q, i) => (
            <li key={i}>{q.type === 'CUSTOM' ? <>{q.label}{(q.options || []).length > 0 && <span className="text-glass-muted"> ({q.options.join(' / ')})</span>}</>
              : { FULL_NAME: 'Full name', PHONE: 'Phone number', EMAIL: 'Email', CITY: 'City', STATE: 'State' }[q.type] || q.type}</li>))}</ol>
          {f.thank_you?.title && <div className="text-[11px] text-glass-muted">After sending: {f.thank_you.title}. {f.thank_you.body}</div>}
        </div>))}</div>
    </Card>);
}

function Creatives({ p, images, admin, onUpload }) {
  const copyAll = (c) => navigator.clipboard?.writeText(`${c.primary_text}\n\nHeadline: ${c.headline}${c.description ? `\nDescription: ${c.description}` : ''}\nButton: ${c.cta}`)
    .then(() => showToast('Ad text copied', 'success')).catch(() => {});
  return (
    <Card title="Creatives" sub="Ready-to-use ad text and a brief for the picture or video" testid="plan-creatives">
      <div className="grid md:grid-cols-2 gap-2">{(p.creatives || []).map((c) => (
        <div key={c.key} className="rounded-xl p-3 space-y-1.5 text-sm" style={{ background: 'rgba(118,118,128,0.06)' }} data-testid="creative">
          <div className="flex items-center gap-2"><b className="flex-1">{c.name}</b><Chip>{c.format}</Chip><Chip>{(c.cta || '').replace('_', ' ').toLowerCase()}</Chip></div>
          {c.angle && <div className="text-[11px] text-glass-muted">Angle: {c.angle}</div>}
          <div className="whitespace-pre-wrap">{c.primary_text}</div>
          <div className="text-xs"><b>{c.headline}</b>{c.description ? ` · ${c.description}` : ''}</div>
          <div className="text-xs text-glass-secondary"><b>Visual: </b>{c.visual_brief}</div>
          {c.why && <div className="text-[11px] text-glass-muted">Why: {c.why}</div>}
          <div className="flex flex-wrap gap-2 no-print">
            <Btn ghost onClick={() => copyAll(c)}><Icon name="copy" size={14} />Copy text</Btn>
            {admin && c.format === 'image' && onUpload && (
              <label className="px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center gap-1.5 cursor-pointer" style={{ background: C.grey }}>
                <Icon name="image" size={14} />{images?.[c.key]?.hash ? 'Picture added ✓ (replace)' : 'Add picture for Meta'}
                <input type="file" accept="image/png,image/jpeg" className="hidden" aria-label={`Picture for ${c.name}`} onChange={(e) => e.target.files?.[0] && onUpload(c.key, e.target.files[0])} />
              </label>)}
          </div>
        </div>))}</div>
    </Card>);
}

const List = ({ title, items, testid, render }) => (items || []).length > 0 && (
  <Card title={title} testid={testid}><ul className="text-sm space-y-1 list-disc pl-5">{items.map((x, i) => <li key={i}>{render ? render(x) : x}</li>)}</ul></Card>);

function Research({ v }) {
  const r = v.research || {};
  const [open, setOpen] = useState(false);
  const sources = [...(v.plan?.sources || []), ...(r.sources || [])].filter((s, i, a) => s?.url && a.findIndex((x) => x.url === s.url) === i);
  return (
    <Card title="Research and sources" sub="What the Researcher found (current Meta guidance, benchmarks, timing, competitors)" testid="plan-research"
      right={<Btn ghost onClick={() => setOpen(!open)}>{open ? 'Less' : 'More'}</Btn>}>
      {r.summary && <div className="text-sm whitespace-pre-wrap">{r.summary}</div>}
      {open && <>
        {(r.benchmarks || []).length > 0 && <table className="w-full text-xs"><tbody>{r.benchmarks.map((b, i) => (
          <tr key={i} className="border-t border-black/5"><td className="py-1 pr-2 font-semibold">{b.metric}</td><td className="py-1 pr-2">{b.value}</td><td className="py-1 text-glass-muted">{b.note}</td></tr>))}</tbody></table>}
        {(r.facts || []).length > 0 && <ul className="text-xs list-disc pl-5">{r.facts.map((f, i) => <li key={i}>{f.fact}{f.url && <> · <a className="underline" href={f.url} target="_blank" rel="noreferrer">source</a></>}</li>)}</ul>}
        {(r.competitors || []).length > 0 && <div className="text-xs"><b>Competitors: </b>{r.competitors.map((c) => `${c.name}${c.angle ? ` (${c.angle})` : ''}`).join('; ')}</div>}
        {(r.gaps || []).length > 0 && <div className="text-xs" style={{ color: C.amber }}><b>Could not verify: </b>{r.gaps.join('; ')}</div>}
      </>}
      {sources.length > 0 && <div className="text-xs space-y-0.5">{sources.slice(0, open ? 50 : 6).map((s, i) => (
        <div key={i}><a className="underline" href={s.url} target="_blank" rel="noreferrer">{s.title || s.url}</a></div>))}</div>}
    </Card>);
}

function Review({ v }) {
  const r = v.review || {};
  const ok = r.verdict === 'approve';
  return (
    <div className="glass-card p-3 text-sm space-y-1" style={{ borderLeft: `4px solid ${ok ? C.green : C.amber}` }} data-testid="plan-review">
      <b>{ok ? 'Reviewer approved this plan' : `Not approved by the ${r.by === 'code checks' ? 'CRM checks' : 'Reviewer'} after 3 tries: read the points below before you use it`}</b>
      {r.notes && <div className="text-xs">{r.notes}</div>}
      {(r.problems || []).length > 0 && <ul className="text-xs list-disc pl-5">{r.problems.map((x, i) => <li key={i}>{x}</li>)}</ul>}
    </div>);
}

// ---------------------------------------------------------------- Create in Meta, plan vs actual
function Build({ d, edge, reload }) {
  const s = d.strategy, b = s.build || {};
  const steps = Object.entries(b.steps || {});
  const tone = { done: C.green, manual: C.amber, waiting: C.amber, error: C.red };
  const go = async () => {
    await rpc('api_ads_meta_strategy_build', { p_id: s.id });
    const r = await edge({ jobs: ['meta_build'], strategy_id: s.id });
    const res = r?.results?.meta_build;
    showToast(res?.detail || 'Done', res?.status === 'error' ? 'error' : 'success');
    reload();
  };
  return (
    <Card title="Create in Meta" sub="Builds the approved version in your ad account with everything PAUSED. You check it in Ads Manager and switch it on there." testid="plan-build"
      right={<Btn onClick={go} disabled={!d.can_build} data-testid="build-go"><Icon name="rocket" size={14} />{steps.length ? 'Create the rest' : 'Create in Meta (paused)'}</Btn>}>
      {!d.can_build && <div className="text-xs" style={{ color: C.amber }}>Connect the Meta ad account and add the Facebook Page ID first (Meta Ads → Setup).</div>}
      <div className="text-xs text-glass-muted">Image ads need their picture (Add picture on each creative). Video and carousel ads are left for you to make in Ads Manager with the text from the plan.</div>
      {b.detail && <div className="text-sm"><b>{b.status === 'done' ? 'Done: ' : b.status === 'error' ? 'Stopped: ' : ''}</b>{b.detail} {b.ended_at && <span className="text-glass-muted">· {ago(b.ended_at)}</span>}</div>}
      {steps.length > 0 && <div className="space-y-0.5 text-xs">{steps.map(([k, st]) => (
        <div key={k} className="flex gap-2"><span className="w-40 truncate font-mono">{k}</span><span style={{ color: tone[st.status] || C.ink }}>{st.status}</span>
          <span className="flex-1 text-glass-muted truncate">{st.id ? `id ${st.id}` : ''} {st.note || st.error || ''}</span></div>))}</div>}
      {steps.some(([, st]) => st.id) && <a className="text-xs underline" href="https://adsmanager.facebook.com/adsmanager/manage/campaigns" target="_blank" rel="noreferrer">Open Ads Manager</a>}
    </Card>);
}

function Tracking({ d, admin, reload }) {
  const s = d.strategy, ss = d.since_start;
  const [links, setLinks] = useState(null);
  const cur = links ?? s.links ?? {};
  const camps = d.current?.plan?.campaigns || [];
  const built = Object.entries(s.build?.steps || {}).filter(([k, v]) => k.startsWith('campaign:') && v.id);
  const verdict = { on_track: ['On track', C.green], behind: ['Behind plan', C.red], ahead: ['Ahead of plan', C.green], no_data: ['No spend yet', C.amber] };
  return (
    <Card title="Plan vs actual" sub="Checked every Monday for the week before. If the plan falls behind, the Strategist drafts a revision for you to approve." testid="plan-tracking">
      {ss && <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
        {[['Spend', inr(ss.actual?.spend), `plan ${inr(ss.planned?.spend)}`], ['Meta leads', fmt(ss.actual?.meta_leads), `plan ${fmt(ss.planned?.leads)}`],
          ['Cost per lead', inr(ss.actual?.cpl), `plan ${inr(ss.planned?.cpl)}`], ['In CRM · qualified · admitted', `${fmt(ss.actual?.crm_leads)} · ${fmt(ss.actual?.qualified)} · ${fmt(ss.actual?.customers)}`, `since ${ss.from}`]]
          .map(([l, v, sub]) => <div key={l} className="glass-card p-3"><div className="text-[11px] text-glass-muted">{l}</div><div className="text-lg font-bold">{v}</div><div className="text-[11px] text-glass-muted">{sub}</div></div>)}
      </div>}
      {!built.length && N(ss?.actual?.campaigns) === 0 && <div className="text-xs" style={{ color: C.amber }}>No Meta campaign is linked yet: create it in Meta from here, or link the campaigns you made yourself.</div>}
      {(d.checks || []).length > 0 && <table className="w-full text-xs"><tbody>{d.checks.map((k) => (
        <tr key={k.week} className="border-t border-black/5"><td className="py-1 pr-2">Week of {k.week}</td>
          <td className="py-1 pr-2"><Chip color={(verdict[k.verdict] || [])[1]}>{(verdict[k.verdict] || [k.verdict])[0]}</Chip></td>
          <td className="py-1 pr-2">{inr(k.data?.actual?.spend)} / plan {inr(k.data?.planned?.spend)}</td>
          <td className="py-1">{fmt(k.data?.actual?.meta_leads)} leads / plan {fmt(k.data?.planned?.leads)}</td></tr>))}</tbody></table>}
      {admin && camps.length > 0 && <div className="space-y-1 no-print">
        <div className="text-xs font-semibold">Link plan campaigns to Meta campaigns (if you built them yourself)</div>
        {camps.map((c) => (
          <div key={c.key} className="flex gap-2 items-center text-sm"><span className="w-48 truncate">{c.name}</span>
            <select aria-label={`Meta campaign for ${c.name}`} className="glass-input px-2 py-1.5 text-sm flex-1" value={cur[c.key] || ''} onChange={(e) => setLinks({ ...cur, [c.key]: e.target.value })}>
              <option value="">Not linked</option>{(d.campaign_options || []).map((o) => <option key={o.ext} value={o.ext}>{o.name || o.ext} ({o.status || '?'})</option>)}</select></div>))}
        {links && <Btn ghost onClick={() => run(rpc('api_ads_meta_strategy_link', { p_id: s.id, p_links: links }).then(() => { setLinks(null); reload(); }), 'Linked')}>Save links</Btn>}
      </div>}
    </Card>);
}

// ---------------------------------------------------------------- one strategy
function Detail({ id, access, edge, onBack }) {
  const [ver, setVer] = useState(null);
  const [d, reload] = useLoad(() => rpc('api_ads_meta_strategy', { p_id: id, p_version: ver }), [id, ver], { refreshMs: 15000 });
  const [req, setReq] = useState('');
  const [research, setResearch] = useState(false);
  const [editGoal, setEditGoal] = useState(false);
  if (!d) return <div className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</div>;
  const s = d.strategy, v = d.current, p = v?.plan || {};
  const admin = access.is_admin;
  const working = s.status === 'working';
  const [label, color] = STATUS[s.status] || [s.status, C.ink];
  const change = async (goal) => {
    const r = await run(rpc('api_ads_meta_strategy_change', { p_id: s.id, p_request: req, p_research: research, p_goal: goal || null }), 'Sent to the agents');
    if (r) { setReq(''); setEditGoal(false); setVer(null); reload(); }
  };
  const upload = async (key, file) => {
    if (file.size > 8 * 1024 * 1024) { showToast('The picture is over 8 MB', 'error'); return; }
    const b64 = await new Promise((res, rej) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result)); fr.onerror = rej; fr.readAsDataURL(file); });
    await run(edge({ jobs: ['meta_image'], strategy_id: s.id, creative_key: key, image_base64: b64, filename: file.name }).then(reload), 'Picture uploaded to Meta');
  };
  return (
    <div className="space-y-4" data-testid="strategy-detail">
      <style>{`@media print { nav, header, [role=tablist], .no-print { display: none !important } .glass-card { box-shadow: none !important; break-inside: avoid } }`}</style>
      <div className="flex flex-wrap items-center gap-2 no-print">
        <Btn ghost onClick={onBack}><Icon name="chevronLeft" size={14} />All strategies</Btn>
        <div className="flex-1" />
        {d.versions.length > 0 && <select aria-label="Version" className="glass-input px-3 py-2 text-sm" value={v?.version || ''} onChange={(e) => setVer(Number(e.target.value))}>
          {d.versions.map((x) => <option key={x.version} value={x.version}>Version {x.version}{x.version === s.approved_version ? ' (approved)' : ''}{x.auto ? ' · drafted by the weekly check' : ''}</option>)}</select>}
        <Btn ghost onClick={() => window.print()}><Icon name="external" size={14} />Download PDF</Btn>
      </div>
      <div className="glass-card p-4 space-y-2">
        <div className="flex flex-wrap items-start gap-2">
          <div className="flex-1"><h3 className="text-lg font-bold">{s.title}</h3>
            <div className="text-xs text-glass-muted">Goal: {s.goal.objective}{s.goal.target_per_month ? ` · ${s.goal.target_per_month}/month` : ''}{s.goal.monthly_budget ? ` · limit ${inr(s.goal.monthly_budget)}/month` : ' · budget: agents suggest'}
              {' · '}{(s.goal.courses || []).join(', ')} · {(s.goal.locations || []).join(', ')} · from {s.goal.start_date}</div></div>
          <Chip color={color} testid="strategy-status">{label}</Chip>
        </div>
        {working && <div className="text-sm" style={{ color: C.blue }} data-testid="strategy-working"><Icon name="clock" size={14} /> {s.working_note || 'Working…'} (refreshes by itself; a plan takes about 10-30 minutes)</div>}
        {!working && s.working_note && <div className="text-xs" style={{ color: C.red }}>{s.working_note}</div>}
        {working && (d.chain || []).some((r) => r.status === 'queued' && Date.now() - new Date(r.at).getTime() > 5 * 60000) && (
          <div className="rounded-xl p-3 text-xs space-y-1" style={{ background: 'rgba(178,94,0,0.08)' }} data-testid="strategy-stuck">
            <b>No agent has picked this up for over 5 minutes.</b> The agents helper may be an older version (it updates itself every 30 minutes),
            stopped, or the Mac asleep. To restart it now, run in Terminal on the Mac:
            <pre className="font-mono text-[11px] whitespace-pre-wrap select-all p-2 rounded" style={{ background: 'rgba(0,0,0,0.05)' }}>launchctl kickstart -k gui/$(id -u)/in.weoneaviation.ads-agents</pre>
            The cloud runner, if set up, also picks it up at the next hour.
          </div>)}
        <div className="flex flex-wrap gap-1 text-[11px]">{(d.chain || []).slice().reverse().slice(0, 6).reverse().map((r, i) => (
          <Chip key={i} color={r.status === 'done' ? C.green : r.status === 'running' ? C.blue : r.status === 'queued' ? C.ink : C.amber}>
            {ROLE[r.role]} {r.attempt > 1 ? `(try ${r.attempt}) ` : ''}{r.status}</Chip>))}</div>
        {v && admin && !working && s.status !== 'archived' && (
          <div className="flex flex-wrap gap-2 no-print">
            {s.approved_version !== v.version && <Btn tone={C.green} onClick={() => run(rpc('api_ads_meta_strategy_approve', { p_id: s.id, p_version: v.version }).then(reload), 'Approved')} data-testid="approve">
              <Icon name="check" size={14} />Approve version {v.version}</Btn>}
            <Btn ghost onClick={() => run(rpc('api_ads_meta_strategy_archive', { p_id: s.id, p_archive: true }).then(onBack), 'Archived')}>Archive</Btn>
          </div>)}
        {admin && s.status === 'archived' && <Btn ghost onClick={() => run(rpc('api_ads_meta_strategy_archive', { p_id: s.id, p_archive: false }).then(reload), 'Restored')}>Restore</Btn>}
      </div>
      {!v ? (s.status === 'failed'
        ? <div className="glass-card p-6 text-center text-sm">The agents could not write a plan. {admin && 'Ask again below.'}</div>
        : <div className="glass-card p-6 text-center text-sm text-glass-muted">The agents are working on the first version.</div>)
        : <>
          {v.request && <div className="text-xs text-glass-muted">This version answers: “{v.request}”</div>}
          <Review v={v} />
          {v.answer && <Card title="From the Strategist" testid="plan-answer"><div className="text-sm whitespace-pre-wrap">{v.answer}</div>
            {(v.changes || []).length > 0 && <ul className="text-xs list-disc pl-5" data-testid="plan-changes">{v.changes.map((c, i) => <li key={i}>{c}</li>)}</ul>}</Card>}
          <Card title="Summary" testid="plan-summary"><div className="text-sm whitespace-pre-wrap">{p.summary}</div>
            {p.goal?.kpi && <div className="text-xs text-glass-muted">Judge it by: {p.goal.kpi}</div>}</Card>
          <Forecast p={p} goal={s.goal} />
          <div className="grid lg:grid-cols-2 gap-4"><Budget p={p} />
            <List title="Patterns it builds on" items={p.patterns_used} testid="plan-patterns" /></div>
          <Structure p={p} />
          <Forms p={p} />
          <Creatives p={p} images={s.build?.images} admin={admin && s.approved_version === v.version} onUpload={upload} />
          <div className="grid lg:grid-cols-2 gap-4">
            <List title="Rules: when to pause, scale or refresh" items={p.rules} testid="plan-rules" render={(r) => <><b>When</b> {r.when} → <b>then</b> {r.then}</>} />
            <List title="Timeline" items={p.timeline} testid="plan-timeline" render={(t) => <><b>{t.when}:</b> {t.what}</>} />
            <List title="How it is measured" items={p.measurement} testid="plan-measurement" />
            <List title="Risks" items={p.risks} testid="plan-risks" />
          </div>
          <Research v={v} />
          {admin && s.approved_version === v.version && s.status === 'approved' && <Build d={d} edge={edge} reload={reload} />}
          {s.approved_version && <Tracking d={d} admin={admin} reload={reload} />}
        </>}
      {admin && !working && s.status !== 'archived' && (
        <Card title="Ask for changes" sub="The Strategist revises the latest version and the Reviewer checks it again. You get a new version; the approved one stays until you approve another." testid="plan-change">
          {editGoal ? <GoalForm initial={s.goal} submit="Send with the new goal" onSubmit={(g) => change(g)} onCancel={() => setEditGoal(false)} /> : <>
            <textarea aria-label="Change request" rows={3} maxLength={2000} className="glass-input w-full px-3 py-2 text-sm" value={req} onChange={(e) => setReq(e.target.value)}
              placeholder="e.g. Keep it under ₹20,000, only Delhi NCR, add a Hindi video ad, ask for the year they finish class 12" />
            <div className="flex flex-wrap items-center gap-3">
              <label className="text-xs flex items-center gap-1.5"><input type="checkbox" checked={research} onChange={(e) => setResearch(e.target.checked)} />Research again first (slower; for new facts or a new month)</label>
              <div className="flex-1" />
              <Btn ghost onClick={() => setEditGoal(true)}>Change the goal</Btn>
              <Btn disabled={req.trim().length < 3} onClick={() => change(null)} data-testid="change-send">Send to the agents</Btn>
            </div></>}
        </Card>)}
    </div>);
}

// ---------------------------------------------------------------- list
export default function AdsMetaStrategy({ access, edge }) {
  const [open, setOpen] = useState(null);
  const [creating, setCreating] = useState(false);
  const [l, reload] = useLoad(() => rpc('api_ads_meta_strategies'), [], { refreshMs: 20000 });
  if (open) return <Detail id={open} access={access} edge={edge} onBack={() => { setOpen(null); reload(); }} />;
  const create = async (goal) => {
    const r = await run(rpc('api_ads_meta_strategy_create', { p_goal: goal }), 'The agents have started. A plan takes about 10-30 minutes.');
    if (r?.id) { setCreating(false); setOpen(r.id); }
  };
  const seen = l?.agents?.last_seen ? (Date.now() - Date.parse(l.agents.last_seen)) / 60000 : null;
  return (
    <div className="space-y-4" data-testid="meta-strategy">
      <Card title="Strategy" sub="Set a goal. The agents study your Meta history, CRM results and current research, then write a full plan: budget, structure, lead forms, ad text, expected outcome and rules. Change it as often as you like; nothing goes to Meta until you choose."
        right={access.is_admin && !creating && <Btn onClick={() => setCreating(true)} data-testid="new-strategy"><Icon name="plus" size={14} />New strategy</Btn>}>
        {l && <div className="text-xs text-glass-muted">
          {l.agents?.paused ? 'The agents are stopped (emergency stop in Google Ads → Autopilot).' : seen === null ? 'The agents have not checked in yet: set up the agents helper in Google Ads → Autopilot.'
            : seen > 90 ? `The agents last checked in ${ago(l.agents.last_seen)}; a new plan starts when they next run.` : 'The agents are online.'}
          {' '}Meta leads in the last 30 days: {fmt(l.meta_leads_last_30d)}. {access.is_admin && `${l.runs_left} new plans or changes left today.`}</div>}
        {creating && <GoalForm submit="Start the agents" onSubmit={create} onCancel={() => setCreating(false)} />}
      </Card>
      {!l ? <div className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</div>
        : !(l.items || []).length ? <div className="glass-card p-6 text-center text-sm text-glass-muted">No strategy yet.{access.is_admin ? ' Press New strategy.' : ''}</div>
        : <div className="grid md:grid-cols-2 gap-3">{l.items.map((s) => {
          const [label, color] = STATUS[s.status] || [s.status, C.ink];
          return (
            <button key={s.id} type="button" onClick={() => setOpen(s.id)} className="glass-card p-4 text-left space-y-1" data-testid="strategy-card">
              <div className="flex items-start gap-2"><b className="flex-1">{s.title}</b><Chip color={color}>{label}</Chip></div>
              <div className="text-xs text-glass-muted">{s.version ? `Version ${s.version}` : 'First version on the way'}{s.approved_version ? ` · v${s.approved_version} approved` : ''} · updated {ago(s.updated_at)}</div>
              {s.likely && <div className="text-sm">{inr(s.monthly)}/month → about {fmt(s.likely.leads)} leads{s.likely.admissions !== undefined ? `, ${fmt(s.likely.admissions)} admissions` : ''}</div>}
              {s.status === 'working' && <div className="text-xs" style={{ color: C.blue }}>{s.working_note}</div>}
              {s.last_check && <div className="text-xs">Last week: {s.last_check.verdict.replace('_', ' ')}</div>}
            </button>);
        })}</div>}
      <AdsMetaCompetitors />
    </div>);
}
