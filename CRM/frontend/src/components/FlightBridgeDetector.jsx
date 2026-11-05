import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { apiFetch } from '../api';
import { countryName, timeAgo } from '../utils/country';

// FlightBridge AI > School Detector: the whole-world search, live.
// The engine (Mac Mini) searches the world square by square inside Google's free monthly allowance. This screen shows
// where it is, what it found and how much of the free allowance is used; the globe replays the latest squares like a
// movie "tracking" screen. Data refreshes every 20 seconds.
const Globe3D = lazy(() => import('./Globe3D'));

const SKU_LABEL = {
  text_search_pro: ['Map searches', 'finding schools square by square'],
  text_search_enterprise: ['Website look-ups', 'finding each school’s website'],
  place_details_pro: ['Location look-ups', 'placing older schools on the globe'],
  place_details_enterprise: ['Phone look-ups', 'Google phone numbers'],
};
const ELIG = {
  eligible_verified: ['Eligible', '#248A3D', 'rgba(52,199,89,0.16)'], eligible_claimed: ['Check needed', '#C93400', 'rgba(255,149,0,0.14)'],
  unqualified: ['Unqualified', '#D70015', 'rgba(255,59,48,0.12)'], unknown: ['Not checked yet', 'rgba(0,0,0,0.6)', 'rgba(118,118,128,0.12)'],
};
const LEGEND = [['#248A3D', 'Eligible'], ['#FF9500', 'Check needed'], ['#32ADE6', 'Other schools'], ['#FF3B30', 'Square being searched'],
  ['#AF52DE', 'Path between squares']];
const HUD = { text: 'rgba(255,255,255,0.92)', sub: 'rgba(255,255,255,0.6)', accent: '#67e8f9', scan: '#fb7185', glass: 'rgba(2,6,23,0.62)', edge: 'rgba(165,243,252,0.28)' };
const C = { ink: 'rgba(0,0,0,0.92)', sub: 'rgba(0,0,0,0.6)', faint: '#8E8E93', line: 'rgba(60,60,67,0.12)', card: '#ffffff', soft: 'rgba(255,255,255,0.6)', accent: '#008299', scan: '#FF3B30' };
const MONO = 'ui-monospace, SFMono-Regular, Menlo, monospace';

async function load() {
  const res = await apiFetch('/api/flightbridge/detector', { token: localStorage.getItem('token') });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

const coord = (c) => {
  if (!c) return '';
  const la = (c.lat0 + c.lat1) / 2; const lo = (c.lng0 + c.lng1) / 2;
  return `${Math.abs(la).toFixed(2)}°${la >= 0 ? 'N' : 'S'} ${Math.abs(lo).toFixed(2)}°${lo >= 0 ? 'E' : 'W'}`;
};
const squareSize = (c) => {
  const s = c ? c.lat1 - c.lat0 : 1;
  return s >= 1 ? `${s}°×${s}°` : `${s * 60}′×${s * 60}′`;
};

function Label({ children, color = C.accent }) {
  return <div className="text-[11px] uppercase tracking-[0.12em] font-semibold" style={{ color, fontFamily: MONO }}>{children}</div>;
}

function Stat({ label, value, sub, color = C.ink }) {
  return (
    <div className="rounded-xl p-3" style={{ background: C.soft, border: `1px solid ${C.line}` }}>
      <Label>{label}</Label>
      <div className="text-2xl font-bold tnum mt-1" style={{ color }}>{value}</div>
      {sub && <div className="text-xs mt-0.5" style={{ color: C.sub }}>{sub}</div>}
    </div>
  );
}

function Bar({ value, max, color = '#32ADE6' }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <div className="h-2 rounded-full overflow-hidden" style={{ background: 'rgba(60,60,67,0.12)' }} role="progressbar"
      aria-valuenow={value} aria-valuemin={0} aria-valuemax={max}>
      <div className="h-full rounded-full transition-[width] duration-700" style={{ width: `${pct}%`, background: color }} />
    </div>
  );
}

// one line of the "terminal", typed out
function TypeLine({ text, instant }) {
  const [n, setN] = useState(instant ? text.length : 0);
  useEffect(() => {
    if (instant) { setN(text.length); return undefined; }
    setN(0);
    const t = setInterval(() => setN((x) => { if (x >= text.length) { clearInterval(t); return x; } return x + 1; }), 16);
    return () => clearInterval(t);
  }, [text, instant]);
  return <div className="truncate">{text.slice(0, n)}{n < text.length && <span style={{ opacity: 0.6 }}>▌</span>}</div>;
}

