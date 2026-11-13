// CRM > ADS > Ads Leads: enquiries that came from an ad (kept apart from organic Leads).
// Reads/writes only through api_ads_* functions (migrations 089, 090): every stage move, assignment and call is
// recorded with who and when, and history can't be edited. Pilot Training and Charter are separate lists.
import { useCallback, useEffect, useMemo, useState } from 'react';
import { rpc, run, Btn } from './adsKit';
import { showToast } from '../utils/toast';
import { promptDialog } from './ui/dialogs';
import Icon from './icons';
import QuickActions, { CloseButton } from './ui/QuickActions';
import { displayPhone, formatPhone } from '../utils/formatters';

const PIPES = [['pilot_training', 'Pilot Training'], ['charter', 'Charter']];
const STAGE_TONE = {
  lead_created: ['#0062CC', 'rgba(0,122,255,0.10)'], contacted: ['#8A5A00', 'rgba(255,149,0,0.14)'],
  interested: ['#6E3FB0', 'rgba(175,82,222,0.12)'], quote_sent: ['#6E3FB0', 'rgba(175,82,222,0.12)'],
  qualified: ['#1E7B34', 'rgba(52,199,89,0.14)'], application_completed: ['#1E7B34', 'rgba(52,199,89,0.14)'],
  admission_completed: ['#fff', '#34C759'], booking_confirmed: ['#fff', '#34C759'], lost: ['#636366', 'rgba(118,118,128,0.14)'],
};
const QUALIFY_FIELDS = {
  pilot_training: [['pcm', 'Class 12 with Physics & Maths', 'yn'], ['age', 'Age 17 or above', 'yn'], ['course', 'Course', 'text'],
    ['start', 'Planned start', 'text'], ['budget', 'Fees / budget discussed', 'yn']],
  charter: [['route', 'Route and date confirmed', 'yn'], ['pax', 'Passengers', 'text'], ['budget', 'Budget discussed', 'yn'],
    ['decision', 'Decision maker on the call', 'yn']],
};
const CONTACT = [['connected', 'Connected'], ['no_answer', 'No answer'], ['busy', 'Busy'], ['callback_requested', 'Call back later'], ['wrong_number', 'Wrong number']];

const Chip = ({ children, fg = '#3C3C43', bg = 'rgba(118,118,128,0.14)' }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: bg, color: fg }}>{children}</span>
);
const mins = (t) => (t ? Math.max(0, Math.round((Date.now() - Date.parse(t)) / 60000)) : null);
const span = (m) => (m === null ? '' : m < 60 ? `${m} min` : m < 1440 ? `${Math.round(m / 60)} h` : `${Math.round(m / 1440)} d`);
const when = (t) => (t ? new Date(t).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '');

// Waiting for the first call: green under 15 min, orange under 1 h, red after.
function Wait({ row }) {
  if (row.first_response_at || row.stage !== 'lead_created' || row.quarantined) return <span className="text-[11px] text-glass-muted">{span(mins(row.created_at))} ago</span>;
  const m = mins(row.created_at);
  const [fg, bg] = m < 15 ? ['#1E7B34', 'rgba(52,199,89,0.14)'] : m < 60 ? ['#8A5A00', 'rgba(255,149,0,0.16)'] : ['#C4261D', 'rgba(255,59,48,0.12)'];
  return <Chip fg={fg} bg={bg}>Not called · {span(m)}</Chip>;
}

