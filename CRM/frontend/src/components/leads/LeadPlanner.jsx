// The parts of the lead window that work the same for every Aviation lead (website, JustDial, walk-in, Meta, Google):
// student details, "When to connect", demo class booking (step by step), notes and the history timeline.
// Data: api_lead_ws (read) and api_lead_ws_save / api_lead_ws_demo / api_lead_ws_followup_done (write), migration 147.
import { useCallback, useEffect, useMemo, useState } from 'react';
import Icon from '../icons';
import { rpc } from '../adsKit';
import { showToast } from '../../utils/toast';
import { Switch } from '../ui/AppleControls';
import DateTimePicker, { Chip } from './DateTimePicker';
import { FINANCE, STREAMS, STUDY, cplHint, label, toIso, whenIso, whenPicked, isPastIso } from '../../utils/leadPlan';
import './leads.css';

// ---------------------------------------------------------------- data
export function useWorkspace(kind, id) {
  const [ws, setWs] = useState(null);
  const [err, setErr] = useState('');
  const load = useCallback(async () => {
    try { setWs(await rpc('api_lead_ws', { p_kind: kind, p_id: id })); setErr(''); } catch (e) { setErr(e.message); }
  }, [kind, id]);
  useEffect(() => { setWs(null); load(); }, [load]);
  return { ws, err, reload: load };
}

export const EMPTY_PROFILE = { class12: null, class12_stream: null, graduation: null, financial_issue: false, finance_help: [] };
export const profileOf = (ws) => ({ ...EMPTY_PROFILE, ...(ws?.profile || {}), finance_help: ws?.profile?.finance_help || [] });

// What the Save button sends (only the parts that were touched).
export function payloadOf({ profile, profileDirty, connect, demo, note }) {
  const p = {};
  if (profileDirty) p.profile = profile;
  if (connect?.date) p.followup = { at: toIso(connect.date, connect.time), has_time: Boolean(connect.time), reason: connect.reason || '' };
  if (demo?.ready) p.demo = { mode: demo.mode, at: toIso(demo.date, demo.time), has_time: Boolean(demo.time),
    meet_link: demo.mode === 'online' ? (demo.meet_link || '').trim() : '', place: demo.mode === 'offline' ? demo.place || '' : '', note: demo.note || '' };
  if (note?.trim()) p.note = note.trim();
  return p;
}
export const saveWorkspace = (kind, id, payload) => rpc('api_lead_ws_save', { p_kind: kind, p_id: id, p_data: payload });

// ---------------------------------------------------------------- building blocks
export function Section({ icon, title, hint, right, children, tone = '#007AFF', id }) {
  return (
    <section className="lp-section" id={id}>
      <header className="flex items-center gap-2.5 mb-3">
        <span className="lp-ico" style={{ background: `${tone}1F`, color: tone }}><Icon name={icon} size={16} /></span>
        <div className="min-w-0 flex-1">
          <h3 className="text-[15px] font-semibold text-glass-primary leading-tight">{title}</h3>
          {hint && <p className="text-[12px] text-glass-muted leading-snug">{hint}</p>}
        </div>
        {right}
      </header>
      {children}
    </section>
  );
}

// tap to choose, tap again to clear
function Pick({ options, value, onChange, tone, ariaLabel }) {
  return (
    <div className="flex flex-wrap gap-2" role="group" aria-label={ariaLabel}>
      {options.map(([k, l]) => <Chip key={k} on={value === k} tone={tone} onClick={() => onChange(value === k ? null : k)}>{l}</Chip>)}
    </div>
  );
}

const HINT_TONE = { green: ['#1E7B34', 'rgba(52,199,89,0.12)', 'checkCircle'], blue: ['#0058C2', 'rgba(0,122,255,0.10)', 'clock'], orange: ['#A35A00', 'rgba(255,149,0,0.14)', 'alert'] };

