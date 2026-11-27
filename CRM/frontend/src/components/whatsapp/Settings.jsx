// WhatsApp > Settings: go live, test numbers, which leads get a welcome, timing, brochure, templates, team access.
// Switches save at once; text fields save with "Save changes". Going live is only possible once Setup is complete.
import { useEffect, useRef, useState } from 'react';
import Icon from '../icons';
import { Switch } from '../ui/AppleControls';
import { confirmDialog } from '../ui/dialogs';
import { Btn, ErrorBox, Field, More, rpc, run, Spinner, useLoad } from './kit';

const SOURCES = [['website', 'Website enquiries', 'weoneaviation.in / .com, pilotschool.in, Flying Star'], ['meta_form', 'Meta lead forms', 'Facebook and Instagram ads'],
  ['google', 'Google', 'Google Ads and Google enquiries'], ['charter', 'Book My Charter', 'Charter enquiries (Charter welcome)'],
  ['justdial', 'JustDial', 'They enquired on JustDial, not with you directly: off is safer'],
  ['whatsapp_inbound', 'People who write to the number', 'Become a lead in Leads automatically'], ['ctwa', 'Click-to-WhatsApp ads', 'They already wrote first; leave off']];
const TPL_SLOTS = [['aviation', 'Welcome: We One Aviation'], ['charter', 'Welcome: Book My Charter'], ['justdial', 'Welcome: JustDial'], ['followup_1', 'Follow-up 1'], ['followup_2', 'Follow-up 2']];

const merge = (a, b) => { const o = { ...a }; for (const [k, v] of Object.entries(b || {})) o[k] = v && typeof v === 'object' && !Array.isArray(v) ? { ...(a?.[k] || {}), ...v } : v; return o; };

