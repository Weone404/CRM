// The lead window. One place to call, record the result, plan the next call, book a demo, note the student's
// education and fees, and see everything that happened so far.
//   Phones: a bottom sheet, actions first, a Save bar that stays at the bottom.
//   Tablet / desktop: two columns (update on the right, profile and history on the left).
// Saves: the call result through the existing Leads API (onContact), everything else through api_lead_ws_save.
import { lazy, Suspense, useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { displayPhone, formatRelativeTime } from '../utils/formatters';
import QuoteGenerator from './QuoteGenerator';
import { CLOSURE, charterRef, formatTime, formatTripDate, labelOf, routeLine, segmentOf, shortPlace } from '../utils/charter';
import { modalProps } from './ui/overlay';
import { confirmDialog } from './ui/dialogs';
import QuickActions, { CloseButton } from './ui/QuickActions';
import { showToast } from '../utils/toast';
import Icon from './icons';
import { TEMP, temperature } from '../utils/leadPlan';
import { DemoBooking, NotesBox, Section, StudentCard, Timeline, WhenToConnect, historyOf, payloadOf, profileOf,
  saveWorkspace, setDemoStatus, useWorkspace, EMPTY_PROFILE } from './leads/LeadPlanner';
import './leads/leads.css';
import { USE_SUPABASE } from '../backend/mode';

const LeadWhatsApp = lazy(() => import('./whatsapp/LeadWhatsApp'));

const OUTCOMES = [
  ['Interested', 'Interested', '#34C759', 'checkCircle'],
  ['Callback', 'Call back', '#AF52DE', 'refresh'],
  ['Not reachable', 'Not reachable', '#FF9500', 'phone'],
  ['Not interested', 'Not interested', '#8E8E93', 'xCircle'],
  ['Closed', 'Closed', '#1C1C1E', 'lock'],
];
const initials = (n) => String(n || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]?.toUpperCase() || '').join('') || '?';

function Pill({ children, fg = '#3C3C43', bg = 'rgba(118,118,128,0.12)', dot }) {
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ color: fg, background: bg }}>
      {dot && <span className="w-1.5 h-1.5 rounded-full" style={{ background: dot }} />}{children}
    </span>
  );
}

