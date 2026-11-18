// Connection health for the signal indicator at the top of the CRM.
// Two separate questions, because they have different fixes:
//   1. Is THIS device's internet working?          (browser online state + a tiny Google probe)
//   2. Is the CRM server answering, and how fast?  (every real request is timed, plus a light health ping)
// Nothing here blocks or slows a request: timings are recorded after the fact.

const SAMPLE_MAX = 12;          // rolling window of recent CRM requests
const PING_EVERY_MS = 30000;    // only while the tab is visible and nothing else has talked to the server
const SLOW_MS = 1200;           // median above this = "Slow"
const VERY_SLOW_MS = 3500;      // median above this = "Very slow"

const state = {
  online: typeof navigator === 'undefined' ? true : navigator.onLine !== false,
  samples: [],                  // { ms, ok, at }
  lastOkAt: 0,
  lastFailAt: 0,
  failStreak: 0,
  inFlight: 0,
  internet: 'unknown',          // 'ok' | 'down' | 'unknown' (only probed when the CRM stops answering)
  lastSyncAt: 0,
};
const listeners = new Set();
let snapshot = null;

function emit() { snapshot = null; listeners.forEach((fn) => { try { fn(); } catch { /* ignore */ } }); }

export function subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); }

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
};

// Pure: turns raw facts into what the user sees. Exported for tests.
export function classify({ online, samples, failStreak, internet, effectiveType }) {
  const okMs = samples.filter((s) => s.ok).map((s) => s.ms);
  const ms = median(okMs);
  if (!online || internet === 'down') {
    return { level: 0, tone: 'bad', label: 'Offline', detail: 'Your internet is down. The CRM keeps showing saved data and catches up when you are back online.', ms };
  }
  if (failStreak >= 2) {
    return { level: 0, tone: 'bad', label: 'CRM not responding', detail: internet === 'ok'
      ? 'Your internet works, but the CRM server is not answering. Retrying automatically.'
      : 'The CRM server is not answering. Checking your internet and retrying automatically.', ms };
  }
  const weak = effectiveType === 'slow-2g' || effectiveType === '2g';
  if (ms == null) return { level: 3, tone: 'good', label: 'Connected', detail: 'Connected.', ms };
  if (ms > VERY_SLOW_MS || weak) {
    return { level: 1, tone: 'warn', label: weak ? 'Weak internet' : 'Very slow', detail: weak
      ? 'Your internet connection is weak. Pages may take longer to load.'
      : `The CRM is answering slowly (about ${(ms / 1000).toFixed(1)} s). Your internet may be busy.`, ms };
  }
  if (ms > SLOW_MS || failStreak === 1) {
    return { level: 2, tone: 'warn', label: 'Slow', detail: `The CRM is answering in about ${(ms / 1000).toFixed(1)} s.`, ms };
  }
  return { level: 3, tone: 'good', label: 'Fast', detail: `The CRM is answering in about ${ms} ms.`, ms };
}

export function getStatus() {
  if (snapshot) return snapshot;
  const conn = typeof navigator !== 'undefined' ? navigator.connection : null;
  const c = classify({ ...state, effectiveType: conn?.effectiveType });
  snapshot = {
    ...c,
    online: state.online,
    internet: state.internet,
    downlink: conn?.downlink ?? null,           // Mbps estimate (Chrome/Edge/Android only)
    effectiveType: conn?.effectiveType ?? null,
    inFlight: state.inFlight,
    lastOkAt: state.lastOkAt,
    lastSyncAt: state.lastSyncAt,
  };
  return snapshot;
}

export function requestStarted() { state.inFlight += 1; emit(); }

// kind: 'api' (database/auth: timed) or 'job' (long-running functions: success/failure only).
export function requestEnded({ ms, ok, kind = 'api' }) {
  state.inFlight = Math.max(0, state.inFlight - 1);
  if (ok) {
    state.lastOkAt = Date.now(); state.failStreak = 0; state.internet = 'ok';
    if (kind === 'api') state.samples = [...state.samples, { ms, ok: true, at: Date.now() }].slice(-SAMPLE_MAX);
  } else {
    state.lastFailAt = Date.now(); state.failStreak += 1;
    if (state.failStreak >= 2) probeInternet();
  }
  emit();
}

export function markSynced() { state.lastSyncAt = Date.now(); emit(); }

let probing = false;
async function probeInternet() {
  if (probing || typeof fetch === 'undefined') return;
  probing = true;
  try {
    // Opaque request to a tiny Google endpoint: success means the internet works, whatever the CRM is doing.
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 5000);
    await fetch('https://www.gstatic.com/generate_204', { mode: 'no-cors', cache: 'no-store', signal: ctl.signal });
    clearTimeout(t);
    state.internet = 'ok';
  } catch {
    state.internet = 'down';
  } finally {
    probing = false;
    emit();
  }
}

let pinger = null;
let doPing = null;
// "Check again" in the signal pop-over: always pings, even if a request just finished.
export function checkNow() { state.lastOkAt = 0; state.internet = 'unknown'; emit(); return doPing ? doPing() : Promise.resolve(); }
export function startMonitoring({ url, apikey, fetchImpl }) {
  if (typeof window === 'undefined' || pinger) return () => {};
  const setOnline = (v) => () => { state.online = v; if (v) { state.internet = 'unknown'; state.failStreak = 0; } emit(); if (v) ping(); };
  const on = setOnline(true), off = setOnline(false);
  window.addEventListener('online', on);
  window.addEventListener('offline', off);
  const conn = navigator.connection;
  const onConn = () => emit();
  conn?.addEventListener?.('change', onConn);

  async function ping() {
    if (!url || document.visibilityState !== 'visible' || !state.online) return;
    if (Date.now() - state.lastOkAt < PING_EVERY_MS / 2 && state.samples.length) return;   // real traffic already tells us
    const started = performance.now();
    requestStarted();
    try {
      const res = await fetchImpl(`${url}/auth/v1/health`, { headers: { apikey }, cache: 'no-store' });
      requestEnded({ ms: Math.round(performance.now() - started), ok: res.ok || res.status < 500 });
    } catch {
      requestEnded({ ms: Math.round(performance.now() - started), ok: false });
    }
  }
  doPing = ping;
  const onVis = () => { if (document.visibilityState === 'visible') ping(); };
  document.addEventListener('visibilitychange', onVis);
  pinger = setInterval(ping, PING_EVERY_MS);
  ping();
  return () => {
    clearInterval(pinger); pinger = null;
    window.removeEventListener('online', on); window.removeEventListener('offline', off);
    conn?.removeEventListener?.('change', onConn);
    document.removeEventListener('visibilitychange', onVis);
  };
}

// Test hook: reset between cases.
export function _reset() {
  Object.assign(state, { online: true, samples: [], lastOkAt: 0, lastFailAt: 0, failStreak: 0, inFlight: 0, internet: 'unknown', lastSyncAt: 0 });
  emit();
}
