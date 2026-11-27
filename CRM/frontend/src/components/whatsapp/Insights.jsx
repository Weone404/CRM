// WhatsApp > Insights: by lead source, how many got the welcome, saw it, replied and asked for counselling;
// why messages failed; and what Meta will roughly charge (rates editable in Settings).
import { useState } from 'react';
import { Segmented } from '../ui/AppleControls';
import { Empty, ErrorBox, rpc, SOURCE, Spinner, useLoad } from './kit';

const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : '—');
const inr = (n) => `₹${Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;

export default function Insights() {
  const [days, setDays] = useState(30);
  const [d, reload, err] = useLoad(() => rpc('api_wa_insights', { p_days: days }), [days], { refreshMs: 60000 });
  const rows = d?.by_source || [];
  const tot = rows.reduce((a, r) => ({ leads: a.leads + r.leads, welcomed: a.welcomed + r.welcomed, delivered: a.delivered + r.delivered,
    read: a.read + r.read, replied: a.replied + r.replied, counselling: a.counselling + r.counselling, opted_out: a.opted_out + r.opted_out }),
  { leads: 0, welcomed: 0, delivered: 0, read: 0, replied: 0, counselling: 0, opted_out: 0 });
  const gst = d?.cost?.gst_pct ?? 18;
  return (
    <div className="space-y-4">
      <div className="w-full sm:w-72"><Segmented label="Period" value={days} onChange={setDays} options={[{ value: 7, label: '7 days' }, { value: 30, label: '30 days' }, { value: 90, label: '90 days' }]} /></div>
      <ErrorBox error={err} onRetry={reload} />
      {!d && !err && <div className="glass-card p-8 text-center"><Spinner /></div>}
      {d && (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[['Leads messaged', tot.welcomed, `${tot.leads} chats`], ['Replied', tot.replied, `${pct(tot.replied, tot.welcomed)} of welcomed`],
              ['Asked for counselling', tot.counselling, `${pct(tot.counselling, tot.replied)} of replies`],
              ['Median time to reply', d.reply_minutes_median != null ? `${d.reply_minutes_median} min` : '—', 'after the welcome']].map(([l, v, s]) => (
              <div key={l} className="glass-stat p-3"><div className="text-xs text-glass-secondary">{l}</div><div className="text-2xl font-bold text-glass-primary">{v}</div><div className="text-[11px] text-glass-secondary">{s}</div></div>
            ))}
          </div>
          <section className="glass-card p-0 overflow-hidden">
            <h2 className="text-lg font-semibold text-glass-primary px-4 pt-4 pb-2">By lead source</h2>
            {!rows.length ? <Empty icon="chart" title="No chats in this period" /> : (
              <div className="overflow-x-auto">
                <table className="glass-table w-full text-sm min-w-[640px]">
                  <thead><tr><th className="text-left">Source</th><th>Chats</th><th>Welcomed</th><th>Delivered</th><th>Read</th><th>Replied</th><th>Counselling</th><th>Opted out</th></tr></thead>
                  <tbody>
                    {rows.map((r) => (
                      <tr key={r.source}>
                        <td className="font-semibold">{SOURCE[r.source] || r.source}</td>
                        <td className="text-center">{r.leads}</td><td className="text-center">{r.welcomed}</td>
                        <td className="text-center">{r.delivered} <span className="text-glass-secondary text-xs">{pct(r.delivered, r.welcomed)}</span></td>
                        <td className="text-center">{r.read} <span className="text-glass-secondary text-xs">{pct(r.read, r.delivered)}</span></td>
                        <td className="text-center font-semibold">{r.replied} <span className="text-glass-secondary text-xs">{pct(r.replied, r.welcomed || r.leads)}</span></td>
                        <td className="text-center">{r.counselling}</td><td className="text-center">{r.opted_out}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          <div className="grid md:grid-cols-2 gap-4">
            <section className="glass-card p-4 space-y-2">
              <h2 className="text-lg font-semibold text-glass-primary">Estimated Meta cost</h2>
              <div className="text-3xl font-bold text-glass-primary">{inr(d.cost.before_gst * (1 + gst / 100))}</div>
              <div className="text-xs text-glass-secondary">{inr(d.cost.before_gst)} + {gst}% GST · delivered messages only · your Meta invoice is the final number</div>
              <ul className="text-sm space-y-1 pt-1">
                <li className="flex justify-between"><span>Utility templates (welcome)</span><b>{d.messages.utility} × {inr(d.cost.rates.utility)}</b></li>
                <li className="flex justify-between"><span>Marketing templates (follow-ups)</span><b>{d.messages.marketing} × {inr(d.cost.rates.marketing)}</b></li>
                <li className="flex justify-between"><span>Replies in the chat</span><b>{d.messages.service} ({d.cost.rates.free_service}/month free)</b></li>
                <li className="flex justify-between text-glass-secondary"><span>Messages from leads</span><span>{d.messages.inbound} (free)</span></li>
              </ul>
            </section>
            <section className="glass-card p-4 space-y-2">
              <h2 className="text-lg font-semibold text-glass-primary">Why messages failed</h2>
              {!d.failures.length ? <div className="text-sm text-glass-secondary">No failed messages in this period.</div> : (
                <ul className="text-sm space-y-1.5">
                  {d.failures.map((f) => (
                    <li key={String(f.code)} className="flex gap-2"><b className="shrink-0">{f.count}×</b><span className="text-glass-secondary">{f.code ? `#${f.code} ` : ''}{HELP[f.code] || f.text || 'Unknown'}</span></li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        </>
      )}
    </div>
  );
}

const HELP = {
  131026: 'Not on WhatsApp or could not receive it: call them',
  131049: 'Meta limits marketing messages per person: it was not sent to protect their inbox',
  131047: 'More than 24 hours since they wrote: use a template',
  131056: 'Too many messages to one person too fast: retried later',
  130429: 'Meta rate limit: retried later',
  132001: 'Template not found in this language: check Templates',
  132000: 'Template variables do not match',
  190: 'The access token expired: paste a new one in Setup',
};
