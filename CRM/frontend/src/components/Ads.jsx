import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog } from './ui/dialogs';
import Icon from './icons';
import { useRoute, navigate, setParams } from '../utils/route';
import { ClientWizard, ImportAccounts } from './AdsClientWizard';
import AdsLeads from './AdsLeads';
import AdsAutopilot from './AdsAutopilot';
import { PERIODS, periodRange, todayIn, money, int, pct, ratio, delta, isNum, LOWER_IS_BETTER, toCsv, STATUS_LABEL } from '../utils/ads';

// CRM > ADS: paid advertising for one or more clients (Google Ads, Meta).
// Every read and write goes through api_ads_* database functions, which check access, compute every metric
// (a missing denominator shows "—", never 0) and run the guards. Nothing here talks to an ad platform:
// the ads-sync Edge Function pulls data and sends only approved changes, then reads them back.
// Platform-reported numbers (spend, platform conversions/ROAS) and CRM-confirmed numbers (leads, customers,
// revenue) are labelled and never added together.

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function edge(body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/ads-sync`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
const run = async (p, okMsg) => {
  try { const r = await p; if (okMsg) showToast(okMsg, 'success'); return r ?? true; }
  catch (e) { showToast(e.message, 'error'); return undefined; }
};
function useLoad(fn, deps = []) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const load = useCallback(async () => {
    try { setData(await fn()); setError(''); } catch (e) { setError(e.message); }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { load(); }, [load]);
  return [data, load, error];
}

const Chip = ({ children, bg = 'rgba(118,118,128,0.14)', fg = '#3C3C43', title }) => (
  <span title={title} className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: bg, color: fg }}>{children}</span>
);
const StatusChip = ({ s }) => { const [l, fg, bg] = STATUS_LABEL[s] || [s, '#3C3C43', 'rgba(118,118,128,0.14)']; return <Chip bg={bg} fg={fg}>{l}</Chip>; };
const SRC = { platform: ['Platform', '#0062CC', 'rgba(0,122,255,0.10)'], crm: ['CRM', '#1E7B34', 'rgba(52,199,89,0.12)'], calc: ['Calculated', '#6E3FB0', 'rgba(175,82,222,0.12)'] };
const Src = ({ s }) => <Chip bg={SRC[s][2]} fg={SRC[s][1]}>{SRC[s][0]}</Chip>;
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const Err = ({ msg }) => (msg ? <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{msg}</div> : null);
const Field = ({ label, children, hint }) => (
  <label className="block text-sm"><span className="block text-xs font-medium text-glass-secondary mb-1">{label}</span>{children}
    {hint && <span className="block text-[11px] text-glass-muted mt-0.5">{hint}</span>}</label>
);
const Input = (p) => <input {...p} className={`glass-input w-full px-3 py-2 text-sm ${p.className || ''}`} />;
const Btn = ({ tone = '#007AFF', ghost, className = '', ...p }) => (
  <button type="button" {...p} className={`px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center gap-1.5 disabled:opacity-40 ${className}`}
    style={ghost ? { background: 'rgba(118,118,128,0.12)', color: '#1C1C1E' } : { background: tone, color: '#fff' }} />
);
const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - Date.parse(t)) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return `${Math.round(m / 1440)} d ago`;
};
const SEV = { blocker: ['Must fix', '#C4261D', 'rgba(255,59,48,0.12)'], confirm: ['Double-check', '#0062CC', 'rgba(0,122,255,0.12)'], warning: ['Heads up', '#B25E00', 'rgba(255,149,0,0.14)'] };
function GuardList({ g }) {
  if (!g) return null;
  const items = [...(g.blockers || []), ...(g.confirms || []), ...(g.warnings || [])];
  if (!items.length) return <div className="text-xs mt-2" style={{ color: '#1E7B34' }}>All checks pass.</div>;
  return (
    <ul className="mt-2 space-y-1">
      {items.map((i, n) => { const [l, fg, bg] = SEV[i.severity] || SEV.warning; return (
        <li key={n} className="text-xs flex gap-2 items-start"><Chip bg={bg} fg={fg}>{l}</Chip><span className="text-glass-secondary">{i.message}</span></li>); })}
    </ul>
  );
}
function download(name, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' }));
  const a = Object.assign(document.createElement('a'), { href: url, download: name });
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// ---------------------------------------------------------------- tiny bar chart (no chart library)
function Bars({ data, value, label, color = '#007AFF', fmt = int }) {
  if (!data?.length) return <Empty>No data for this period.</Empty>;
  const max = Math.max(...data.map((d) => Number(value(d)) || 0), 1);
  return (
    <div>
      <div className="flex items-end gap-[2px] h-28" role="img" aria-label={label}>
        {data.map((d, i) => {
          const v = Number(value(d)) || 0;
          return <div key={i} className="flex-1 rounded-t" title={`${d.day}: ${fmt(v)}`} style={{ height: `${Math.max(2, (v / max) * 100)}%`, background: color, opacity: v ? 0.85 : 0.2 }} />;
        })}
      </div>
      <div className="flex justify-between text-[10px] text-glass-muted mt-1"><span>{data[0].day}</span><span>{data[data.length - 1].day}</span></div>
    </div>
  );
}
// Fill missing days with 0-height bars so the time axis is honest.
function fillDays(rows, from, to, key = 'day') {
  const map = new Map(rows.map((r) => [r[key], r]));
  const out = [];
  for (let t = Date.parse(`${from}T00:00:00Z`); t <= Date.parse(`${to}T00:00:00Z`) && out.length < 400; t += 86400000) {
    const d = new Date(t).toISOString().slice(0, 10);
    out.push(map.get(d) || { day: d });
  }
  return out;
}

// ---------------------------------------------------------------- KPI card
function Kpi({ label, value, prev, cur, k, src, help, onClick }) {
  const dl = delta(cur, prev);
  const good = dl === null ? null : (LOWER_IS_BETTER.has(k) ? dl < 0 : dl > 0);
  const body = (
    <>
      <div className="flex items-center justify-between gap-2"><span className="text-xs text-glass-muted">{label}</span><Src s={src} /></div>
      <div className="text-2xl font-bold mt-1 text-glass-primary">{value}</div>
      <div className="text-[11px] mt-0.5" style={{ color: good === null ? 'var(--text-muted, #8E8E93)' : good ? '#1E7B34' : '#C4261D' }}>
        {dl === null ? 'No comparison' : `${dl > 0 ? '▲' : '▼'} ${Math.abs(dl).toFixed(1)}% vs previous period`}
      </div>
    </>
  );
  return onClick
    ? <button type="button" title={help} onClick={onClick} className="glass-card p-3 text-left w-full">{body}</button>
    : <div className="glass-card p-3" title={help}>{body}</div>;
}

// ---------------------------------------------------------------- Home
function Home({ ctx, access, go }) {
  const [o, load, err] = useLoad(() => rpc('api_ads_overview', { p_client: ctx.client || null, p_from: ctx.from, p_to: ctx.to }), [ctx.client, ctx.from, ctx.to]);
  const [busy, setBusy] = useState(false);
  const sync = async () => {
    setBusy(true);
    const r = await run(edge({ jobs: ['sync'] }));
    setBusy(false);
    if (r?.results?.sync) showToast(r.results.sync.detail || r.results.sync.status, r.results.sync.status === 'ok' ? 'success' : 'error');
    load();
  };
  if (err) return <Err msg={err} />;
  if (!o) return <Empty>Loading…</Empty>;
  const single = ctx.client ? o.clients[0] : null;
  const prev = ctx.client ? o.previous[0] : null;
  const cur = single?.currency || 'INR';
  const todo = [];
  if (!o.accounts.length) todo.push({ tone: '#FF9500', text: 'No ad accounts added yet.', sub: access.is_admin ? 'Save the Google / Meta keys in Settings, then import the accounts you already run (Clients > Import existing accounts).' : 'Ask Admin to add accounts.', to: access.is_admin ? 'clients' : null, btn: 'Open Clients' });
  o.accounts.filter((a) => a.status !== 'connected' && a.status !== 'disabled').forEach((a) => todo.push({ tone: '#FF3B30', text: `${a.platform === 'google' ? 'Google Ads' : 'Meta'} ${a.name || a.external_id} (${a.client}): ${STATUS_LABEL[a.status]?.[0] || a.status}.`, sub: a.last_error || 'Open Settings and press Test connection.', to: access.is_admin ? 'settings' : null, btn: 'Settings' }));
  o.accounts.filter((a) => a.status === 'connected' && a.stale).forEach((a) => todo.push({ tone: '#FF9500', text: `${a.name || a.external_id} has not synced recently.`, sub: `Last good sync ${ago(a.last_ok_at)}. Numbers may be out of date.` }));
  if (o.pending_approvals) todo.push({ tone: '#FF9500', text: `${o.pending_approvals} change${o.pending_approvals > 1 ? 's' : ''} waiting for approval.`, sub: 'Nothing is sent to Google or Meta until approved.', to: 'approvals', btn: 'Review' });
  if (o.open_recommendations) todo.push({ tone: '#007AFF', text: `${o.open_recommendations} recommendation${o.open_recommendations > 1 ? 's' : ''} to look at.`, sub: 'Rule-based, with the data behind each one.', to: 'recommendations', btn: 'Open' });
  if (o.execution_paused) todo.push({ tone: '#FF3B30', text: 'Emergency stop is ON.', sub: 'Approved changes are not being sent.', to: access.is_admin ? 'settings' : null, btn: 'Settings' });
  if (o.last_sync?.status === 'error') todo.push({ tone: '#FF3B30', text: 'The last sync had a problem.', sub: o.last_sync.detail });
  const kp = (k) => single?.[k]; const kc = (k) => single?.crm?.[k];
  const pp = (k) => prev?.[k]; const pc = (k) => prev?.crm?.[k];
  const plat = single?.platform?.[0];
  const pplat = prev?.platform?.[0];
  const trend = fillDays((o.trend || []).filter((t) => !ctx.client || t.currency === cur), ctx.from, ctx.to);
  const leadsTrend = fillDays(o.leads_trend || [], ctx.from, ctx.to);
  const budgetLeft = single?.targets?.monthly_budget != null && ctx.period === 'month' && isNum(single?.spend) ? Number(single.targets.monthly_budget) - Number(single.spend) : null;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-glass-muted">
        <span>Last sync: {o.last_sync ? `${o.last_sync.status} · ${ago(o.last_sync.at)}` : 'never'}</span>
        <Btn onClick={sync} disabled={busy}><Icon name="refresh" size={14} />{busy ? 'Syncing…' : 'Sync now'}</Btn>
      </div>
      {single ? (
        <>
          {single.mixed_currency && <div className="glass-card p-3 text-sm" style={{ color: '#B25E00' }}>This client's accounts report in more than one currency, so spend is not totalled. See Campaigns for each account.</div>}
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <Kpi k="spend" label="Ad spend" src="platform" value={money(kp('spend'), cur)} cur={kp('spend')} prev={pp('spend')} help="Sum of spend reported by Google Ads and Meta for the period." onClick={() => go('campaigns')} />
            <Kpi k="leads" label="Leads (CRM)" src="crm" value={single.crm_linked ? int(kc('leads')) : '—'} cur={kc('leads')} prev={pc('leads')} help="CRM leads whose UTM matches a campaign or account of this client." onClick={() => go('leads')} />
            <Kpi k="qualified" label="Qualified leads" src="crm" value={single.crm_linked ? int(kc('qualified')) : '—'} cur={kc('qualified')} prev={pc('qualified')} help="Valid leads marked Interested on a call, or marked eligible." onClick={() => go('leads')} />
            <Kpi k="customers" label="Customers" src="crm" value={single.crm_linked ? int(kc('customers')) : '—'} cur={kc('customers')} prev={pc('customers')} help="Leads closed as admission completed / booking confirmed." onClick={() => go('leads')} />
            <Kpi k="revenue" label="Confirmed revenue" src="crm" value={single.crm_linked ? money(kc('revenue'), cur) : '—'} cur={kc('revenue')} prev={pc('revenue')} help="Sales minus refunds recorded in ADS > Leads & Revenue. Never mixed with platform-attributed value." onClick={() => go('leads')} />
            <Kpi k="cpl" label="Cost per lead" src="calc" value={money(kc('cpl'), cur)} cur={kc('cpl')} prev={pc('cpl')} help="Spend ÷ valid CRM leads." />
            <Kpi k="qualified_cpl" label="Cost per qualified lead" src="calc" value={money(kc('qualified_cpl'), cur)} cur={kc('qualified_cpl')} prev={pc('qualified_cpl')} help="Spend ÷ qualified CRM leads." />
            <Kpi k="cac" label="Customer acquisition cost" src="calc" value={money(kc('cac'), cur)} cur={kc('cac')} prev={pc('cac')} help="Spend ÷ new customers." />
            <Kpi k="crm_roas" label="ROAS (CRM revenue)" src="calc" value={ratio(kc('crm_roas'))} cur={kc('crm_roas')} prev={pc('crm_roas')} help="Confirmed CRM revenue ÷ spend." />
            <Kpi k="platform_roas" label="ROAS (platform-attributed)" src="platform" value={ratio(plat?.platform_roas)} cur={plat?.platform_roas} prev={pplat?.platform_roas} help="Conversion value the platforms claim ÷ spend. Platforms can over-count; compare with CRM ROAS." />
            <Kpi k="contribution" label="Contribution" src="calc" value={money(kc('contribution'), cur)} cur={kc('contribution')} prev={pc('contribution')} help="Confirmed revenue × gross margin − ad spend. Needs gross margin in the client profile." />
            <Kpi k="budget" label={ctx.period === 'month' ? 'Budget left this month' : 'Budget left'} src="calc" value={budgetLeft === null ? '—' : money(budgetLeft, cur)} help="Monthly budget (client profile) − spend so far. Shown for “This month” only." />
          </div>
          {!single.crm_linked && <div className="text-xs text-glass-muted">CRM numbers are not available for this client: it is not linked to CRM leads (Clients → CRM leads).</div>}
        </>
      ) : (
        <div className="glass-card p-4 overflow-x-auto">
          <h3 className="font-bold mb-2">Clients</h3>
          {o.clients.length === 0 ? <Empty>No clients yet.</Empty> : (
            <table className="w-full text-sm">
              <thead><tr className="text-left text-xs text-glass-muted"><th className="py-1 pr-2">Client</th><th className="pr-2">Spend</th><th className="pr-2">Leads</th><th className="pr-2">Qualified</th><th className="pr-2">Customers</th><th className="pr-2">CPL</th><th className="pr-2">Revenue (CRM)</th></tr></thead>
              <tbody>
                {o.clients.map((c) => (
                  <tr key={c.client_id} className="border-t" style={{ borderColor: 'var(--border-subtle)' }}>
                    <td className="py-2 pr-2"><button type="button" className="font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setParams({ client: c.client_id })}>{c.name}</button></td>
                    <td className="pr-2">{c.mixed_currency ? 'mixed' : money(c.spend, c.currency)}</td>
                    <td className="pr-2">{c.crm_linked ? int(c.crm?.leads) : '—'}</td><td className="pr-2">{c.crm_linked ? int(c.crm?.qualified) : '—'}</td>
                    <td className="pr-2">{c.crm_linked ? int(c.crm?.customers) : '—'}</td><td className="pr-2">{money(c.crm?.cpl, c.currency)}</td>
                    <td className="pr-2">{c.crm_linked ? money(c.crm?.revenue, c.currency) : '—'}</td>
                  </tr>))}
              </tbody>
            </table>)}
          <p className="text-[11px] text-glass-muted mt-2">Totals are per client because clients can use different currencies.</p>
        </div>
      )}
      <div className="glass-card p-4">
        <h3 className="font-bold mb-3">What needs attention</h3>
        {todo.length === 0 ? <div className="text-sm" style={{ color: '#1E7B34' }}>All good. Nothing needs you right now.</div> : (
          <ul className="space-y-2">
            {todo.map((a, i) => (
              <li key={i} className="flex items-center gap-3 p-3 rounded-2xl" style={{ background: `${a.tone}14` }}>
                <span className="h-2.5 w-2.5 rounded-full shrink-0" style={{ background: a.tone }} />
                <div className="flex-1 min-w-0"><div className="text-sm font-semibold">{a.text}</div>{a.sub && <div className="text-xs text-glass-secondary break-words">{a.sub}</div>}</div>
                {a.to && <Btn ghost onClick={() => go(a.to)}>{a.btn}</Btn>}
              </li>))}
          </ul>)}
      </div>
      <div className="grid md:grid-cols-2 gap-3">
        <div className="glass-card p-4"><h3 className="font-bold mb-2 text-sm">Ad spend per day <Src s="platform" /></h3>
          <Bars data={trend} value={(d) => d.spend} label="Ad spend per day" fmt={(v) => money(v, cur)} /></div>
        <div className="glass-card p-4"><h3 className="font-bold mb-2 text-sm">CRM leads per day <Src s="crm" /></h3>
          <Bars data={leadsTrend} value={(d) => d.leads} label="CRM leads per day" color="#34C759" /></div>
      </div>
      <div className="glass-card p-4 overflow-x-auto">
        <h3 className="font-bold mb-2">Platform comparison <Src s="platform" /></h3>
        <table className="w-full text-sm">
          <thead><tr className="text-left text-xs text-glass-muted"><th className="py-1 pr-2">Platform</th><th className="pr-2">Spend</th><th className="pr-2">Impressions</th><th className="pr-2">Clicks</th><th className="pr-2">CTR</th><th className="pr-2">CPC</th><th className="pr-2">Conversions</th><th className="pr-2">ROAS</th></tr></thead>
          <tbody>
            {['google', 'meta'].flatMap((p) => ((o.by_platform[p] || []).length ? o.by_platform[p] : [null]).map((r, i) => (
              <tr key={`${p}${i}`} className="border-t" style={{ borderColor: 'var(--border-subtle)' }}>
                <td className="py-2 pr-2 font-semibold">{p === 'google' ? 'Google Ads' : 'Meta'}{r && (o.by_platform[p].length > 1) ? ` (${r.currency})` : ''}</td>
                {r ? <><td className="pr-2">{money(r.spend, r.currency)}</td><td className="pr-2">{int(r.impressions)}</td><td className="pr-2">{int(r.clicks)}</td><td className="pr-2">{pct(r.ctr)}</td>
                  <td className="pr-2">{money(r.cpc, r.currency)}</td><td className="pr-2">{int(r.conversions)}</td><td className="pr-2">{ratio(r.platform_roas)}</td></>
                  : <td className="pr-2 text-glass-muted" colSpan={7}>No data</td>}
              </tr>)))}
          </tbody>
        </table>
      </div>
      <div className="glass-card p-4">
        <h3 className="font-bold mb-2">Integration health</h3>
        {o.accounts.length === 0 ? <Empty>No accounts.</Empty> : (
          <ul className="space-y-2">{o.accounts.map((a) => (
            <li key={a.id} className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-semibold">{a.platform === 'google' ? 'Google Ads' : 'Meta'}</span><span>{a.name || a.external_id}</span>
              <span className="text-glass-muted text-xs">{a.client}</span><StatusChip s={a.status} />
              <span className="text-xs text-glass-muted">last good sync {ago(a.last_ok_at)}</span>
            </li>))}</ul>)}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Campaigns
async function draftChange(c, kind, after, summary, recommendation) {
  const g = await run(rpc('api_ads_check', { p_campaign: c.id, p_kind: kind, p_after: after }));
  if (!g) return false;
  const items = [...g.blockers, ...g.confirms, ...g.warnings].map((i) => `• ${i.message}`).join('\n');
  if (g.blockers.length) { showToast(g.blockers[0].message, 'error'); return false; }
  if (!(await confirmDialog(summary, { message: `${items ? `${items}\n\n` : ''}This goes to Approvals. Nothing is sent until someone approves it.`, confirmText: 'Send for approval' }))) return false;
  return !!(await run(rpc('api_ads_change_create', { p_campaign: c.id, p_kind: kind, p_after: after, p_summary: summary, p_recommendation: recommendation || null }), 'Sent for approval.'));
}

// Google's delivery verdict (campaign.primary_status + reasons) in plain words.
const DELIVERY = {
  ELIGIBLE: ['Showing', 'rgba(52,199,89,0.14)', '#1E7B34'], LEARNING: ['Learning', 'rgba(0,122,255,0.12)', '#0A58CA'],
  LIMITED: ['Limited', 'rgba(255,149,0,0.16)', '#9A5B00'], PENDING: ['Not started yet', undefined, undefined],
  MISCONFIGURED: ['Not showing: setup problem', 'rgba(255,59,48,0.12)', '#B42318'], NOT_ELIGIBLE: ['Not showing', 'rgba(255,59,48,0.12)', '#B42318'],
  ENDED: ['Ended', undefined, undefined],
};
const REASON = {
  BUDGET_CONSTRAINED: 'Budget limits delivery', BUDGET_MISCONFIGURED: 'Budget is set up wrongly',
  BIDDING_STRATEGY_LEARNING: 'Bid strategy is learning', BIDDING_STRATEGY_LIMITED: 'Bid strategy is limited', BIDDING_STRATEGY_CONSTRAINED: 'Bid strategy is constrained',
  BIDDING_STRATEGY_MISCONFIGURED: 'Bid strategy is set up wrongly', SEARCH_VOLUME_LIMITED: 'Keywords have low search volume',
  HAS_ADS_DISAPPROVED: 'Some ads are disapproved', HAS_ADS_LIMITED_BY_POLICY: 'Some ads are limited by policy',
  MOST_ADS_UNDER_REVIEW: 'Ads are under review', MOST_ASSET_GROUPS_UNDER_REVIEW: 'Asset groups are under review',
  HAS_ASSET_GROUPS_DISAPPROVED: 'Some asset groups are disapproved', HAS_ASSET_GROUPS_LIMITED_BY_POLICY: 'Some asset groups are limited by policy',
  NO_KEYWORDS: 'No keywords', KEYWORDS_PAUSED: 'All keywords are paused', NO_AD_GROUPS: 'No ad groups', AD_GROUPS_PAUSED: 'All ad groups are paused',
  NO_AD_GROUP_ADS: 'No ads', AD_GROUP_ADS_PAUSED: 'All ads are paused', NO_ASSET_GROUPS: 'No asset groups', ASSET_GROUPS_PAUSED: 'All asset groups are paused',
  MISSING_LOCATION_TARGETING: 'No location targeting', MISSING_CALL_EXTENSION: 'Call asset missing', MISSING_LEAD_FORM_EXTENSION: 'Lead form missing',
  CALL_EXTENSION_DISAPPROVED: 'Call asset disapproved', CALL_EXTENSION_UNDER_REVIEW: 'Call asset under review',
  LEAD_FORM_EXTENSION_DISAPPROVED: 'Lead form disapproved', LEAD_FORM_EXTENSION_UNDER_REVIEW: 'Lead form under review',
  CAMPAIGN_PENDING: 'Start date is in the future', CAMPAIGN_ENDED: 'End date has passed', CAMPAIGN_DRAFT: 'Still a draft',
  CAMPAIGN_GROUP_PAUSED: 'Campaign group is paused', CAMPAIGN_GROUP_ALL_GROUP_BUDGETS_ENDED: 'Campaign group budgets have ended',
};
const SKIP_REASON = new Set(['CAMPAIGN_PAUSED', 'CAMPAIGN_REMOVED', 'UNKNOWN', 'UNSPECIFIED']);
function Delivery({ c }) {
  const d = c.delivery;
  if (!d || c.status !== 'ENABLED') return null;                  // paused/removed already say it all
  const look = DELIVERY[d.primary_status];
  const reasons = (d.reasons || []).filter((r) => !SKIP_REASON.has(r)).map((r) => REASON[r] || r.toLowerCase().replace(/_/g, ' '));
  if (!look && !reasons.length) return null;
  return (
    <div className="flex flex-wrap items-center gap-1.5 mt-2 text-xs" data-testid="delivery">
      {look && <Chip bg={look[1]} fg={look[2]}>{look[0]}</Chip>}
      {reasons.map((r) => <span key={r} className="px-2 py-0.5 rounded-full bg-black/5 text-glass-secondary">{r}</span>)}
    </div>
  );
}

function Campaigns({ ctx, access }) {
  const [rows, load, err] = useLoad(() => rpc('api_ads_campaigns', { p_client: ctx.client || null, p_from: ctx.from, p_to: ctx.to }), [ctx.client, ctx.from, ctx.to]);
  const [q, setQ] = useState('');
  const [sort, setSort] = useState('spend');
  const list = useMemo(() => {
    const val = (r) => { const v = sort === 'leads' ? r.crm?.leads : r[sort]; return isNum(v) ? Number(v) : null; };
    const asc = sort === 'cpl';                                   // cheapest first; campaigns with no CPL last
    return (rows || []).filter((r) => !q || `${r.name} ${r.client} ${r.account}`.toLowerCase().includes(q.toLowerCase()))
      .sort((a, b) => { const x = val(a), y = val(b); if (x === null) return y === null ? 0 : 1; if (y === null) return -1; return asc ? x - y : y - x; });
  }, [rows, q, sort]);
  if (err) return <Err msg={err} />;
  if (!rows) return <Empty>Loading…</Empty>;
  const budget = async (c) => {
    const v = await promptDialog(`New daily budget for “${c.name}”`, { message: `Now: ${money(c.daily_budget, c.currency)} a day.`, placeholder: 'e.g. 1500', required: true });
    if (v === null) return;
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0) { showToast('Enter a number above 0', 'error'); return; }
    if (await draftChange(c, 'budget', { daily_budget: n }, `${c.name}: daily budget ${money(c.daily_budget, c.currency)} → ${money(n, c.currency)}`)) load();
  };
  const toggle = async (c) => {
    const to = c.status === 'ENABLED' ? 'PAUSED' : 'ENABLED';
    if (await draftChange(c, 'status', { status: to }, `${c.name}: ${to === 'PAUSED' ? 'pause' : 'turn on'}`)) load();
  };
  const mapUtm = async (c) => {
    const v = await promptDialog(`UTM campaign for “${c.name}”`, { message: `CRM leads whose utm_campaign equals this value count for this campaign. Now: ${c.utm_campaign || 'not set'}. Leave empty to remove.`, placeholder: 'e.g. cpl_search_delhi' });
    if (v === null) return;
    if (await run(rpc('api_ads_campaign_map', { p_campaign: c.id, p_utm_campaign: v }), 'Saved.')) load();
  };
  const csv = () => download(`campaigns_${ctx.from}_${ctx.to}.csv`, toCsv(list, [['client', 'Client'], ['platform', 'Platform'], ['account', 'Account'], ['name', 'Campaign'], ['status', 'Status'],
    ['currency', 'Currency'], ['daily_budget', 'Daily budget'], ['spend', 'Spend (platform)'], ['impressions', 'Impressions'], ['clicks', 'Clicks'], ['ctr', 'CTR %'], ['cpc', 'CPC'],
    ['conversions', 'Conversions (platform)'], ['conversion_value', 'Conversion value (platform)'], [(r) => r.crm?.leads, 'Leads (CRM)'], [(r) => r.crm?.qualified, 'Qualified (CRM)'],
    [(r) => r.crm?.customers, 'Customers (CRM)'], ['cpl', 'CPL'], ['qualified_cpl', 'Qualified CPL'], ['utm_campaign', 'utm_campaign']]));
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2 items-center">
        <Input placeholder="Search campaigns" value={q} onChange={(e) => setQ(e.target.value)} className="max-w-xs" aria-label="Search campaigns" />
        <select className="glass-input px-3 py-2 text-sm" value={sort} onChange={(e) => setSort(e.target.value)} aria-label="Sort by">
          <option value="spend">Sort: spend</option><option value="clicks">Sort: clicks</option><option value="leads">Sort: CRM leads</option><option value="cpl">Sort: CPL</option>
        </select>
        <Btn ghost onClick={csv} disabled={!list.length}><Icon name="external" size={14} />Export CSV</Btn>
      </div>
      {list.length === 0 ? <Empty>{rows.length ? 'No campaign matches.' : 'No campaigns yet. Add accounts and press Sync now on Home.'}</Empty> : (
        <div className="space-y-2">
          {list.map((c) => (
            <div key={c.id} className="glass-card p-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-semibold text-glass-primary">{c.name}</span>
                <Chip>{c.platform === 'google' ? 'Google Ads' : 'Meta'}</Chip>
                <Chip bg={c.status === 'ENABLED' ? 'rgba(52,199,89,0.14)' : undefined} fg={c.status === 'ENABLED' ? '#1E7B34' : undefined}>{c.status === 'ENABLED' ? 'On' : c.status === 'PAUSED' ? 'Paused' : c.status}</Chip>
                {!ctx.client && <span className="text-xs text-glass-muted">{c.client}</span>}
                {c.account_status !== 'connected' && <StatusChip s={c.account_status} />}
              </div>
              <Delivery c={c} />
              <div className="grid grid-cols-3 sm:grid-cols-6 gap-2 mt-2 text-xs">
                <div><div className="text-glass-muted">Spend</div><div className="font-semibold">{money(c.spend, c.currency)}</div></div>
                <div><div className="text-glass-muted">Clicks · CTR</div><div className="font-semibold">{int(c.clicks)} · {pct(c.ctr)}</div></div>
                <div><div className="text-glass-muted">CPC</div><div className="font-semibold">{money(c.cpc, c.currency)}</div></div>
                <div><div className="text-glass-muted">Platform conv.</div><div className="font-semibold">{int(c.conversions)}</div></div>
                <div><div className="text-glass-muted">CRM leads · qualified</div><div className="font-semibold">{c.crm_linked ? `${int(c.crm?.leads)} · ${int(c.crm?.qualified)}` : <span title="Set the UTM campaign to link CRM leads">not linked</span>}</div></div>
                <div><div className="text-glass-muted">CPL</div><div className="font-semibold">{money(c.cpl, c.currency)}</div></div>
              </div>
              <div className="flex flex-wrap gap-2 mt-2 items-center">
                <span className="text-xs text-glass-muted">Daily budget {c.budget_editable ? money(c.daily_budget, c.currency) : 'set in the platform (shared / ad-set / lifetime)'}</span>
                <span className="flex-1" />
                {c.budget_editable && <Btn ghost onClick={() => budget(c)}>Change budget</Btn>}
                {(c.status === 'ENABLED' || c.status === 'PAUSED') && <Btn ghost onClick={() => toggle(c)}>{c.status === 'ENABLED' ? 'Pause' : 'Turn on'}</Btn>}
                {access.is_admin && <Btn ghost onClick={() => mapUtm(c)}>UTM: {c.utm_campaign || 'not set'}</Btn>}
              </div>
            </div>))}
        </div>)}
      <p className="text-[11px] text-glass-muted">Spend, clicks and conversions are reported by the platform. Leads and CPL use the CRM. Synced {rows[0]?.synced_at ? ago(rows[0].synced_at) : '—'}.</p>
    </div>
  );
}

// ---------------------------------------------------------------- Leads & Revenue
function LeadsRevenue({ ctx, access, clients }) {
  const client = (clients || []).find((c) => c.id === ctx.client);
  const [leads, , lErr] = useLoad(() => (ctx.client ? rpc('api_ads_leads', { p_client: ctx.client, p_from: ctx.from, p_to: ctx.to }) : Promise.resolve(null)), [ctx.client, ctx.from, ctx.to]);
  const [rev, loadRev] = useLoad(() => (ctx.client ? rpc('api_ads_revenue', { p_client: ctx.client, p_from: ctx.from, p_to: ctx.to }) : Promise.resolve(null)), [ctx.client, ctx.from, ctx.to]);
  const [f, setF] = useState({ kind: 'sale', amount: '', on: todayIn(), lead: '', note: '' });
  if (!ctx.client) return <Empty>Pick a client at the top to see its ad leads and revenue.</Empty>;
  if (client && !client.crm_segment) return <Empty>{client.name} is not linked to CRM leads. Link it in More → Clients (CRM leads).</Empty>;
  const add = async () => {
    const id = await run(rpc('api_ads_revenue_add', { p_client: ctx.client, p_kind: f.kind, p_amount: Number(f.amount), p_on: f.on, p_lead: f.lead || null, p_note: f.note || null }), 'Recorded.');
    if (id) { setF({ ...f, amount: '', lead: '', note: '' }); loadRev(); }
  };
  const del = async (r) => { if (await confirmDialog(`Delete this ${r.kind} of ${money(r.amount, r.currency)}?`, { danger: true, confirmText: 'Delete' }) && await run(rpc('api_ads_revenue_delete', { p_id: r.id }), 'Deleted.')) loadRev(); };
  return (
    <div className="space-y-4">
      <div className="glass-card p-4">
        <h3 className="font-bold mb-1">Leads from ads <Src s="crm" /></h3>
        <p className="text-xs text-glass-muted mb-2">CRM leads in this period whose utm_campaign matches a campaign, or whose utm_source matches an account.</p>
        <Err msg={lErr} />
        {!leads ? <Empty>Loading…</Empty> : leads.length === 0 ? <Empty>No ad leads in this period.</Empty> : (
          <div className="overflow-x-auto"><table className="w-full text-sm">
            <thead><tr className="text-left text-xs text-glass-muted"><th className="py-1 pr-2">Lead</th><th className="pr-2">When</th><th className="pr-2">Campaign / source</th><th className="pr-2">Valid</th><th className="pr-2">Qualified</th><th className="pr-2">Customer</th></tr></thead>
            <tbody>{leads.map((l) => (
              <tr key={l.id} className="border-t" style={{ borderColor: 'var(--border-subtle)' }}>
                <td className="py-2 pr-2 font-semibold">{l.name}</td>
                <td className="pr-2 text-xs">{new Date(l.created_at).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}</td>
                <td className="pr-2 text-xs">{l.campaign || l.utm_source || '—'}</td>
                <td className="pr-2">{l.outcome.valid ? 'Yes' : 'No'}</td><td className="pr-2">{l.outcome.qualified ? 'Yes' : 'No'}</td><td className="pr-2">{l.customer ? 'Yes' : 'No'}</td>
              </tr>))}</tbody></table></div>)}
      </div>
      <div className="glass-card p-4">
        <h3 className="font-bold mb-1">Confirmed revenue <Src s="crm" /></h3>
        <p className="text-xs text-glass-muted mb-3">Money actually received from customers. Kept apart from the conversion value Google/Meta report.</p>
        {access.can_approve && (
          <div className="grid sm:grid-cols-6 gap-2 mb-3 items-end">
            <Field label="Type"><select className="glass-input w-full px-3 py-2 text-sm" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="sale">Sale</option><option value="refund">Refund</option></select></Field>
            <Field label={`Amount (${client?.currency || ''})`}><Input inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></Field>
            <Field label="Date"><Input type="date" value={f.on} onChange={(e) => setF({ ...f, on: e.target.value })} /></Field>
            <Field label="Lead (optional)"><select className="glass-input w-full px-3 py-2 text-sm" value={f.lead} onChange={(e) => setF({ ...f, lead: e.target.value })}><option value="">—</option>{(leads || []).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
            <Field label="Note"><Input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
            <Btn onClick={add} disabled={!(Number(f.amount) > 0)}><Icon name="plus" size={14} />Add</Btn>
          </div>)}
        {!rev ? <Empty>Loading…</Empty> : rev.length === 0 ? <Empty>Nothing recorded in this period.</Empty> : (
          <ul className="divide-y" style={{ borderColor: 'var(--border-subtle)' }}>{rev.map((r) => (
            <li key={r.id} className="py-2 flex items-center gap-2 text-sm">
              <Chip bg={r.kind === 'sale' ? 'rgba(52,199,89,0.14)' : 'rgba(255,59,48,0.12)'} fg={r.kind === 'sale' ? '#1E7B34' : '#C4261D'}>{r.kind}</Chip>
              <span className="font-semibold">{money(r.amount, r.currency)}</span><span className="text-xs text-glass-muted">{r.occurred_on}</span>
              <span className="text-xs text-glass-secondary flex-1 truncate">{[r.lead_name, r.note].filter(Boolean).join(' · ')}</span>
              {access.is_admin && <button type="button" onClick={() => del(r)} className="text-xs" style={{ color: '#C4261D' }}>Delete</button>}
            </li>))}</ul>)}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Approvals
const Q_STATUS = { pending: 'Waiting', approved: 'Approved, sending soon', executing: 'Sending', verified: 'Done and checked', failed: 'Failed', outcome_unknown: 'Sent, result unknown (re-checking)', rejected: 'Rejected', cancelled: 'Cancelled', stale: 'Out of date' };
function Approvals({ access, onChange }) {
  const [view, setView] = useState('pending');
  const [rows, load, err] = useLoad(() => rpc('api_ads_queue', { p_status: view === 'pending' ? 'pending' : null }), [view]);
  const [busy, setBusy] = useState(false);
  const approve = async (q) => {
    let second = false;
    if (q.needs_second_confirm) {
      const msgs = (q.guard_result.confirms || []).map((c) => c.message).join('\n');
      if (!(await confirmDialog('Second confirm', { message: `${msgs}\n\nApprove anyway?`, confirmText: 'Yes, approve' }))) return;
      second = true;
    }
    if (await run(rpc('api_ads_approve', { p_id: q.id, p_second_confirm: second }), 'Approved.')) {
      setBusy(true);
      const r = await run(edge({ jobs: ['execute'] }));
      setBusy(false);
      if (r?.results?.execute) showToast(r.results.execute.detail || 'Processed', r.results.execute.status === 'ok' ? 'success' : 'error');
      load(); onChange();
    }
  };
  const reject = async (q) => {
    const why = await promptDialog('Why reject?', { placeholder: 'A few words', required: true });
    if (why !== null && await run(rpc('api_ads_reject', { p_id: q.id, p_reason: why }), 'Rejected.')) { load(); onChange(); }
  };
  if (err) return <Err msg={err} />;
  return (
    <div className="space-y-3">
      <div className="flex gap-1 p-1 rounded-xl w-max" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {[['pending', 'Waiting'], ['all', 'History']].map(([v, l]) => (
          <button key={v} type="button" onClick={() => setView(v)} aria-pressed={view === v} className={`px-3 py-1.5 rounded-lg text-sm ${view === v ? 'bg-white font-semibold shadow-sm' : ''}`}>{l}</button>))}
      </div>
      {busy && <div className="text-xs text-glass-muted">Sending and checking with the platform…</div>}
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>{view === 'pending' ? 'Nothing waiting.' : 'No changes yet.'}</Empty> : rows.map((q) => (
        <div key={q.id} className="glass-card p-3">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold">{q.summary || `${q.campaign}: ${q.kind}`}</span>
            <Chip>{q.platform === 'google' ? 'Google Ads' : 'Meta'}</Chip><span className="text-xs text-glass-muted">{q.client}</span>
            <Chip bg={q.status === 'verified' ? 'rgba(52,199,89,0.14)' : ['failed', 'outcome_unknown', 'stale'].includes(q.status) ? 'rgba(255,59,48,0.12)' : undefined}
              fg={q.status === 'verified' ? '#1E7B34' : ['failed', 'outcome_unknown', 'stale'].includes(q.status) ? '#C4261D' : undefined}>{Q_STATUS[q.status] || q.status}</Chip>
          </div>
          <div className="text-xs text-glass-secondary mt-1">
            {q.kind === 'budget' ? `Daily budget ${money(q.before?.daily_budget, q.currency)} → ${money(q.after?.daily_budget, q.currency)}` : `Status ${q.before?.status} → ${q.after?.status}`}
            {' · '}by {q.created_by_name || q.created_by_type} {ago(q.created_at)}{q.approved_by_name ? ` · approved by ${q.approved_by_name}` : ''}
          </div>
          {q.error && <div className="text-xs mt-1" style={{ color: '#C4261D' }}>{q.error}</div>}
          {q.status === 'pending' && <GuardList g={q.guard_result} />}
          {q.status === 'pending' && (
            <div className="flex gap-2 mt-2">
              {access.can_approve && <Btn tone="#248A3D" onClick={() => approve(q)} disabled={busy || (q.guard_result?.blockers || []).length > 0}>Approve and send</Btn>}
              <Btn ghost onClick={() => reject(q)}>{access.can_approve ? 'Reject' : 'Cancel'}</Btn>
            </div>)}
        </div>))}
    </div>
  );
}

// ---------------------------------------------------------------- Recommendations
function Recommendations({ ctx, onChange }) {
  const [rows, load, err] = useLoad(() => rpc('api_ads_recommendations', { p_client: ctx.client || null, p_status: 'open' }), [ctx.client]);
  const [camps] = useLoad(() => rpc('api_ads_campaigns', { p_client: ctx.client || null, p_from: ctx.from, p_to: ctx.to }), [ctx.client]);
  const runNow = async () => { const n = await run(rpc('api_ads_recommend_run')); if (n !== undefined) { showToast(`${n} new`, 'success'); load(); } };
  const dismiss = async (r) => { const why = await promptDialog('Why dismiss?', { required: true }); if (why !== null && await run(rpc('api_ads_recommendation_dismiss', { p_id: r.id, p_reason: why }), 'Dismissed.')) load(); };
  const act = async (r) => {
    const c = (camps || []).find((x) => x.id === r.campaign_id);
    if (!c) { showToast('Campaign not found in this view', 'error'); return; }
    if (await draftChange(c, r.proposed_change.kind, r.proposed_change.after, `${c.name}: ${r.proposed_action}`, r.id)) { load(); onChange(); }
  };
  if (err) return <Err msg={err} />;
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-2"><p className="text-xs text-glass-muted">Made by fixed rules from synced data and CRM leads (no AI). Limits are in Settings → Rules.</p><Btn ghost onClick={runNow}>Check now</Btn></div>
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No open recommendations.</Empty> : rows.map((r) => (
        <div key={r.id} className="glass-card p-3 space-y-1 text-sm">
          <div className="flex flex-wrap gap-2 items-center"><span className="font-semibold">{r.campaign || r.client}</span><Chip>confidence: {r.confidence}</Chip><Chip>money at risk: {r.financial_risk}</Chip></div>
          <div><b>Seen:</b> {r.observation}</div>
          <div><b>Why it matters:</b> {r.reasoning}</div>
          {r.alternatives && <div className="text-glass-secondary"><b>Other explanations:</b> {r.alternatives}</div>}
          <div><b>Suggested:</b> {r.proposed_action}</div>
          {r.expected_impact && <div className="text-glass-secondary"><b>Expected effect:</b> {r.expected_impact}</div>}
          <details className="text-xs text-glass-muted"><summary>Data used</summary><pre className="whitespace-pre-wrap">{JSON.stringify(r.source_data, null, 2)}</pre></details>
          <div className="flex gap-2 pt-1">
            {r.proposed_change && <Btn onClick={() => act(r)}>Send change for approval</Btn>}
            <Btn ghost onClick={() => dismiss(r)}>Dismiss</Btn>
          </div>
        </div>))}
    </div>
  );
}

// ---------------------------------------------------------------- Clients
const PLATFORM_LABEL = { google: 'Google Ads', meta: 'Meta' };
// mode: list | new | edit | import. Wizard and import screens live in AdsClientWizard.jsx.
function Clients({ access, clients, reload, initialMode, clientsErr }) {
  const [mode, setMode] = useState(initialMode || 'list');
  const [edit, setEdit] = useState(null);
  const [options, reloadOptions, optErr] = useLoad(() => rpc('api_ads_options'));
  const save = async (data) => {
    const id = await run(rpc('api_ads_client_save', { p_data: data }), data.is_draft ? 'Draft saved.' : 'Client saved.');
    if (id) { setMode('list'); setEdit(null); reload(); }
  };
  const discover = async () => {
    const r = await run(edge({ jobs: ['discover'] }));
    return r?.results?.discover;
  };
  const doImport = async (payload) => {
    const r = await run(rpc('api_ads_import', { p_data: payload }));
    if (!r) return;
    showToast(`Imported ${r.added} account${r.added === 1 ? '' : 's'}${r.skipped?.length ? `, skipped ${r.skipped.length}` : ''}. Getting their data…`, 'success');
    await reload();
    const s = await run(edge({ jobs: ['sync'] }));
    if (s?.results?.sync) showToast(s.results.sync.detail || s.results.sync.status, s.results.sync.status === 'ok' ? 'success' : 'error');
    const fresh = await rpc('api_ads_clients').catch(() => null);
    const c = (fresh || []).find((x) => x.id === r.client_id);
    reload();
    if (c?.is_draft) { setEdit(c); setMode('edit'); showToast('Now finish the setup: objectives and targets.', 'info'); }
    else setMode('list');
  };
  const m = access.is_admin ? mode : 'list';
  if (m === 'new' || m === 'edit') {
    if (optErr) return <div className="space-y-2"><Err msg={`Could not load the setup options: ${optErr}`} /><Btn ghost onClick={reloadOptions}>Try again</Btn></div>;
    if (!options) return <Empty>Loading…</Empty>;
    return <ClientWizard key={edit?.id || 'new'} options={options} initial={m === 'edit' ? Object.fromEntries(Object.entries(edit).map(([k, v]) => [k, v ?? ''])) : undefined}
      onSave={save} onCancel={() => { setMode('list'); setEdit(null); }} onImport={() => setMode('import')} />;
  }
  if (m === 'import') return <ImportAccounts clients={clients} options={options} discover={discover} onImport={doImport} onCancel={() => setMode('list')} goSettings={() => navigate('ads', 'settings')} />;
  return (
    <div className="space-y-2">
      {access.is_admin && (
        <div className="flex flex-wrap gap-2">
          <Btn onClick={() => setMode('new')}><Icon name="plus" size={14} />New client</Btn>
          <Btn ghost onClick={() => setMode('import')}><Icon name="search" size={14} />Import existing accounts</Btn>
        </div>)}
      {clientsErr ? <Err msg={clientsErr} /> : !clients ? <Empty>Loading…</Empty> : clients.length === 0 ? <Empty>No clients yet. Create one, or import the Google Ads / Meta accounts you already run.</Empty> : clients.map((c) => (
        <div key={c.id} className="glass-card p-3 flex flex-wrap items-center gap-2">
          <div className="flex-1 min-w-0">
            <div className="font-semibold flex flex-wrap items-center gap-1.5">{c.name}
              {(c.platforms || []).map((p) => <Chip key={p} bg={p === 'google' ? 'rgba(26,115,232,0.12)' : 'rgba(8,102,255,0.12)'} fg={p === 'google' ? '#1A57B5' : '#0650C2'}>{PLATFORM_LABEL[p]}</Chip>)}
              {c.is_draft && <Chip bg="rgba(255,149,0,0.14)" fg="#B25E00">Setup not finished</Chip>}
              {!c.active && <Chip>inactive</Chip>}</div>
            <div className="text-xs text-glass-muted">{[c.industry, c.currency, c.timezone, c.crm_segment ? `CRM: ${c.crm_segment} leads` : 'CRM: not linked', `${c.accounts} account(s)`,
              c.target_cpl ? `target CPL ${money(c.target_cpl, c.currency)}` : null].filter(Boolean).join(' · ')}</div></div>
          <Btn ghost onClick={() => setParams({ client: c.id })}>Select</Btn>
          {access.is_admin && <Btn ghost={!c.is_draft} onClick={() => { setEdit(c); setMode('edit'); }}>{c.is_draft ? 'Finish setup' : 'Edit'}</Btn>}
        </div>))}
    </div>
  );
}

// ---------------------------------------------------------------- Accounts
function Accounts({ access, clients, ctx }) {
  const [rows, load, err] = useLoad(() => rpc('api_ads_accounts', { p_client: ctx.client || null }), [ctx.client]);
  const [f, setF] = useState({ client_id: ctx.client || '', platform: 'google', external_id: '', name: '', utm_source: '' });
  const add = async () => { if (await run(rpc('api_ads_account_save', { p_data: f }), 'Account added. Press Test connection in Settings.')) { setF({ ...f, external_id: '', name: '' }); load(); } };
  const toggle = async (a) => { if (await run(rpc('api_ads_account_save', { p_data: { id: a.id, disabled: a.status !== 'disabled' } }), 'Saved.')) load(); };
  const utm = async (a) => { const v = await promptDialog('utm_source for this account', { message: 'CRM leads with this utm_source and no matching campaign count for this account (e.g. google, facebook).' }); if (v !== null && await run(rpc('api_ads_account_save', { p_data: { id: a.id, utm_source: v } }), 'Saved.')) load(); };
  if (err) return <Err msg={err} />;
  return (
    <div className="space-y-3">
      {access.is_admin && (
        <div className="glass-card p-4 grid sm:grid-cols-6 gap-2 items-end">
          <Field label="Client"><select className="glass-input w-full px-3 py-2 text-sm" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })}><option value="">Pick…</option>{(clients || []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
          <Field label="Platform"><select className="glass-input w-full px-3 py-2 text-sm" value={f.platform} onChange={(e) => setF({ ...f, platform: e.target.value })}><option value="google">Google Ads</option><option value="meta">Meta</option></select></Field>
          <Field label={f.platform === 'google' ? 'Customer ID' : 'Ad account ID'} hint={f.platform === 'google' ? '123-456-7890' : 'act_… or digits'}><Input value={f.external_id} onChange={(e) => setF({ ...f, external_id: e.target.value })} /></Field>
          <Field label="Name (optional)"><Input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <Field label="utm_source (optional)"><Input value={f.utm_source} placeholder={f.platform === 'google' ? 'google' : 'facebook'} onChange={(e) => setF({ ...f, utm_source: e.target.value })} /></Field>
          <Btn onClick={add} disabled={!f.client_id || !f.external_id}><Icon name="plus" size={14} />Add</Btn>
        </div>)}
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No accounts.</Empty> : rows.map((a) => (
        <div key={a.id} className="glass-card p-3 flex flex-wrap items-center gap-2 text-sm">
          <span className="font-semibold">{a.platform === 'google' ? 'Google Ads' : 'Meta'}</span><span>{a.name || a.external_id}</span><span className="text-xs text-glass-muted">{a.external_id} · {a.client} · {a.currency || 'currency unknown'} · {a.campaigns} campaigns</span>
          <StatusChip s={a.status} /><span className="text-xs text-glass-muted">synced {ago(a.last_sync_at)}</span>
          {a.last_error && <div className="w-full text-xs" style={{ color: '#C4261D' }}>{a.last_error}</div>}
          {access.is_admin && <div className="w-full flex gap-2"><Btn ghost onClick={() => utm(a)}>utm_source: {a.utm_source || 'not set'}</Btn><Btn ghost onClick={() => toggle(a)}>{a.status === 'disabled' ? 'Enable' : 'Disable'}</Btn></div>}
        </div>))}
    </div>
  );
}

// ---------------------------------------------------------------- Research & Experiments
const CLASS = { fact: ['Verified fact', '#1E7B34', 'rgba(52,199,89,0.14)'], inference: ['Reasoned inference', '#0062CC', 'rgba(0,122,255,0.12)'], hypothesis: ['Hypothesis', '#B25E00', 'rgba(255,149,0,0.14)'], unknown: ['Unknown', '#6E6E73', 'rgba(118,118,128,0.14)'] };
function Research({ ctx }) {
  const [rows, load, err] = useLoad(() => rpc('api_ads_research', { p_client: ctx.client || null }), [ctx.client]);
  const blank = { topic: '', competitor: '', observation: '', classification: 'fact', source_url: '', publisher: '', published_on: '', confidence: 'medium', interpretation: '', opportunity: '', action: '' };
  const [f, setF] = useState(null);
  const save = async () => { if (await run(rpc('api_ads_research_save', { p_data: { ...f, client_id: ctx.client } }), 'Saved.')) { setF(null); load(); } };
  if (!ctx.client) return <Empty>Pick a client at the top.</Empty>;
  if (err) return <Err msg={err} />;
  return (
    <div className="space-y-3">
      <p className="text-xs text-glass-muted">Research → evidence → interpretation → opportunity. A “verified fact” needs a source link. Never record a competitor's ROAS, CAC or budget unless they published it.</p>
      {f ? (
        <div className="glass-card p-4 grid sm:grid-cols-2 gap-3">
          <Field label="Topic"><Input value={f.topic} onChange={(e) => setF({ ...f, topic: e.target.value })} /></Field>
          <Field label="Competitor (optional)"><Input value={f.competitor} onChange={(e) => setF({ ...f, competitor: e.target.value })} /></Field>
          <div className="sm:col-span-2"><Field label="Observation"><textarea className="glass-input w-full px-3 py-2 text-sm" rows={2} value={f.observation} onChange={(e) => setF({ ...f, observation: e.target.value })} /></Field></div>
          <Field label="What kind of statement"><select className="glass-input w-full px-3 py-2 text-sm" value={f.classification} onChange={(e) => setF({ ...f, classification: e.target.value })}>{Object.entries(CLASS).map(([k, [l]]) => <option key={k} value={k}>{l}</option>)}</select></Field>
          <Field label="Confidence"><select className="glass-input w-full px-3 py-2 text-sm" value={f.confidence} onChange={(e) => setF({ ...f, confidence: e.target.value })}><option>low</option><option>medium</option><option>high</option></select></Field>
          <Field label="Source URL"><Input value={f.source_url} placeholder="https://" onChange={(e) => setF({ ...f, source_url: e.target.value })} /></Field>
          <Field label="Publisher / date"><div className="flex gap-2"><Input value={f.publisher} onChange={(e) => setF({ ...f, publisher: e.target.value })} /><Input type="date" value={f.published_on} onChange={(e) => setF({ ...f, published_on: e.target.value })} /></div></Field>
          <Field label="Interpretation"><Input value={f.interpretation} onChange={(e) => setF({ ...f, interpretation: e.target.value })} /></Field>
          <Field label="Opportunity / action"><Input value={f.opportunity} onChange={(e) => setF({ ...f, opportunity: e.target.value })} /></Field>
          <div className="flex gap-2"><Btn onClick={save} disabled={!f.topic || !f.observation}>Save</Btn><Btn ghost onClick={() => setF(null)}>Cancel</Btn></div>
        </div>
      ) : <Btn onClick={() => setF(blank)}><Icon name="plus" size={14} />Add finding</Btn>}
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No research yet.</Empty> : rows.map((r) => { const [l, fg, bg] = CLASS[r.classification]; return (
        <div key={r.id} className="glass-card p-3 text-sm space-y-1">
          <div className="flex flex-wrap gap-2 items-center"><span className="font-semibold">{r.topic}</span>{r.competitor && <Chip>{r.competitor}</Chip>}<Chip bg={bg} fg={fg}>{l}</Chip><Chip>confidence: {r.confidence}</Chip></div>
          <div>{r.observation}</div>
          {r.interpretation && <div className="text-glass-secondary">Meaning: {r.interpretation}</div>}
          {r.opportunity && <div className="text-glass-secondary">Opportunity: {r.opportunity}</div>}
          <div className="text-xs text-glass-muted">{r.source_url ? <a href={r.source_url} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>{r.publisher || r.source_url}</a> : 'no source'}{r.published_on ? ` · published ${r.published_on}` : ''} · recorded {ago(r.retrieved_at)}</div>
        </div>); })}
    </div>
  );
}

function Experiments({ ctx }) {
  const [rows, load, err] = useLoad(() => rpc('api_ads_experiments', { p_client: ctx.client || null }), [ctx.client]);
  const [f, setF] = useState(null);
  const save = async () => { if (await run(rpc('api_ads_experiment_save', { p_data: { ...f, client_id: ctx.client } }), 'Saved.')) { setF(null); load(); } };
  if (!ctx.client) return <Empty>Pick a client at the top.</Empty>;
  if (err) return <Err msg={err} />;
  const T = (k, l, ta) => <Field label={l}>{ta ? <textarea className="glass-input w-full px-3 py-2 text-sm" rows={2} value={f[k] || ''} onChange={(e) => setF({ ...f, [k]: e.target.value })} /> : <Input value={f[k] || ''} onChange={(e) => setF({ ...f, [k]: e.target.value })} />}</Field>;
  return (
    <div className="space-y-3">
      {f ? (
        <div className="glass-card p-4 grid sm:grid-cols-2 gap-3">
          {T('name', 'Name')}
          <Field label="Type"><select className="glass-input w-full px-3 py-2 text-sm" value={f.kind || 'creative'} onChange={(e) => setF({ ...f, kind: e.target.value })}>{['creative', 'headline', 'cta', 'offer', 'audience', 'landing_page', 'budget', 'bidding'].map((k) => <option key={k}>{k}</option>)}</select></Field>
          <div className="sm:col-span-2">{T('hypothesis', 'Hypothesis', true)}</div>
          {T('control', 'Control (A)')}{T('treatment', 'Treatment (B)')}
          {T('primary_metric', 'Primary metric')}{T('sample_plan', 'Sample size / how long')}
          <Field label="Start"><Input type="date" value={f.starts_on || ''} onChange={(e) => setF({ ...f, starts_on: e.target.value })} /></Field>
          <Field label="End"><Input type="date" value={f.ends_on || ''} onChange={(e) => setF({ ...f, ends_on: e.target.value })} /></Field>
          {f.id && <>
            <Field label="Status"><select className="glass-input w-full px-3 py-2 text-sm" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>{['planned', 'running', 'analysing', 'done', 'stopped'].map((k) => <option key={k}>{k}</option>)}</select></Field>
            <Field label="Confidence in result"><select className="glass-input w-full px-3 py-2 text-sm" value={f.confidence || ''} onChange={(e) => setF({ ...f, confidence: e.target.value })}><option value="">—</option><option value="not_enough_data">Not enough data</option><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option></select></Field>
            <div className="sm:col-span-2">{T('result', 'Result', true)}</div>{T('decision', 'Decision')}
          </>}
          <div className="flex gap-2"><Btn onClick={save} disabled={!f.name || !f.hypothesis || !f.primary_metric}>Save</Btn><Btn ghost onClick={() => setF(null)}>Cancel</Btn></div>
        </div>
      ) : <Btn onClick={() => setF({ kind: 'creative' })}><Icon name="plus" size={14} />New experiment</Btn>}
      <p className="text-xs text-glass-muted">Do not call a result significant without enough data; choose “Not enough data” when unsure.</p>
      {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>No experiments yet.</Empty> : rows.map((x) => (
        <div key={x.id} className="glass-card p-3 text-sm">
          <div className="flex flex-wrap gap-2 items-center"><span className="font-semibold">{x.name}</span><Chip>{x.kind}</Chip><Chip>{x.status}</Chip>{x.confidence && <Chip>confidence: {x.confidence.replace(/_/g, ' ')}</Chip>}<span className="flex-1" /><Btn ghost onClick={() => setF(Object.fromEntries(Object.entries(x).map(([k, v]) => [k, v ?? ''])))}>Edit</Btn></div>
          <div className="text-glass-secondary mt-1">{x.hypothesis}</div>
          {x.result && <div className="mt-1"><b>Result:</b> {x.result}{x.decision ? ` · Decision: ${x.decision}` : ''}</div>}
        </div>))}
    </div>
  );
}

function Activity() {
  const [rows, , err] = useLoad(() => rpc('api_ads_activity', { p_limit: 300 }));
  const [runs] = useLoad(() => rpc('api_ads_sync_runs'));
  if (err) return <Err msg={err} />;
  return (
    <div className="grid lg:grid-cols-2 gap-3">
      <div className="glass-card p-4"><h3 className="font-bold mb-2">Who did what</h3>
        {!rows ? <Empty>Loading…</Empty> : rows.length === 0 ? <Empty>Nothing yet.</Empty> : (
          <ul className="space-y-1 text-xs">{rows.map((r, i) => <li key={i}><span className="text-glass-muted">{new Date(r.at).toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'short' })}</span> · <b>{r.who}</b> · {r.action.replace(/_/g, ' ')} {r.entity_id ? <span className="text-glass-muted">({r.entity} {String(r.entity_id).slice(0, 12)})</span> : null}</li>)}</ul>)}
      </div>
      <div className="glass-card p-4"><h3 className="font-bold mb-2">Sync runs</h3>
        {!runs ? <Empty>Loading…</Empty> : runs.length === 0 ? <Empty>No runs yet.</Empty> : (
          <ul className="space-y-1 text-xs">{runs.map((r) => <li key={r.id}><span className="text-glass-muted">{new Date(r.started_at).toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'short' })}</span> · <b>{r.job}</b> · {r.status}{r.detail ? ` · ${r.detail}` : ''}</li>)}</ul>)}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Settings (Admin)
const SECRETS = {
  google: [['GOOGLE_ADS_CLIENT_ID', 'OAuth client ID', 'Google Cloud → APIs & Services → Credentials (ends with .apps.googleusercontent.com). The project needs the Google Ads API enabled and Explorer access or higher to open live accounts (no developer token since 9 Sep 2026).'],
    ['GOOGLE_ADS_CLIENT_SECRET', 'OAuth client secret', ''],
    ['GOOGLE_ADS_REFRESH_TOKEN', 'Refresh token', 'From the OAuth consent of a user who can access the ad accounts (starts with 1//).'],
    ['GOOGLE_ADS_LOGIN_CUSTOMER_ID', 'Manager (MCC) customer ID', 'Only if accounts are reached through a manager account.']],
  meta: [['META_ACCESS_TOKEN', 'Access token', 'A System User token from Meta Business Settings with ads_read (and ads_management to change budgets/status).'],
    ['META_APP_ID', 'App ID', 'Optional, for reference.'], ['META_APP_SECRET', 'App secret', 'Optional. When set, every call carries appsecret_proof.']],
};
function Settings() {
  const [s, load, err] = useLoad(() => rpc('api_ads_settings'));
  const [rules, loadRules] = useLoad(() => rpc('api_ads_rules'));
  const [team, loadTeam] = useLoad(() => rpc('api_ads_team'));
  const [busy, setBusy] = useState(false);
  const save = async (name) => {
    const v = await promptDialog(`Paste ${name}`, { message: 'Stored encrypted in Supabase Vault. Only the last 4 characters are ever shown.', required: true, confirmText: 'Save' });
    if (v !== null && await run(rpc('api_ads_settings_save', { p_name: name, p_value: v }), 'Saved.')) load();
  };
  const del = async (name) => { if (await confirmDialog(`Remove ${name}?`, { danger: true, confirmText: 'Remove' }) && await run(rpc('api_ads_secret_delete', { p_name: name }), 'Removed.')) load(); };
  const cfg = async (k, label) => { const v = await promptDialog(label, { message: `Now: ${s.config[k]}`, required: true }); if (v !== null && await run(rpc('api_ads_settings_save', { p_name: k, p_value: v }), 'Saved.')) load(); };
  const stop = async () => {
    const on = s.config.execution_paused !== 'true';
    if (await confirmDialog(on ? 'Turn ON the emergency stop?' : 'Turn OFF the emergency stop?', { message: on ? 'No approved change will be sent to Google or Meta until it is turned off.' : 'Approved changes will start being sent again.', danger: on, confirmText: on ? 'Stop everything' : 'Resume' })
      && await run(rpc('api_ads_settings_save', { p_name: 'execution_paused', p_value: on ? 'true' : 'false' }), 'Saved.')) load();
  };
  const test = async () => {
    setBusy(true);
    const r = await run(edge({ jobs: ['test'] }));
    setBusy(false);
    if (r?.results?.test) Object.entries(r.results.test).forEach(([p, x]) => showToast(`${p}: ${x.detail || x.status}`, x.status === 'ok' ? 'success' : 'error'));
    load();
  };
  const rule = async (r) => {
    const v = await promptDialog(r.label, { message: `Now: ${JSON.stringify(r.value)}. Enter JSON with the same keys.`, required: true });
    if (v === null) return;
    let val; try { val = JSON.parse(v); } catch { showToast('Not valid JSON', 'error'); return; }
    if (await run(rpc('api_ads_rule_set', { p_code: r.code, p_value: val, p_active: r.active }), 'Saved.')) loadRules();
  };
  const ruleToggle = async (r) => { if (await run(rpc('api_ads_rule_set', { p_code: r.code, p_value: r.value, p_active: !r.active }), 'Saved.')) loadRules(); };
  const access = async (e, a, ap) => { if (await run(rpc('api_ads_team_set', { p_employee: e.id, p_access: a, p_can_approve: ap }), 'Saved.')) loadTeam(); };
  if (err) return <Err msg={err} />;
  if (!s) return <Empty>Loading…</Empty>;
  return (
    <div className="space-y-4">
      <div className="glass-card p-4 flex flex-wrap items-center gap-3" style={s.config.execution_paused === 'true' ? { boxShadow: 'inset 0 0 0 1px rgba(255,59,48,0.5)' } : undefined}>
        <div className="flex-1"><div className="font-bold">Emergency stop</div><div className="text-xs text-glass-secondary">{s.config.execution_paused === 'true' ? 'ON: nothing is being sent to the ad platforms.' : 'Off: approved changes are sent and checked.'}</div></div>
        <Btn tone={s.config.execution_paused === 'true' ? '#248A3D' : '#FF3B30'} onClick={stop}>{s.config.execution_paused === 'true' ? 'Resume' : 'Stop everything'}</Btn>
      </div>
      {['google', 'meta'].map((p) => {
        const t = s.tests?.[`test_${p}`];
        return (
          <div key={p} className="glass-card p-4">
            <div className="flex flex-wrap items-center gap-2 mb-2">
              <h3 className="font-bold flex-1">{p === 'google' ? 'Google Ads API' : 'Meta Marketing API'}</h3>
              {t ? <Chip bg={t.status === 'ok' ? 'rgba(52,199,89,0.14)' : 'rgba(255,59,48,0.12)'} fg={t.status === 'ok' ? '#1E7B34' : '#C4261D'}>{t.status === 'ok' ? 'Connected' : 'Not working'} · {ago(t.at)}</Chip> : <Chip>Not tested</Chip>}
              <a className="text-xs" style={{ color: 'var(--accent)' }} target="_blank" rel="noopener noreferrer" href={p === 'google' ? 'https://developers.google.com/google-ads/api/docs/get-started/introduction' : 'https://developers.facebook.com/docs/marketing-api/get-started'}>Docs</a>
            </div>
            {t?.detail && <div className="text-xs mb-2" style={{ color: t.status === 'ok' ? '#1E7B34' : '#C4261D' }}>{t.detail}</div>}
            <ul className="space-y-2">{SECRETS[p].map(([k, l, h]) => { const v = s.secrets[k]; return (
              <li key={k} className="flex flex-wrap items-center gap-2 text-sm">
                <div className="flex-1 min-w-[12rem]"><div className="font-medium">{l}</div>{h && <div className="text-[11px] text-glass-muted">{h}</div>}</div>
                <span className="text-xs text-glass-muted">{v?.set ? `••••${v.last4} · ${ago(v.updated_at)}` : 'not set'}</span>
                <Btn ghost onClick={() => save(k)}>{v?.set ? 'Replace' : 'Add'}</Btn>{v?.set && <Btn ghost onClick={() => del(k)}>Remove</Btn>}
              </li>); })}</ul>
            <div className="text-xs text-glass-muted mt-2">API version: {p === 'google' ? s.config.google_api_version : s.config.meta_api_version} <button type="button" style={{ color: 'var(--accent)' }} onClick={() => cfg(p === 'google' ? 'google_api_version' : 'meta_api_version', 'API version')}>change</button></div>
          </div>);
      })}
      <div className="flex flex-wrap gap-2 items-center">
        <Btn onClick={test} disabled={busy}><Icon name="refresh" size={14} />{busy ? 'Testing…' : 'Test connection'}</Btn>
        <span className="text-xs text-glass-muted">Days of metrics re-pulled each sync: {s.config.sync_days} <button type="button" style={{ color: 'var(--accent)' }} onClick={() => cfg('sync_days', 'Days (1–90)')}>change</button></span>
      </div>
      <div className="glass-card p-4"><h3 className="font-bold mb-2">Rules and limits</h3>
        {!rules ? <Empty>Loading…</Empty> : <ul className="space-y-2">{rules.map((r) => (
          <li key={r.code} className="flex flex-wrap items-center gap-2 text-sm"><span className="flex-1 min-w-[12rem]">{r.label}</span><code className="text-xs">{JSON.stringify(r.value)}</code>
            <Btn ghost onClick={() => rule(r)}>Edit</Btn><Btn ghost onClick={() => ruleToggle(r)}>{r.active ? 'On' : 'Off'}</Btn></li>))}</ul>}
      </div>
      <div className="glass-card p-4"><h3 className="font-bold mb-2">Team access</h3>
        {!team ? <Empty>Loading…</Empty> : <ul className="space-y-1">{team.map((e) => (
          <li key={e.id} className="flex flex-wrap items-center gap-3 text-sm"><span className="flex-1">{e.name} <span className="text-xs text-glass-muted">{e.department}</span></span>
            {e.is_admin ? <span className="text-xs text-glass-muted">Admin (full access)</span> : <>
              <label className="flex items-center gap-1 text-xs"><input type="checkbox" checked={e.access} onChange={(x) => access(e, x.target.checked, x.target.checked && e.can_approve)} />Can view</label>
              <label className="flex items-center gap-1 text-xs"><input type="checkbox" checked={e.can_approve} disabled={!e.access} onChange={(x) => access(e, true, x.target.checked)} />Can approve</label></>}
          </li>))}</ul>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- shell
const TABS = [
  { id: 'home', label: 'Home', icon: 'chart' },
  { id: 'campaigns', label: 'Campaigns', icon: 'rocket' },
  { id: 'adsleads', label: 'Ads Leads', short: 'Leads', icon: 'leads' },
  { id: 'approvals', label: 'Approvals', icon: 'check' },
  { id: 'autopilot', label: 'Autopilot', short: 'Auto', icon: 'plane' },
  { id: 'more', label: 'More', icon: 'more' },
];
const MORE = [
  { id: 'leads', label: 'Leads & Revenue', icon: 'funnel', hint: 'CRM leads matched to campaigns by UTM, and recorded revenue' },
  { id: 'recommendations', label: 'Recommendations', icon: 'sparkles', hint: 'Rule-based suggestions with the data behind them' },
  { id: 'clients', label: 'Clients', icon: 'team', hint: 'Business profile, economics and targets' },
  { id: 'accounts', label: 'Ad accounts', icon: 'globe', hint: 'Google Ads and Meta accounts per client' },
  { id: 'research', label: 'Research', icon: 'search', hint: 'Market and competitor findings with sources' },
  { id: 'experiments', label: 'Experiments', icon: 'zap', hint: 'A/B tests: hypothesis, result, decision' },
  { id: 'activity', label: 'Activity', icon: 'list', hint: 'Every action and sync run' },
  { id: 'settings', label: 'Settings', icon: 'settings', hint: 'API keys, test connection, limits, team', admin: true },
];

export default function Ads({ access }) {
  const route = useRoute();
  const p = route.tab === 'ads' ? route.params : {};
  const view = (route.tab === 'ads' && route.section) || 'home';
  const [clients, reloadClients, clientsErr] = useLoad(() => rpc('api_ads_clients'));
  const [pending, reloadPending] = useLoad(() => rpc('api_ads_queue', { p_status: 'pending' }), [view]);
  const client = (clients || []).find((c) => c.id === p.client);
  const tz = client?.timezone || 'Asia/Kolkata';
  const period = PERIODS.some(([k]) => k === p.period) ? p.period : '30d';
  const { from, to } = periodRange(period, todayIn(tz), { from: p.from, to: p.to });
  const ctx = { client: client ? client.id : '', period, from, to, tz };
  const go = (v) => navigate('ads', v, p);
  const more = MORE.filter((m) => !m.admin || access.is_admin);
  const sub = more.find((m) => m.id === view);
  const tab = sub ? 'more' : (TABS.find((t) => t.id === view) ? view : 'home');
  const count = { approvals: pending?.length || 0 };
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div><h2 className="text-xl font-bold text-glass-primary">ADS</h2><div className="text-xs text-glass-muted">Google Ads · Meta · CRM outcomes</div></div>
        <div className="flex flex-wrap gap-2 items-center">
          <select aria-label="Client" className="glass-input px-3 py-2 text-sm" value={ctx.client} onChange={(e) => setParams({ client: e.target.value })}>
            <option value="">All clients</option>{(clients || []).filter((c) => c.active).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <select aria-label="Period" className="glass-input px-3 py-2 text-sm" value={period} onChange={(e) => setParams({ period: e.target.value })}>
            {PERIODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
          {period === 'custom' && <>
            <input type="date" aria-label="From" className="glass-input px-2 py-2 text-sm" value={from} onChange={(e) => setParams({ from: e.target.value })} />
            <input type="date" aria-label="To" className="glass-input px-2 py-2 text-sm" value={to} onChange={(e) => setParams({ to: e.target.value })} />
          </>}
        </div>
      </div>
      <div className="text-[11px] text-glass-muted -mt-2">{from} to {to} · time zone {tz}{client ? ` · ${client.name}` : ' · every client'}</div>
      <div role="tablist" aria-label="ADS" className="glass-card p-1 grid grid-cols-6 gap-1">
        {TABS.map((t) => {
          const active = tab === t.id;
          return (
            <button key={t.id} role="tab" aria-selected={active} onClick={() => go(t.id)}
              className="relative flex flex-col sm:flex-row items-center justify-center gap-0.5 sm:gap-1.5 rounded-xl py-2 px-1 text-[11px] sm:text-sm min-h-[52px]"
              style={active ? { background: '#007AFF', color: '#fff', fontWeight: 600 } : undefined}>
              <Icon name={t.icon} size={18} />
              <span className="leading-tight text-center"><span className="sm:hidden">{t.short || t.label}</span><span className="hidden sm:inline">{t.label}</span></span>
              {count[t.id] > 0 && <span className="absolute top-1 right-1 sm:static min-w-[1.2rem] h-[1.2rem] px-1 rounded-full text-[10px] font-bold inline-flex items-center justify-center"
                style={{ background: active ? '#fff' : '#FF3B30', color: active ? '#007AFF' : '#fff' }}>{count[t.id]}</span>}
            </button>
          );
        })}
      </div>
      {sub && <button type="button" onClick={() => go('more')} className="text-sm font-semibold inline-flex items-center gap-1" style={{ color: 'var(--accent)' }}><Icon name="chevronLeft" size={16} />More</button>}
      {sub && <h3 className="text-lg font-bold text-glass-primary -mt-2">{sub.label}</h3>}
      {view === 'more' && (
        <div className="grid sm:grid-cols-2 gap-2">
          {more.map((m) => (
            <button key={m.id} type="button" onClick={() => go(m.id)} className="glass-card p-3 flex items-center gap-3 text-left min-h-[64px]">
              <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(0,122,255,0.12)', color: '#007AFF' }}><Icon name={m.icon} size={20} /></span>
              <span className="min-w-0 flex-1"><span className="block font-semibold text-glass-primary">{m.label}</span><span className="block text-xs text-glass-secondary">{m.hint}</span></span>
              <Icon name="chevronRight" size={16} />
            </button>))}
        </div>
      )}
      {tab === 'home' && <Home ctx={ctx} access={access} go={go} />}
      {tab === 'campaigns' && <Campaigns ctx={ctx} access={access} />}
      {tab === 'adsleads' && <AdsLeads access={access} />}
      {view === 'leads' && <LeadsRevenue ctx={ctx} access={access} clients={clients} />}
      {tab === 'approvals' && <Approvals access={access} onChange={reloadPending} />}
      {tab === 'autopilot' && <AdsAutopilot />}
      {view === 'recommendations' && <Recommendations ctx={ctx} onChange={reloadPending} />}
      {view === 'clients' && <Clients access={access} clients={clients} reload={reloadClients} clientsErr={clientsErr} />}
      {view === 'accounts' && <Accounts access={access} clients={clients} ctx={ctx} />}
      {view === 'research' && <Research ctx={ctx} />}
      {view === 'experiments' && <Experiments ctx={ctx} />}
      {view === 'activity' && <Activity />}
      {view === 'settings' && access.is_admin && <Settings />}
    </div>
  );
}
