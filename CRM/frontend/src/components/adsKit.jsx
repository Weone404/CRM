// Shared plumbing for CRM > ADS screens: reliable server calls and buttons that cannot be pressed twice.
//
//  rpc()      every call has a time limit and a plain-language error (slow server, no internet, session expired).
//  useLoad()  keeps showing the last good data while it refreshes, ignores answers that arrive out of order,
//             and refreshes when the person comes back to the tab.
//  Btn        when its onClick returns a promise, the button shows a spinner and stays disabled until it settles,
//             so a second tap does nothing. Buttons that share a `scope` are all disabled while one of them works
//             (e.g. Accept / Change / Dismiss on the same suggestion).
//  WorkingBar a thin bar at the top while anything is being saved; OfflineBar when the internet drops.
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { supabase } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';

// ---------------------------------------------------------------- errors in plain words
export function friendly(e) {
  const m = String(e?.message || e || '');
  if (e?.name === 'AbortError' || /aborted|timed out/i.test(m)) return 'The server is taking too long. Check your internet and try again.';
  if (/Failed to fetch|NetworkError|Load failed|network/i.test(m)) return 'No internet connection, or the server could not be reached. Try again.';
  if (/JWT|session|not authenticated|401/i.test(m)) return 'Your session has expired. Sign in again.';
  return m || 'Something went wrong. Try again.';
}

export async function rpc(fn, args, { timeout = 25000 } = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const { data, error } = await supabase.rpc(fn, args).abortSignal(ctrl.signal);
    if (error) throw Object.assign(new Error(friendly(error)), { code: error.code });
    return data;
  } catch (e) {
    throw e instanceof Error && e.code ? e : new Error(friendly(e));
  } finally { clearTimeout(t); }
}

export const run = async (p, okMsg) => {
  try { const r = await p; if (okMsg) showToast(okMsg, 'success'); return r ?? true; }
  catch (e) { showToast(friendly(e), 'error'); return undefined; }
};

// ---------------------------------------------------------------- loading
export function useLoad(fn, deps = [], { refreshMs = 0, onFocus = true } = {}) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const seq = useRef(0);
  const last = useRef(0);
  const load = useCallback(async () => {
    const my = ++seq.current;
    setLoading(true);
    try {
      const d = await fn();
      if (my === seq.current) { setData(d); setError(''); last.current = Date.now(); }
    } catch (e) {
      if (my === seq.current) setError(friendly(e));   // keep the last good data on screen
    } finally { if (my === seq.current) setLoading(false); }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!refreshMs) return undefined;
    const t = setInterval(() => { if (document.visibilityState === 'visible') load(); }, refreshMs);
    return () => clearInterval(t);
  }, [load, refreshMs]);
  useEffect(() => {
    if (!onFocus) return undefined;
    const f = () => { if (document.visibilityState === 'visible' && Date.now() - last.current > 30000) load(); };
    document.addEventListener('visibilitychange', f);
    window.addEventListener('online', load);
    return () => { document.removeEventListener('visibilitychange', f); window.removeEventListener('online', load); };
  }, [load, onFocus]);
  return [data, load, error, loading];
}

// ---------------------------------------------------------------- busy store (what is being saved right now)
const busy = new Map();       // scope -> count ('*' = everything)
const subs = new Set();
const emit = () => subs.forEach((f) => f());
const subscribe = (f) => { subs.add(f); return () => subs.delete(f); };
export function begin(scope) { for (const s of ['*', scope].filter(Boolean)) busy.set(s, (busy.get(s) || 0) + 1); emit(); }
export function end(scope) { for (const s of ['*', scope].filter(Boolean)) busy.set(s, Math.max(0, (busy.get(s) || 0) - 1)); emit(); }
export const useBusy = (scope) => useSyncExternalStore(subscribe, () => (busy.get(scope) || 0) > 0);

// Runs one action at a time per scope; a second call while the first runs is ignored.
export async function once(scope, fn) {
  if ((busy.get(scope) || 0) > 0) return undefined;
  begin(scope);
  try { return await fn(); } finally { end(scope); }
}

export function Spinner({ size = 14 }) {
  return <span aria-hidden className="inline-block rounded-full animate-spin" style={{ width: size, height: size, border: '2px solid currentColor', borderRightColor: 'transparent' }} />;
}

export function Btn({ tone = '#007AFF', ghost, className = '', onClick, scope, busyText, disabled, children, ...p }) {
  const [mine, setMine] = useState(false);
  const scopeBusy = useBusy(scope || '__none__');
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);
  const handle = async (e) => {
    if (mine || scopeBusy || !onClick) return;
    const r = onClick(e);
    if (!r || typeof r.then !== 'function') return;
    setMine(true); begin(scope);
    try { await r; } catch (err) { showToast(friendly(err), 'error'); }
    finally { end(scope); if (alive.current) setMine(false); }
  };
  const off = disabled || mine || (scope && scopeBusy);
  return (
    <button type="button" {...p} onClick={handle} disabled={off} aria-busy={mine || undefined}
      className={`px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center justify-center gap-1.5 disabled:opacity-40 transition-opacity ${className}`}
      style={ghost ? { background: 'rgba(118,118,128,0.12)', color: '#1C1C1E' } : { background: tone, color: '#fff' }}>
      {mine ? <><Spinner />{busyText || children}</> : children}
    </button>
  );
}

export function WorkingBar() {
  const any = useBusy('*');
  if (!any) return null;
  return (
    <div role="status" aria-live="polite" className="fixed top-0 left-0 right-0 z-50 h-1 overflow-hidden" data-testid="working-bar">
      <div className="h-full w-1/3 animate-[adsbar_1.1s_ease-in-out_infinite]" style={{ background: '#007AFF' }} />
      <style>{'@keyframes adsbar{0%{transform:translateX(-100%)}100%{transform:translateX(300%)}}'}</style>
      <span className="sr-only">Saving…</span>
    </div>
  );
}

export function OfflineBar() {
  const [on, setOn] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);
  useEffect(() => {
    const a = () => setOn(true), b = () => setOn(false);
    window.addEventListener('online', a); window.addEventListener('offline', b);
    return () => { window.removeEventListener('online', a); window.removeEventListener('offline', b); };
  }, []);
  if (on) return null;
  return <div role="alert" className="glass-card p-3 text-sm font-semibold" style={{ color: '#B25E00' }}>You are offline. Nothing can be saved until the internet is back; this page refreshes by itself when it is.</div>;
}