export default function AdsLeads({ access }) {
  const [pipe, setPipe] = useState('pilot_training');
  const [stage, setStage] = useState('');
  const [quar, setQuar] = useState(false);
  const [q, setQ] = useState('');
  const [board, setBoard] = useState(null);
  const [err, setErr] = useState('');
  const [staff, setStaff] = useState([]);
  const [open, setOpen] = useState(null);
  const [, tick] = useState(0);

  const load = useCallback(async () => {
    try {
      setBoard(await rpc('api_ads_lead_board', { p_pipeline: pipe, p_stage: stage || null, p_quarantined: quar, p_search: q || null, p_limit: 200 }));
      setErr('');
    } catch (e) { setErr(e.message); }
  }, [pipe, stage, quar, q]);
  useEffect(() => { const t = setTimeout(load, q ? 250 : 0); return () => clearTimeout(t); }, [load, q]);
  useEffect(() => { rpc('api_ads_staff').then(setStaff, () => setStaff([])); }, []);
  useEffect(() => { const i = setInterval(() => tick((n) => n + 1), 60000); return () => clearInterval(i); }, []);   // timers

  const s = board?.stats || {};
  const stages = board?.stages || [];
  const label = useMemo(() => Object.fromEntries(stages.map((d) => [d.stage, d.label])), [stages]);
  const canEdit = board?.role && board.role !== 'viewer';

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
        {[['New today', s.new_today], ['Not called yet', s.not_contacted, s.not_contacted > 0 ? '#C4261D' : undefined],
          [pipe === 'charter' ? 'Qualified this month' : 'Qualified this month', s.qualified_month],
          [pipe === 'charter' ? 'Bookings this month' : 'Admissions this month', s.customers_month]].map(([l, v, c]) => (
          <div key={l} className="glass-card p-3"><div className="text-[11px] text-glass-muted">{l}</div>
            <div className="text-2xl font-bold" style={{ color: c || 'var(--glass-primary, #1C1C1E)' }}>{v ?? '—'}</div></div>))}
      </div>

      <div className="glass-card p-2 flex flex-wrap items-center gap-2">
        <div role="tablist" aria-label="Pipeline" className="inline-flex rounded-xl p-0.5" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {PIPES.map(([k, l]) => (
            <button key={k} role="tab" aria-selected={pipe === k} type="button" onClick={() => { setPipe(k); setStage(''); }}
              className="px-3 py-1.5 rounded-[10px] text-sm font-semibold" style={pipe === k ? { background: '#fff', color: '#007AFF', boxShadow: '0 1px 3px rgba(0,0,0,0.12)' } : { color: '#3C3C43' }}>{l}</button>))}
        </div>
        <select aria-label="Stage" className="glass-input px-3 py-2 text-sm" value={stage} onChange={(e) => setStage(e.target.value)}>
          <option value="">All stages</option>{stages.map((d) => <option key={d.stage} value={d.stage}>{d.label}</option>)}
        </select>
        <input aria-label="Search" className="glass-input px-3 py-2 text-sm flex-1 min-w-[140px]" placeholder="Search name, phone, email" value={q} onChange={(e) => setQ(e.target.value)} />
        <button type="button" onClick={() => setQuar(!quar)} aria-pressed={quar}
          className="px-3 py-2 rounded-xl text-sm font-semibold inline-flex items-center gap-1.5"
          style={quar ? { background: '#FF9500', color: '#fff' } : { background: 'rgba(118,118,128,0.12)', color: '#1C1C1E' }}>
          <Icon name="shield" size={16} />Quarantine{s.quarantined ? ` (${s.quarantined})` : ''}
        </button>
      </div>

      {err && <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{err} <button type="button" className="underline ml-1" onClick={load}>Try again</button></div>}
      {!board && !err && <div className="text-center text-glass-muted py-10 text-sm">Loading…</div>}
      {board && !board.rows.length && (
        <div className="text-center text-glass-muted py-10 text-sm">
          {quar ? 'Nothing in quarantine.' : q || stage ? 'No Ads leads match.' : 'No Ads leads yet. They appear here when someone fills a form after clicking an ad.'}
        </div>)}

      <div className="space-y-2">
        {board?.rows.map((r) => (
          <div key={r.id} className="glass-card p-3">
            <button type="button" onClick={() => setOpen(r.id)} className="w-full text-left flex flex-wrap items-start gap-x-3 gap-y-1">
              <span className="min-w-0 flex-1">
                <span className="block font-semibold text-glass-primary truncate">{r.name}</span>
                <span className="block text-xs text-glass-secondary truncate">
                  {formatPhone(r.phone_e164)}{r.course_interest ? ` · ${r.course_interest}` : ''}
                  {r.charter_details?.from ? ` · ${r.charter_details.from} → ${r.charter_details.to}` : ''}
                </span>
                <span className="block text-[11px] text-glass-muted truncate">{r.source}{r.campaign ? ` · ${r.campaign}` : ''}{r.enquiry_count > 1 ? ` · ${r.enquiry_count} enquiries` : ''}{r.organic_lead_id ? ' · also in Leads' : ''}</span>
              </span>
              <span className="flex flex-col items-end gap-1 shrink-0">
                <Chip fg={(STAGE_TONE[r.stage] || [])[0]} bg={(STAGE_TONE[r.stage] || [])[1]}>{label[r.stage] || r.stage}</Chip>
                <Wait row={r} />
                <span className="text-[11px] text-glass-muted">{r.owner_name || 'Unassigned'}</span>
              </span>
            </button>
            {r.quarantined && <div className="text-[11px] mt-1" style={{ color: '#8A5A00' }}>Quarantined: {(r.quarantine_reasons || []).join(', ')}</div>}
          </div>))}
      </div>

      {open && <LeadPanel id={open} pipe={pipe} stages={stages} staff={staff} canEdit={canEdit} isAdmin={board?.role === 'admin' || access?.is_admin}
        onClose={() => setOpen(null)} onChanged={load} />}
    </div>
  );
}

