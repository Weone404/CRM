import { useCallback, useEffect, useMemo, useState } from 'react';
import { SUPABASE_URL } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { navigate } from '../utils/route';
import { promptDialog } from './ui/dialogs';
import { rpc, run, Btn, friendly } from './adsKit';
import Icon from './icons';

// Setup checklist for Google Ads and Meta Ads (Admin). Every step says what to do, gives the exact text to copy and
// the page to paste it in, and has Check Now. Steps are checked automatically every 30 s while this page is open.
// Checks run on the server: api_ads_setup_status (database) and ads-sync {jobs:["setup"]} (which functions are deployed).
// A step whose function does not exist yet (migration not run) shows as "not done", never as an error page.

const REF = (() => { try { return new URL(SUPABASE_URL).hostname.split('.')[0]; } catch { return ''; } })();
const SQL_EDITOR = `https://supabase.com/dashboard/project/${REF}/sql/new`;
const HOOK = `${SUPABASE_URL}/functions/v1/ads-meta-webhook`;
const BUILD = '2026-11-18.meta7';      // must equal ADS_BUILD in supabase/functions/_shared/ads_meta.ts
const SCHEMA = 107;                     // newest ADS migration this screen needs (ads_config ads_schema)
// Migrations the Setup page can hand out, oldest first; each is safe to run again.
const MIGRATIONS = [
  { n: 100, file: '100_ads_meta_signals.sql', load: () => import('../../../backend/migrations/100_ads_meta_signals.sql?raw') },
  { n: 101, file: '101_ads_meta_organic.sql', load: () => import('../../../backend/migrations/101_ads_meta_organic.sql?raw') },
  { n: 102, file: '102_ads_meta_verification.sql', load: () => import('../../../backend/migrations/102_ads_meta_verification.sql?raw') },
  { n: 103, file: '103_ads_meta_insights.sql', load: () => import('../../../backend/migrations/103_ads_meta_insights.sql?raw') },
  { n: 104, file: '104_ads_meta_strategy.sql', load: () => import('../../../backend/migrations/104_ads_meta_strategy.sql?raw') },
  { n: 105, file: '105_ads_meta_reports.sql', load: () => import('../../../backend/migrations/105_ads_meta_reports.sql?raw') },
  { n: 106, file: '106_ads_meta_quality.sql', load: () => import('../../../backend/migrations/106_ads_meta_quality.sql?raw') },
  { n: 107, file: '107_ads_meta_funnel.sql', load: () => import('../../../backend/migrations/107_ads_meta_funnel.sql?raw') },
];
const schemaOf = (st) => (st.db ? Number(st.db.schema) || 100 : 0);
const dbOk = (st) => schemaOf(st) >= SCHEMA;
const ago = (t) => { if (!t) return ''; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };
const notFound = (e) => /Could not find the function|PGRST202|does not exist|404/i.test(`${e?.code || ''} ${e?.message || e}`);
// Supabase CLI 3.x: --remote=<ref> (was --project-ref), --use-api builds on Supabase (no Docker), --yes confirms the hosted change.
// All run with JWT checking off: ads-sync checks the caller itself (CRM login or cron token), ads-agents its own token, the rest are public.
// Meta: ads-agents too, since Meta Ads > Strategy runs on the same agents (it answers /version with the build).
const META_FNS = ['ads-sync', 'ads-intake', 'ads-meta-webhook', 'ads-agents'];
const DEPLOY = (fns) => `cd ~/Desktop/CRM/CRM/CRM\n${fns.map((f) => `npx -y supabase@latest functions deploy ${f} --no-verify-jwt --use-api --remote=${REF} --yes`).join('\n')}`;

async function copy(text, what = 'Copied.') {
  try { await navigator.clipboard.writeText(text); showToast(what, 'success'); } catch { showToast('Copy did not work here: select the text and copy it.', 'error'); }
}

// ---------------------------------------------------------------- data
export function useSetup(platform, edge) {
  const [st, setSt] = useState({ loading: true });
  const check = useCallback(async () => {
    if (!edge) return {};                                 // not Admin: no checks
    const out = { at: new Date().toISOString() };
    try { out.db = await rpc('api_ads_setup_status', { p_platform: platform }); }
    catch (e) { if (notFound(e)) out.dbMissing = true; else out.dbError = friendly(e); }
    if (platform === 'meta' && out.db) { try { out.meta = await rpc('api_ads_meta_settings'); } catch { /* shown by its step */ } }
    try { out.fns = (await edge({ jobs: ['setup'] }))?.results?.setup; }
    catch (e) { out.fnError = /jobs must include/i.test(String(e?.message)) ? 'ads-sync is an older version' : friendly(e); }
    setSt(out);
    return out;
  }, [platform, edge]);
  useEffect(() => { check(); }, [check]);
  return [st, check];
}

