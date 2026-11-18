import { createClient } from '@supabase/supabase-js';
import { requestStarted, requestEnded, startMonitoring } from '../utils/netStatus';

// Public values only: the project URL and the publishable (anon) key are meant to
// ship in the browser. Every table is protected by Row Level Security.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
export const SUPABASE_PUBLISHABLE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

// Every request to the CRM server goes through here:
//  - a hard time limit, so a dropped connection ends in a clear error instead of a screen that spins forever
//    (database and sign-in calls: 25 s; long jobs in Edge Functions: 150 s, their own platform limit);
//  - a caller's own cancel signal still works;
//  - the time each request took feeds the signal indicator at the top of the CRM.
export const LIMITS = { db: 25000, job: 150000 };    // exported so tests can shorten them
const networkFetch = (...a) => globalThis.fetch(...a);

export function timedFetch(input, init = {}) {
  const url = typeof input === 'string' ? input : input?.url || '';
  const isJob = url.includes('/functions/v1/');
  const ctl = new AbortController();
  const limit = setTimeout(() => ctl.abort(new DOMException('The CRM server took too long to answer.', 'TimeoutError')), isJob ? LIMITS.job : LIMITS.db);
  const outer = init.signal;
  const forward = () => ctl.abort(outer.reason);
  if (outer) { if (outer.aborted) forward(); else outer.addEventListener('abort', forward, { once: true }); }
  const started = typeof performance !== 'undefined' ? performance.now() : Date.now();
  requestStarted();
  return networkFetch(input, { ...init, signal: ctl.signal }).then(
    (res) => {
      const ms = Math.round((typeof performance !== 'undefined' ? performance.now() : Date.now()) - started);
      requestEnded({ ms, ok: res.status < 500, kind: isJob ? 'job' : 'api' });
      return res;
    },
    (err) => {
      const ms = Math.round((typeof performance !== 'undefined' ? performance.now() : Date.now()) - started);
      // Cancelled by the screen itself (user left the page): not a connection problem.
      const userCancelled = outer?.aborted;
      requestEnded({ ms, ok: userCancelled, kind: 'job' });
      throw err;
    },
  ).finally(() => {
    clearTimeout(limit);
    if (outer) outer.removeEventListener('abort', forward);
  });
}

export const supabase = SUPABASE_URL && SUPABASE_PUBLISHABLE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, storageKey: 'weone-crm-auth' },
      global: { fetch: timedFetch },
    })
  : null;

if (supabase && typeof window !== 'undefined') {
  startMonitoring({ url: SUPABASE_URL, apikey: SUPABASE_PUBLISHABLE_KEY, fetchImpl: networkFetch });
}

export const AUTH_FUNCTION_URL = SUPABASE_URL ? `${SUPABASE_URL}/functions/v1/crm-auth` : '';
