import { useState } from 'react';
import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';

// Meta Ads > Strategy: who the plans speak to (premium audience: metros, what Meta offers this account) and the Competitor
// watch (migrations 114-115). Free sources only: competitors' ads are added by hand from the Meta Ad Library and Google's
// Ads Transparency Center (their APIs do not return Indian commercial ads); the Strategy Researcher reads them and keeps
// each competitor's strongest idea and the gap it leaves.

const C = { green: '#1E9E4A', amber: '#B25E00', grey: 'rgba(118,118,128,0.14)', ink: '#1C1C1E', blue: '#0088FF' };
const enc = encodeURIComponent;
const adLibrary = (q) => `https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=IN&q=${enc(q)}&search_type=keyword_unordered`;
const transparency = (d) => `https://adstransparency.google.com/?region=IN&domain=${enc(d)}`;
const FORMATS = [['image', 'Image'], ['video', 'Video'], ['carousel', 'Carousel'], ['text', 'Text (Google)'], ['other', 'Other']];
const PLATFORMS = [['meta', 'Facebook / Instagram'], ['google', 'Google'], ['youtube', 'YouTube'], ['other', 'Other']];

const Chip = ({ children, color = C.ink }) => <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: C.grey, color }}>{children}</span>;

function Audience() {
  const [t] = useLoad(() => rpc('api_ads_meta_targeting').catch(() => null), []);
  if (!t) return null;
  const s = t.support || {};
  const yes = (v) => (v === true ? ['Offered', C.green] : v === false ? ['Not offered', C.amber] : ['Not checked yet', 'rgba(60,60,67,0.6)']);
  const [zl, zc] = yes(s.zip?.ok); const [il, ic] = yes(s.income?.ok);
  return (
    <section className="glass-card p-4 space-y-2" data-testid="premium-audience">
      <div className="flex items-start gap-2"><div className="flex-1"><h3 className="m-0 text-base font-semibold">Who the plans reach</h3>
        <p className="m-0 text-xs text-glass-muted">Premium audience is on for new strategies: students 18+ and parents (35+), every form asks how training will be funded, and one ad states the fee range. Meta no longer lets anyone exclude people by interest, so the ad and the form do the filtering.</p></div></div>
      <div className="text-sm"><span className="text-glass-muted">Default places:</span> {(t.metros || []).map((m) => m.name).join(', ')}</div>
      <div className="flex flex-wrap gap-2 text-xs">
        <span className="inline-flex items-center gap-1.5">PIN-code targeting in India <Chip color={zc}>{zl}</Chip></span>
        <span className="inline-flex items-center gap-1.5">Household income <Chip color={ic}>{il}</Chip></span>
        {s.checked_at && <span className="text-glass-muted">checked {new Date(s.checked_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })} by the daily audience job</span>}
      </div>
      {s.income?.ok && (s.income.options || []).length > 0 && <div className="text-xs text-glass-muted">Income options Meta offers: {s.income.options.map((o) => o.name).join(', ')}. Meta does not say which countries they cover, so plans use them only as a test.</div>}
    </section>);
}

