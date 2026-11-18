import { useState } from 'react';
import { rpc, run, useLoad, Btn } from './adsKit';
import { showToast } from '../utils/toast';
import { promptDialog } from './ui/dialogs';

// CRM > Meta Ads > Funnel (migration 107): the funnel map, the audience library kept in Meta, and where to aim location.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF', grey: 'rgba(118,118,128,0.12)' };
const fmt = (v) => (v === null || v === undefined ? '–' : Math.round(Number(v)).toLocaleString('en-IN'));
const inr = (v) => (v === null || v === undefined ? '–' : `₹${Number(v).toLocaleString('en-IN', { maximumFractionDigits: Number(v) < 100 ? 2 : 0 })}`);
const pct = (v) => (v === null || v === undefined ? '–' : `${Number(v) < 1 ? Number(v).toFixed(2) : Number(v).toFixed(1)}%`);
const iso = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const back = (n) => iso(new Date(Date.now() - n * 86400000));
const PERIODS = [[30, 'Last 30 days'], [90, 'Last 90 days'], [180, 'Last 6 months'], [365, 'Last 12 months']];
const KIND = { engagement: 'Meta', crm: 'CRM list', website: 'Website', lookalike: 'Lookalike' };
const STAGE = { cold: ['Cold', '#6B7280'], hot: ['Hot', C.red], engaged: ['Warm', C.amber], lead: ['Lead', C.blue], qualified: ['Qualified', C.green], customer: ['Admission', '#6B21A8'] };
const USE = { prospect: 'New people (hint)', retarget: 'Retarget', exclude: 'Exclude', seed: 'Lookalike seed', reengage: 'Re-engage' };
const VERDICT = { focus: [C.green, 'Focus'], keep: ['#6B7280', 'Keep'], reduce: [C.amber, 'Reduce'], cut: [C.red, 'Cut'], 'too few leads': ['#9CA3AF', 'Too few leads'] };
const size = (a) => (a.size_high ? (a.size_low && a.size_low !== a.size_high ? `${fmt(a.size_low)}-${fmt(a.size_high)}` : fmt(a.size_high)) : '–');

function FunnelMap({ days }) {
  const [f] = useLoad(() => rpc('api_ads_meta_funnel', { p_from: back(days), p_to: iso(new Date()) }), [days]);
  if (!f) return <section className="glass-card p-6 text-center text-sm text-glass-muted">Loading…</section>;
  const max = Math.max(1, ...f.stages.map((s) => Number(s.n) || 0));
  return (
    <section className="glass-card p-4 space-y-3" data-testid="funnel-map">
      <div className="flex flex-wrap items-baseline gap-2">
        <h3 className="font-bold flex-1">Funnel map</h3>
        <span className="text-xs text-glass-muted">Spend {inr(f.spend)} · median first call {f.first_call_min === null ? '–' : `${fmt(f.first_call_min)} min`} · lead to qualified {f.qualify_days === null ? '–' : `${f.qualify_days} days`}</span>
      </div>
      <div className="space-y-1.5">
        {f.stages.map((s) => (
          <div key={s.key} className="grid grid-cols-[7.5rem_1fr_auto] sm:grid-cols-[9rem_1fr_7rem_6rem] items-center gap-2 text-sm" data-testid={`stage-${s.key}`}>
            <span className="font-medium">{s.label}</span>
            <div className="h-5 rounded-md overflow-hidden" style={{ background: C.grey }}>
              <div className="h-full rounded-md" style={{ width: `${Math.max(Number(s.n) ? 1.5 : 0, (Math.log10((Number(s.n) || 0) + 1) / Math.log10(max + 1)) * 100)}%`, background: C.blue }} />
            </div>
            <span className="text-right font-semibold">{fmt(s.n)}{s.from_prev !== null && s.from_prev !== undefined && <span className="text-xs text-glass-muted font-normal"> · {pct(s.from_prev)}</span>}</span>
            <span className="hidden sm:block text-right text-xs text-glass-muted">{s.cost ? `${inr(s.cost)} each` : ''}</span>
          </div>))}
      </div>
      <p className="text-[11px] text-glass-muted">Bars use a log scale so the small stages stay visible. % is how many of the stage above moved on. "Became a lead" counts Meta leads that reached the CRM{f.stages[2]?.meta_count ? ` (Meta counted ${fmt(f.stages[2].meta_count)})` : ''}.</p>
      {f.warm.length > 0 && <div className="flex flex-wrap gap-1.5">{f.warm.map((a) => (
        <span key={a.key} className="text-xs px-2 py-1 rounded-lg" style={{ background: C.grey }}>
          <b style={{ color: STAGE[a.stage]?.[1] }}>{STAGE[a.stage]?.[0]}</b> {a.name}: {a.status === 'ready' ? size(a) : 'not in Meta yet'}</span>))}</div>}
      {f.notes.length > 0 && <ul className="text-sm space-y-1" data-testid="funnel-notes">{f.notes.map((n) => <li key={n} className="flex gap-2"><span style={{ color: C.amber }}>●</span><span>{n}</span></li>)}</ul>}
    </section>);
}

