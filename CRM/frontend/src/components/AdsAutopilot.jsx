// CRM > ADS > Autopilot (Google Ads only; Meta and Amazon are separate). Reads/writes only through api_ads_* functions
// (migration 093). The agents run on their own bridge; this screen sets their limits, shows what they suggest and did,
// and takes instructions (typed or spoken). Spend limits are enforced in the database, not here.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog } from './ui/dialogs';
import Icon from './icons';
import { money } from '../utils/ads';

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
const run = async (p, okMsg) => {
  try { const r = await p; if (okMsg) showToast(okMsg, 'success'); return r ?? true; }
  catch (e) { showToast(e.message, 'error'); return undefined; }
};
const Chip = ({ children, fg = '#3C3C43', bg = 'rgba(118,118,128,0.14)' }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: bg, color: fg }}>{children}</span>
);
const Btn = ({ tone = '#007AFF', ghost, className = '', ...p }) => (
  <button type="button" {...p} className={`px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center justify-center gap-1.5 disabled:opacity-40 ${className}`}
    style={ghost ? { background: 'rgba(118,118,128,0.12)', color: '#1C1C1E' } : { background: tone, color: '#fff' }} />
);
const ago = (t) => {
  if (!t) return '';
  const m = Math.round((Date.now() - Date.parse(t)) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return `${Math.round(m / 1440)} d ago`;
};
const GREEN = ['#1E7B34', 'rgba(52,199,89,0.14)'];
const RED = ['#C4261D', 'rgba(255,59,48,0.12)'];
const AMBER = ['#8A5A00', 'rgba(255,149,0,0.14)'];
const BLUE = ['#0062CC', 'rgba(0,122,255,0.10)'];
const GREY = ['#636366', 'rgba(118,118,128,0.14)'];
const ROLE = { researcher: 'Researcher', builder: 'Builder', reviewer: 'Reviewer', allocator: 'Budget', learner: 'Learner', supervisor: 'Supervisor' };
const RUN_TONE = { queued: GREY, running: BLUE, done: GREEN, failed: RED, rejected: AMBER, escalated: RED };
const OP_TONE = { pending: AMBER, blocked: RED, approved: BLUE, executing: BLUE, verified: GREEN, failed: RED, outcome_unknown: AMBER, rejected: GREY, stale: GREY };
const OP_LABEL = { pending: 'Waiting', blocked: 'Blocked by checks', approved: 'Approved', executing: 'Sending', verified: 'Live (checked)',
  failed: 'Failed', outcome_unknown: 'Unclear, checking', rejected: 'Rejected', stale: 'Out of date' };
const KIND = { geo: 'Locations', keywords: 'Keywords', negatives: 'Negatives', ads: 'Ads', assets: 'Callouts & links', budget: 'Budget', tracking: 'Tracking', other: 'Other' };
const PRESETS = [200, 300, 500, 1000];

function Bar({ value, max, label, cur }) {
  const p = max > 0 ? Math.min(100, (Number(value || 0) / max) * 100) : 0;
  const tone = p >= 100 ? '#FF3B30' : p >= 80 ? '#FF9500' : '#34C759';
  return (
    <div>
      <div className="flex justify-between text-xs text-glass-secondary"><span>{label}</span>
        <span className="font-semibold text-glass-primary">{money(value || 0, cur, 0)}{max ? <span className="text-glass-muted font-normal"> of {money(max, cur, 0)}</span> : ''}</span></div>
      <div className="h-2 rounded-full mt-1" style={{ background: 'rgba(118,118,128,0.16)' }}>
        <div className="h-2 rounded-full transition-all" style={{ width: `${p}%`, background: tone }} />
      </div>
    </div>
  );
}

function Limits({ d, reload }) {
  const cur = d.account?.currency || 'INR';
  const [daily, setDaily] = useState(String(d.caps.daily ?? ''));
  const [monthly, setMonthly] = useState(String(d.caps.monthly ?? ''));
  const [mode, setMode] = useState(d.mode);
  const [busy, setBusy] = useState(false);
  useEffect(() => { setDaily(String(d.caps.daily ?? '')); setMonthly(String(d.caps.monthly ?? '')); setMode(d.mode); }, [d.caps.daily, d.caps.monthly, d.mode]);
  const dirty = String(d.caps.daily ?? '') !== daily || String(d.caps.monthly ?? '') !== monthly || d.mode !== mode;
  const pick = (v) => { setDaily(String(v)); setMonthly(String(Math.round(v * 30.4))); };
  const save = async () => {
    setBusy(true);
    const ok = await run(rpc('api_ads_autopilot_save', { p_mode: mode, p_daily: Number(daily), p_monthly: Number(monthly) }), 'Limits saved.');
    setBusy(false); if (ok) reload();
  };
  const ro = !d.can_approve;
  return (
    <section className="glass-card p-4 space-y-4" data-testid="ap-limits">
      <div className="flex items-start justify-between gap-3">
        <div><div className="font-bold text-glass-primary">Spend limits</div>
          <div className="text-xs text-glass-secondary">The agents can never raise budgets or switch campaigns on above these. Lowering spend is always allowed.</div></div>
        <div className="flex gap-1 p-1 rounded-xl shrink-0" style={{ background: 'rgba(118,118,128,0.12)' }} role="radiogroup" aria-label="Autopilot mode">
          {[['auto', 'Automatic'], ['off', 'Ask me']].map(([v, l]) => (
            <button key={v} type="button" role="radio" aria-checked={mode === v} disabled={ro} onClick={() => setMode(v)}
              className={`px-3 py-1.5 rounded-lg text-sm ${mode === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
        </div>
      </div>
      <div className="text-xs text-glass-secondary -mt-2">{mode === 'auto'
        ? 'Automatic: changes that pass every check go live without waiting for you.'
        : 'Ask me: every agent change waits in Approvals.'}</div>
      <div className="space-y-2.5">
        <Bar label="Spent today" value={d.spend.today} max={d.caps.daily} cur={cur} />
        <Bar label="Spent this month" value={d.spend.month} max={d.caps.monthly} cur={cur} />
        <div className="text-[11px] text-glass-muted">Running campaigns can spend up to {money(d.budgets.enabled_total, cur, 0)} a day · last 7 days averaged {money(d.spend.avg7, cur, 0)} a day · Google may spend up to 2× a day's budget on busy days, but not more than about 30.4 days of it in a month.</div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <label className="block text-sm"><span className="block text-xs font-medium text-glass-secondary mb-1">Daily limit ({cur})</span>
          <input inputMode="decimal" className="glass-input w-full px-3 py-2 text-sm" value={daily} disabled={ro} aria-label="Daily limit"
            onChange={(e) => setDaily(e.target.value.replace(/[^\d.]/g, ''))} /></label>
        <label className="block text-sm"><span className="block text-xs font-medium text-glass-secondary mb-1">Monthly limit ({cur})</span>
          <input inputMode="decimal" className="glass-input w-full px-3 py-2 text-sm" value={monthly} disabled={ro} aria-label="Monthly limit"
            onChange={(e) => setMonthly(e.target.value.replace(/[^\d.]/g, ''))} /></label>
      </div>
      {!ro && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-xs text-glass-muted">Quick:</span>
          {PRESETS.map((v) => <button key={v} type="button" onClick={() => pick(v)} className="px-2.5 py-1 rounded-full text-xs font-semibold"
            style={Number(daily) === v ? { background: '#007AFF', color: '#fff' } : { background: 'rgba(0,122,255,0.10)', color: '#0062CC' }}>{money(v, cur, 0)}/day</button>)}
          <Btn className="ml-auto" disabled={!dirty || busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</Btn>
        </div>
      )}
      {ro && <div className="text-xs text-glass-muted">Only people who can approve ADS changes can edit these.</div>}
    </section>
  );
}

function Funds({ d, reload }) {
  const cur = d.account?.currency || 'INR';
  const f = d.funds;
  const add = async () => {
    const v = await promptDialog('How much did you add to Google Ads?', { message: `Amount in ${cur}. Used only to estimate how long the balance lasts.`, placeholder: 'e.g. 10000', required: true });
    if (v === null) return;
    const n = Number(String(v).replace(/[^\d.]/g, ''));
    if (await run(rpc('api_ads_funds_add', { p_amount: n }), 'Recorded.')) reload();
  };
  const show = f.low || f.estimate == null;
  return (
    <section className="glass-card p-4" data-testid="ap-funds" style={f.low ? { boxShadow: 'inset 0 0 0 1px rgba(255,149,0,0.6)' } : undefined}>
      <div className="flex flex-wrap items-center gap-3">
        <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center shrink-0" style={{ background: f.low ? 'rgba(255,149,0,0.16)' : 'rgba(52,199,89,0.14)', color: f.low ? '#B25E00' : '#1E7B34' }}>
          <Icon name={f.low ? 'alert' : 'cart'} size={20} /></span>
        <div className="flex-1 min-w-[12rem]">
          {f.estimate == null
            ? <><div className="font-bold text-glass-primary">Ad balance</div><div className="text-xs text-glass-secondary">Record each top-up and Autopilot will warn you before the money runs out.</div></>
            : <><div className="font-bold text-glass-primary">{f.low ? 'Add money to your Google Ads account' : `About ${money(Math.max(0, f.estimate), cur, 0)} left`}</div>
              <div className="text-xs text-glass-secondary">{f.low
                ? `Estimated ${money(Math.max(0, f.estimate), cur, 0)} left${f.days_left != null ? `, about ${Math.max(0, f.days_left)} day(s) of spend` : ''}. Ads stop when the balance runs out.`
                : `Estimate: ${money(f.added, cur, 0)} added since ${f.since}, minus ${money(f.spent_since, cur, 0)} spent${f.days_left != null ? ` · about ${f.days_left} days left` : ''}.`}</div></>}
        </div>
        <div className="flex gap-2">
          {show && <a href="https://ads.google.com/aw/billing/summary" target="_blank" rel="noreferrer" className="px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center gap-1.5"
            style={{ background: f.low ? '#FF9500' : 'rgba(118,118,128,0.12)', color: f.low ? '#fff' : '#1C1C1E' }}>Add funds <Icon name="external" size={14} /></a>}
          <Btn ghost onClick={add}>I added money</Btn>
        </div>
      </div>
    </section>
  );
}

function optionList(s) {
  const ops = s.proposal?.ops || [];
  const ids = [...new Set(ops.filter((o) => o.option != null).map((o) => String(o.option)))];
  const meta = Object.fromEntries((s.proposal?.options || []).map((o) => [String(o.id), o]));
  return ids.map((id) => ({ id, label: meta[id]?.label || ops.find((o) => String(o.option) === id)?.summary || id, reason: meta[id]?.reason }));
}

function Suggestion({ s, reload }) {
  const opts = useMemo(() => optionList(s), [s]);
  const [pick, setPick] = useState(() => new Set(opts.filter((o) => (s.proposal?.options || []).find((x) => String(x.id) === o.id)?.selected !== false).map((o) => o.id)));
  const [busy, setBusy] = useState(false);
  const shared = (s.proposal?.ops || []).filter((o) => o.option == null);
  const decide = async (action, note) => {
    setBusy(true);
    const r = await run(rpc('api_ads_suggestion_decide', { p_id: s.id, p_action: action, p_note: note ?? null, p_pick: opts.length ? [...pick] : null }));
    setBusy(false);
    if (r) {
      const blocked = (r.ops || []).filter((o) => o.status === 'blocked').length;
      showToast(action === 'accept' ? (blocked ? `Accepted; ${blocked} change(s) failed the checks and were not sent.` : 'Accepted.') : action === 'change' ? 'Sent to the agents.' : 'Dismissed.', blocked ? 'error' : 'success');
      reload();
    }
  };
  const change = async () => {
    const v = await promptDialog('What should change?', { placeholder: 'e.g. keep Jaipur, drop Lucknow', required: true, multiline: true });
    if (v !== null) decide('change', v);
  };
  return (
    <div className="glass-card p-3 space-y-2" data-testid="ap-suggestion">
      <div className="flex flex-wrap items-center gap-2"><Chip fg={BLUE[0]} bg={BLUE[1]}>{KIND[s.kind] || s.kind}</Chip><span className="font-semibold text-glass-primary">{s.title}</span>
        <span className="text-[11px] text-glass-muted ml-auto">{ago(s.created_at)}</span></div>
      {s.reason && <div className="text-sm text-glass-secondary whitespace-pre-line">{s.reason}</div>}
      {opts.length > 0 && (
        <div className="grid sm:grid-cols-2 gap-1.5">
          {opts.map((o) => (
            <label key={o.id} className="flex items-start gap-2 rounded-xl p-2 cursor-pointer" style={{ background: pick.has(o.id) ? 'rgba(0,122,255,0.08)' : 'rgba(118,118,128,0.08)' }}>
              <input type="checkbox" className="mt-0.5" checked={pick.has(o.id)} onChange={() => setPick((p) => { const n = new Set(p); n.has(o.id) ? n.delete(o.id) : n.add(o.id); return n; })} />
              <span className="text-sm"><span className="font-medium text-glass-primary">{o.label}</span>{o.reason && <span className="block text-[11px] text-glass-secondary">{o.reason}</span>}</span>
            </label>))}
        </div>)}
      {shared.length > 0 && <ul className="text-xs text-glass-secondary list-disc pl-5">{shared.slice(0, 8).map((o, i) => <li key={i}>{o.summary || o.kind}</li>)}{shared.length > 8 && <li>and {shared.length - 8} more</li>}</ul>}
      <div className="flex flex-wrap gap-2 pt-1">
        <Btn tone="#248A3D" disabled={busy || (opts.length > 0 && pick.size === 0)} onClick={() => decide('accept')}><Icon name="check" size={16} />Accept{opts.length > 0 ? ` (${pick.size})` : ''}</Btn>
        <Btn ghost disabled={busy} onClick={change}>Change</Btn>
        <Btn ghost disabled={busy} onClick={() => decide('dismiss')}>Dismiss</Btn>
      </div>
    </div>
  );
}

function Suggestions({ d, reload }) {
  const open = d.suggestions.filter((s) => s.status === 'open');
  const done = d.suggestions.filter((s) => s.status !== 'open');
  const [showDone, setShowDone] = useState(false);
  const TONE = { accepted: GREEN, changed: BLUE, dismissed: GREY, superseded: GREY };
  return (
    <section className="space-y-2" data-testid="ap-suggestions">
      <div className="flex items-center justify-between"><h3 className="font-bold text-glass-primary">Suggestions {open.length > 0 && <Chip fg="#fff" bg="#FF3B30">{open.length}</Chip>}</h3>
        {done.length > 0 && <button type="button" className="text-xs font-semibold" style={{ color: '#007AFF' }} onClick={() => setShowDone((v) => !v)}>{showDone ? 'Hide earlier' : `Earlier (${done.length})`}</button>}</div>
      {open.length === 0 && <div className="glass-card p-4 text-sm text-glass-secondary">No suggestions waiting. When the agents find something worth your choice (for example which cities to target), it shows here with the reason.</div>}
      {open.map((s) => <Suggestion key={s.id} s={s} reload={reload} />)}
      {showDone && done.map((s) => (
        <div key={s.id} className="glass-card p-3 flex flex-wrap items-center gap-2 text-sm">
          <Chip fg={(TONE[s.status] || GREY)[0]} bg={(TONE[s.status] || GREY)[1]}>{s.status}</Chip><span className="text-glass-primary">{s.title}</span>
          {s.user_note && <span className="text-xs text-glass-secondary">“{s.user_note}”</span>}<span className="text-[11px] text-glass-muted ml-auto">{ago(s.decided_at)}</span>
        </div>))}
    </section>
  );
}

function Tell({ d, reload }) {
  const [text, setText] = useState('');
  const [via, setVia] = useState('typed');
  const [listening, setListening] = useState(false);
  const [lang, setLang] = useState('en-IN');
  const rec = useRef(null);
  const SR = typeof window !== 'undefined' ? (window.SpeechRecognition || window.webkitSpeechRecognition) : null;
  useEffect(() => () => rec.current?.abort?.(), []);
  const listen = () => {
    if (!SR) { showToast('This browser cannot take voice input. Try Chrome, or type instead.', 'error'); return; }
    if (listening) { rec.current?.stop(); return; }
    const r = new SR();
    r.lang = lang; r.interimResults = true; r.continuous = false;
    const base = text ? `${text.trim()} ` : '';
    r.onresult = (e) => { setText(base + Array.from(e.results).map((x) => x[0].transcript).join(' ')); setVia('voice'); };
    r.onerror = (e) => { if (e.error !== 'aborted' && e.error !== 'no-speech') showToast(e.error === 'not-allowed' ? 'Allow the microphone to speak.' : `Voice input stopped (${e.error}).`, 'error'); };
    r.onend = () => setListening(false);
    rec.current = r; setListening(true); r.start();
  };
  const send = async () => {
    if (await run(rpc('api_ads_agent_instruct', { p_text: text, p_via: via }), 'Sent to the agents.')) { setText(''); setVia('typed'); reload(); }
  };
  const ST = { new: ['Waiting', AMBER], working: ['Working', BLUE], answered: ['Answered', GREEN], failed: ['Could not do', RED] };
  return (
    <section className="glass-card p-4 space-y-3" data-testid="ap-tell">
      <div><div className="font-bold text-glass-primary">Tell the agents</div>
        <div className="text-xs text-glass-secondary">Type or speak, in English or Hindi. For example: “Add Chandigarh and stop Punjab”, “Focus on DGCA ground classes this month”.</div></div>
      <textarea rows={3} className="glass-input w-full px-3 py-2 text-sm" value={text} maxLength={2000} aria-label="Instruction for the agents"
        placeholder={listening ? 'Listening…' : 'What should the agents do?'} onChange={(e) => { setText(e.target.value); if (!e.target.value) setVia('typed'); }} />
      <div className="flex flex-wrap items-center gap-2">
        <Btn tone={listening ? '#FF3B30' : '#5856D6'} onClick={listen} aria-pressed={listening}><Icon name="mic" size={16} />{listening ? 'Stop' : 'Speak'}</Btn>
        <select aria-label="Voice language" className="glass-input px-2 py-2 text-sm" value={lang} onChange={(e) => setLang(e.target.value)}>
          <option value="en-IN">English</option><option value="hi-IN">हिन्दी</option></select>
        <Btn className="ml-auto" disabled={text.trim().length < 2} onClick={send}><Icon name="send" size={16} />Send</Btn>
      </div>
      {d.instructions.length > 0 && (
        <ul className="space-y-2 pt-1">
          {d.instructions.slice(0, 6).map((i) => { const [l, t] = ST[i.status] || ST.new; return (
            <li key={i.id} className="rounded-xl p-2.5" style={{ background: 'rgba(118,118,128,0.08)' }}>
              <div className="flex items-start gap-2 text-sm"><Icon name={i.via === 'voice' ? 'mic' : 'form'} size={14} /><span className="flex-1 text-glass-primary">{i.body}</span><Chip fg={t[0]} bg={t[1]}>{l}</Chip></div>
              {i.answer && <div className="text-xs text-glass-secondary mt-1 pl-5 whitespace-pre-line">{i.answer}</div>}
              <div className="text-[11px] text-glass-muted pl-5">{ago(i.created_at)}</div>
            </li>); })}
        </ul>)}
    </section>
  );
}

function Activity({ d }) {
  const [f, setF] = useState('all');
  const items = useMemo(() => {
    const runs = d.runs.map((r) => ({ key: `r${r.id}`, at: r.created_at, who: ROLE[r.role] || r.role, text: r.summary || r.job || r.error || 'Working',
      err: r.status === 'failed' ? r.error : null, tone: RUN_TONE[r.status] || GREY, label: r.status === 'rejected' ? 'Rejected by Reviewer' : r.status,
      rejected: r.status === 'rejected', live: false, attempt: r.attempt }));
    const ops = d.ops.map((o) => ({ key: `o${o.id}`, at: o.created_at, who: o.by === 'agent' ? 'Agent change' : o.by === 'user' ? 'Your change' : 'System',
      text: o.summary || o.kind, err: o.status === 'blocked' ? (o.blockers || []).join(' · ') : o.error, tone: OP_TONE[o.status] || GREY,
      label: OP_LABEL[o.status] || o.status, rejected: o.status === 'blocked' || o.status === 'rejected', live: o.status === 'verified' }));
    return [...runs, ...ops].sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
      .filter((x) => f === 'all' || (f === 'live' && x.live) || (f === 'rejected' && x.rejected));
  }, [d, f]);
  return (
    <section className="space-y-2" data-testid="ap-activity">
      <div className="flex flex-wrap items-center justify-between gap-2"><h3 className="font-bold text-glass-primary">What the agents did</h3>
        <div className="flex gap-1 p-1 rounded-xl" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[['all', 'All'], ['live', 'Went live'], ['rejected', 'Stopped']].map(([v, l]) => (
            <button key={v} type="button" aria-pressed={f === v} onClick={() => setF(v)} className={`px-3 py-1.5 rounded-lg text-sm ${f === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
        </div></div>
      {items.length === 0 ? <div className="glass-card p-4 text-sm text-glass-secondary">{f === 'all' ? 'Nothing yet. Each step the agents take, every change the Reviewer stops, and everything that goes live is listed here.' : 'Nothing here yet.'}</div>
        : <div className="glass-card divide-y" style={{ borderColor: 'rgba(118,118,128,0.15)' }}>
          {items.slice(0, 60).map((x) => (
            <div key={x.key} className="p-3 flex items-start gap-3">
              <div className="flex-1 min-w-0">
                <div className="flex flex-wrap items-center gap-2"><span className="text-xs font-semibold text-glass-secondary">{x.who}{x.attempt > 1 ? ` · try ${x.attempt}` : ''}</span><Chip fg={x.tone[0]} bg={x.tone[1]}>{x.label}</Chip></div>
                <div className="text-sm text-glass-primary break-words">{x.text}</div>
                {x.err && <div className="text-xs mt-0.5 break-words" style={{ color: '#C4261D' }}>{x.err}</div>}
              </div>
              <span className="text-[11px] text-glass-muted whitespace-nowrap">{ago(x.at)}</span>
            </div>))}
        </div>}
    </section>
  );
}

export default function AdsAutopilot() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const load = useCallback(async () => { try { setD(await rpc('api_ads_autopilot')); setErr(''); } catch (e) { setErr(e.message); } }, []);
  useEffect(() => { load(); const t = setInterval(load, 30000); return () => clearInterval(t); }, [load]);
  if (err) return <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{err}</div>;
  if (!d) return <div className="text-center text-glass-muted py-10 text-sm">Loading…</div>;
  const stop = async () => {
    if (d.stopped) {
      if (await run(rpc('api_ads_autopilot_stop', { p_stop: false }), 'Resumed.')) load();
    } else if (await confirmDialog('Stop everything?', { message: 'Nothing will be sent to Google Ads or Meta until someone who can approve turns this off. Campaigns keep running as they are.', confirmText: 'Stop everything', danger: true })) {
      if (await run(rpc('api_ads_autopilot_stop', { p_stop: true }), 'Stopped. Nothing is being sent.')) load();
    }
  };
  const on = d.mode === 'auto' && !d.stopped;
  return (
    <div className="space-y-4" data-testid="autopilot">
      <section className="glass-card p-4 flex flex-wrap items-center gap-3" style={d.stopped ? { boxShadow: 'inset 0 0 0 1px rgba(255,59,48,0.55)' } : undefined}>
        <span className="h-11 w-11 rounded-[14px] inline-flex items-center justify-center shrink-0" style={{ background: on ? 'rgba(52,199,89,0.14)' : d.stopped ? 'rgba(255,59,48,0.12)' : 'rgba(118,118,128,0.14)', color: on ? '#1E7B34' : d.stopped ? '#C4261D' : '#636366' }}>
          <Icon name={d.stopped ? 'pause' : 'plane'} size={22} /></span>
        <div className="flex-1 min-w-[12rem]">
          <div className="font-bold text-glass-primary" data-testid="ap-state">{d.stopped ? 'Emergency stop is ON' : on ? 'Autopilot is flying' : 'Autopilot asks before acting'}</div>
          <div className="text-xs text-glass-secondary">{d.account ? `Google Ads ${d.account.name || d.account.external_id}${d.account.status !== 'connected' ? ` · ${d.account.status.replace(/_/g, ' ')}` : ''} · synced ${ago(d.account.last_ok_at) || 'never'}` : 'Connect a Google Ads account in More › Ad accounts.'}</div>
        </div>
        <Btn tone={d.stopped ? '#248A3D' : '#FF3B30'} onClick={stop} disabled={d.stopped && !d.can_approve}><Icon name={d.stopped ? 'play' : 'pause'} size={16} />{d.stopped ? 'Resume' : 'Stop everything'}</Btn>
      </section>
      <Funds d={d} reload={load} />
      <div className="grid lg:grid-cols-2 gap-4 items-start">
        <Limits d={d} reload={load} />
        <Tell d={d} reload={load} />
      </div>
      <Suggestions d={d} reload={load} />
      <Activity d={d} />
    </div>
  );
}
