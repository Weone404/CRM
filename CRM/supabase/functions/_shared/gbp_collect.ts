// Google My Business collector logic (139), kept free of Deno/Supabase so it can be tested with a fake Google and a fake database.
//   discover  one Google login: does it still sign in, does Google let this project read Business Profile, which profiles it manages
//   sync      its tracked profiles: daily numbers, the words people searched (month by month) and the reviews
// A login's state is always saved in plain words: connected, waiting for Google's approval (quota 0), sign in again, API off, no access.
import { accountsUrl, addDays, gbpError, keywordsUrl, locationsUrl, mediaUrl, metricsUrl, monthsBack, parseAccounts, parseKeywords, parseLocations,
  parseMedia, parseMetrics, parsePosts, parseReviews, postBody, postsUrl, replyUrl, reviewUrl, reviewsUrl, type GbpState, type LocRow, type MediaRow, type PostRow } from "./gbp.ts";

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
  await d.rpc("svc_gbp_details_save", { p_connection: c.id, p_rows: rows.map((r) => ({ name: r.name, details: r.details })) });      // for the health check (143)
  await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: "connected", p_error: null, p_email: who });
  return `${c.label}: ${n} profile(s) in ${accounts.length} account(s)` + (cut ? " (time limit reached; the rest next run)" : "");
}

export async function sync(d: Deps, w: Work, c: Conn): Promise<string> {
  if (!c.locations.length) return `${c.label}: no tracked profile`;
  const token = await signIn(d, w, c);
  let days = 0, words = 0, reviews = 0, posts = 0, photos = 0, good = 0; const notes = new Set<string>(); let firstProblem: GoogleSaid | null = null;
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
    // Posts and photos (143). The whole list is read when it fits, so what was removed on Google disappears here too.
    await part(async () => {
      const rows: PostRow[] = []; let next: string | null = null, pages = 0;
      do {
        const p = parsePosts(await gget(d, token, "Google My Business API (posts)", postsUrl(l.account, l.name, next)));
        rows.push(...p.rows); next = p.next;
      } while (next && ++pages < 5 && !d.expired());
      posts += Number(await d.rpc("svc_gbp_posts_save", { p_location: l.id, p_rows: rows, p_complete: !next }));
    });
    await part(async () => {
      const rows: MediaRow[] = []; const totals: (number | null)[] = [null, null]; let complete = true;
      for (const [i, customers] of [false, true].entries()) {
        let next: string | null = null, pages = 0;
        do {
          const m = parseMedia(await gget(d, token, "Google My Business API (photos)", mediaUrl(l.account, l.name, customers, next)), !customers);
          if (!pages) totals[i] = m.total ?? (m.next ? null : m.rows.length);
          rows.push(...m.rows); next = m.next;
        } while (next && ++pages < (customers ? 2 : 5) && !d.expired());
        if (next) complete = false;
      }
      photos += Number(await d.rpc("svc_gbp_media_save", { p_location: l.id, p_rows: rows, p_owner_total: totals[0], p_customer_total: totals[1], p_complete: complete }));
    });
  }
  if (!good && firstProblem) throw firstProblem;                       // nothing at all could be read: that is the login's state
  await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: "connected", p_error: notes.size ? [...notes].join(" | ").slice(0, 480) : null, p_email: null });
  return `${c.label}: ${c.locations.length} profile(s), ${days} day-numbers, ${words} search words, ${reviews} reviews` + (posts || photos ? `, ${posts} posts, ${photos} photos` : "") + (notes.size ? `. ${[...notes].join(" | ")}` : "");
}

// Reviews only, newest first, one page per tracked profile: the 3-hourly look for new reviews (the nightly sync reads everything).
export async function syncReviews(d: Deps, w: Work, c: Conn): Promise<string> {
  if (!c.locations.length) return `${c.label}: no tracked profile`;
  const token = await signIn(d, w, c);
  let n = 0;
  for (const l of c.locations) {
    if (d.expired()) break;
    const r = parseReviews(await gget(d, token, "Google My Business API (reviews)", reviewsUrl(l.account, l.name)));
    n += Number(await d.rpc("svc_gbp_reviews_save", { p_location: l.id, p_rows: r.rows, p_total: r.total, p_rating: r.rating }));
  }
  return `${c.label}: ${n} review(s) read`;
}

