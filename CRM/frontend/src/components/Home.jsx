import { useEffect, useMemo, useState } from 'react';
import Icon from './icons';
import { navigate } from '../utils/route';

const DAY = 86400000;
const fmt = (n) => (n == null ? '—' : Number(n).toLocaleString('en-IN'));
const short = (n) => (n == null ? '—' : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : fmt(n));
const pct = (cur, prev) => (prev > 0 ? Math.round((100 * (cur - prev)) / prev) : null);
const label = (s) => { const t = String(s || 'new').replace(/[_-]+/g, ' ').trim(); return t.charAt(0).toUpperCase() + t.slice(1); };

// Pure numbers for the Home screen. Exported for tests.
export function homeNumbers(leads = [], followups = [], now = Date.now()) {
  const at = (l) => new Date(l.created_at).getTime() || 0;
  const week = leads.filter((l) => now - at(l) < 7 * DAY).length;
  const prevWeek = leads.filter((l) => now - at(l) >= 7 * DAY && now - at(l) < 14 * DAY).length;
  const recent = leads.filter((l) => now - at(l) < 28 * DAY);
  const notContacted = leads.filter((l) => !l.first_contacted_at && !l.closed && !l.closure_outcome).length;
  const tally = (rows, key) => Object.entries(rows.reduce((m, r) => { const k = key(r); m[k] = (m[k] || 0) + 1; return m; }, {}))
    .map(([name, n]) => ({ name, n })).sort((a, b) => b.n - a.n);
  return {
    week, prevWeek, notContacted, followupsDue: followups.length, recentTotal: recent.length,
    statuses: tally(recent, (l) => label(l.status)),
    sources: tally(recent, (l) => (l.utm_source && String(l.utm_source).trim()) || 'Not recorded'),
  };
}

// Website numbers are aggregate (no personal data), so the last answer is kept for an instant next open.
const SITE_KEY = 'home:site';
function useSiteSignals(enabled) {
  const [site, setSite] = useState(() => { try { return JSON.parse(sessionStorage.getItem(SITE_KEY) || 'null'); } catch { return null; } });
  useEffect(() => {
    if (!enabled) return undefined;
    let live = true;
    import('../backend/supabaseClient').then(({ supabase }) => supabase?.rpc('api_ads_site_signals')).then((r) => {
      if (!live || !r || r.error || !r.data) return;
      setSite(r.data);
      try { sessionStorage.setItem(SITE_KEY, JSON.stringify(r.data)); } catch { /* ignore */ }
    }).catch(() => { /* keep what we have */ });
    return () => { live = false; };
  }, [enabled]);
  return enabled ? site : null;
}

function Stat({ title, value, note, tone, onClick }) {
  const color = tone === 'good' ? '#1E7B34' : tone === 'bad' ? '#A42219' : 'var(--label-2)';
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag type={onClick ? 'button' : undefined} onClick={onClick}
      className={`glass-card p-4 sm:p-5 flex flex-col gap-1 text-left ${onClick ? 'tile-link' : ''}`}>
      <span className="text-[13px] text-glass-secondary">{title}</span>
      <span className="text-[28px] font-semibold leading-tight text-glass-primary">{value}</span>
      {note && <span className="text-[13px]" style={{ color }}>{note}</span>}
    </Tag>
  );
}

function Fold({ title, hint, children }) {
  return (
    <details className="glass-card group">
      <summary className="flex items-center justify-between gap-3 px-5 min-h-[52px] cursor-pointer list-none">
        <span className="font-semibold text-glass-primary">{title}{hint && <span className="font-normal text-glass-secondary"> · {hint}</span>}</span>
        <span className="text-[13px] text-[var(--accent)] group-open:hidden">Show</span>
        <span className="text-[13px] text-[var(--accent)] hidden group-open:inline">Hide</span>
      </summary>
      <div className="px-5 pb-5 pt-1 border-t border-[var(--hairline)]">{children}</div>
    </details>
  );
}