// ads-sync answers the check itself, so it is current only when its build is the one this screen expects.
const fnState = (st, n) => (n === 'ads-sync' && st.fns && st.fns.build !== BUILD ? 'old' : st.fns?.functions?.[n]);
const L = (st) => st.db?.meta?.leads || {};
const leadsHandled = (st) => (L(st).ingested || 0) + (L(st).quarantined || 0) + (L(st).organic || 0) + (L(st).test || 0);
const leadSub = (st) => {
  const l = L(st);
  const parts = [`${l.received || 0} delivered: ${(l.ingested || 0) + (l.quarantined || 0)} to Ads Leads, ${l.organic_filed || 0} without an ad to Leads, ${l.test || 0} test`];
  parts.push((l.by_webhook || 0) > 0 ? `webhook works${st.db?.meta?.webhook_last_at ? ` (last ${ago(st.db.meta.webhook_last_at)})` : ''}`
    : 'Meta has not sent a lead to the webhook yet');
  if (l.failed) parts.push(`${l.failed} not filed${l.last_error ? `: ${l.last_error}` : ''}`);
  if (!st.db?.meta?.sources?.instant_form?.intake) parts.push('lead intake is off');
  return `${parts.join(' · ')}.`;
};
const fnOk = (st, names) => st.fns && names.every((n) => fnState(st, n) === 'current');
const fnSub = (st, names) => (st.fnError ? `Not yet: ${st.fnError}.` : st.fns
  ? names.map((n) => `${n}: ${({ current: 'deployed', old: 'older version, deploy again', missing: 'not deployed', unknown: 'could not check' })[fnState(st, n)] || 'not deployed'}`).join(' · ')
  : 'Checking…');