function AdForm({ competitor, onDone }) {
  const [f, setF] = useState({ platform: 'meta', format: 'image', started_on: '', primary_text: '', headline: '', url: '', landing_url: '', offer: '', angle: '' });
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const save = async () => { const r = await run(rpc('api_ads_competitor_ad_save', { p: { ...f, competitor_id: competitor.id } }), 'Ad added'); if (r) onDone(); };
  const inp = 'glass-input w-full px-3 py-2 text-sm';
  return (
    <div className="space-y-2 rounded-xl border border-[var(--hairline)] p-3" data-testid="competitor-ad-form">
      <div className="grid sm:grid-cols-3 gap-2">
        <label className="text-xs text-glass-muted">Where<select className={inp} value={f.platform} onChange={set('platform')}>{PLATFORMS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <label className="text-xs text-glass-muted">Format<select className={inp} value={f.format} onChange={set('format')}>{FORMATS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <label className="text-xs text-glass-muted">Started running on<input type="date" className={inp} value={f.started_on} max={new Date().toISOString().slice(0, 10)} onChange={set('started_on')} /></label>
      </div>
      <label className="block text-xs text-glass-muted">Ad text<textarea rows={3} className={inp} value={f.primary_text} onChange={set('primary_text')} placeholder="Paste the ad's main text" /></label>
      <div className="grid sm:grid-cols-2 gap-2">
        <label className="text-xs text-glass-muted">Headline<input className={inp} value={f.headline} onChange={set('headline')} /></label>
        <label className="text-xs text-glass-muted">Offer (if any)<input className={inp} value={f.offer} onChange={set('offer')} placeholder="e.g. free counselling, scholarship test" /></label>
        <label className="text-xs text-glass-muted">Ad link (Ad Library / Transparency Center)<input className={inp} value={f.url} onChange={set('url')} placeholder="https://" /></label>
        <label className="text-xs text-glass-muted">Landing page<input className={inp} value={f.landing_url} onChange={set('landing_url')} placeholder="https://" /></label>
      </div>
      <div className="flex gap-2 justify-end"><Btn ghost onClick={onDone}>Cancel</Btn><Btn onClick={save} data-testid="competitor-ad-save">Add ad</Btn></div>
    </div>);
}

function Competitor({ c, canEdit, reload }) {
  const [open, setOpen] = useState(false);
  const [adding, setAdding] = useState(false);
  const top = (c.ads || [])[0];
  const f = (c.findings || [])[0];
  return (
    <div className="py-3 border-t border-[var(--hairline)] first:border-t-0" data-testid="competitor">
      <button type="button" className="w-full text-left flex items-start gap-2" onClick={() => setOpen(!open)} aria-expanded={open}>
        <div className="flex-1 min-w-0">
          <div className="font-semibold text-sm">{c.name}{c.domain && <span className="font-normal text-glass-muted"> · {c.domain}</span>}</div>
          <div className="text-xs text-glass-muted">{(c.ads || []).length} ad{(c.ads || []).length === 1 ? '' : 's'} saved{top?.days_running != null ? ` · longest running ${top.days_running} days` : ''}
            {f?.gap ? ` · gap: ${f.gap}` : ''}</div>
        </div>
        <span style={{ display: 'inline-flex', transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}><Icon name="chevronDown" size={16} /></span>
      </button>
      {open && <div className="mt-2 space-y-2">
        <div className="flex flex-wrap gap-3 text-xs">
          <a href={adLibrary(c.name)} target="_blank" rel="noreferrer">Their live ads in the Meta Ad Library</a>
          {c.domain && <a href={transparency(c.domain)} target="_blank" rel="noreferrer">Their Google ads (Transparency Center)</a>}
          {c.domain && <a href={`https://${c.domain}`} target="_blank" rel="noreferrer">Website</a>}
        </div>
        {f && <div className="text-sm rounded-xl p-2.5" style={{ background: 'rgba(0,136,255,0.06)' }}>
          {f.strongest && <div><span className="text-glass-muted">Their strongest idea:</span> {f.strongest}</div>}
          {f.gap && <div><span className="text-glass-muted">The gap we can own:</span> {f.gap}</div>}
          <div className="text-[11px] text-glass-muted">From the Strategy Researcher, {new Date(f.at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}</div>
        </div>}
        {(c.ads || []).map((a) => (
          <div key={a.id} className="text-sm rounded-xl border border-[var(--hairline)] p-2.5 space-y-1">
            <div className="flex flex-wrap items-center gap-1.5">
              <Chip>{a.format}</Chip>{a.days_running != null && <Chip color={a.days_running >= 30 ? C.green : C.ink}>{a.days_running} days running{a.days_running >= 30 ? ' · proven' : ''}</Chip>}
              {a.offer && <Chip color={C.blue}>{a.offer}</Chip>}
              <div className="flex-1" />
              {canEdit && <button type="button" className="text-xs text-[var(--accent)]" onClick={() => run(rpc('api_ads_competitor_ad_seen', { p_id: a.id }), 'Marked as still running').then(reload)}>Still running</button>}
              {canEdit && <button type="button" className="text-xs text-glass-muted" onClick={() => run(rpc('api_ads_competitor_delete', { p_kind: 'ad', p_id: a.id }), 'Removed').then(reload)}>Remove</button>}
            </div>
            {a.headline && <div className="font-medium">{a.headline}</div>}
            {a.primary_text && <div className="text-glass-secondary whitespace-pre-line">{a.primary_text}</div>}
            {a.url && <a className="text-xs" href={a.url} target="_blank" rel="noreferrer">Open the ad</a>}
          </div>))}
        {canEdit && (adding ? <AdForm competitor={c} onDone={() => { setAdding(false); reload(); }} />
          : <div className="flex gap-3"><Btn ghost onClick={() => setAdding(true)} data-testid="competitor-add-ad"><Icon name="plus" size={14} />Add one of their ads</Btn>
            <Btn ghost onClick={() => run(rpc('api_ads_competitor_delete', { p_kind: 'competitor', p_id: c.id }), 'Competitor removed').then(reload)}>Remove competitor</Btn></div>)}
      </div>}
    </div>);
}

export default function AdsMetaCompetitors() {
  const [d, reload] = useLoad(() => rpc('api_ads_competitors'), []);
  const [name, setName] = useState(''); const [domain, setDomain] = useState('');
  const add = async () => { const r = await run(rpc('api_ads_competitor_save', { p: { name, domain } }), 'Competitor added'); if (r) { setName(''); setDomain(''); reload(); } };
  return (
    <div className="space-y-4">
      <Audience />
      <section className="glass-card p-4 space-y-2" data-testid="competitor-watch">
        <h3 className="m-0 text-base font-semibold">Competitor watch</h3>
        <p className="m-0 text-xs text-glass-muted">Save competitors' ads from the Meta Ad Library and Google's Ads Transparency Center with the date they started. Ads that keep running for weeks are the ones that work for them. Every new strategy reads this, takes their strongest ideas where they fit our facts and aims at the gaps they leave.</p>
        {!d ? <div className="text-sm text-glass-muted">Loading…</div> : <>
          {(d.items || []).map((c) => <Competitor key={c.id} c={c} canEdit={d.can_edit} reload={reload} />)}
          {(d.other_findings || []).length > 0 && <div className="text-xs text-glass-muted pt-2">Also found by the Researcher: {d.other_findings.map((f) => `${f.name}${f.gap ? ` (gap: ${f.gap})` : ''}`).join('; ')}</div>}
          {d.can_edit && <div className="flex flex-wrap gap-2 pt-2">
            <input aria-label="Competitor name" className="glass-input px-3 py-2 text-sm flex-1 min-w-[160px]" value={name} onChange={(e) => setName(e.target.value)} placeholder="Competitor name" />
            <input aria-label="Competitor website" className="glass-input px-3 py-2 text-sm flex-1 min-w-[160px]" value={domain} onChange={(e) => setDomain(e.target.value)} placeholder="Website (optional)" />
            <Btn disabled={name.trim().length < 2} onClick={add} data-testid="competitor-add">Add competitor</Btn>
          </div>}
        </>}
      </section>
    </div>);
}
