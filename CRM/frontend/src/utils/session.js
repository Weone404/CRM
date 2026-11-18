// Renew the sign-in once before treating a 401 as "signed out". After a laptop wakes up or Wi-Fi switches,
// the session has often just expired and renews fine; signing people out then was the wrong answer.
// Returns 'ok' (renewed), 'offline' (could not reach the server: keep the person signed in) or 'none' (really signed out).
// One shared renewal at a time, so ten screens failing together trigger one refresh, not ten.
let renewing = null;
export function renewSession(supabase, refreshToken) {
  if (!supabase) return Promise.resolve('none');
  renewing = renewing || (refreshToken ? supabase.auth.refreshSession({ refresh_token: refreshToken }) : supabase.auth.refreshSession())
    .then(({ data, error }) => {
      if (data?.session) return 'ok';
      const networkish = error && (error.name === 'AuthRetryableFetchError' || !error.status || error.status >= 500);
      return networkish ? 'offline' : 'none';
    })
    .catch(() => 'offline')
    .finally(() => { setTimeout(() => { renewing = null; }, 2000); });
  return renewing;
}
export function _resetRenew() { renewing = null; }
