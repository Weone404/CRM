import { useState } from 'react';
import { useRoute, navigate, setParams } from '../utils/route';
import Icon from './icons';
import AdsLeads from './AdsLeads';
import AdsSetup, { SetupBanner, progress } from './AdsSetup';
import AdsMetaInsights from './AdsMetaInsights';
import AdsMetaStrategy from './AdsMetaStrategy';
import AdsMetaReports from './AdsMetaReports';
import AdsMetaQuality from './AdsMetaQuality';
import AdsMetaHealth from './AdsMetaHealth';
import { SpeedAlerts, LeadArchive } from './AdsMetaLeadTools';
import { Campaigns, Settings, edge, useSetupFor } from './Ads';
import { rpc, useLoad, WorkingBar, OfflineBar } from './adsKit';
import { PERIODS, periodRange, todayIn } from '../utils/ads';

// CRM > Meta Ads: its own section, separate from Google Ads. Same data and rules underneath (api_ads_*), filtered to
// Meta: campaigns of Meta ad accounts, Ads leads that came through Meta (lead forms, Meta ad → website, WhatsApp ads),
// the Meta setup checklist and Meta settings (keys, lead sources, the Meta-only stop).

const TABS = [
  { id: 'home', label: 'Overview', icon: 'chart' },
  { id: 'reports', label: 'Reports', icon: 'chart' },
  { id: 'insights', label: 'Insights', icon: 'sparkles' },
  { id: 'strategy', label: 'Strategy', icon: 'zap' },
  { id: 'campaigns', label: 'Campaigns', icon: 'rocket' },
  { id: 'leads', label: 'Leads', icon: 'leads' },
  { id: 'setup', label: 'Setup', icon: 'checkCircle', admin: true },
  { id: 'settings', label: 'Settings', icon: 'settings', admin: true },
];
const ago = (t) => { if (!t) return 'never'; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };

function Overview({ access, st, go, edge }) {
  const [m] = useLoad(() => (access.is_admin ? rpc('api_ads_meta_settings').catch(() => null) : Promise.resolve(null)), [access.is_admin]);
  const p = st ? progress('meta', st) : null;
  const src = (k) => m?.sources?.find((s) => s.source === k) || {};
  const card = (label, value, sub, tone) => (
    <div className="glass-card p-3"><div className="text-[11px] text-glass-muted">{label}</div>
      <div className="text-2xl font-bold" style={{ color: tone || 'var(--glass-primary, #1C1C1E)' }}>{value}</div>
      {sub && <div className="text-[11px] text-glass-muted">{sub}</div>}</div>
  );
  return (
    <div className="space-y-3">
      {access.is_admin && p && (
        <button type="button" onClick={() => go('setup')} className="w-full glass-card p-4 text-left">
          <div className="flex items-center gap-2"><span className="font-bold flex-1">Setup</span>
            <span className="text-sm font-semibold" style={{ color: p.first ? '#B25E00' : '#1E7B34' }}>{p.done} of {p.total} done</span></div>
          <div className="mt-2 h-2 rounded-full overflow-hidden" style={{ background: 'rgba(118,118,128,0.16)' }}>
            <div className="h-full rounded-full" style={{ width: `${Math.round((p.done / p.total) * 100)}%`, background: p.first ? '#0088FF' : '#34C759' }} /></div>
          <div className="text-xs text-glass-secondary mt-1">{p.first ? `Next: ${p.first.title}` : 'Everything is set up.'}</div>
        </button>)}
      {m && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          {card('Form leads filed', src('instant_form').leads?.ingested ?? 0, `${src('instant_form').leads?.pending ?? 0} waiting`)}
          {card('Reports sent to Meta', ['instant_form', 'website', 'ctwa'].reduce((n, k) => n + (src(k).reports?.sent || 0), 0),
            `${['instant_form', 'website', 'ctwa'].reduce((n, k) => n + (src(k).reports?.failed || 0), 0)} not accepted`)}
          {card('Last call from Meta', ago(m.config.webhook_last_at), m.config.webhook_last_at ? 'webhook' : 'no lead yet')}
          {card('Sending to Meta', m.config.execution_paused ? 'Stopped' : 'On', m.config.execution_paused ? 'Settings → Resume' : 'emergency stop is off', m.config.execution_paused ? '#C4261D' : '#1E7B34')}
        </div>)}
      <AdsMetaHealth access={access} edge={edge} />
      <div className="grid md:grid-cols-2 gap-3"><SpeedAlerts access={access} /><LeadArchive access={access} /></div>
      <div className="grid sm:grid-cols-2 gap-2">
        <button type="button" onClick={() => go('leads')} className="glass-card p-3 text-left flex items-center gap-3">
          <Icon name="leads" size={20} /><span className="flex-1"><span className="block font-semibold">Leads from Meta</span><span className="block text-xs text-glass-secondary">Lead forms, Meta ad → website, WhatsApp ads</span></span><Icon name="chevronRight" size={16} /></button>
        <button type="button" onClick={() => go('campaigns')} className="glass-card p-3 text-left flex items-center gap-3">
          <Icon name="rocket" size={20} /><span className="flex-1"><span className="block font-semibold">Meta campaigns</span><span className="block text-xs text-glass-secondary">Spend and CRM results per campaign</span></span><Icon name="chevronRight" size={16} /></button>
      </div>
    </div>
  );
}

