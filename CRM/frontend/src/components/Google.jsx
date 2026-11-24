import { useEffect, useState } from 'react';
import { supabase } from '../backend/supabaseClient';
import { navigate } from '../utils/route';
import Icon from './icons';

// Growth > Google: one door for everything Google. Three cards (Website, Google My Business, Google Ads), each with its
// headline numbers from the CRM's own data (api_google_hub), each opening its full section. The sections keep their
// addresses (#/website, #/gbp, #/ads), so every old link and bookmark still works.

const fmt = (n) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: 0 }));
const short = (n) => (n == null ? '—' : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : fmt(Math.round(n)));
const pct = (a, b) => (a == null || !b ? null : Math.round((100 * (a - b)) / b));
const day = (d) => (d ? new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' }) : '');
const daysSince = (d) => (d ? Math.floor((Date.now() - new Date(`${d}T00:00:00Z`).getTime()) / 86400000) : null);

let cache = null;

export const GOOGLE_PAGES = [['website', 'Website', 'chart'], ['gbp', 'Google My Business', 'pin'], ['ads', 'Google Ads', 'rocket']];

// The strip above Website / Google My Business / Google Ads: back to Google, or straight across to a sibling.
export function GoogleCrumb({ page, canAds = true }) {
  return (
    <nav aria-label="Google pages" className="mb-3 flex flex-wrap items-center gap-1.5 text-[13px]" data-testid="google-crumb">
      <button type="button" onClick={() => navigate('google')} className="inline-flex items-center gap-1 min-h-[32px] pr-2 font-medium text-[var(--accent)]">
        <Icon name="chevronLeft" size={15} />Google
      </button>
      {GOOGLE_PAGES.filter(([id]) => id !== 'ads' || canAds).map(([id, label]) => (
        <button key={id} type="button" onClick={() => navigate(id)} aria-current={page === id ? 'page' : undefined}
          className={`min-h-[32px] px-3 rounded-full ${page === id ? 'bg-[var(--accent-light)] text-[var(--accent)] font-semibold' : 'text-glass-secondary bg-[var(--surface-sunken)]'}`}>{label}</button>
      ))}
    </nav>
  );
}

function Delta({ cur, prev }) {
  const c = pct(cur, prev);
  if (c == null) return null;
  if (c === 0) return <span className="text-[12px] text-glass-secondary">same</span>;
  return <span className="text-[12px] font-medium whitespace-nowrap" style={{ color: c > 0 ? '#1E7B34' : '#A42219' }}>{c > 0 ? '↑' : '↓'} {Math.abs(c)}%</span>;
}
function Stat({ label, value, cur, prev }) {
  return (
    <span className="flex flex-col min-w-0">
      <span className="text-[12px] leading-tight text-glass-secondary min-h-[30px] flex items-end">{label}</span>
      <span className="text-[22px] font-semibold leading-tight text-glass-primary">{value}</span>
      <span className="min-h-[18px]"><Delta cur={cur} prev={prev} /></span>
    </span>
  );
}
function HubCard({ id, icon, title, tag, tagTone, stats, note, children }) {
  const tones = { good: ['rgba(30,123,52,0.10)', '#1E7B34'], warn: ['rgba(178,106,0,0.12)', '#8A5300'], bad: ['rgba(192,39,29,0.10)', '#A42219'], muted: ['var(--surface-sunken)', 'var(--label-2)'] };
  const [bg, fg] = tones[tagTone] || tones.muted;
  return (
    <button type="button" onClick={() => navigate(id)} data-testid={`google-card-${id}`} className="glass-card tile-link p-5 text-left block w-full">
      <span className="flex flex-col gap-4 w-full min-h-[190px]">
        <span className="flex items-center gap-3 min-w-0">
          <span className="h-11 w-11 rounded-[12px] inline-flex items-center justify-center text-white shrink-0" style={{ background: 'linear-gradient(160deg, #3D9BFF, #0A63CE)' }}><Icon name={icon} size={21} /></span>
          <span className="flex flex-col gap-1 min-w-0 items-start">
            <span className="text-[17px] font-semibold leading-tight text-glass-primary">{title}</span>
            {tag && <span className="text-[12px] px-2 py-0.5 rounded-full" style={{ background: bg, color: fg }}>{tag}</span>}
          </span>
        </span>
        {stats?.length > 0 && <span className="grid gap-3" style={{ gridTemplateColumns: `repeat(${stats.length}, minmax(0, 1fr))` }}>{stats.map((s) => <Stat key={s.label} {...s} />)}</span>}
        {children}
        <span className="mt-auto flex items-end justify-between gap-3 text-[13px]">
          <span className="text-glass-secondary">{note}</span>
          <span className="inline-flex items-center gap-0.5 font-medium text-[var(--accent)] shrink-0">Open<Icon name="chevronRight" size={15} /></span>
        </span>
      </span>
    </button>
  );
}

export default function Google({ canAds = true }) {
  const [h, setH] = useState(cache);
  const [err, setErr] = useState('');
  useEffect(() => {
    let stop = false;
    supabase.rpc('api_google_hub').then(({ data, error }) => {
      if (stop) return;
      if (error) { setErr(error.message); return; }
      cache = data; setH(data); setErr('');
    });
    return () => { stop = true; };
  }, []);
  const w = h?.website, a = h?.ads, g = h?.gbp;
  const gt = g?.totals, gp = g?.prev;
  const idle = daysSince(a?.last_spend_day);
  const gbpTag = !g ? null : g.last_day ? ['Connected', 'good'] : g.waiting_google ? ['Waiting for Google', 'warn'] : g.connections > 0 ? ['Setting up', 'warn'] : ['Not connected', 'muted'];
  const adsTag = !a ? null : idle == null ? ['No spend yet', 'muted'] : idle > 3 ? [`No spend since ${day(a.last_spend_day)}`, 'bad'] : ['Running', 'good'];
  return (
    <div className="flex flex-col gap-5" data-testid="google-hub">
      <div>
        <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">Google</h1>
        <p className="m-0 text-sm text-glass-secondary">Your website in Google Search, your Business Profile on Search and Maps, and your Google Ads. Last 28 days, with the change from the 28 days before.</p>
      </div>
      {err && !h && <div role="alert" className="glass-card p-5 text-sm">{err}</div>}
      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 300px), 1fr))' }}>
        <HubCard id="website" icon="chart" title="Website" tag={w ? (w.clicks != null ? 'Connected' : 'No data yet') : null} tagTone={w?.clicks != null ? 'good' : 'muted'}
          stats={[{ label: 'Clicks from Google', value: fmt(w?.clicks), cur: w?.clicks, prev: w?.clicks_prev }, { label: 'Seen on Google', value: short(w?.impressions) }, { label: 'Visitors', value: fmt(w?.visitors) }]}
          note="Search Console and Google Analytics" />
        <HubCard id="gbp" icon="pin" title="Google My Business" tag={gbpTag?.[0]} tagTone={gbpTag?.[1]}
          stats={g?.last_day ? [{ label: 'Profile views', value: short(gt?.views), cur: gt?.views, prev: gp?.days ? gp?.views : null }, { label: 'Calls', value: fmt(gt?.calls), cur: gt?.calls, prev: gp?.days ? gp?.calls : null },
            { label: 'Rating', value: g.rating != null ? `${Number(g.rating).toFixed(1)} ★` : '—' }] : null}
          note={g?.last_day ? `${fmt(g.reviews)} reviews · ${g.tracked} profile${g.tracked === 1 ? '' : 's'}` : 'Views, calls, directions, search words and reviews'}>
          {h && !g?.last_day && <span className="text-sm text-glass-secondary">{g?.waiting_google ? 'Google has not approved the project for Business Profile data yet. Nothing can be read until its approval email arrives.'
            : g?.connections > 0 ? 'A Google login is saved. Open to choose the profiles and collect the first numbers.' : 'Add the Google login that owns or manages your Business Profile to see how people find and contact you.'}</span>}
        </HubCard>
        {canAds && <HubCard id="ads" icon="rocket" title="Google Ads" tag={adsTag?.[0]} tagTone={adsTag?.[1]}
          stats={[{ label: 'Spend', value: a ? `₹${fmt(a.spend)}` : '—' }, { label: 'Clicks', value: fmt(a?.clicks) }, { label: 'Seen', value: short(a?.impressions) }]}
          note="Campaigns, leads and the AI team" />}
      </div>
    </div>
  );
}