function LeadPanel({ id, pipe, stages, staff, canEdit, isAdmin, onClose, onChanged }) {
  const [l, setL] = useState(null);
  const [err, setErr] = useState('');
  const [qualify, setQualify] = useState(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    try { setL(await rpc('api_ads_lead', { p_lead: id })); setErr(''); } catch (e) { setErr(e.message); }
  }, [id]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => { const k = (e) => { if (e.key === 'Escape') onClose(); }; window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k); }, [onClose]);

  const act = async (p, msg) => { setBusy(true); const r = await run(p, msg); setBusy(false); if (r !== undefined) { await load(); onChanged(); } return r; };
  const label = Object.fromEntries(stages.map((d) => [d.stage, d.label]));
  const cur = stages.find((d) => d.stage === l?.stage);
  const next = stages.filter((d) => cur && !cur.terminal && d.ord > cur.ord && d.stage !== 'lost');
  const name = (e) => staff.find((x) => x.id === e)?.name || (e ? 'Staff' : 'System');

  const moveTo = async (d) => {
    if (d.needs_evidence) { setQualify({}); return; }
    let note = null;
    if (d.terminal) { note = await promptDialog(`Mark as ${d.label}?`, { message: 'Add a short note (optional).', confirmText: d.label }); if (note === null) return; }
    act(rpc('api_ads_lead_set_stage', { p_lead: id, p_stage: d.stage, p_note: note || null, p_evidence: {} }), `Moved to ${d.label}.`);
  };
  const lost = async () => {
    const why = await promptDialog('Mark as Lost', { message: 'Why? (e.g. not interested, not eligible, chose another academy)', required: true, confirmText: 'Mark Lost' });
    if (why !== null) act(rpc('api_ads_lead_set_stage', { p_lead: id, p_stage: 'lost', p_note: why, p_evidence: {} }), 'Marked as Lost.');
  };
  const reopen = async () => {
    const why = await promptDialog('Reopen this lead', { message: 'Why is it being reopened?', required: true, confirmText: 'Reopen' });
    if (why !== null) act(rpc('api_ads_lead_set_stage', { p_lead: id, p_stage: 'contacted', p_note: why, p_evidence: {} }), 'Reopened.');
  };
  const quarantine = async (on) => {
    const why = await promptDialog(on ? 'Move to quarantine' : 'Release from quarantine', { message: on ? 'Why? (spam, test, fake number…)' : 'What did you check?', required: true });
    if (why !== null) act(rpc('api_ads_lead_quarantine', { p_lead: id, p_quarantined: on, p_reason: why }), on ? 'Quarantined.' : 'Released.');
  };
  const saveQualify = () => {
    const ev = Object.fromEntries(Object.entries(qualify).filter(([, v]) => String(v ?? '').trim() !== ''));
    if (!Object.keys(ev).length) { showToast('Record at least one answer', 'error'); return; }
    act(rpc('api_ads_lead_set_stage', { p_lead: id, p_stage: 'qualified', p_note: ev.note || null, p_evidence: ev }), 'Marked as Qualified Lead.').then((r) => { if (r !== undefined) setQualify(null); });
  };

  const timeline = useMemo(() => {
    if (!l) return [];
    const t = [];
    for (const e of l.enquiries || []) t.push({ at: e.at, k: 'enq', text: `Enquiry${e.touch?.utm_campaign ? ` from ${e.touch.utm_campaign}` : ''}${e.dedup === 'repeat_enquiry' ? ' (repeat)' : ''}`, sub: e.touch?.page_url || e.touch?.landing_page });
    for (const s of l.stages || []) {
      if (s.from_stage === null) continue;
      t.push({ at: s.at, k: 'stage', text: s.from_stage === s.to_stage ? (s.note || 'Note') : `${label[s.from_stage] || s.from_stage} → ${label[s.to_stage] || s.to_stage}`,
        sub: [name(s.employee_id), s.from_stage !== s.to_stage && s.note, Object.keys(s.evidence || {}).filter((k) => k !== 'quarantine' && k !== 'test').length
          ? Object.entries(s.evidence).filter(([k]) => k !== 'quarantine' && k !== 'test').map(([k, v]) => `${k}: ${v}`).join(', ') : ''].filter(Boolean).join(' · ') });
    }
    for (const a of l.assignments || []) t.push({ at: a.at, k: 'assign', text: `Assigned to ${a.to_employee ? name(a.to_employee) : 'nobody'}`, sub: [name(a.by_employee), a.reason].filter(Boolean).join(' · ') });
    for (const c of l.contacts || []) t.push({ at: c.at, k: 'call', text: `${c.channel === 'phone' ? 'Call' : c.channel}: ${(CONTACT.find(([k]) => k === c.outcome) || [, c.outcome])[1]}`, sub: [name(c.employee_id), c.note].filter(Boolean).join(' · ') });
    return t.sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [l, stages, staff]);

  const ft = l?.first_touch || {};
  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center p-0 sm:p-4" style={{ background: 'rgba(0,0,0,0.35)' }} onClick={onClose}>
      <div role="dialog" aria-label="Ads lead" onClick={(e) => e.stopPropagation()}
        className="w-full sm:max-w-2xl max-h-[92vh] overflow-y-auto rounded-t-3xl sm:rounded-3xl p-4 space-y-3"
        style={{ background: 'rgba(255,255,255,0.92)', backdropFilter: 'blur(24px)', WebkitBackdropFilter: 'blur(24px)', boxShadow: '0 20px 60px rgba(0,0,0,0.25)' }}>
        {err && <div className="text-sm" style={{ color: '#C4261D' }}>{err}</div>}
        {!l && !err && <div className="text-center text-glass-muted py-10 text-sm">Loading…</div>}
        {l && <>
          <div className="flex items-start gap-3">
            <div className="min-w-0 flex-1">
              <div className="text-lg font-bold text-glass-primary truncate">{l.name}</div>
              <div className="text-sm text-glass-secondary">{formatPhone(l.phone_e164)}{l.email ? ` · ${l.email}` : ''}</div>
              <div className="flex flex-wrap gap-1 mt-1">
                <Chip fg={(STAGE_TONE[l.stage] || [])[0]} bg={(STAGE_TONE[l.stage] || [])[1]}>{label[l.stage] || l.stage}</Chip>
                <Chip>{pipe === 'charter' ? 'Charter' : 'Pilot Training'}</Chip>
                {l.quarantined && <Chip fg="#8A5A00" bg="rgba(255,149,0,0.16)">Quarantined</Chip>}
                {l.organic_lead_id && <Chip>Also in Leads</Chip>}
              </div>
            </div>
            <CloseButton onClick={onClose} />
          </div>

          <QuickActions phone={displayPhone(l.phone_e164)} email={l.email} name={l.name}
            waText={`Hello ${l.name}, this is We One Aviation regarding your enquiry.`} />

          <div className="glass-card p-3 text-xs space-y-0.5">
            <div className="font-semibold text-glass-primary text-sm mb-1">Came from</div>
            <div>{[ft.gclid || ft.gbraid || ft.wbraid ? 'Google Ads click' : ft.fbclid || ft.fbc ? 'Meta ad click' : 'Paid campaign', ft.utm_source, ft.utm_campaign].filter(Boolean).join(' · ')}</div>
            {ft.landing_page && <div className="truncate text-glass-muted">Landing page: {ft.landing_page}</div>}
            <div className="text-glass-muted">First enquiry {when(l.created_at)}{l.enquiry_count > 1 ? ` · ${l.enquiry_count} enquiries` : ''}
              {l.first_response_at ? ` · first response after ${span(Math.round((Date.parse(l.first_response_at) - Date.parse(l.created_at)) / 60000))}` : ''}</div>
            {l.course_interest && <div>Course: {l.course_interest}</div>}
            {l.charter_details?.from && <div>Trip: {l.charter_details.from} → {l.charter_details.to}{l.charter_details.departureDate ? ` · ${l.charter_details.departureDate}` : ''}{l.charter_details.passengers ? ` · ${l.charter_details.passengers} pax` : ''}</div>}
            <div className="text-glass-muted">Consent: reply {l.consent?.enquiry_response} · marketing {l.consent?.marketing} · share with Google/Meta {l.consent?.ad_data_sharing}</div>
          </div>

          {canEdit && !l.quarantined && <>
            {cur && !cur.terminal && <div>
              <div className="text-xs font-medium text-glass-secondary mb-1">Log a call</div>
              <div className="flex flex-wrap gap-1.5">
                {CONTACT.map(([k, t]) => <Btn key={k} ghost disabled={busy} onClick={() => act(rpc('api_ads_lead_log_contact', { p_lead: id, p_channel: 'phone', p_outcome: k, p_note: null }), 'Call logged.')}>{t}</Btn>)}
              </div>
            </div>}
            <div>
              <div className="text-xs font-medium text-glass-secondary mb-1">Move to</div>
              <div className="flex flex-wrap gap-1.5">
                {next.map((d) => <Btn key={d.stage} disabled={busy} tone={d.customer ? '#34C759' : '#007AFF'} onClick={() => moveTo(d)}>{d.label}</Btn>)}
                {cur && !cur.terminal && <Btn ghost disabled={busy} onClick={lost}>Lost</Btn>}
                {cur?.terminal && isAdmin && <Btn ghost disabled={busy} onClick={reopen}>Reopen</Btn>}
              </div>
            </div>
            {qualify && (
              <div className="glass-card p-3 space-y-2">
                <div className="text-sm font-semibold text-glass-primary">Qualified Lead: record what you checked</div>
                {QUALIFY_FIELDS[pipe].map(([k, t, kind]) => (
                  <label key={k} className="flex items-center justify-between gap-3 text-sm">
                    <span>{t}</span>
                    {kind === 'yn'
                      ? <select aria-label={t} className="glass-input px-2 py-1.5 text-sm" value={qualify[k] || ''} onChange={(e) => setQualify({ ...qualify, [k]: e.target.value })}>
                          <option value="">—</option><option>Yes</option><option>No</option></select>
                      : <input aria-label={t} className="glass-input px-2 py-1.5 text-sm w-40" value={qualify[k] || ''} onChange={(e) => setQualify({ ...qualify, [k]: e.target.value })} />}
                  </label>))}
                <input aria-label="Note" className="glass-input px-3 py-2 text-sm w-full" placeholder="Note (optional)" value={qualify.note || ''} onChange={(e) => setQualify({ ...qualify, note: e.target.value })} />
                <div className="flex gap-2 justify-end"><Btn ghost onClick={() => setQualify(null)}>Cancel</Btn><Btn tone="#34C759" disabled={busy} onClick={saveQualify}>Mark Qualified</Btn></div>
              </div>)}
          </>}

          {canEdit && <div className="flex flex-wrap items-center gap-2">
            <label className="text-sm flex items-center gap-2"><span className="text-xs font-medium text-glass-secondary">Assigned to</span>
              <select aria-label="Assigned to" className="glass-input px-2 py-1.5 text-sm" value={l.owner_employee_id || ''} disabled={busy}
                onChange={(e) => act(rpc('api_ads_lead_assign', { p_lead: id, p_employee: e.target.value || null, p_reason: null }), 'Assigned.')}>
                <option value="">Unassigned</option>{staff.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select></label>
            <span className="flex-1" />
            <Btn ghost disabled={busy} onClick={() => quarantine(!l.quarantined)}>{l.quarantined ? 'Release from quarantine' : 'Quarantine'}</Btn>
          </div>}
          {l.quarantined && <div className="text-xs" style={{ color: '#8A5A00' }}>Reasons: {(l.quarantine_reasons || []).join(', ')}</div>}

          <div>
            <div className="text-sm font-semibold text-glass-primary mb-1">History</div>
            <ol className="space-y-1.5">
              {timeline.map((e, i) => (
                <li key={i} className="flex gap-2 text-xs">
                  <span className="text-glass-muted w-28 shrink-0">{when(e.at)}</span>
                  <span className="min-w-0"><span className="text-glass-primary">{e.text}</span>{e.sub && <span className="block text-glass-muted truncate">{e.sub}</span>}</span>
                </li>))}
              {!timeline.length && <li className="text-xs text-glass-muted">No activity yet.</li>}
            </ol>
          </div>
        </>}
      </div>
    </div>
  );
}