// Each step: id, title, why, done(st), sub(st) (what Check Now found), body(ctx) (the guide), required.
function metaSteps() {
  return [
    { id: 'db', title: 'Run the database update', why: 'Creates the Meta lead tables, the report queue and this checklist.',
      done: dbOk, sub: (st) => (dbOk(st) ? 'Done: the database is up to date.' : st.db ? 'A database update is waiting: run the SQL below.' : st.dbError || 'Not run yet.'),
      body: (x) => <SqlStep st={x.st} /> },
    { id: 'fns', title: 'Deploy the three ADS functions', why: 'ads-sync (jobs), ads-intake (website enquiries) and ads-meta-webhook (Meta calls it with new leads).',
      done: (st) => fnOk(st, META_FNS), sub: (st) => fnSub(st, META_FNS),
      body: () => <CmdStep fns={META_FNS} /> },
    { id: 'keys', title: 'Save the Meta keys', why: 'The access token reads leads and sends reports; the app secret proves webhook calls come from Meta; the verify token is a password you give Meta.',
      done: (st) => ['META_ACCESS_TOKEN', 'META_APP_SECRET', 'META_WEBHOOK_VERIFY_TOKEN'].every((k) => st.db?.secrets?.[k]),
      sub: (st) => ['META_ACCESS_TOKEN', 'META_APP_SECRET', 'META_WEBHOOK_VERIFY_TOKEN'].map((k) => `${k.replace('META_', '').toLowerCase().replace(/_/g, ' ')}: ${st.db?.secrets?.[k] ? 'saved' : 'missing'}`).join(' · '),
      body: (x) => <KeysStep x={x} keys={[
        ['META_ACCESS_TOKEN', 'Access token', 'Meta Business Settings → Users → System users → Add (Employee) → assign the Page and the ad account → Generate new token with ads_management, ads_read, leads_retrieval, pages_show_list, pages_read_engagement, pages_manage_metadata, business_management.', 'https://business.facebook.com/settings/system-users'],
        ['META_APP_SECRET', 'App secret', 'developers.facebook.com → your app → App settings → Basic → App secret → Show.', 'https://developers.facebook.com/apps/'],
        ['META_WEBHOOK_VERIFY_TOKEN', 'Webhook verify token', 'Any long random word. Press Make one, save it, and paste the same word in Meta in step 6.', null, true]]} /> },
    { id: 'test', title: 'Test the Meta connection', why: 'Proves the token works before anything depends on it.',
      done: (st) => st.db?.runs?.test_meta?.status === 'ok',
      sub: (st) => (st.db?.runs?.test_meta ? `${st.db.runs.test_meta.status === 'ok' ? 'Passed' : 'Failed'} ${ago(st.db.runs.test_meta.at)}: ${st.db.runs.test_meta.detail || ''}` : 'Not tested yet.'),
      body: (x) => <ActStep text="Runs a read-only check against Meta." btn="Test connection" onClick={() => x.job(['test'])} /> },
    { id: 'account', title: 'Add the Meta ad account', why: 'Leads are counted against the account\'s campaigns.',
      done: (st) => (st.db?.accounts?.total || 0) > 0, sub: (st) => `${st.db?.accounts?.total || 0} Meta ad account(s), ${st.db?.accounts?.connected || 0} connected.`,
      body: () => <ActStep text="Google Ads → More → Ad accounts → Import existing accounts, tick the Meta account (or add its ID)." btn="Open Ad accounts" onClick={() => navigate('ads', 'accounts')} /> },
    { id: 'hook', title: 'Connect the webhook in Meta', why: 'Meta calls this address the moment someone submits your lead form.',
      done: (st) => !!st.db?.meta?.webhook_verified_at,
      sub: (st) => (st.db?.meta?.webhook_verified_at ? `Meta checked the address ${ago(st.db.meta.webhook_verified_at)}.` : 'Meta has not checked the address yet.'),
      body: () => <HookStep /> },
    { id: 'page', title: 'Add your Facebook Page and connect it', why: 'The Page owns the lead forms; connecting it makes the Page send new leads.',
      done: (st) => st.db?.runs?.meta_page?.status === 'ok',
      sub: (st) => (st.db?.runs?.meta_page ? `${st.db.runs.meta_page.detail || ''} (${ago(st.db.runs.meta_page.at)})` : st.db?.meta?.page_id ? `Page ${st.db.meta.page_id}: press Connect Page.` : 'No Page ID yet.'),
      body: (x) => <PageStep x={x} /> },
    { id: 'lead', title: 'Go Live and send a test lead', why: 'Meta only sends real leads to a Live app. A test lead proves the whole path end to end.',
      // Done when Meta delivered a lead through the webhook AND the CRM handled it (Ads lead, normal lead or test lead).
      done: (st) => leadsHandled(st) > 0 && (st.db?.meta?.leads?.by_webhook || 0) > 0,
      sub: (st) => leadSub(st),
      body: (x) => <LeadStep x={x} /> },
    { id: 'report', title: 'Turn on reporting to Meta', why: 'Tells Meta which leads became qualified and admitted, so it finds more people like them.',
      done: (st) => !!(st.db?.meta?.sources?.instant_form?.report && st.db?.meta?.sources?.instant_form?.dataset),
      sub: (st) => (st.db?.meta?.sources?.instant_form?.dataset ? (st.db.meta.sources.instant_form.report ? 'On.' : 'Dataset saved; reporting is off.') : 'No dataset ID yet.'),
      body: (x) => <ReportStep x={x} /> },
    { id: 'event', title: 'Send a test event', why: 'Shows a report arriving in Meta before real ones are sent. Only Meta\'s test leads are used, never a real lead.',
      done: (st) => st.db?.runs?.meta_test_event?.status === 'ok',
      sub: (st) => (st.db?.runs?.meta_test_event ? `${st.db.runs.meta_test_event.detail || ''} (${ago(st.db.runs.meta_test_event.at)})` : 'Not sent yet.'),
      body: (x) => <TestEventStep x={x} /> },
  ];
}