// ---------------------------------------------------------------- Student details
export function StudentCard({ profile, onChange }) {
  const set = (k, v) => onChange({ ...profile, [k]: v, ...(k === 'class12' && !['appearing', 'completed'].includes(v) ? { class12_stream: null } : {}) });
  const hint = cplHint(profile);
  const help = profile.finance_help || [];
  return (
    <Section icon="students" title="Student details" hint="Tap to choose. Tap again to clear." tone="#5856D6">
      <div className="space-y-4">
        <div>
          <div className="lp-label">Class 12</div>
          <Pick options={STUDY} value={profile.class12} onChange={(v) => set('class12', v)} ariaLabel="Class 12" tone="#5856D6" />
          {['appearing', 'completed'].includes(profile.class12) && (
            <div className="mt-2.5 lp-reveal">
              <div className="lp-sublabel">Stream</div>
              <Pick options={STREAMS} value={profile.class12_stream} onChange={(v) => set('class12_stream', v)} ariaLabel="Class 12 stream" tone="#5856D6" />
            </div>
          )}
        </div>
        <div>
          <div className="lp-label">Graduation</div>
          <Pick options={STUDY} value={profile.graduation} onChange={(v) => set('graduation', v)} ariaLabel="Graduation" tone="#5856D6" />
        </div>
        {hint && (
          <div className="flex items-start gap-2 rounded-xl px-3 py-2 text-[13px] lp-reveal" style={{ color: HINT_TONE[hint.tone][0], background: HINT_TONE[hint.tone][1] }}>
            <Icon name={HINT_TONE[hint.tone][2]} size={16} /><span>{hint.text}</span>
          </div>
        )}
        <div className="rounded-2xl p-3" style={{ background: 'rgba(118,118,128,0.08)' }}>
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="text-[14px] font-medium text-glass-primary">Financial issues</div>
              <div className="text-[12px] text-glass-muted">Optional. Tick if fees are a concern.</div>
            </div>
            <Switch size="sm" on={Boolean(profile.financial_issue)} label="Financial issues"
              onChange={(on) => onChange({ ...profile, financial_issue: on, finance_help: on ? help : [] })} />
          </div>
          {profile.financial_issue && (
            <div className="mt-3 lp-reveal">
              <div className="lp-sublabel">What could help?</div>
              <div className="flex flex-wrap gap-2">
                {FINANCE.map(([k, l]) => (
                  <Chip key={k} on={help.includes(k)} tone="#FF9500"
                    onClick={() => onChange({ ...profile, finance_help: help.includes(k) ? help.filter((x) => x !== k) : [...help, k] })}>{l}</Chip>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------- When to connect
export function WhenToConnect({ value, onChange, current }) {
  const [open, setOpen] = useState(false);
  const has = Boolean(value?.date);
  return (
    <Section icon="clock" title="When to connect" tone="#FF9500"
      hint={current ? `Planned now: ${whenIso(current.due_at, current.has_time)}${current.reason ? ` · ${current.reason}` : ''}` : 'The next call. It goes on the Today list and the Tasks board.'}
      right={has && <button type="button" className="lp-link" onClick={() => { onChange(null); setOpen(false); }}>Clear</button>}>
      {has && !open && (
        <button type="button" className="lp-summary w-full" onClick={() => setOpen(true)}>
          <Icon name="calendar" size={18} /><span className="flex-1 min-w-0 truncate text-left font-semibold">{whenPicked(value.date, value.time)}</span><span className="lp-link">Change</span>
        </button>
      )}
      {(!has || open) && (
        <div className="lp-reveal">
          <DateTimePicker value={value || { date: '', time: '' }} label="When to connect"
            onChange={(v) => { setOpen(true); onChange({ reason: value?.reason || '', ...v }); }} />
          {has && <button type="button" className="lp-btn lp-btn-soft w-full mt-3" onClick={() => setOpen(false)}>Done</button>}
        </div>
      )}
      {has && (
        <input className="glass-input w-full px-3 py-2.5 mt-3 rounded-xl text-[15px]" placeholder="Reason (optional), e.g. Call after the exam"
          value={value.reason || ''} maxLength={200} onChange={(e) => onChange({ ...value, reason: e.target.value })} aria-label="Reason" />
      )}
    </Section>
  );
}

// ---------------------------------------------------------------- Demo class (step by step)
const STEPS = { online: ['How', 'When', 'Link'], offline: ['How', 'When', 'Details'] };
export function DemoBooking({ value, onChange, demos = [], onStatus }) {
  const d = value;
  const set = (patch) => onChange({ ...d, ...patch, ready: false });
  const upcoming = demos.filter((x) => x.status === 'scheduled');
  const past = demos.filter((x) => x.status !== 'scheduled').slice(0, 3);
  const step = d?.step || 0;
  const names = STEPS[d?.mode || 'online'];
  return (
    <Section icon="calendar" title="Demo class" tone="#34C759"
      hint={upcoming.length ? 'Booked. Mark how it went after the class.' : 'Online with a meeting link, or at the institute.'}
      right={d && <button type="button" className="lp-link" onClick={() => onChange(null)}>Cancel</button>}>
      {upcoming.map((x) => <DemoRow key={x.id} x={x} onStatus={onStatus} />)}
      {past.map((x) => <DemoRow key={x.id} x={x} onStatus={onStatus} />)}

      {!d && (
        <button type="button" className="lp-btn lp-btn-green w-full" onClick={() => onChange({ step: 1 })}>
          <Icon name="plus" size={16} />{upcoming.length ? 'Book another demo' : 'Book a demo class'}
        </button>
      )}

      {d && (
        <div className="lp-reveal">
          <ol className="lp-steps" aria-label="Steps">
            {names.map((n, i) => <li key={n} data-on={step >= i + 1 || undefined} data-cur={step === i + 1 || undefined}><span>{i + 1}</span>{n}</li>)}
          </ol>

          {step === 1 && (
            <div className="grid grid-cols-2 gap-2.5">
              {[['online', 'Online', 'Video call with a link', 'globe'], ['offline', 'At the institute', 'In person, in class', 'pin']].map(([k, t, s, ic]) => (
                <button key={k} type="button" className={`lp-choice ${d.mode === k ? 'lp-choice-on' : ''}`} onClick={() => set({ mode: k, step: 2 })}>
                  <span className="lp-ico lp-ico-lg" style={{ background: 'rgba(52,199,89,0.14)', color: '#1E7B34' }}><Icon name={ic} size={20} /></span>
                  <span className="text-[15px] font-semibold text-glass-primary">{t}</span>
                  <span className="text-[12px] text-glass-muted">{s}</span>
                </button>
              ))}
            </div>
          )}

          {step === 2 && (
            <>
              <DateTimePicker value={{ date: d.date || '', time: d.time || '' }} onChange={(v) => set(v)} label="Demo date" />
              <div className="flex gap-2 mt-3">
                <button type="button" className="lp-btn lp-btn-soft" onClick={() => set({ step: 1 })}>Back</button>
                <button type="button" className="lp-btn lp-btn-green flex-1" disabled={!d.date} onClick={() => set({ step: 3 })}>Next</button>
              </div>
            </>
          )}

          {step === 3 && (
            <>
              {d.mode === 'online' ? (
                <div className="space-y-2">
                  <label className="lp-sublabel" htmlFor="demo-link">Meeting link</label>
                  <input id="demo-link" className="glass-input w-full px-3 py-2.5 rounded-xl text-[15px]" inputMode="url" placeholder="https://meet.google.com/…"
                    value={d.meet_link || ''} onChange={(e) => set({ meet_link: e.target.value, step: 3 })} />
                  <a className="lp-link inline-flex items-center gap-1" href="https://meet.google.com/new" target="_blank" rel="noreferrer noopener">
                    <Icon name="external" size={13} />Create a Google Meet link, then paste it here
                  </a>
                  {d.meet_link && !/^https:\/\/\S+$/i.test(d.meet_link.trim()) && <div className="text-[12px]" style={{ color: '#C4261D' }}>The link must start with https://</div>}
                </div>
              ) : (
                <div className="space-y-2">
                  <label className="lp-sublabel" htmlFor="demo-place">Where (optional)</label>
                  <input id="demo-place" className="glass-input w-full px-3 py-2.5 rounded-xl text-[15px]" placeholder="e.g. Classroom 2, ask for the front desk"
                    value={d.place || ''} maxLength={200} onChange={(e) => set({ place: e.target.value, step: 3 })} />
                </div>
              )}
              <input className="glass-input w-full px-3 py-2.5 mt-2 rounded-xl text-[15px]" placeholder="Note for the class (optional)" maxLength={300}
                value={d.note || ''} onChange={(e) => set({ note: e.target.value, step: 3 })} aria-label="Demo note" />
              <div className="flex gap-2 mt-3">
                <button type="button" className="lp-btn lp-btn-soft" onClick={() => set({ step: 2 })}>Back</button>
                <button type="button" className="lp-btn lp-btn-green flex-1"
                  disabled={d.mode === 'online' && d.meet_link && !/^https:\/\/\S+$/i.test(d.meet_link.trim())}
                  onClick={() => onChange({ ...d, step: 4, ready: true })}>Done</button>
              </div>
            </>
          )}

          {step === 4 && d.ready && (
            <div className="lp-summary" style={{ background: 'rgba(52,199,89,0.10)', color: '#1E7B34' }}>
              <Icon name="checkCircle" size={18} />
              <span className="flex-1 min-w-0 text-left">
                <span className="block font-semibold">{d.mode === 'online' ? 'Online demo' : 'Demo at the institute'} · {whenPicked(d.date, d.time)}</span>
                <span className="block text-[12px] opacity-80 truncate">{d.mode === 'online' ? (d.meet_link || 'Link to be added later') : (d.place || 'At the institute')} · saved when you press Save</span>
              </span>
              <button type="button" className="lp-link" onClick={() => onChange({ ...d, step: 1, ready: false })}>Edit</button>
            </div>
          )}
        </div>
      )}
    </Section>
  );
}

const DEMO_STATE = { scheduled: ['Booked', '#0058C2', 'rgba(0,122,255,0.10)'], attended: ['Attended', '#1E7B34', 'rgba(52,199,89,0.12)'],
  no_show: ["Didn't come", '#A35A00', 'rgba(255,149,0,0.14)'], cancelled: ['Cancelled', '#6E6E73', 'rgba(118,118,128,0.12)'] };
function DemoRow({ x, onStatus }) {
  const [busy, setBusy] = useState(false);
  const s = DEMO_STATE[x.status];
  const set = async (st) => { setBusy(true); await onStatus(x.id, st); setBusy(false); };
  const due = x.status === 'scheduled' && isPastIso(x.at);
  return (
    <div className="rounded-2xl p-3 mb-2.5" style={{ background: 'rgba(118,118,128,0.08)' }}>
      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-[14px] font-semibold text-glass-primary">{x.mode === 'online' ? 'Online' : 'At the institute'} · {whenIso(x.at, x.has_time)}</span>
        <span className="lp-badge" style={{ color: s[1], background: s[2] }}>{s[0]}</span>
      </div>
      {(x.meet_link || x.place || x.note) && (
        <div className="text-[12px] text-glass-muted mt-1 truncate">
          {x.meet_link && <a href={x.meet_link} target="_blank" rel="noreferrer noopener" className="lp-link">Join link</a>}
          {x.place && <span>{x.place}</span>}{x.note && <span>{(x.meet_link || x.place) ? ' · ' : ''}{x.note}</span>}
        </div>
      )}
      {x.status === 'scheduled' && (
        <div className="flex flex-wrap gap-2 mt-2.5">
          {due && <span className="text-[12px] self-center" style={{ color: '#A35A00' }}>How did it go?</span>}
          <button type="button" disabled={busy} className="lp-btn lp-btn-sm lp-btn-green" onClick={() => set('attended')}>Attended</button>
          <button type="button" disabled={busy} className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => set('no_show')}>Didn't come</button>
          <button type="button" disabled={busy} className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => set('cancelled')}>Cancel</button>
        </div>
      )}
    </div>
  );
}
export async function setDemoStatus(id, status) {
  try { await rpc('api_lead_ws_demo', { p_demo: id, p_status: status }); showToast(status === 'attended' ? 'Marked as attended' : status === 'no_show' ? "Marked as didn't come" : 'Demo cancelled', 'success'); return true; }
  catch (e) { showToast(e.message, 'error'); return false; }
}

// ---------------------------------------------------------------- Notes
export function NotesBox({ value, onChange, last, placeholder }) {
  return (
    <Section icon="form" title="Comments / notes" tone="#8E8E93" hint={last ? `Last note: ${last}` : 'Shows in the lead list and the history.'}>
      <textarea className="glass-input w-full px-3 py-2.5 rounded-xl text-[15px] leading-relaxed" rows={3} maxLength={4000}
        placeholder={placeholder || 'What did you talk about? Anything to remember?'} value={value} onChange={(e) => onChange(e.target.value)} aria-label="Notes" />
    </Section>
  );
}

// ---------------------------------------------------------------- History
const OUTCOME_TONE = { Interested: '#34C759', Callback: '#AF52DE', 'Not reachable': '#FF9500', 'Not interested': '#8E8E93', Connected: '#007AFF' };
export function historyOf(ws, extra = []) {
  if (!ws) return extra;
  const t = [...extra];
  for (const c of ws.calls || []) t.push({ at: c.at, icon: 'phone', tone: OUTCOME_TONE[c.outcome] || '#007AFF', text: `Call: ${c.outcome || 'logged'}`, sub: [c.by, c.note].filter(Boolean).join(' · ') });
  for (const n of ws.notes || []) t.push({ at: n.at, icon: 'form', tone: '#8E8E93', text: 'Note', sub: [n.by, n.body].filter(Boolean).join(' · ') });
  for (const f of ws.followups || []) t.push({ at: f.created_at, icon: 'clock', tone: '#FF9500', text: `Next call set for ${whenIso(f.due_at, f.has_time)}${f.done ? ' (done)' : ''}`, sub: [f.by, f.reason].filter(Boolean).join(' · ') });
  for (const d of ws.demos || []) {
    t.push({ at: d.created_at, icon: 'students', tone: '#34C759', text: `Demo booked: ${d.mode === 'online' ? 'online' : 'at the institute'}, ${whenIso(d.at, d.has_time)}`, sub: d.by || '' });
    if (d.status !== 'scheduled') t.push({ at: d.updated_at, icon: 'checkCircle', tone: '#34C759', text: `Demo: ${DEMO_STATE[d.status][0].toLowerCase()}`, sub: '' });
  }
  return t.filter((e) => e.at).sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
}
const AGO = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true, timeZone: 'Asia/Kolkata' });
export function Timeline({ items, limit = 6 }) {
  const [all, setAll] = useState(false);
  const shown = all ? items : items.slice(0, limit);
  if (!items.length) return <div className="text-[13px] text-glass-muted py-2">Nothing yet. Calls, notes, follow-ups and demos appear here.</div>;
  return (
    <>
      <ol className="lp-timeline">
        {shown.map((e, i) => (
          <li key={i}>
            <span className="lp-dot" style={{ background: e.tone }}><Icon name={e.icon} size={11} /></span>
            <div className="min-w-0">
              <div className="text-[13px] text-glass-primary">{e.text}</div>
              {e.sub && <div className="text-[12px] text-glass-muted break-words">{e.sub}</div>}
              <div className="text-[11px] text-glass-muted">{AGO.format(new Date(e.at))}</div>
            </div>
          </li>
        ))}
      </ol>
      {items.length > limit && <button type="button" className="lp-link mt-1" onClick={() => setAll(!all)}>{all ? 'Show less' : `Show all ${items.length}`}</button>}
    </>
  );
}

// ---------------------------------------------------------------- for Meta / Google leads: the same planner with its own Save
export function LeadPlannerPanel({ kind, id, canEdit, onLoaded }) {
  const { ws, err, reload } = useWorkspace(kind, id);
  const [profile, setProfile] = useState(EMPTY_PROFILE);
  const [dirty, setDirty] = useState(false);
  const [connect, setConnect] = useState(null);
  const [demo, setDemo] = useState(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (ws) { setProfile(profileOf(ws)); setDirty(false); onLoaded?.(ws); } }, [ws]); // eslint-disable-line react-hooks/exhaustive-deps
  const open = useMemo(() => (ws?.followups || []).find((f) => !f.done), [ws]);
  const payload = payloadOf({ profile, profileDirty: dirty, connect, demo, note });
  const pending = Object.keys(payload).length > 0 || (demo && !demo.ready);
  const save = async () => {
    if (demo && !demo.ready) { showToast('Finish the demo steps first (or cancel them)', 'error'); return; }
    setBusy(true);
    try { await saveWorkspace(kind, id, payload); showToast('Saved', 'success'); setConnect(null); setDemo(null); setNote(''); await reload(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  if (err) return <div className="text-sm" style={{ color: '#C4261D' }}>{err}</div>;
  if (!ws) return <div className="text-sm text-glass-muted py-3">Loading student details…</div>;
  if (!canEdit) return null;
  return (
    <div className="space-y-3">
      <StudentCard profile={profile} onChange={(p) => { setProfile(p); setDirty(true); }} />
      <WhenToConnect value={connect} onChange={setConnect} current={open} />
      <DemoBooking value={demo} onChange={setDemo} demos={ws.demos} onStatus={async (did, st) => { if (await setDemoStatus(did, st)) reload(); }} />
      <NotesBox value={note} onChange={setNote} />
      <button type="button" className="lp-btn lp-btn-primary w-full" disabled={!pending || busy} onClick={save}>{busy ? 'Saving…' : 'Save details'}</button>
    </div>
  );
}
