import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';
import './components/ui/apple.css';
import { installModalKeys } from './components/ui/overlay';
import { API_URL } from './api';

// Auto-logout when the saved EMPLOYEE token is rejected (expired, or signed with
// an old SECRET_KEY). Without this the app kept the dead token and showed
// "Couldn't load leads (HTTP 401)" on every page until the user clicked Logout.
// Only acts when ALL of these hold, so nothing else changes:
//   - the request went to the CRM backend (API_URL),
//   - it carried exactly the employee token from localStorage,
//   - the backend answered 401 "Could not validate credentials" (the auth
//     check itself; other 401s such as "Current password is incorrect" on
//     change-password are left alone).
// Login, the student portal (student_token) and public calls are untouched.
// The original response is always returned.
import { USE_SUPABASE } from './backend/mode';
import { handleApiRequest, isRenderPassthrough, signOutSupabase, withSupabaseAuth } from './backend/router';

// Supabase backend: every `${API_URL}/api/...` call is answered by backend/router.js
// (same status codes and JSON shapes as the Render API), so no screen had to change.
if (USE_SUPABASE && !window.__crmSupabaseInterceptor) {
  window.__crmSupabaseInterceptor = true;
  const networkFetch = window.fetch.bind(window);
  window.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input?.url || '';
    if (!url.startsWith(API_URL + '/api/')) return networkFetch(input, init);
    const parsed = new URL(url);
    if (isRenderPassthrough(parsed.pathname)) return networkFetch(url, await withSupabaseAuth(init));
    const method = (init.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
    return handleApiRequest(method, parsed.pathname, parsed.searchParams, init.body);
  };
}

const AUTH_FAILED_DETAIL = 'Could not validate credentials';

function requestUrl(input) {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.href;
  return input?.url || '';
}

function requestAuthHeader(input, init) {
  const fromInit = init?.headers;
  if (fromInit) {
    if (fromInit instanceof Headers) return fromInit.get('Authorization');
    if (Array.isArray(fromInit)) {
      const pair = fromInit.find(([k]) => String(k).toLowerCase() === 'authorization');
      return pair ? pair[1] : null;
    }
    const key = Object.keys(fromInit).find((k) => k.toLowerCase() === 'authorization');
    if (key) return fromInit[key];
  }
  if (input instanceof Request) return input.headers.get('Authorization');
  return null;
}

if (!window.__crmFetchWrapped) {
  window.__crmFetchWrapped = true;
  const originalFetch = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await originalFetch(input, init);
    try {
      if (response.status === 401 && requestUrl(input).startsWith(API_URL)) {
        const token = localStorage.getItem('token');
        if (token && requestAuthHeader(input, init) === `Bearer ${token}`) {
          const body = await response.clone().json().catch(() => null);
          if (body?.detail === AUTH_FAILED_DETAIL) {
            if (USE_SUPABASE) signOutSupabase();
            localStorage.removeItem('token');
            localStorage.removeItem('employee');
            window.location.replace('/');
          }
        }
      }
    } catch {
      /* never let the logout check break the original request */
    }
    return response;
  };
}

// NOTE: React.StrictMode intentionally double-invokes effects/mounts in dev,
// which made every data-fetching useEffect fire TWICE (duplicate GET /api/leads,
// GET /api/followups/pending, etc. seen in the backend logs). Rendering without
// it so each page load issues each request exactly once.
installModalKeys();
ReactDOM.createRoot(document.getElementById('root')).render(
  <App />
);
