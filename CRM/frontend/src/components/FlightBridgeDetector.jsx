import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react';
import { apiFetch } from '../api';
import { countryName, timeAgo } from '../utils/country';

// FlightBridge AI > School Detector: the whole-world sweep, live.
// The engine (Mac Mini) searches the world square by square inside Google's free monthly allowance; this screen
// shows where it is, what it has found, and how much of the free allowance is used. Refreshes every 20 seconds.
const Globe3D = lazy(() => import('./Globe3D'));

const SKU_LABEL = {
  text_search_pro: ['Map searches', 'finding schools square by square'],
  text_search_enterprise: ['Website look-ups', 'finding each school’s website'],
  place_details_pro: ['Location look-ups', 'placing older schools on the globe'],
  place_details_enterprise: ['Phone look-ups', 'Google phone numbers'],
};
const ELIG = {
  eligible_verified: ['Eligible', '#34d399'], eligible_claimed: ['Check needed', '#fbbf24'],
  unqualified: ['Unqualified', '#f87171'], unknown: ['Not checked yet', '#94a3b8'],
};

async function load() {
  const res = await apiFetch('/api/flightbridge/detector', { token: localStorage.getItem('token') });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

function Stat({ label, value, sub, color = '#e2e8f0' }) {
  return (
    <div className="rounded-xl p-3" style={{ background: 'rgba(15,23,42,0.7)', border: '1px solid rgba(34,211,238,0.15)' }}>
      <div className="text-[11px] uppercase tracking-wider" style={{ color: '#7dd3fc' }}>{label}</div>
      <div className="text-2xl font-bold tnum mt-0.5" style={{ color }}>{value}</div>
      {sub && <div className="text-xs mt-0.5" style={{ color: '#94a3b8' }}>{sub}</div>}
    </div>
  );
}

function Bar({ value, max, color = '#22d3ee' }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <div className="h-2 rounded-full overflow-hidden" style={{ background: 'rgba(148,163,184,0.18)' }} role="progressbar"
      aria-valuenow={value} aria-valuemin={0} aria-valuemax={max}>
      <div className="h-full rounded-full transition-[width] duration-700" style={{ width: `${pct}%`, background: color, boxShadow: `0 0 10px ${color}` }} />
    </div>
  );
}

