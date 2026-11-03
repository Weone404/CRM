export const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:8000';

// Shared fetch helper: attaches the bearer token and a hard timeout so a
// cold-starting backend can't leave a request hanging forever (which is what
// made the UI feel "stuck" and forced hard refreshes).
export async function apiFetch(path, { token, timeout = 20000, ...opts } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const res = await fetch(`${API_URL}${path}`, {
      ...opts,
      signal: controller.signal,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(opts.headers || {}),
      },
    });
    return res;
  } finally {
    clearTimeout(timer);
  }
}

export async function login(login_id, password) {
  const res = await fetch(`${API_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ login_id, password })
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.detail || 'Login failed');
  }
  return res.json();
}

// Lightweight config load — replaces polling the heavy /api/sync snapshot.
export async function fetchConfig(token) {
  const res = await apiFetch('/api/config', { token });
  if (!res.ok) throw new Error(`Config load failed (HTTP ${res.status})`);
  return res.json();
}
