// CRM > ADS > Today: one page to see everything and act on it without opening other tabs.
//   status strip (Autopilot, agents, spend vs limits, balance, emergency stop)
//   "Needs you" (every item that waits for a person, with its button right there)
//   results with trends, best / wasted searches, campaign health, what changed, ask the agents.
// All writes go through the same api_ads_* functions as the other tabs; buttons cannot be pressed twice (adsKit).
import { useMemo, useState } from 'react';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { money, int, todayIn, periodRange } from '../utils/ads';
import { setParams } from '../utils/route';
import { showToast } from '../utils/toast';
import { rpc, run, useLoad, Btn } from './adsKit';
import { AgentsBadge, Report, Funds, Suggestion, Tell, Activity, Bar, Playbook } from './AdsAutopilot';

const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - Date.parse(t)) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return `${Math.round(m / 1440)} d ago`;
};
const Card = ({ title, right, children, testid }) => (
  <section className="glass-card p-4" data-testid={testid}>
    {(title || right) && <div className="flex flex-wrap items-center justify-between gap-2 mb-3"><h3 className="font-bold text-glass-primary">{title}</h3>{right}</div>}
    {children}
  </section>
);
const Explain = ({ text }) => (
  <button type="button" className="text-[11px] font-semibold ml-1 align-middle" style={{ color: '#007AFF' }} title={text}
    onClick={() => alertLike(text)} aria-label={`Explain: ${text}`}>?</button>
);
// Explanations: the browser's tooltip on desktop, a toast on tap (phones).
function alertLike(text) { showToast(text, 'info'); }

function Needs({ items }) {
  if (!items.length) return <div className="text-sm font-semibold" style={{ color: '#1E7B34' }} data-testid="all-good">All good — nothing needs you right now.</div>;
  return <div className="space-y-3">{items}</div>;
}

