// Meta Ads > Funnel > Website signals (migration 108): Search Console and GA4 read through their official APIs, summed
// into rows the CRM stores (no visitor-level data exists in either API). Pure helpers for the ads-sync job site_signals.
//  * Search Console: searchAnalytics.query, dimensions query / page; data lags ~2-3 days, so windows end 3 days ago.
//    Rare queries are anonymised by Google and never appear.
//  * GA4 Data API: properties/{id}:runReport with sessions, engagedSessions, activeUsers, keyEvents, eventCount.

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export interface SiteRow { src: "gsc" | "ga"; kind: string; k1: string; k2: string; win: "cur" | "prev"; m: Record<string, number> }

const iso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (d: string, n: number) => iso(new Date(Date.parse(`${d}T00:00:00Z`) + n * 86400e3));

// Two back-to-back 28-day windows; Search Console ends 3 days before today (its data lag), GA4 ends yesterday.
export function windows(today: string, lagDays: number) {
  const curEnd = addDays(today, -lagDays), curStart = addDays(curEnd, -27);
  const prevEnd = addDays(curStart, -1), prevStart = addDays(prevEnd, -27);
  return { cur: [curStart, curEnd] as const, prev: [prevStart, prevEnd] as const };
}

export function gscBody(dim: "query" | "page", start: string, end: string, rowLimit: number) {
  return { startDate: start, endDate: end, dimensions: [dim], type: "web", rowLimit, dataState: "final" };
}
export function parseGsc(b: any, kind: "query" | "page", win: "cur" | "prev"): SiteRow[] {
  return (Array.isArray(b?.rows) ? b.rows : []).map((r: any) => ({
    src: "gsc" as const, kind, k1: String(r.keys?.[0] ?? "").slice(0, 300), k2: "", win,
    m: { clicks: Number(r.clicks) || 0, impressions: Number(r.impressions) || 0, ctr: Number(r.ctr) || 0, position: Number(r.position) || 0 },
  })).filter((r: SiteRow) => r.k1);
}

// The GA4 reports: what each dimension is used for, and its metrics.
export const GA_REPORTS: { kind: string; dims: string[]; metrics: string[]; limit: number }[] = [
  { kind: "landing", dims: ["landingPage"], metrics: ["sessions", "engagedSessions", "keyEvents"], limit: 200 },
  { kind: "channel", dims: ["sessionDefaultChannelGroup"], metrics: ["sessions", "engagedSessions", "keyEvents"], limit: 30 },
  { kind: "source", dims: ["sessionSourceMedium"], metrics: ["sessions", "keyEvents"], limit: 50 },
  { kind: "city", dims: ["city", "region"], metrics: ["activeUsers", "sessions", "keyEvents"], limit: 100 },
  { kind: "event", dims: ["eventName"], metrics: ["eventCount", "activeUsers"], limit: 60 },
];
export function gaBody(r: { dims: string[]; metrics: string[]; limit: number }, start: string, end: string) {
  return { dateRanges: [{ startDate: start, endDate: end }], dimensions: r.dims.map((name) => ({ name })),
    metrics: r.metrics.map((name) => ({ name })), limit: String(r.limit), orderBys: [{ metric: { metricName: r.metrics[0] }, desc: true }] };
}
export function parseGa(b: any, kind: string, win: "cur" | "prev"): SiteRow[] {
  const mh: string[] = (b?.metricHeaders ?? []).map((h: any) => String(h.name));
  return (Array.isArray(b?.rows) ? b.rows : []).map((r: any) => {
    const m: Record<string, number> = {};
    mh.forEach((n, i) => { m[n] = Number(r.metricValues?.[i]?.value) || 0; });
    return { src: "ga" as const, kind, k1: String(r.dimensionValues?.[0]?.value ?? "").slice(0, 300), k2: String(r.dimensionValues?.[1]?.value ?? "").slice(0, 120), win, m };
  }).filter((r: SiteRow) => r.k1 && r.k1 !== "(not set)");
}

// A Search Console property is either "sc-domain:example.com" or a URL prefix ending in "/".
export function gscSite(v: string): string | null {
  const s = String(v ?? "").trim();
  if (/^sc-domain:[a-z0-9.-]+\.[a-z]{2,}$/i.test(s)) return s.toLowerCase();
  if (/^https?:\/\/[a-z0-9.-]+\.[a-z]{2,}(\/.*)?$/i.test(s)) return s.endsWith("/") ? s : `${s}/`;
  return null;
}

export async function googleToken(f: Fetch, clientId: string, clientSecret: string, refreshToken: string): Promise<string> {
  const r = await f("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken }).toString() });
  const b = await r.json().catch(() => ({}));
  if (!r.ok || !b.access_token) throw new Error(`Google sign-in failed: ${b.error ?? r.status} ${b.error_description ?? ""}`.trim());
  return String(b.access_token);
}

export function siteError(api: "Search Console" | "GA4", status: number, b: any): string {
  const msg = String(b?.error?.message ?? b?.error ?? status);
  if (status === 403 && /scope|insufficient/i.test(msg)) return `${api}: the Google sign-in lacks the read scope (re-create the refresh token with webmasters.readonly and analytics.readonly).`;
  if (status === 403) return `${api}: this Google user has no access to the property (add it as a user with read access). ${msg}`.slice(0, 300);
  if (status === 404) return `${api}: property not found; check the ${api === "GA4" ? "GA4 property ID (digits only)" : "Search Console site (sc-domain:... or https://.../)"}.`;
  return `${api}: ${msg}`.slice(0, 300);
}
