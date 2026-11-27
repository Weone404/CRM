// WhatsApp > Flow & replies: what the bot says, step by step, and the words it reacts to. Everything here is stored in
// the database (wa_flow_step, wa_reply_rule) and used on the very next message. "Try it" runs the real flow without
// sending anything. How a reply is matched: STOP first, then the step's own buttons, then rules in this order:
// button > exact > contains > similar word (each on the current step first, then on any step). A typed answer is kept
// when the step asks a question (e.g. city). Not understood twice, or a question after the flow ended: a person takes over.
import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from '../icons';
import { Segmented, Switch } from '../ui/AppleControls';
import { confirmDialog } from '../ui/dialogs';
import { admin, Btn, Empty, ErrorBox, Field, More, Pill, rpc, run, Spinner, useLoad } from './kit';

const KINDS = [['text', 'Text'], ['buttons', 'Buttons (up to 3)'], ['list', 'List (up to 10)'], ['document', 'Brochure PDF']];
const ACTIONS = [['goto', 'Go to step'], ['handoff', 'Hand to a person'], ['book_counselling', 'Book free counselling'],
  ['send_brochure', 'Send brochure'], ['restart', 'Start again'], ['end', 'End politely'], ['optout', 'Stop messages (opt out)']];
const MATCH = [['button', 'Button tapped'], ['exact', 'Exactly'], ['contains', 'Contains'], ['synonym', 'Similar word']];
const actionLabel = (a) => (ACTIONS.find((x) => x[0] === a) || [a, a])[1];

export default function Flow({ manage }) {
  const [brand, setBrand] = useState('aviation');
  const [flow, reload, err] = useLoad(() => rpc('api_wa_flow', { p_brand: brand }), [brand]);
  const [editing, setEditing] = useState(null);
  const steps = flow?.steps || [];
  const rules = flow?.rules || [];
  const can = manage && flow?.can_manage;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="w-full sm:w-80"><Segmented label="Brand" value={brand} onChange={(b) => { setBrand(b); setEditing(null); }}
          options={[{ value: 'aviation', label: 'We One Aviation' }, { value: 'charter', label: 'Book My Charter' }]} /></div>
        <span className="text-sm text-glass-secondary">Use <code>{'{{name}}'}</code>, <code>{'{{counsellor_phone}}'}</code> and <code>{'{{brand}}'}</code> in any message.</span>
      </div>
      <ErrorBox error={err} onRetry={reload} />
      {!flow && !err && <div className="glass-card p-8 text-center"><Spinner /></div>}
      {flow && (
        <div className="grid xl:grid-cols-[1fr_380px] gap-4 items-start">
          <div className="space-y-4 min-w-0">
            <section className="glass-card p-4 space-y-2">
              <div className="flex items-center justify-between gap-2">
                <h2 className="text-lg font-semibold text-glass-primary">Steps</h2>
                {can && <Btn onClick={() => setEditing({ brand, key: '', kind: 'text', body: '', buttons: [], sort: (steps.at(-1)?.sort || 0) + 10 })}><Icon name="plus" size={15} />Step</Btn>}
              </div>
              {!steps.length && <Empty icon="zap" title="No steps yet">Add the first message the bot sends.</Empty>}
              <ol className="space-y-2">
                {steps.map((s, i) => (
                  <li key={s.id}>
                    {editing?.id === s.id ? <StepForm step={editing} steps={steps} onCancel={() => setEditing(null)} onSaved={() => { setEditing(null); reload(); }} />
                      : <StepCard s={s} n={i + 1} can={can} onEdit={() => setEditing({ ...s })} />}
                  </li>
                ))}
                {editing && !editing.id && <li><StepForm step={editing} steps={steps} onCancel={() => setEditing(null)} onSaved={() => { setEditing(null); reload(); }} /></li>}
              </ol>
            </section>
            <Rules rules={rules} steps={steps} brand={brand} can={can} reload={reload} />
          </div>
          <TryIt brand={brand} steps={steps} />
        </div>
      )}
    </div>
  );
}

