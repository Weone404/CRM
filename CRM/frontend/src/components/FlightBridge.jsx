import { useState, useEffect, useCallback } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';

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
            <div key={i} className="text-sm mb-3 border-l-2 pl-3" style={{ borderColor: m.direction === 'inbound' ? '#6366f1' : '#22c55e' }}>
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
            {!edit && <button disabled={busy} onClick={() => decide('approve')} className="glass-btn px-4 py-2" style={{ background: '#22c55e' }}>✓ Approve</button>}
            {edit && <button disabled={busy} onClick={() => decide('edit_approve')} className="glass-btn px-4 py-2" style={{ background: '#16a34a' }}>✓ Approve edited version</button>}
            <button disabled={busy} onClick={() => decide('more_research')} className="glass-btn px-4 py-2 text-sm">Request more research</button>
            <button disabled={busy} onClick={() => decide('resolve')} className="glass-btn px-4 py-2 text-sm">Mark resolved</button>
            <button disabled={busy} onClick={() => decide('reject')} className="glass-btn px-4 py-2 text-sm" style={{ background: '#ef4444' }}>Reject</button>
          </div>
          <div className="text-xs text-glass-muted">Approving does not send. It queues the email for automatic jurisdiction and content checks; while DRY_RUN is on it is only rendered.</div>
        </div>
      ) : <div className="text-sm text-glass-secondary">Decided: <b>{t.status}</b> {t.decided_at && `on ${new Date(t.decided_at).toLocaleString()}`}</div>}
    </div>
  );
}

export default function FlightBridge() {
  const [view, setView] = useState('queue');
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
      const [s, t, o] = await Promise.all([call('/summary'), call(`/approvals?status=${statusFilter}`), call('/outbound?limit=50')]);
      setSummary(s); setTasks(t); setOutbound(o);
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

  if (error) return <div className="glass-card p-6 text-red-600">FlightBridge unavailable: {error}</div>;
  if (selected) return <ApprovalDetail id={selected} onBack={() => setSelected(null)} onDone={() => { setSelected(null); load(); }} />;
  const killEngaged = summary?.kill_switches?.outbound_kill_switch !== false;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap justify-between items-center gap-2">
        <h2 className="text-xl font-bold text-glass-primary">Partnerships · FlightBridge</h2>
        <button onClick={toggleKill} className="glass-btn px-3 py-2 text-sm" style={{ background: killEngaged ? '#ef4444' : '#f59e0b' }}>
          {killEngaged ? '⛔ Outbound kill switch: ENGAGED' : '⚠️ Kill switch released'}
        </button>
      </div>

      {summary && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Schools</div><div className="text-2xl font-bold">{Object.values(summary.organisations).reduce((a, b) => a + b, 0)}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Awaiting approval</div><div className="text-2xl font-bold">{summary.approvals.open || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Dry-run rendered</div><div className="text-2xl font-bold">{summary.outbound.dry_run_rendered || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Blocked / review</div><div className="text-2xl font-bold">{(summary.outbound.blocked || 0) + (summary.outbound.needs_review || 0)}</div></div>
        </div>
      )}

      <div className="flex gap-2">
        {['queue', 'outbound', 'suppression'].map((v) => (
          <button key={v} onClick={() => setView(v)} className={`glass-tab-btn ${view === v ? 'active' : ''}`}>
            {v === 'queue' ? 'Approval queue' : v === 'outbound' ? 'Outbound & checks' : 'Suppression'}
          </button>
        ))}
      </div>

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

      {view === 'suppression' && (
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
            <button disabled={!supp.value} onClick={addSuppression} className="glass-btn px-3 py-1 text-sm" style={{ background: '#ef4444' }}>Suppress</button>
          </div>
          <div className="text-xs text-glass-muted">{summary?.suppressions ?? 0} suppression records.</div>
        </div>
      )}
    </div>
  );
}