function Audiences({ access, edge }) {
  const [a, reload] = useLoad(() => rpc('api_ads_meta_audiences'), []);
  const [busy, setBusy] = useState(false);
  if (!a) return null;
  const admin = access?.is_admin;
  const sync = async () => {
    setBusy(true);
    const r = await edge({ jobs: ['meta_audiences'] }).catch((e) => ({ error: e.message }));
    const res = r?.results?.meta_audiences;
    showToast(res?.detail || r?.error || 'Done', res?.status === 'error' || r?.error ? 'error' : 'success');
    setBusy(false); reload();
  };
  return (
    <section className="glass-card p-4 space-y-3" data-testid="audience-library">
      <div className="flex flex-wrap items-start gap-2">
        <div className="flex-1 min-w-[14rem]"><h3 className="font-bold">Audience library</h3>
          <p className="text-xs text-glass-muted">Kept in Meta and refreshed every night. Meta treats only location, minimum age, languages and these exclusions as hard limits; everything else is a hint, so exclusions are the main control. CRM lists are sent hashed, and only people whose consent rule allows it.</p></div>
        {admin && <label className="text-sm flex items-center gap-1.5 font-semibold"><input type="checkbox" aria-label="Keep audiences in Meta" checked={a.on}
          onChange={(e) => run(rpc('api_ads_meta_audiences_on', { p_on: e.target.checked }).then(reload), e.target.checked ? 'Audiences on' : 'Audiences off')} />Keep audiences in Meta</label>}
        {(admin || access?.can_approve) && a.on && <Btn ghost disabled={busy} onClick={sync}>{busy ? 'Updating…' : 'Update now'}</Btn>}
      </div>
      {a.last?.at && <div className="text-xs text-glass-muted">Last update {new Date(a.last.at).toLocaleString('en-IN')}: {a.last.ok ?? 0} up to date{a.last.errors ? `, ${a.last.errors} with a problem` : ''}{a.last.detail ? `. ${a.last.detail}` : ''}</div>}
      <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="audience-table">
        <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">Audience</th><th className="p-2">Stage</th><th className="p-2">Use</th>
          <th className="p-2 text-right">Size in Meta</th><th className="p-2">Status</th>{admin && <th className="p-2">On</th>}<th className="p-2" title="Kept out of new-people ad sets the Strategy builds">Exclude from new-people ads</th></tr></thead>
        <tbody>{a.audiences.map((x) => (
          <tr key={x.key} className="border-t border-black/5 align-top" style={x.enabled ? undefined : { opacity: 0.5 }}>
            <td className="p-2"><div className="font-medium">{x.name} <span className="text-[10px] font-normal px-1.5 py-0.5 rounded" style={{ background: C.grey }}>{KIND[x.kind]}</span></div><div className="text-[11px] text-glass-muted">{x.why}</div>
              {x.kind === 'crm' && <div className="text-[11px] text-glass-muted">{fmt(x.eligible)} people can be sent{x.members !== null && x.members !== undefined ? ` · ${fmt(x.members)} sent last time` : ''}</div>}</td>
            <td className="p-2 whitespace-nowrap"><b style={{ color: STAGE[x.stage]?.[1] }}>{STAGE[x.stage]?.[0]}</b></td>
            <td className="p-2 whitespace-nowrap">{USE[x.use_as]}</td>
            <td className="p-2 text-right whitespace-nowrap">{x.status === 'ready' ? size(x) : '–'}</td>
            <td className="p-2 text-xs"><span style={{ color: x.status === 'ready' ? C.green : x.status === 'error' ? C.red : '#6B7280' }}>{x.status === 'planned' ? 'not in Meta yet' : x.status}</span>
              {x.detail && <div className="text-[11px] text-glass-muted max-w-[16rem] break-words">{x.detail}</div>}</td>
            {admin && <td className="p-2"><input type="checkbox" aria-label={`Use ${x.name}`} checked={x.enabled}
              onChange={(e) => run(rpc('api_ads_meta_audience_save', { p_key: x.key, p_enabled: e.target.checked, p_exclude_default: null }).then(reload), 'Saved')} /></td>}
            <td className="p-2"><input type="checkbox" aria-label={`Exclude ${x.name} from new-people ads`} checked={x.exclude_default} disabled={!admin}
              onChange={(e) => run(rpc('api_ads_meta_audience_save', { p_key: x.key, p_enabled: null, p_exclude_default: e.target.checked }).then(reload), 'Saved')} /></td>
          </tr>))}</tbody></table></div>
      {!a.on && <p className="text-xs text-glass-muted">{admin ? 'Turn on "Keep audiences in Meta" to create these audiences in the ad account (Meta may first ask you to accept its Custom Audience terms; the CRM shows the link).' : 'Admin can turn audiences on.'}</p>}
    </section>);
}

