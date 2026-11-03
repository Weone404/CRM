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
// The full standalone workspace (schools by country/region, automation, team). Same login and data as the CRM.
const FLIGHTBRIDGE_APP_URL = import.meta.env.VITE_FLIGHTBRIDGE_URL || 'https://flying.weoneaviation.in';

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

  return (
    <div className="space-y-4">
      <div className="glass-card p-4 space-y-3">
        <div className="flex flex-wrap gap-2 items-center justify-between">
          <div className="font-semibold">Paste your outreach email</div>
          <select id="fb-tpl-kind" className="glass-input px-2 py-1 text-sm" value={kind} onChange={(e) => { setKind(e.target.value); setResult(null); }}>
            {Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </div>
        <input id="fb-tpl-subject" className="glass-input w-full px-3 py-2" maxLength={150} placeholder="Subject, e.g. Student referral partnership with {{school_name}}" value={subject} onChange={(e) => setSubject(e.target.value)} />
        <textarea id="fb-tpl-body" className="glass-input w-full px-3 py-2 font-mono text-sm" rows={12} placeholder={'Paste the email body here.\n\nYou may use {{school_name}}, {{city}} and {{country}}.\nDo not add an unsubscribe line or signature divider: the legal footer is added automatically.'} value={body} onChange={(e) => setBody(e.target.value)} />
        <div className="flex flex-wrap gap-2 items-center">
          <button disabled={busy || !subject.trim() || body.trim().length < 20} onClick={save} className="glass-btn px-4 py-2">Save and check</button>
          <span className="text-xs text-glass-muted">Saving creates a new version. Only an approved version is used for drafts.</span>
        </div>
        {result && (
          <div className={`p-3 rounded-lg text-sm ${result.validation.ok ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'}`}>
            {result.validation.ok ? <div>Looks good. Version {result.version} is ready to approve.</div> : <div>Version {result.version} cannot be approved yet:</div>}
            <Reasons list={result.validation.errors} />
            {result.validation.warnings.length > 0 && <div className="mt-1 text-orange-700">{result.validation.warnings.join(' ')}</div>}
            {result.validation.ok && <button onClick={() => approve(result.id)} className="glass-btn px-3 py-1 text-xs mt-2" style={{ background: '#22c55e' }}>Approve version {result.version}</button>}
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
  google_places_api_key: { where: 'Google Cloud > APIs & Services > Credentials. Enable "Places API (New)" in the same project.', used: 'Finds each school\'s official website.' },
  groq_api_key: { where: 'console.groq.com > API Keys (free tier).', used: 'Writes a 2-sentence summary of each school and double-checks replies.' },
  gemini_api_key: { where: 'aistudio.google.com > Get API key (free tier).', used: 'Same as Groq - use one of the two.' },
  hostinger_mail_api_token: { where: 'hPanel > Emails > your mailbox > API access.', used: 'Reads replies from schools.' },
  hostinger_mailbox_resource_id: { where: 'Shown next to the API token in hPanel.', used: 'Which mailbox to read.' },
};
const GROUPS = [
  { title: 'Website search', keys: ['google_places_api_key'] },
  { title: 'Free AI (optional)', keys: ['groq_api_key', 'gemini_api_key'], provider: true },
  { title: 'Mailbox (replies)', keys: ['hostinger_mail_api_token', 'hostinger_mailbox_resource_id'], inbound: true },
];

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
          placeholder={k.saved ? 'Paste a new key to replace it' : 'Paste the key here'} value={value} onChange={(e) => setValue(e.target.value)} />
        <button className="glass-btn px-3 py-2 text-sm" disabled={busy || !value.trim()} onClick={save}>{busy ? 'Checking…' : 'Save & test'}</button>
        {k.saved && <button className="px-3 py-2 text-sm rounded-lg border border-gray-300 bg-white text-gray-700 hover:bg-gray-50" disabled={busy} onClick={test}>Test</button>}
        {k.saved && <button className="px-3 py-2 text-sm rounded-lg border border-red-200 bg-white text-red-600 hover:bg-red-50" disabled={busy} onClick={remove}>Remove</button>}
      </div>
      <div className="text-xs text-glass-muted mt-1">Where to get it: {help.where}</div>
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
  if (error) return <div className="glass-card p-4 text-red-600">{error}{/migration|schema/i.test(error) ? ' — run FLIGHTBRIDGE_INSTALL.sql / migration 040 in Supabase.' : ''}</div>;
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
            {g.inbound && (
              <label className="text-sm flex items-center gap-2"><input type="checkbox" checked={s.inbound_source === 'hostinger'} onChange={(e) => saveSettings({ inbound_source: e.target.checked ? 'hostinger' : 'none' })} /> Read replies from this mailbox</label>
            )}
          </div>
          {g.keys.map((name) => keyMap[name] && <KeyRow key={name} k={keyMap[name]} onChanged={load} />)}
        </div>
      ))}
      <p className="text-xs text-glass-muted">Keys are encrypted before they are stored and are never shown again — only the last 4 characters. Only admins can see this page.</p>
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

  const openApp = (
    <a href={FLIGHTBRIDGE_APP_URL} target="_blank" rel="noopener noreferrer" className="glass-btn px-3 py-2 text-sm">
      Open FlightBridge AI
    </a>
  );
  if (error) {
    return (
      <div className="glass-card p-6 space-y-3">
        <p className="text-red-600">FlightBridge unavailable: {error}</p>
        {/schema not installed/i.test(error) && <p className="text-sm text-glass-muted">Run migrations 037, 038 and 039 in the Supabase SQL editor, then reload.</p>}
        {openApp}
      </div>
    );
  }
  if (selected) return <ApprovalDetail id={selected} onBack={() => setSelected(null)} onDone={() => { setSelected(null); load(); }} />;
  const killEngaged = summary?.kill_switches?.outbound_kill_switch !== false;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap justify-between items-center gap-2">
        <h2 className="text-xl font-bold text-glass-primary">FlightBridge AI</h2>
        <div className="flex flex-wrap gap-2">
        {openApp}
        <button onClick={toggleKill} className="glass-btn px-3 py-2 text-sm" style={{ background: killEngaged ? '#ef4444' : '#f59e0b' }}>
          {killEngaged ? '⛔ Outbound kill switch: ENGAGED' : '⚠️ Kill switch released'}
        </button>
        </div>
      </div>

      {summary && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Schools</div><div className="text-2xl font-bold">{Object.values(summary.organisations).reduce((a, b) => a + b, 0)}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Awaiting approval</div><div className="text-2xl font-bold">{summary.approvals.open || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Dry-run rendered</div><div className="text-2xl font-bold">{summary.outbound.dry_run_rendered || 0}</div></div>
          <div className="glass-card p-3"><div className="text-xs text-glass-muted">Blocked / review</div><div className="text-2xl font-bold">{(summary.outbound.blocked || 0) + (summary.outbound.needs_review || 0)}</div></div>
        </div>
      )}

      <div className="flex gap-2 overflow-x-auto whitespace-nowrap">
        {[['queue', 'Approval queue'], ['templates', 'Email templates'], ['inbox', 'Inbox'], ['outbound', 'Outbound & checks'],
          ['metrics', 'Metrics'], ['suppression', 'Suppression'], ['settings', 'Settings']].map(([v, label]) => (
          <button key={v} onClick={() => setView(v)} className={`glass-tab-btn ${view === v ? 'active' : ''}`}>{label}</button>
        ))}
      </div>

      {view === 'templates' && <Templates />}
      {view === 'inbox' && <Inbox />}
      {view === 'metrics' && <Metrics />}
      {view === 'settings' && <Settings />}

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