function googleSteps() {
  return [
    { id: 'db', title: 'Run the database update', why: 'Adds the separate Google / Meta stops, the per-platform Leads lists and this checklist.',
      done: dbOk, sub: (st) => (dbOk(st) ? 'Done.' : st.db ? 'A database update is waiting: run the SQL below.' : st.dbError || 'Not run yet.'),
      body: (x) => <SqlStep st={x.st} /> },
    { id: 'fns', title: 'Deploy the ADS functions', why: 'ads-sync runs every job; ads-intake receives the website\'s ad enquiries.',
      done: (st) => fnOk(st, ['ads-sync', 'ads-intake']), sub: (st) => fnSub(st, ['ads-sync', 'ads-intake']),
      body: () => <CmdStep fns={['ads-sync', 'ads-intake']} /> },
    { id: 'keys', title: 'Save the Google Ads keys', why: 'OAuth client and refresh token of the Google user who can open the ad account.',
      done: (st) => ['GOOGLE_ADS_CLIENT_ID', 'GOOGLE_ADS_CLIENT_SECRET', 'GOOGLE_ADS_REFRESH_TOKEN'].every((k) => st.db?.secrets?.[k]),
      sub: (st) => ['GOOGLE_ADS_CLIENT_ID', 'GOOGLE_ADS_CLIENT_SECRET', 'GOOGLE_ADS_REFRESH_TOKEN'].map((k) => `${k.replace('GOOGLE_ADS_', '').toLowerCase().replace(/_/g, ' ')}: ${st.db?.secrets?.[k] ? 'saved' : 'missing'}`).join(' · '),
      body: () => <ActStep text="Google Ads → Settings → Google Ads API: add the three keys." btn="Open Settings" onClick={() => navigate('ads', 'settings')} /> },
    { id: 'test', title: 'Connect the Google Ads account', why: 'The account must be reachable for sync, agents and reporting.',
      done: (st) => st.db?.runs?.test_google?.status === 'ok' && (st.db?.accounts?.connected || 0) > 0,
      sub: (st) => `${st.db?.accounts?.connected || 0} of ${st.db?.accounts?.total || 0} account(s) connected${st.db?.runs?.test_google ? ` · last test ${st.db.runs.test_google.status === 'ok' ? 'passed' : 'failed'} ${ago(st.db.runs.test_google.at)}` : ''}.`,
      body: (x) => <ActStep text="Runs a read-only check of the keys against every added account." btn="Test connection" onClick={() => x.job(['test'])} /> },
    { id: 'caps', title: 'Set the spend limits', why: 'Agents may change bids and budgets only inside these limits.',
      done: (st) => !!st.db?.google?.cap_daily, sub: (st) => (st.db?.google?.cap_daily ? `Daily limit ₹${st.db.google.cap_daily}.` : 'No daily limit yet.'),
      body: () => <ActStep text="Google Ads → More → Autopilot → spend limits." btn="Open Autopilot" onClick={() => navigate('ads', 'autopilot')} /> },
    { id: 'conv', title: 'Report enquiries to Google', why: 'Google learns which clicks became real enquiries and admissions.',
      done: (st) => !!st.db?.google?.conv_upload && (st.db?.google?.conv_actions || 0) >= 3,
      sub: (st) => `${st.db?.google?.conv_upload ? 'On' : 'Off'} · ${st.db?.google?.conv_actions || 0} of 3 conversion actions created · ${st.db?.google?.reported || 0} reported.`,
      body: (x) => <ActStep text="Creates the three CRM conversion actions in Google Ads (once) and sends what is due." btn="Report now" onClick={() => x.job(['convert'])} /> },
    { id: 'agents', title: 'AI agents online', why: 'The hourly cloud runner does the agents\' work; no Mac needs to stay on.',
      done: (st) => !!st.db?.google?.agents_last_seen && Date.now() - new Date(st.db.google.agents_last_seen).getTime() < 90 * 60000,
      sub: (st) => (st.db?.google?.agents_last_seen ? `Last checked in ${ago(st.db.google.agents_last_seen)}.` : 'Never checked in.'),
      body: () => <ActStep text="If this stays red for more than 90 minutes, check the runner on the Autopilot page." btn="Open Autopilot" onClick={() => navigate('ads', 'autopilot')} /> },
  ];
}

export function setupSteps(platform) { return platform === 'meta' ? metaSteps() : googleSteps(); }

export function progress(platform, st) {
  const steps = setupSteps(platform);
  const done = steps.filter((s) => { try { return !!s.done(st); } catch { return false; } });
  const first = steps.find((s) => !done.includes(s));
  return { total: steps.length, done: done.length, first };
}

