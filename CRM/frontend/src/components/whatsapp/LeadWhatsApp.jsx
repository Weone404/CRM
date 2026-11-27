// The WhatsApp panel inside a lead (Leads > lead window): read-only. Shows whether the welcome went out, the last
// messages, what the bot learned and whether a person is needed, with a link to the full chat. Nothing shows when the
// lead has no WhatsApp chat yet or this person has no access.
import { useEffect, useState } from 'react';
import { navigate } from '../../utils/route';
import { ago, Pill, rpc, STATUS, Ticks } from './kit';

export default function LeadWhatsApp({ leadId }) {
  const [d, setD] = useState(null);
  useEffect(() => {
    let live = true;
    const pull = () => rpc('api_wa_lead_panel', { p_lead: leadId }).then((x) => { if (live) setD(x); }, () => {});
    pull();
    const t = setInterval(() => { if (document.visibilityState === 'visible') pull(); }, 15000);
    return () => { live = false; clearInterval(t); };
  }, [leadId]);
  if (!d) return null;
  const [label, tone] = STATUS[d.status] || STATUS.bot;
  return (
    <div className="rounded-2xl p-3 mb-3" style={{ background: 'rgba(37,211,102,0.08)', boxShadow: '0 0 0 1px rgba(31,168,85,0.25)' }} data-testid="lead-whatsapp">
      <div className="flex flex-wrap items-center gap-2 mb-1.5">
        <span className="font-semibold text-[14px]" style={{ color: '#1E8E3E' }}>WhatsApp</span>
        <Pill tone={tone}>{label}</Pill>
        {d.opted_out && <Pill tone="red">Asked to stop</Pill>}
        {d.not_on_whatsapp && <Pill tone="red">Not on WhatsApp: call</Pill>}
        {!d.welcomed_at && d.pending && <Pill tone="gray">{d.pending.state === 'pending' ? 'Welcome waiting' : d.pending.state === 'skipped' ? `Not sent: ${d.pending.last_error}` : d.pending.state}</Pill>}
        {d.can_open && d.conversation_id && (
          <button type="button" className="ml-auto text-sm font-semibold" style={{ color: '#007AFF' }} onClick={() => navigate('whatsapp', 'inbox', { c: d.conversation_id })}>Open chat</button>
        )}
      </div>
      {Object.keys(d.answers || {}).length > 0 && (
        <div className="text-xs text-glass-secondary mb-1.5">{Object.entries(d.answers).map(([k, v]) => `${k}: ${v}`).join(' · ')}</div>
      )}
      <ul className="space-y-1">
        {(d.messages || []).map((m) => (
          <li key={m.id} className={`text-[13px] flex gap-1.5 ${m.direction === 'out' ? 'text-glass-secondary' : 'text-glass-primary'}`}>
            <span className="shrink-0 font-semibold">{m.direction === 'out' ? 'Us' : 'Lead'}:</span>
            <span className="truncate flex-1">{m.body || `[${m.kind}]`}</span>
            <span className="shrink-0 text-[11px] text-glass-secondary inline-flex items-center gap-1">{m.direction === 'out' && <Ticks status={m.status} />}{ago(m.created_at)}</span>
          </li>
        ))}
        {!(d.messages || []).length && <li className="text-[13px] text-glass-secondary">No messages yet.</li>}
      </ul>
    </div>
  );
}