function linesFor(f, totals) {
  const c = f.cell;
  switch (f.phase) {
    case 'travel': return [`> ${f.far ? 'long jump' : 'next square'} → ${coord(c)}`];
    case 'scan': return [`> scanning ${squareSize(c)} square ${coord(c)} · ${countryName(c.country)}`];
    case 'lock': return [
      ...(c.results !== undefined ? [`> Google: ${c.results} results in ${c.calls} page${c.calls === 1 ? '' : 's'}`,
        `> ${c.schools} schools · ${c.new_schools} new to the CRM`] : []),
      ...(c.status === 'split' ? ['> busy square → split into 4 smaller squares'] : []),
      `> ${f.inCell ?? 0} schools on the map here · links drawn`];
    case 'overview': return [`> world view · ${(totals.squares_done ?? 0).toLocaleString()} of ${(totals.squares_total ?? 0).toLocaleString()} squares searched`];
    case 'manual': return ['> manual view · the tour carries on in 10 s'];
    default: return [];
  }
}

export default function FlightBridgeDetector() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [allCountries, setAllCountries] = useState(false);
  const [focus, setFocus] = useState(null);
  const [log, setLog] = useState([]);
  const seq = useRef(0);
  const totalsRef = useRef({});
  const reduced = useMemo(() => !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches, []);

  // A single failed refresh (phone asleep, weak signal) is ignored; an error shows only if nothing has loaded yet
  // or three refreshes in a row fail.
  const fails = useRef(0);
  const loaded = useRef(false);
  const refresh = useCallback(() => load().then((x) => { fails.current = 0; loaded.current = true; setD(x); setErr(''); }, (e) => {
    fails.current += 1;
    if (!loaded.current || fails.current >= 3) setErr(/load failed|failed to fetch|abort|network/i.test(e.message) ? 'No connection. Retrying every 20 seconds.' : e.message);
  }), []);
  useEffect(() => {
    refresh();
    const t = setInterval(() => { if (!document.hidden) refresh(); }, 20000);
    const onVis = () => { if (!document.hidden) refresh(); };          // catch up as soon as the phone wakes
    document.addEventListener('visibilitychange', onVis);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', onVis); };
  }, [refresh]);

  const points = useMemo(() => d?.points || [], [d]);
  const recent = useMemo(() => d?.recent || [], [d]);
  const cells = useMemo(() => (d?.cells?.length ? d.cells : d?.scanning ? [d.scanning] : []), [d]);
  const countries = d?.countries || [];
  const tot = d?.totals || {};
  totalsRef.current = tot;
  const active = countries.find((c) => c.state === 'scanning');
  const shown = allCountries ? countries
    : [...countries.filter((c) => c.state === 'scanning'), ...countries.filter((c) => c.state === 'queued').slice(0, 5),
      ...countries.filter((c) => c.state === 'done').slice(-4)];
  const engineAge = d?.engine?.at ? (Date.now() - new Date(d.engine.at).getTime()) / 60000 : null;
  const engineOk = engineAge !== null && engineAge < 5 && !d?.engine?.engine_off;
  const sweepOff = d?.autopilot && d.autopilot.world_sweep === false;
  const latest = cells[cells.length - 1];

  const onFocus = useCallback((f) => {
    setFocus(f);
    const lines = linesFor(f, totalsRef.current);
    if (lines.length) setLog((l) => [...l, ...lines.map((text) => ({ text, id: ++seq.current }))].slice(-5));
  }, []);

  const fc = focus?.cell;
  const fresh = fc?.at && Date.now() - new Date(fc.at).getTime() < 30 * 60000;
  const badge = !fc ? null : focus.phase === 'overview' ? ['WORLD VIEW', HUD.accent]
    : focus.live ? [fresh ? 'LIVE' : `LATEST · ${timeAgo(fc.at)}`, HUD.scan]
      : [`REPLAY ${focus.idx + 1}/${focus.total} · ${timeAgo(fc.at)}`, '#c4b5fd'];
  const locked = fc && (focus.phase === 'scan' || focus.phase === 'lock');

  return (
    <section className="glass-card overflow-hidden" aria-label="School Detector" style={{ color: C.ink }}>
      <div className="flex flex-wrap items-center justify-between gap-3 px-4 sm:px-5 pt-4">
        <div className="min-w-0">
          <h3 className="text-lg font-bold flex items-center gap-2">
            <span className="relative flex h-2.5 w-2.5" aria-hidden="true">
              {engineOk && !sweepOff && !reduced && <span className="absolute inline-flex h-full w-full rounded-full opacity-60 animate-ping" style={{ background: C.scan }} />}
              <span className="relative inline-flex rounded-full h-2.5 w-2.5" style={{ background: engineOk ? C.scan : '#8E8E93' }} />
            </span>
            School Detector
          </h3>
          <p className="text-sm" style={{ color: C.sub }}>
            Searching every country for flying schools{active ? <> · now in <b style={{ color: C.ink }}>{countryName(active.country)}</b></> : ''}
          </p>
        </div>
        <div className="text-xs px-2.5 py-1 rounded-md" style={{ fontFamily: MONO, background: engineOk ? 'rgba(48,176,199,0.10)' : 'rgba(255,59,48,0.08)', color: engineOk ? '#008299' : '#D70015', border: `1px solid ${engineOk ? '#a5f3fc' : 'rgba(255,59,48,0.3)'}` }}>
          {engineAge === null ? 'engine not reporting' : engineOk ? `engine online · ${d.engine.runner || 'runner'}` : `engine last seen ${timeAgo(d.engine.at)}`}
        </div>
      </div>

      {err && <div className="mx-4 sm:mx-5 mt-3 text-sm rounded-lg p-3" style={{ background: 'rgba(255,59,48,0.08)', color: '#D70015' }}>{err}</div>}
      {sweepOff && <div className="mx-4 sm:mx-5 mt-3 text-sm rounded-lg p-3" style={{ background: 'rgba(255,149,0,0.08)', color: '#C93400' }}>The world search is switched off in Automation settings.</div>}

      <div className="grid gap-4 p-4 sm:p-5 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
        {/* ---------------- globe stage */}
        <div className="min-w-0">
          <div className="relative rounded-xl overflow-hidden h-[380px] sm:h-[480px] lg:h-[600px]"
            style={{ border: '1px solid rgba(0,0,0,0.92)', background: 'radial-gradient(circle at 50% 45%, #0d1b33 0%, #050b18 55%, #01030a 100%)' }}>
            <div className="absolute inset-0 pointer-events-none fb-stars" aria-hidden="true" />
            <Suspense fallback={<div className="absolute inset-0 grid place-items-center text-sm" style={{ color: HUD.sub }}>Loading Earth…</div>}>
              <Globe3D points={points} recent={recent} cells={cells} onFocus={onFocus} />
            </Suspense>

            {/* HUD frame corners */}
            {['top-2 left-2 border-t-2 border-l-2', 'top-2 right-2 border-t-2 border-r-2', 'bottom-2 left-2 border-b-2 border-l-2', 'bottom-2 right-2 border-b-2 border-r-2'].map((p) => (
              <span key={p} className={`absolute w-5 h-5 pointer-events-none ${p}`} style={{ borderColor: 'rgba(103,232,249,0.55)' }} aria-hidden="true" />
            ))}

            {/* target reticle (the camera always centres the square it is on) */}
            {locked && !reduced && (
              <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none" aria-hidden="true">
                <div className="w-24 h-24 sm:w-28 sm:h-28 rounded-full fb-spin" style={{ border: '1px dashed rgba(251,113,133,0.6)', boxShadow: '0 0 24px rgba(251,113,133,0.25)' }} />
              </div>
            )}

            {/* sector read-out */}
            <div className="absolute top-3 left-3 sm:top-4 sm:left-4 pointer-events-none max-w-[70%]" style={{ fontFamily: MONO }}>
              <div className="text-[10px] uppercase tracking-[0.18em]" style={{ color: HUD.accent }}>
                {focus?.phase === 'overview' ? 'World search' : focus?.phase === 'manual' ? 'Manual view' : 'Searching square'}
              </div>
              <div className="text-sm sm:text-base font-bold tnum" style={{ color: '#fff', textShadow: '0 1px 6px rgba(0,0,0,0.8)' }}>
                {focus?.phase === 'overview' || !fc ? `${(tot.squares_done ?? 0).toLocaleString()} / ${(tot.squares_total ?? 0).toLocaleString()} squares` : coord(fc)}
              </div>
              {fc && focus?.phase !== 'overview' && (
                <div className="text-[11px]" style={{ color: HUD.text, textShadow: '0 1px 4px rgba(0,0,0,0.9)' }}>{countryName(fc.country)} · {squareSize(fc)}{fc.schools !== undefined ? ` · ${fc.schools} schools` : ''}</div>
              )}
            </div>
            {badge && (
              <div className="absolute top-3 right-3 sm:top-4 sm:right-4 pointer-events-none flex items-center gap-1.5 text-[10px] sm:text-[11px] font-bold tracking-wider px-2 py-1 rounded"
                style={{ fontFamily: MONO, color: badge[1], background: HUD.glass, border: `1px solid ${badge[1]}88`, backdropFilter: 'blur(4px)' }}>
                <span className={`h-1.5 w-1.5 rounded-full ${badge[0] === 'LIVE' && !reduced ? 'animate-pulse' : ''}`} style={{ background: badge[1] }} />
                {badge[0]}
              </div>
            )}

            {/* terminal */}
            {log.length > 0 && (
              <div className="absolute left-3 bottom-3 sm:left-4 sm:bottom-4 pointer-events-none w-[min(92%,440px)] rounded-lg px-2.5 py-2 text-[10.5px] sm:text-[11.5px] leading-[1.55]"
                style={{ fontFamily: MONO, background: HUD.glass, border: `1px solid ${HUD.edge}`, color: HUD.accent, backdropFilter: 'blur(4px)' }}
                aria-live="off">
                {log.slice(-4).map((l, i, a) => <TypeLine key={l.id} text={l.text} instant={reduced || i < a.length - 2} />)}
              </div>
            )}
          </div>

          <div className="flex flex-wrap gap-x-4 gap-y-1.5 text-xs mt-3 justify-center" style={{ color: C.sub }}>
            {LEGEND.map(([c, l]) => (
              <span key={l} className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-full" style={{ background: c }} />{l}</span>
            ))}
          </div>
          <p className="text-center text-xs mt-1" style={{ color: C.faint }}>
            Replays the last {cells.length || 16} squares searched. Drag to look around. Imagery: NASA Blue Marble and Landsat (NASA GIBS).
          </p>
        </div>

        {/* ---------------- numbers */}
        <div className="space-y-4 min-w-0">
          <div className="grid grid-cols-2 gap-3">
            <Stat label="Schools in CRM" value={(tot.all_schools ?? 0).toLocaleString()} />
            <Stat label="New in 24 hours" value={(tot.new_24h ?? 0).toLocaleString()} color="#248A3D" />
            <Stat label="Found by world search" value={(tot.schools_found ?? 0).toLocaleString()} sub={`${(tot.schools_new ?? 0).toLocaleString()} were new`} />
            <Stat label="Countries finished" value={`${tot.countries_done ?? 0} / ${tot.countries ?? 0}`} />
          </div>

          <div className="rounded-xl p-3 space-y-2" style={{ background: 'rgba(255,59,48,0.08)', border: '1px solid rgba(255,59,48,0.25)' }}>
            <Label color={C.scan}>Searching now</Label>
            {active ? (
              <>
                <div className="flex justify-between gap-2 text-sm">
                  <span className="font-semibold">{countryName(active.country)}</span>
                  <span className="tnum" style={{ color: C.sub, fontFamily: MONO }}>{active.squares_done.toLocaleString()} / {active.squares_total.toLocaleString()} squares</span>
                </div>
                <Bar value={active.squares_done} max={active.squares_total} color={C.scan} />
                {latest && <div className="text-xs" style={{ color: C.sub, fontFamily: MONO }}>
                  last square {coord(latest)} · {timeAgo(latest.at)}
                </div>}
              </>
            ) : <div className="text-sm" style={{ color: C.sub }}>{countries.length ? 'Waiting for the next search (paced to stay inside Google’s free limit).' : 'Starts when the engine on the Mac Mini is updated.'}</div>}
          </div>

          <div className="rounded-xl p-3 space-y-3" style={{ background: C.soft, border: `1px solid ${C.line}` }}>
            <div className="flex flex-wrap justify-between items-baseline gap-x-2">
              <Label>Google free limit this month</Label>
              <div className="text-[11px]" style={{ color: C.sub }}>stops before it costs anything</div>
            </div>
            {Object.entries(d?.quota?.skus || {}).map(([k, v]) => {
              const [label, hint] = SKU_LABEL[k] || [k, ''];
              const pct = v.cap ? v.used / v.cap : 0;
              return (
                <div key={k}>
                  <div className="flex justify-between gap-2 text-xs mb-1">
                    <span className="min-w-0"><b className="font-semibold">{label}</b> <span style={{ color: C.sub }}>· {hint}</span></span>
                    <span className="tnum shrink-0" style={{ color: C.sub, fontFamily: MONO }}>{v.used.toLocaleString()} / {v.cap.toLocaleString()}</span>
                  </div>
                  <Bar value={v.used} max={v.cap} color={pct > 0.9 ? '#FF3B30' : pct > 0.7 ? '#FF9500' : '#32ADE6'} />
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <div className="grid gap-4 px-4 sm:px-5 pb-5 lg:grid-cols-2">
        <div className="rounded-xl p-3 min-w-0" style={{ background: C.soft, border: `1px solid ${C.line}` }}>
          <div className="mb-2"><Label>Live feed</Label></div>
          {recent.length === 0 ? <div className="text-sm py-4 text-center" style={{ color: C.faint }}>No finds yet.</div> : (
            <ul className="space-y-1.5 max-h-80 overflow-y-auto pr-1">
              {recent.slice(0, 30).map((r) => {
                const [el, ec, eb] = ELIG[r.eligibility] || ELIG.unknown;
                return (
                  <li key={r.org_id} className="flex items-center gap-2 text-sm rounded-lg px-2 py-1.5" style={{ background: C.card, border: `1px solid ${C.line}` }}>
                    <span className="shrink-0 text-[10px] font-bold px-1.5 py-0.5 rounded"
                      style={{ background: r.is_new ? 'rgba(52,199,89,0.16)' : 'rgba(118,118,128,0.12)', color: r.is_new ? '#248A3D' : 'rgba(0,0,0,0.6)' }}>{r.is_new ? 'NEW' : 'SEEN'}</span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate font-medium">{r.name}</span>
                      <span className="block text-xs" style={{ color: C.sub }}>{countryName(r.country)} · {timeAgo(r.at)}</span>
                    </span>
                    <span className="shrink-0 text-[11px] px-1.5 py-0.5 rounded" style={{ color: ec, background: eb }}>{el}</span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className="rounded-xl p-3 min-w-0" style={{ background: C.soft, border: `1px solid ${C.line}` }}>
          <div className="flex justify-between items-center mb-2">
            <Label>Countries</Label>
            {countries.length > 10 && <button className="text-xs font-semibold min-h-[32px] px-1" style={{ color: C.accent }} onClick={() => setAllCountries((v) => !v)}>
              {allCountries ? 'Show fewer' : `Show all ${countries.length}`}</button>}
          </div>
          {countries.length === 0 ? <div className="text-sm py-4 text-center" style={{ color: C.faint }}>The country list appears once the search starts.</div> : (
            <ul className="space-y-2 max-h-80 overflow-y-auto pr-1">
              {shown.map((c) => (
                <li key={c.country} className="text-sm">
                  <div className="flex justify-between gap-2">
                    <span className="truncate"><span className="text-xs mr-1.5" style={{ color: C.faint, fontFamily: MONO }}>{String(c.priority).padStart(3, '0')}</span>{countryName(c.country)}</span>
                    <span className="shrink-0 text-xs" style={{ color: c.state === 'done' ? '#248A3D' : c.state === 'scanning' ? C.scan : C.faint }}>
                      {c.state === 'done' ? `done · ${c.schools_found.toLocaleString()} schools` : c.state === 'scanning' ? `${c.schools_found.toLocaleString()} schools so far` : 'waiting'}
                    </span>
                  </div>
                  {c.state !== 'queued' && <div className="mt-1"><Bar value={c.squares_done} max={c.squares_total} color={c.state === 'done' ? '#34C759' : C.scan} /></div>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}