// ---------------------------------------------------------------- banner (top of each section)
export function SetupBanner({ platform, st, onOpen }) {
  if (!st || st.loading) return null;
  const p = progress(platform, st);
  if (!p.first) return null;
  const name = platform === 'meta' ? 'Meta Ads' : 'Google Ads';
  return (
    <button type="button" onClick={onOpen} data-testid={`setup-banner-${platform}`}
      className="w-full glass-card p-3 flex items-center gap-3 text-left" style={{ boxShadow: 'inset 0 0 0 1px rgba(255,149,0,0.55)' }}>
      <span className="h-9 w-9 rounded-full inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(255,149,0,0.16)', color: '#B25E00' }}><Icon name="alert" size={18} /></span>
      <span className="flex-1 min-w-0">
        <span className="block font-semibold text-glass-primary">{name} setup: {p.total - p.done} step{p.total - p.done === 1 ? '' : 's'} left</span>
        <span className="block text-xs text-glass-secondary truncate">Next: {p.first.title}</span>
      </span>
      <span className="text-sm font-semibold" style={{ color: 'var(--accent)' }}>Continue</span>
    </button>
  );
}

// ---------------------------------------------------------------- page
export default function AdsSetup({ platform, edge, st, check }) {
  const steps = useMemo(() => setupSteps(platform), [platform]);
  const [open, setOpen] = useState(null);
  const [checking, setChecking] = useState(false);
  const now = async () => { setChecking(true); try { await check(); } finally { setChecking(false); } };
  useEffect(() => {                                       // re-check every 30 s while the page is visible
    const t = setInterval(() => { if (document.visibilityState === 'visible') check(); }, 30000);
    return () => clearInterval(t);
  }, [check]);
  const p = progress(platform, st);
  useEffect(() => { if (open === null && p.first) setOpen(p.first.id); }, [p.first, open]);
  const job = async (jobs, extra = {}) => {
    const r = await run(edge({ jobs, ...extra }));
    if (r?.results) Object.values(r.results).forEach((x) => {
      if (x?.status) showToast(x.detail || x.status, x.status === 'ok' ? 'success' : 'error');
      else if (x && typeof x === 'object') Object.values(x).forEach((y) => y?.status && showToast(y.detail || y.status, y.status === 'ok' ? 'success' : 'error'));
    });
    await check();
  };
  const x = { st, check, job, edge };
  const pct = Math.round((p.done / p.total) * 100);
  return (
    <div className="space-y-3" data-testid={`setup-${platform}`}>
      <div className="glass-card p-4">
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex-1 min-w-[12rem]">
            <div className="font-bold text-glass-primary">{p.first ? `${p.done} of ${p.total} done` : 'Everything is set up'}</div>
            <div className="text-xs text-glass-secondary">{p.first ? 'Do the steps in order. Each one turns green when Check Now finds it done.' : 'All checks pass. This page keeps checking while it is open.'}</div>
          </div>
          <Btn ghost onClick={now} disabled={checking}><Icon name="refresh" size={14} />{checking ? 'Checking…' : 'Check all now'}</Btn>
        </div>
        <div className="mt-3 h-2 rounded-full overflow-hidden" style={{ background: 'rgba(118,118,128,0.16)' }} role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
          <div className="h-full rounded-full transition-all" style={{ width: `${pct}%`, background: p.first ? '#0088FF' : '#34C759' }} />
        </div>
        {st.at && <div className="text-[11px] text-glass-muted mt-1">Checked {ago(st.at)}</div>}
      </div>
      {steps.map((s, i) => {
        let ok = false; try { ok = !!s.done(st); } catch { ok = false; }
        const blocked = steps.slice(0, i).some((b) => { try { return !b.done(st); } catch { return true; } });
        const isOpen = open === s.id;
        return (
          <div key={s.id} className="glass-card p-0 overflow-hidden" data-testid={`step-${platform}-${s.id}`} data-done={ok ? 'yes' : 'no'}>
            <button type="button" onClick={() => setOpen(isOpen ? '' : s.id)} aria-expanded={isOpen}
              className="w-full p-4 flex items-start gap-3 text-left">
              <span className="h-7 w-7 rounded-full inline-flex items-center justify-center shrink-0 text-sm font-bold"
                style={ok ? { background: '#34C759', color: '#fff' } : blocked ? { background: 'rgba(118,118,128,0.16)', color: '#8E8E93' } : { background: 'rgba(255,149,0,0.18)', color: '#B25E00' }}>
                {ok ? <Icon name="check" size={16} /> : i + 1}</span>
              <span className="flex-1 min-w-0">
                <span className="block font-semibold text-glass-primary">{s.title}</span>
                <span className="block text-xs" style={{ color: ok ? '#1E7B34' : '#6E6E73' }}>{st.loading ? 'Checking…' : s.sub(st)}</span>
              </span>
              <Icon name={isOpen ? 'chevronDown' : 'chevronRight'} size={16} />
            </button>
            {isOpen && (
              <div className="px-4 pb-4 space-y-3 border-t" style={{ borderColor: 'rgba(60,60,67,0.12)' }}>
                <p className="text-xs text-glass-secondary pt-3">{s.why}</p>
                {blocked && !ok && <p className="text-xs font-semibold" style={{ color: '#B25E00' }}>Finish the steps above first; this one depends on them.</p>}
                <fieldset disabled={blocked && !ok} className="space-y-3 disabled:opacity-50">{s.body(x)}</fieldset>
                <div className="flex items-center gap-2">
                  <Btn ghost onClick={now} disabled={checking}><Icon name="refresh" size={14} />Check now</Btn>
                  <span className="text-xs font-semibold" style={{ color: ok ? '#1E7B34' : '#B25E00' }}>{ok ? 'Done' : 'Not done yet'}</span>
                </div>
              </div>)}
          </div>);
      })}
      {platform === 'meta' && (
        <div className="glass-card p-4 text-xs text-glass-secondary">
          <div className="font-semibold text-glass-primary text-sm mb-1">Optional later: WhatsApp ads</div>
          Needs a WhatsApp Cloud API number and Meta App Review for whatsapp_business_manage_events. Switch it on in Settings → WhatsApp ads when both are ready.
        </div>)}
    </div>
  );
}