export default function Settings({ isAdmin, onChange }) {
  const [server, reload, err] = useLoad(() => rpc('api_wa_settings'), []);
  const [over, setOver] = useState({});               // switches flip on screen at once, before the server answers
  const seq = useRef(0);
  const s = server ? merge(server, over) : null;
  const [tpls] = useLoad(() => rpc('api_wa_templates'), []);
  const [f, setF] = useState(null);
  useEffect(() => { if (server) setF({ counsellor_phone: s.counsellor_phone, brochure_url: s.brochure_url || '', brochure_name: s.brochure_name,
    quiet_start: String(s.quiet_start).slice(0, 5), quiet_end: String(s.quiet_end).slice(0, 5), followup_hours: (s.followup_hours || []).join(', '),
    max_followups: s.max_followups, daily_new_contact_cap: s.daily_new_contact_cap, rates: { ...s.rates } }); }, [server]); // eslint-disable-line react-hooks/exhaustive-deps
  if (err && !s) return <ErrorBox error={err} onRetry={reload} />;
  if (!s || !f) return <div className="glass-card p-8 text-center"><Spinner /></div>;
  const save = (p, msg = 'Saved') => {
    const my = ++seq.current;
    setOver((o) => merge(o, p));
    return run(rpc('api_wa_settings_save', { p }), msg).then(async (r) => {
      if (r) { await reload(); onChange?.(); }
      if (my === seq.current) setOver({});            // the latest change is saved (or failed): show what the server has
      return r;
    });
  };
  const dirty = JSON.stringify(f) !== JSON.stringify({ counsellor_phone: s.counsellor_phone, brochure_url: s.brochure_url || '', brochure_name: s.brochure_name,
    quiet_start: String(s.quiet_start).slice(0, 5), quiet_end: String(s.quiet_end).slice(0, 5), followup_hours: (s.followup_hours || []).join(', '),
    max_followups: s.max_followups, daily_new_contact_cap: s.daily_new_contact_cap, rates: { ...s.rates } });
  const saveFields = () => save({ ...f, followup_hours: f.followup_hours.split(',').map((x) => Number(x.trim())).filter((x) => x > 0),
    max_followups: Number(f.max_followups), daily_new_contact_cap: Number(f.daily_new_contact_cap) }, 'Settings saved');
  const approved = (tpls?.templates || []).filter((t) => t.meta_status === 'approved' || t.meta_status === 'pending' || t.meta_status === 'draft');

  return (
    <div className="space-y-4 pb-20">
      <section className="glass-card p-4 space-y-4">
        <Row title="Live" hint={s.ready_to_go_live || s.enabled ? 'New leads get the welcome automatically.' : 'Finish Setup first.'}>
          <Switch on={s.enabled} disabled={!s.ready_to_go_live && !s.enabled} label="Live" onChange={async (v) => {
            if (!v && !(await confirmDialog('Stop welcoming new leads?', { message: 'Chats in progress keep working. You can go live again any time.' }))) return;
            await save({ enabled: v }, v ? 'WhatsApp is live' : 'Stopped');
          }} />
        </Row>
        <Row title="Test mode" hint="Only the test numbers below get messages. Turn off to message every new lead.">
          <Switch on={s.test_mode} label="Test mode" onChange={(v) => save({ test_mode: v }, v ? 'Test mode on' : 'Test mode off: every new lead gets messages')} />
        </Row>
        <Row title="Pause everything" hint="Stops the bot and follow-ups at once. People can still reply by hand from Inbox." danger>
          <Switch on={s.pause_all} label="Pause everything" onChange={(v) => save({ pause_all: v }, v ? 'Paused' : 'Running again')} />
        </Row>
      </section>

      <section className="glass-card p-4 space-y-2">
        <h2 className="font-semibold text-glass-primary">Test numbers</h2>
        <TestNumbers list={s.test_numbers || []} save={save} />
      </section>

      <section className="glass-card p-4 space-y-3">
        <h2 className="font-semibold text-glass-primary">Which new leads get a welcome</h2>
        {SOURCES.map(([k, label, hint]) => (
          <Row key={k} title={label} hint={hint}>
            <Switch size="sm" on={!!s.auto_sources?.[k]} label={label} onChange={(v) => save({ auto_sources: { [k]: v } }, `${label}: ${v ? 'on' : 'off'}`)} />
          </Row>
        ))}
      </section>

      <section className="glass-card p-4 space-y-3">
        <h2 className="font-semibold text-glass-primary">Timing and content</h2>
        <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-3">
          <Field label="Quiet from" hint="No follow-ups (India time)"><input type="time" className="glass-input w-full" value={f.quiet_start} onChange={(e) => setF({ ...f, quiet_start: e.target.value })} /></Field>
          <Field label="Quiet until"><input type="time" className="glass-input w-full" value={f.quiet_end} onChange={(e) => setF({ ...f, quiet_end: e.target.value })} /></Field>
          <Field label="Follow-ups after (hours)" hint="If they never replied, e.g. 24, 72"><input className="glass-input w-full" value={f.followup_hours} onChange={(e) => setF({ ...f, followup_hours: e.target.value })} /></Field>
          <Field label="Most follow-ups"><select className="glass-input w-full" value={f.max_followups} onChange={(e) => setF({ ...f, max_followups: e.target.value })}>{[0, 1, 2, 3].map((n) => <option key={n} value={n}>{n}</option>)}</select></Field>
          <Field label="New people per day" hint="Meta's start limit is 250"><input type="number" min="1" className="glass-input w-full" value={f.daily_new_contact_cap} onChange={(e) => setF({ ...f, daily_new_contact_cap: e.target.value })} /></Field>
          <Field label="Counsellor phone" hint="Used as {{counsellor_phone}}"><input className="glass-input w-full" inputMode="tel" value={f.counsellor_phone} onChange={(e) => setF({ ...f, counsellor_phone: e.target.value })} /></Field>
          <Field label="Brochure PDF link" hint="Public https link to the PDF"><input className="glass-input w-full" value={f.brochure_url} onChange={(e) => setF({ ...f, brochure_url: e.target.value })} placeholder="https://…/brochure.pdf" /></Field>
          <Field label="Brochure file name"><input className="glass-input w-full" value={f.brochure_name} onChange={(e) => setF({ ...f, brochure_name: e.target.value })} /></Field>
        </div>
        <More title="Meta prices used for the cost estimate (₹ per delivered message)">
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-2">
            {[['utility', 'Utility'], ['marketing', 'Marketing'], ['service', 'Reply'], ['free_service', 'Free replies / month'], ['gst', 'GST %']].map(([k, l]) => (
              <Field key={k} label={l}><input type="number" step="0.0001" className="glass-input w-full" value={f.rates[k] ?? ''} onChange={(e) => setF({ ...f, rates: { ...f.rates, [k]: Number(e.target.value) } })} /></Field>
            ))}
          </div>
          <p className="text-xs text-glass-secondary mt-2">India rates from 1 Oct 2026: marketing ₹0.8631, utility and replies ₹0.115 (1,000 replies a month free per number), plus GST. Check WhatsApp Manager for your exact rates.</p>
        </More>
      </section>

      <section className="glass-card p-4 space-y-3">
        <h2 className="font-semibold text-glass-primary">Which template is used</h2>
        <div className="grid sm:grid-cols-2 gap-3">
          {TPL_SLOTS.map(([k, l]) => (
            <Field key={k} label={l}>
              <select className="glass-input w-full" value={s.templates?.[k] || ''} onChange={(e) => save({ templates: { [k]: e.target.value } }, `${l}: ${e.target.value || 'none'}`)}>
                <option value="">None</option>
                {approved.map((t) => <option key={t.id} value={t.name}>{t.name}{t.meta_status !== 'approved' ? ` (${t.meta_status})` : ''}</option>)}
              </select>
            </Field>
          ))}
        </div>
      </section>

      {isAdmin && <Team />}

      {dirty && (
        <div className="fixed bottom-20 lg:bottom-6 left-1/2 -translate-x-1/2 z-30 glass-strong px-4 py-3 flex items-center gap-3 shadow-lg rounded-2xl">
          <span className="text-sm font-semibold">Unsaved changes</span>
          <Btn ghost onClick={() => reload()}>Undo</Btn>
          <Btn onClick={saveFields} busyText="Saving">Save changes</Btn>
        </div>
      )}
    </div>
  );
}