// Sends the approved replies (migration 140). Before each one the review is read once more: if it was answered on Google
// in the meantime, or deleted, nothing is sent. A reply is sent at most once: any doubt about the outcome is a retry of
// the read-then-write, and the read sees a reply that did arrive.
type Queued = { id: number; connection_id: string; account: string; location: string; review_id: string; text: string };
export async function sendReplies(d: Deps, w: Work): Promise<{ status: "ok" | "error"; detail: string }> {
  const q = (await d.rpc("svc_gbp_reply_queue", { p_limit: 10 }) ?? []) as Queued[];
  if (!Array.isArray(q) || !q.length) return { status: "ok", detail: "No reply is waiting to be sent." };
  const tokens = new Map<string, string | GoogleSaid>(); let sent = 0, skipped = 0, later = 0, failed = 0; const notes = new Set<string>();
  const result = (id: number, state: string, error: string | null) => d.rpc("svc_gbp_reply_result", { p_id: id, p_state: state, p_error: error });
  for (const r of q) {
    if (d.expired()) { later++; continue; }
    const c = (w.connections ?? []).find((x) => x.id === r.connection_id);
    try {
      if (!c) throw new GoogleSaid("needs_signin", "The Google login of this profile was removed.");
      if (!tokens.has(c.id)) { try { tokens.set(c.id, await signIn(d, w, c)); } catch (e) { tokens.set(c.id, e instanceof GoogleSaid ? e : new GoogleSaid("error", "Google sign-in failed.")); } }
      const token = tokens.get(c.id)!;
      if (token instanceof GoogleSaid) throw token;
      const readAt = reviewUrl(r.account, r.location, r.review_id), writeAt = replyUrl(r.account, r.location, r.review_id);   // refuses anything that is not an id
      let res: Response;
      try { res = await d.fetch(readAt, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30000) }); }
      catch { throw new GoogleSaid("busy", "Google did not answer in time."); }
      const b = await res.json().catch(() => ({}));
      if (res.status === 404) { await result(r.id, "skipped", "The review is no longer on Google"); skipped++; continue; }
      if (!res.ok) { const e = gbpError("Google My Business API (reviews)", res.status, b); throw new GoogleSaid(e.state, e.message); }
      const there = String(b?.reviewReply?.comment ?? "").trim();
      if (there && there === r.text.trim()) { await result(r.id, "sent", null); sent++; continue; }      // an earlier try did arrive
      if (there) { await result(r.id, "skipped", "Answered on Google"); skipped++; continue; }
      let put: Response;
      try { put = await d.fetch(writeAt, { method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ comment: r.text }), signal: AbortSignal.timeout(30000) }); }
      catch { throw new GoogleSaid("busy", "Google did not confirm the reply in time; it is checked again before another try."); }
      const pb = await put.json().catch(() => ({}));
      if (!put.ok) { const e = gbpError("Google My Business API (reviews)", put.status, pb); throw new GoogleSaid(e.state, e.message); }
      await result(r.id, "sent", null); sent++;
    } catch (e) {
      const g = e instanceof GoogleSaid ? e : new GoogleSaid("error", String((e as Error)?.message ?? e).slice(0, 300));
      notes.add(g.message);
      // waiting for Google, a busy Google or an expired sign-in can clear up: keep the reply queued. Anything else is Google refusing this reply.
      if (g.state === "busy" || g.state === "waiting_google" || g.state === "needs_signin" || g.state === "api_off") { await result(r.id, "retry", g.message); later++; }
      else { await result(r.id, "failed", g.message); failed++; }
      if (c && (g.state === "needs_signin" || g.state === "waiting_google")) await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: g.state, p_error: g.message, p_email: null });
    }
  }
  const detail = `${sent} sent, ${skipped} not needed, ${later} waiting, ${failed} refused` + (notes.size ? `. ${[...notes].join(" | ")}` : "");
  return { status: failed || later ? "error" : "ok", detail: detail.slice(0, 900) };
}