function Locations({ days }) {
  const [g] = useLoad(() => rpc('api_ads_meta_geo', { p_from: back(days), p_to: iso(new Date()) }), [days]);
  if (!g) return null;
  return (
    <section className="glass-card p-4 space-y-3" data-testid="location-focus">
      <h3 className="font-bold">Location focus</h3>
      <p className="text-xs text-glass-muted">{g.tip} Average qualified rate {g.avg_q_rate === null ? '–' : `${g.avg_q_rate}%`}.{g.unknown_location ? ` ${fmt(g.unknown_location)} lead(s) gave no city or state: add a City or State question to the form.` : ''}</p>
      {g.regions.length === 0 ? <div className="text-sm text-glass-muted">No location data yet.</div> : (
        <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="region-table">
          <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">State</th><th className="p-2 text-right">Spend</th><th className="p-2 text-right">Meta leads</th>
            <th className="p-2 text-right">Cost per lead</th><th className="p-2 text-right">Qualified</th><th className="p-2 text-right">Admissions</th><th className="p-2 text-right">Qualified rate</th>
            <th className="p-2 text-right">Cost per qualified</th><th className="p-2">Verdict</th></tr></thead>
          <tbody>{g.regions.map((r) => (
            <tr key={r.region} className="border-t border-black/5">
              <td className="p-2 font-medium">{r.region}</td><td className="p-2 text-right">{inr(r.spend)}</td><td className="p-2 text-right">{fmt(r.meta_leads)}</td>
              <td className="p-2 text-right">{inr(r.cpl)}</td><td className="p-2 text-right">{fmt(r.qualified)}</td><td className="p-2 text-right">{fmt(r.customers)}</td>
              <td className="p-2 text-right">{pct(r.q_rate)}</td><td className="p-2 text-right">{inr(r.cost_per_qualified)}</td>
              <td className="p-2"><b style={{ color: VERDICT[r.verdict]?.[0] }}>{VERDICT[r.verdict]?.[1]}</b></td></tr>))}</tbody></table></div>)}
      {g.cities.length > 0 && <details className="text-sm"><summary className="cursor-pointer text-xs font-semibold">Cities ({g.cities.length})</summary>
        <div className="flex flex-wrap gap-1.5 mt-2">{g.cities.map((c) => (
          <span key={c.city} className="text-xs px-2 py-1 rounded-lg" style={{ background: C.grey, opacity: c.small ? 0.6 : 1 }}>{c.city}: {fmt(c.leads)} leads · {pct(c.q_rate)} qualified</span>))}</div></details>}
    </section>);
}

