import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { inr, diffRows, STATUS_STYLE, ageText, plain, FIELD_LABELS } from '../utils/amazon';

// Decisions inbox, Live Claude chat, Morning summary and Mac connection for CRM > Amazon.
// Built for the shop owner: one card per change with the product photo, old vs new, why, and three buttons.

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function edge(name, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body) });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
const Chip = ({ children, style }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: 'rgba(118,118,128,0.14)', color: '#3C3C43', ...style }}>{children}</span>
);
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const RED = { background: 'rgba(255,59,48,0.12)', color: '#C4261D' };
const GREEN = { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' };
const AMBER = { background: 'rgba(255,149,0,0.14)', color: '#B25E00' };
const DONE = { live: ['Live on Amazon.', 'success'], executing: ['Sent. Amazon is applying it.', 'success'], skipped: ['Already being sent.', 'success'],
  failed: ['Amazon said no. See the card for the reason.', 'error'], stale: ['This product changed on Amazon meanwhile. Nothing sent.', 'error'],
  needs_manual: ['Sent. One step is left for you (see the card).', 'success'] };
const send = async (id) => {
  const r = await edge('amazon-execute', { id }).catch((e) => ({ status: 'error', detail: e.message }));
  const [m, t] = DONE[r.status] || [r.detail || 'Sent. It will go live within 5 minutes.', r.status === 'error' ? 'error' : 'success'];
  return { status: r.status, m, t };
};
const istHour = () => Number(new Intl.DateTimeFormat('en-GB', { hour: 'numeric', hour12: false, timeZone: 'Asia/Kolkata' }).format(new Date()));
const shipBy = (d) => (d ? new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' }).format(new Date(d)) : '');

// ---------------------------------------------------------------- Decisions
const WHO = { claude: 'Suggested by Claude', system: 'Suggested by the CRM', user: 'Made by you or your team' };
const REASONS = ['Wrong information', "Don't like the wording", 'Price not right', 'Not now'];
const INLINE = ['title', 'bullets', 'description', 'backend_terms', 'price', 'mrp', 'quantity', 'handling_days'];

function EditBox({ c, onDone, onCancel }) {
  const [v, setV] = useState(() => Object.fromEntries(Object.entries(c.after).filter(([k]) => INLINE.includes(k))
    .map(([k, x]) => [k, k === 'bullets' ? (x || []).join('\n') : x ?? ''])));
  const [busy, setBusy] = useState(false);
  const save = async (second = false) => {
    const after = {};
    Object.entries(v).forEach(([k, x]) => {
      if (k === 'bullets') after[k] = String(x).split('\n').map((s) => s.trim()).filter(Boolean);
      else if (['price', 'mrp', 'quantity', 'handling_days'].includes(k)) after[k] = Number(x);
      else after[k] = String(x).trim();
    });
    Object.entries(c.after).forEach(([k, x]) => { if (!INLINE.includes(k)) after[k] = x; });
    setBusy(true);
    try {
      const r = await rpc('api_amz_revise', { p_id: c.id, p_after: after, p_second_confirm: second });
      if (r.status === 'blocked') showToast(`Not allowed: ${(r.guard_result?.blockers || []).map((b) => b.message).join(' ')}`, 'error');
      else if (r.status === 'confirm') {
        setBusy(false);
        if (await confirmDialog((r.guard_result?.confirms || []).map((x) => x.message).join('\n'), { title: 'Please check', confirmText: 'Yes, approve', danger: true })) await save(true);
        return;
      } else if (r.status === 'stale') showToast('This product changed on Amazon meanwhile. Nothing sent.', 'error');
      else { const s = await send(r.id); showToast(s.m, s.t); onDone(); }
    } catch (e) { showToast(e.message, 'error'); }
    setBusy(false);
  };
  return (
    <div className="mt-3 space-y-3 rounded-2xl p-3" style={{ background: 'rgba(0,122,255,0.06)' }}>
      {Object.keys(v).map((k) => (
        <label key={k} className="block text-sm">
          <span className="font-semibold">{FIELD_LABELS[k] || k}</span>
          {k === 'handling_days' ? (
            <select aria-label={FIELD_LABELS[k]} className="glass-input w-full px-3 py-2 mt-1" value={v[k]} onChange={(e) => setV((s) => ({ ...s, [k]: e.target.value }))}>
              <option value="0">Same day</option><option value="1">Next day</option><option value="2">2 days</option></select>
          ) : ['price', 'mrp', 'quantity'].includes(k) ? (
            <input aria-label={FIELD_LABELS[k]} type="number" className="glass-input w-full px-3 py-2 mt-1" value={v[k]} onChange={(e) => setV((s) => ({ ...s, [k]: e.target.value }))} />
          ) : (
            <textarea aria-label={FIELD_LABELS[k]} rows={k === 'title' ? 2 : 5} className="glass-input w-full px-3 py-2 mt-1 text-sm" value={v[k]} onChange={(e) => setV((s) => ({ ...s, [k]: e.target.value }))} />
          )}
          {k === 'bullets' && <span className="text-[11px] text-glass-muted">One key point per line.</span>}
        </label>
      ))}
      {Object.keys(c.after).some((k) => !INLINE.includes(k)) && <div className="text-xs text-glass-muted">Photos and details are kept as suggested. To change them, open the product.</div>}
      <div className="flex gap-2">
        <button type="button" className="glass-btn px-4 py-2 text-sm" disabled={busy} onClick={() => save(false)}>{busy ? 'Sending…' : 'Approve my version'}</button>
        <button type="button" className="glass-btn-ghost px-3 py-2 text-sm" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

function RejectBox({ c, onDone, onCancel }) {
  const [txt, setTxt] = useState('');
  const go = async (reason) => {
    try { await rpc('api_amz_reject', { p_id: c.id, p_reason: reason }); showToast('Rejected. Claude will learn from your reason.', 'success'); onDone(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <div className="mt-3 rounded-2xl p-3 space-y-2" style={{ background: 'rgba(255,59,48,0.06)' }}>
      <div className="text-sm font-semibold">Why not?</div>
      <div className="flex flex-wrap gap-2">{REASONS.map((r) => <button key={r} type="button" className="glass-btn-ghost px-3 py-1.5 text-sm" onClick={() => go(r)}>{r}</button>)}</div>
      <div className="flex gap-2">
        <input aria-label="Other reason" className="glass-input flex-1 px-3 py-2 text-sm" placeholder="Or write your own reason" value={txt} onChange={(e) => setTxt(e.target.value)} />
        <button type="button" className="glass-btn px-3 py-2 text-sm" disabled={txt.trim().length < 3} onClick={() => go(txt.trim())}>Reject</button>
      </div>
      <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={onCancel}>Cancel</button>
    </div>
  );
}

function DecisionCard({ c, access, busy, onApprove, onChanged, openProduct }) {
  const [mode, setMode] = useState('');
  const st = STATUS_STYLE[c.status] || {};
  const rows = diffRows(c.before, c.after);
  const act = async (fn, msg) => { try { await rpc(fn, { p_id: c.id }); showToast(msg, 'success'); onChanged(); } catch (e) { showToast(e.message, 'error'); } };
  const pending = c.status === 'pending';
  return (
    <div className="glass-card p-4 text-sm" data-change={c.id}>
      <div className="flex gap-3 items-start">
        <button type="button" onClick={() => c.sku && openProduct(c.sku)} className="w-14 h-14 rounded-xl bg-white grid place-items-center overflow-hidden shrink-0" aria-label="Open product">
          {c.photo ? <img src={c.photo} alt="" className="w-full h-full object-contain" /> : <Icon name="image" size={20} />}
        </button>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="font-semibold text-glass-primary">{c.summary || 'Change'}</div>
            <Chip style={{ background: st.bg, color: st.fg }}>{st.label || c.status}</Chip>
          </div>
          <div className="text-xs text-glass-secondary line-clamp-1">{c.product || c.asin || 'Whole account'}</div>
          <div className="text-[11px] text-glass-muted">{WHO[c.created_by_type] || ''} · {ageText(c.created_at)}</div>
        </div>
      </div>
      {c.reason && <div className="mt-3 text-sm rounded-xl px-3 py-2" style={{ background: 'rgba(175,82,222,0.08)' }}><b>Why: </b>{c.reason}</div>}
      <div className="mt-3 space-y-2">
        {rows.map((r) => (
          <div key={r.key} className="text-xs">
            <div className="text-glass-muted mb-1">{r.label}</div>
            <div className="grid sm:grid-cols-2 gap-1.5">
              <div className="rounded-lg px-2 py-1.5 whitespace-pre-wrap line-through decoration-1" style={{ background: 'rgba(255,59,48,0.06)', color: '#8E8E93' }}><span className="sr-only">Now: </span>{r.before}</div>
              <div className="rounded-lg px-2 py-1.5 whitespace-pre-wrap font-medium" style={{ background: 'rgba(52,199,89,0.10)' }}><span className="sr-only">New: </span>{r.after}</div>
            </div>
          </div>
        ))}
      </div>
      {(c.guard_result?.blockers || []).length > 0 && pending && <div className="mt-2 text-xs" style={{ color: '#C4261D' }}>Can't approve: {c.guard_result.blockers.map((b) => b.message).join(' ')}</div>}
      {(c.guard_result?.warnings || []).length > 0 && pending && <div className="mt-2 text-xs" style={{ color: '#B25E00' }}>Heads up: {c.guard_result.warnings.map((b) => b.message).join(' ')}</div>}
      {c.error && <div className="mt-2 text-xs" style={{ color: c.status === 'needs_manual' ? '#7A2EA8' : '#C4261D' }}>{c.status === 'failed' ? 'Amazon said: ' : ''}{c.error}</div>}
      {c.reject_reason && !pending && <div className="mt-2 text-xs text-glass-muted">Reason: {c.reject_reason}</div>}
      {mode === 'edit' && <EditBox c={c} onDone={() => { setMode(''); onChanged(); }} onCancel={() => setMode('')} />}
      {mode === 'reject' && <RejectBox c={c} onDone={() => { setMode(''); onChanged(); }} onCancel={() => setMode('')} />}
      {!mode && (
        <div className="flex flex-wrap gap-2 mt-3">
          {pending && access.can_approve && <>
            <button type="button" disabled={!!busy || !c.guard_result?.ok} onClick={() => onApprove(c)} className="px-5 py-2 rounded-xl text-sm font-semibold text-white" style={{ background: c.guard_result?.ok ? '#34C759' : '#A1A1A6' }}>{busy === c.id ? 'Sending…' : 'Approve'}</button>
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={() => setMode('edit')}>Change</button>
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" style={{ color: '#C4261D' }} onClick={() => setMode('reject')}>Reject</button>
          </>}
          {pending && !access.can_approve && <span className="text-xs text-glass-muted">Waiting for Admin to approve.</span>}
          {['failed', 'stale'].includes(c.status) && <button type="button" className="glass-btn-ghost px-3 py-2 text-sm" onClick={() => act('api_amz_resubmit', 'Checked again and back in Decisions')}>Try again</button>}
          {c.status === 'needs_manual' && access.can_approve && <button type="button" className="glass-btn-ghost px-3 py-2 text-sm" onClick={() => act('api_amz_manual_done', 'Marked done')}>I did it in Seller Central</button>}
          {['live', 'needs_manual'].includes(c.status) && c.kind !== 'ads_budget' && <button type="button" className="glass-btn-ghost px-3 py-2 text-sm" onClick={() => act('api_amz_rollback', 'Undo prepared. Approve it to undo.')}>Undo</button>}
        </div>
      )}
    </div>
  );
}

export function Decisions({ access, onChange, openProduct, askClaude }) {
  const [status, setStatus] = useState('open');
  const [rows, setRows] = useState(null);
  const [findings, setFindings] = useState([]);
  const [busy, setBusy] = useState('');
  const [showFix, setShowFix] = useState(false);
  const load = useCallback(async () => {
    try {
      const [d, f] = await Promise.all([rpc('api_amz_decisions', { p_status: status }), rpc('api_amz_findings', { p_status: 'open' })]);
      setRows(d); setFindings(f || []);
    } catch (e) { showToast(e.message, 'error'); }
  }, [status]);
  useEffect(() => { load(); }, [load]);
  const refresh = () => { load(); onChange?.(); };
  const approve = async (c) => {
    let second = false;
    if (c.needs_second_confirm) {
      const msg = `${(c.guard_result.confirms || []).map((x) => x.message).join(' ')}\n\n${diffRows(c.before, c.after).map((r) => `${r.label}: ${r.before} → ${r.after}`).join('\n')}`;
      if (!(await confirmDialog(msg, { title: 'Please check again', confirmText: 'Yes, approve', danger: true }))) return;
      second = true;
    }
    setBusy(c.id);
    try {
      const a = await rpc('api_amz_approve', { p_id: c.id, p_second_confirm: second });
      if (a?.status === 'stale') showToast('This product changed on Amazon after the suggestion. Marked out of date.', 'error');
      else { const s = await send(c.id); showToast(s.m, s.t); }
    } catch (e) { showToast(e.message, 'error'); }
    setBusy(''); refresh();
  };
  const pend = (rows || []).filter((c) => c.status === 'pending');
  const safe = pend.filter((c) => c.guard_result?.ok && !c.needs_second_confirm);
  const warned = safe.filter((c) => (c.guard_result?.warnings || []).length).length;
  const approveAll = async () => {
    if (!(await confirmDialog(`Approve ${safe.length} safe changes?`, { message: `Only changes that pass every check. Each one goes live on Amazon.${warned ? ` ${warned} of them have a heads-up (shown on the card) — please read before approving.` : ''}`, confirmText: 'Approve all' }))) return;
    setBusy('all');
    let ok = 0, bad = 0;
    for (let i = 0; i < safe.length; i++) {
      showToast(`Sending ${i + 1} of ${safe.length}…`, 'info');
      try {
        const a = await rpc('api_amz_approve', { p_id: safe[i].id, p_second_confirm: false });
        if (a?.status === 'stale') { bad++; continue; }
        const s = await send(safe[i].id); if (s.t === 'error') bad++; else ok++;
      } catch { bad++; }
    }
    setBusy(''); showToast(`${ok} sent${bad ? `, ${bad} need a look` : ''}.`, bad ? 'error' : 'success'); refresh();
  };
  const withDraft = new Set(pend.map((c) => c.sku));
  const fixes = findings.filter((f) => !f.sku || !withDraft.has(f.sku));
  return (
    <div className="space-y-3">
      <div className="glass-card p-3 text-xs text-glass-secondary">Nothing changes on Amazon until you approve it. Every live change can be undone.</div>
      <div className="flex flex-wrap justify-between gap-2 items-center">
        <div className="flex gap-1 p-1 rounded-xl" role="group" aria-label="Show" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[['open', `Waiting${pend.length ? ` (${pend.length})` : ''}`], ['done', 'Done'], ['rejected', 'Rejected']].map(([v, l]) => (
            <button key={v} type="button" aria-pressed={status === v} onClick={() => setStatus(v)} className={`px-3 py-1.5 rounded-lg text-sm ${status === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
        </div>
        {access.can_approve && status === 'open' && safe.length > 1 && (
          <button type="button" className="px-4 py-2 rounded-xl text-sm font-semibold text-white" style={{ background: '#34C759' }} disabled={!!busy} onClick={approveAll}>{busy === 'all' ? 'Sending…' : `Approve all safe (${safe.length})`}</button>)}
      </div>
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>{status === 'open' ? 'No decisions waiting. All done.' : 'Nothing here yet.'}</Empty>
        : rows.map((c) => <DecisionCard key={c.id} c={c} access={access} busy={busy} onApprove={approve} onChanged={refresh} openProduct={openProduct} />)}
      {status === 'open' && fixes.length > 0 && (
        <div className="glass-card p-4 space-y-3">
          <div className="flex justify-between items-center">
            <h3 className="font-bold">Problems with no suggestion yet ({fixes.length})</h3>
            {fixes.length > 5 && <button type="button" className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setShowFix((s) => !s)}>{showFix ? 'Show less' : 'Show all'}</button>}
          </div>
          {(showFix ? fixes : fixes.slice(0, 5)).map((f) => {
            const [what, how] = plain(f.rule_code, f.message);
            return (
              <div key={f.id} className="flex flex-wrap items-center gap-2 text-sm">
                <div className="flex-1 min-w-[200px]"><div className="font-semibold text-glass-primary">{what}</div>
                  <div className="text-xs text-glass-secondary">{f.asin || 'Whole account'}{how ? ` · ${how}` : ''}</div></div>
                {f.sku && askClaude && <button type="button" className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => askClaude(`Please suggest a fix for product ${f.sku} (${f.asin}): ${what}. ${f.message}`, f.sku)}>Ask Claude to fix</button>}
                {f.sku && <button type="button" className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => openProduct(f.sku)}>Fix myself</button>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Live Claude chat
function useSpeech(onText) {
  const R = typeof window !== 'undefined' ? (window.SpeechRecognition || window.webkitSpeechRecognition) : null;
  const rec = useRef(null);
  const [on, setOn] = useState(false);
  const start = (lang) => {
    if (!R) { showToast('Voice works in Chrome, Edge and Safari. Please type here.', 'info'); return; }
    const r = new R(); r.lang = lang; r.interimResults = true; r.continuous = false;
    let base = null;
    r.onresult = (e) => { const t = [...e.results].map((x) => x[0].transcript).join(' '); onText((prev) => { if (base === null) base = prev ? `${prev} ` : ''; return base + t; }); };
    r.onerror = (e) => { if (e.error === 'not-allowed') showToast('Allow the microphone for this site to speak.', 'error'); setOn(false); };
    r.onend = () => setOn(false);
    rec.current = r; r.start(); setOn(true);
  };
  const stop = () => { rec.current?.stop(); setOn(false); };
  return { supported: !!R, on, start, stop };
}

export function ClaudeChat({ open, onClose, preset, goDecisions }) {
  const [d, setD] = useState(null);
  const [text, setText] = useState('');
  const [lang, setLang] = useState('en-IN');
  const [sending, setSending] = useState(false);
  const end = useRef(null);
  const speech = useSpeech(setText);
  const load = useCallback(() => rpc('api_amz_chat', { p_limit: 40 }).then(setD).catch((e) => setD({ error: e.message })), []);
  useEffect(() => { if (open) load(); }, [open, load]);
  useEffect(() => { if (open && preset) setText(preset.text); }, [open, preset]);
  const waiting = (d?.messages || []).some((m) => m.status === 'waiting' || m.status === 'working');
  useEffect(() => {
    if (!open) return undefined;
    const t = setInterval(load, waiting ? 3000 : 15000);
    return () => clearInterval(t);
  }, [open, waiting, load]);
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }); }, [d?.messages?.length, open]);
  const submit = async () => {
    const t = text.trim();
    if (t.length < 2) return;
    speech.stop(); setSending(true);
    try { await rpc('api_amz_chat_send', { p_text: t, p_sku: preset?.sku || null }); setText(''); await load(); }
    catch (e) { showToast(e.message, 'error'); }
    setSending(false);
  };
  if (!open) return null;
  const status = !d ? null : d.error ? null : d.online ? ['Online on your Mac', '#34C759'] : d.connected ? ['Mac offline: answers within the hour', '#FF9500'] : ['Not connected: answers within the hour', '#8E8E93'];
  return (
    <div className="fixed inset-0 z-50 flex justify-end" role="dialog" aria-label="Claude chat" aria-modal="true">
      <button type="button" className="absolute inset-0 bg-black/20" aria-label="Close chat" onClick={onClose} />
      <div className="relative w-full sm:w-[420px] h-full flex flex-col" style={{ background: 'var(--surface-elevated, #fff)', boxShadow: '-8px 0 30px rgba(0,0,0,0.15)' }}>
        <div className="p-4 border-b flex items-center gap-3" style={{ borderColor: 'var(--border-subtle)' }}>
          <span className="w-9 h-9 rounded-full grid place-items-center text-white" style={{ background: 'linear-gradient(160deg,#D97757,#C15F3C)' }}><Icon name="sparkles" size={18} /></span>
          <div className="flex-1 min-w-0">
            <div className="font-bold">Claude</div>
            {status && <div className="text-xs flex items-center gap-1.5 text-glass-secondary"><span className="w-2 h-2 rounded-full" style={{ background: status[1] }} />{status[0]}</div>}
          </div>
          <button type="button" className="glass-btn-ghost p-2" aria-label="Close" onClick={onClose}><Icon name="close" size={16} /></button>
        </div>
        <div className="flex-1 overflow-y-auto p-4 space-y-3">
          {d?.error && <div className="text-sm" style={{ color: '#C4261D' }}>{d.error}</div>}
          {d && !d.error && d.messages.length === 0 && (
            <div className="text-sm text-glass-secondary space-y-2">
              <p>Ask anything about your Amazon shop, in English or Hindi. For example:</p>
              {['Which product sold most this week?', 'Write a better name for my B5 brown diary', 'Why am I losing Add to Cart on 3 products?'].map((q) => (
                <button key={q} type="button" className="block text-left glass-btn-ghost px-3 py-2 text-sm w-full" onClick={() => setText(q)}>{q}</button>))}
              <p className="text-xs text-glass-muted">Claude can suggest changes. They wait in Decisions until you approve.</p>
            </div>
          )}
          {(d?.messages || []).map((m) => (
            <div key={m.id} className="space-y-2">
              <div className="flex justify-end"><div className="max-w-[85%] rounded-2xl rounded-br-md px-3 py-2 text-sm text-white whitespace-pre-wrap" style={{ background: '#007AFF' }}>{m.question}</div></div>
              <div className="flex">
                <div className="max-w-[90%] rounded-2xl rounded-bl-md px-3 py-2 text-sm whitespace-pre-wrap" style={{ background: 'rgba(118,118,128,0.12)' }}>
                  {m.status === 'answered' ? m.answer : m.status === 'working' ? 'Claude is thinking…'
                    : d.online ? 'Waiting for Claude…' : `Waiting. Claude answers when your Mac is online, or within the hour.${m.note ? ` (${m.note})` : ''}`}
                  {m.status === 'answered' && (m.draft_ids || []).length > 0 && (
                    <button type="button" className="block mt-2 text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => { onClose(); goDecisions(); }}>
                      {m.draft_ids.length} suggested change{m.draft_ids.length > 1 ? 's' : ''} waiting in Decisions →</button>)}
                </div>
              </div>
            </div>
          ))}
          <div ref={end} />
        </div>
        <div className="p-3 border-t space-y-2" style={{ borderColor: 'var(--border-subtle)' }}>
          {speech.on && <div className="text-xs" style={{ color: '#C4261D' }}>Listening… speak now, then check the text before sending.</div>}
          <div className="flex gap-2 items-end">
            <textarea aria-label="Message to Claude" rows={2} className="glass-input flex-1 px-3 py-2 text-sm" placeholder="Type or press the mic to speak" value={text}
              onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); } }} />
            <div className="flex flex-col gap-1">
              <button type="button" aria-label={speech.on ? 'Stop listening' : 'Speak'} className="w-10 h-10 rounded-full grid place-items-center text-white"
                style={{ background: speech.on ? '#FF3B30' : '#8E8E93' }} onClick={() => (speech.on ? speech.stop() : speech.start(lang))}><Icon name="mic" size={18} /></button>
              <button type="button" aria-label="Send" disabled={sending || text.trim().length < 2} className="w-10 h-10 rounded-full grid place-items-center text-white" style={{ background: '#007AFF' }} onClick={submit}><Icon name="send" size={16} /></button>
            </div>
          </div>
          <div className="flex items-center gap-2 text-[11px] text-glass-muted">
            Voice:
            {[['en-IN', 'English'], ['hi-IN', 'हिन्दी']].map(([v, l]) => <button key={v} type="button" aria-pressed={lang === v} onClick={() => setLang(v)} className={`px-2 py-0.5 rounded-full ${lang === v ? 'font-semibold' : ''}`} style={lang === v ? { background: 'rgba(0,122,255,0.12)', color: '#007AFF' } : undefined}>{l}</button>)}
          </div>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Morning summary (top of Home)
export function MorningSummary({ go, openProduct }) {
  const [h, setH] = useState(null);
  const [showReport, setShowReport] = useState(false);
  useEffect(() => { rpc('api_amz_home').then(setH).catch(() => setH({ error: true })); }, []);
  if (!h || h.error) return null;
  const hr = istHour();
  const hello = hr < 12 ? 'Good morning' : hr < 17 ? 'Good afternoon' : 'Good evening';
  const due = h.to_ship || [];
  const left = 12 - hr;
  return (
    <div className="space-y-3">
      <div className="glass-card p-4">
        <div className="text-lg font-bold text-glass-primary">{hello} 👋</div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-3">
          <button type="button" onClick={() => go('sales')} className="text-left"><div className="text-xs text-glass-muted">Yesterday</div><div className="text-xl font-bold">{inr(h.yesterday.revenue)}</div><div className="text-[11px] text-glass-muted">{h.yesterday.units} sold</div></button>
          <button type="button" onClick={() => go('sales')} className="text-left"><div className="text-xs text-glass-muted">Last 7 days</div><div className="text-xl font-bold">{inr(h.week.revenue)}</div><div className="text-[11px] text-glass-muted">{h.week.units} sold</div></button>
          <div><div className="text-xs text-glass-muted">Orders to ship</div><div className="text-xl font-bold" style={due.length ? { color: '#FF9500' } : undefined}>{due.length}</div><div className="text-[11px] text-glass-muted">{h.orders_synced_at ? `updated ${ageText(h.orders_synced_at)}` : 'waiting for first update'}</div></div>
          <button type="button" onClick={() => go('decisions')} className="text-left"><div className="text-xs text-glass-muted">Decisions waiting</div><div className="text-xl font-bold" style={h.decisions ? { color: '#007AFF' } : undefined}>{h.decisions}</div><div className="text-[11px] text-glass-muted">tap to review</div></button>
        </div>
      </div>
      {due.length > 0 && (
        <div className="glass-card p-4 space-y-2">
          <div className="flex flex-wrap justify-between items-center gap-2">
            <h3 className="font-bold">Ship these {due.length === 1 ? 'order' : `${due.length} orders`}</h3>
            {hr < 12 ? <Chip style={left <= 2 ? RED : AMBER}>Book Easy Ship pickup before 12 noon · {left} h left</Chip> : <Chip>Today's pickup slot has passed: book for tomorrow</Chip>}
          </div>
          {due.slice(0, 8).map((o) => (
            <a key={o.order_id} href={`https://sellercentral.amazon.in/orders-v3/order/${o.order_id}`} target="_blank" rel="noreferrer" className="flex items-center gap-3 rounded-xl p-2 hover:bg-black/5">
              <span className="w-11 h-11 rounded-lg bg-white grid place-items-center overflow-hidden shrink-0">{o.photo ? <img src={o.photo} alt="" className="w-full h-full object-contain" /> : <Icon name="cart" size={18} />}</span>
              <span className="flex-1 min-w-0 text-sm"><span className="block font-semibold truncate">{(o.items || []).map((i) => `${i.qty} × ${i.title || i.sku}`).join(', ') || `${o.units} item(s)`}</span>
                <span className="block text-[11px] text-glass-muted">Order {o.order_id} · ship by {shipBy(o.latest_ship_date)}{o.easy_ship_status ? ` · ${o.easy_ship_status.replace(/([a-z])([A-Z])/g, '$1 $2')}` : ''}</span></span>
              <Icon name="chevronRight" size={14} />
            </a>
          ))}
          <div className="text-[11px] text-glass-muted">Tap an order to open it in Seller Central (name on cover and address are shown there).</div>
        </div>
      )}
      {(h.low_stock || []).length > 0 && (
        <div className="glass-card p-4 space-y-2">
          <h3 className="font-bold">Running low (under {h.low_stock_min})</h3>
          <div className="flex gap-2 overflow-x-auto pb-1">
            {h.low_stock.map((p) => (
              <button key={p.sku} type="button" onClick={() => openProduct(p.sku)} className="shrink-0 w-28 text-left">
                <div className="w-28 h-28 rounded-xl bg-white grid place-items-center overflow-hidden">{p.photo ? <img src={p.photo} alt="" className="w-full h-full object-contain" /> : <Icon name="image" size={20} />}</div>
                <div className="text-[11px] mt-1 line-clamp-2">{p.title}</div>
                <Chip style={p.stock === 0 ? RED : AMBER}>{p.stock} left</Chip>
              </button>
            ))}
          </div>
        </div>
      )}
      {h.report && (
        <div className="glass-card p-4">
          <button type="button" className="w-full flex justify-between items-center" onClick={() => setShowReport((s) => !s)} aria-expanded={showReport}>
            <span className="font-bold inline-flex items-center gap-2"><Icon name="sparkles" size={16} />This week's report from Claude</span>
            <span className="text-xs text-glass-muted">{ageText(h.report.at)}</span>
          </button>
          {showReport && <div className="mt-3 text-sm whitespace-pre-wrap text-glass-secondary">{h.report.text}</div>}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Settings: connect the Mac Mini
export function MacConnect() {
  const [d, setD] = useState(null);
  const [code, setCode] = useState('');
  const load = () => rpc('api_amz_chat', { p_limit: 1 }).then(setD).catch(() => setD(null));
  useEffect(() => { load(); }, []);
  const make = async () => {
    if (d?.connected && !(await confirmDialog('Make a new connection code?', { message: 'The Mac using the old code will stop working until you install the new one.', confirmText: 'Make new code', danger: true }))) return;
    try { setCode(await rpc('api_amz_bridge_token_new')); load(); } catch (e) { showToast(e.message, 'error'); }
  };
  const revoke = async () => {
    if (!(await confirmDialog('Disconnect the Mac?', { message: 'Live Claude stops at once. Messages are then answered by the hourly task.', confirmText: 'Disconnect', danger: true }))) return;
    try { await rpc('api_amz_bridge_token_revoke'); setCode(''); load(); showToast('Mac disconnected.', 'success'); } catch (e) { showToast(e.message, 'error'); }
  };
  const cmd = 'bash ~/Desktop/CRM/CRM/tools/claude-bridge/install.sh';
  const copy = (t) => navigator.clipboard?.writeText(t).then(() => showToast('Copied', 'success')).catch(() => {});
  return (
    <div className="glass-card p-4 space-y-3">
      <h3 className="font-bold">Live Claude on your Mac Mini</h3>
      <div className="text-sm flex items-center gap-2"><span className="w-2.5 h-2.5 rounded-full" style={{ background: d?.online ? '#34C759' : d?.connected ? '#FF9500' : '#8E8E93' }} />
        {d?.online ? 'Online now' : d?.connected ? `Connected, Mac offline${d.seen_at ? ` (last seen ${ageText(d.seen_at)})` : ''}` : 'Not connected'}</div>
      {code ? (
        <div className="space-y-2 rounded-2xl p-3" style={{ background: 'rgba(0,122,255,0.06)' }}>
          <div className="text-sm font-semibold">Connection code (shown only now)</div>
          <div className="flex gap-2"><code className="flex-1 text-xs break-all p-2 rounded-lg bg-white">{code}</code><button type="button" className="glass-btn px-3 text-sm" onClick={() => copy(code)}>Copy</button></div>
          <ol className="text-sm list-decimal pl-5 space-y-1">
            <li>On the Mac Mini, open <b>Terminal</b>.</li>
            <li>Paste and run: <code className="text-xs">{cmd}</code> <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => copy(cmd)}>Copy</button></li>
            <li>When it asks, paste the connection code above.</li>
            <li>In System Settings &gt; Energy, turn on "Prevent automatic sleeping" so Claude stays online.</li>
          </ol>
        </div>
      ) : (
        <div className="text-xs text-glass-secondary">Uses the Claude login on your Mac (Max plan). No API key, no extra cost. Only Admin and people allowed to approve can chat.</div>
      )}
      <div className="flex flex-wrap gap-2">
        <button type="button" className="glass-btn px-4 py-2 text-sm" onClick={make}>{d?.connected ? 'Make a new connection code' : 'Connect my Mac'}</button>
        {d?.connected && <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" style={{ color: '#C4261D' }} onClick={revoke}>Disconnect</button>}
      </div>
    </div>
  );
}

