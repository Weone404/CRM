// WhatsApp > Contacts: everyone the CRM knows on WhatsApp, how they agreed to messages, and who asked to stop.
// Opting someone back in needs a reason (how they agreed again), and it is logged.
import { useEffect, useState } from 'react';
import Icon from '../icons';
import { navigate } from '../../utils/route';
import { promptDialog, confirmDialog } from '../ui/dialogs';
import { ago, Btn, Empty, ErrorBox, phoneOf, Pill, rpc, run, SOURCE, Spinner, useLoad } from './kit';

const FILTERS = [['all', 'Everyone'], ['opted_in', 'Can message'], ['opted_out', 'Asked to stop'], ['unreachable', 'Not on WhatsApp']];

export default function Contacts() {
  const [filter, setFilter] = useState('all');
  const [q, setQ] = useState('');
  const [dq, setDq] = useState('');
  useEffect(() => { const t = setTimeout(() => setDq(q), 300); return () => clearTimeout(t); }, [q]);
  const [rows, reload, err, loading] = useLoad(() => rpc('api_wa_contacts', { p_search: dq || null, p_filter: filter, p_limit: 200 }), [dq, filter]);

  const optOut = async (c) => {
    if (!(await confirmDialog(`Stop all WhatsApp messages to ${c.name || phoneOf(c)}?`, { danger: true, confirmText: 'Stop messages' }))) return;
    await run(rpc('api_wa_contact_optout', { p_contact: c.id, p_out: true, p_reason: 'Set by staff' }), 'Opted out');
    reload();
  };
  const optIn = async (c) => {
    const why = await promptDialog('How did they agree to messages again?', { placeholder: 'e.g. Asked on a call today to get WhatsApp updates', required: true });
    if (!why) return;
    await run(rpc('api_wa_contact_optout', { p_contact: c.id, p_out: false, p_reason: why }), 'Opted in again');
    reload();
  };

  return (
    <div className="glass-card p-0 overflow-hidden">
      <div className="p-3 flex flex-col sm:flex-row gap-2 border-b" style={{ borderColor: 'var(--hairline)' }}>
        <div className="relative flex-1">
          <span className="absolute left-3 top-1/2 -translate-y-1/2 text-glass-secondary"><Icon name="search" size={16} /></span>
          <input className="glass-input w-full pl-9" placeholder="Search name or number" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search contacts" />
        </div>
        <div className="flex gap-1.5 overflow-x-auto">
          {FILTERS.map(([id, label]) => (
            <button key={id} type="button" onClick={() => setFilter(id)} className="px-3 py-1.5 rounded-full text-[13px] font-semibold whitespace-nowrap"
              style={filter === id ? { background: '#007AFF', color: '#fff' } : { background: 'rgba(118,118,128,0.12)', color: '#3C3C43' }}>{label}</button>
          ))}
        </div>
      </div>
      <ErrorBox error={err} onRetry={reload} />
      {!rows && loading && <div className="p-6 text-center"><Spinner /></div>}
      {rows && !rows.length && <Empty icon="leads" title="No contacts">New leads appear here as soon as they come in.</Empty>}
      <ul>
        {(rows || []).map((c) => (
          <li key={c.id} className="px-3 py-3 flex flex-col sm:flex-row sm:items-center gap-2" style={{ borderBottom: '1px solid var(--hairline)' }}>
            <div className="min-w-0 flex-1">
              <div className="font-semibold text-glass-primary truncate">{c.name || phoneOf(c)}</div>
              <div className="text-xs text-glass-secondary">{phoneOf(c)} · from {SOURCE[c.first_source] || c.first_source || 'lead'} · {ago(c.created_at)}</div>
              <div className="flex flex-wrap gap-1 mt-1">
                {c.opted_out ? <Pill tone="red" title={c.opt_out_reason}>Asked to stop {ago(c.opted_out_at)}</Pill>
                  : c.opted_in ? <Pill tone="green">Agreed: {SOURCE[c.opt_in_source] || c.opt_in_source}</Pill> : <Pill tone="orange">No opt-in recorded</Pill>}
                {c.not_on_whatsapp && <Pill tone="red">Not on WhatsApp</Pill>}
              </div>
            </div>
            <div className="flex gap-2 shrink-0">
              {c.conversation_id && <Btn ghost onClick={() => navigate('whatsapp', 'inbox', { c: c.conversation_id })}>Open chat</Btn>}
              {c.opted_out ? <Btn ghost onClick={() => optIn(c)}>Opt in again</Btn> : <Btn ghost onClick={() => optOut(c)}>Stop messages</Btn>}
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
