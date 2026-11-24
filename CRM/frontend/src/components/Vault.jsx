import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import { navigate } from '../utils/route';
import Icon from './icons';

// Setup > Connections & keys (Admin only). Every key, token and account ID the CRM holds, grouped by provider.
// Secrets are write-only: once saved they show as •••• + last 4 and can be replaced, tested or removed, never read back.
// Account IDs that are not secret (client IDs, customer/profile/seller IDs) show in full and can be copied or edited.
// Each action goes through the function its module already uses, so checks, logs and the code that reads the keys are unchanged.

const FN = `${SUPABASE_URL}/functions/v1`;
const DAY = 86400000;

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function edge(name, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${FN}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || out.error || `Request failed (${res.status})`);
  return out;
}
async function fb(path, method = 'POST', body) {
  const res = await apiFetch(`/api/flightbridge${path}`, { token: localStorage.getItem('token'), method,
    headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
export async function copyText(text, what = 'Copied') {
  try { await navigator.clipboard.writeText(text); }
  catch {
    const t = document.createElement('textarea'); t.value = text; document.body.appendChild(t);
    t.select(); document.execCommand('copy'); t.remove();
  }
  showToast(`${what} copied`, 'success');
}
const when = (t) => {
  if (!t) return '';
  const d = new Date(t); if (Number.isNaN(d.getTime())) return '';
  const days = Math.floor((Date.now() - d.getTime()) / DAY);
  return days <= 0 ? 'today' : days === 1 ? 'yesterday' : days < 30 ? `${days} days ago` : d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
};

// ---------------------------------------------------------------- catalog
const ads = (name, label, kind, hint) => ({ id: `ads:${name}`, store: 'ads', name, label, kind, hint });
const amz = (name, label, kind, hint) => ({ id: `amz:${name}`, store: 'amz', name, label, kind, hint });
const AI_PROVIDERS = [
  ['groq', 'Groq', 'Starts with gsk_ (console.groq.com/keys)'], ['gemini', 'Google Gemini', 'Google AI Studio > Get API key'],
  ['openai', 'OpenAI', 'Starts with sk- (platform.openai.com/api-keys)'], ['anthropic', 'Anthropic (Claude)', 'Starts with sk-ant-'],
  ['openrouter', 'OpenRouter', 'Starts with sk-or-'], ['google_places', 'Google Maps / Places', 'Google Cloud > Credentials'],
];
const FB_KEYS = [
  ['tavily_api_key', 'Tavily web search', 'app.tavily.com > API Keys'], ['google_places_api_key', 'Google Places', 'Google Cloud > Credentials'],
  ['groq_api_key', 'Groq', 'console.groq.com > API Keys'], ['gemini_api_key', 'Gemini', 'aistudio.google.com > Get API key'],
  ['hostinger_mail_api_token', 'Hostinger Mail API token', 'hPanel > Emails > mailbox > API access'],
  ['hostinger_mailbox_resource_id', 'Hostinger mailbox ID', 'Shown next to the API token in hPanel'],
];
const INBOUND = [
  { id: 'website', label: 'Website enquiry forms', where: 'weoneaviation.in / .com and pilotschool.in: the form "send to" address', url: `${FN}/crm-leads/ingest` },
  { id: 'charter', label: 'BookMyCharter', where: 'bookmycharter.in settings (Vercel): CRM address and token', url: `${FN}/crm-leads/charter`, token: true },
  { id: 'hikvision', label: 'Hikvision attendance machine', where: 'Machine web page > Network > HTTP Listening; the token goes at the end of the address', url: `${FN}/crm-attendance/hikvision?token=`, token: true },
  { id: 'partner', label: 'Partner apps (DGCA prep)', where: 'DGCA prep (Vercel): CRM_PARTNER_TOKEN = the token', url: `${FN}/crm-attendance/partner/attendance/by-mobile`, token: true },
  { id: 'reelstudio', label: 'Reel Studio (Content)', where: 'Mac mini: ~/ReelStudio/.env CRM_CONTENT_TOKEN = the token', url: `${FN}/crm-content`, token: true },
];

function buildGroups(o) {
  const st = (store, name) => (o?.[store] || {})[name] || { set: false };
  const tests = o?.ads_status?.tests || {};
  const site = o?.ads_status?.site || {};
  const amzSt = o?.amz_status || {};
  const testLine = (t) => (t ? `${t.status === 'ok' ? 'Test passed' : 'Test failed'} ${when(t.at)}${t.status !== 'ok' && t.detail ? `: ${t.detail}` : ''}` : 'Not tested yet');
  const rot = amzSt.rotated_on ? Math.ceil((new Date(amzSt.rotated_on).getTime() + 180 * DAY - Date.now()) / DAY) : null;
  const gaEmpty = site.ga4_property && site.last && Number(site.last.ga_rows || 0) === 0;
  const pixelMissing = site.pixel && site.pixel.firing === false;
  const aiRows = new Map((o?.ai || []).map((r) => [r.provider, r]));
  const fbRows = new Map((o?.fb || []).map((r) => [r.name, r]));

  const groups = [
    { id: 'google', name: 'Google', summary: 'Google Ads, Search Console, GA4',
      tests: [{ label: 'Test Google Ads', run: () => edge('ads-sync', { jobs: ['test'] }), line: testLine(tests.test_google), bad: tests.test_google && tests.test_google.status !== 'ok' },
        { label: 'Check website data', run: () => edge('ads-sync', { jobs: ['site_signals'] }), line: tests.site_signals ? `Last check ${when(tests.site_signals.at)}: ${tests.site_signals.detail || tests.site_signals.status}` : 'Not checked yet', bad: gaEmpty }],
      items: [
        ads('GOOGLE_ADS_CLIENT_ID', 'Sign-in app · Client ID', 'id', 'Ends with .apps.googleusercontent.com'),
        ads('GOOGLE_ADS_CLIENT_SECRET', 'Sign-in app · Client secret', 'secret'),
        ads('GOOGLE_ADS_REFRESH_TOKEN', 'Google Ads sign-in token', 'secret', 'Starts with 1//'),
        ads('GOOGLE_ADS_LOGIN_CUSTOMER_ID', 'Manager (MCC) customer ID', 'id', '10 digits'),
        ads('GOOGLE_SITE_REFRESH_TOKEN', 'Website sign-in token (Search Console + GA4)', 'secret', 'Starts with 1//'),
        { id: 'site:gsc', store: 'site', name: 'gsc', label: 'Search Console site', kind: 'id', hint: 'sc-domain:weoneaviation.in or https://weoneaviation.in/', value: site.gsc_url },
        { id: 'site:ga4', store: 'site', name: 'ga4', label: 'GA4 property ID', kind: 'id', hint: 'Digits only (GA4 Admin > Property details)', value: site.ga4_property,
          warn: gaEmpty ? 'Connected but returns no visitor data: check it is the property for weoneaviation.in' : '' },
      ].map((i) => (i.store === 'site' ? { ...i, set: !!i.value } : { ...i, ...st('ads', i.name) })) },
    { id: 'meta', name: 'Meta', summary: 'Ad account, Page, lead forms, Pixel',
      tests: [{ label: 'Test Meta', run: () => edge('ads-sync', { jobs: ['test'] }), line: testLine(tests.test_meta), bad: tests.test_meta && tests.test_meta.status !== 'ok' }],
      notes: pixelMissing ? ['No Meta Pixel on the ad account yet, so website audiences can’t be built.'] : [],
      items: [
        ads('META_APP_ID', 'App ID', 'id', 'Digits only'),
        ads('META_APP_SECRET', 'App secret', 'secret'),
        ads('META_ACCESS_TOKEN', 'Access token (system user)', 'secret'),
        ads('META_PAGE_TOKEN', 'Page token', 'secret'),
        ads('META_WEBHOOK_VERIFY_TOKEN', 'Webhook verify token', 'secret', 'Any long random text; paste the same in the Meta app'),
        ads('INSTAGRAM_LOGIN_TOKEN', 'Instagram token (comment-to-DM)', 'secret', 'Meta for Developers > your app > Instagram > API setup with Instagram login > Generate token. Renews itself every 20 days'),
      ].map((i) => ({ ...i, ...st('ads', i.name) })) },
    { id: 'amazon', name: 'Amazon', summary: 'Seller Central, Amazon Ads, Pexels images',
      tests: [{ label: 'Test Amazon', run: () => edge('amazon-settings', { action: 'test' }), line: amzSt.last_test?.status ? `${amzSt.last_test.status === 'ok' ? 'Test passed' : 'Test failed'} ${when(amzSt.last_test.at)}` : 'Not tested yet', bad: amzSt.last_test?.status && amzSt.last_test.status !== 'ok' }],
      notes: rot != null && rot <= 14 ? [rot < 0 ? `The Amazon client secret is ${-rot} days past its 180-day rotation.` : `Rotate the Amazon client secret within ${rot} days.`] : [],
      items: [
        amz('AMZ_LWA_CLIENT_ID', 'Seller app · Client ID', 'id'), amz('AMZ_LWA_CLIENT_SECRET', 'Seller app · Client secret', 'secret'),
        amz('AMZ_REFRESH_TOKEN', 'Seller sign-in token', 'secret', 'Starts with Atzr|'), amz('AMZ_SELLER_ID', 'Seller ID', 'id'),
        amz('ADS_CLIENT_ID', 'Amazon Ads · Client ID', 'id'), amz('ADS_CLIENT_SECRET', 'Amazon Ads · Client secret', 'secret'),
        amz('ADS_REFRESH_TOKEN', 'Amazon Ads sign-in token', 'secret'), amz('ADS_PROFILE_ID', 'Amazon Ads profile ID', 'id'),
        amz('PEXELS_API_KEY', 'Pexels API key', 'secret', 'pexels.com/api (free)'),
      ].map((i) => ({ ...i, ...st('amz', i.name) })) },
    { id: 'ai', name: 'AI models', summary: 'Keys the CRM’s AI features use',
      items: [...AI_PROVIDERS, ...[...aiRows.keys()].filter((p) => !AI_PROVIDERS.some(([id]) => id === p)).map((p) => [p, p, ''])].map(([p, label, hint]) => {
        const r = aiRows.get(p);
        return { id: `ai:${p}`, store: 'ai', name: p, label, kind: 'secret', hint, set: !!r, last4: r?.last4, updated_at: r?.updated_at, off: r && r.enabled === false };
      }) },
    { id: 'fb', name: 'FlightBridge AI', summary: 'Web search, AI and mailbox keys for school outreach',
      items: FB_KEYS.map(([n, label, hint]) => {
        const r = fbRows.get(n);
        return { id: `fb:${n}`, store: 'fb', name: n, label, kind: n === 'hostinger_mailbox_resource_id' ? 'id' : 'secret', hint, set: !!r, last4: r?.last4, updated_at: r?.updated_at,
          test: r ? { ok: r.last_test_ok, msg: r.last_test_message, at: r.last_test_at } : null };
      }) },
    { id: 'email', name: 'Email sending', summary: 'The mailbox the CRM sends alerts from',
      items: [{ id: 'smtp', store: 'smtp', name: 'smtp', label: 'Alert email password', kind: 'secret', ...(amzSt.smtp_password || { set: false }),
        sub: amzSt.smtp ? `${amzSt.smtp.username || ''} via ${amzSt.smtp.host || ''}:${amzSt.smtp.port || ''} · ${amzSt.smtp.enabled ? 'sending on' : 'sending off'}` : 'Not set up' }] },
    { id: 'inbound', name: 'Sending data into the CRM', summary: 'Addresses and tokens other systems use',
      items: INBOUND.map((c) => ({ ...c, store: 'inbound', name: c.id, kind: c.token ? 'token' : 'url', ...(c.token ? (o?.inbound?.[c.id] || { set: false }) : { set: true }) })) },
  ];
  for (const g of groups) {
    const missing = g.items.filter((i) => !i.set && i.kind !== 'url').length;
    const problems = (g.tests || []).filter((t) => t.bad).length + (g.notes || []).length + g.items.filter((i) => i.warn || i.test?.ok === false).length;
    g.problems = problems; g.missing = missing; g.saved = g.items.filter((i) => i.set).length;
  }
  return groups;
}

// ---------------------------------------------------------------- actions (each through the module's own function)
async function saveItem(item, value, o) {
  const v = value.trim();
  if (item.store === 'ads') return rpc('api_ads_settings_save', { p_name: item.name, p_value: v });
  if (item.store === 'amz') return rpc('api_amz_settings_save', { p_name: item.name, p_value: v });
  if (item.store === 'site') {
    const s = o?.ads_status?.site || {};
    return rpc('api_ads_site_settings_save', { p_gsc_url: item.name === 'gsc' ? v : (s.gsc_url || ''), p_ga4_property: item.name === 'ga4' ? v : (s.ga4_property || '') });
  }
  if (item.store === 'ai') return rpc('ai_integration_set', { provider: item.name, api_key: v, enabled: true });
  if (item.store === 'fb') return fb(`/integrations/${item.name}`, 'POST', { value: v });
  if (item.store === 'smtp') {
    const c = o?.amz_status?.smtp;
    if (!c?.host) throw new Error('Set up the mail server first in Settings > Business email');
    return rpc('api_amz_smtp', { p_cfg: { host: c.host, port: Number(c.port), username: c.username, from_name: c.from_name || '', enabled: !!c.enabled, password: v } });
  }
  throw new Error('This item cannot be edited here');
}
async function removeItem(item) {
  if (item.store === 'ads') return rpc('api_ads_secret_delete', { p_name: item.name });
  if (item.store === 'amz') return rpc('api_vault_amz_remove', { p_name: item.name });
  if (item.store === 'ai') return rpc('ai_integration_delete', { provider: item.name });
  if (item.store === 'fb') return fb(`/integrations/${item.name}`, 'DELETE');
  throw new Error('This item cannot be removed here');
}
const canRemove = (i) => i.set && ['ads', 'amz', 'ai', 'fb'].includes(i.store);
const canEdit = (i) => ['ads', 'amz', 'site', 'ai', 'fb', 'smtp'].includes(i.store);

// ---------------------------------------------------------------- UI
let cache = null;   // last overview, so reopening the page is instant (IDs and statuses only; never secrets)

const KIND = { secret: ['Secret', '#5B3A9E', 'rgba(91,58,158,0.10)'], id: ['ID', '#3C3C43', 'rgba(118,118,128,0.14)'],
  token: ['Token', '#8A5300', 'rgba(178,106,0,0.12)'], url: ['Address', '#0A63CE', 'rgba(10,99,206,0.10)'] };
const btn = 'min-h-[36px] px-3 rounded-[9px] text-[13px] border border-[var(--border-default)] bg-white hover:bg-[rgba(118,118,128,0.06)] disabled:opacity-50';

function Row({ item, o, onDone, busy, setBusy }) {
  const [editing, setEditing] = useState(false);
  const [val, setVal] = useState('');
  const [shown, setShown] = useState('');
  const k = KIND[item.kind] || KIND.secret;
  const isBusy = busy === item.id;
  const masked = item.set ? `•••• ${item.last4 || ''}` : 'Not saved';
  const value = item.kind === 'url' ? item.url : item.kind === 'id' ? (item.value || (item.set ? `•••• ${item.last4 || ''}` : 'Not saved')) : (shown || masked);
  const act = async (fn, ok) => {
    setBusy(item.id);
    try { await fn(); if (ok) showToast(ok, 'success'); await onDone(); return true; }
    catch (e) { showToast(e.message, 'error'); return false; }
    finally { setBusy(''); }
  };
  const status = item.test && item.test.ok != null
    ? { text: item.test.ok ? `Working${item.test.at ? ` · tested ${when(item.test.at)}` : ''}` : `Problem: ${item.test.msg || 'last test failed'}`, tone: item.test.ok ? 'good' : 'warn' }
    : item.warn ? { text: item.warn, tone: 'warn' }
    : item.kind === 'url' ? { text: item.where, tone: 'muted' }
    : item.set ? { text: `${item.off ? 'Saved, switched off' : 'Saved'}${item.updated_at ? ` ${when(item.updated_at)}` : ''}${item.sub ? ` · ${item.sub}` : ''}`, tone: 'muted' }
    : { text: item.sub || item.hint || 'Not saved yet', tone: 'muted' };
  const tone = { good: '#1E7B34', warn: '#8A5300', muted: 'var(--label-2)' }[status.tone];

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 py-3.5 border-t border-[var(--hairline)]" data-item={item.id}>
      <div className="flex flex-col gap-0.5 min-w-0 flex-[1_1_300px]">
        <span className="flex items-center gap-2 text-sm font-medium text-glass-primary">{item.label}
          <span className="text-[11px] font-semibold px-1.5 py-px rounded-full" style={{ color: k[1], background: k[2] }}>{k[0]}</span></span>
        <span className="text-[13px] font-mono text-glass-secondary truncate" title={item.kind === 'id' || item.kind === 'url' ? value : undefined}>{value}</span>
        <span className="text-[13px]" style={{ color: tone }}>{status.text}</span>
      </div>
      {editing ? (
        <form className="flex flex-wrap items-end gap-2" onSubmit={async (e) => {
          e.preventDefault();
          if (!val.trim()) { showToast('Paste the value first', 'error'); return; }
          if (await act(() => saveItem(item, val, o), item.kind === 'secret' ? 'Saved. The value is now hidden for good.' : 'Saved')) { setEditing(false); setVal(''); }
        }}>
          <label className="flex flex-col gap-1 text-xs text-glass-secondary">{item.kind === 'secret' ? 'New value' : 'Value'}
            <input autoFocus type={item.kind === 'secret' ? 'password' : 'text'} autoComplete="off" spellCheck={false} value={val} onChange={(e) => setVal(e.target.value)}
              placeholder={item.hint || ''} className="glass-input min-h-[38px] w-[260px] max-w-full px-2.5 text-sm" />
          </label>
          <button type="submit" disabled={isBusy} className="glass-btn min-h-[38px] px-3.5 text-[13px]">{isBusy ? 'Saving…' : 'Save'}</button>
          <button type="button" className={btn} onClick={() => { setEditing(false); setVal(''); }}>Cancel</button>
        </form>
      ) : (
        <div className="flex flex-wrap gap-2">
          {(item.kind === 'id' && item.value) && <button type="button" className={btn} onClick={() => copyText(item.value, item.label)}>Copy</button>}
          {item.kind === 'url' && <button type="button" className={btn} onClick={() => copyText(item.url, 'Address')}>Copy address</button>}
          {item.kind === 'token' && (<>
            <button type="button" className={btn} onClick={() => copyText(item.url, 'Address')}>Copy address</button>
            {item.set && <button type="button" className={btn} disabled={isBusy} onClick={() => act(async () => {
              const t = await rpc('api_connection_token', { p_id: item.name }); await copyText(t, 'Token'); setShown(t);
              setTimeout(() => setShown(''), 15000);
            })}>Copy token</button>}
            {item.set && <button type="button" className={btn} disabled={isBusy} onClick={async () => {
              if (!await confirmDialog(`Replace the ${item.label} token?`, { message: 'The old token stops working at once, so paste the new one into the other system straight away.', confirmText: 'Replace', danger: true })) return;
              act(async () => { const t = await rpc('api_connection_rotate', { p_id: item.name }); await copyText(t, 'New token'); }, 'New token made and copied');
            }}>Replace</button>}
          </>)}
          {canEdit(item) && <button type="button" className={btn} onClick={() => setEditing(true)}>{item.set ? (item.kind === 'secret' ? 'Replace' : 'Edit') : 'Add'}</button>}
          {item.store === 'ai' && item.set && <button type="button" className={btn} disabled={isBusy}
            onClick={() => act(() => rpc('ai_integration_toggle', { provider: item.name, enabled: !!item.off }), item.off ? 'Switched on' : 'Switched off')}>{item.off ? 'Switch on' : 'Switch off'}</button>}
          {item.store === 'fb' && item.set && <button type="button" className={btn} disabled={isBusy} onClick={() => act(() => fb(`/integrations/${item.name}/test`), 'Test finished')}>Test</button>}
          {canRemove(item) && <button type="button" className={`${btn} text-[#A42219] border-[rgba(192,39,29,0.3)]`} disabled={isBusy} onClick={async () => {
            if (!await confirmDialog(`Remove ${item.label}?`, { message: 'Anything that uses it stops working until a new one is saved.', confirmText: 'Remove', danger: true })) return;
            act(() => removeItem(item), 'Removed');
          }}>Remove</button>}
        </div>
      )}
    </div>
  );
}

function Group({ g, o, open, onToggle, onDone, busy, setBusy }) {
  const [testing, setTesting] = useState('');
  const badge = g.problems ? `${g.problems} need${g.problems === 1 ? 's' : ''} attention` : g.missing === g.items.length ? 'Not set up' : `${g.saved} saved`;
  const badgeStyle = g.problems ? { background: 'rgba(178,106,0,0.12)', color: '#8A5300' } : g.missing === g.items.length ? { background: 'rgba(118,118,128,0.12)', color: 'var(--label-2)' } : { background: 'rgba(30,123,52,0.10)', color: '#1E7B34' };
  return (
    <section className="glass-card" data-group={g.id}>
      <button type="button" onClick={onToggle} aria-expanded={open} className="w-full flex items-center justify-between gap-3 px-5 min-h-[60px] text-left">
        <span className="flex flex-col"><span className="font-semibold text-glass-primary">{g.name}</span><span className="text-[13px] text-glass-secondary">{g.summary}</span></span>
        <span className="flex items-center gap-3 shrink-0"><span className="text-xs px-2.5 py-1 rounded-full" style={badgeStyle}>{badge}</span>
          <span className="text-[13px] text-[var(--accent)]">{open ? 'Hide' : 'Show'}</span></span>
      </button>
      {open && (
        <div className="px-5 pb-3">
          {(g.notes || []).map((n) => <div key={n} className="crm-stale mb-2"><Icon name="alert" size={15} />{n}</div>)}
          {(g.tests || []).length > 0 && (
            <div className="flex flex-col gap-2 py-3 border-t border-[var(--hairline)]">
              {g.tests.map((t) => (
                <div key={t.label} className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-[13px]" style={{ color: t.bad ? '#8A5300' : 'var(--label-2)' }}>{t.line}</span>
                  <button type="button" className={btn} disabled={!!testing} onClick={async () => {
                    setTesting(t.label);
                    try { await t.run(); showToast(`${t.label}: finished`, 'success'); } catch (e) { showToast(e.message, 'error'); }
                    finally { setTesting(''); onDone(); }
                  }}>{testing === t.label ? 'Testing…' : t.label}</button>
                </div>
              ))}
            </div>
          )}
          {g.items.map((i) => <Row key={i.id} item={i} o={o} onDone={onDone} busy={busy} setBusy={setBusy} />)}
          {g.id === 'email' && <button type="button" className="text-[13px] text-[var(--accent)] py-2" onClick={() => navigate('settings')}>Mail server and sender name are in Settings</button>}
        </div>
      )}
    </section>
  );
}

export default function Vault() {
  const [o, setO] = useState(cache);
  const [error, setError] = useState('');
  const [open, setOpen] = useState(() => { try { return JSON.parse(sessionStorage.getItem('vault:open') || 'null') || {}; } catch { return {}; } });
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState('');
  const [showLog, setShowLog] = useState(false);

  const load = useCallback(async () => {
    try { const d = await rpc('api_vault_overview'); cache = d; setO(d); setError(''); }
    catch (e) { setError(e.message); }
  }, []);
  useEffect(() => { load(); }, [load]);

  const groups = useMemo(() => buildGroups(o), [o]);
  const term = q.trim().toLowerCase();
  const shownGroups = term
    ? groups.map((g) => ({ ...g, items: g.items.filter((i) => `${g.name} ${i.label} ${i.name} ${i.hint || ''}`.toLowerCase().includes(term)) })).filter((g) => g.items.length)
    : groups;
  const isOpen = (g) => (term ? true : open[g.id] ?? (g.problems > 0));
  const toggle = (id, now) => setOpen((s) => { const n = { ...s, [id]: !now }; try { sessionStorage.setItem('vault:open', JSON.stringify(n)); } catch { /* ignore */ } return n; });
  const attention = groups.filter((g) => g.problems > 0);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="max-w-2xl">
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Connections &amp; keys</h1>
          <p className="m-0 text-sm text-glass-secondary">Every key and account ID in one place. Secrets are encrypted: once saved they can be replaced, tested or removed, but never shown again.</p>
        </div>
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search keys" aria-label="Search keys"
          className="glass-input min-h-[40px] w-[240px] max-w-full px-3 text-sm" />
      </div>
      {error && !o && <div role="alert" className="glass-card p-5 text-sm text-glass-primary">{error} <button type="button" className="text-[var(--accent)] font-medium ml-2" onClick={load}>Try again</button></div>}
      {!o && !error && <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>}
      {o && attention.length > 0 && !term && (
        <div className="crm-stale" role="status"><Icon name="alert" size={15} />
          {attention.length === 1 ? `${attention[0].name} needs attention.` : `${attention.map((g) => g.name).join(', ')} need attention.`}</div>
      )}
      {o && shownGroups.map((g) => {
        const isO = isOpen(g);
        return <Group key={g.id} g={g} o={o} open={isO} onToggle={() => toggle(g.id, isO)} onDone={load} busy={busy} setBusy={setBusy} />;
      })}
      {o && term && shownGroups.length === 0 && <p className="text-sm text-glass-secondary">Nothing matches “{q}”.</p>}
      {o && (
        <details className="glass-card" open={showLog} onToggle={(e) => setShowLog(e.currentTarget.open)}>
          <summary className="px-5 min-h-[52px] flex items-center justify-between cursor-pointer list-none">
            <span className="font-semibold text-glass-primary">Activity <span className="font-normal text-glass-secondary">· who added, replaced, viewed or removed what</span></span>
            <span className="text-[13px] text-[var(--accent)]">{showLog ? 'Hide' : 'Show'}</span>
          </summary>
          <div className="px-5 pb-4">
            {(o.activity || []).length === 0 && <p className="text-sm text-glass-secondary m-0 py-2">Nothing yet.</p>}
            {(o.activity || []).map((a, n) => (
              <div key={n} className="flex flex-wrap justify-between gap-2 py-2 border-t border-[var(--hairline)] text-[13px]">
                <span className="text-glass-primary">{(a.action || '').replace(/_/g, ' ')} · <span className="font-mono">{a.what}</span></span>
                <span className="text-glass-secondary">{a.who || 'System'} · {when(a.at)}</span>
              </div>
            ))}
          </div>
        </details>
      )}
      <p className="m-0 text-xs text-glass-secondary">Only Admin sees this page. Saving, replacing and removing go through each module’s own checks and are logged by name, never by value.</p>
    </div>
  );
}