function WebsiteSignals({ access, edge }) {
  const [w, reload] = useLoad(() => rpc('api_ads_site_signals'), []);
  const [cfg, setCfg] = useState(null);
  const [busy, setBusy] = useState(false);
  if (!w) return null;
  const admin = access?.is_admin;
  const st = cfg ?? { gsc: w.settings.gsc_url || '', ga4: w.settings.ga4_property || '' };
  const check = async () => {
    setBusy(true);
    const r = await edge({ jobs: ['site_signals'] }).catch((e) => ({ error: e.message }));
    const res = r?.results?.site_signals;
    showToast(res?.detail || r?.error || 'Checked', res?.status === 'error' || r?.error ? 'error' : 'success');
    setBusy(false); reload();
  };
  const token = async () => {
    const v = await promptDialog('Paste the website refresh token', { message: 'A Google refresh token (starts with 1//) with the webmasters.readonly and analytics.readonly scopes, made with the same OAuth client as Google Ads. Stored encrypted in Supabase Vault.', required: true, confirmText: 'Save' });
    if (v !== null && await run(rpc('api_ads_settings_save', { p_name: 'GOOGLE_SITE_REFRESH_TOKEN', p_value: v }), 'Saved')) reload();
  };
  const t = w.totals || {};
  const wf = w.web_funnel || {};
  const px = w.pixel;
  const none = !w.configured.gsc && !w.configured.ga4;
  return (
    <section className="glass-card p-4 space-y-3" data-testid="website-signals">
      <div className="flex flex-wrap items-start gap-2">
        <div className="flex-1 min-w-[14rem]"><h3 className="font-bold">Website signals</h3>
          <p className="text-xs text-glass-muted">What people search on Google before they reach the site (Search Console) and what they do on it (GA4), last 28 days against the 28 before. Totals only: neither tool names a visitor, and Google hides rare searches.</p></div>
        {(admin || access?.can_approve) && <Btn ghost disabled={busy} onClick={check}>{busy ? 'Checking…' : 'Check now'}</Btn>}
      </div>
      <div className="flex flex-wrap gap-2 text-xs" data-testid="pixel-status">
        <span className="px-2 py-1 rounded-lg" style={{ background: C.grey }}>Meta Pixel: {!px ? 'not checked yet' : px.id ? <b style={{ color: px.firing ? C.green : C.red }}>{px.firing ? 'firing' : 'not firing in the last 7 days'}</b> : <b style={{ color: C.red }}>none on the ad account</b>}{px?.id ? ` (${px.name || px.id})` : ''}</span>
        {w.last?.at && <span className="px-2 py-1 rounded-lg" style={{ background: C.grey }}>Last check {new Date(w.last.at).toLocaleString('en-IN')}{w.last.notes?.length ? `: ${w.last.notes.join('; ')}` : ''}</span>}
      </div>
      {admin && <details className="text-sm" open={none} data-testid="site-settings"><summary className="cursor-pointer text-xs font-semibold">Connect Search Console and GA4</summary>
        <div className="flex flex-wrap items-end gap-2 mt-2">
          <label className="text-xs">Search Console site<input aria-label="Search Console site" className="glass-input px-2 py-1 text-sm w-56 block" placeholder="sc-domain:weoneaviation.in" value={st.gsc} onChange={(e) => setCfg({ ...st, gsc: e.target.value })} /></label>
          <label className="text-xs">GA4 property ID<input aria-label="GA4 property ID" className="glass-input px-2 py-1 text-sm w-36 block" placeholder="digits only" value={st.ga4} onChange={(e) => setCfg({ ...st, ga4: e.target.value })} /></label>
          <Btn ghost disabled={!cfg} onClick={() => run(rpc('api_ads_site_settings_save', { p_gsc_url: st.gsc, p_ga4_property: st.ga4 }).then(() => { setCfg(null); reload(); }), 'Saved')}>Save</Btn>
          <Btn ghost onClick={token}>{w.settings.token_set ? 'Replace Google sign-in' : 'Add Google sign-in'}</Btn>
        </div>
        <p className="text-[11px] text-glass-muted mt-1">{w.settings.client_set ? 'Uses the OAuth client already saved for Google Ads.' : 'Save the Google Ads OAuth client ID and secret first (Google Ads → Settings).'} The Google user needs read access in Search Console (Settings → Users) and GA4 (Property access management).</p>
      </details>}
      {none ? <div className="text-sm text-glass-muted">Not connected yet.</div> : <>
        <div className="grid grid-cols-2 sm:grid-cols-5 gap-2 text-sm">
          {[['Google clicks', t.clicks, t.clicks_prev], ['Google impressions', t.impressions], ['Site sessions', wf.sessions], ['Form starts', wf.form_start], ['Key events', wf.key_events]].map(([l, v, p]) => (
            <div key={l} className="rounded-xl p-2" style={{ background: C.grey }}><div className="text-[11px] text-glass-muted">{l}</div><div className="font-bold">{fmt(v)}</div>
              {p ? <div className="text-[11px]" style={{ color: Number(v) >= Number(p) ? C.green : C.red }}>{Number(v) >= Number(p) ? '+' : ''}{Math.round(100 * (Number(v) - Number(p)) / Number(p))}% vs before</div> : null}</div>))}
        </div>
        {w.topics.length > 0 && <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="topic-table">
          <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">Search intent</th><th className="p-2 text-right">Impressions</th><th className="p-2 text-right">Clicks</th><th className="p-2 text-right">Change</th><th className="p-2">Top searches</th></tr></thead>
          <tbody>{w.topics.map((x) => (
            <tr key={x.key} className="border-t border-black/5"><td className="p-2 font-medium">{x.label}</td><td className="p-2 text-right">{fmt(x.impressions)}</td><td className="p-2 text-right">{fmt(x.clicks)}</td>
              <td className="p-2 text-right" style={{ color: x.change > 0 ? C.green : x.change < 0 ? C.red : undefined }}>{x.change === null ? '–' : `${x.change > 0 ? '+' : ''}${x.change}%`}</td>
              <td className="p-2 text-xs text-glass-muted">{(x.top || []).join(' · ')}</td></tr>))}</tbody></table></div>}
        {w.rising.length > 0 && <div><div className="text-xs font-semibold mb-1">Rising searches</div><div className="flex flex-wrap gap-1.5" data-testid="rising">{w.rising.map((r) => (
          <span key={r.query} className="text-xs px-2 py-1 rounded-lg" style={{ background: C.grey }}>{r.query} <b style={{ color: C.green }}>{fmt(r.impressions_prev || 0)} → {fmt(r.impressions)}</b></span>))}</div></div>}
        {w.pages.length > 0 && <details className="text-sm"><summary className="cursor-pointer text-xs font-semibold">Landing pages ({w.pages.length})</summary>
          <div className="overflow-x-auto"><table className="w-full text-sm mt-1" data-testid="page-table">
            <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">Page</th><th className="p-2 text-right">Google clicks</th><th className="p-2 text-right">Sessions</th><th className="p-2 text-right">Engaged</th><th className="p-2 text-right">Key events</th></tr></thead>
            <tbody>{w.pages.map((x) => (<tr key={x.page} className="border-t border-black/5"><td className="p-2 break-all">{x.page || '/'}</td><td className="p-2 text-right">{fmt(x.google_clicks)}</td>
              <td className="p-2 text-right">{fmt(x.sessions)}</td><td className="p-2 text-right">{pct(x.engaged_rate)}</td><td className="p-2 text-right">{fmt(x.key_events)}</td></tr>))}</tbody></table></div></details>}
        {(w.channels.length > 0 || w.cities.length > 0) && <div className="flex flex-wrap gap-1.5 text-xs">
          {w.channels.map((c) => <span key={c.channel} className="px-2 py-1 rounded-lg" style={{ background: C.grey }}>{c.channel}: {fmt(c.sessions)} sessions · {fmt(c.key_events)} key events</span>)}
          {w.cities.slice(0, 8).map((c) => <span key={c.city + c.region} className="px-2 py-1 rounded-lg" style={{ background: C.grey }}>{c.city}: {fmt(c.users)} users</span>)}</div>}
      </>}
    </section>);
}

