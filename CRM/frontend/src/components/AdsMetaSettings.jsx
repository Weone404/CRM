import { useState } from 'react';
import { SUPABASE_URL } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { promptDialog } from './ui/dialogs';
import { rpc, run, useLoad, Btn } from './adsKit';

// ADS > Settings > Meta lead sources (Admin). Everything about Meta leads is switched and configured here:
// which sources bring leads in, which report back to Meta, the consent rule, and the Meta event name for each stage.
// All writes go through api_ads_meta_* (Admin only, logged). Nothing is on until it is switched on here.

const SOURCES = {
  instant_form: { title: 'Meta lead forms', sub: 'Instant Forms on Facebook / Instagram ads. Leads arrive within about 2 minutes; a daily check catches any the webhook missed.', report: 'Conversions API for CRM (Conversion Leads)' },
  website: { title: 'Meta ad → your website', sub: 'Website enquiries from people who clicked a Meta ad (they already arrive in Ads Leads).', report: 'Website events (needs the click id and the visitor\'s browser details)' },
  ctwa: { title: 'WhatsApp ads (Click-to-WhatsApp)', sub: 'A chat started from a Meta ad. Needs a WhatsApp Cloud API number: the WhatsApp Business app does not pass the ad click id.', report: 'Business messaging events' },
};
const CONSENT = [['required', 'Only people who said yes'], ['required_if_collected', 'Everyone except people who said no'], ['not_required', 'Everyone (no consent needed)']];
const PURPOSE = [['ad_data_sharing', 'Ad data sharing'], ['marketing', 'Marketing']];
const PIPES = [['pilot_training', 'Pilot Training'], ['charter', 'Charter']];
const ago = (t) => { if (!t) return 'never'; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };

const Chip = ({ children, ok, warn }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap"
    style={ok ? { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' } : warn ? { background: 'rgba(255,149,0,0.16)', color: '#8A5A00' } : { background: 'rgba(118,118,128,0.14)', color: '#3C3C43' }}>{children}</span>
);

function Switch({ on, label, onChange, disabled }) {
  return (
    <button type="button" role="switch" aria-checked={!!on} aria-label={label} disabled={disabled} onClick={() => onChange(!on)}
      className="relative inline-flex h-[31px] w-[51px] shrink-0 rounded-full transition-colors disabled:opacity-40"
      style={{ background: on ? '#34C759' : 'rgba(120,120,128,0.32)' }}>
      <span className="absolute top-[2px] h-[27px] w-[27px] rounded-full bg-white transition-transform" style={{ left: 2, transform: on ? 'translateX(20px)' : 'none', boxShadow: '0 3px 8px rgba(0,0,0,0.15)' }} />
    </button>
  );
}

const Pick = ({ value, options, onChange, label }) => (
  <select aria-label={label} className="glass-input px-3 py-2 text-sm" value={value ?? ''} onChange={(e) => onChange(e.target.value)}>
    {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
  </select>
);

function Check({ ok, warn, children, sub }) {
  return (
    <li className="flex items-start gap-2 text-sm">
      <span aria-hidden className="mt-0.5 text-base leading-none" style={{ color: ok ? '#34C759' : warn ? '#FF9500' : '#FF3B30' }}>{ok ? '●' : '○'}</span>
      <span><span className="font-medium">{children}</span>{sub && <span className="block text-[11px] text-glass-muted">{sub}</span>}</span>
    </li>
  );
}

export default function AdsMetaSettings({ edge, paused }) {
  const [m, load, err] = useLoad(() => rpc('api_ads_meta_settings'));
  const [openMap, setOpenMap] = useState('');
  if (err) return <div className="glass-card p-4 text-sm" style={{ color: '#C4261D' }}>{err}</div>;
  if (!m) return <div className="glass-card p-4 text-sm text-glass-muted">Loading Meta lead sources…</div>;

  const c = m.config;
  const hook = `${SUPABASE_URL}/functions/v1/ads-meta-webhook`;
  const saveSource = async (source, data, msg = 'Saved.') => { if (await run(rpc('api_ads_meta_source_save', { p_source: source, p_data: data }), msg)) load(); };
  const editCfg = async (key, label, now, hint) => {
    const v = await promptDialog(label, { message: `${hint}${now ? ` Now: ${now}` : ''}`, confirmText: 'Save' });
    if (v !== null && await run(rpc('api_ads_meta_config_save', { p_key: key, p_value: v }), 'Saved.')) load();
  };
  const editText = async (source, field, label, now, hint) => {
    const v = await promptDialog(label, { message: `${hint}${now ? ` Now: ${now}` : ''}`, confirmText: 'Save' });
    if (v !== null) await saveSource(source, { [field]: v });
  };
  const job = async (jobs, extra = {}, ok) => {
    const r = await run(edge({ jobs, ...extra }));
    if (r?.results) Object.values(r.results).forEach((x) => x && showToast(x.detail || x.status, x.status === 'ok' ? 'success' : x.status === 'skipped' ? 'info' : 'error'));
    else if (r && ok) showToast(ok, 'success');
    load();
  };
  const mapRow = async (r, event, enabled) => {
    if (await run(rpc('api_ads_meta_event_map_save', { p_source: r.source, p_pipeline: r.pipeline, p_stage: r.stage, p_event: event, p_enabled: enabled }), 'Saved.')) load();
  };
  const copy = async () => { try { await navigator.clipboard.writeText(hook); showToast('Callback URL copied.', 'success'); } catch { showToast(hook, 'info'); } };

  return (
    <div className="space-y-4" data-testid="ads-meta-settings">
      <div className="glass-card p-4">
        <div className="flex flex-wrap items-center gap-2 mb-1">
          <h3 className="font-bold flex-1">Meta lead sources</h3>
          {(paused ?? c.execution_paused) && <Chip warn>Emergency stop is on: nothing is sent to Meta</Chip>}
        </div>
        <p className="text-xs text-glass-secondary mb-3">Meta ad leads come into Ads Leads, and how far each lead gets (contacted, qualified, admission) is reported back so Meta finds more people like your real students. Contact details are only ever sent as one-way codes (SHA-256).</p>
        <ul className="space-y-2">
          <Check ok={m.secrets.META_ACCESS_TOKEN} sub="Settings above → Meta Marketing API → Access token (a System User with ads_management, leads_retrieval and the Page as an asset).">Meta access token</Check>
          <Check ok={m.secrets.META_APP_SECRET} sub="Needed to check that webhook calls really come from Meta.">Meta app secret</Check>
          <Check ok={m.secrets.META_WEBHOOK_VERIFY_TOKEN} sub="Any long random word. Paste the same word in Meta App Dashboard → Webhooks → Verify token.">Webhook verify token</Check>
          <Check ok={!!c.page_id} sub={c.page_id ? `Page ${c.page_id}` : 'The Facebook Page that runs the lead forms.'}>Facebook Page</Check>
          <Check ok={m.page_check?.status === 'ok'} warn={!m.page_check} sub={m.page_check ? `${m.page_check.detail} · ${ago(m.page_check.at)}` : 'Press Check Page after adding the Page ID.'}>Page sends leads to the CRM</Check>
          <Check ok={!!c.webhook_last_at} warn sub={c.webhook_last_at ? `Last call from Meta ${ago(c.webhook_last_at)}` : 'No call from Meta yet. The Meta app must be switched to Live: in Development mode Meta only sends test pings.'}>Webhook received</Check>
          <Check ok={m.meta_accounts > 0} warn sub="Ad accounts → add the Meta ad account so leads are counted against its campaigns.">Meta ad account added</Check>
        </ul>
        <div className="mt-3 text-xs flex flex-wrap items-center gap-2">
          <span className="text-glass-muted">Callback URL for Meta:</span><code className="break-all">{hook}</code>
          <button type="button" style={{ color: 'var(--accent)' }} onClick={copy}>Copy</button>
        </div>
        <div className="mt-3 grid sm:grid-cols-3 gap-2 text-sm">
          {[['meta_page_id', 'Facebook Page ID', c.page_id, 'Page → About → Page transparency, or Business Settings → Pages.'],
            ['meta_waba_id', 'WhatsApp Business Account ID', c.waba_id, 'Only for WhatsApp ads. WhatsApp Manager → Account tools.'],
            ['meta_crm_name', 'CRM name sent to Meta', c.crm_name, 'Meta asks which tool the leads are managed in.']].map(([k, l, v, h]) => (
            <button key={k} type="button" onClick={() => editCfg(k, l, v, h)} className="glass-input px-3 py-2 text-left">
              <span className="block text-[11px] text-glass-muted">{l}</span><span className="block font-medium truncate">{v || 'Not set'}</span>
            </button>))}
        </div>
        <div className="mt-3 flex flex-wrap gap-2">
          <Btn ghost onClick={() => job(['meta_page'])}>Check Page</Btn>
          <Btn ghost onClick={() => job(['meta_page'], { subscribe: true })}>Connect Page</Btn>
          <Btn ghost onClick={() => job(['meta_leads_reconcile', 'meta_leads'])}>Fetch leads now</Btn>
          <Btn ghost onClick={() => job(['meta_convert'])}>Send reports now</Btn>
        </div>
        <div className="mt-2 text-[11px] text-glass-muted">Last daily form check: {ago(c.reconcile_last_at)} · Meta API {c.api_version}</div>
      </div>

      {m.sources.map((s) => {
        const d = SOURCES[s.source];
        const rows = (m.event_map || []).filter((r) => r.source === s.source);
        const names = m.event_names?.[s.source];
        return (
          <div key={s.source} className="glass-card p-4" data-testid={`meta-source-${s.source}`}>
            <h3 className="font-bold">{d.title}</h3>
            <p className="text-xs text-glass-secondary mb-3">{d.sub}</p>
            <div className="space-y-3">
              {s.source !== 'website' && (
                <div className="flex items-center gap-3"><div className="flex-1"><div className="text-sm font-medium">Bring leads into Ads Leads</div>
                  <div className="text-[11px] text-glass-muted">{s.leads?.received || 0} received · {s.leads?.ingested || 0} filed · {s.leads?.pending || 0} waiting · {s.leads?.failed || 0} failed{s.source === 'instant_form' ? ` · ${s.leads?.organic || 0} organic` : ''}</div>
                  {s.leads?.last_error && <div className="text-[11px]" style={{ color: '#C4261D' }}>{s.leads.last_error}</div>}</div>
                  <Switch label={`${d.title}: intake`} on={s.intake_enabled} onChange={(v) => saveSource(s.source, { intake_enabled: v })} /></div>)}
              <div className="flex items-center gap-3"><div className="flex-1"><div className="text-sm font-medium">Report lead stages to Meta</div>
                <div className="text-[11px] text-glass-muted">{d.report} · {s.reports?.sent || 0} sent · {s.reports?.pending || 0} waiting · {s.reports?.failed || 0} not accepted · {s.reports?.skipped || 0} skipped</div>
                {s.reports?.last_error && <div className="text-[11px]" style={{ color: '#C4261D' }}>{s.reports.last_error}</div>}</div>
                <Switch label={`${d.title}: report`} on={s.report_enabled} onChange={(v) => saveSource(s.source, { report_enabled: v })} /></div>
              <div className="grid sm:grid-cols-2 gap-2">
                <label className="text-[11px] text-glass-muted">Who is reported<Pick label="Consent rule" value={s.consent_mode} options={CONSENT} onChange={(v) => saveSource(s.source, { consent_mode: v })} /></label>
                <label className="text-[11px] text-glass-muted">Consent that counts<Pick label="Consent purpose" value={s.consent_purpose} options={PURPOSE} onChange={(v) => saveSource(s.source, { consent_purpose: v })} /></label>
                {s.source !== 'website' && <label className="text-[11px] text-glass-muted">New leads go to<Pick label="Default pipeline" value={s.pipeline} options={PIPES} onChange={(v) => saveSource(s.source, { pipeline: v })} /></label>}
                <button type="button" className="glass-input px-3 py-2 text-left" onClick={() => editText(s.source, 'dataset_id', 'Dataset ID', s.dataset_id, 'Events Manager → Data sources → the dataset (pixel) ID.')}>
                  <span className="block text-[11px] text-glass-muted">Dataset ID</span><span className="block text-sm font-medium">{s.dataset_id || 'Not set'}</span></button>
                {s.source === 'instant_form' && <button type="button" className="glass-input px-3 py-2 text-left" onClick={() => editText(s.source, 'consent_field', 'Consent question key', s.consent_field, 'The key of the form question or optional consent checkbox that asks permission (e.g. ad_data_sharing).')}>
                  <span className="block text-[11px] text-glass-muted">Consent question on the form</span><span className="block text-sm font-medium">{s.consent_field || 'Not asked'}</span></button>}
              </div>
              {s.source === 'ctwa' && <p className="text-[11px]" style={{ color: '#8A5A00' }}>Meta lists Advanced Access for whatsapp_business_manage_events, which needs App Review. Switch reporting on only after it is approved.</p>}
              <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setOpenMap(openMap === s.source ? '' : s.source)}>
                {openMap === s.source ? 'Hide' : 'Show'} stage → Meta event names</button>
              {openMap === s.source && (
                <div className="space-y-3">{PIPES.map(([pk, pl]) => (
                  <div key={pk}><div className="text-[11px] font-semibold text-glass-muted mb-1">{pl}</div>
                    <ul className="space-y-1">{rows.filter((r) => r.pipeline === pk).map((r) => (
                      <li key={r.stage} className="flex items-center gap-2 text-sm">
                        <span className="flex-1 min-w-0 truncate">{r.label}</span>
                        {names ? <Pick label={`${r.label} event`} value={r.meta_event_name} options={names.map((n) => [n, n])} onChange={(v) => mapRow(r, v, r.enabled)} />
                          : <button type="button" className="glass-input px-2 py-1 text-xs" onClick={async () => { const v = await promptDialog('Event name sent to Meta', { message: `Stage: ${r.label}. Now: ${r.meta_event_name}`, confirmText: 'Save' }); if (v !== null) mapRow(r, v, r.enabled); }}>{r.meta_event_name}</button>}
                        <Switch label={`${r.label}: send`} on={r.enabled} onChange={(v) => mapRow(r, r.meta_event_name, v)} />
                      </li>))}</ul></div>))}
                </div>)}
            </div>
          </div>);
      })}

      <div className="glass-card p-4"><h3 className="font-bold mb-1">Lead forms on the Page</h3>
        <p className="text-xs text-glass-secondary mb-2">Found by Check Page. Choose where each form's leads go; switch off a form to stop its daily check.</p>
        {!m.forms.length ? <div className="text-sm text-glass-muted">No forms yet. Add the Page ID and press Check Page.</div>
          : <ul className="space-y-2">{m.forms.map((f) => (
            <li key={f.form_id} className="flex flex-wrap items-center gap-2 text-sm">
              <span className="flex-1 min-w-[10rem]"><span className="font-medium">{f.name || f.form_id}</span>
                <span className="block text-[11px] text-glass-muted">{f.status || ''} · checked {ago(f.last_reconciled_at)}</span></span>
              <Pick label={`${f.name || f.form_id} pipeline`} value={f.pipeline} options={PIPES} onChange={(v) => run(rpc('api_ads_meta_form_save', { p_form: f.form_id, p_pipeline: v, p_active: f.active }), 'Saved.').then(load)} />
              <Switch label={`${f.name || f.form_id} active`} on={f.active} onChange={(v) => run(rpc('api_ads_meta_form_save', { p_form: f.form_id, p_pipeline: f.pipeline, p_active: v }), 'Saved.').then(load)} />
            </li>))}</ul>}
      </div>
    </div>
  );
}