// ---------------------------------------------------------------- step bodies
function CopyBlock({ label, text, big, testid }) {
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-2"><span className="text-[11px] font-semibold text-glass-muted flex-1">{label}</span>
        <Btn ghost onClick={() => copy(text, `${label} copied.`)}><Icon name="copy" size={14} />Copy</Btn></div>
      <pre data-testid={testid} className="text-[11px] leading-snug rounded-xl p-3 overflow-auto whitespace-pre-wrap break-all"
        style={{ background: 'rgba(118,118,128,0.10)', maxHeight: big ? 220 : 140 }}>{text}</pre>
    </div>
  );
}

function SqlStep({ st }) {
  const have = schemaOf(st || {});
  const need = MIGRATIONS.filter((m) => m.n > have);
  const [sql, setSql] = useState({});
  const [err, setErr] = useState('');
  useEffect(() => {
    need.forEach((m) => { if (!sql[m.file]) m.load().then((x) => setSql((o) => ({ ...o, [m.file]: x.default })), (e) => setErr(String(e))); });
  }, [need.map((m) => m.file).join()]);  // eslint-disable-line react-hooks/exhaustive-deps
  if (!need.length) return <p className="text-sm">The database is up to date.</p>;
  return (
    <>
      <ol className="text-sm list-decimal pl-5 space-y-1">
        <li>Open the Supabase SQL Editor: <a className="font-semibold" style={{ color: 'var(--accent)' }} href={SQL_EDITOR} target="_blank" rel="noopener noreferrer">open SQL Editor</a> (a new empty query).</li>
        <li>{need.length > 1 ? 'For each file below, in this order: ' : ''}press <b>Copy</b>, paste into the editor, press <b>Run</b>. "Success. No rows returned" means it worked. Running a file again is safe.</li>
        <li>Come back here and press <b>Check now</b>.</li>
      </ol>
      {err ? <p className="text-xs" style={{ color: '#C4261D' }}>Could not load the file in this build: {err}</p>
        : need.map((m) => <CopyBlock key={m.file} label={m.file} text={sql[m.file] || 'Loading…'} big testid={`sql-${m.n}`} />)}
      <p className="text-[11px] text-glass-muted">To undo: each file has a _down.sql partner in backend/migrations.</p>
    </>
  );
}

function CmdStep({ fns }) {
  return (
    <>
      <ol className="text-sm list-decimal pl-5 space-y-1">
        <li>On the Mac, open Terminal (Node.js must be installed; nothing else).</li>
        <li>First time only: <code>npx -y supabase@latest login</code> (opens the browser once).</li>
        <li>Copy and paste the commands below, then press Enter. They go to the repo folder and deploy each function.</li>
        <li>Press <b>Check now</b>. Each function must show "deployed".</li>
      </ol>
      <CopyBlock label="Deploy commands" text={DEPLOY(fns)} testid="deploy-cmds" />
      <p className="text-[11px] text-glass-muted">Build expected: {BUILD}. --no-verify-jwt: Meta and website visitors have no CRM login; ads-sync checks the caller itself.</p>
    </>
  );
}