const SPLIT_KEYS = [['prospecting', 'New people'], ['retarget', 'Retarget'], ['reengage', 'Re-engage']];
const lines = (t) => String(t || '').split('\n').map((x) => x.trim()).filter(Boolean).slice(0, 12);

function FunnelPlan({ access, personas }) {
  const [monthly, setMonthly] = useState('60000');
  const [split, setSplit] = useState({ prospecting: 70, retarget: 20, reengage: 10 });
  const [objective, setObjective] = useState('admissions');
  const [course, setCourse] = useState('CPL');
  const [picked, setPicked] = useState([]);
  const [bp, setBp] = useState(null);
  const [err, setErr] = useState('');
  const sum = SPLIT_KEYS.reduce((a, [k]) => a + (Number(split[k]) || 0), 0);
  const work = async () => {
    setErr('');
    try { setBp(await rpc('api_ads_meta_funnel_blueprint', { p_monthly: Number(monthly), p_split: Object.fromEntries(SPLIT_KEYS.map(([k]) => [k, Number(split[k]) || 0])) })); }
    catch (e) { setErr(e.message); setBp(null); }
  };
  const send = () => run(rpc('api_ads_meta_strategy_create', { p_goal: { objective, monthly_budget: String(Number(monthly)), courses: [course],
    funnel: { split: Object.fromEntries(SPLIT_KEYS.map(([k]) => [k, Number(split[k]) || 0])) }, personas: picked } })
    .then((r) => { window.location.hash = '#/metaads/strategy'; return r; }), 'Sent: the agents are planning it in Strategy');
  const name = (k) => (personas || []).find((p) => p.key === k)?.name || k;
  return (
    <section className="glass-card p-4 space-y-3" data-testid="funnel-plan">
      <div><h3 className="font-bold">Funnel plan</h3>
        <p className="text-xs text-glass-muted">Split a monthly budget across the funnel. Retarget and re-engage shares are capped by the real pool sizes at your cost per 1,000 views; whatever a pool cannot take goes to new people. Meta needs about 50 leads a week per ad set to finish learning, so small stages stay one ad set.</p></div>
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-xs">Monthly budget (₹)<input aria-label="Monthly budget" type="number" min="3000" className="glass-input px-2 py-1 text-sm w-28 block" value={monthly} onChange={(e) => setMonthly(e.target.value)} /></label>
        {SPLIT_KEYS.map(([k, l]) => <label key={k} className="text-xs">{l} %<input aria-label={`${l} share`} type="number" min="0" max="100" className="glass-input px-2 py-1 text-sm w-20 block" value={split[k]} onChange={(e) => setSplit({ ...split, [k]: e.target.value })} /></label>)}
        <span className="text-xs" style={{ color: sum === 100 ? C.green : C.red }}>{sum}%</span>
        <Btn ghost disabled={sum !== 100 || Number(monthly) < 3000} onClick={work}>Work it out</Btn>
      </div>
      {err && <div className="text-sm" style={{ color: C.red }}>{err}</div>}
      {bp && <div className="space-y-2" data-testid="blueprint">
        <div className="text-xs text-glass-muted">₹{fmt(bp.daily)} a day · CPM {bp.cpm ? inr(bp.cpm) : 'unknown'} · cost per lead {bp.cpl ? inr(bp.cpl) : 'unknown'} · qualified rate {bp.q_rate !== null ? pct(100 * bp.q_rate) : 'unknown'}
          {bp.qualified_per_month !== null ? ` · about ${fmt(bp.qualified_per_month)} qualified a month at past rates` : ''}</div>
        <div className="grid md:grid-cols-3 gap-2">{bp.stages.map((st) => (
          <div key={st.stage} className="rounded-xl p-3 text-sm space-y-1" style={{ background: C.grey }} data-testid={`bp-${st.stage}`}>
            <div className="font-bold">{st.label}</div>
            <div>{inr(st.daily)} a day · {inr(st.monthly)} a month · {st.share}%</div>
            {st.include.length > 0 && <div className="text-xs"><b>Include</b> ({st.include_is}): {st.include.join(', ')}</div>}
            {st.exclude.length > 0 && <div className="text-xs"><b>Exclude</b>: {st.exclude.join(', ')}</div>}
            <div className="text-xs"><b>Form</b>: {st.form}</div>
            <div className="text-xs"><b>Message</b>: {st.message}</div>
            {st.personas.length > 0 && <div className="text-xs"><b>Personas</b>: {st.personas.map(name).join(', ')}</div>}
            <div className="text-xs"><b>Judge by</b>: {st.kpi}</div>
            <div className="text-xs text-glass-muted">{st.leads_per_week !== null ? `~${st.leads_per_week} leads a week; ` : ''}{st.learning}</div>
          </div>))}</div>
        {bp.notes.length > 0 && <ul className="text-sm space-y-1">{bp.notes.map((n) => <li key={n} className="flex gap-2"><span style={{ color: C.amber }}>●</span><span>{n}</span></li>)}</ul>}
        {access?.is_admin && <div className="flex flex-wrap items-end gap-2 pt-1 border-t border-black/5">
          <label className="text-xs">Aim for<select aria-label="Aim for" className="glass-input px-2 py-1 text-sm block" value={objective} onChange={(e) => setObjective(e.target.value)}>
            <option value="admissions">Admissions</option><option value="qualified">Qualified leads</option><option value="leads">Leads</option></select></label>
          <label className="text-xs">Course<input aria-label="Course" className="glass-input px-2 py-1 text-sm w-32 block" value={course} onChange={(e) => setCourse(e.target.value)} /></label>
          <div className="text-xs"><div>Personas to cover</div><div className="flex flex-wrap gap-1 mt-0.5">{(personas || []).filter((p) => p.enabled).map((p) => (
            <button key={p.key} aria-pressed={picked.includes(p.key)} onClick={() => setPicked(picked.includes(p.key) ? picked.filter((x) => x !== p.key) : [...picked, p.key].slice(0, 6))}
              className="px-2 py-1 rounded-lg" style={picked.includes(p.key) ? { background: C.blue, color: '#fff' } : { background: C.grey }}>{p.name}</button>))}</div></div>
          <Btn disabled={!course.trim()} onClick={send}>Send to Strategy</Btn>
        </div>}
      </div>}
    </section>);
}