export default function AdsToday({ ctx, access, go, parts }) {
  const { Kpi, Bars, fillDays, Delivery } = parts;
  const days = ctx.period === '30d' ? 30 : 7;
  const tz = ctx.tz || 'Asia/Kolkata';
  const { from, to } = periodRange(days === 30 ? '30d' : '7d', todayIn(tz));
  const [ap, loadAp, apErr] = useLoad(() => rpc('api_ads_autopilot'), [], { refreshMs: 30000 });
  const [st, loadSt] = useLoad(() => rpc('api_ads_autopilot_status').catch(() => null), [], { refreshMs: 30000 });
  const [o, loadO, oErr] = useLoad(() => rpc('api_ads_overview', { p_client: ctx.client || null, p_from: from, p_to: to }), [ctx.client, from, to]);
  const [camps, loadC] = useLoad(() => rpc('api_ads_campaigns', { p_client: ctx.client || null, p_from: from, p_to: to }), [ctx.client, from, to]);
  const [queue, loadQ] = useLoad(() => rpc('api_ads_queue', { p_status: 'pending' }), [], { refreshMs: 60000 });
  const [si] = useLoad(() => rpc('api_ads_search_insights', { p_limit: 6 }).catch(() => null), []);
  const reloadAll = () => { loadAp(); loadSt(); loadO(); loadC(); loadQ(); };

  const pendingOps = useMemo(() => (ap?.ops || []).filter((x) => x.status === 'pending'), [ap]);
  if (apErr && !ap) return <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{apErr}</div>;
  if (!ap || !o) return <div className="text-center text-glass-muted py-10 text-sm" data-testid="today-loading">Loading…</div>;

  const cur = ap.account?.currency || 'INR';
  const client = ctx.client ? o.clients[0] : (o.clients.length === 1 ? o.clients[0] : null);
  const prev = ctx.client ? o.previous[0] : (o.previous?.length === 1 ? o.previous[0] : null);
  const on = ap.mode === 'auto' && !ap.stopped;

  const stop = async () => {
    if (ap.stopped) { if (await run(rpc('api_ads_autopilot_stop', { p_stop: false }), 'Resumed.')) loadAp(); return; }
    if (await confirmDialog('Stop everything?', { message: 'Nothing will be sent to Google Ads or Meta until someone who can approve turns this off. Campaigns keep running as they are.', confirmText: 'Stop everything', danger: true })) {
      if (await run(rpc('api_ads_autopilot_stop', { p_stop: true }), 'Stopped. Nothing is being sent.')) loadAp();
    }
  };
  const decideOp = async (op, approve) => {
    if (await run(rpc('api_ads_google_op_decide', { p_id: op.id, p_approve: approve, p_reason: approve ? null : 'Declined on Today' }), approve ? 'Approved. It goes out within 5 minutes.' : 'Declined.')) loadAp();
  };

  // ------------------------------------------------ Needs you
  const needs = [];
  const row = (key, tone, text, sub, action) => (
    <div key={key} className="flex flex-wrap items-center gap-3 p-3 rounded-2xl" style={{ background: `${tone}14` }}>
      <span className="h-2.5 w-2.5 rounded-full shrink-0" style={{ background: tone }} />
      <div className="flex-1 min-w-[12rem]"><div className="text-sm font-semibold text-glass-primary">{text}</div>{sub && <div className="text-xs text-glass-secondary break-words">{sub}</div>}</div>
      {action}
    </div>);
  if (ap.stopped) needs.push(row('stop', '#FF3B30', 'Emergency stop is ON.', 'Nothing is being sent to the ad platforms.',
    ap.can_approve && <Btn tone="#248A3D" scope="stop" busyText="Resuming…" onClick={stop}><Icon name="play" size={14} />Resume</Btn>));
  (o.accounts || []).filter((a) => a.status !== 'connected' && a.status !== 'disabled').forEach((a) => needs.push(row(`acc${a.id}`, '#FF3B30',
    `${a.platform === 'google' ? 'Google Ads' : 'Meta'} is not connected (${String(a.status).replace(/_/g, ' ')}).`,
    a.last_error || 'Sign in again: ADS › More › Settings.', access.is_admin && <Btn ghost onClick={() => go('settings')}>Reconnect</Btn>)));
  if (ap.funds?.low) needs.push(<Funds key="funds" d={ap} reload={loadAp} />);
  if (st?.agents && !st.agents.online) needs.push(row('agents', '#FF9500', 'The AI agents are offline.',
    st.agents.last_seen ? `Last seen ${ago(st.agents.last_seen)}. Wake the Mac Mini; the helper starts by itself.` : 'Set up the helper on the Mac Mini (tools/ads-agents/install.sh).', null));
  (ap.suggestions || []).filter((s) => s.status === 'open').forEach((s) => needs.push(<Suggestion key={`s${s.id}`} s={s} reload={reloadAll} />));
  pendingOps.forEach((op) => needs.push(row(`op${op.id}`, '#FF9500', op.summary || op.kind, 'An agent change waiting for approval (Autopilot is on "Ask me").',
    ap.can_approve && <div className="flex gap-2">
      <Btn tone="#248A3D" scope={`op-${op.id}`} busyText="Approving…" onClick={() => decideOp(op, true)}>Approve</Btn>
      <Btn ghost scope={`op-${op.id}`} onClick={() => decideOp(op, false)}>Decline</Btn></div>)));
  if ((queue || []).length) needs.push(row('queue', '#FF9500', `${queue.length} budget / status change${queue.length > 1 ? 's' : ''} waiting for approval.`,
    'Each shows its checks before you approve.', <Btn ghost onClick={() => go('approvals')}>Review</Btn>));
  (o.accounts || []).filter((a) => a.status === 'connected' && a.stale).forEach((a) => needs.push(row(`st${a.id}`, '#FF9500',
    `${a.name || a.external_id} has not synced recently.`, `Last good sync ${ago(a.last_ok_at)}.`, null)));

  // ------------------------------------------------ results
  const kp = (k) => client?.[k]; const kc = (k) => client?.crm?.[k];
  const pp = (k) => prev?.[k]; const pc = (k) => prev?.crm?.[k];
  const clicks = (o.by_platform?.google || []).concat(o.by_platform?.meta || []).reduce((s, r) => s + (Number(r.clicks) || 0), 0);
  const trend = fillDays((o.trend || []).filter((t) => !t.currency || t.currency === cur), from, to);
  const leadsTrend = fillDays(o.leads_trend || [], from, to);
  const enabled = (camps || []).filter((c) => c.status === 'ENABLED');

  return (
    <div className="space-y-4" data-testid="today">
      {/* status strip */}
      <section className="glass-card p-4" style={ap.stopped ? { boxShadow: 'inset 0 0 0 1px rgba(255,59,48,0.55)' } : undefined}>
        <div className="flex flex-wrap items-center gap-3">
          <span className="h-11 w-11 rounded-[14px] inline-flex items-center justify-center shrink-0" style={{ background: on ? 'rgba(52,199,89,0.14)' : ap.stopped ? 'rgba(255,59,48,0.12)' : 'rgba(118,118,128,0.14)', color: on ? '#1E7B34' : ap.stopped ? '#C4261D' : '#636366' }}>
            <Icon name={ap.stopped ? 'pause' : 'plane'} size={22} /></span>
          <div className="flex-1 min-w-[12rem]">
            <div className="font-bold text-glass-primary" data-testid="today-state">{ap.stopped ? 'Emergency stop is ON' : on ? 'Autopilot is flying' : 'Autopilot asks before acting'}</div>
            <AgentsBadge s={st} />
          </div>
          <Btn tone={ap.stopped ? '#248A3D' : '#FF3B30'} scope="stop" onClick={stop} disabled={ap.stopped && !ap.can_approve}
            busyText={ap.stopped ? 'Resuming…' : 'Stopping…'}><Icon name={ap.stopped ? 'play' : 'pause'} size={16} />{ap.stopped ? 'Resume' : 'Stop everything'}</Btn>
        </div>
        <div className="grid sm:grid-cols-3 gap-3 mt-3">
          <Bar label="Spent today" value={ap.spend.today} max={ap.caps.daily} cur={cur} />
          <Bar label="Spent this month" value={ap.spend.month} max={ap.caps.monthly} cur={cur} />
          <div className="text-xs text-glass-secondary self-end">
            {ap.funds?.estimate != null ? <>Balance about <b className="text-glass-primary">{money(Math.max(0, ap.funds.estimate), cur, 0)}</b>{ap.funds.days_left != null && ` · ${ap.funds.days_left} days`}</>
              : <>Balance unknown · <button type="button" className="font-semibold" style={{ color: '#007AFF' }} onClick={() => go('autopilot')}>record a top-up</button></>}
            <Explain text="An estimate: money you recorded as added, minus what Google reports as spent since then. Google does not share the real prepaid balance." />
          </div>
        </div>
      </section>

      <Card title="Needs you" testid="needs" right={needs.length > 0 && <span className="text-xs font-semibold rounded-full px-2 py-0.5" style={{ background: '#FF3B30', color: '#fff' }}>{needs.length}</span>}>
        <Needs items={needs} />
      </Card>

      {st?.report && <Report r={st.report} />}

      {/* results */}
      <Card title="Results" testid="results" right={
        <div className="flex gap-1 p-1 rounded-xl" style={{ background: 'rgba(118,118,128,0.12)' }}>
          {[['7d', '7 days'], ['30d', '30 days']].map(([v, l]) => (
            <button key={v} type="button" aria-pressed={(days === 30 ? '30d' : '7d') === v} onClick={() => setParams({ period: v })}
              className={`px-3 py-1.5 rounded-lg text-sm ${(days === 30 ? '30d' : '7d') === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
        </div>}>
        {oErr && <div className="text-xs mb-2" style={{ color: '#C4261D' }}>{oErr} (showing the last numbers loaded)</div>}
        {client ? (
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <Kpi k="spend" label="Ad spend" src="platform" value={money(kp('spend'), cur)} cur={kp('spend')} prev={pp('spend')} help="What Google Ads and Meta report as spent." onClick={() => go('campaigns')} />
            <Kpi k="leads" label="Enquiries (CRM)" src="crm" value={client.crm_linked ? int(kc('leads')) : '—'} cur={kc('leads')} prev={pc('leads')} help="Leads in your CRM that came from these ads." onClick={() => go('adsleads')} />
            <Kpi k="cpl" label="Cost per enquiry" src="calc" value={money(kc('cpl'), cur)} cur={kc('cpl')} prev={pc('cpl')} help="Spend divided by CRM enquiries. Lower is better." />
            <Kpi k="clicks" label="Clicks" src="platform" value={int(clicks)} help="People who clicked an ad." />
          </div>
        ) : <div className="text-sm text-glass-secondary">Pick a client at the top to see its numbers.</div>}
        <div className="grid md:grid-cols-2 gap-3 mt-3">
          <div><div className="text-xs font-semibold text-glass-secondary mb-1">Spend per day</div><Bars data={trend} value={(d) => d.spend} label="Spend per day" fmt={(v) => money(v, cur)} /></div>
          <div><div className="text-xs font-semibold text-glass-secondary mb-1">CRM enquiries per day</div><Bars data={leadsTrend} value={(d) => d.leads} label="CRM enquiries per day" color="#34C759" /></div>
        </div>
      </Card>

      {si && (si.best.length > 0 || si.wasted.length > 0) && (
        <Card title={`Searches (${si.source})`} testid="searches">
          <div className="grid md:grid-cols-2 gap-4">
            <div><div className="text-xs font-semibold mb-1" style={{ color: '#1E7B34' }}>Brought results</div>
              {si.best.length === 0 ? <div className="text-xs text-glass-muted">None yet.</div> : <ul className="space-y-1 text-sm">{si.best.map((b) => (
                <li key={b.term} className="flex justify-between gap-2"><span className="truncate">{b.term}</span><span className="text-glass-muted whitespace-nowrap">{money(b.cost_per_conversion, cur, 0)} each</span></li>))}</ul>}</div>
            <div><div className="text-xs font-semibold mb-1" style={{ color: '#C4261D' }}>Cost money, brought nothing</div>
              {si.wasted.length === 0 ? <div className="text-xs text-glass-muted">None.</div> : <ul className="space-y-1 text-sm">{si.wasted.map((w) => (
                <li key={w.term} className="flex justify-between gap-2"><span className="truncate">{w.term}</span><span className="text-glass-muted whitespace-nowrap">{money(w.cost, cur, 0)}</span></li>))}</ul>}</div>
          </div>
          <div className="text-[11px] text-glass-muted mt-2">"Results" are Google's own conversions; the agents block wasted searches on their daily review.</div>
        </Card>)}

      <Card title="Campaign health" testid="health">
        {enabled.length === 0 ? <div className="text-sm text-glass-secondary">No campaign is running.</div> : (
          <ul className="space-y-2">{enabled.map((c) => (
            <li key={c.id} className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-semibold text-glass-primary">{c.name}</span>
              <span className="text-xs text-glass-muted">{c.platform === 'meta' ? 'Meta' : 'Google'} · {money(c.daily_budget, c.currency || cur, 0)}/day</span>
              <div className="w-full"><Delivery c={c} /></div>
            </li>))}</ul>)}
      </Card>

      <div className="grid lg:grid-cols-2 gap-4 items-start">
        <Activity d={ap} limit={10} title="What changed" />
        <Tell d={ap} reload={loadAp} />
      </div>
      {st?.playbook?.length > 0 && <Playbook items={st.playbook} />}

      {/* phones: the agents are one tap away */}
      <button type="button" aria-label="Tell the agents" className="sm:hidden fixed bottom-5 right-5 z-40 h-14 w-14 rounded-full shadow-lg inline-flex items-center justify-center"
        style={{ background: '#5856D6', color: '#fff' }}
        onClick={() => document.querySelector('[data-testid="ap-tell"] textarea')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>
        <Icon name="mic" size={22} /></button>
    </div>
  );
}
