import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';

// CRM > Meta Ads > Overview (migration 121): money left to spend and each live campaign at a glance: budget used against
// the strategy's total, today, leads, cost per lead, qualified, one row per ad and the latest form answers with call speed.
// Numbers refresh every 15 minutes while ads run (cron crm-ads-meta-live); this view reloads every minute.

const C = { green: '#1E7B34', red: '#C4261D', amber: '#B25E00', blue: '#0088FF', track: 'rgba(118,118,128,0.16)', soft: 'rgba(118,118,128,0.08)' };
const inr = (v) => (v === null || v === undefined ? '–' : `₹${Math.round(Number(v)).toLocaleString('en-IN')}`);
const num = (v) => Math.round(Number(v) || 0).toLocaleString('en-IN');
const ago = (t) => { if (!t) return 'not yet'; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };
const words = (s) => String(s || '').replace(/[?_]+/g, ' ').replace(/\s*\/\s*/g, ' / ').trim();
const cap = (s) => { const w = words(s); return w ? w[0].toUpperCase() + w.slice(1) : ''; };
const STATUS = { ACTIVE: ['Running', C.green], PAUSED: ['Paused', C.amber], IN_PROCESS: ['Starting', C.blue], PENDING_REVIEW: ['In review', C.blue],
  WITH_ISSUES: ['Has an issue', C.red], DISAPPROVED: ['Rejected', C.red], CAMPAIGN_PAUSED: ['Paused', C.amber], ADSET_PAUSED: ['Paused', C.amber] };