export default function FlightBridgeDetector() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [allCountries, setAllCountries] = useState(false);

  const refresh = useCallback(() => load().then((x) => { setD(x); setErr(''); }, (e) => setErr(e.message)), []);
  useEffect(() => {
    refresh();
    const t = setInterval(() => { if (!document.hidden) refresh(); }, 20000);
    return () => clearInterval(t);
  }, [refresh]);

  const points = useMemo(() => d?.points || [], [d]);
  const recent = useMemo(() => d?.recent || [], [d]);
  const scanning = d?.scanning || null;
  const countries = d?.countries || [];
  const tot = d?.totals || {};
  const active = countries.find((c) => c.state === 'scanning');
  const shown = allCountries ? countries
    : [...countries.filter((c) => c.state === 'scanning'), ...countries.filter((c) => c.state === 'queued').slice(0, 5),
      ...countries.filter((c) => c.state === 'done').slice(-4)];
  const engineAge = d?.engine?.at ? (Date.now() - new Date(d.engine.at).getTime()) / 60000 : null;
  const engineOk = engineAge !== null && engineAge < 5 && !d?.engine?.engine_off;
  const sweepOff = d?.autopilot && d.autopilot.world_sweep === false;

  return (
    <section className="rounded-2xl overflow-hidden text-slate-200" aria-label="School Detector"
      style={{ background: 'radial-gradient(120% 90% at 20% 0%, #0b2540 0%, #050b16 55%, #02060d 100%)', border: '1px solid rgba(34,211,238,0.18)' }}>
      <div className="flex flex-wrap items-center justify-between gap-3 px-4 sm:px-5 pt-4">
        <div>
          <h3 className="text-lg font-bold text-white flex items-center gap-2">
            <span className="relative flex h-2.5 w-2.5" aria-hidden="true">
              {engineOk && !sweepOff && <span className="absolute inline-flex h-full w-full rounded-full opacity-75 animate-ping" style={{ background: '#22d3ee' }} />}
              <span className="relative inline-flex rounded-full h-2.5 w-2.5" style={{ background: engineOk ? '#22d3ee' : '#64748b' }} />
            </span>
            School Detector
          </h3>
          <p className="text-sm" style={{ color: '#94a3b8' }}>
            Searching every country for flying schools{active ? <> · now in <b className="text-white">{countryName(active.country)}</b></> : ''}
          </p>
        </div>
        <div className="text-xs font-mono px-2.5 py-1 rounded-md" style={{ background: 'rgba(15,23,42,0.8)', color: engineOk ? '#67e8f9' : '#fca5a5' }}>
          {engineAge === null ? 'engine not reporting' : engineOk ? `engine online · ${d.engine.runner || 'runner'}` : `engine last seen ${timeAgo(d.engine.at)}`}
        </div>
      </div>

      {err && <div className="mx-5 mt-3 text-sm rounded-lg p-3" style={{ background: 'rgba(127,29,29,0.4)', color: '#fecaca' }}>Couldn’t load: {err}</div>}
      {sweepOff && <div className="mx-5 mt-3 text-sm rounded-lg p-3" style={{ background: 'rgba(120,53,15,0.4)', color: '#fde68a' }}>The world search is switched off in Automation settings.</div>}

      <div className="grid gap-4 p-4 sm:p-5 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div className="relative rounded-xl" style={{ minHeight: 280 }}>
          <div className="aspect-square w-full max-h-[560px] mx-auto">
            <Suspense fallback={<div className="w-full h-full grid place-items-center text-sm" style={{ color: '#64748b' }}>Loading globe…</div>}>
              <Globe3D points={points} recent={recent} scanning={scanning} />
            </Suspense>
          </div>
          <div className="flex flex-wrap gap-3 text-xs mt-2 justify-center" style={{ color: '#cbd5e1' }}>
            {[['#34d399', 'Eligible'], ['#fbbf24', 'Check needed'], ['#22d3ee', 'Other schools'], ['#f472b6', 'Searching now'], ['#2fa3c7', 'Airfields']].map(([c, l]) => (
              <span key={l} className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-full" style={{ background: c, boxShadow: `0 0 6px ${c}` }} />{l}</span>
            ))}
          </div>
          <p className="text-center text-xs mt-1" style={{ color: '#64748b' }}>Drag to turn the globe</p>
        </div>

        <div className="space-y-4 min-w-0">
          <div className="grid grid-cols-2 gap-3">
            <Stat label="Schools in database" value={(tot.all_schools ?? 0).toLocaleString()} />
            <Stat label="New in 24 hours" value={(tot.new_24h ?? 0).toLocaleString()} color="#34d399" />
            <Stat label="Found by the world search" value={(tot.schools_found ?? 0).toLocaleString()} sub={`${(tot.schools_new ?? 0).toLocaleString()} were new`} />
            <Stat label="Countries finished" value={`${tot.countries_done ?? 0} / ${tot.countries ?? 0}`} />
          </div>

          <div className="rounded-xl p-3 space-y-2" style={{ background: 'rgba(15,23,42,0.7)', border: '1px solid rgba(244,114,182,0.25)' }}>
            <div className="text-[11px] uppercase tracking-wider" style={{ color: '#f9a8d4' }}>Searching now</div>
            {active ? (
              <>
                <div className="flex justify-between gap-2 text-sm">
                  <span className="font-semibold text-white">{countryName(active.country)}</span>
                  <span className="font-mono" style={{ color: '#cbd5e1' }}>{active.squares_done.toLocaleString()} / {active.squares_total.toLocaleString()} squares</span>
                </div>
                <Bar value={active.squares_done} max={active.squares_total} color="#f472b6" />
                {scanning && <div className="text-xs font-mono" style={{ color: '#94a3b8' }}>
                  last square {Math.abs(scanning.lat0).toFixed(1)}°{scanning.lat0 >= 0 ? 'N' : 'S'} {Math.abs(scanning.lng0).toFixed(1)}°{scanning.lng0 >= 0 ? 'E' : 'W'} · {timeAgo(scanning.at)}
                </div>}
              </>
            ) : <div className="text-sm" style={{ color: '#94a3b8' }}>{countries.length ? 'Waiting for the next search (paced to stay inside Google’s free limit).' : 'Starts when the engine on the Mac Mini is updated.'}</div>}
          </div>

          <div className="rounded-xl p-3 space-y-3" style={{ background: 'rgba(15,23,42,0.7)', border: '1px solid rgba(34,211,238,0.15)' }}>
            <div className="flex justify-between items-baseline">
              <div className="text-[11px] uppercase tracking-wider" style={{ color: '#7dd3fc' }}>Google free limit this month</div>
              <div className="text-[11px]" style={{ color: '#64748b' }}>stops before it costs anything</div>
            </div>
            {Object.entries(d?.quota?.skus || {}).map(([k, v]) => {
              const [label, hint] = SKU_LABEL[k] || [k, ''];
              const pct = v.cap ? v.used / v.cap : 0;
              return (
                <div key={k}>
                  <div className="flex justify-between text-xs mb-1"><span className="text-slate-200">{label} <span style={{ color: '#64748b' }}>· {hint}</span></span>
                    <span className="font-mono" style={{ color: '#cbd5e1' }}>{v.used.toLocaleString()} / {v.cap.toLocaleString()}</span></div>
                  <Bar value={v.used} max={v.cap} color={pct > 0.9 ? '#f87171' : pct > 0.7 ? '#fbbf24' : '#22d3ee'} />
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <div className="grid gap-4 px-4 sm:px-5 pb-5 lg:grid-cols-2">
        <div className="rounded-xl p-3 min-w-0" style={{ background: 'rgba(15,23,42,0.7)', border: '1px solid rgba(34,211,238,0.15)' }}>
          <div className="text-[11px] uppercase tracking-wider mb-2" style={{ color: '#7dd3fc' }}>Live feed</div>
          {recent.length === 0 ? <div className="text-sm py-4 text-center" style={{ color: '#64748b' }}>No finds yet.</div> : (
            <ul className="space-y-1.5 max-h-80 overflow-y-auto pr-1">
              {recent.slice(0, 30).map((r, i) => {
                const [el, ec] = ELIG[r.eligibility] || ELIG.unknown;
                return (
                  <li key={`${r.org_id}-${i}`} className="flex items-center gap-2 text-sm rounded-lg px-2 py-1.5" style={{ background: 'rgba(2,6,23,0.55)' }}>
                    <span className={`shrink-0 text-[10px] font-bold px-1.5 py-0.5 rounded ${r.is_new ? '' : 'opacity-60'}`}
                      style={{ background: r.is_new ? 'rgba(52,211,153,0.18)' : 'rgba(148,163,184,0.15)', color: r.is_new ? '#6ee7b7' : '#cbd5e1' }}>{r.is_new ? 'NEW' : 'SEEN'}</span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-slate-100">{r.name}</span>
                      <span className="block text-xs" style={{ color: '#94a3b8' }}>{countryName(r.country)} · {timeAgo(r.at)}</span>
                    </span>
                    <span className="shrink-0 text-[11px] px-1.5 py-0.5 rounded" style={{ color: ec, border: `1px solid ${ec}55` }}>{el}</span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className="rounded-xl p-3 min-w-0" style={{ background: 'rgba(15,23,42,0.7)', border: '1px solid rgba(34,211,238,0.15)' }}>
          <div className="flex justify-between items-center mb-2">
            <div className="text-[11px] uppercase tracking-wider" style={{ color: '#7dd3fc' }}>Countries</div>
            {countries.length > 10 && <button className="text-xs underline min-h-[32px] px-1" style={{ color: '#67e8f9' }} onClick={() => setAllCountries((v) => !v)}>
              {allCountries ? 'Show fewer' : `Show all ${countries.length}`}</button>}
          </div>
          {countries.length === 0 ? <div className="text-sm py-4 text-center" style={{ color: '#64748b' }}>The country list appears once the search starts.</div> : (
            <ul className="space-y-2 max-h-80 overflow-y-auto pr-1">
              {shown.map((c) => (
                <li key={c.country} className="text-sm">
                  <div className="flex justify-between gap-2">
                    <span className="truncate"><span className="font-mono text-xs mr-1.5" style={{ color: '#64748b' }}>{String(c.priority).padStart(3, '0')}</span>{countryName(c.country)}</span>
                    <span className="shrink-0 text-xs" style={{ color: c.state === 'done' ? '#6ee7b7' : c.state === 'scanning' ? '#f9a8d4' : '#64748b' }}>
                      {c.state === 'done' ? `done · ${c.schools_found} schools` : c.state === 'scanning' ? `${c.schools_found} schools so far` : 'waiting'}
                    </span>
                  </div>
                  {c.state !== 'queued' && <div className="mt-1"><Bar value={c.squares_done} max={c.squares_total} color={c.state === 'done' ? '#34d399' : '#f472b6'} /></div>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}