export default function LeadDetail({ lead, onClose, onContact, onRefresh, nextLead, onOpenLead }) {
  const isCharter = segmentOf(lead) === 'charter';
  const closure = CLOSURE[isCharter ? 'charter' : 'aviation'];
  const trip = lead.charter_details || {};
  const { ws, reload } = useWorkspace('lead', lead.id);

  const [disposition, setDisposition] = useState('');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [track, setTrack] = useState(lead.interest_track || '');
  const [note, setNote] = useState('');
  const [profile, setProfile] = useState(EMPTY_PROFILE);
  const [profileDirty, setProfileDirty] = useState(false);
  const [connect, setConnect] = useState(null);
  const [demo, setDemo] = useState(null);
  const [busy, setBusy] = useState(false);
  const [showQuoteGen, setShowQuoteGen] = useState(false);
  useEffect(() => { if (ws && !profileDirty) setProfile(profileOf(ws)); }, [ws]); // eslint-disable-line react-hooks/exhaustive-deps

  const payload = payloadOf({ profile, profileDirty: profileDirty && !isCharter, connect, demo: isCharter ? null : demo, note: disposition ? '' : note });
  const dirty = Boolean(disposition) || Object.keys(payload).length > 0 || Boolean(demo);
  const openFollowup = useMemo(() => (ws?.followups || []).find((f) => !f.done), [ws]);
  const history = useMemo(() => historyOf(ws), [ws]);
  const temp = temperature(lead);

  const requestClose = async () => {
    if (dirty && !(await confirmDialog('Discard your changes?', { message: 'What you picked or typed in this window will be lost.', confirmText: 'Discard', cancelText: 'Keep editing', danger: true }))) return;
    onClose();
  };

  const save = async (goNext) => {
    if (demo && !demo.ready) { showToast('Finish the demo steps (or tap Cancel on the demo)', 'error'); document.getElementById('lp-demo')?.scrollIntoView({ behavior: 'smooth', block: 'center' }); return; }
    if (disposition === 'Closed' && !closureOutcome) { showToast(`Choose ${closure.positive.label} or ${closure.negative.label}`, 'error'); return; }
    if (disposition === 'Interested' && !isCharter && !track) { showToast('Choose the course: CPL, PPL or Flying', 'error'); return; }
    if (disposition === 'Callback' && !connect?.date) { showToast('Pick when to call back', 'error'); document.getElementById('lp-connect')?.scrollIntoView({ behavior: 'smooth', block: 'center' }); return; }
    if (!dirty) { showToast('Nothing to save yet', 'error'); return; }
    setBusy(true);
    try {
      if (disposition === 'Closed') await onContact(lead.id, { closure_outcome: closureOutcome, note });
      else if (disposition) await onContact(lead.id, { channel: 'phone', disposition, note, ...(disposition === 'Interested' && !isCharter ? { interest_track: track } : {}) });
    } catch { setBusy(false); return; }                       // onContact already said what went wrong; keep the window
    try {
      if (Object.keys(payload).length) { await saveWorkspace('lead', lead.id, payload); await onRefresh?.(); }
    } catch (e) { showToast(`Not saved: ${e.message}`, 'error'); setBusy(false); return; }
    setBusy(false);
    showToast(goNext && nextLead ? `Saved. Next: ${nextLead.name}` : 'Saved', 'success');
    if (goNext && nextLead) onOpenLead(nextLead); else onClose();
  };

  const waText = isCharter
    ? `Hello ${lead.name}, this is Book My Charter regarding your charter enquiry ${charterRef(lead.id)} (${routeLine(trip)}${trip.departureDate ? `, ${formatTripDate(trip.departureDate)}` : ''}).`
    : `Hello ${lead.name}, this is We One Aviation regarding your enquiry.`;

  const tripRows = isCharter ? [
    ['From', trip.from], ['To', trip.to],
    ['Departure', [formatTripDate(trip.departureDate), formatTime(trip.departureTime)].filter(Boolean).join(' · ') || null],
    ['Trip', trip.tripType ? labelOf(trip.tripType) : null], ['Return', trip.returnDate ? formatTripDate(trip.returnDate) : null],
    ['Passengers', trip.passengers], ['Aircraft preference', trip.aircraftPreference ? labelOf(trip.aircraftPreference) : null],
    ['Purpose', trip.purpose ? labelOf(trip.purpose) : null], ['Flexible dates', trip.flexibleDates ? 'Yes' : null],
    ['Requirements', trip.additionalRequirements], ['Page', trip.sourcePath],
  ].filter(([, v]) => v !== null && v !== undefined && v !== '') : [];

  const about = [
    !isCharter && ['Course', lead.course_interest],
    lead.guardian_name && ['Guardian', lead.guardian_name],
    !isCharter && ['Address', lead.address],
    (lead.utm_source || lead.utm_campaign) && ['Source', [lead.utm_source, lead.utm_medium, lead.utm_campaign].filter(Boolean).join(' / ')],
    ['Received', lead.created_at ? new Date(lead.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }) : null],
    ws?.owner && ['Looked after by', ws.owner.name],
  ].filter((r) => r && r[1]);

  const outcome = OUTCOMES.find(([v]) => v === disposition);

  return (
    <>
      {createPortal(
        <div className="fixed inset-0 glass-overlay z-50 flex items-end sm:items-center justify-center sm:p-4" data-nosheet="" {...modalProps(requestClose)}>
          <div className="lp-sheet" role="dialog" aria-modal="true" aria-label={`Lead: ${lead.name}`}>
            <div className="lp-grab" aria-hidden="true" />
            {/* header */}
            <div className="flex items-start gap-3 px-4 sm:px-6 pt-3 sm:pt-5 pb-3" style={{ borderBottom: '0.5px solid rgba(60,60,67,0.15)' }}>
              <div className="w-12 h-12 rounded-full grid place-items-center text-white font-bold text-[17px] shrink-0"
                style={{ background: isCharter ? 'linear-gradient(160deg,#5AC8FA,#007AFF)' : 'linear-gradient(160deg,#7D7AFF,#5856D6)' }}>{initials(lead.name)}</div>
              <div className="min-w-0 flex-1">
                <h2 className="text-[19px] sm:text-[22px] font-bold text-glass-primary leading-tight truncate">{lead.name}</h2>
                <div className="text-[13px] text-glass-secondary truncate">{displayPhone(lead.phone)}{lead.email ? ` · ${lead.email}` : ''}</div>
                <div className="flex flex-wrap gap-1 mt-1.5">
                  <Pill fg="#0058C2" bg="rgba(0,122,255,0.10)">{lead.status === 'new' || !lead.status ? 'New' : lead.status}</Pill>
                  {temp && <Pill fg={TEMP[temp].fg} bg={TEMP[temp].bg} dot={TEMP[temp].dot}>{TEMP[temp].label}</Pill>}
                  {lead.interest_track && <Pill>{lead.interest_track}</Pill>}
                  {lead.utm_source && <Pill>{lead.utm_source}</Pill>}
                  {lead.created_at && <Pill>{formatRelativeTime(lead.created_at)}</Pill>}
                  {isCharter && <Pill>{charterRef(lead.id)}</Pill>}
                </div>
              </div>
              <CloseButton onClick={requestClose} />
            </div>

            {/* body */}
            <div className="flex-1 overflow-y-auto overflow-x-hidden overscroll-contain px-3 sm:px-6 py-3 sm:py-4">
              <QuickActions phone={lead.phone} email={lead.email} name={lead.name} waText={waText} className="mb-3" />
              {USE_SUPABASE && <Suspense fallback={null}><LeadWhatsApp leadId={lead.id} /></Suspense>}
              <div className="grid gap-3 lg:grid-cols-[minmax(0,0.95fr)_minmax(0,1.15fr)] items-start">
                {/* right on desktop, first on phones: what to do now */}
                <div className="space-y-3 min-w-0">
                  <Section icon="phone" title="Result of this call" hint="Optional. Pick one if you spoke or tried to call." tone="#007AFF">
                    <div className="grid grid-cols-3 sm:grid-cols-5 gap-2">
                      {OUTCOMES.map(([v, l, c, ic]) => (
                        <button key={v} type="button" className="lp-outcome" aria-pressed={disposition === v}
                          style={disposition === v ? { background: c } : { color: c }}
                          onClick={() => { setDisposition(disposition === v ? '' : v); setClosureOutcome(''); }}>
                          <Icon name={ic} size={18} /><span className="text-center leading-tight" style={disposition === v ? undefined : { color: '#3C3C43' }}>{l}</span>
                        </button>
                      ))}
                    </div>
                    {disposition === 'Interested' && !isCharter && (
                      <div className="mt-3 lp-reveal">
                        <div className="lp-sublabel">Which course?</div>
                        <div className="grid grid-cols-3 gap-2">
                          {['CPL', 'PPL', 'Flying'].map((t) => (
                            <button key={t} type="button" className={`lp-chip ${track === t ? 'lp-chip-on' : ''}`} style={track === t ? { background: '#34C759', borderColor: '#34C759' } : undefined} onClick={() => setTrack(t)}>{t}</button>
                          ))}
                        </div>
                      </div>
                    )}
                    {disposition === 'Closed' && (
                      <div className="mt-3 grid grid-cols-2 gap-2 lp-reveal">
                        {[[closure.positive, '#34C759'], [closure.negative, '#FF3B30']].map(([o, c]) => (
                          <button key={o.value} type="button" className={`lp-chip ${closureOutcome === o.value ? 'lp-chip-on' : ''}`}
                            style={closureOutcome === o.value ? { background: c, borderColor: c } : undefined} onClick={() => setClosureOutcome(o.value)}>{o.label}</button>
                        ))}
                      </div>
                    )}
                    {disposition === 'Callback' && !connect?.date && <div className="mt-2 text-[12px] lp-reveal" style={{ color: '#AF52DE' }}>Pick when to call back just below.</div>}
                  </Section>
                  <div id="lp-connect"><WhenToConnect value={connect} onChange={setConnect} current={openFollowup} /></div>
                  {!isCharter && (
                    <div id="lp-demo"><DemoBooking value={demo} onChange={setDemo} demos={ws?.demos || []}
                      onStatus={async (id, st) => { if (await setDemoStatus(id, st)) { await reload(); onRefresh?.(); } }} /></div>
                  )}
                  <NotesBox value={note} onChange={setNote} last={lead.last_note}
                    placeholder={isCharter ? 'e.g. Wants options after 3 PM' : 'e.g. Father will decide; call after his shift'} />
                </div>

                {/* left on desktop: who this is */}
                <div className="space-y-3 min-w-0 lg:order-first">
                  {isCharter ? (
                    <Section icon="plane" title={`${shortPlace(trip.from)} → ${shortPlace(trip.to)}`} hint={charterRef(lead.id)} tone="#007AFF">
                      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[14px]">
                        {tripRows.map(([k, v]) => <div key={k} className="contents"><dt className="text-glass-secondary">{k}</dt><dd className="text-glass-primary break-words">{v}</dd></div>)}
                      </dl>
                    </Section>
                  ) : (
                    <StudentCard profile={profile} onChange={(p) => { setProfile(p); setProfileDirty(true); }} />
                  )}
                  <Section icon="profile" title="About this lead" tone="#8E8E93">
                    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[14px]">
                      {about.map(([k, v]) => <div key={k} className="contents"><dt className="text-glass-secondary">{k}</dt><dd className="text-glass-primary break-words">{v}</dd></div>)}
                    </dl>
                    {!isCharter && (
                      <button type="button" className="lp-btn lp-btn-soft w-full mt-3" onClick={() => setShowQuoteGen(true)}><Icon name="form" size={16} />Make a fee quote</button>
                    )}
                  </Section>
                  <Section icon="clock" title="History" hint={history.length ? `${history.length} so far` : null} tone="#5AC8FA">
                    <Timeline items={history} />
                  </Section>
                </div>
              </div>
            </div>

            {/* save bar */}
            <div className="px-3 sm:px-6 pt-3 pb-[calc(12px+env(safe-area-inset-bottom))] flex items-center gap-2" style={{ borderTop: '0.5px solid rgba(60,60,67,0.15)', background: 'rgba(249,249,251,0.92)' }}>
              <div className="hidden sm:block flex-1 min-w-0 text-[12px] text-glass-muted truncate">
                {dirty ? ['Will save:', outcome && outcome[1], payload.profile && 'student details', payload.followup && 'next call', payload.demo && 'demo', (payload.note || (disposition && note)) && 'note'].filter(Boolean).join(' ') : 'Nothing changed yet'}
              </div>
              {nextLead && (
                <button type="button" className="lp-btn lp-btn-soft flex-1 sm:flex-none" disabled={busy || !dirty} onClick={() => save(true)} title={`Then open ${nextLead.name}`}>
                  Save & next<Icon name="chevronRight" size={16} />
                </button>
              )}
              <button type="button" className="lp-btn lp-btn-primary flex-1 sm:flex-none sm:min-w-[140px]" disabled={busy || !dirty} onClick={() => save(false)}>{busy ? 'Saving…' : 'Save'}</button>
            </div>
          </div>
        </div>,
        document.body,
      )}
      {showQuoteGen && <QuoteGenerator lead={lead} onClose={() => setShowQuoteGen(false)} />}
    </>
  );
}
