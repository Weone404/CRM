// Google My Business collector logic (139), kept free of Deno/Supabase so it can be tested with a fake Google and a fake database.
//   discover  one Google login: does it still sign in, does Google let this project read Business Profile, which profiles it manages
//   sync      its tracked profiles: daily numbers, the words people searched (month by month) and the reviews
// A login's state is always saved in plain words: connected, waiting for Google's approval (quota 0), sign in again, API off, no access.
import { accountsUrl, addDays, gbpError, keywordsUrl, locationsUrl, metricsUrl, monthsBack, parseAccounts, parseKeywords, parseLocations,
  parseMetrics, parseReviews, reviewsUrl, type GbpState, type LocRow } from "./gbp.ts";

export type Loc = { id: string; account: string; name: string; first: boolean; reviews_stored: number; keyword_months: string[] };
export type Conn = { id: string; label: string; refresh_token: string | null; locations: Loc[] };
export type Work = { client_id: string | null; client_secret: string | null; connections: Conn[] };
export type Deps = {
  fetch: (url: string, init?: RequestInit) => Promise<Response>;
  rpc: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
  today: string;                       // yyyy-mm-dd (UTC)
  expired: () => boolean;              // true once the run should stop starting new work
};

export class GoogleSaid extends Error {
  constructor(public state: GbpState, message: string) { super(message); }
}

async function gget(d: Deps, token: string, api: string, url: string) {
  let res: Response;
  try { res = await d.fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30000) }); }
  catch { throw new GoogleSaid("busy", `${api}: Google did not answer in time. The next run tries again.`); }
  const b = await res.json().catch(() => ({}));
  if (!res.ok) { const e = gbpError(api, res.status, b); throw new GoogleSaid(e.state, e.message); }
  return b;
}

// Only Google saying "this sign-in is no longer valid" asks for a new sign-in; a network hiccup or a Google outage does not.
export async function signIn(d: Deps, w: Work, c: Conn): Promise<string> {
  if (!w.client_id || !w.client_secret) throw new GoogleSaid("needs_signin", "The Google OAuth client is not saved yet (Connections & keys > Google).");
  if (!c.refresh_token) throw new GoogleSaid("needs_signin", "No Google sign-in is saved for this login. Save its refresh token.");
  let res: Response;
  try {
    res = await d.fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", client_id: w.client_id, client_secret: w.client_secret, refresh_token: c.refresh_token }).toString(),
      signal: AbortSignal.timeout(20000) });
  } catch { throw new GoogleSaid("busy", "Google sign-in did not answer in time. The next run tries again."); }
  const b = await res.json().catch(() => ({}));
  if (res.ok && typeof b?.access_token === "string" && b.access_token) return b.access_token;
  const code = String(b?.error ?? "");
  if (code === "invalid_grant") throw new GoogleSaid("needs_signin", "Google no longer accepts this sign-in (expired or revoked). Sign in again and save the new token.");
  if (code === "invalid_client" || code === "unauthorized_client") throw new GoogleSaid("needs_signin", "This token was made with a different Google OAuth client than the one saved in the CRM. Make it again with the CRM's client.");
  if (res.status >= 500 || res.status === 429) throw new GoogleSaid("busy", "Google sign-in is busy. The next run tries again.");
  throw new GoogleSaid("error", `Google sign-in failed (${code || res.status}).`);
}

export async function discover(d: Deps, w: Work, c: Conn): Promise<string> {
  const token = await signIn(d, w, c);
  const rows: LocRow[] = []; const accounts: string[] = []; let who = "", next: string | null = null, pages = 0;
  do {
    const a = parseAccounts(await gget(d, token, "My Business Account Management API", accountsUrl(next)));
    for (const x of a.rows) { accounts.push(x.name); if (!who) who = x.label; }
    next = a.next;
  } while (next && ++pages < 5);
  let cut = false;
  for (const acc of accounts) {
    next = null; pages = 0;
    do {
      if (d.expired()) { cut = true; break; }
      const l = parseLocations(await gget(d, token, "My Business Business Information API", locationsUrl(acc, next)), acc);
      rows.push(...l.rows); next = l.next;
    } while (next && ++pages < 20);
  }
  const n = Number(await d.rpc("svc_gbp_locations_save", { p_connection: c.id, p_rows: rows }));
  await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: "connected", p_error: null, p_email: who });
  return `${c.label}: ${n} profile(s) in ${accounts.length} account(s)` + (cut ? " (time limit reached; the rest next run)" : "");
}