function Row({ title, hint, children, danger }) {
  return (
    <div className="flex items-center gap-3">
      <div className="min-w-0 flex-1">
        <div className="font-semibold" style={{ color: danger ? '#C4291F' : undefined }}>{title}</div>
        {hint && <div className="text-xs text-glass-secondary">{hint}</div>}
      </div>
      {children}
    </div>
  );
}

function TestNumbers({ list, save }) {
  const [v, setV] = useState('');
  const add = () => save({ test_numbers: [...list, v.trim()] }, 'Test number added').then((r) => { if (r) setV(''); });
  return (
    <>
      <div className="flex flex-wrap gap-2">
        {list.map((n) => (
          <span key={n} className="inline-flex items-center gap-1 pl-3 pr-1 py-1 rounded-full text-sm" style={{ background: 'rgba(0,122,255,0.1)', color: '#0A63CE' }}>
            +{n}
            <button type="button" aria-label={`Remove ${n}`} className="h-6 w-6 rounded-full inline-flex items-center justify-center" onClick={() => save({ test_numbers: list.filter((x) => x !== n) }, 'Removed')}><Icon name="close" size={13} /></button>
          </span>
        ))}
        {!list.length && <span className="text-sm text-glass-secondary">None yet. Add your own phone to test.</span>}
      </div>
      <div className="flex gap-2">
        <input className="glass-input flex-1" inputMode="tel" placeholder="10-digit mobile" value={v} onChange={(e) => setV(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && v.trim()) add(); }} />
        <Btn disabled={!v.trim()} onClick={add}>Add</Btn>
      </div>
    </>
  );
}

function Team() {
  const [list, reload, err] = useLoad(() => rpc('api_wa_access_list'), []);
  const set = (e, on, manage) => run(rpc('api_wa_access_set', { p_employee: e.id, p_on: on, p_manage: manage }), 'Access updated').then(reload);
  return (
    <section className="glass-card p-4 space-y-2">
      <h2 className="font-semibold text-glass-primary">Who can open WhatsApp</h2>
      <p className="text-xs text-glass-secondary">Admin always can. “Chats” lets someone read and reply; “Manage” adds Setup, Settings, Flow and Templates.</p>
      <ErrorBox error={err} onRetry={reload} />
      <ul>
        {(list || []).map((e) => (
          <li key={e.id} className="flex items-center gap-3 py-2" style={{ borderBottom: '1px solid var(--hairline)' }}>
            <div className="min-w-0 flex-1"><div className="font-medium truncate">{e.name}</div><div className="text-xs text-glass-secondary">{e.department || '—'}</div></div>
            <label className="flex items-center gap-2 text-xs">Chats<Switch size="sm" on={e.has_access} label={`${e.name}: chats`} onChange={(v) => set(e, v, false)} /></label>
            <label className="flex items-center gap-2 text-xs">Manage<Switch size="sm" on={e.can_manage} disabled={!e.has_access} label={`${e.name}: manage`} onChange={(v) => set(e, true, v)} /></label>
          </li>
        ))}
      </ul>
    </section>
  );
}
