// Shared helpers for the Supabase route modules: Render-style responses and RPC calls.
import { supabase, AUTH_FUNCTION_URL, SUPABASE_PUBLISHABLE_KEY } from './supabaseClient';

export const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
export const detail = (status, message) => json(status, { detail: message });

// Postgres rolls a transaction back completely on these, so trying again is always safe:
// deadlock_detected, serialization_failure, lock_not_available.
const TRANSIENT = new Set(['40P01', '40001', '55P03']);
const pause = (ms) => new Promise((ok) => setTimeout(ok, ms));

// Call a Postgres API function. Errors raised as SQLSTATE PTnnn become HTTP status nnn.
export async function call(fn, args = {}) {
  let res = await supabase.rpc(fn, args);
  for (let i = 0; res.error && TRANSIENT.has(res.error.code) && i < 3; i++) {
    await pause(250 * 3 ** i + Math.random() * 200);       // 0.25 s, 0.75 s, 2.25 s
    res = await supabase.rpc(fn, args);
  }
  const { data, error, status } = res;
  if (!error) return { data };
  if (TRANSIENT.has(error.code)) return { error: detail(503, 'The database was busy for a moment. Please try again.') };
  const code = /^PT(\d{3})$/.exec(error.code || '');
  const httpStatus = code ? Number(code[1]) : (status && status >= 400 ? status : 500);
  if (httpStatus === 401 || /JWT|not authenticated/i.test(error.message || '')) {
    return { error: detail(401, 'Could not validate credentials') };
  }
  return { error: detail(httpStatus, error.message || 'Request failed') };
}

export const rpc = async (fn, args) => {
  const r = await call(fn, args);
  return r.error || json(200, r.data);
};

// The crm-auth Edge Function, called with the signed-in user's token.
export async function authFunction(payload) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(AUTH_FUNCTION_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_PUBLISHABLE_KEY,
      Authorization: `Bearer ${data.session?.access_token || ''}`,
    },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body };
}

export const UUID = '([0-9a-f-]{36})';