// Publishes the posts a person queued (143). One request per post and no retry: if Google does not answer, nobody can tell whether
// the post exists, and a second try could publish it twice. The post is marked failed with that explanation and a person decides.
type QueuedPost = { id: number; location_id: string; connection_id: string; account: string; location: string; summary: string; cta_type: string | null; cta_url: string | null; photo_url: string | null };
export async function sendPosts(d: Deps, w: Work): Promise<{ status: "ok" | "error"; detail: string }> {
  const q = (await d.rpc("svc_gbp_post_queue", { p_limit: 5 }) ?? []) as QueuedPost[];
  if (!Array.isArray(q) || !q.length) return { status: "ok", detail: "No post is waiting to be published." };
  const tokens = new Map<string, string | GoogleSaid>(); let sent = 0, failed = 0; const notes = new Set<string>();
  const result = (id: number, state: string, error: string | null, name: string | null) => d.rpc("svc_gbp_post_result", { p_id: id, p_state: state, p_error: error, p_name: name });
  for (const p of q) {
    const c = (w.connections ?? []).find((x) => x.id === p.connection_id);
    try {
      if (!c) throw new GoogleSaid("needs_signin", "The Google login of this profile was removed.");
      if (!tokens.has(c.id)) { try { tokens.set(c.id, await signIn(d, w, c)); } catch (e) { tokens.set(c.id, e instanceof GoogleSaid ? e : new GoogleSaid("error", "Google sign-in failed.")); } }
      const token = tokens.get(c.id)!;
      if (token instanceof GoogleSaid) throw token;
      const at = postsUrl(p.account, p.location).split("?")[0];
      let res: Response;
      try { res = await d.fetch(at, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(postBody(p)), signal: AbortSignal.timeout(45000) }); }
      catch { throw new GoogleSaid("error", "Google did not confirm this post. Check the profile on Google before publishing it again."); }
      const b = await res.json().catch(() => ({}));
      if (!res.ok) { const e = gbpError("Google My Business API (posts)", res.status, b); throw new GoogleSaid(e.state, e.message); }
      if (String(b?.state ?? "") === "REJECTED") throw new GoogleSaid("error", "Google rejected the post (it breaks Google's content rules for posts).");
      await result(p.id, "sent", null, typeof b?.name === "string" ? b.name : null); sent++;
      const live = parsePosts({ localPosts: [b] }).rows;                              // show it at once, before the nightly read
      if (live.length) await d.rpc("svc_gbp_posts_save", { p_location: p.location_id, p_rows: live, p_complete: false }).catch(() => null);
    } catch (e) {
      const g = e instanceof GoogleSaid ? e : new GoogleSaid("error", String((e as Error)?.message ?? e).slice(0, 300));
      notes.add(g.message); failed++;
      await result(p.id, "failed", g.message, null);
      if (c && (g.state === "needs_signin" || g.state === "waiting_google")) await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: g.state, p_error: g.message, p_email: null });
    }
  }
  return { status: failed ? "error" : "ok", detail: (`${sent} published, ${failed} not published` + (notes.size ? `. ${[...notes].join(" | ")}` : "")).slice(0, 900) };
}

// Runs one job over every login. A failing login never stops the others. "busy" is passing: it never overwrites what is known.
export type Job = "discover" | "sync" | "reviews" | "reply" | "post";
export async function runJob(d: Deps, job: Job, w: Work): Promise<{ status: "ok" | "error"; detail: string }> {
  if (job === "reply") return sendReplies(d, w);
  if (job === "post") return sendPosts(d, w);
  const lines: string[] = []; let bad = 0;
  for (const c of w.connections ?? []) {
    try { lines.push(job === "discover" ? await discover(d, w, c) : job === "reviews" ? await syncReviews(d, w, c) : await sync(d, w, c)); }
    catch (e) {
      bad++;
      const g = e instanceof GoogleSaid ? e : new GoogleSaid("error", String((e as Error)?.message ?? e).slice(0, 300));
      if (g.state !== "busy") await d.rpc("svc_gbp_connection_status", { p_id: c.id, p_status: g.state, p_error: g.message, p_email: null });
      lines.push(`${c.label}: ${g.message}`);
    }
  }
  return { status: bad ? "error" : "ok", detail: (lines.join(" · ") || "No Google login is saved yet.").slice(0, 900) };
}
