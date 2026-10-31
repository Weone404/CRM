/**
 * CRM failover front door (Cloudflare Worker).
 *
 * One stable URL in front of several identical CRM backends (Render, Koyeb,
 * Railway). Every backend shares the same Supabase database, so any of them can
 * serve any request.
 *
 * Routing rules
 * - BACKENDS (env var) = comma-separated base URLs, highest priority first.
 * - Health state is kept per isolate with a 30 s TTL. A backend is used only if
 *   GET /health answers 2xx within 3 s (result cached 30 s).
 * - GET / HEAD / OPTIONS: 15 s timeout; on network error, timeout or 502/503/504
 *   the backend is marked down and the next one is tried.
 * - Every other method (POST, PUT, PATCH, DELETE): falls back ONLY on network
 *   error or 502/503/504 (the request never reached the app). It never falls
 *   back on a timeout, because the first backend may already have saved the
 *   lead/record and a retry elsewhere would create a duplicate.
 * - Last resort: if every backend failed its health check, the request is sent
 *   to the first backend anyway, so a cold start (e.g. Render waking from sleep)
 *   still completes instead of being rejected.
 * - The backend's response is returned unchanged, plus `x-crm-backend`.
 * - If every backend fails: 503 JSON.
 */

const HEALTH_TTL_MS = 30_000;
const HEALTH_TIMEOUT_MS = 3_000;
const IDEMPOTENT_TIMEOUT_MS = 15_000;
const WRITE_TIMEOUT_MS = 90_000;
const IDEMPOTENT = new Set(["GET", "HEAD", "OPTIONS"]);
const RETRYABLE_STATUS = new Set([502, 503, 504]);

// Per-isolate health cache: base URL -> { ok, until }
const health = new Map();

function parseBackends(env) {
  return String(env.BACKENDS || "")
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter(Boolean);
}

function setHealth(base, ok) {
  health.set(base, { ok, until: Date.now() + HEALTH_TTL_MS });
}

function cachedHealth(base) {
  const h = health.get(base);
  return h && h.until > Date.now() ? h.ok : undefined;
}

async function isHealthy(base) {
  const cached = cachedHealth(base);
  if (cached !== undefined) return cached;
  let ok = false;
  try {
    const r = await fetch(`${base}/health`, {
      method: "GET",
      signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS),
      redirect: "manual",
    });
    ok = r.ok;
    // Drain so the connection can be reused.
    await r.body?.cancel();
  } catch {
    ok = false;
  }
  setHealth(base, ok);
  return ok;
}

function isTimeout(err) {
  return err && (err.name === "TimeoutError" || err.name === "AbortError");
}

function json(status, body, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

function withBackendHeader(resp, base) {
  const out = new Response(resp.body, resp);
  out.headers.set("x-crm-backend", base);
  return out;
}

/**
 * Send the request to one backend.
 * Returns { response } on a usable answer, { retry: true } when the next backend
 * should be tried, or { response, final: true } when we must stop (write timeout).
 */
async function tryBackend(base, request, url, body, idempotent) {
  const target = `${base}${url.pathname}${url.search}`;
  const headers = new Headers(request.headers);
  headers.delete("host");
  try {
    const resp = await fetch(target, {
      method: request.method,
      headers,
      body,
      redirect: "manual",
      signal: AbortSignal.timeout(idempotent ? IDEMPOTENT_TIMEOUT_MS : WRITE_TIMEOUT_MS),
    });
    if (RETRYABLE_STATUS.has(resp.status)) {
      await resp.body?.cancel();
      setHealth(base, false);
      return { retry: true };
    }
    return { response: withBackendHeader(resp, base) };
  } catch (err) {
    if (isTimeout(err) && !idempotent) {
      // The backend may already have committed this write: never replay it.
      return {
        final: true,
        response: json(504, { error: "Backend timed out; request was not retried", backend: base }, { "x-crm-backend": base }),
      };
    }
    setHealth(base, false);
    return { retry: true };
  }
}

export default {
  async fetch(request, env) {
    const backends = parseBackends(env);
    if (backends.length === 0) {
      return json(500, { error: "BACKENDS is not configured on the failover Worker" });
    }

    const url = new URL(request.url);
    const method = request.method.toUpperCase();
    const idempotent = IDEMPOTENT.has(method);
    // Buffer the body once so it can be replayed to the next backend.
    const body = method === "GET" || method === "HEAD" ? undefined : await request.arrayBuffer();

    const tried = new Set();
    for (const base of backends) {
      if (!(await isHealthy(base))) continue;
      tried.add(base);
      const result = await tryBackend(base, request, url, body, idempotent);
      if (result.response) return result.response;
    }

    // Last resort: nothing passed its health check (e.g. every free instance is
    // asleep). Send the request to the first backend not already tried, and let
    // it finish its cold start.
    const fallback = backends.find((b) => !tried.has(b));
    if (fallback) {
      const result = await tryBackend(fallback, request, url, body, idempotent);
      if (result.response) return result.response;
    }

    return json(503, { error: "All CRM backends are unavailable", backends });
  },
};
