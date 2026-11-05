import { useState, useEffect, useCallback } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';
import FlightBridgeSchools from './FlightBridgeSchools';
import FlightBridgeDetector from './FlightBridgeDetector';
import Icon from './icons';
import SectionNav from './SectionNav';
import { countryName } from '../utils/country';
import { Areas, Automation, Team } from './FlightBridgeOps';

// FlightBridge partnership module (Admin only). This screen records human decisions.
// It never sends email: the central FlightBridge service runs compliance checks and is the only sender.

const RISK_STYLE = { RED: 'bg-red-100 text-red-800', AMBER: 'bg-yellow-100 text-yellow-800', GREEN: 'bg-green-100 text-green-800' };
const OUT_STYLE = {
  dry_run_rendered: 'bg-blue-100 text-blue-800', blocked: 'bg-red-100 text-red-800', needs_review: 'bg-yellow-100 text-yellow-800',
  sent: 'bg-green-100 text-green-800', send_unknown: 'bg-orange-100 text-orange-800', failed: 'bg-red-100 text-red-800',
};

const HUMAN_FACTS = [
  'message_relevant_to_business_role', 'no_refusal_statement_near_address', 'address_conspicuously_published',
  'recipient_is_corporate_subscriber', 'legitimate_interests_assessment_done',
];

