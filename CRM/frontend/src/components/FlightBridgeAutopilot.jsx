import { useState, useEffect, useCallback, useRef } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';
import Icon from './icons';
import { countryName } from '../utils/country';
import { confirmDialog } from './ui/dialogs';
import { modalProps } from './ui/overlay';
import { CloseButton } from './ui/QuickActions';

// Email Auto-Pilot and the outreach Pipeline.
// The engine on the Mac Mini does the sending (flightbridge/autosend.py): this screen only stores the owner's choices
// and shows what the engine reports. Every email still passes the compliance gates, the kill switch and DRY_RUN.

async function call(path, opts = {}) {
  const token = localStorage.getItem('token');
  const res = await apiFetch(`/api/flightbridge${path}`, { token, ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

const ago = (iso) => {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
};
const when = (iso) => (iso ? new Date(iso).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');
const day = (iso) => (iso ? new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) : '');

const TONE = {
  green: { bg: 'rgba(52,199,89,0.12)', fg: '#1E7B34', dot: '#34C759' },
  blue: { bg: 'rgba(0,122,255,0.10)', fg: '#0058C2', dot: '#007AFF' },
  orange: { bg: 'rgba(255,149,0,0.14)', fg: '#A35A00', dot: '#FF9500' },
  red: { bg: 'rgba(255,59,48,0.10)', fg: '#C4261D', dot: '#FF3B30' },
  grey: { bg: 'rgba(118,118,128,0.12)', fg: '#3C3C43', dot: '#8E8E93' },
};

// What the engine reported, in plain words
function statusLine(d) {
  const cfg = d.config || {};
  const st = d.state || {};
  if (!cfg.enabled) return { tone: 'grey', title: 'Off', text: 'Nothing is sent automatically. Turn it on when the checklist is green.' };
  if (!d.engine_online) return { tone: 'orange', title: 'Waiting for the Mac Mini', text: `The engine hasn't reported since ${when(d.engine?.at) || 'it was installed'}. Wake the Mac or open it.` };
  if (st.paused_at && !(cfg.resume_at && cfg.resume_at > st.paused_at)) return { tone: 'red', title: 'Paused for safety', text: st.pause_reason, paused: true };
  const detail = st.status_detail || '';
  switch (st.status) {
    case 'blocked': return { tone: 'red', title: 'Not sending yet', text: detail || 'Fix the red items in the checklist.' };
    case 'waiting': return { tone: 'orange', title: 'Waiting', text: detail };
    case 'done_today': return { tone: 'green', title: 'Done for today', text: `${detail}. Continues tomorrow.` };
    case 'gap': return { tone: 'green', title: 'Running', text: `Next email after ${when(st.next_send_at)} (random gap between emails).` };
    case 'waiting_hours': return { tone: 'blue', title: 'Running', text: detail };
    case 'idle': return { tone: 'blue', title: 'Running', text: detail || 'No school is waiting for an email.' };
    case 'drafted': case 'sent': case 'busy': case 'skipped': return { tone: 'green', title: 'Running', text: st.last ? `Last email ${ago(st.last.at)}.` : 'Sending.' };
    case 'off': return { tone: 'blue', title: 'Starting', text: 'The Mac Mini picks this up within a minute.' };
    default: return { tone: 'blue', title: 'Starting', text: 'The Mac Mini picks this up within a minute.' };
  }
}

function Switch({ on, disabled, onChange, label }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} onClick={() => onChange(!on)}
      className="relative inline-flex items-center rounded-full transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style={{ width: 64, height: 36, background: on ? '#34C759' : 'rgba(120,120,128,0.32)', opacity: disabled ? 0.5 : 1, outlineColor: '#007AFF' }}>
      <span className="absolute rounded-full bg-white transition-transform" style={{ width: 30, height: 30, left: 3, top: 3, transform: on ? 'translateX(28px)' : 'none', boxShadow: '0 2px 6px rgba(0,0,0,0.25)' }} />
    </button>
  );
}

function Stat({ label, value, sub, children }) {
  return (
    <div className="glass-subtle rounded-2xl p-3 min-w-0">
      <div className="text-[12px] text-glass-muted">{label}</div>
      <div className="text-xl font-bold text-glass-primary tabular-nums">{value}</div>
      {children}
      {sub && <div className="text-[11px] text-glass-muted mt-0.5">{sub}</div>}
    </div>
  );
}

const CHECK_ICON = { pass: ['checkCircle', '#34C759'], warn: ['alert', '#FF9500'], fail: ['xCircle', '#FF3B30'] };

function Checklist({ pre, isAdmin, busy, onCheck, onWriteFollowups }) {
  const checks = pre?.checks || [];
  const fails = checks.filter((c) => c.status === 'fail').length;
  return (
    <div className="glass-card p-4 space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <div className="font-semibold text-glass-primary">Pre-flight checklist</div>
          <div className="text-xs text-glass-muted">
            {pre?.at ? `Checked ${ago(pre.at)} by the Mac Mini · ` : 'Not checked yet · '}
            {checks.length ? (fails ? `${fails} to fix before sending` : 'Ready to send') : 'press Check now'}
          </div>
        </div>
        {isAdmin && <button className="glass-btn px-3 py-2 text-sm inline-flex items-center gap-2" disabled={busy} onClick={onCheck}><Icon name="refresh" size={15} />Check now</button>}
      </div>
      {checks.length === 0 && <div className="text-sm text-glass-muted">The engine checks your domain's SPF, DKIM and DMARC records, reverse DNS, spam blocklists, the mailbox login and your templates.</div>}
      <ul className="divide-y" style={{ borderColor: 'rgba(0,0,0,0.06)' }}>
        {checks.map((c) => {
          const [ic, col] = CHECK_ICON[c.status] || CHECK_ICON.warn;
          return (
            <li key={c.id} className="py-2.5 flex gap-3">
              <span style={{ color: col }} className="mt-0.5"><Icon name={ic} size={20} /></span>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-medium text-glass-primary">{c.label}</div>
                <div className="text-[13px] text-glass-secondary break-words">{c.detail}</div>
                {c.fix && <div className="text-[12px] mt-0.5 break-words" style={{ color: c.status === 'fail' ? '#C4261D' : '#A35A00' }}>Fix: {c.fix}</div>}
                {c.id === 'template_followups' && c.status !== 'pass' && isAdmin && (
                  <button className="mt-1.5 text-[13px] inline-flex items-center gap-1.5 font-medium" style={{ color: '#007AFF' }} onClick={onWriteFollowups}>
                    <Icon name="sparkles" size={15} />Write the follow-ups with AI
                  </button>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function FollowupWriter({ days, onClose, onDone }) {
  const [busy, setBusy] = useState(true);
  const [list, setList] = useState(null);
  const [err, setErr] = useState(null);
  const [saving, setSaving] = useState(false);
  const run = useCallback(async () => {
    setBusy(true); setErr(null);
    try { setList((await call('/templates/followups', { method: 'POST', body: '{}' })).followups); } catch (e) { setErr(e.message); }
    setBusy(false);
  }, []);
  useEffect(() => { run(); }, [run]);
  const edit = (i, k, v) => setList((l) => l.map((f, j) => (j === i ? { ...f, [k]: v } : f)));
  const approveAll = async () => {
    setSaving(true);
    try {
      for (const f of list) {
        const r = await call('/templates', { method: 'POST', body: JSON.stringify({ kind: `followup_${f.step}`, subject: f.subject, body: f.body }) });
        if (!r.validation.ok) throw new Error(`Follow-up ${f.step}: ${r.validation.errors.join('; ')}`);
        await call(`/templates/${r.id}/approve`, { method: 'POST' });
      }
      showToast(`${list.length} follow-ups approved`, 'success'); onDone();
    } catch (e) { showToast(e.message, 'error'); } finally { setSaving(false); }
  };
  return (
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(onClose, { guard: true })}>
      <div className="glass-strong max-w-2xl w-full p-5 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
        <div className="flex justify-between items-start gap-3 mb-3">
          <div>
            <h2 className="text-xl font-bold text-glass-primary">Follow-up emails</h2>
            <p className="text-sm text-glass-secondary">Written for your approved first email. Sent only when a school hasn't replied: days {days.join(', ')}.</p>
          </div>
          <CloseButton onClick={onClose} />
        </div>
        {busy && <div className="py-10 text-center text-glass-muted text-sm">Writing {days.length} follow-ups…</div>}
        {err && <div className="p-3 rounded-xl text-sm" style={{ background: TONE.red.bg, color: TONE.red.fg }}>{err} <button className="underline ml-1" onClick={run}>Try again</button></div>}
        {list && !busy && (
          <div className="space-y-3">
            {list.map((f, i) => (
              <div key={f.step} className="glass-subtle rounded-2xl p-3 space-y-2">
                <div className="flex items-center justify-between gap-2 text-[12px] text-glass-muted">
                  <span className="font-semibold text-glass-primary text-sm">Follow-up {f.step} · day {f.day}</span>
                  {f.check?.errors?.length ? <span style={{ color: '#C4261D' }}>{f.check.errors.length} to fix</span> : <span style={{ color: '#1E7B34' }}>Checks passed</span>}
                </div>
                <input className="glass-input w-full px-3 py-2 text-sm" value={f.subject} maxLength={150} onChange={(e) => edit(i, 'subject', e.target.value)} aria-label={`Follow-up ${f.step} subject`} />
                <textarea className="glass-input w-full px-3 py-2 text-sm" rows={6} value={f.body} onChange={(e) => edit(i, 'body', e.target.value)} aria-label={`Follow-up ${f.step} body`} />
                {f.check?.errors?.length > 0 && <ul className="text-[12px] list-disc pl-5" style={{ color: '#C4261D' }}>{f.check.errors.map((x) => <li key={x}>{x}</li>)}</ul>}
              </div>
            ))}
            <div className="flex flex-wrap gap-2 justify-end pt-1">
              <button className="px-4 py-2 rounded-xl text-sm glass-subtle" onClick={run} disabled={saving}>Write again</button>
              <button className="glass-btn px-4 py-2 text-sm" style={{ background: '#34C759' }} onClick={approveAll} disabled={saving}>{saving ? 'Saving…' : `Approve all ${list.length}`}</button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export function AutoPilot({ isAdmin }) {
  const [d, setD] = useState(null);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState(null);
  const [writer, setWriter] = useState(false);
  const dirty = useRef(false);

  const load = useCallback(async () => {
    try {
      const x = await call('/send-autopilot');
      setD(x);
      if (!dirty.current) {
        setForm({ daily_limit: x.config.daily_limit ?? 40, warmup: x.config.warmup !== false,
          followups: (x.followup_days || []).length, days: [...(x.followup_days || [])] });
      }
    } catch (e) { showToast(e.message, 'error'); }
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 15000); return () => clearInterval(t); }, [load]);

  const save = async (patch, ok) => {
    setBusy(true);
    try { await call('/send-autopilot', { method: 'POST', body: JSON.stringify(patch) }); if (ok) showToast(ok, 'success'); dirty.current = false; await load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };

  if (!d || !form) return <div className="glass-card p-6 text-glass-muted text-sm">Loading Auto-Pilot…</div>;
  const cfg = d.config || {};
  const st = d.state || {};
  const line = statusLine(d);
  const tone = TONE[line.tone];
  const today = st.today && st.today.date === new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) ? st.today : null;
  const limit = today?.limit ?? (cfg.warmup !== false ? Math.min(10, cfg.daily_limit || 40) : cfg.daily_limit || 40);
  const sent = today?.sent ?? 0;
  const mailboxes = d.mailboxes || [];
  const sel = mailboxes.find((m) => m.selected);

  const toggle = async (on) => {
    if (on) {
      const fails = (st.preflight?.checks || []).filter((c) => c.status === 'fail').length;
      const yes = await confirmDialog('Turn on Email Auto-Pilot?', {
        message: `It will email Eligible schools by itself with your approved templates from ${sel?.address || 'the chosen mailbox'}, up to ${limit} today${cfg.warmup !== false ? ' (warm-up)' : ''}, only in each school's business hours.${fails ? ` ${fails} checklist item(s) must be fixed before the first email goes.` : ''} You can turn it off any time.`,
        confirmText: 'Turn on' });
      if (!yes) return;
    }
    save({ enabled: on }, on ? 'Auto-Pilot is on' : 'Auto-Pilot is off');
  };
  const setDays = (n) => {
    dirty.current = true;
    const base = [4, 9, 16, 25, 40];
    setForm((f) => ({ ...f, followups: n, days: Array.from({ length: n }, (_, i) => f.days[i] ?? base[i]) }));
  };
  const daysOk = form.days.every((v, i) => Number.isInteger(v) && v >= 2 && v <= 90 && (i === 0 || v > form.days[i - 1]));
  const changed = form.daily_limit !== (cfg.daily_limit ?? 40) || form.warmup !== (cfg.warmup !== false)
    || JSON.stringify(form.days) !== JSON.stringify(d.followup_days || []);

  return (
    <div className="space-y-4">
      {/* status + switch */}
      <div className="glass-card p-4 sm:p-5 space-y-4">
        <div className="flex items-start gap-4">
          <div className="w-12 h-12 rounded-2xl grid place-items-center shrink-0" style={{ background: tone.bg, color: tone.dot }}><Icon name="rocket" size={24} /></div>
          <div className="min-w-0 flex-1">
            <h3 className="text-lg font-bold text-glass-primary leading-tight">Email Auto-Pilot</h3>
            <div className="mt-1 inline-flex items-center gap-2 px-2.5 py-1 rounded-full text-[13px] font-medium" style={{ background: tone.bg, color: tone.fg }}>
              <span className="w-2 h-2 rounded-full" style={{ background: tone.dot }} />{line.title}
            </div>
            {line.text && <p className="text-sm text-glass-secondary mt-1.5 break-words">{line.text}</p>}
            {line.paused && isAdmin && (
              <button className="glass-btn px-3 py-1.5 text-sm mt-2 inline-flex items-center gap-1.5" disabled={busy} onClick={() => save({ resume: true }, 'Resumed')}><Icon name="play" size={14} />Resume</button>
            )}
          </div>
          <Switch on={!!cfg.enabled} disabled={!isAdmin || busy} onChange={toggle} label="Email Auto-Pilot" />
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <Stat label="Sent today" value={`${sent} / ${limit}`} sub={today?.warmup_week ? `Warm-up week ${today.warmup_week}` : (cfg.warmup !== false ? 'Warm-up' : 'Fixed pace')}>
            <div className="h-1.5 rounded-full mt-1.5 overflow-hidden" style={{ background: 'rgba(120,120,128,0.18)' }}>
              <div className="h-full rounded-full" style={{ width: `${Math.min(100, (sent / Math.max(limit, 1)) * 100)}%`, background: '#34C759' }} />
            </div>
          </Stat>
          <Stat label="Ready to send" value={d.ready} sub={`${d.eligible_with_email} Eligible schools have an email`} />
          <Stat label="Follow-ups due" value={d.followups_waiting} sub="Sent when the school hasn't replied" />
          <Stat label="Sent so far" value={d.sent_total} sub={d.enabled_by && cfg.enabled ? `On since ${day(cfg.since)} · ${d.enabled_by}` : ' '} />
        </div>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-glass-muted">
          <span className="inline-flex items-center gap-1.5"><span className="w-2 h-2 rounded-full" style={{ background: d.engine_online ? '#34C759' : '#FF9500' }} />Mac Mini {d.engine_online ? 'online' : 'offline'}{d.engine?.at ? ` · ${ago(d.engine.at)}` : ''}</span>
          <span>Server sending: {d.engine?.dry_run === false && d.engine?.outbound_enabled ? 'on' : 'off (DRY_RUN)'}</span>
          <span>Kill switch: {d.kill_switch_engaged ? 'on' : 'released'}</span>
        </div>
      </div>

      {/* settings */}
      <div className="glass-card p-4 sm:p-5 space-y-4">
        <div className="font-semibold text-glass-primary">Settings</div>
        <label className="block">
          <span className="text-sm font-medium text-glass-primary">Send emails from</span>
          <select className="glass-input w-full px-3 py-2 mt-1" value={sel?.id || ''} disabled={!isAdmin || busy}
            onChange={(e) => save({ send_from: e.target.value }, 'Sending mailbox changed')} aria-label="Send emails from">
            {mailboxes.map((m) => <option key={m.id} value={m.id} disabled={!m.connected && !m.selected}>{m.address} · {m.provider}{m.connected ? '' : ' (not connected)'}</option>)}
          </select>
          <span className="text-[12px] text-glass-muted">Only connected mailboxes can be chosen. Connect another in Settings › Email.</span>
        </label>

        <div className="grid sm:grid-cols-2 gap-4">
          <div>
            <div className="text-sm font-medium text-glass-primary">Daily pace</div>
            <label className="flex items-center gap-2 mt-2 text-sm">
              <input type="checkbox" className="w-4 h-4" checked={form.warmup} disabled={!isAdmin}
                onChange={(e) => { dirty.current = true; setForm({ ...form, warmup: e.target.checked }); }} />
              Warm-up (safest for a new sending domain)
            </label>
            <label className="flex items-center gap-2 mt-2 text-sm">
              <span className="text-glass-secondary">Up to</span>
              <input type="number" min={1} max={100} className="glass-input px-2 py-1.5 w-20 text-center" value={form.daily_limit} disabled={!isAdmin}
                onChange={(e) => { dirty.current = true; setForm({ ...form, daily_limit: Math.max(1, Math.min(100, Number(e.target.value) || 1)) }); }} aria-label="Emails a day" />
              <span className="text-glass-secondary">emails a day</span>
            </label>
            <p className="text-[12px] text-glass-muted mt-1.5">{form.warmup ? `Week 1: ${Math.min(10, form.daily_limit)} a day, +10 each week until ${form.daily_limit}.` : `${form.daily_limit} every day from the start.`} Weekdays, in each school's 9 am–5 pm, with random gaps of 4–11 minutes.</p>
          </div>
          <div>
            <div className="text-sm font-medium text-glass-primary">Follow-ups when there's no reply</div>
            <div className="flex flex-wrap gap-1.5 mt-2" role="radiogroup" aria-label="Number of follow-ups">
              {[0, 1, 2, 3, 4, 5].map((n) => (
                <button key={n} type="button" role="radio" aria-checked={form.followups === n} disabled={!isAdmin} onClick={() => setDays(n)}
                  className="w-10 h-9 rounded-xl text-sm font-medium transition"
                  style={form.followups === n ? { background: '#007AFF', color: '#fff' } : { background: 'rgba(118,118,128,0.12)', color: '#3C3C43' }}>{n}</button>
              ))}
            </div>
            {form.followups > 0 && (
              <div className="flex flex-wrap items-center gap-1.5 mt-2 text-sm">
                <span className="text-glass-secondary">On days</span>
                {form.days.map((v, i) => (
                  <input key={i} type="number" min={2} max={90} value={v} disabled={!isAdmin} aria-label={`Follow-up ${i + 1} day`}
                    className="glass-input px-1 py-1.5 w-14 text-center"
                    onChange={(e) => { dirty.current = true; const days = [...form.days]; days[i] = Number(e.target.value); setForm({ ...form, days }); }} />
                ))}
              </div>
            )}
            <p className="text-[12px] mt-1.5" style={{ color: daysOk ? undefined : '#C4261D' }}>
              {daysOk ? (form.followups ? 'Days after the first email. Stops the moment the school replies, unsubscribes or bounces.' : 'Only the first email is sent.') : 'Each day must be 2–90 and later than the one before.'}
            </p>
          </div>
        </div>
        {isAdmin && (
          <div className="flex justify-end gap-2">
            {changed && <button className="px-4 py-2 rounded-xl text-sm glass-subtle" onClick={() => { dirty.current = false; load(); }}>Undo</button>}
            <button className="glass-btn px-4 py-2 text-sm" disabled={!changed || !daysOk || busy}
              onClick={() => save({ daily_limit: form.daily_limit, warmup: form.warmup, followup_days: form.days }, 'Settings saved')}>Save settings</button>
          </div>
        )}
      </div>

      <Checklist pre={st.preflight} isAdmin={isAdmin} busy={busy} onCheck={() => save({ check_now: true }, 'The Mac Mini will check within a minute')}
        onWriteFollowups={() => setWriter(true)} />

      {(d.recent || []).length > 0 && (
        <div className="glass-card p-4">
          <div className="font-semibold text-glass-primary mb-2">Latest Auto-Pilot emails</div>
          <ul className="divide-y" style={{ borderColor: 'rgba(0,0,0,0.06)' }}>
            {d.recent.map((r) => (
              <li key={r.id} className="py-2 flex items-center gap-3 text-sm">
                <span style={{ color: r.status === 'sent' ? '#34C759' : r.status === 'failed' ? '#FF3B30' : '#FF9500' }}><Icon name={r.status === 'sent' ? 'send' : 'alert'} size={16} /></span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-glass-primary">{r.name} <span className="text-glass-muted">· {countryName(r.country)}</span></div>
                  <div className="truncate text-[12px] text-glass-muted">{r.kind === 'followup' ? 'Follow-up' : 'First email'} · {r.subject}</div>
                </div>
                <span className="text-[12px] text-glass-muted shrink-0">{when(r.at)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {writer && <FollowupWriter days={d.followup_days || []} onClose={() => setWriter(false)} onDone={() => { setWriter(false); save({ check_now: true }); }} />}
    </div>
  );
}

// ------------------------------------------------------------------------------------------------ pipeline
const STAGES = [
  ['queued', 'Queued', 'grey'], ['sent', 'Sent', 'blue'], ['followup', 'Follow-up', 'blue'], ['replied', 'Replied', 'green'],
  ['meeting', 'Meeting', 'orange'], ['partner', 'Partner', 'green'], ['closed', 'Closed', 'grey'],
];
const STAGE_OF = Object.fromEntries(STAGES.map(([k, l, t]) => [k, { label: l, tone: t }]));

function PipelineRow({ r, onMove }) {
  const t = TONE[STAGE_OF[r.stage]?.tone || 'grey'];
  const steps = [];
  if (r.sent_at) steps.push(`First email ${day(r.sent_at)}`);
  if (r.followups_planned) steps.push(`${r.followups_sent} of ${r.followups_planned} follow-ups`);
  if (r.next_followup_at && !r.reply_at) steps.push(`next ${day(r.next_followup_at)}`);
  if (r.reply_at) steps.push(`replied ${day(r.reply_at)}`);
  return (
    <li className="glass-card p-3 sm:p-4">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-glass-primary truncate">{r.name}</span>
            <span className="px-2 py-0.5 rounded-full text-[12px] font-medium" style={{ background: t.bg, color: t.fg }}>{r.note}</span>
            {r.via === 'autopilot' && <span className="text-[11px] text-glass-muted inline-flex items-center gap-1"><Icon name="rocket" size={12} />Auto-Pilot</span>}
          </div>
          <div className="text-[13px] text-glass-secondary truncate">{[r.city, countryName(r.country)].filter(Boolean).join(', ')}{r.email ? ` · ${r.email}` : ''}</div>
          {steps.length > 0 && <div className="text-[12px] text-glass-muted mt-0.5">{steps.join(' · ')}</div>}
          {r.reply_snippet && <div className="text-[13px] mt-1.5 p-2 rounded-xl glass-subtle text-glass-secondary line-clamp-2">“{r.reply_snippet}”</div>}
        </div>
      </div>
      <div className="flex flex-wrap gap-1.5 mt-2.5">
        {r.stage !== 'meeting' && r.stage !== 'partner' && <button className="px-3 py-1.5 rounded-xl text-[13px] glass-subtle" onClick={() => onMove(r, 'meeting')}>Meeting</button>}
        {r.stage !== 'partner' && <button className="px-3 py-1.5 rounded-xl text-[13px] glass-subtle" onClick={() => onMove(r, 'partner')}>Partner</button>}
        {r.stage !== 'closed' ? <button className="px-3 py-1.5 rounded-xl text-[13px]" style={{ color: '#C4261D', background: 'rgba(255,59,48,0.08)' }} onClick={() => onMove(r, 'closed')}>Close</button>
          : <button className="px-3 py-1.5 rounded-xl text-[13px] glass-subtle" onClick={() => onMove(r, 'reopen')}>Reopen</button>}
      </div>
    </li>
  );
}

export function Pipeline() {
  const [stage, setStage] = useState('all');
  const [q, setQ] = useState('');
  const [data, setData] = useState(null);
  const load = useCallback(async () => {
    try {
      const p = new URLSearchParams({ stage }); if (q.trim()) p.set('q', q.trim());
      setData(await call(`/pipeline?${p}`));
    } catch (e) { showToast(e.message, 'error'); }
  }, [stage, q]);
  useEffect(() => { const t = setTimeout(load, q ? 300 : 0); return () => clearTimeout(t); }, [load, q]);
  const counts = data?.counts || {};
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  const move = async (r, to) => {
    if (to === 'closed' && !(await confirmDialog(`Close ${r.name}?`, { message: 'No more emails go to this school, including follow-ups.', confirmText: 'Close', danger: true }))) return;
    try { await call('/pipeline/move', { method: 'POST', body: JSON.stringify({ org_id: r.org_id, stage: to }) }); showToast(`${r.name}: ${to === 'reopen' ? 'reopened' : `moved to ${STAGE_OF[to]?.label || to}`}`, 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <div className="space-y-3">
      <div className="flex gap-1.5 overflow-x-auto pb-1 -mx-1 px-1" role="tablist" aria-label="Pipeline stages">
        {[['all', 'All', 'grey'], ...STAGES].map(([k, l]) => {
          const n = k === 'all' ? total : counts[k] || 0;
          const on = stage === k;
          return (
            <button key={k} role="tab" aria-selected={on} onClick={() => setStage(k)}
              className="shrink-0 px-3 py-2 rounded-xl text-sm font-medium inline-flex items-center gap-1.5 transition"
              style={on ? { background: '#007AFF', color: '#fff' } : { background: 'rgba(118,118,128,0.12)', color: '#3C3C43' }}>
              {l}<span className="tabular-nums text-[12px] px-1.5 rounded-full" style={{ background: on ? 'rgba(255,255,255,0.25)' : 'rgba(118,118,128,0.16)' }}>{n}</span>
            </button>
          );
        })}
      </div>
      <input className="glass-input w-full px-3 py-2" placeholder="Search school, email or country code" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search the pipeline" />
      {!data && <div className="glass-card p-6 text-sm text-glass-muted">Loading…</div>}
      {data && data.rows.length === 0 && (
        <div className="glass-card p-6 text-center">
          <div className="mx-auto w-12 h-12 rounded-2xl grid place-items-center mb-2" style={{ background: TONE.blue.bg, color: '#007AFF' }}><Icon name="funnel" size={22} /></div>
          <div className="font-semibold text-glass-primary">{total ? 'Nothing in this stage' : 'No emails yet'}</div>
          <div className="text-sm text-glass-muted mt-1">{total ? 'Pick another stage above.' : 'Approve a first-email template; each Eligible school then appears here, from Queued to Partner.'}</div>
        </div>
      )}
      {data && data.rows.length > 0 && <ul className="space-y-2">{data.rows.map((r) => <PipelineRow key={r.org_id} r={r} onMove={move} />)}</ul>}
    </div>
  );
}