export default function AdsMeta({ access }) {
  const route = useRoute();
  const p = route.tab === 'metaads' ? route.params : {};
  const tabs = TABS.filter((t) => !t.admin || access.is_admin);
  const view = tabs.some((t) => t.id === route.section) ? route.section : 'home';
  const go = (v) => navigate('metaads', v, p);
  const [clients] = useLoad(() => rpc('api_ads_clients'));
  const client = (clients || []).find((c) => c.id === p.client);
  const tz = client?.timezone || 'Asia/Kolkata';
  const period = PERIODS.some(([k]) => k === p.period) ? p.period : '30d';
  const { from, to } = periodRange(period, todayIn(tz), { from: p.from, to: p.to });
  const ctx = { client: client ? client.id : '', period, from, to, tz };
  const [st, check] = useSetupFor(access.is_admin, 'meta');
  const [, force] = useState(0);
  return (
    <div className="space-y-4" data-testid="meta-ads">
      <WorkingBar /><OfflineBar />
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div><h2 className="text-xl font-bold text-glass-primary">Meta Ads</h2><div className="text-xs text-glass-muted">Facebook · Instagram · WhatsApp · CRM outcomes</div></div>
        {view === 'campaigns' && (
          <div className="flex flex-wrap gap-2 items-center">
            <select aria-label="Client" className="glass-input px-3 py-2 text-sm" value={ctx.client} onChange={(e) => setParams({ client: e.target.value })}>
              <option value="">All clients</option>{(clients || []).filter((c) => c.active).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <select aria-label="Period" className="glass-input px-3 py-2 text-sm" value={period} onChange={(e) => setParams({ period: e.target.value })}>
              {PERIODS.filter(([k]) => k !== 'custom').map(([k, l]) => <option key={k} value={k}>{l}</option>)}
            </select>
          </div>)}
      </div>
      {access.is_admin && view !== 'setup' && <SetupBanner platform="meta" st={st} onOpen={() => go('setup')} />}
      <div role="tablist" aria-label="Meta Ads" className="glass-card p-1 grid gap-1" style={{ gridTemplateColumns: `repeat(${tabs.length}, minmax(0, 1fr))` }}>
        {tabs.map((t) => {
          const active = view === t.id;
          return (
            <button key={t.id} role="tab" aria-selected={active} onClick={() => go(t.id)}
              className="relative flex flex-col sm:flex-row items-center justify-center gap-0.5 sm:gap-1.5 rounded-xl py-2 px-1 text-[11px] sm:text-sm min-h-[52px]"
              style={active ? { background: '#0088FF', color: '#fff', fontWeight: 600 } : undefined}>
              <Icon name={t.icon} size={18} /><span className="leading-tight text-center">{t.label}</span>
              {t.id === 'setup' && st && !st.loading && progress('meta', st).first && (
                <span aria-label="steps left" className="absolute top-1 right-1 sm:static h-2.5 w-2.5 rounded-full" style={{ background: active ? '#fff' : '#FF9500' }} />)}
            </button>);
        })}
      </div>
      {view === 'home' && <Overview access={access} st={st} go={go} edge={edge} />}
      {view === 'reports' && <ReportsView access={access} edge={edge} />}
      {view === 'insights' && <AdsMetaInsights access={access} edge={edge} />}
      {view === 'strategy' && <AdsMetaStrategy access={access} edge={edge} />}
      {view === 'campaigns' && <Campaigns ctx={ctx} access={access} platform="meta" />}
      {view === 'leads' && <AdsLeads access={access} platform="meta" />}
      {view === 'setup' && access.is_admin && <AdsSetup platform="meta" edge={edge} st={st || {}} check={async () => { const r = await check(); force((n) => n + 1); return r; }} />}
      {view === 'settings' && access.is_admin && <Settings platform="meta" />}
    </div>
  );
}

// Reports: Meta's numbers (Ads Manager style) or what the CRM adds (lead quality and score).
function ReportsView({ access, edge }) {
  const [mode, setMode] = useState('meta');
  return (
    <div className="space-y-3">
      <div role="tablist" aria-label="Report type" className="inline-flex rounded-xl overflow-hidden no-print" style={{ background: 'rgba(118,118,128,0.12)' }}>
        {[['meta', 'Meta results'], ['quality', 'Lead quality (CRM)']].map(([id, l]) => (
          <button key={id} role="tab" aria-selected={mode === id} onClick={() => setMode(id)} className="px-3 py-1.5 text-sm font-semibold"
            style={mode === id ? { background: '#0088FF', color: '#fff' } : {}}>{l}</button>))}
      </div>
      {mode === 'meta' ? <AdsMetaReports access={access} edge={edge} /> : <AdsMetaQuality access={access} />}
    </div>);
}
