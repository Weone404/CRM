// WhatsApp > Templates: the only messages WhatsApp lets a business send first (welcome, follow-ups) or after 24 hours.
// Meta approves each one (usually minutes, up to 24 hours). {{1}} becomes the lead's first name.
// Utility templates (a reply to their enquiry) cost about ₹0.115; marketing templates (follow-ups) about ₹0.86, and
// Meta limits how many marketing messages one person gets, so keep follow-ups few and useful. Never mention fees.
import { useState } from 'react';
import Icon from '../icons';
import { confirmDialog } from '../ui/dialogs';
import { showToast } from '../../utils/toast';
import { admin, ago, Btn, Empty, ErrorBox, Field, Pill, rpc, run, Spinner, useLoad } from './kit';

const PURPOSE = [['aviation', 'Welcome: We One Aviation'], ['charter', 'Welcome: Book My Charter'], ['justdial', 'Welcome: JustDial'],
  ['followup_1', 'Follow-up 1'], ['followup_2', 'Follow-up 2'], ['other', 'Other (send by hand)']];
const STATE = { approved: ['Approved', 'green'], pending: ['Waiting for Meta', 'orange'], in_appeal: ['In appeal', 'orange'], rejected: ['Rejected', 'red'],
  draft: ['Draft (not sent to Meta)', 'gray'], paused: ['Paused by Meta', 'red'], disabled: ['Disabled by Meta', 'red'] };

export default function Templates({ manage }) {
  const [data, reload, err] = useLoad(() => rpc('api_wa_templates'), []);
  const [edit, setEdit] = useState(null);
  const list = data?.templates || [];
  const can = manage && data?.can_manage;
  const drafts = list.filter((t) => ['draft', 'rejected'].includes(t.meta_status)).length;
  const submit = async (names) => {
    const r = await admin('templates_submit', names ? { names } : {});
    const bad = r.results.filter((x) => x.status === 'REJECTED');
    showToast(bad.length ? `${r.submitted - bad.length} sent, ${bad.length} refused: ${bad[0].reason}` : `${r.submitted} sent to Meta for approval`, bad.length ? 'error' : 'success');
    reload();
  };
  const sync = async () => { const r = await admin('templates_sync'); showToast(r.detail, 'success'); reload(); };

  return (
    <div className="space-y-4">
      <div className="glass-card p-4 flex flex-col sm:flex-row sm:items-center gap-3">
        <div className="flex-1 text-sm text-glass-secondary">Templates start conversations. Meta checks each one before it can be used. <b className="text-glass-primary">{'{{1}}'}</b> is the lead's first name.</div>
        <div className="flex flex-wrap gap-2">
          <Btn ghost onClick={sync} busyText="Checking">Check status with Meta</Btn>
          {can && drafts > 0 && <Btn onClick={() => submit()} busyText="Sending">Submit {drafts} to Meta</Btn>}
          {can && <Btn ghost onClick={() => setEdit({ name: '', category: 'UTILITY', purpose: 'other', body: '', footer: 'We One Aviation', buttons: [] })}><Icon name="plus" size={15} />Template</Btn>}
        </div>
      </div>
      <ErrorBox error={err} onRetry={reload} />
      {!data && !err && <div className="glass-card p-8 text-center"><Spinner /></div>}
      {edit && !edit.id && <TemplateForm t={edit} onDone={() => { setEdit(null); reload(); }} onCancel={() => setEdit(null)} />}
      {data && !list.length && <div className="glass-card"><Empty icon="form" title="No templates">Add one, or run the database setup again to get the starter set.</Empty></div>}
      <div className="grid md:grid-cols-2 gap-3">
        {list.map((t) => (edit?.id === t.id ? <div key={t.id} className="md:col-span-2"><TemplateForm t={edit} onDone={() => { setEdit(null); reload(); }} onCancel={() => setEdit(null)} /></div> : (
          <article key={t.id} className="glass-card p-4 flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="font-mono text-sm font-semibold text-glass-primary break-all">{t.name}</span>
              <Pill tone={(STATE[t.meta_status] || STATE.draft)[1]}>{(STATE[t.meta_status] || [t.meta_status])[0]}</Pill>
              <Pill tone={t.category === 'MARKETING' ? 'purple' : 'blue'}>{t.category === 'MARKETING' ? 'Marketing' : 'Utility'}</Pill>
            </div>
            <div className="text-xs text-glass-secondary">{(PURPOSE.find((p) => p[0] === t.purpose) || [0, t.purpose])[1]} · {t.language}{t.synced_at ? ` · checked ${ago(t.synced_at)}` : ''}</div>
            <div className="rounded-2xl px-3 py-2 text-[14px] whitespace-pre-wrap" style={{ background: '#DCF8C6' }}>
              {t.body.replace(/\{\{1\}\}/g, 'Rahul')}
              {t.footer && <div className="text-[11px] text-glass-secondary mt-1">{t.footer}</div>}
            </div>
            {(t.buttons || []).length > 0 && <div className="flex flex-wrap gap-1.5">{t.buttons.map((b) => <span key={b} className="text-[12px] px-2 py-1 rounded-lg" style={{ background: 'rgba(0,122,255,0.1)', color: '#0A63CE' }}>{b}</span>)}</div>}
            {t.rejection_reason && <div className="text-sm" style={{ color: '#C4291F' }}>Meta: {t.rejection_reason}</div>}
            {can && (
              <div className="flex flex-wrap gap-2 mt-auto pt-1">
                {['draft', 'rejected'].includes(t.meta_status) && <Btn onClick={() => submit([t.name])} busyText="Sending">Submit to Meta</Btn>}
                {['draft', 'rejected'].includes(t.meta_status) && <Btn ghost onClick={() => setEdit({ ...t })}>Edit</Btn>}
                {['approved', 'pending'].includes(t.meta_status) && <Btn ghost onClick={() => setEdit({ ...t, id: undefined, name: `${t.name}_v2`, meta_status: 'draft' })}>Copy as new</Btn>}
                {['draft', 'rejected'].includes(t.meta_status) && <Btn ghost onClick={async () => { if (await confirmDialog(`Delete ${t.name}?`, { danger: true })) { await run(rpc('api_wa_template_delete', { p_id: t.id }), 'Deleted'); reload(); } }}>Delete</Btn>}
              </div>
            )}
          </article>
        )))}
      </div>
    </div>
  );
}