function KeysStep({ x, keys }) {
  const save = async (k, label, make) => {
    let v = '';
    if (make) {
      v = Array.from(crypto.getRandomValues(new Uint8Array(18)), (b) => b.toString(36).padStart(2, '0')).join('').slice(0, 32);
      await copy(v, 'New verify token copied: paste it in Meta in step 6.');
    } else {
      v = await promptDialog(`Paste the ${label}`, { message: 'Stored encrypted in Supabase Vault. Only the last 4 characters are ever shown.', required: true, confirmText: 'Save' });
      if (v === null) return;
    }
    if (await run(rpc('api_ads_settings_save', { p_name: k, p_value: v }), `${label} saved.`)) await x.check();
  };
  return (
    <ul className="space-y-3">{keys.map(([k, label, how, link, make]) => {
      const set = x.st.db?.secrets?.[k];
      return (
        <li key={k} className="flex flex-wrap items-start gap-2 text-sm">
          <span className="mt-1" style={{ color: set ? '#34C759' : '#FF9500' }}>{set ? '●' : '○'}</span>
          <span className="flex-1 min-w-[12rem]"><span className="font-medium">{label}</span>
            <span className="block text-[11px] text-glass-muted">{how}{link && <> <a href={link} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>Open</a></>}</span></span>
          {make && <Btn ghost onClick={() => save(k, label, true)}>Make one</Btn>}
          <Btn ghost onClick={() => save(k, label, false)}>{set ? 'Replace' : 'Paste'}</Btn>
        </li>);
    })}</ul>
  );
}

const ActStep = ({ text, btn, onClick }) => (
  <div className="flex flex-wrap items-center gap-2 text-sm"><span className="flex-1 min-w-[12rem]">{text}</span><Btn onClick={onClick}>{btn}</Btn></div>
);

function HookStep() {
  return (
    <>
      <ol className="text-sm list-decimal pl-5 space-y-1">
        <li>Open <a href="https://developers.facebook.com/apps/" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>developers.facebook.com/apps</a> → your app → <b>Use cases</b> → <b>Capture &amp; manage ad leads</b> → <b>Customize</b> → <b>Webhooks</b> (older apps: <b>Webhooks</b> in the left menu).</li>
        <li>Choose <b>Page</b> in the object list.</li>
        <li>Callback URL: paste the address below. Verify token: the same word you saved in step 3.</li>
        <li>Press <b>Verify and save</b>, then press <b>Subscribe</b> next to the <b>leadgen</b> field.</li>
        <li>Press <b>Check now</b> here: it turns green when Meta has checked the address.</li>
      </ol>
      <CopyBlock label="Callback URL" text={HOOK} testid="hook-url" />
    </>
  );
}

function PageStep({ x }) {
  const pageId = x.st.db?.meta?.page_id;
  const setPage = async () => {
    const v = await promptDialog('Facebook Page ID', { message: 'Your Page → About → Page transparency (Page ID), or Business Settings → Pages.', required: true, confirmText: 'Save' });
    if (v !== null && await run(rpc('api_ads_meta_config_save', { p_key: 'meta_page_id', p_value: v }), 'Saved.')) await x.check();
  };
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <span className="flex-1 min-w-[12rem]">Page ID: <b>{pageId || 'not set'}</b></span>
      <Btn ghost onClick={setPage}>{pageId ? 'Change' : 'Add Page ID'}</Btn>
      <Btn ghost disabled={!pageId} onClick={() => x.job(['meta_page'])}>Check Page</Btn>
      <Btn disabled={!pageId} onClick={() => x.job(['meta_page'], { subscribe: true })}>Connect Page</Btn>
    </div>
  );
}

