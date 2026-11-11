import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { inr, diffRows, STATUS_STYLE, ageText, plain, FIELD_LABELS } from '../utils/amazon';
import { useRoute, setParams } from '../utils/route';

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

// ---------------------------------------------------------------- pop-ups
export function Modal({ title, onClose, children, wide, z = 50 }) {
  useEffect(() => {
    const k = (e) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  return (
    <div className="fixed inset-0 flex items-end sm:items-center justify-center p-0 sm:p-6" style={{ zIndex: z }} role="dialog" aria-modal="true" aria-label={title}>
      <button type="button" className="absolute inset-0 bg-black/30" aria-label="Close" onClick={onClose} />
      <div className={`relative w-full ${wide ? 'sm:max-w-4xl' : 'sm:max-w-lg'} max-h-[92vh] overflow-y-auto rounded-t-3xl sm:rounded-3xl p-5`}
        style={{ background: 'var(--surface-elevated, #fff)', boxShadow: '0 20px 60px rgba(0,0,0,0.25)' }}>
        <div className="flex items-start justify-between gap-3 mb-4">
          <h3 className="text-lg font-bold text-glass-primary">{title}</h3>
          <button type="button" className="glass-btn-ghost p-2 shrink-0" aria-label="Close pop-up" onClick={onClose}><Icon name="close" size={16} /></button>
        </div>
        {children}
      </div>
    </div>
  );
}

const RANK = ['', 'Best choice', '2nd choice', '3rd choice'];
function WhyModal({ c, onClose }) {
  const g = c.guard_result || {};
  return (
    <Modal title={`Why ${RANK[c.alt_rank] ? `"${RANK[c.alt_rank]}"` : 'this choice'}?`} onClose={onClose} z={60}>
      <div className="space-y-3 text-sm">
        {c.rank_reason && <div className="rounded-2xl p-3" style={{ background: 'rgba(175,82,222,0.08)' }}><div className="text-xs font-semibold mb-1">How Claude ranked it</div>{c.rank_reason}</div>}
        {c.reason && <div><div className="text-xs font-semibold text-glass-muted">What it fixes</div>{c.reason}</div>}
        <div>
          <div className="text-xs font-semibold text-glass-muted mb-1">Amazon rule checks</div>
          {(g.blockers || []).length + (g.warnings || []).length + (g.confirms || []).length === 0
            ? <div style={{ color: '#1E7B34' }}>All rules pass: price floor, name length, repeated words, sales words, required details.</div>
            : <ul className="space-y-1">{[...(g.blockers || []).map((x) => ['Must fix', RED, x]), ...(g.confirms || []).map((x) => ['Double-check', AMBER, x]), ...(g.warnings || []).map((x) => ['Heads up', AMBER, x])]
                .map(([w, st, x], i) => <li key={i} className="flex gap-2"><Chip style={st}>{w}</Chip><span>{x.message}</span></li>)}</ul>}
        </div>
        <div className="text-xs text-glass-muted">{WHO[c.created_by_type] || ''} · {ageText(c.created_at)}. Ranking weighs: Amazon rules, search visibility, buyer clarity, risk to sales and your margin.</div>
      </div>
    </Modal>
  );
}

function currentFor(p, f) {
  const code = f.rule_code;
  if (['title_max_chars', 'title_word_repeat', 'title_promo_words', 'title_special_chars', 'stale_year', 'title_drift'].includes(code))
    return [['Product name now', `${p?.title || '—'}${p?.title ? `  (${[...p.title].length} letters)` : ''}`]];
  if (['buybox_lost', 'buybox_none'].includes(code))
    return [['Your price', inr(p?.price)], ['Add to Cart winner asks', p?.buybox_price ? inr(p.buybox_price) : 'Nobody has it'], ['Stock', p?.stock ?? '—']];
  if (code === 'amazon_issue') return [['Amazon says', f.message]];
  return [['Details', f.message]];
}

export function ProblemModal({ findingId, access, onClose, onChanged, openProduct }) {
  const [d, setD] = useState(null);
  const [why, setWhy] = useState(null);
  const [busy, setBusy] = useState('');
  const load = useCallback(() => rpc('api_amz_problem', { p_id: findingId }).then(setD).catch((e) => setD({ error: e.message })), [findingId]);
  useEffect(() => { load(); }, [load]);
  if (!d) return <Modal title="Loading…" onClose={onClose}><Empty>Loading…</Empty></Modal>;
  if (d.error) return <Modal title="Problem" onClose={onClose}><div style={{ color: '#C4261D' }}>{d.error}</div></Modal>;
  const f = d.problem; const p = d.product;
  const [what, how] = plain(f.rule_code, f.message);
  const approve = async (c) => {
    let second = false;
    if (c.needs_second_confirm) {
      if (!(await confirmDialog((c.guard_result.confirms || []).map((x) => x.message).join('\n'), { title: 'Please check', confirmText: 'Yes, approve', danger: true }))) return;
      second = true;
    }
    setBusy(c.id);
    try {
      const a = await rpc('api_amz_approve', { p_id: c.id, p_second_confirm: second });
      if (a?.status === 'stale') showToast('This product changed on Amazon meanwhile. Nothing sent.', 'error');
      else { const s = await send(c.id); showToast(s.m, s.t); }
    } catch (e) { showToast(e.message, 'error'); }
    setBusy(''); onChanged(); onClose();
  };
  const askFix = async () => {
    try { const r = await rpc('api_amz_fix', { p_sku: f.sku }); showToast(r.queued ? 'Claude is working on it. Solutions appear here and in Decisions.' : 'Claude is already working on this product.', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <Modal title={what} onClose={onClose} wide>
      <div className="grid md:grid-cols-2 gap-4">
        <div className="rounded-2xl p-4 space-y-3" style={{ background: 'rgba(255,59,48,0.06)', boxShadow: 'inset 0 0 0 0.5px rgba(255,59,48,0.3)' }}>
          <div className="text-xs font-bold uppercase tracking-wide" style={{ color: '#C4261D' }}>What's wrong now</div>
          {p && (
            <div className="flex gap-3 items-center">
              <div className="w-14 h-14 rounded-xl bg-white grid place-items-center overflow-hidden shrink-0">{p.photo ? <img src={p.photo} alt="" className="w-full h-full object-contain" /> : <Icon name="image" size={18} />}</div>
              <div className="text-sm min-w-0"><div className="font-semibold line-clamp-2">{p.title}</div><div className="text-[11px] text-glass-muted">{p.asin} · {p.sku}</div></div>
            </div>
          )}
          {currentFor(p, f).map(([k, v]) => <div key={k} className="text-sm"><div className="text-xs text-glass-muted">{k}</div><div className="whitespace-pre-wrap">{v}</div></div>)}
          {how && <div className="text-sm"><b>What Amazon wants: </b>{how}</div>}
        </div>
        <div className="rounded-2xl p-4 space-y-3" style={{ background: 'rgba(52,199,89,0.06)', boxShadow: 'inset 0 0 0 0.5px rgba(52,199,89,0.35)' }}>
          <div className="text-xs font-bold uppercase tracking-wide" style={{ color: '#1E7B34' }}>Solutions {d.solutions.length > 1 ? '(ranked)' : ''}</div>
          {d.solutions.length === 0 && (
            <div className="text-sm space-y-3">
              <div className="text-glass-secondary">{d.fix_waiting ? 'Claude is preparing solutions for this product…' : 'No solution yet.'}</div>
              <div className="flex flex-wrap gap-2">
                {!d.fix_waiting && access.can_approve && <button type="button" className="glass-btn px-4 py-2 text-sm inline-flex items-center gap-1.5" onClick={askFix}><Icon name="sparkles" size={14} />Ask Claude to fix this</button>}
                {f.sku && <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={() => { onClose(); openProduct(f.sku); }}>Fix myself</button>}
              </div>
            </div>
          )}
          {d.solutions.map((c, i) => (
            <div key={c.id} className="rounded-2xl p-3 bg-white/70 space-y-2" style={{ boxShadow: i === 0 ? '0 0 0 2px #34C759' : 'inset 0 0 0 0.5px rgba(0,0,0,0.12)' }}>
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 min-w-0">
                  <span className="w-7 h-7 rounded-full grid place-items-center text-xs font-bold text-white shrink-0" style={{ background: i === 0 ? '#34C759' : '#8E8E93' }}>#{c.alt_rank || i + 1}</span>
                  <span className="font-semibold text-sm truncate">{c.summary}</span>
                </div>
                <button type="button" className="text-xs font-semibold shrink-0" style={{ color: 'var(--accent)' }} onClick={() => setWhy(c)}>Why this rank?</button>
              </div>
              {diffRows(c.before, c.after).map((r) => <div key={r.key} className="text-xs"><span className="text-glass-muted">{r.label}: </span><span className="font-medium whitespace-pre-wrap">{r.after}</span></div>)}
              {access.can_approve && (
                <button type="button" disabled={!!busy || !c.guard_result?.ok} onClick={() => approve(c)} className="px-4 py-1.5 rounded-xl text-sm font-semibold text-white" style={{ background: c.guard_result?.ok ? '#34C759' : '#A1A1A6' }}>
                  {busy === c.id ? 'Sending…' : 'Use this'}</button>)}
            </div>
          ))}
          {d.solutions.length > 1 && <div className="text-[11px] text-glass-muted">Using one choice closes the others.</div>}
        </div>
      </div>
      {why && <WhyModal c={why} onClose={() => setWhy(null)} />}
    </Modal>
  );
}

export function Decisions({ access, onChange, openProduct }) {
  const route = useRoute();
  const openId = route.params?.open || '';
  const [status, setStatus] = useState('open');
  const [rows, setRows] = useState(null);
  const [findings, setFindings] = useState([]);
  const [fix, setFix] = useState(null);
  const [busy, setBusy] = useState('');
  const [problem, setProblem] = useState(null);
  const load = useCallback(async () => {
    try {
      const [d, f, s] = await Promise.all([rpc('api_amz_decisions', { p_status: status }), rpc('api_amz_findings', { p_status: 'open' }), rpc('api_amz_fix_status')]);
      setRows(d); setFindings(f || []); setFix(s);
    } catch (e) { showToast(e.message, 'error'); }
  }, [status]);
  useEffect(() => { load(); }, [load]);
  const running = (fix?.waiting || 0) + (fix?.working || 0);
  useEffect(() => { if (!running) return undefined; const t = setInterval(load, 10000); return () => clearInterval(t); }, [running, load]);
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
  const all = rows || [];
  // Show only the best choice of each problem; the others open in the pop-up.
  const bestOnly = all.filter((c) => !(c.status === 'pending' && c.alt_group && (c.alt_rank || 1) > 1
    && all.some((x) => x.alt_group === c.alt_group && x.status === 'pending' && (x.alt_rank || 1) < (c.alt_rank || 1))));
  const others = (c) => all.filter((x) => x.alt_group && x.alt_group === c.alt_group && x.id !== c.id && x.status === 'pending').length;
  const pend = all.filter((c) => c.status === 'pending');
  const safe = bestOnly.filter((c) => c.status === 'pending' && c.guard_result?.ok && !c.needs_second_confirm);
  const warned = safe.filter((c) => (c.guard_result?.warnings || []).length).length;
  const approveAll = async () => {
    if (!(await confirmDialog(`Approve ${safe.length} safe changes?`, { message: `Only the best choice of each problem, and only changes that pass every check.${warned ? ` ${warned} have a heads-up shown on the card.` : ''} Each one goes live on Amazon.`, confirmText: 'Approve all' }))) return;
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
  const fixAll = async () => {
    if (!(await confirmDialog('Let Claude fix every problem?', { message: `Claude prepares 1-3 ranked choices for each of the ${findings.length} problems. Nothing goes live until you approve.${fix?.mac_online ? '' : ' Your Mac is offline, so the hourly backup will do it (slower).'}`, confirmText: 'Fix all with Claude' }))) return;
    try { const r = await rpc('api_amz_fix', { p_sku: null }); showToast(r.queued ? `Claude is fixing ${r.queued} product${r.queued > 1 ? 's' : ''}. Solutions appear here as they are ready.` : 'Claude is already working on these.', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const solved = new Set(pend.map((c) => c.finding_id).filter(Boolean));
  const open = findings.filter((f) => !solved.has(f.id));
  return (
    <div className="space-y-3">
      <div className="glass-card p-3 text-xs text-glass-secondary">Nothing changes on Amazon until you approve it. Every live change can be undone.</div>
      {access.can_approve && findings.length > 0 && (
        <div className="glass-card p-4 flex flex-wrap items-center gap-3" style={{ background: 'linear-gradient(135deg, rgba(217,119,87,0.12), rgba(175,82,222,0.10))' }}>
          <span className="w-10 h-10 rounded-full grid place-items-center text-white shrink-0" style={{ background: 'linear-gradient(160deg,#D97757,#C15F3C)' }}><Icon name="sparkles" size={18} /></span>
          <div className="flex-1 min-w-[200px]">
            <div className="font-bold">{running ? `Claude is fixing ${running} product${running > 1 ? 's' : ''}…` : `${findings.length} problem${findings.length > 1 ? 's' : ''} found`}</div>
            <div className="text-xs text-glass-secondary">{running ? (fix?.mac_online ? 'About a minute per product on your Mac. You can leave this page.' : 'Your Mac is offline: the hourly backup will finish it.') : 'Claude prepares ranked choices for each one. You decide.'}</div>
          </div>
          {!running && <button type="button" className="px-5 py-2.5 rounded-xl text-sm font-semibold text-white" style={{ background: 'linear-gradient(160deg,#D97757,#C15F3C)' }} onClick={fixAll}>Fix All with Claude</button>}
        </div>
      )}
      <div className="flex flex-wrap justify-between gap-2 items-center">
        <div className="flex gap-1 p-1 rounded-xl" role="group" aria-label="Show" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[['open', `Waiting${bestOnly.filter((c) => c.status === 'pending').length ? ` (${bestOnly.filter((c) => c.status === 'pending').length})` : ''}`], ['done', 'Done'], ['rejected', 'Rejected']].map(([v, l]) => (
            <button key={v} type="button" aria-pressed={status === v} onClick={() => setStatus(v)} className={`px-3 py-1.5 rounded-lg text-sm ${status === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
        </div>
        {access.can_approve && status === 'open' && safe.length > 1 && (
          <button type="button" className="px-4 py-2 rounded-xl text-sm font-semibold text-white" style={{ background: '#34C759' }} disabled={!!busy} onClick={approveAll}>{busy === 'all' ? 'Sending…' : `Approve all safe (${safe.length})`}</button>)}
      </div>
      {!rows ? <Empty>Loading…</Empty> : bestOnly.length === 0 ? <Empty>{status === 'open' ? 'No decisions waiting.' : 'Nothing here yet.'}</Empty>
        : bestOnly.map((c) => (
          <div key={c.id}>
            <DecisionCard c={c} access={access} busy={busy} onApprove={approve} onChanged={refresh} openProduct={openProduct} />
            {others(c) > 0 && c.finding_id && <button type="button" className="ml-4 mt-1 text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setProblem(c.finding_id)}>See {others(c)} other choice{others(c) > 1 ? 's' : ''} ranked →</button>}
          </div>))}
      {status === 'open' && open.length > 0 && (
        <div className="space-y-2">
          <h3 className="font-bold px-1 pt-2">Problems ({open.length}) · tap one to see the fix</h3>
          <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {open.map((f) => {
              const [what, how] = plain(f.rule_code, f.message);
              return (
                <button key={f.id} type="button" data-problem={f.id} onClick={() => setProblem(f.id)} className="glass-card p-4 text-left hover:shadow-lg transition-shadow space-y-1.5">
                  <div className="flex items-center gap-2"><Chip style={f.severity === 'blocker' ? RED : AMBER}>{f.severity === 'blocker' ? 'Fix first' : 'Should fix'}</Chip><span className="text-[11px] text-glass-muted">{f.asin || 'Whole account'}</span></div>
                  <div className="font-semibold text-sm text-glass-primary">{what}</div>
                  {how && <div className="text-xs text-glass-secondary line-clamp-2">{how}</div>}
                  <div className="text-xs font-semibold" style={{ color: 'var(--accent)' }}>See the fix →</div>
                </button>
              );
            })}
          </div>
        </div>
      )}
      {problem && <ProblemModal findingId={problem} access={access} onClose={() => setProblem(null)} onChanged={refresh} openProduct={openProduct} />}
      {openId && rows && (() => {
        const c = all.find((x) => x.id === openId);
        return (
          <Modal title={c ? 'Decision from your email' : 'Decision'} onClose={() => setParams({ open: '' })}>
            {c ? <DecisionCard c={c} access={access} busy={busy} onApprove={async (x) => { await approve(x); setParams({ open: '' }); }} onChanged={refresh} openProduct={openProduct} />
              : <div className="text-sm text-glass-secondary">This decision was already handled. See the Done and Rejected tabs.</div>}
          </Modal>
        );
      })()}
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
                style={{ background: speech.on ? '#FF3B30' : '#8E8E93' }} onClick={() => (speech.on ? speech.stop() : speech.start(lang.split('|')[0]))}><Icon name="mic" size={18} /></button>
              <button type="button" aria-label="Send" disabled={sending || text.trim().length < 2} className="w-10 h-10 rounded-full grid place-items-center text-white" style={{ background: '#007AFF' }} onClick={submit}><Icon name="send" size={16} /></button>
            </div>
          </div>
          <div className="flex items-center gap-2 text-[11px] text-glass-muted flex-wrap">
            Voice (Claude replies in the language you use):
            {[['en-IN', 'English'], ['hi-IN', 'हिन्दी'], ['en-IN|hinglish', 'Hinglish']].map(([v, l]) => <button key={v} type="button" aria-pressed={lang === v} onClick={() => setLang(v)} className={`px-2 py-0.5 rounded-full ${lang === v ? 'font-semibold' : ''}`} style={lang === v ? { background: 'rgba(0,122,255,0.12)', color: '#007AFF' } : undefined}>{l}</button>)}
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
  const [alerts, setAlerts] = useState([]);
  const [fests, setFests] = useState([]);
  useEffect(() => {
    rpc('api_amz_home').then(setH).catch(() => setH({ error: true }));
    rpc('api_amz_alerts', { p_mark_seen: false }).then(setAlerts).catch(() => {});
    rpc('api_amz_festivals').then(setFests).catch(() => {});
  }, []);
  const prep = async (f) => {
    try { await rpc('api_amz_festival_prep', { p_name: f.name }); showToast(`Claude is preparing ideas for ${f.name}. They will wait in Decisions.`, 'success'); setFests((x) => x.map((y) => (y.name === f.name ? { ...y, prepared: true } : y))); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const ALERT_ICON = { new_order: 'cart', pickup: 'clock', feedback: 'heart', out_of_stock: 'alert', suppressed: 'alert' };
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
      {alerts.filter((a) => !a.seen_at).length > 0 && (
        <div className="glass-card p-4 space-y-2">
          <div className="flex justify-between items-center"><h3 className="font-bold">Alerts</h3>
            <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => rpc('api_amz_alerts', { p_mark_seen: true }).then(() => setAlerts((x) => x.map((a) => ({ ...a, seen_at: new Date().toISOString() })))).catch(() => {})}>Mark all as read</button></div>
          {alerts.filter((a) => !a.seen_at).slice(0, 6).map((a) => (
            <a key={a.id} href={a.link || undefined} target="_blank" rel="noreferrer" className="flex items-start gap-3 rounded-xl p-2 hover:bg-black/5">
              <span className="w-8 h-8 rounded-full grid place-items-center text-white shrink-0" style={{ background: a.kind === 'new_order' ? '#34C759' : a.kind === 'pickup' ? '#FF9500' : '#FF3B30' }}><Icon name={ALERT_ICON[a.kind] || 'alert'} size={14} /></span>
              <span className="text-sm min-w-0"><span className="block font-semibold">{a.title}</span>{a.body && <span className="block text-xs text-glass-secondary">{a.body}</span>}<span className="block text-[11px] text-glass-muted">{ageText(a.created_at)}</span></span>
            </a>
          ))}
        </div>
      )}
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
      {fests.length > 0 && (
        <div className="glass-card p-4 space-y-2">
          <h3 className="font-bold">Coming up</h3>
          <div className="flex gap-2 overflow-x-auto pb-1 snap-x snap-mandatory -mx-1 px-1" style={{ scrollPaddingLeft: 4 }}>
            {fests.slice(0, 6).map((f) => (
              <div key={`${f.name}${f.day}`} className="shrink-0 snap-start w-[min(13rem,72%)] rounded-2xl p-3 space-y-1.5 flex flex-col" style={{ background: f.days_left <= 21 ? 'rgba(255,149,0,0.10)' : 'rgba(118,118,128,0.08)' }}>
                <div className="font-semibold text-sm">{f.name}</div>
                <div className="text-[11px] text-glass-muted">{new Date(f.day).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })} · {f.days_left === 0 ? 'today' : `in ${f.days_left} days`}</div>
                {f.note && <div className="text-xs text-glass-secondary line-clamp-2">{f.note}</div>}
                <div className="mt-auto pt-1">{f.prepared ? <Chip style={GREEN}>Claude is on it</Chip>
                  : <button type="button" className="glass-btn-ghost px-3 py-1 text-xs whitespace-nowrap" onClick={() => prep(f)}>Prepare with Claude</button>}</div>
              </div>
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
  const cmd = 'bash <(curl -fsSL https://raw.githubusercontent.com/Weone404/CRM/main/CRM/tools/claude-bridge/install.sh)';
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


// ---------------------------------------------------------------- Settings: who gets alert emails
export function AlertEmails() {
  const [list, setList] = useState(null);
  const [add, setAdd] = useState('');
  useEffect(() => { rpc('api_amz_alert_emails', { p_emails: null }).then(setList).catch(() => setList([])); }, []);
  const save = async (next) => {
    try { setList(await rpc('api_amz_alert_emails', { p_emails: next })); showToast('Saved', 'success'); return true; }
    catch (e) { showToast(e.message, 'error'); return false; }
  };
  const valid = /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(add.trim());
  return (
    <div className="glass-card p-4 space-y-3">
      <h3 className="font-bold">Alert emails</h3>
      <div className="text-xs text-glass-secondary">New orders, the 11 AM pickup reminder, 1–2 star feedback and out-of-stock alerts go to these people. With the business email on, they arrive within a minute; otherwise they come every hour from 9 AM to 8 PM from your connected Gmail.</div>
      {!list ? <Empty>Loading…</Empty> : (
        <div className="flex flex-wrap gap-2">
          {list.length === 0 && <span className="text-sm text-glass-muted">No emails yet. Alerts still show on Home.</span>}
          {list.map((e) => (
            <span key={e} className="inline-flex items-center gap-1.5 pl-3 pr-1 py-1 rounded-full text-sm" style={{ background: 'rgba(0,122,255,0.10)' }}>
              {e}<button type="button" aria-label={`Remove ${e}`} className="w-6 h-6 rounded-full grid place-items-center hover:bg-black/10" onClick={() => save(list.filter((x) => x !== e))}><Icon name="close" size={12} /></button>
            </span>))}
        </div>
      )}
      <div className="flex gap-2">
        <input aria-label="Add alert email" type="email" className="glass-input flex-1 px-3 py-2 text-sm" placeholder="name@example.com" value={add}
          onChange={(e) => setAdd(e.target.value)} onKeyDown={async (e) => { if (e.key === 'Enter' && valid && await save([...(list || []), add.trim()])) setAdd(''); }} />
        <button type="button" aria-label="Add email" className="glass-btn px-4 text-sm" disabled={!valid || (list || []).length >= 10} onClick={async () => { if (await save([...(list || []), add.trim()])) setAdd(''); }}>Add</button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Settings: my style
const TONES = ['Friendly', 'Professional', 'Premium', 'Simple'];
function Words({ label, list, onChange, placeholder }) {
  const [w, setW] = useState('');
  const add = () => { const t = w.trim(); if (t && !list.includes(t) && list.length < 30) onChange([...list, t]); setW(''); };
  return (
    <div className="space-y-1.5">
      <div className="text-sm font-semibold">{label}</div>
      <div className="flex flex-wrap gap-1.5">{list.map((x) => (
        <span key={x} className="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full text-xs" style={{ background: 'rgba(118,118,128,0.12)' }}>{x}
          <button type="button" aria-label={`Remove ${x}`} className="w-5 h-5 rounded-full grid place-items-center hover:bg-black/10" onClick={() => onChange(list.filter((y) => y !== x))}><Icon name="close" size={10} /></button></span>))}</div>
      <div className="flex gap-2"><input aria-label={label} className="glass-input flex-1 px-3 py-1.5 text-sm" placeholder={placeholder} value={w} onChange={(e) => setW(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } }} />
        <button type="button" aria-label={`Add to ${label}`} className="glass-btn-ghost px-3 text-sm" onClick={add}>Add</button></div>
    </div>
  );
}
export function MyStyle() {
  const [st, setSt] = useState(null);
  useEffect(() => { rpc('api_amz_style', { p_style: null }).then((r) => setSt({ tone: '', language: 'auto', use_words: [], avoid_words: [], notes: '', ...r })).catch(() => setSt(null)); }, []);
  if (!st) return null;
  const save = async () => { try { await rpc('api_amz_style', { p_style: st }); showToast('Style saved. Claude uses it from the next suggestion.', 'success'); } catch (e) { showToast(e.message, 'error'); } };
  return (
    <div className="glass-card p-4 space-y-3">
      <h3 className="font-bold">My style</h3>
      <div className="text-xs text-glass-secondary">Claude follows this in every name, key point and description it suggests, and in its replies.</div>
      <div className="grid sm:grid-cols-2 gap-3">
        <label className="text-sm"><span className="font-semibold">Tone</span>
          <select aria-label="Tone" className="glass-input w-full px-3 py-2 mt-1" value={st.tone || ''} onChange={(e) => setSt({ ...st, tone: e.target.value })}>
            <option value="">No preference</option>{TONES.map((t) => <option key={t}>{t}</option>)}</select></label>
        <label className="text-sm"><span className="font-semibold">Claude's reply language</span>
          <select aria-label="Reply language" className="glass-input w-full px-3 py-2 mt-1" value={st.language || 'auto'} onChange={(e) => setSt({ ...st, language: e.target.value })}>
            <option value="auto">Same as my message</option><option value="english">English</option><option value="hindi">हिन्दी (Hindi)</option><option value="hinglish">Hinglish</option></select></label>
      </div>
      <Words label="Words I like" list={st.use_words || []} onChange={(v) => setSt({ ...st, use_words: v })} placeholder="e.g. personalised" />
      <Words label="Words never to use" list={st.avoid_words || []} onChange={(v) => setSt({ ...st, avoid_words: v })} placeholder="e.g. cheap" />
      <label className="block text-sm"><span className="font-semibold">Anything else Claude should know</span>
        <textarea aria-label="Style notes" rows={2} className="glass-input w-full px-3 py-2 mt-1 text-sm" maxLength={600} value={st.notes || ''} onChange={(e) => setSt({ ...st, notes: e.target.value })} placeholder="e.g. Mention free name printing on the cover." /></label>
      <div className="text-[11px] text-glass-muted">Product listings stay in English for Amazon.in; only Claude's replies follow the language setting.</div>
      <button type="button" className="glass-btn px-4 py-2 text-sm" onClick={save}>Save my style</button>
    </div>
  );
}

// ---------------------------------------------------------------- Sales: profit per product
export function Profit() {
  const [rows, setRows] = useState(null);
  const [edit, setEdit] = useState({});
  const load = () => rpc('api_amz_margins').then(setRows).catch(() => setRows([]));
  useEffect(() => { load(); }, []);
  const save = async (r) => {
    const e = edit[r.sku] || {};
    const cost = e.cost === '' || e.cost === undefined ? null : Number(e.cost);
    try { await rpc('api_amz_cost_set', { p_sku: r.sku, p_cost: cost, p_extra: Number(e.extra || 0) }); showToast('Saved', 'success'); setEdit((x) => ({ ...x, [r.sku]: undefined })); load(); }
    catch (err) { showToast(err.message, 'error'); }
  };
  if (!rows) return null;
  const missing = rows.filter((r) => r.cost == null).length;
  return (
    <div className="glass-card p-4 space-y-3">
      <h3 className="font-bold">Profit per product</h3>
      <div className="text-xs text-glass-secondary">Enter what one diary costs you (with name printing) and packing per order, once. Amazon fees per unit come from your last 60 days of orders. Claude then protects your margin in price suggestions.{missing ? ` ${missing} product${missing > 1 ? 's' : ''} still need a cost.` : ''}</div>
      <div className="divide-y" style={{ borderColor: 'var(--border-subtle)' }}>
        {rows.map((r) => {
          const e = edit[r.sku];
          const tone = r.margin_pct == null ? {} : r.margin_pct < 0 ? RED : r.margin_pct < 10 ? AMBER : GREEN;
          return (
            <div key={r.sku} className="py-2 flex flex-wrap items-center gap-3 text-sm">
              <div className="w-10 h-10 rounded-lg bg-white grid place-items-center overflow-hidden shrink-0">{r.photo ? <img src={r.photo} alt="" className="w-full h-full object-contain" /> : null}</div>
              <div className="flex-1 min-w-[160px]"><div className="truncate font-medium">{r.title}</div>
                <div className="text-[11px] text-glass-muted">Price {inr(r.price)} · Amazon fee {r.fee_per_unit != null ? inr(r.fee_per_unit) : 'not known yet'}</div></div>
              {e ? (
                <div className="flex items-center gap-1.5">
                  <input aria-label={`Cost of ${r.sku}`} type="number" min="0" className="glass-input w-20 px-2 py-1 text-sm" placeholder="Cost" value={e.cost ?? ''} onChange={(ev) => setEdit((x) => ({ ...x, [r.sku]: { ...e, cost: ev.target.value } }))} />
                  <input aria-label={`Packing of ${r.sku}`} type="number" min="0" className="glass-input w-20 px-2 py-1 text-sm" placeholder="Packing" value={e.extra ?? ''} onChange={(ev) => setEdit((x) => ({ ...x, [r.sku]: { ...e, extra: ev.target.value } }))} />
                  <button type="button" className="glass-btn px-3 py-1 text-xs" onClick={() => save(r)}>Save</button>
                </div>
              ) : (
                <button type="button" className="flex items-center gap-2" onClick={() => setEdit((x) => ({ ...x, [r.sku]: { cost: r.cost ?? '', extra: r.extra ?? '' } }))}>
                  {r.cost == null ? <Chip>Add cost</Chip> : <><span className="font-semibold">{inr(r.profit)}</span><Chip style={tone}>{r.margin_pct}%</Chip></>}
                </button>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