function StepCard({ s, n, can, onEdit }) {
  return (
    <div className="rounded-2xl p-3" style={{ background: 'rgba(118,118,128,0.07)' }}>
      <div className="flex items-start gap-2">
        <span className="h-7 w-7 rounded-full text-[13px] font-bold inline-flex items-center justify-center shrink-0" style={{ background: s.is_start ? '#1FA855' : 'rgba(0,122,255,0.12)', color: s.is_start ? '#fff' : '#0A63CE' }}>{n}</span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="font-semibold text-glass-primary">{s.title || s.key}</span>
            <Pill>{(KINDS.find((k) => k[0] === s.kind) || [s.kind, s.kind])[1]}</Pill>
            {s.is_start && <Pill tone="green">First step</Pill>}
            {s.handoff && <Pill tone="orange">Hands to a person</Pill>}
            {s.capture && <Pill tone="blue">Keeps answer as “{s.capture}”</Pill>}
          </div>
          <p className="text-sm text-glass-secondary mt-1 whitespace-pre-wrap">{s.body}</p>
          {(s.buttons || []).length > 0 && (
            <div className="flex flex-wrap gap-1.5 mt-2">
              {s.buttons.map((b, i) => <span key={i} className="text-[12px] px-2 py-1 rounded-lg" style={{ background: '#fff', boxShadow: '0 0 0 1px rgba(0,0,0,0.06)' }}>
                {b.title} <span className="text-glass-secondary">→ {b.action && b.action !== 'goto' ? actionLabel(b.action) : b.goto || '?'}</span></span>)}
            </div>
          )}
          {(s.next_key || s.auto_next) && <div className="text-xs text-glass-secondary mt-1.5">{s.auto_next ? `Then sends: ${s.auto_next}` : `After the answer: ${s.next_key}`}</div>}
        </div>
        {can && <button type="button" onClick={onEdit} className="text-sm font-semibold shrink-0" style={{ color: '#007AFF' }}>Edit</button>}
      </div>
    </div>
  );
}