function TemplateForm({ t: init, onDone, onCancel }) {
  const [t, setT] = useState(init);
  const set = (k, v) => setT((x) => ({ ...x, [k]: v }));
  const save = () => run(rpc('api_wa_template_save', { p: { ...t, buttons: (t.buttons || []).filter((b) => b.trim()) } }), 'Template saved').then((r) => { if (r) onDone(); });
  const fees = /fee|₹|rs\.?\s?\d|price|cost/i.test(t.body);
  return (
    <div className="glass-card p-4 space-y-3" style={{ boxShadow: '0 0 0 2px rgba(0,122,255,0.35)' }}>
      <div className="grid sm:grid-cols-3 gap-3">
        <Field label="Name" hint="small letters, numbers and _"><input className="glass-input w-full font-mono" value={t.name} onChange={(e) => set('name', e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_'))} /></Field>
        <Field label="Type" hint="Reply to their enquiry = Utility; offers and reminders = Marketing">
          <select className="glass-input w-full" value={t.category} onChange={(e) => set('category', e.target.value)}><option value="UTILITY">Utility</option><option value="MARKETING">Marketing</option></select>
        </Field>
        <Field label="Used for"><select className="glass-input w-full" value={t.purpose} onChange={(e) => set('purpose', e.target.value)}>{PURPOSE.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
      </div>
      <Field label="Message" hint={`${t.body.length}/1024 · {{1}} = first name`}><textarea className="glass-input w-full min-h-[110px]" value={t.body} onChange={(e) => set('body', e.target.value)} maxLength={1024} /></Field>
      {fees && <div className="text-sm rounded-xl p-2" style={{ background: 'rgba(255,149,0,0.12)', color: '#B25E00' }}>Fees or prices are not to be mentioned in WhatsApp messages yet.</div>}
      <div className="grid sm:grid-cols-2 gap-3">
        <Field label="Footer (optional)"><input className="glass-input w-full" value={t.footer || ''} onChange={(e) => set('footer', e.target.value)} maxLength={60} /></Field>
        <Field label="Quick-reply buttons (up to 3, 25 characters)" hint="Use the same words as the first step's buttons, so taps continue the flow">
          <div className="space-y-1.5">
            {[0, 1, 2].map((i) => <input key={i} className="glass-input w-full" value={t.buttons?.[i] || ''} maxLength={25} placeholder={`Button ${i + 1}`}
              onChange={(e) => { const b = [...(t.buttons || [])]; b[i] = e.target.value; set('buttons', b); }} />)}
          </div>
        </Field>
      </div>
      <div className="flex justify-end gap-2"><Btn ghost onClick={onCancel}>Cancel</Btn><Btn onClick={save} disabled={!t.name || !t.body.trim()} busyText="Saving">Save draft</Btn></div>
    </div>
  );
}