async function call(path, opts = {}) {
  const token = localStorage.getItem('token');
  const res = await apiFetch(`/api/flightbridge${path}`, {
    token, ...opts,
    headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

function Badge({ text, style }) {
  return <span className={`glass-badge ${style || 'bg-gray-100 text-gray-800'}`}>{text}</span>;
}

function Reasons({ list }) {
  if (!list || !list.length) return null;
  return <ul className="text-xs text-glass-muted list-disc ml-4 mt-1">{list.map((r, i) => <li key={i}>{r}</li>)}</ul>;
}

function ApprovalDetail({ id, onDone, onBack }) {
  const [t, setT] = useState(null);
  const [edit, setEdit] = useState(false);
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [ev, setEv] = useState({ fact: HUMAN_FACTS[0], source_url: '', excerpt: '' });

  const load = useCallback(async () => {
    try {
      const d = await call(`/approvals/${id}`);
      setT(d); setSubject(d.draft_subject); setBody(d.draft_body);
    } catch (e) { showToast(e.message, 'error'); }
  }, [id]);
  useEffect(() => { load(); }, [load]);

  const decide = async (action) => {
    if (action === 'reject' && !confirm('Reject this draft?')) return;
    setBusy(true);
    try {
      const payload = { action, note: note || null };
      if (action === 'edit_approve') { payload.subject = subject; payload.body = body; }
      const r = await call(`/approvals/${id}/decision`, { method: 'POST', body: JSON.stringify(payload) });
      showToast(r.message || `Marked ${r.status}`, 'success');
      onDone();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };

  const addEvidence = async () => {
    try {
      await call('/evidence', { method: 'POST', body: JSON.stringify({ contact_id: t.contact_id, ...ev }) });
      showToast('Evidence recorded', 'success'); setEv({ ...ev, source_url: '', excerpt: '' }); load();
    } catch (e) { showToast(e.message, 'error'); }
  };

  if (!t) return <div className="text-glass-muted p-6">Loading…</div>;
  const q = t.qualification;
  return (
    <div className="space-y-4">
      <button onClick={onBack} className="text-sm text-indigo-600 hover:underline">← Back to queue</button>
      <div className="glass-card p-4">
        <div className="flex justify-between items-start">
          <div>
            <div className="text-lg font-semibold text-glass-primary">{t.organisation?.name}</div>
            <div className="text-sm text-glass-secondary">{t.organisation?.country} · {t.organisation?.website_domain || 'no website'} · {t.contact?.email} {t.contact?.is_role_address ? '(role address)' : '(named person)'}</div>
            <div className="text-xs text-glass-muted mt-1">Contact source: <a className="underline" href={t.contact?.source_url} target="_blank" rel="noopener noreferrer">{t.contact?.source_url}</a></div>
          </div>
          <Badge text={t.risk} style={RISK_STYLE[t.risk]} />
        </div>
        <div className="text-sm mt-3"><b>Why this needs you:</b> {t.escalation_reason}</div>
        {t.summary && <div className="text-sm mt-1"><b>Summary:</b> {t.summary}</div>}
      </div>

      <div className="grid md:grid-cols-2 gap-4">
        <div className="glass-card p-4">
          <div className="font-semibold mb-2">Regulatory status</div>
          {t.regulatory.length === 0 && <div className="text-sm text-red-600">No regulator record: unverified</div>}
          {t.regulatory.map((r, i) => (
            <div key={i} className="text-sm mb-1">{r.authority_code} · {r.classification} · {r.approval_ref || '—'} · <Badge text={r.status} />
              <div className="text-xs text-glass-muted">checked {new Date(r.checked_at).toLocaleDateString()} · <a className="underline" href={r.source_url} target="_blank" rel="noopener noreferrer">source</a></div></div>
          ))}
          {q && (<div className="mt-3 text-sm"><b>Qualification:</b> {q.score}/100 ({q.confidence} confidence) → {q.recommended_action}
            {q.missing?.length > 0 && <div className="text-xs text-glass-muted">Missing: {q.missing.join(', ')}</div>}
            {q.risks?.length > 0 && <div className="text-xs text-orange-600">Risks: {q.risks.join(', ')}</div>}</div>)}
        </div>
        <div className="glass-card p-4">
          <div className="font-semibold mb-2">Legal-condition evidence for this contact</div>
          {t.contact_evidence.length === 0 && <div className="text-sm text-glass-muted">None recorded</div>}
          {t.contact_evidence.map((e, i) => (
            <div key={i} className="text-xs mb-2"><b>{e.fact}</b> · {e.method} · expires {new Date(e.expires_at).toLocaleDateString()}
              <div className="text-glass-muted">“{e.excerpt}”</div></div>
          ))}
          <div className="mt-2 space-y-1">
            <select className="glass-input w-full px-2 py-1 text-sm" value={ev.fact} onChange={(e) => setEv({ ...ev, fact: e.target.value })}>
              {HUMAN_FACTS.map((f) => <option key={f} value={f}>{f}</option>)}
            </select>
            <input className="glass-input w-full px-2 py-1 text-sm" placeholder="Source URL you checked" value={ev.source_url} onChange={(e) => setEv({ ...ev, source_url: e.target.value })} />
            <input className="glass-input w-full px-2 py-1 text-sm" placeholder="Exact text that proves it" value={ev.excerpt} onChange={(e) => setEv({ ...ev, excerpt: e.target.value })} />
            <button onClick={addEvidence} disabled={!ev.source_url || ev.excerpt.length < 3} className="glass-btn px-3 py-1 text-sm">Record verified evidence</button>
          </div>
        </div>
      </div>

      {t.thread.length > 0 && (
        <div className="glass-card p-4">
          <div className="font-semibold mb-2">Conversation</div>
          {t.thread.map((m, i) => (
            <div key={i} className="text-sm mb-3 border-l-2 pl-3" style={{ borderColor: m.direction === 'inbound' ? '#5856D6' : '#34C759' }}>
              <div className="text-xs text-glass-muted">{m.direction} · {m.from_address} · {new Date(m.occurred_at).toLocaleString()}</div>
              <div className="font-medium">{m.subject}</div><div className="whitespace-pre-wrap">{m.body_text}</div>
            </div>
          ))}
        </div>
      )}

      <div className="glass-card p-4">
        <div className="flex justify-between items-center mb-2">
          <div className="font-semibold">Proposed email <span className="text-xs text-glass-muted">({t.generator})</span></div>
          {t.status === 'open' && <button onClick={() => setEdit(!edit)} className="text-sm text-indigo-600 hover:underline">{edit ? 'Cancel edit' : 'Edit'}</button>}
        </div>
        {edit ? (
          <>
            <input className="glass-input w-full px-3 py-2 mb-2" value={subject} maxLength={150} onChange={(e) => setSubject(e.target.value)} />
            <textarea className="glass-input w-full px-3 py-2" rows={12} value={body} onChange={(e) => setBody(e.target.value)} />
          </>
        ) : (
          <>
            <div className="font-medium">{t.draft_subject}</div>
            <div className="text-sm whitespace-pre-wrap mt-1">{t.draft_body}</div>
          </>
        )}
        <div className="text-xs text-glass-muted mt-2">The legal footer (identity, address, contact, opt-out, reference) is added automatically and cannot be edited here.</div>
        {Array.isArray(t.evidence) && t.evidence.length > 0 && <div className="text-xs text-glass-muted mt-1">Evidence: {t.evidence.join(' · ')}</div>}
      </div>

      {t.status === 'open' ? (
        <div className="glass-card p-4 space-y-2">
          <input className="glass-input w-full px-3 py-2 text-sm" placeholder="Decision note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex flex-wrap gap-2">
            {!edit && <button disabled={busy} onClick={() => decide('approve')} className="glass-btn px-4 py-2" style={{ background: '#34C759' }}>✓ Approve</button>}
            {edit && <button disabled={busy} onClick={() => decide('edit_approve')} className="glass-btn px-4 py-2" style={{ background: '#248A3D' }}>✓ Approve edited version</button>}
            <button disabled={busy} onClick={() => decide('more_research')} className="glass-btn px-4 py-2 text-sm">Request more research</button>
            <button disabled={busy} onClick={() => decide('resolve')} className="glass-btn px-4 py-2 text-sm">Mark resolved</button>
            <button disabled={busy} onClick={() => decide('reject')} className="glass-btn px-4 py-2 text-sm" style={{ background: '#FF3B30' }}>Reject</button>
          </div>
          <div className="text-xs text-glass-muted">Approving does not send. It queues the email for automatic jurisdiction and content checks; while DRY_RUN is on it is only rendered.</div>
        </div>
      ) : <div className="text-sm text-glass-secondary">Decided: <b>{t.status}</b> {t.decided_at && `on ${new Date(t.decided_at).toLocaleString()}`}</div>}
    </div>
  );
}



// "Write with AI": the person describes the email; the AI writes 3-5 different versions (3 subject lines each, the email
// and a 5-7 day follow-up) following the outreach writing rules. School facts stay placeholders, filled for each school
// from verified data when its draft is made. Picking a version saves it as a DRAFT template: an admin still approves it.
const SAMPLE_SCHOOL = { school_name: 'Sheble Aviation', city: 'Ardmore', state: 'Oklahoma', country: 'the United States', credential: 'FAA Part 141 certification' };
const PLACEHOLDER_RE = /\{\{\s*([a-z_]+)\s*\}\}/g;
const fillSample = (t) => (t || '').replace(PLACEHOLDER_RE, (m, k) => SAMPLE_SCHOOL[k] ?? m);
const PLACEHOLDER_HELP = [['{{school_name}}', 'school name'], ['{{city}}', 'town'], ['{{state}}', 'state / province'],
  ['{{country}}', 'country'], ['{{credential}}', 'its official approval, e.g. “FAA Part 141 certification”']];
const ABOUT_DEFAULT = 'We One Aviation is based in Dwarka, Delhi, and was founded in 2009. We teach DGCA ground subjects (theory) in classroom and online batches and provide pilot-career counselling to Indian students. We are looking for flying-school partners for our students’ practical flight training.';
const BRIEF_FIELDS = [
  ['sender_name', 'Your name', 'e.g. Nikhil Bisht'], ['sender_title', 'Your title', 'e.g. Partnerships Lead'],
  ['organisation', 'Organisation', 'We One Aviation'], ['sender_email', 'Email in the signature', 'e.g. info@weoneaviation.com'],
  ['sender_phone', 'Phone in the signature', 'e.g. +91 93556 11996'],
];

function VariantCard({ v, n, preview, onEdit, onSaved }) {
  const [pick, setPick] = useState(0);
  const [busy, setBusy] = useState(false);
  const [showFollow, setShowFollow] = useState(false);
  const show = (t) => (preview ? fillSample(t) : t);
  const problems = [...(v.check?.errors || []), ...(v.style || [])];
  const save = async () => {
    setBusy(true);
    try {
      const a = await call('/templates', { method: 'POST', body: JSON.stringify({ kind: 'initial', subject: v.subjects[pick], body: v.body }) });
      let msg = `Saved as First email v${a.version}`;
      if (v.followup_body) {
        const f = await call('/templates', { method: 'POST', body: JSON.stringify({ kind: 'followup_1', subject: v.followup_subject || v.subjects[pick], body: v.followup_body }) });
        msg += ` and Follow-up 1 v${f.version}`;
      }
      showToast(`${msg}. Review and approve them below.`, 'success');
      onSaved();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  return (
    <div className="glass-subtle p-3 space-y-2">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="font-semibold text-sm">{n}. {v.label}</div>
          {v.approach && <div className="text-xs text-glass-muted">{v.approach}</div>}
        </div>
        <Badge text={problems.length ? 'Needs a fix' : 'Passes checks'} style={problems.length ? 'bg-orange-100 text-orange-800' : 'bg-green-100 text-green-800'} />
      </div>
      <fieldset className="space-y-1">
        <legend className="text-xs font-medium text-glass-secondary">Subject line</legend>
        {v.subjects.map((sub, i) => (
          <label key={i} className="flex items-start gap-2 text-sm cursor-pointer">
            <input type="radio" name={`fb-ai-subj-${n}`} className="mt-1" checked={pick === i} onChange={() => setPick(i)} />
            <span>{show(sub)}</span>
          </label>
        ))}
      </fieldset>
      <div className="text-sm whitespace-pre-wrap rounded-lg p-3" style={{ background: 'rgba(255,255,255,0.55)' }}>{show(v.body)}</div>
      {v.followup_body && (
        <div>
          <button type="button" className="text-xs font-medium text-blue-600" onClick={() => setShowFollow((x) => !x)} aria-expanded={showFollow}>
            {showFollow ? 'Hide' : 'Show'} the follow-up (sent 5–7 days later if there is no reply)
          </button>
          {showFollow && (
            <div className="mt-1 text-sm whitespace-pre-wrap rounded-lg p-3" style={{ background: 'rgba(255,255,255,0.4)' }}>
              <div className="font-medium mb-1">{show(v.followup_subject)}</div>{show(v.followup_body)}
            </div>
          )}
        </div>
      )}
      {problems.length > 0 && <Reasons list={problems} />}
      {(v.check?.warnings || []).length > 0 && <div className="text-xs text-orange-700">{v.check.warnings.join(' ')}</div>}
      <div className="flex flex-wrap gap-2">
        <button disabled={busy} onClick={save} className="glass-btn px-4 py-2 text-sm">{busy ? 'Saving…' : 'Use this version'}</button>
        <button type="button" onClick={() => onEdit(v.subjects[pick], v.body)} className="glass-btn px-4 py-2 text-sm" style={{ background: 'rgba(118,118,128,0.18)', color: 'inherit' }}>Edit first</button>
      </div>
    </div>
  );
}

function AiWriter({ onSaved, onEdit }) {
  const [b, setB] = useState({ organisation: 'We One Aviation', about: ABOUT_DEFAULT, count: '3' });
  const [busy, setBusy] = useState(false);
  const [out, setOut] = useState(null);
  const [preview, setPreview] = useState(true);
  const [open, setOpen] = useState(true);
  useEffect(() => {
    call('/templates/brief').then((x) => {
      if (x && typeof x === 'object') setB((p) => ({ ...p, ...Object.fromEntries(Object.entries(x).filter(([k, v]) => v != null && v !== '' && k !== 'count')) }));
    }).catch(() => {});
  }, []);
  const set = (k) => (e) => setB((p) => ({ ...p, [k]: e.target.value }));
  const ready = ((b.reason || '') + (b.instructions || '')).trim().length >= 10;
  const generate = async () => {
    setBusy(true); setOut(null);
    try { setOut(await call('/templates/generate', { method: 'POST', body: JSON.stringify({ ...b, count: Number(b.count) }) })); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  return (
    <div className="glass-card p-4 space-y-3">
      <button type="button" className="w-full flex items-center justify-between gap-2 text-left" onClick={() => setOpen((x) => !x)} aria-expanded={open}>
        <span>
          <span className="block font-semibold">Write with AI</span>
          <span className="block text-xs text-glass-muted">Describe the email; get 3–5 different versions with subject lines and a follow-up. Pick one, then approve it below.</span>
        </span>
        <span className="text-glass-muted text-sm">{open ? 'Hide' : 'Show'}</span>
      </button>
      {open && (
        <>
          <div className="grid gap-2 sm:grid-cols-2">
            {BRIEF_FIELDS.map(([k, label, ph]) => (
              <label key={k} className="text-xs font-medium text-glass-secondary">{label}
                <input className="glass-input w-full px-3 py-2 text-sm mt-1" value={b[k] || ''} placeholder={ph} onChange={set(k)} maxLength={160} />
              </label>
            ))}
            <label className="text-xs font-medium text-glass-secondary">Versions to write
              <select className="glass-input w-full px-3 py-2 text-sm mt-1" value={b.count} onChange={set('count')}>
                {['3', '4', '5'].map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </label>
          </div>
          <label className="block text-xs font-medium text-glass-secondary">About your organisation (only these facts are used)
            <textarea className="glass-input w-full px-3 py-2 text-sm mt-1" rows={3} maxLength={2000} value={b.about || ''} onChange={set('about')} />
          </label>
          <div className="grid gap-2 sm:grid-cols-3">
            <label className="text-xs font-medium text-glass-secondary">Why you are writing
              <textarea className="glass-input w-full px-3 py-2 text-sm mt-1" rows={3} maxLength={1500} value={b.reason || ''} placeholder="e.g. Our students finish DGCA theory with us and need a flying school abroad for their CPL." onChange={set('reason')} />
            </label>
            <label className="text-xs font-medium text-glass-secondary">What the school gains
              <textarea className="glass-input w-full px-3 py-2 text-sm mt-1" rows={3} maxLength={1500} value={b.value || ''} placeholder="e.g. Students who arrive with theory done and documents ready." onChange={set('value')} />
            </label>
            <label className="text-xs font-medium text-glass-secondary">Next step you want
              <textarea className="glass-input w-full px-3 py-2 text-sm mt-1" rows={3} maxLength={300} value={b.next_step || ''} placeholder="e.g. A 15-minute call with the admissions team." onChange={set('next_step')} />
            </label>
          </div>
          <label className="block text-xs font-medium text-glass-secondary">Your instructions (anything else: tone, length, what to stress or avoid)
            <textarea id="fb-ai-prompt" className="glass-input w-full px-3 py-2 text-sm mt-1" rows={3} maxLength={3000} value={b.instructions || ''} placeholder="e.g. Keep it under 150 words. Mention that we can share student profiles before they apply." onChange={set('instructions')} />
          </label>
          <div className="text-xs text-glass-muted">
            Filled in for each school when its email is drafted, from verified data only:{' '}
            {PLACEHOLDER_HELP.map(([ph, what], i) => <span key={ph}>{i > 0 && ' · '}<code>{ph}</code> {what}</span>)}.
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button disabled={busy || !ready} onClick={generate} className="glass-btn px-4 py-2">{busy ? 'Writing… (about 20–40 seconds)' : out ? 'Write new versions' : 'Write versions'}</button>
            {!ready && <span className="text-xs text-glass-muted">Say why you are writing, or add instructions.</span>}
            {out && (
              <label className="text-sm flex items-center gap-2">
                <input type="checkbox" checked={preview} onChange={(e) => setPreview(e.target.checked)} /> Preview with a real school (Sheble Aviation, Ardmore)
              </label>
            )}
          </div>
          {out && (
            <div className="space-y-2">
              {out.variants.map((v, i) => <VariantCard key={`${i}-${v.label}`} v={v} n={i + 1} preview={preview} onEdit={onEdit} onSaved={onSaved} />)}
              <div className="text-xs text-glass-muted">Written by {out.model} on Groq. Nothing is sent: a saved version waits for approval, and every email still goes to Approvals first.</div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

const KIND_LABEL = { initial: 'First email', followup_1: 'Follow-up 1', followup_2: 'Follow-up 2', followup_3: 'Follow-up 3' };

function Templates() {
  const [list, setList] = useState([]);
  const [kind, setKind] = useState('initial');
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => { try { setList(await call('/templates')); } catch (e) { showToast(e.message, 'error'); } }, []);
  useEffect(() => { load(); }, [load]);
  const current = list.filter((t) => t.kind === kind);
  const approved = current.find((t) => t.status === 'approved');

  const save = async () => {
    setBusy(true);
    try {
      const r = await call('/templates', { method: 'POST', body: JSON.stringify({ kind, subject, body }) });
      setResult(r); showToast(r.validation.ok ? `Saved version ${r.version}` : `Saved version ${r.version} with problems`, r.validation.ok ? 'success' : 'warning');
      load();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const approve = async (id) => {
    try { await call(`/templates/${id}/approve`, { method: 'POST' }); showToast('Approved. New drafts will use this version.', 'success'); setResult(null); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };

  const editDraft = (subj, text) => {
    setKind('initial'); setSubject(subj); setBody(text); setResult(null);
    setTimeout(() => document.getElementById('fb-tpl-subject')?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 50);
  };

  return (
    <div className="space-y-4">
      <AiWriter onSaved={() => { setKind('initial'); setResult(null); load(); }} onEdit={editDraft} />
      <div className="glass-card p-4 space-y-3">
        <div className="flex flex-wrap gap-2 items-center justify-between">
          <div className="font-semibold">Paste or edit your outreach email</div>
          <select id="fb-tpl-kind" className="glass-input px-2 py-1 text-sm" value={kind} onChange={(e) => { setKind(e.target.value); setResult(null); }}>
            {Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </div>
        <input id="fb-tpl-subject" className="glass-input w-full px-3 py-2" maxLength={150} placeholder="Subject, e.g. Student referral partnership with {{school_name}}" value={subject} onChange={(e) => setSubject(e.target.value)} />
        <textarea id="fb-tpl-body" className="glass-input w-full px-3 py-2 font-mono text-sm" rows={12} placeholder={'Paste the email body here.\n\nYou may use {{school_name}}, {{city}}, {{state}}, {{country}} and {{credential}}.\nDo not add an unsubscribe line or signature divider: the legal footer is added automatically.'} value={body} onChange={(e) => setBody(e.target.value)} />
        <div className="flex flex-wrap gap-2 items-center">
          <button disabled={busy || !subject.trim() || body.trim().length < 20} onClick={save} className="glass-btn px-4 py-2">Save and check</button>
          <span className="text-xs text-glass-muted">Saving creates a new version. Only an approved version is used for drafts.</span>
        </div>
        {result && (
          <div className={`p-3 rounded-lg text-sm ${result.validation.ok ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'}`}>
            {result.validation.ok ? <div>Looks good. Version {result.version} is ready to approve.</div> : <div>Version {result.version} cannot be approved yet:</div>}
            <Reasons list={result.validation.errors} />
            {result.validation.warnings.length > 0 && <div className="mt-1 text-orange-700">{result.validation.warnings.join(' ')}</div>}
            {result.validation.ok && <button onClick={() => approve(result.id)} className="glass-btn px-3 py-1 text-xs mt-2" style={{ background: '#34C759' }}>Approve version {result.version}</button>}
          </div>
        )}
      </div>
      <div className="glass-card p-4">
        <div className="font-semibold mb-2">{KIND_LABEL[kind]}: versions</div>
        {!approved && <div className="text-sm text-orange-600 mb-2">No approved version. No {KIND_LABEL[kind].toLowerCase()} drafts will be created until one is approved.</div>}
        {current.map((t) => (
          <div key={t.id} className="border-t py-2 text-sm" style={{ borderColor: 'rgba(0,0,0,0.08)' }}>
            <div className="flex justify-between gap-2"><b>v{t.version} · {t.subject}</b><Badge text={t.status} style={t.status === 'approved' ? 'bg-green-100 text-green-800' : undefined} /></div>
            <div className="whitespace-pre-wrap text-glass-secondary mt-1">{t.body}</div>
            {t.status === 'draft' && t.validation?.ok && <button onClick={() => approve(t.id)} className="glass-btn px-3 py-1 text-xs mt-1">Approve this version</button>}
            {t.status === 'draft' && t.validation && !t.validation.ok && <Reasons list={t.validation.errors} />}
          </div>
        ))}
        {current.length === 0 && <div className="text-sm text-glass-muted">Nothing saved yet.</div>}
      </div>
    </div>
  );
}

function Inbox() {
  const [rows, setRows] = useState([]);
  const [risk, setRisk] = useState('');
  const [unmatched, setUnmatched] = useState(false);
  const load = useCallback(async () => {
    try { setRows(await call(`/inbox?${risk ? `risk=${risk}&` : ''}${unmatched ? 'unmatched=true' : ''}`)); } catch (e) { showToast(e.message, 'error'); }
  }, [risk, unmatched]);
  useEffect(() => { load(); }, [load]);
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2 items-center">
        <select id="fb-inbox-risk" className="glass-input px-2 py-1 text-sm" value={risk} onChange={(e) => setRisk(e.target.value)}>
          <option value="">All risk levels</option><option value="RED">RED</option><option value="AMBER">AMBER</option><option value="GREEN">GREEN</option>
        </select>
        <label className="text-sm flex items-center gap-1"><input id="fb-inbox-unmatched" type="checkbox" checked={unmatched} onChange={(e) => setUnmatched(e.target.checked)} /> Unmatched senders only</label>
      </div>
      {rows.map((m) => (
        <div key={m.id} className="glass-card p-3">
          <div className="flex justify-between gap-2 flex-wrap">
            <div className="font-semibold">{m.org_name || 'Unknown sender'} · <span className="text-sm font-normal">{m.from_address}</span></div>
            <div className="flex gap-1">{m.risk && <Badge text={m.risk} style={RISK_STYLE[m.risk]} />}{m.is_unsubscribe && <Badge text="unsubscribed" />}{m.is_bounce && <Badge text="bounce" />}{m.is_auto_reply && <Badge text="auto-reply" />}{m.injection && <Badge text="injection attempt" style="bg-red-100 text-red-800" />}</div>
          </div>
          <div className="text-sm">{m.subject}</div>
          <div className="text-xs text-glass-muted">{new Date(m.occurred_at).toLocaleString()} · {m.intent || 'not classified'} · matched by {m.match_method}</div>
          <div className="text-sm whitespace-pre-wrap mt-1 text-glass-secondary">{m.preview}</div>
        </div>
      ))}
      {rows.length === 0 && <div className="text-center text-glass-muted py-10">No inbound email yet.</div>}
    </div>
  );
}

function Metrics() {
  const [m, setM] = useState(null);
  const [days, setDays] = useState('');
  useEffect(() => {
    (async () => {
      try { setM(await call('/metrics')); const st = await call('/settings'); setDays((st.followup_schedule_days || []).join(', ')); }
      catch (e) { showToast(e.message, 'error'); }
    })();
  }, []);
  const saveDays = async () => {
    try {
      const arr = days.split(',').map((x) => parseInt(x.trim(), 10)).filter((x) => !Number.isNaN(x));
      await call('/settings/followups', { method: 'POST', body: JSON.stringify({ days: arr }) }); showToast('Follow-up schedule saved', 'success');
    } catch (e) { showToast(e.message, 'error'); }
  };
  if (!m) return <div className="text-glass-muted p-6">Loading…</div>;
  const tile = (label, value, hint) => (<div className="glass-card p-3"><div className="text-xs text-glass-muted">{label}</div><div className="text-2xl font-bold" style={{ fontVariantNumeric: 'tabular-nums' }}>{value}</div>{hint && <div className="text-xs text-glass-muted">{hint}</div>}</div>);
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {tile('Schools contacted', m.schools_contacted, 'first email actually sent')}
        {tile('Schools replied', m.schools_replied, 'excludes auto-replies and bounces')}
        {tile('Response rate', m.response_rate == null ? '—' : `${Math.round(m.response_rate * 100)}%`, 'replied ÷ contacted')}
        {tile('Bounces', m.bounces)}
        {tile('Waiting for you', m.approvals_open)}
        {tile('Approved', m.approvals_approved, `${m.approvals_edited} edited by a person`)}
        {tile('Rejected drafts', m.approvals_rejected)}
        {tile('Replies by risk', `${m.inbound_by_risk.GREEN || 0} / ${m.inbound_by_risk.AMBER || 0} / ${m.inbound_by_risk.RED || 0}`, 'green / amber / red')}
      </div>
      <div className="text-xs text-glass-muted">Email opens are not tracked: a tracking pixel cannot prove an email was read.</div>
      <div className="glass-card p-4 space-y-2">
        <div className="font-semibold">Follow-up schedule</div>
        <div className="text-sm text-glass-secondary">Days after the first email, e.g. 4, 9, 16. Follow-ups stop on any reply, opt-out or bounce, and each one still needs your approval.</div>
        <div className="flex gap-2"><input id="fb-followup-days" className="glass-input px-3 py-1 text-sm" value={days} onChange={(e) => setDays(e.target.value)} /><button onClick={saveDays} className="glass-btn px-3 py-1 text-sm">Save</button></div>
      </div>
    </div>
  );
}


const KEY_HELP = {
  tavily_api_key: { where: 'app.tavily.com > API Keys (free: 1,000 searches a month, no card needed).', used: 'Searches the web for school websites the free address-guessing didn\'t find (paced to 900 a month).' },
  google_places_api_key: { where: 'Google Cloud > APIs & Services > Credentials. Enable "Places API (New)" in the same project.', used: 'Finds each school\'s official website.' },
  groq_api_key: { where: 'console.groq.com > API Keys (free tier).', used: 'Writes a 2-sentence summary of each school and double-checks replies.' },
  gemini_api_key: { where: 'aistudio.google.com > Get API key (free tier).', used: 'Same as Groq - use one of the two.' },
  hostinger_mail_api_token: { where: 'hPanel > Emails > your mailbox > API access.', used: 'Reads replies from schools.' },
  hostinger_mailbox_resource_id: { where: 'Shown next to the API token in hPanel.', used: 'Which mailbox to read.' },
  hiox_mail_password: { where: 'The password of this mailbox (HIOX India control panel > Email Accounts). It is checked by logging in; nothing is sent.',
    used: 'Lets FlightBridge send outreach from this address and read the replies.', placeholder: 'Mailbox password' },
};
const GROUPS = [
  { title: 'Website search', keys: ['tavily_api_key', 'google_places_api_key'] },
  { title: 'Free AI (optional)', keys: ['groq_api_key', 'gemini_api_key'], provider: true },
];
const HOSTINGER_KEYS = ['hostinger_mail_api_token', 'hostinger_mailbox_resource_id'];
const keyOk = (k) => !!k && (k.from_server_env || k.last_test_ok === true);

// Email: the mailboxes FlightBridge can send from (HIOX India over SMTP/IMAP, Hostinger over its Mail API). Once a mailbox
// is connected (its login test passed) it can be chosen to send outreach; replies are read from the same mailbox.
function Mailboxes({ s, keyMap, saveSettings, onChanged }) {
  const [user, setUser] = useState(s.hiox_mail_user || '');
  const [host, setHost] = useState(s.hiox_mail_host || '');
  useEffect(() => { setUser(s.hiox_mail_user || ''); setHost(s.hiox_mail_host || ''); }, [s.hiox_mail_user, s.hiox_mail_host]);
  const hiox = keyMap.hiox_mail_password;
  const options = [
    { id: 'hiox', address: s.hiox_mail_user, provider: 'HIOX India', ok: keyOk(hiox) },
    { id: 'hostinger', address: 'info@weoneaviation.com', provider: 'Hostinger', ok: HOSTINGER_KEYS.every((n) => keyOk(keyMap[n])) },
  ];
  const anyOk = options.some((o) => o.ok);
  const changed = user.trim().toLowerCase() !== (s.hiox_mail_user || '') || host.trim().toLowerCase() !== (s.hiox_mail_host || '');
  return (
    <div className="glass-card p-4 space-y-4">
      <div>
        <h3 className="font-bold">Email</h3>
        <p className="text-sm text-glass-muted">The mailbox outreach is sent from. Replies are read from the same mailbox.</p>
      </div>
      {anyOk ? (
        <fieldset className="space-y-2">
          <legend className="text-sm font-semibold mb-1">Send emails from</legend>
          {options.map((o) => (
            <label key={o.id} className={`flex items-center gap-3 p-3 rounded-xl border ${o.ok ? 'cursor-pointer' : 'opacity-50 cursor-not-allowed'} ${s.send_from === o.id && o.ok ? 'border-blue-500 bg-blue-50/60' : 'border-gray-200 bg-white/40'}`}>
              <input type="radio" name="fb-send-from" disabled={!o.ok} checked={s.send_from === o.id}
                onChange={() => saveSettings({ send_from: o.id, inbound_source: o.id })} />
              <span className="min-w-0">
                <span className="block font-medium text-sm break-all">{o.address}</span>
                <span className="block text-xs text-glass-muted">{o.provider} · {o.ok ? 'Connected' : 'Not connected'}</span>
              </span>
            </label>
          ))}
          <div className="text-xs text-glass-muted">Nothing is sent while dry run is on, and every email still waits in Approvals.</div>
        </fieldset>
      ) : <div className="text-sm text-orange-700">Connect a mailbox below; then you can choose which email sends.</div>}

      <div className="border-t pt-3" style={{ borderColor: 'rgba(0,0,0,0.08)' }}>
        <div className="font-semibold text-sm">HIOX India mailbox</div>
        <div className="grid gap-2 sm:grid-cols-2 mt-2">
          <label className="text-xs font-medium text-glass-secondary">Email address
            <input className="glass-input w-full px-3 py-2 text-sm mt-1" value={user} autoComplete="off" onChange={(e) => setUser(e.target.value)} />
          </label>
          <label className="text-xs font-medium text-glass-secondary">Mail server
            <input className="glass-input w-full px-3 py-2 text-sm mt-1" value={host} autoComplete="off" spellCheck={false} onChange={(e) => setHost(e.target.value)} />
          </label>
        </div>
        {changed && (
          <button className="glass-btn px-3 py-2 text-sm mt-2"
            onClick={() => saveSettings({ hiox_mail_user: user.trim(), hiox_mail_host: host.trim() })}>Save address and server</button>
        )}
        <div className="text-xs text-glass-muted mt-1">Server for weoneaviation.in mail (from its MX record): host2.dnsinweb.com · IMAP 993 and SMTP 465, both encrypted. After changing the address or server, press Test.</div>
        {hiox && <KeyRow k={hiox} onChanged={onChanged} />}
      </div>

      <div className="border-t pt-3" style={{ borderColor: 'rgba(0,0,0,0.08)' }}>
        <div className="font-semibold text-sm">Hostinger mailbox</div>
        {HOSTINGER_KEYS.map((n) => keyMap[n] && <KeyRow key={n} k={keyMap[n]} onChanged={onChanged} />)}
      </div>
    </div>
  );
}

function KeyRow({ k, onChanged }) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const help = KEY_HELP[k.name] || {};
  const run = async (fn) => { setBusy(true); try { await fn(); onChanged(); } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); } };
  const save = () => run(async () => {
    const r = await call(`/integrations/${k.name}`, { method: 'POST', body: JSON.stringify({ value }) });
    setValue('');
    showToast(r.test_ok ? `Saved and tested: ${r.message}` : `Saved, but the test failed: ${r.message}`, r.test_ok ? 'success' : 'warning');
  });
  const test = () => run(async () => {
    const r = await call(`/integrations/${k.name}/test`, { method: 'POST' });
    showToast(r.message, r.test_ok ? 'success' : 'warning');
  });
  const remove = () => { if (confirm(`Remove the saved ${k.label}?`)) run(() => call(`/integrations/${k.name}`, { method: 'DELETE' })); };
  const status = k.from_server_env ? { text: 'Set on the server', cls: 'bg-blue-100 text-blue-800' }
    : !k.saved ? { text: 'Not set', cls: 'bg-gray-100 text-gray-700' }
    : k.last_test_ok === true ? { text: `Working · …${k.last4}`, cls: 'bg-green-100 text-green-800' }
    : k.last_test_ok === false ? { text: `Problem · …${k.last4}`, cls: 'bg-red-100 text-red-800' }
    : { text: `Saved · …${k.last4}`, cls: 'bg-yellow-100 text-yellow-800' };
  return (
    <div className="py-3 border-t border-gray-100 first:border-t-0">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <div className="font-semibold text-sm">{k.label}</div>
          <div className="text-xs text-glass-muted">{help.used}</div>
        </div>
        <Badge text={status.text} style={status.cls} />
      </div>
      {k.last_test_ok === false && k.last_test_message && <div className="text-xs text-red-700 mt-1">{k.last_test_message}</div>}
      <div className="flex flex-wrap gap-2 mt-2">
        <input type="password" autoComplete="off" spellCheck={false} className="glass-input flex-1 min-w-[220px] px-3 py-2 text-sm"
          placeholder={k.saved ? `Enter a new ${help.placeholder ? 'password' : 'key'} to replace it` : (help.placeholder || 'Paste the key here')} value={value} onChange={(e) => setValue(e.target.value)} />
        <button className="glass-btn px-3 py-2 text-sm" disabled={busy || !value.trim()} onClick={save}>{busy ? 'Checking…' : 'Save & test'}</button>
        {k.saved && <button className="px-3 py-2 text-sm rounded-lg border border-gray-300 bg-white text-gray-700 hover:bg-gray-50" disabled={busy} onClick={test}>Test</button>}
        {k.saved && <button className="px-3 py-2 text-sm rounded-lg border border-red-200 bg-white text-red-600 hover:bg-red-50" disabled={busy} onClick={remove}>Remove</button>}
      </div>
      <div className="text-xs text-glass-muted mt-1">Where to get it: {help.where}</div>
    </div>
  );
}

// Official lists ("upload centre"): regulator lists that a person must download or save, because the regulator's site
// refuses automated downloads. Lists the engine fetches by itself are shown as Automatic; where no list is published
// online, schools are confirmed one by one on the school page.
const UPLOAD_STATUS = { pending: ['Waiting for the engine', 'bg-yellow-100 text-yellow-800'], imported: ['Imported', 'bg-green-100 text-green-800'],
  error: ['Problem', 'bg-red-100 text-red-800'] };
const MODE = { upload: ['Upload needed', 'bg-orange-100 text-orange-800'], optional: ['Optional', 'bg-indigo-100 text-indigo-800'],
  auto: ['Automatic', 'bg-green-100 text-green-800'], none: ['No list online', 'bg-gray-100 text-gray-700'] };
const SAVE_PAGE = 'Save the page: Safari > File > Save As… > Format "Page Source"; Chrome > Ctrl/Cmd+S > "Webpage, HTML Only".';
const OFFICIAL_LISTS = [
  { country: 'US', lists: [
    { kind: 'faa_part141', mode: 'upload', title: 'FAA Part 141 pilot schools', proves: 'US schools on it become Eligible.',
      link: 'https://www.faa.gov/av-info/facility-dashboard', linkText: 'FAA facility dashboard',
      steps: ['Open the FAA facility dashboard.', 'Show the Part 141 pilot schools (use the dashboard’s filter if it has one).',
        'Click Download (bottom bar of the dashboard) > Crosstab > CSV or Excel.', 'Upload the file here. Once a month is enough.'] },
    { kind: 'sevp', mode: 'upload', title: 'SEVP-certified schools (F-1 / M-1 student visas)',
      proves: 'Second way a US school can be Eligible. With both US lists loaded, every US school is decided automatically: on a list → Eligible, on neither → Not Qualified.',
      link: 'https://studyinthestates.dhs.gov/school-search', linkText: 'SEVP school search',
      steps: ['Open the SEVP school search.', 'Click “Download Certified School List” on that page.',
        'Upload the file here as it downloaded (CSV or Excel). Only aviation schools are kept. Once a month is enough.'] },
  ] },
  { country: 'CA', lists: [
    { kind: 'tc_ftu', mode: 'upload', title: 'Transport Canada Flight Training Units', proves: 'Canadian schools on it become Eligible; schools not on it become Not Qualified.',
      link: 'https://wwwapps.tc.gc.ca/Saf-Sec-Sur/2/CAS-SAC/ftaefveas.aspx?lang=eng', linkText: 'Flight Training Units Search',
      steps: ['Open the Flight Training Units Search.', 'Search by “Flight Training Unit” with the name left empty; Region and Province “All records”; Category “Aeroplane”. Click Search.',
        SAVE_PAGE, 'Upload the saved .html file. If the results run over several pages, save and upload each page.'] },
    { kind: 'ircc_dli', mode: 'optional', title: 'IRCC Designated Learning Institutions', proves: 'Second way a Canadian school can be Eligible (study permits).',
      link: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/study-canada/study-permit/prepare/designated-learning-institutions-list.html',
      linkText: 'DLI list', steps: ['Open the DLI list and show a province.', SAVE_PAGE, 'Upload it. Only aviation colleges are kept.'] },
  ] },
  { country: 'AU', lists: [
    { mode: 'auto', title: 'CRICOS providers (student visas)', proves: 'Australian schools on it become Eligible.',
      link: 'https://data.gov.au/data/dataset/cricos', linkText: 'data.gov.au', steps: ['Nothing to do: the engine downloads it every month.'] },
    { kind: 'casa_ato', mode: 'optional', title: 'CASA Part 141 / 142 flight training operators', proves: 'Second way an Australian school can be Eligible.',
      link: 'https://www.casa.gov.au/search-centre/flight-training-operators', linkText: 'Find a flight training operator',
      steps: ['Open CASA’s “Find a flight training operator”.', SAVE_PAGE + ' Do this for each results page.', 'Upload the saved pages.'] },
  ] },
  { country: 'GB', lists: [
    { mode: 'auto', title: 'UK CAA Approved Training Organisations (SD31)', proves: 'UK schools on it are Eligible.',
      link: 'https://www.caa.co.uk/publication/download/13488', linkText: 'CAA SD31 (PDF)', steps: ['Nothing to do: already loaded from the CAA list.'] },
  ] },
  { country: 'NZ', lists: [
    { mode: 'none', title: 'CAA NZ Part 141 / NZQA', proves: 'New Zealand schools are confirmed one by one.',
      link: 'https://www.aviation.govt.nz/', linkText: 'CAA New Zealand',
      steps: ['No downloadable list was found. Check the school on the CAA site, then press “I checked – it’s approved” on the school.'] },
  ] },
  { country: 'Other', lists: [
    { mode: 'none', title: 'Every other country', proves: 'Schools show as “Check needed” once their website is read.',
      steps: ['Check the school on that country’s aviation authority site, then press “I checked – it’s approved” and paste the page link.'] },
  ] },
];
function toBase64(buf) {
  const bytes = new Uint8Array(buf); let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
function ListCard({ l, uploads, onUploaded }) {
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(l.mode === 'upload');
  const [mLabel, mCls] = MODE[l.mode];
  const mine = uploads.filter((u) => u.kind === l.kind).slice(0, 3);
  const upload = async (files) => {
    const list = Array.from(files || []);
    if (!list.length) return;
    setBusy(true);
    let ok = 0;
    for (const file of list) {
      if (file.size > 10 * 1024 * 1024) { showToast(`${file.name}: too large (10 MB at most)`, 'error'); continue; }
      try {
        await call('/register-uploads', { method: 'POST', body: JSON.stringify({ kind: l.kind, filename: file.name, content_b64: toBase64(await file.arrayBuffer()) }) });
        ok += 1;
      } catch (e) { showToast(`${file.name}: ${e.message}`, 'error'); }
    }
    setBusy(false);
    if (ok) { showToast(`${ok} file${ok > 1 ? 's' : ''} uploaded. The engine imports ${ok > 1 ? 'them' : 'it'} on its next cycle (within 15 minutes).`, 'success'); onUploaded(); }
  };
  return (
    <div className="glass-subtle p-3">
      <button type="button" className="w-full flex flex-wrap items-start justify-between gap-2 text-left" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="min-w-0">
          <span className="block font-semibold text-sm">{l.title}</span>
          <span className="block text-xs text-glass-muted">{l.proves}</span>
        </span>
        <Badge text={mLabel} style={mCls} />
      </button>
      {open && (
        <div className="mt-2 space-y-2">
          <ol className="text-sm list-decimal pl-5 space-y-1">{l.steps.map((st, i) => <li key={i}>{st}</li>)}</ol>
          <div className="flex flex-wrap items-center gap-2">
            {l.link && <a className="text-sm font-medium text-blue-600 underline" href={l.link} target="_blank" rel="noreferrer noopener">Open {l.linkText}</a>}
            {l.kind && (
              <label className={`glass-btn inline-flex items-center gap-2 px-4 py-2 text-sm cursor-pointer ${busy ? 'opacity-60 pointer-events-none' : ''}`}>
                {busy ? 'Uploading…' : 'Upload file'}
                <input type="file" multiple accept=".csv,.xlsx,.tsv,.txt,.html,.htm" className="hidden" disabled={busy}
                  onChange={(e) => { upload(e.target.files); e.target.value = ''; }} />
              </label>
            )}
          </div>
          {mine.map((u) => {
            const [label, cls] = UPLOAD_STATUS[u.status] || [u.status, 'bg-gray-100 text-gray-700'];
            const r = u.result || {};
            return (
              <div key={u.id} className="text-xs rounded-lg px-2 py-1.5 bg-white/70">
                <div className="flex flex-wrap justify-between gap-2"><span className="break-all font-medium">{u.filename}</span><Badge text={label} style={cls} /></div>
                <div className="text-glass-muted">{new Date(u.uploaded_at).toLocaleString('en-IN')}{u.uploaded_by ? ` · ${u.uploaded_by}` : ''}</div>
                {u.status === 'imported' && <div>{(r.rows ?? 0).toLocaleString()} schools read · {(r.matched ?? 0).toLocaleString()} matched · {(r.created ?? 0).toLocaleString()} added</div>}
                {u.status === 'error' && <div className="text-red-700">{r.error}</div>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
function OfficialLists() {
  const [uploads, setUploads] = useState([]);
  const load = useCallback(() => call('/register-uploads').then(setUploads, () => {}), []);
  useEffect(() => { load(); const t = setInterval(load, 30000); return () => clearInterval(t); }, [load]);
  return (
    <div className="glass-card p-4 space-y-3">
      <div>
        <h3 className="font-bold">Official lists</h3>
        <p className="text-sm text-glass-muted">The approval lists that make schools Eligible, country by country. Some regulators block automatic downloads, so those lists are downloaded here by hand; the rest run on their own.</p>
      </div>
      {OFFICIAL_LISTS.map((c) => (
        <div key={c.country}>
          <div className="text-[12px] font-semibold uppercase tracking-wider text-glass-secondary mb-1.5">{c.country === 'Other' ? 'Other countries' : countryName(c.country)}</div>
          <div className="space-y-2">{c.lists.map((l) => <ListCard key={l.title} l={l} uploads={uploads} onUploaded={load} />)}</div>
        </div>
      ))}
    </div>
  );
}

function Settings() {
  const [data, setData] = useState(null);
  const [auto, setAuto] = useState(null);
  const [error, setError] = useState(null);
  const load = useCallback(async () => {
    try { setError(null); const [i, a] = await Promise.all([call('/integrations'), call('/automation')]); setData(i); setAuto(a); }
    catch (e) { setError(e.message); }
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 30000); return () => clearInterval(t); }, [load]);
  const saveSettings = async (patch) => {
    try { await call('/integrations-settings', { method: 'POST', body: JSON.stringify({ ...data.settings, ...patch }) }); showToast('Saved', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const runNow = async () => {
    try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify({ kind: 'cycle' }) }); showToast(r.message, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };
  if (error) return <div className="glass-card p-4 text-red-600">{error}{/migration|schema/i.test(error) ? ' — the server is installing the tables; reload in a minute.' : ''}</div>;
  if (!data) return <div className="glass-card p-4 text-glass-muted">Loading settings…</div>;
  const keyMap = Object.fromEntries(data.keys.map((k) => [k.name, k]));
  const last = auto?.runs?.[0];
  const lastErr = last && (last.error || Object.entries({ ...(last.stats || {}), ...((last.stats || {}).research || {}) }).filter(([kk]) => kk.endsWith('_error')).map(([, v]) => v)[0]);
  const s = data.settings;
  return (
    <div className="space-y-4">
      <div className="glass-card p-4">
        <div className="flex flex-wrap justify-between items-start gap-3">
          <div>
            <h3 className="font-bold">Automation</h3>
            <p className="text-sm text-glass-muted">Runs on the CRM server every 15 minutes: finds websites, reads them, scores schools, drafts emails for approval. Nothing is sent from here.</p>
            <p className="text-sm mt-2">
              {data.engine_env_off ? 'Switched off on the server (FLIGHTBRIDGE_ENGINE=off).'
                : !s.engine_in_crm ? 'Paused.'
                : last ? <>Last cycle {new Date(last.started_at).toLocaleString('en-IN')} on {last.runner} — <b>{last.status}</b></> : 'Waiting for the first cycle (starts within 2 minutes of the server starting).'}
            </p>
            {lastErr && <p className="text-xs text-red-700 mt-1">{String(lastErr).includes('GOOGLE_PLACES_API_KEY') ? 'Website search needs the Google Places key below.' : String(lastErr)}</p>}
          </div>
          <div className="flex gap-2 flex-wrap">
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={!!s.engine_in_crm} onChange={(e) => saveSettings({ engine_in_crm: e.target.checked })} /> Run automation</label>
            <button className="glass-btn px-3 py-2 text-sm" onClick={runNow}>Run a cycle now</button>
          </div>
        </div>
        <div className="text-xs text-glass-muted mt-2">Sending: {data.dry_run || !data.outbound_enabled ? 'off on the server (dry run) — emails can be approved but not sent.' : 'enabled on the server; the kill switch still applies.'}</div>
      </div>

      <OfficialLists />

      {GROUPS.map((g) => (
        <div key={g.title} className="glass-card p-4">
          <div className="flex flex-wrap justify-between items-center gap-2 mb-1">
            <h3 className="font-bold">{g.title}</h3>
            {g.provider && (
              <label className="text-sm flex items-center gap-2">Use
                <select className="glass-input px-2 py-1 text-sm" value={s.llm_provider} onChange={(e) => saveSettings({ llm_provider: e.target.value })}>
                  <option value="none">No AI (keywords only)</option><option value="groq">Groq</option><option value="gemini">Gemini</option>
                </select>
              </label>
            )}
          </div>
          {g.keys.map((name) => keyMap[name] && <KeyRow key={name} k={keyMap[name]} onChanged={load} />)}
        </div>
      ))}
      <Mailboxes s={s} keyMap={keyMap} saveSettings={saveSettings} onChanged={load} />
      <p className="text-xs text-glass-muted">Keys are encrypted before they are stored and are never shown again — only the last 4 characters. Only admins can see this page.</p>
    </div>
  );
}

export default function FlightBridge() {
  const [view, setView] = useState('detector');
  const [me, setMe] = useState(null);
  const [summary, setSummary] = useState(null);
  const [tasks, setTasks] = useState([]);
  const [statusFilter, setStatusFilter] = useState('open');
  const [outbound, setOutbound] = useState([]);
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState(null);
  const [supp, setSupp] = useState({ scope: 'contact', value: '', reason: 'manual' });

  const load = useCallback(async () => {
    try {
      setError(null);
      const [m, s, t, o] = await Promise.all([call('/me'), call('/summary'), call(`/approvals?status=${statusFilter}`), call('/outbound?limit=50')]);
      setMe(m); setSummary(s); setTasks(t); setOutbound(o);
    } catch (e) { setError(e.message); }
  }, [statusFilter]);
  useEffect(() => { load(); }, [load]);

  const toggleKill = async () => {
    const engaged = summary?.kill_switches?.outbound_kill_switch !== false;
    if (engaged && !confirm('Release the outbound kill switch? Nothing will send unless DRY_RUN=false and OUTBOUND_ENABLED=true are also set on the server.')) return;
    try { await call('/kill-switch', { method: 'POST', body: JSON.stringify({ engaged: !engaged }) }); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };

  const recheck = async (id) => {
    try { await call(`/outbound/${id}/recheck`, { method: 'POST' }); showToast('Queued for re-check', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };

  const addSuppression = async () => {
    const key = supp.scope === 'contact' ? 'email' : supp.scope === 'organisation' ? 'org_id' : 'domain';
    try {
      await call('/suppressions', { method: 'POST', body: JSON.stringify({ scope: supp.scope, [key]: supp.value, reason: supp.reason }) });
      showToast('Suppressed', 'success'); setSupp({ ...supp, value: '' }); load();
    } catch (e) { showToast(e.message, 'error'); }
  };

  if (error) {
    return (
      <div className="glass-card p-6 space-y-3">
        <p className="text-red-600">FlightBridge unavailable: {error}</p>
        {/schema not installed/i.test(error) && <p className="text-sm text-glass-muted">The server is installing the FlightBridge tables. Reload in a minute.</p>}
        <button className="glass-btn px-3 py-2 text-sm" onClick={load}>Retry</button>
      </div>
    );
  }
  if (selected) return <ApprovalDetail id={selected} onBack={() => setSelected(null)} onDone={() => { setSelected(null); load(); }} />;
  const killEngaged = summary?.kill_switches?.outbound_kill_switch !== false;
  const isAdmin = me?.role === 'admin';
  const openApprovals = summary?.approvals?.open || 0;
  const needLook = (summary?.outbound?.blocked || 0) + (summary?.outbound?.needs_review || 0);
  const GROUPS = [
    { label: 'Find schools', items: [
      { id: 'detector', label: 'School Detector', hint: 'Live world search on the 3D Earth', icon: 'globe' },
      { id: 'schools', label: 'Schools', hint: 'Every school found, by country', icon: 'list' },
      { id: 'areas', label: 'Areas', hint: 'Cities and regions to search', icon: 'map' },
    ] },
    { label: 'Outreach', items: [
      { id: 'queue', label: 'Approval queue', hint: 'Emails waiting for your OK', icon: 'check', count: openApprovals },
      { id: 'inbox', label: 'Inbox', hint: 'Replies from schools', icon: 'inbox' },
      isAdmin && { id: 'templates', label: 'Email templates', hint: 'Wording of each email', icon: 'mail' },
      { id: 'outbound', label: 'Outbound & checks', hint: 'Every email and its safety checks', icon: 'outbox', count: needLook },
    ].filter(Boolean) },
    { label: 'Results', items: [
      { id: 'metrics', label: 'Metrics', hint: 'Replies, bounces, approvals', icon: 'chart' },
    ] },
    { label: 'Setup', items: [
      { id: 'automation', label: 'Automation', hint: 'What runs on its own', icon: 'zap' },
      isAdmin && { id: 'suppression', label: 'Suppression', hint: 'Never contact these', icon: 'ban' },
      isAdmin && { id: 'team', label: 'Team', hint: 'Who can use FlightBridge', icon: 'team' },
      isAdmin && { id: 'settings', label: 'Settings', hint: 'Keys and limits', icon: 'settings' },
    ].filter(Boolean) },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap justify-between items-center gap-2">
        <h2 className="text-xl font-bold text-glass-primary">FlightBridge AI</h2>
        <div className="flex flex-wrap gap-2">
        {isAdmin && <button onClick={toggleKill} className="glass-btn px-3 py-2 text-sm inline-flex items-center gap-2 min-h-[40px]" style={{ background: killEngaged ? '#FF3B30' : '#FF9500' }}
          title={killEngaged ? 'Nothing can be sent. Click to release.' : 'Sending is possible once the server also allows it.'}>
          <Icon name={killEngaged ? 'shield' : 'alert'} size={16} />
          {killEngaged ? 'Sending blocked (kill switch on)' : 'Kill switch released'}
        </button>}
        </div>
      </div>

      {summary && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Schools</div><div className="text-2xl font-bold">{Object.values(summary.organisations).reduce((a, b) => a + b, 0)}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Awaiting approval</div><div className="text-2xl font-bold">{summary.approvals.open || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Test emails (not sent)</div><div className="text-2xl font-bold">{summary.outbound.dry_run_rendered || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Need a look</div><div className="text-2xl font-bold">{(summary.outbound.blocked || 0) + (summary.outbound.needs_review || 0)}</div></div>
        </div>
      )}

      <SectionNav groups={GROUPS} value={view} onChange={(v) => { setView(v); window.scrollTo({ top: 0, behavior: 'smooth' }); }} />

      {view === 'detector' && <FlightBridgeDetector />}

      {view === 'areas' && <Areas isAdmin={isAdmin} />}
      {view === 'automation' && <Automation isAdmin={isAdmin} />}
      {view === 'team' && isAdmin && <Team meId={me?.id} />}
      {view === 'templates' && isAdmin && <Templates />}
      {view === 'inbox' && <Inbox />}
      {view === 'metrics' && <Metrics />}
      {view === 'settings' && isAdmin && <Settings />}
      {view === 'schools' && <FlightBridgeSchools />}

      {view === 'queue' && (
        <div className="space-y-2">
          <select className="glass-input px-2 py-1 text-sm" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
            {['open', 'approved', 'edited_approved', 'rejected', 'more_research', 'resolved'].map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
          {tasks.map((t) => (
            <button key={t.id} onClick={() => setSelected(t.id)} className="glass-card p-3 w-full text-left hover:shadow-md">
              <div className="flex justify-between"><div className="font-semibold text-glass-primary">{t.org_name} <span className="text-xs text-glass-muted">({t.country})</span></div><Badge text={t.risk} style={RISK_STYLE[t.risk]} /></div>
              <div className="text-sm text-glass-secondary">{t.subject}</div>
              <div className="text-xs text-glass-muted">{t.kind} · {t.email} · {new Date(t.created_at).toLocaleString()} · {t.escalation_reason}</div>
            </button>
          ))}
          {tasks.length === 0 && <div className="text-center text-glass-muted py-10">No tasks with status “{statusFilter}”.</div>}
        </div>
      )}

      {view === 'outbound' && (
        <div className="space-y-2">
          {outbound.map((m) => (
            <div key={m.id} className="glass-card p-3">
              <div className="flex justify-between"><div className="font-semibold">{m.org_name} · {m.email}</div><Badge text={m.status} style={OUT_STYLE[m.status]} /></div>
              <div className="text-sm text-glass-secondary">{m.subject} <span className="text-xs text-glass-muted">({m.ref_token})</span></div>
              <div className="text-xs mt-1">Jurisdiction: <b>{m.jurisdiction || '—'}</b> · Content: <b>{m.content || '—'}</b></div>
              <Reasons list={[...(m.jurisdiction_reasons || []), ...(m.content_reasons || [])]} />
              {m.status === 'needs_review' && <button onClick={() => recheck(m.id)} className="glass-btn px-3 py-1 text-xs mt-2">Re-run checks</button>}
            </div>
          ))}
          {outbound.length === 0 && <div className="text-center text-glass-muted py-10">No outbound messages yet.</div>}
        </div>
      )}

      {view === 'suppression' && isAdmin && (
        <div className="glass-card p-4 space-y-2">
          <div className="text-sm text-glass-secondary">Suppression is permanent. Domain scope cannot be used for shared providers such as gmail.com.</div>
          <div className="flex flex-wrap gap-2">
            <select className="glass-input px-2 py-1 text-sm" value={supp.scope} onChange={(e) => setSupp({ ...supp, scope: e.target.value })}>
              <option value="contact">Contact (email)</option><option value="organisation">Organisation (id)</option><option value="domain">Domain</option>
            </select>
            <input className="glass-input px-2 py-1 text-sm flex-1" placeholder={supp.scope === 'contact' ? 'email@school.example' : supp.scope === 'organisation' ? 'organisation id' : 'school.example'} value={supp.value} onChange={(e) => setSupp({ ...supp, value: e.target.value })} />
            <select className="glass-input px-2 py-1 text-sm" value={supp.reason} onChange={(e) => setSupp({ ...supp, reason: e.target.value })}>
              {['manual', 'unsubscribe', 'rejection', 'complaint', 'hard_bounce', 'legal'].map((r) => <option key={r} value={r}>{r}</option>)}
            </select>
            <button disabled={!supp.value} onClick={addSuppression} className="glass-btn px-3 py-1 text-sm" style={{ background: '#FF3B30' }}>Suppress</button>
          </div>
          <div className="text-xs text-glass-muted">{summary?.suppressions ?? 0} suppression records.</div>
        </div>
      )}
    </div>
  );
}
