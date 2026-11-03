import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';
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
ReactDOM.createRoot(document.getElementById('root')).render(
  <App />
);