export async function sync(d: Deps, w: Work, c: Conn): Promise<string> {
  if (!c.locations.length) return `${c.label}: no tracked profile`;
  const token = await signIn(d, w, c);
  let days = 0, words = 0, reviews = 0, good = 0; const notes = new Set<string>(); let firstProblem: GoogleSaid | null = null;
  // One part failing for one profile (no access, or that one API switched off) must not stop the other parts or profiles.
  const part = async (fn: () => Promise<void>) => {
    try { await fn(); good++; }
    catch (e) {
      if (e instanceof GoogleSaid && (e.state === "no_access" || e.state === "api_off")) { notes.add(e.message); firstProblem ??= e; return; }
      throw e;
    }
  };
  for (const l of c.locations) {
    if (d.expired()) { notes.add("time limit reached; the rest next run"); break; }
    // Google publishes with a delay of a few days and revises recent days, so the last 5 weeks are always re-read.
    await part(async () => {
      const m = parseMetrics(await gget(d, token, "Business Profile Performance API", metricsUrl(l.name, addDays(d.today, l.first ? -180 : -35), d.today)));
      days += Number(await d.rpc("svc_gbp_metrics_save", { p_location: l.id, p_rows: m }));
    });
    await part(async () => {
      const have = new Set(l.keyword_months ?? []);
      for (const [i, mo] of monthsBack(d.today, 6).entries()) {
        if (i > 0 && have.has(mo.first)) continue;                    // older months do not change; the latest one may
        if (d.expired()) break;
        const rows = []; let next: string | null = null, pages = 0;
        do {
          const k = parseKeywords(await gget(d, token, "Business Profile Performance API", keywordsUrl(l.name, mo.y, mo.m, next)));
          rows.push(...k.rows); next = k.next;
        } while (next && ++pages < 10);
        words += Number(await d.rpc("svc_gbp_keywords_save", { p_location: l.id, p_month: mo.first, p_rows: rows }));
      }
    });
    await part(async () => {
      let next: string | null = null, pages = 0; const max = l.reviews_stored > 0 ? 2 : 20;      // newest first: 2 pages catch every change since last night
      do {
        if (d.expired()) break;
        const r = parseReviews(await gget(d, token, "Google My Business API (reviews)", reviewsUrl(l.account, l.name, next)));
        reviews += Number(await d.rpc("svc_gbp_reviews_save", { p_location: l.id, p_rows: r.rows, p_total: r.total, p_rating: r.rating }));
        next = r.next;
      } while (next && ++pages < max);
    });
  }
  if (!good && firstProblem) throw firstProblem;                       // nothing at all could be read: that is the login's state
  await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: "connected", p_error: notes.size ? [...notes].join(" | ").slice(0, 480) : null, p_email: null });
  return `${c.label}: ${c.locations.length} profile(s), ${days} day-numbers, ${words} search words, ${reviews} reviews` + (notes.size ? `. ${[...notes].join(" | ")}` : "");
}

// Runs one job over every login. A failing login never stops the others. "busy" is passing: it never overwrites what is known.
export async function runJob(d: Deps, job: "discover" | "sync", w: Work): Promise<{ status: "ok" | "error"; detail: string }> {
  const lines: string[] = []; let bad = 0;
  for (const c of w.connections ?? []) {
    try { lines.push(job === "discover" ? await discover(d, w, c) : await sync(d, w, c)); }
    catch (e) {
      bad++;
      const g = e instanceof GoogleSaid ? e : new GoogleSaid("error", String((e as Error)?.message ?? e).slice(0, 300));
      if (g.state !== "busy") await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: g.state, p_error: g.message, p_email: null });
      lines.push(`${c.label}: ${g.message}`);
    }
  }
  return { status: bad ? "error" : "ok", detail: (lines.join(" · ") || "No Google login is saved yet.").slice(0, 900) };
}