export default function Home({ employee, leads, followups, leadsReady, canAccessLeads, canAccessAds, canOpenKeys, onOpenTab }) {
  const n = useMemo(() => homeNumbers(leads, followups), [leads, followups]);
  const site = useSiteSignals(canAccessAds);
  const go = onOpenTab || ((tab, section, params) => navigate(tab, section, params));
  const totals = site?.totals || null;
  const clickChange = totals ? pct(Number(totals.clicks || 0), Number(totals.clicks_prev || 0)) : null;
  const gaEmpty = site?.configured?.ga4 && site?.last && Number(site.last.ga_rows || 0) === 0;
  const noPixel = site?.pixel && site.pixel.firing === false;
  const hour = new Date().getHours();
  const hello = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
  const first = String(employee?.name || '').split(' ')[0];

  const attention = [
    canAccessLeads && n.notContacted > 0 && { tone: 'bad', text: `${n.notContacted} lead${n.notContacted === 1 ? '' : 's'} not contacted yet`, action: 'Open', to: ['leads', '', { filter: 'pending' }] },
    canAccessLeads && n.followupsDue > 0 && { tone: 'warn', text: `${n.followupsDue} follow-up${n.followupsDue === 1 ? ' is' : 's are'} due`, action: 'Open', to: ['leads'] },
    gaEmpty && { tone: 'warn', text: 'GA4 is connected but sends no visitor data', action: 'Fix', to: canOpenKeys ? ['connections'] : ['metaads', 'funnel'] },
    noPixel && { tone: 'warn', text: 'The Meta ad account has no Pixel yet', action: 'Set up', to: canOpenKeys ? ['connections'] : ['metaads', 'funnel'] },
  ].filter(Boolean);
  const dot = { bad: '#C0271D', warn: '#B26A00', info: '#0A63CE' };

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="m-0 text-[26px] font-semibold tracking-tight text-glass-primary">{hello}{first ? `, ${first}` : ''}</h1>
          <p className="m-0 text-sm text-glass-secondary">{new Date().toLocaleDateString('en-IN', { weekday: 'long', day: 'numeric', month: 'long' })} · what needs you today</p>
        </div>
      </div>

      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
        {canAccessLeads && (
          <Stat title="Leads this week" value={leadsReady ? fmt(n.week) : '…'}
            note={leadsReady ? (n.week === n.prevWeek ? `Same as last week (${n.prevWeek})` : `${n.week > n.prevWeek ? '↑' : '↓'} ${Math.abs(n.week - n.prevWeek)} vs last week (${n.prevWeek})`) : null}
            tone={n.week >= n.prevWeek ? 'good' : 'bad'} onClick={() => go('leads')} />
        )}
        {canAccessLeads && (
          <Stat title="Not contacted yet" value={leadsReady ? fmt(n.notContacted) : '…'} note={n.notContacted ? 'Call these first' : 'All caught up'}
            tone={n.notContacted ? 'bad' : 'good'} onClick={() => go('leads', '', { filter: 'pending' })} />
        )}
        {canAccessLeads && (
          <Stat title="Follow-ups due" value={leadsReady ? fmt(n.followupsDue) : '…'} note={n.followupsDue ? 'Waiting for a call back' : 'Nothing due'}
            tone={n.followupsDue ? 'bad' : 'good'} onClick={() => go('leads')} />
        )}
        {canAccessAds && (
          <Stat title="Google clicks · 28 days" value={totals ? fmt(totals.clicks) : '…'}
            note={clickChange == null ? (totals ? 'From Search Console' : null) : `${clickChange >= 0 ? '↑' : '↓'} ${Math.abs(clickChange)}% vs previous 28 days`}
            tone={clickChange != null && clickChange < 0 ? 'bad' : 'good'} />
        )}
        {!canAccessLeads && !canAccessAds && (
          <Stat title="Your tasks" value={<Icon name="tasks" size={26} />} note="Open your task board" onClick={() => go('tasks')} />
        )}
      </div>

      <div className="grid gap-4 items-start" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))' }}>
        <section className="glass-card p-5">
          <h2 className="m-0 mb-2 text-base font-semibold text-glass-primary">Needs your attention</h2>
          {attention.length === 0 ? (
            <p className="m-0 py-3 text-sm text-glass-secondary inline-flex items-center gap-2"><Icon name="check" size={16} />Nothing urgent right now.</p>
          ) : attention.map((a) => (
            <div key={a.text} className="flex items-center justify-between gap-3 py-3 border-t border-[var(--hairline)] first-of-type:border-t-0">
              <span className="flex items-center gap-3 min-w-0 text-sm text-glass-primary">
                <span className="w-2 h-2 rounded-full shrink-0" style={{ background: dot[a.tone] }} />{a.text}
              </span>
              <button type="button" onClick={() => go(...a.to)} className="shrink-0 text-sm font-medium text-[var(--accent)] min-h-[36px] px-1">{a.action}</button>
            </div>
          ))}
        </section>

        {canAccessLeads && (
          <section className="glass-card p-5">
            <div className="flex items-baseline justify-between mb-3">
              <h2 className="m-0 text-base font-semibold text-glass-primary">Leads · last 28 days</h2>
              <span className="text-[13px] text-glass-secondary">{leadsReady ? `${n.recentTotal} total` : 'Loading…'}</span>
            </div>
            <div className="flex flex-col gap-3">
              {n.statuses.slice(0, 6).map((s) => (
                <div key={s.name} className="flex flex-col gap-1">
                  <div className="flex justify-between text-sm"><span className="text-glass-primary">{s.name}</span><span className="text-glass-secondary">{s.n}</span></div>
                  <div className="h-2 rounded bg-[var(--surface-sunken)] overflow-hidden">
                    <div className="h-2 rounded" style={{ width: `${Math.round((100 * s.n) / Math.max(1, n.recentTotal))}%`, background: 'var(--accent)' }} />
                  </div>
                </div>
              ))}
              {leadsReady && n.statuses.length === 0 && <p className="m-0 text-sm text-glass-secondary">No leads in the last 28 days.</p>}
            </div>
          </section>
        )}
      </div>

      {canAccessLeads && n.sources.length > 0 && (
        <Fold title="Where leads came from" hint="last 28 days">
          {n.sources.map((s) => (
            <div key={s.name} className="flex justify-between py-2 text-sm"><span className="text-glass-primary">{s.name}</span><span className="text-glass-secondary">{s.n}</span></div>
          ))}
        </Fold>
      )}

      {canAccessAds && totals && (
        <Fold title="Website at a glance" hint="Google Search, last 28 days">
          <div className="grid gap-3 py-2" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))' }}>
            <div><div className="text-[13px] text-glass-secondary">Clicks</div><div className="text-xl font-semibold">{fmt(totals.clicks)}</div></div>
            <div><div className="text-[13px] text-glass-secondary">Seen on Google</div><div className="text-xl font-semibold">{short(Number(totals.impressions || 0))}</div></div>
            <div><div className="text-[13px] text-glass-secondary">Searches you appear for</div><div className="text-xl font-semibold">{fmt(totals.queries)}</div></div>
          </div>
          {Array.isArray(site?.rising) && site.rising.length > 0 && (
            <>
              <div className="text-[13px] text-glass-secondary mt-2 mb-1">Rising searches</div>
              {site.rising.slice(0, 5).map((r) => (
                <div key={r.query} className="flex justify-between gap-3 py-1.5 text-sm">
                  <span className="truncate text-glass-primary">{r.query}</span>
                  <span className="shrink-0 text-glass-secondary">{fmt(r.impressions)} views · pos {r.position}</span>
                </div>
              ))}
            </>
          )}
        </Fold>
      )}
    </div>
  );
}