const Pill = ({ s }) => { const [l, c] = STATUS[s] || [cap(s).toLowerCase() || 'Unknown', C.amber];
  return <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full" style={{ background: `${c}14`, color: c }}>{l}</span>; };
const Stat = ({ label, value }) => (
  <div className="rounded-xl px-3 py-2" style={{ background: C.soft }}><div className="text-[11px] text-glass-muted">{label}</div><div className="text-lg font-bold">{value}</div></div>);

function Wallet({ w }) {
  const billing = `https://business.facebook.com/billing_hub/payment_settings/?asset_id=${w.account || ''}`;
  const limitBinds = w.cap_left !== null && w.cap_left !== undefined && w.prepaid !== null && w.prepaid !== undefined && Number(w.cap_left) < Number(w.prepaid);
  return (
    <section className="glass-card p-4" data-testid="meta-wallet">
      <div className="flex items-center gap-3 flex-wrap">
        <span className="h-10 w-10 rounded-xl flex items-center justify-center" style={{ background: C.soft }}><Icon name="wallet" size={20} /></span>
        <div className="flex-1 min-w-[180px]">
          <div className="text-xs text-glass-muted">Available to spend</div>
          <div className="text-2xl font-bold" data-testid="wallet-available">{inr(w.available)}</div>
          <div className="text-xs" style={{ color: w.low ? C.red : 'inherit' }}>
            {w.daily_budget ? <>About {w.days_left ?? 0} day{w.days_left === 1 ? '' : 's'} at {inr(w.daily_budget)}/day + GST.{w.low ? ' Top up now.' : ''}</> : 'No ads running.'}
          </div>
        </div>
        <a href={billing} target="_blank" rel="noreferrer" className="glass-input px-3 py-2 text-sm font-semibold flex items-center gap-1.5" data-testid="wallet-add">
          Add funds <Icon name="external" size={14} /></a>
      </div>
      <div className="grid grid-cols-2 gap-2 mt-3 text-xs">
        <div className="rounded-xl px-3 py-2" style={{ background: C.soft }}><span className="text-glass-muted">Prepaid balance </span><b>{inr(w.prepaid)}</b></div>
        <div className="rounded-xl px-3 py-2" style={{ background: C.soft }}><span className="text-glass-muted">Spending limit left </span><b>{inr(w.cap_left)}</b></div>
      </div>
      {limitBinds && <div className="text-xs mt-2" style={{ color: C.amber }}>The account spending limit runs out before the balance. In Billing, raise or reset the spending limit, or added money cannot be spent.</div>}
      <div className="text-[11px] text-glass-muted mt-2">From Meta, checked {ago(w.checked_at)}.</div>
    </section>);
}

function Campaign({ c, access, edge, reload }) {
  const pct = c.budget_total ? Math.min(100, (Number(c.used) / Number(c.budget_total)) * 100) : 0;
  const on = c.status === 'ACTIVE';
  const toggle = () => run((async () => {
    const r = await rpc('api_ads_meta_action_request', { p_level: 'campaign', p_object_id: c.id, p_kind: on ? 'pause' : 'activate', p_params: {}, p_reason: on ? 'Paused from Overview' : 'Switched on from Overview' });
    if (r?.self_approve) await rpc('api_ads_meta_action_decide', { p_id: r.id, p_approve: true, p_note: 'Overview' });
    await edge({ jobs: ['meta_actions'] }).catch(() => null);
    reload();
  })(), on ? 'Pausing in Meta' : 'Switching on in Meta');
  return (
    <section className="glass-card p-4 space-y-3" data-testid="meta-campaign">
      <div className="flex items-center gap-2 flex-wrap">
        <b className="text-base">{c.name}</b><Pill s={c.status} />
        {c.day > 0 && <span className="text-xs text-glass-muted">day {c.day} of {c.horizon_days}</span>}
        <span className="flex-1" />
        {access.can_approve && <Btn ghost onClick={toggle}>{on ? 'Pause' : 'Switch on'}</Btn>}
      </div>
      <div>
        <div className="flex justify-between text-xs text-glass-muted mb-1"><span>Budget used</span>
          <span><b className="text-glass-primary" data-testid="budget-used">{inr(c.used)}</b> of {c.budget_total ? inr(c.budget_total) : 'no total set'}</span></div>
        <div className="h-2 rounded-full overflow-hidden" style={{ background: C.track }}><div className="h-full rounded-full" style={{ width: `${pct}%`, background: C.blue }} /></div>
      </div>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
        <Stat label="Spent today" value={inr(c.today)} /><Stat label="Leads" value={num(c.meta_leads)} />
        <Stat label="Cost per lead" value={inr(c.cpl)} /><Stat label="Qualified" value={num(c.qualified)} />
      </div>
      {(c.ads || []).length > 0 && (
        <table className="w-full text-sm" style={{ tableLayout: 'fixed' }}>
          <thead><tr className="text-[11px] text-glass-muted text-left"><th className="font-normal py-1 w-[40%]">Ad</th><th className="font-normal">Spent</th><th className="font-normal">Views</th><th className="font-normal">Leads</th><th className="font-normal">₹/lead</th></tr></thead>
          <tbody>{c.ads.map((a) => (
            <tr key={a.id} className="border-t" style={{ borderColor: C.track }}>
              <td className="py-1.5 pr-2 truncate">{a.post ? <a className="underline" href={a.post} target="_blank" rel="noreferrer">{a.name}</a> : a.name}
                {a.status !== 'ACTIVE' && <span className="text-[11px] text-glass-muted"> · {(STATUS[a.status] || [cap(a.status)])[0]}</span>}</td>
              <td>{inr(a.spend)}</td><td>{num(a.impressions)}</td><td>{num(a.leads || a.meta_leads)}</td>
              <td>{(a.leads || a.meta_leads) ? inr(Number(a.spend) / Number(a.leads || a.meta_leads)) : '–'}</td>
            </tr>))}</tbody>
        </table>)}
      <div>
        <div className="text-xs text-glass-muted mb-1">Latest responses</div>
        {(c.latest || []).length === 0 && <div className="text-sm text-glass-muted">No form answers yet. They show here within a minute of arriving.</div>}
        {(c.latest || []).map((l, i) => (
          <div key={i} className="flex items-start gap-2 text-sm py-1.5 border-t" style={{ borderColor: C.track }} data-testid="latest-row">
            <div className="flex-1 min-w-0"><b>{l.name}</b>
              <span className="text-glass-secondary"> · {(l.answers || []).map((x) => cap(x.a)).join(' · ') || 'no answers'}</span></div>
            <span className="text-xs font-semibold whitespace-nowrap" style={{ color: l.called_at ? C.green : l.wait_min >= 15 ? C.red : C.amber }}>
              {l.called_at ? `Called in ${l.wait_min} min` : `Not called · ${l.wait_min} min`}</span>
          </div>))}
      </div>
    </section>);
}

export default function AdsMetaMoney({ access, edge }) {
  const [d, reload] = useLoad(() => rpc('api_ads_meta_live').catch(() => null), [], { refreshMs: 60000 });
  if (!d) return null;
  return (
    <div className="space-y-3" data-testid="meta-money">
      <Wallet w={d.wallet || {}} />
      {(d.campaigns || []).map((c) => <Campaign key={c.id} c={c} access={access} edge={edge} reload={reload} />)}
      {(d.campaigns || []).length > 0 && <div className="text-[11px] text-glass-muted">Spend and views from Meta, updated {ago(d.numbers_at)}{d.live ? ', every 15 minutes while ads run' : ''}. Leads and calls are live from the CRM.</div>}
    </div>);
}