function LeadStep({ x }) {
  const on = x.st.db?.meta?.sources?.instant_form?.intake;
  const turnOn = async () => { if (await run(rpc('api_ads_meta_source_save', { p_source: 'instant_form', p_data: { intake_enabled: true } }), 'Lead intake is on.')) await x.check(); };
  return (
    <>
      <ol className="text-sm list-decimal pl-5 space-y-1">
        <li>{on ? 'Lead intake is on.' : <>Turn on lead intake: <Btn onClick={turnOn}>Turn on</Btn></>}</li>
        <li>Publish the app: <a href="https://developers.facebook.com/apps/" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>developers.facebook.com/apps</a> → your app → <b>Publish</b>. An unpublished app gets no real leads.</li>
        <li>Same app → <b>Use cases</b> → <b>Capture &amp; manage ad leads</b> → <b>Customize</b> → <b>Webhooks</b>: object <b>Page</b>, field <b>leadgen</b> must show <b>Subscribed</b>.</li>
        <li>Open the <a href="https://developers.facebook.com/tools/lead-ads-testing" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>Lead Ads Testing Tool</a>, choose your Page and a form, press <b>Create lead</b> (one per form: press <b>Delete lead</b> first if one exists).</li>
        <li>Within about 2 minutes this step turns green ("webhook works"). Test leads are recognised and never added to Leads.</li>
      </ol>
      <p className="text-xs text-glass-secondary">After setup: a form filled from an ad becomes an Ads lead; a form filled without an ad (opened from the Page) becomes a normal lead in Leads; every form is also re-read every hour, so a missed webhook never loses a lead.</p>
      <ActStep text="Webhook not arriving? Read the forms now (does not prove the webhook)." btn="Fetch leads now" onClick={() => x.job(['meta_leads_reconcile', 'meta_leads'])} />
    </>
  );
}

function ReportStep({ x }) {
  const src = x.st.meta?.sources?.find((s) => s.source === 'instant_form') || {};
  const save = async (data, msg) => { if (await run(rpc('api_ads_meta_source_save', { p_source: 'instant_form', p_data: data }), msg)) await x.check(); };
  const dataset = async () => {
    const v = await promptDialog('Dataset ID', { message: 'Events Manager → Data sources → your dataset (pixel) → its ID (digits).', required: true, confirmText: 'Save' });
    if (v !== null) await save({ dataset_id: v }, 'Saved.');
  };
  return (
    <div className="space-y-2 text-sm">
      <div className="flex flex-wrap items-center gap-2"><span className="flex-1 min-w-[12rem]">Dataset ID: <b>{src.dataset_id || 'not set'}</b> <a href="https://business.facebook.com/events_manager2" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>Open Events Manager</a></span>
        <Btn ghost onClick={dataset}>{src.dataset_id ? 'Change' : 'Add'}</Btn></div>
      <label className="flex flex-wrap items-center gap-2"><span className="flex-1 min-w-[12rem]">Who is reported</span>
        <select aria-label="Setup consent rule" className="glass-input px-3 py-2 text-sm" value={src.consent_mode || 'required'} onChange={(e) => save({ consent_mode: e.target.value }, 'Saved.')}>
          <option value="required">Only people who said yes</option><option value="required_if_collected">Everyone except people who said no</option><option value="not_required">Everyone</option>
        </select></label>
      <div className="flex flex-wrap items-center gap-2"><span className="flex-1 min-w-[12rem]">Reporting is <b>{src.report_enabled ? 'on' : 'off'}</b></span>
        <Btn disabled={!src.dataset_id} onClick={() => save({ report_enabled: !src.report_enabled }, src.report_enabled ? 'Reporting is off.' : 'Reporting is on.')}>{src.report_enabled ? 'Turn off' : 'Turn on'}</Btn></div>
    </div>
  );
}

function TestEventStep({ x }) {
  const [code, setCode] = useState('');
  return (
    <>
      <ol className="text-sm list-decimal pl-5 space-y-1">
        <li>Open <a href="https://business.facebook.com/events_manager2" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)' }}>Events Manager</a> (top right: your business portfolio) → <b>Datasets</b> → your dataset → <b>Test events</b> → channel <b>CRM</b>, Page and form.</li>
        <li>Meta shows a <b>Verification Lead</b> and "Waiting for an event". Wait until step 8 above shows a new test lead (about a minute).</li>
        <li>Press <b>Send for Meta's Verification Lead</b>. Meta's waiting screen turns green within a minute.</li>
      </ol>
      <Btn onClick={() => x.job(['meta_test_event'])}>Send for Meta's Verification Lead</Btn>
      <details className="text-xs text-glass-secondary">
        <summary className="cursor-pointer">Meta showed a code starting with TEST instead (channel Website / server)</summary>
        <div className="flex flex-wrap gap-2 mt-2">
          <input aria-label="Test event code" className="glass-input px-3 py-2 text-sm flex-1 min-w-[10rem]" placeholder="TEST12345" value={code} onChange={(e) => setCode(e.target.value.trim())} />
          <Btn disabled={!/^TEST\w{2,30}$/.test(code)} onClick={() => x.job(['meta_test_event'], { test_event_code: code })}>Send test event</Btn>
        </div>
      </details>
    </>
  );
}