function StepForm({ step, steps, onCancel, onSaved }) {
  const [s, setS] = useState(step);
  const set = (k, v) => setS((x) => ({ ...x, [k]: v }));
  const others = steps.filter((x) => x.key !== s.key);
  const btnMax = s.kind === 'list' ? 10 : 3;
  const setBtn = (i, patch) => set('buttons', s.buttons.map((b, j) => (j === i ? { ...b, ...patch } : b)));
  const save = () => run(rpc('api_wa_step_save', { p: { ...s, buttons: (s.kind === 'buttons' || s.kind === 'list') ? s.buttons : [] } }), 'Step saved').then((r) => { if (r) onSaved(); });
  const del = async () => {
    if (!(await confirmDialog(`Delete step “${s.title || s.key}”?`, { danger: true, message: 'Buttons and rules that go to it will hand the chat to a person instead.' }))) return;
    if (await run(rpc('api_wa_step_delete', { p_id: s.id }), 'Step deleted')) onSaved();
  };
  return (
    <div className="rounded-2xl p-3 space-y-3" style={{ background: '#fff', boxShadow: '0 0 0 2px rgba(0,122,255,0.35)' }}>
      <div className="grid sm:grid-cols-2 gap-3">
        <Field label="Title" hint="Only your team sees this"><input className="glass-input w-full" value={s.title || ''} onChange={(e) => set('title', e.target.value)} maxLength={80} /></Field>
        <Field label="Step name" hint="small letters, numbers and _ (used by buttons and rules)">
          <input className="glass-input w-full font-mono" value={s.key} onChange={(e) => set('key', e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_'))} maxLength={40} />
        </Field>
      </div>
      <Field label="Type"><select className="glass-input w-full" value={s.kind} onChange={(e) => set('kind', e.target.value)}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
      <Field label={s.kind === 'document' ? 'Caption under the brochure' : 'Message'} hint={`${(s.body || '').length}/1024`}>
        <textarea className="glass-input w-full min-h-[90px]" value={s.body} onChange={(e) => set('body', e.target.value)} maxLength={1024} />
      </Field>
      {(s.kind === 'buttons' || s.kind === 'list') && (
        <div className="space-y-2">
          <div className="text-[13px] font-semibold">Options ({s.buttons.length}/{btnMax})</div>
          {s.buttons.map((b, i) => (
            <div key={i} className="grid grid-cols-1 sm:grid-cols-[1fr_1fr_auto] gap-2 items-center">
              <input className="glass-input" placeholder="Button text" value={b.title} maxLength={s.kind === 'list' ? 24 : 20} onChange={(e) => setBtn(i, { title: e.target.value, id: b.id || e.target.value.toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 30) })} />
              <select className="glass-input" value={b.action && b.action !== 'goto' ? b.action : `goto:${b.goto || ''}`}
                onChange={(e) => { const v = e.target.value; setBtn(i, v.startsWith('goto:') ? { action: 'goto', goto: v.slice(5) } : { action: v, goto: null }); }}>
                {others.map((o) => <option key={o.key} value={`goto:${o.key}`}>Go to: {o.title || o.key}</option>)}
                <option value="goto:">Go to: (pick a step)</option>
                {ACTIONS.filter(([a]) => a !== 'goto').map(([a, l]) => <option key={a} value={a}>{l}</option>)}
              </select>
              <button type="button" onClick={() => set('buttons', s.buttons.filter((_, j) => j !== i))} className="text-sm" style={{ color: '#FF3B30' }} aria-label="Remove option"><Icon name="trash" size={16} /></button>
            </div>
          ))}
          {s.buttons.length < btnMax && <Btn ghost onClick={() => set('buttons', [...s.buttons, { title: '', goto: others[0]?.key || null, action: 'goto' }])}><Icon name="plus" size={14} />Option</Btn>}
        </div>
      )}
      <More title="More: keep a typed answer, what comes next">
        <div className="grid sm:grid-cols-3 gap-3">
          <Field label="Keep the typed answer as" hint="e.g. city (leave empty if not a question)"><input className="glass-input w-full" value={s.capture || ''} onChange={(e) => set('capture', e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_'))} /></Field>
          <Field label="After the answer go to"><select className="glass-input w-full" value={s.next_key || ''} onChange={(e) => set('next_key', e.target.value)}><option value="">—</option>{others.map((o) => <option key={o.key} value={o.key}>{o.title || o.key}</option>)}</select></Field>
          <Field label="Then send right away"><select className="glass-input w-full" value={s.auto_next || ''} onChange={(e) => set('auto_next', e.target.value)}><option value="">—</option>{others.map((o) => <option key={o.key} value={o.key}>{o.title || o.key}</option>)}</select></Field>
        </div>
        <div className="flex flex-wrap gap-5 mt-3">
          <label className="flex items-center gap-2 text-sm"><Switch size="sm" on={!!s.handoff} onChange={(v) => set('handoff', v)} label="Hand to a person after this" />Hand to a person after this</label>
          <label className="flex items-center gap-2 text-sm"><Switch size="sm" on={!!s.is_start} onChange={(v) => set('is_start', v)} label="First step" />First step</label>
        </div>
      </More>
      <div className="flex flex-wrap gap-2 justify-end">
        {s.id && !s.is_start && <Btn ghost onClick={del}>Delete</Btn>}
        <Btn ghost onClick={onCancel}>Cancel</Btn>
        <Btn onClick={save} disabled={!s.key || !s.body?.trim()} busyText="Saving">Save step</Btn>
      </div>
    </div>
  );
}

function Rules({ rules, steps, brand, can, reload }) {
  const [edit, setEdit] = useState(null);
  const label = (k) => steps.find((s) => s.key === k)?.title || k;
  return (
    <section className="glass-card p-4 space-y-2">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold text-glass-primary">Words the bot reacts to</h2>
          <p className="text-xs text-glass-secondary">Add Hinglish and common spellings. STOP-type rules always win.</p>
        </div>
        {can && <Btn onClick={() => setEdit({ brand, step_key: '', match_type: 'contains', patterns: [], action: 'handoff', priority: 10, active: true })}><Icon name="plus" size={15} />Rule</Btn>}
      </div>
      {edit && !edit.id && <RuleForm r={edit} steps={steps} onDone={() => { setEdit(null); reload(); }} onCancel={() => setEdit(null)} />}
      <ul className="space-y-2">
        {rules.map((r) => (edit?.id === r.id ? <li key={r.id}><RuleForm r={edit} steps={steps} onDone={() => { setEdit(null); reload(); }} onCancel={() => setEdit(null)} /></li> : (
          <li key={r.id} className="rounded-xl p-3 flex flex-col sm:flex-row sm:items-center gap-2" style={{ background: 'rgba(118,118,128,0.07)', opacity: r.active ? 1 : 0.5 }}>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap gap-1 mb-1">
                {r.patterns.slice(0, 8).map((p) => <span key={p} className="text-[12px] px-2 py-0.5 rounded-full" style={{ background: '#fff' }}>{p}</span>)}
                {r.patterns.length > 8 && <span className="text-[12px] text-glass-secondary">+{r.patterns.length - 8}</span>}
              </div>
              <div className="text-xs text-glass-secondary">
                {(MATCH.find((m) => m[0] === r.match_type) || [])[1]} · {r.step_key ? `on “${label(r.step_key)}”` : 'any step'}{r.brand ? '' : ' · both brands'} → <b className="text-glass-primary">{actionLabel(r.action)}{r.goto_key ? `: ${label(r.goto_key)}` : ''}</b>
              </div>
            </div>
            {can && <button type="button" className="text-sm font-semibold shrink-0" style={{ color: '#007AFF' }} onClick={() => setEdit({ ...r, step_key: r.step_key || '' })}>Edit</button>}
          </li>
        )))}
      </ul>
    </section>
  );
}

function RuleForm({ r: init, steps, onDone, onCancel }) {
  const [r, setR] = useState({ ...init, words: (init.patterns || []).join(', ') });
  const set = (k, v) => setR((x) => ({ ...x, [k]: v }));
  const save = () => run(rpc('api_wa_rule_save', { p: { ...r, patterns: r.words.split(',').map((w) => w.trim()).filter(Boolean) } }), 'Rule saved').then((x) => { if (x) onDone(); });
  const del = async () => { if (await confirmDialog('Delete this rule?', { danger: true })) { if (await run(rpc('api_wa_rule_delete', { p_id: r.id }), 'Rule deleted')) onDone(); } };
  return (
    <div className="rounded-2xl p-3 space-y-3" style={{ background: '#fff', boxShadow: '0 0 0 2px rgba(0,122,255,0.35)' }}>
      <Field label="Words or phrases" hint="Separate with commas, e.g. fees, fee, kitna, how much"><input className="glass-input w-full" value={r.words} onChange={(e) => set('words', e.target.value)} /></Field>
      <div className="grid sm:grid-cols-3 gap-3">
        <Field label="Match"><select className="glass-input w-full" value={r.match_type} onChange={(e) => set('match_type', e.target.value)}>{MATCH.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
        <Field label="Only on step"><select className="glass-input w-full" value={r.step_key || ''} onChange={(e) => set('step_key', e.target.value)}><option value="">Any step</option>{steps.map((s) => <option key={s.key} value={s.key}>{s.title || s.key}</option>)}</select></Field>
        <Field label="Then"><select className="glass-input w-full" value={r.action} onChange={(e) => set('action', e.target.value)}>{ACTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
      </div>
      {r.action === 'goto' && <Field label="Go to step"><select className="glass-input w-full" value={r.goto_key || ''} onChange={(e) => set('goto_key', e.target.value)}><option value="">Pick a step</option>{steps.map((s) => <option key={s.key} value={s.key}>{s.title || s.key}</option>)}</select></Field>}
      <Field label="Reply first (optional)" hint="Sent before the step or the hand-off. Never put fees here."><textarea className="glass-input w-full" value={r.reply_text || ''} onChange={(e) => set('reply_text', e.target.value)} maxLength={1000} /></Field>
      <div className="flex flex-wrap items-center gap-4">
        <label className="flex items-center gap-2 text-sm"><Switch size="sm" on={r.active !== false} onChange={(v) => set('active', v)} label="Active" />Active</label>
        <label className="flex items-center gap-2 text-sm">Priority <input type="number" className="glass-input w-20" value={r.priority ?? 0} onChange={(e) => set('priority', Number(e.target.value) || 0)} /></label>
        <span className="flex-1" />
        {r.id && <Btn ghost onClick={del}>Delete</Btn>}
        <Btn ghost onClick={onCancel}>Cancel</Btn>
        <Btn onClick={save} disabled={!r.words.trim()} busyText="Saving">Save rule</Btn>
      </div>
    </div>
  );
}

// Runs the real flow (wa-admin "simulate") without sending or saving anything.
function TryIt({ brand, steps }) {
  const [log, setLog] = useState([]);
  const [state, setState] = useState({ step: null, miss: 0, opted_out: false });
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const box = useRef(null);
  useEffect(() => { setLog([]); setState({ step: null, miss: 0, opted_out: false }); }, [brand]);
  useEffect(() => { if (box.current) box.current.scrollTop = box.current.scrollHeight; }, [log]);
  const lastButtons = useMemo(() => { for (let i = log.length - 1; i >= 0; i--) if (log[i].who === 'bot') return log[i].buttons || []; return []; }, [log]);
  const say = async ({ text: t, button }) => {
    if (busy) return;
    setBusy(true);
    setLog((l) => [...l, { who: 'you', body: t || button }]);
    try {
      const d = await admin('simulate', { brand, step: state.step, miss: state.miss, opted_out: state.opted_out, text: t, button });
      const add = d.out.map((o) => ({ who: 'bot', body: o.body || o.caption || (o.type === 'document' ? `📄 ${o.filename}` : ''), buttons: (o.buttons || o.rows || []).map((b) => b.title) }));
      const ev = (d.events || []).map((e) => ({ who: 'sys', body: e.kind === 'handoff' ? 'A person takes over this chat now' : e.kind === 'counselling_requested' ? 'Counselling request: the team gets an alert' : e.kind.replace(/_/g, ' ') }));
      setLog((l) => [...l, ...add, ...ev]);
      setState((s) => ({ step: d.patch.current_step ?? s.step, miss: d.patch.miss_count ?? s.miss,
        opted_out: d.patch.opted_out ? true : d.patch.opted_in ? false : s.opted_out, human: d.patch.status === 'human' }));
    } catch (e) { setLog((l) => [...l, { who: 'sys', body: e.message }]); }
    finally { setBusy(false); }
  };
  return (
    <section className="glass-card p-4 space-y-2 xl:sticky xl:top-20">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-lg font-semibold text-glass-primary">Try it</h2>
        <button type="button" className="text-sm font-semibold" style={{ color: '#007AFF' }} onClick={() => { setLog([]); setState({ step: null, miss: 0, opted_out: false }); }}>Restart</button>
      </div>
      <div className="flex items-center gap-2 text-xs text-glass-secondary">
        Start at
        <select className="glass-input py-1 text-xs" value={state.step || ''} onChange={(e) => setState({ step: e.target.value || null, miss: 0, opted_out: false })}>
          <option value="">They write first</option>
          {steps.map((s) => <option key={s.key} value={s.key}>After: {s.title || s.key}</option>)}
        </select>
      </div>
      <div ref={box} className="rounded-2xl p-2.5 space-y-1.5 h-[340px] overflow-y-auto" style={{ background: 'rgba(118,118,128,0.07)' }}>
        {!log.length && <div className="text-sm text-glass-secondary p-2">Type what a lead might write, like “hi”, “fees kitna hai” or “Mohali”. Nothing is sent.</div>}
        {log.map((m, i) => (m.who === 'sys' ? <div key={i} className="text-center text-[11px] font-semibold" style={{ color: '#B25E00' }}>{m.body}</div> : (
          <div key={i} className={`flex ${m.who === 'you' ? 'justify-start' : 'justify-end'}`}>
            <div className="max-w-[85%] rounded-2xl px-3 py-1.5 text-[13px] whitespace-pre-wrap" style={{ background: m.who === 'you' ? '#fff' : '#DCF8C6' }}>
              {m.body}
              {m.buttons?.length > 0 && <div className="flex flex-wrap gap-1 mt-1">{m.buttons.map((b) => <span key={b} className="text-[11px] px-1.5 py-0.5 rounded-full" style={{ background: 'rgba(0,122,255,0.1)', color: '#0A63CE' }}>{b}</span>)}</div>}
            </div>
          </div>
        )))}
        {busy && <div className="text-center"><Spinner /></div>}
      </div>
      {lastButtons.length > 0 && <div className="flex flex-wrap gap-1.5">{lastButtons.map((b) => <button key={b} type="button" disabled={busy} onClick={() => say({ button: b })} className="text-[13px] px-3 py-1.5 rounded-full font-semibold" style={{ background: 'rgba(0,122,255,0.1)', color: '#0A63CE' }}>{b}</button>)}</div>}
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (text.trim()) { say({ text }); setText(''); } }}>
        <input className="glass-input flex-1" placeholder="Type as the lead" value={text} onChange={(e) => setText(e.target.value)} />
        <button type="submit" className="glass-btn px-3" disabled={!text.trim() || busy} aria-label="Send"><Icon name="send" size={16} /></button>
      </form>
      {state.human && <div className="text-xs text-glass-secondary">In real chats the bot now stays quiet until someone presses “Hand back to bot”.</div>}
    </section>
  );
}