function Personas({ access, list, reload }) {
  const [edit, setEdit] = useState(null);
  if (!list) return null;
  const admin = access?.is_admin;
  const save = () => run(rpc('api_ads_meta_persona_save', { p: { key: edit.key, name: edit.name, who: edit.who, enabled: edit.enabled,
    objections: lines(edit.objections), proof: lines(edit.proof), angles: lines(edit.angles), form_questions: lines(edit.form_questions), stages: edit.stages } })
    .then(() => { setEdit(null); reload(); }), 'Saved');
  const open = (p) => setEdit(p ? { ...p, objections: p.objections.join('\n'), proof: p.proof.join('\n'), angles: p.angles.join('\n'), form_questions: p.form_questions.join('\n') }
    : { key: '', name: '', who: '', objections: '', proof: '', angles: '', form_questions: '', stages: ['prospecting'], enabled: true, isNew: true });
  return (
    <section className="glass-card p-4 space-y-3" data-testid="personas">
      <div className="flex items-start gap-2"><div className="flex-1"><h3 className="font-bold">Personas</h3>
        <p className="text-xs text-glass-muted">Who the ads speak to. Meta now finds the audience largely from the ad itself, so each concept should be written for one of these people. The Strategy agents use them, and Google searches show what each one asks.</p></div>
        {admin && <Btn ghost onClick={() => open(null)}>Add persona</Btn>}</div>
      <div className="grid md:grid-cols-2 gap-2">{list.map((p) => (
        <div key={p.key} className="rounded-xl p-3 text-sm space-y-1" style={{ background: C.grey, opacity: p.enabled ? 1 : 0.5 }} data-testid={`persona-${p.key}`}>
          <div className="flex items-start gap-2"><b className="flex-1">{p.name}</b>{admin && <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={() => open(p)}>Edit</button>}</div>
          <div className="text-xs text-glass-muted">{p.who}</div>
          {p.search.length > 0 && <div className="text-xs"><b>Searches</b>: {p.search.map((x) => `${x.topic} (${fmt(x.impressions)}${x.change !== null ? `, ${x.change > 0 ? '+' : ''}${x.change}%` : ''})`).join(' · ')}</div>}
          <div className="text-xs"><b>Objections</b>: {p.objections.join(' · ')}</div>
          <div className="text-xs"><b>Proof they need</b>: {p.proof.join(' · ')}</div>
          <div className="text-xs"><b>Angles</b>: {p.angles.join(' · ')}</div>
          <div className="text-xs text-glass-muted">Best for: {p.stages.join(', ')}</div>
        </div>))}</div>
      {edit && <div className="rounded-xl p-3 space-y-2 border border-black/10" data-testid="persona-edit">
        <div className="flex flex-wrap gap-2">
          <label className="text-xs">Key<input aria-label="Persona key" disabled={!edit.isNew} className="glass-input px-2 py-1 text-sm w-36 block" value={edit.key} onChange={(e) => setEdit({ ...edit, key: e.target.value })} /></label>
          <label className="text-xs flex-1">Name<input aria-label="Persona name" className="glass-input px-2 py-1 text-sm w-full block" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
          <label className="text-xs flex items-center gap-1 mt-4"><input type="checkbox" aria-label="Persona on" checked={edit.enabled} onChange={(e) => setEdit({ ...edit, enabled: e.target.checked })} />On</label>
        </div>
        <label className="text-xs block">Who<textarea aria-label="Persona who" rows="2" className="glass-input px-2 py-1 text-sm w-full block" value={edit.who} onChange={(e) => setEdit({ ...edit, who: e.target.value })} /></label>
        <div className="grid md:grid-cols-2 gap-2">{[['objections', 'Objections'], ['proof', 'Proof they need'], ['angles', 'Angles'], ['form_questions', 'Form questions']].map(([k, l]) => (
          <label key={k} className="text-xs block">{l} (one per line)<textarea aria-label={`Persona ${l}`} rows="3" className="glass-input px-2 py-1 text-sm w-full block" value={edit[k]} onChange={(e) => setEdit({ ...edit, [k]: e.target.value })} /></label>))}</div>
        <div className="flex flex-wrap items-center gap-3 text-xs">{SPLIT_KEYS.map(([k, l]) => (
          <label key={k} className="flex items-center gap-1"><input type="checkbox" aria-label={`Persona stage ${l}`} checked={edit.stages.includes(k)}
            onChange={(e) => setEdit({ ...edit, stages: e.target.checked ? [...edit.stages, k] : edit.stages.filter((x) => x !== k) })} />{l}</label>))}
          <div className="flex-1" /><Btn ghost onClick={() => setEdit(null)}>Cancel</Btn><Btn onClick={save}>Save persona</Btn></div>
      </div>}
    </section>);
}

export default function AdsMetaFunnel({ access, edge }) {
  const [days, setDays] = useState(90);
  const [personas, reloadPersonas] = useLoad(() => rpc('api_ads_meta_personas'), []);
  return (
    <div className="space-y-3" data-testid="meta-funnel">
      <div className="flex items-center gap-2">
        <select aria-label="Funnel period" className="glass-input px-3 py-2 text-sm" value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {PERIODS.map(([n, l]) => <option key={n} value={n}>{l}</option>)}</select>
        <span className="text-xs text-glass-muted">Funnel targeting: find new people broadly, bring warm and hot people back with their own message, keep paying customers and fresh leads out.</span>
      </div>
      <FunnelMap days={days} />
      <FunnelPlan access={access} personas={personas} />
      <Audiences access={access} edge={edge} />
      <Locations days={days} />
      <WebsiteSignals access={access} edge={edge} />
      <Personas access={access} list={personas} reload={reloadPersonas} />
    </div>);
}
