// Instagram comment-to-DM (migration 135; moved from Reel Studio's ig-poster/dm.ts, universal mode).
// Every 2 minutes: read the comments on the account's posts from the last 7 days; a new comment gets ONE private reply
// (Instagram "private replies": one message per comment, within 7 days) when the person has not had our message yet, and a
// short public reply under the comment. Spam gets nothing; angry / "fraud" comments are left for a person. The inbox too:
// someone who writes first gets the message once; a mobile number in a reply becomes a CRM lead.
// Never twice: each comment is claimed (Store.claim, primary key) BEFORE anything is sent, and a comment the account has
// already replied to (Reel Studio answered it before the move, or a person did) is recorded as 'imported' and skipped.
// Pure logic: Instagram and the database come in as interfaces, so the tests run it against fakes.

export type Json = Record<string, any>;

export const API = "https://graph.instagram.com/v26.0";
export const DEFAULT_PUBLIC = ["Boarding pass is in your inbox 🎫", "Boarding pass is in your inbox ✈️", "Boarding pass is in your inbox 🛫"];
export const MAX_CAP = 200;
const WINDOW_MIN = 7 * 1440 - 30;            // private replies are allowed for 7 days after the comment
const SPAM = /(https?:\/\/|www\.|\.(com|in|net|xyz)\b|\bpromot(e|ion)\b|\bcollab\b|\bdm (me|for)\b|\bcheck (my|our) (profile|page|bio)\b|\bfollowers?\b|\bcrypto\b|\bbitcoin\b|\bforex\b|\bgiveaway\b|\bearn (money|daily)\b)/i;
const NEGATIVE = /\b(scam|scammer|fraud|fake|cheat(er|ing)?|loot|worst|bakwas|bekar|dhokha|chor)\b/i;
const PERMISSION = new Set([3, 10, 200, 230]);

export class IGError extends Error {
  constructor(msg: string, public code?: number, public auth = false, public perm = false) { super(msg); }
}

export interface IG { get(path: string, params?: Json): Promise<Json>; post(path: string, params?: Json, body?: Json): Promise<Json>; }
export interface Store {
  known(ids: string[]): Promise<Set<string>>;                       // comment ids already in the log
  claim(row: Json): Promise<boolean>;                               // insert; false when someone else has it
  finish(commentId: string, patch: Json): Promise<void>;
  release(commentId: string): Promise<void>;                        // not the person's fault (token / permission): answer later
  person(id?: string, username?: string): Promise<Json | null>;
  savePerson(row: Json): Promise<void>;
  sent(kind: string): Promise<void>;
  lead(p: Json): Promise<Json>;                                     // svc_content_dm_lead
  cfg(patch: Json): Promise<void>;                                  // svc_ig_dm_cfg (state fields only)
}

// the Graph API over fetch; the token never appears in an error
export function httpIG(token: string, f: typeof fetch = fetch, api = API): IG {
  const call = async (method: "GET" | "POST", path: string, params: Json = {}, body?: Json) => {
    const u = `${api}/${path}?${new URLSearchParams({ ...params, access_token: token })}`;
    let r: Response;
    try { r = await f(u, body ? { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : { method }); }
    catch (e) { throw new IGError(`network problem talking to Instagram (${(e as Error).name})`); }
    let j: Json = {}; try { j = await r.json(); } catch { /* empty */ }
    if (!r.ok || j.error) {
      const e = j.error ?? {};
      const msg = String(e.error_user_msg ?? e.message ?? `HTTP ${r.status}`).split(token).join("***").slice(0, 240);
      throw new IGError(msg, e.code, e.code === 190 || r.status === 401, PERMISSION.has(e.code));
    }
    return j;
  };
  return { get: (p, q) => call("GET", p, q), post: (p, q, b) => call("POST", p, q, b) };
}

const ts = (s: unknown) => Date.parse(String(s ?? "").replace(/\+0000$/, "Z"));
const minsAgo = (s: unknown, now: number) => (now - ts(s)) / 60000;
export const render = (msg: string, username?: string) => String(msg).replace(/\{name\}/g, username ? `@${username}` : "there").slice(0, 950);

export function classify(text: string): "spam" | "negative" | null {
  const t = String(text ?? "");
  if (SPAM.test(t)) return "spam";
  if (NEGATIVE.test(t)) return "negative";
  return null;
}

// an Indian mobile anywhere in a message (+91 / 0 / spaces / dashes allowed), as +91XXXXXXXXXX
export function phoneOf(text: string): string | null {
  const d = String(text ?? "").replace(/[^\d+]/g, " ");
  for (const m of d.matchAll(/(?:\+?91|0)?\s*([6-9](?:\s*\d){9})(?!\s*\d)/g)) {
    const n = m[1].replace(/\s/g, "");
    if (/^[6-9]\d{9}$/.test(n)) return `+91${n}`;
  }
  return null;
}
const pkey = (id?: string, username?: string) => (id ? String(id) : `u:${String(username ?? "").toLowerCase()}`);
const publicText = (cfg: Json, n: number) => {
  const l: string[] = (cfg.public_replies ?? []).filter((x: unknown) => String(x ?? "").trim());
  const a = l.length ? l : DEFAULT_PUBLIC;
  return a[n % a.length];
};

// did the account (or a person on it) already answer this comment? then Reel Studio, or the team, has handled it
async function answered(ig: IG, commentId: string, uid: string, own: string): Promise<boolean> {
  const r = await ig.get(`${commentId}/replies`, { fields: "id,username,from", limit: "50" });
  return (r.data ?? []).some((x: Json) => String(x.from?.id ?? "") === uid || String(x.username ?? x.from?.username ?? "").toLowerCase() === own);
}

export async function comments(ig: IG, st: Store, cfg: Json, uid: string, own: string, media: Json[], out: Json, budget: { n: number }, now: number) {
  for (const m of media) {
    if (budget.n <= 0) { out.capped = true; return; }
    const list: Json[] = ((await ig.get(`${m.id}/comments`, { fields: "id,text,timestamp,username,from", limit: "50" })).data ?? [])
      .filter((c: Json) => minsAgo(c.timestamp, now) < WINDOW_MIN)
      .map((c: Json): Json => ({ ...c, who: String(c.username ?? c.from?.username ?? "") }))
      .filter((c: Json) => c.who && c.who.toLowerCase() !== own && String(c.from?.id ?? "") !== uid);
    if (!list.length) continue;
    const done = await st.known(list.map((c) => String(c.id)));
    for (const c of list.sort((x, y) => ts(x.timestamp) - ts(y.timestamp))) {
      if (done.has(String(c.id))) continue;
      if (budget.n <= 0) { out.capped = true; return; }
      const base = { comment_id: String(c.id), media_id: String(m.id), username: c.who.slice(0, 60), text: String(c.text ?? "").slice(0, 200), person: pkey(c.from?.id, c.who) };
      const kind = classify(c.text);
      if (kind) { if (await st.claim({ ...base, state: "skipped", reason: kind })) out[kind] = (out[kind] ?? 0) + 1; continue; }
      if (!(await st.claim({ ...base, state: "sending" }))) continue;                 // another run has it
      try {
        if (await answered(ig, String(c.id), uid, own)) { await st.finish(String(c.id), { state: "imported", reason: "already answered" }); out.imported = (out.imported ?? 0) + 1; continue; }
      } catch (e) {
        const err = e as IGError;
        if (err.auth || err.perm) { await st.release(String(c.id)); await stopFor(st, err, "comments"); out.stop = true; return; }
        await st.release(String(c.id)); continue;                                    // try this comment again next run
      }
      const p = await st.person(c.from?.id, c.who);
      let reached = !!p?.dm_at, state = "public";
      if (!reached) {
        try {
          const r = await ig.post(`${uid}/messages`, {}, { recipient: { comment_id: String(c.id) }, message: { text: render(String(cfg.message), c.who).slice(0, 990) } });
          budget.n--; await st.sent("private");
          await st.savePerson({ person: pkey(r.recipient_id ?? c.from?.id, c.who), igsid: r.recipient_id ?? c.from?.id ?? null, username: c.who, source: "comment", dm_at: new Date(now).toISOString() });
          reached = true; state = "sent"; out.sent = (out.sent ?? 0) + 1;
        } catch (e) {
          const err = e as IGError;
          if (err.auth || err.perm) { await st.release(String(c.id)); await stopFor(st, err, "messages"); out.stop = true; return; }
          await st.finish(String(c.id), { state: "failed", error: err.message.slice(0, 200) });
          out.failed = (out.failed ?? 0) + 1;
          continue;                                                                    // no DM, so no "check your inbox" either
        }
      }
      if (reached && cfg.public_reply !== false && budget.n > 0) {
        try { await ig.post(`${c.id}/replies`, { message: publicText(cfg, out.public ?? 0) }); budget.n--; await st.sent("public"); out.public = (out.public ?? 0) + 1; }
        catch { /* the DM is what matters */ }
      }
      await st.finish(String(c.id), { state, sent_at: new Date(now).toISOString() });
    }
  }
}

// The inbox: chats updated in the last 24 hours (Instagram allows replies within 24 hours of the person's message)
export async function inbox(ig: IG, st: Store, cfg: Json, uid: string, out: Json, budget: { n: number }, now: number) {
  const since = Math.max(cfg.inbox_at ? ts(cfg.inbox_at) - 120e3 : 0, now - 24 * 3600e3 + 300e3);
  const convs: Json[] = (await ig.get("me/conversations", { platform: "instagram", fields: "id,updated_time", limit: "25" })).data ?? [];
  let newest = since; const res = { welcomed: 0, phones: 0, leads: 0 };
  for (const cv of convs) {
    const t = ts(cv.updated_time);
    if (!(t > since)) continue;
    if (budget.n <= 0) { out.capped = true; break; }
    const ids: Json[] = ((await ig.get(String(cv.id), { fields: "messages" })).messages?.data ?? []).slice(0, 8);
    const msgs: Json[] = [];
    for (const m of ids) { try { msgs.push(await ig.get(String(m.id), { fields: "id,created_time,from,to,message" })); } catch { /* too old for Instagram */ } }
    const theirs = msgs.filter((m) => m.from?.id && String(m.from.id) !== uid).sort((x, y) => ts(x.created_time) - ts(y.created_time));
    if (!theirs.length) { newest = Math.max(newest, t); continue; }
    const who = theirs[theirs.length - 1].from; const id = String(who.id); const username = String(who.username ?? "");
    const p = await st.person(id, username);
    const fresh = theirs.filter((m) => ts(m.created_time) > Math.max(since, p?.last_in_at ? ts(p.last_in_at) : 0));
    if (!fresh.length) { newest = Math.max(newest, t); continue; }
    const first = ts(fresh[0].created_time);
    const row: Json = { person: p?.person ?? id, igsid: id, username: username || p?.username || null, last_in_at: new Date(ts(fresh[fresh.length - 1].created_time)).toISOString() };
    const send = async (message: Json, kind: string) => { await ig.post(`${uid}/messages`, {}, { recipient: { id }, message }); budget.n--; await st.sent(kind); };
    try {
      if (!p?.dm_at) {      // they wrote first: welcome them once, unless the team is already talking to them in this chat
        const team = msgs.some((m) => String(m.from?.id ?? "") === uid && ts(m.created_time) < first);
        if (!team) { await send({ text: render(String(cfg.message), username || undefined).slice(0, 990) }, "welcome"); row.dm_at = new Date(now).toISOString(); row.source = p?.source ?? "dm"; res.welcomed++; }
      }
      const phone = p?.phone ? null : fresh.map((m) => phoneOf(String(m.message ?? ""))).find(Boolean);
      if (phone) {
        row.phone = phone; res.phones++;
        if (cfg.crm !== false && username) {
          try {
            const l = await st.lead({ username, phone, source: (p?.source ?? row.source) === "dm" ? "dm" : "comment_dm",
              text: fresh.map((m) => String(m.message ?? "")).join(" ").replace(/\s+/g, " ").trim().slice(0, 300) });
            if (l?.lead_id) { row.lead_id = l.lead_id; res.leads++; }
            else if (l?.error) row.note = String(l.error).slice(0, 200);
          } catch (e) { row.note = `CRM lead: ${String((e as Error).message).slice(0, 180)}`; }
        }
        if (cfg.thanks && budget.n > 0) await send({ text: render(String(cfg.thanks), username || undefined).slice(0, 990) }, "thanks");
      }
    } catch (e) {
      const err = e as IGError;
      if (err.auth || err.perm) { await stopFor(st, err, "inbox"); out.inbox = { ...res, stop: true }; return; }
      row.note = err.message.slice(0, 200);           // outside the 24-hour window or a deleted chat: not retried
    }
    await st.savePerson(row);
    newest = Math.max(newest, t);
  }
  out.inbox = res;
  await st.cfg({ inbox_at: new Date(newest).toISOString() });
}

async function stopFor(st: Store, err: IGError, where: "comments" | "messages" | "inbox") {
  const need = where === "comments" ? "instagram_business_manage_comments" : "instagram_business_manage_messages";
  await st.cfg({ state: err.auth ? "not_connected" : "needs_permission", checked_at: new Date().toISOString(),
    note: err.auth ? "The Instagram token expired or was revoked: generate a new one and save it as INSTAGRAM_LOGIN_TOKEN."
      : `Instagram refused (${err.message.slice(0, 120)}): the token needs ${need}. Generate it again with that permission and save it.` });
}

// One run. work = svc_ig_dm_work(): { cfg, token, token_at, sent_last_hour }
export async function tick(work: Json, ig: IG | null, st: Store, now = Date.now()): Promise<Json> {
  const cfg: Json = work.cfg ?? {};
  if (!cfg.on) return { off: true };
  if (!work.token || !ig) {
    if (cfg.state !== "not_connected") await st.cfg({ state: "not_connected", note: "Save the Instagram Login token (INSTAGRAM_LOGIN_TOKEN) to start." });
    return { connected: false };
  }
  // refused for a missing permission: wait until the token is replaced or the settings are saved again
  if (cfg.state === "needs_permission" && !(work.token_at && ts(work.token_at) > ts(cfg.checked_at ?? 0))) return { waiting: "permission" };
  if (!String(cfg.message ?? "").trim()) return { incomplete: true };
  let uid = String(cfg.user_id ?? ""), own = String(cfg.username ?? "").toLowerCase();
  if (cfg.state !== "ready" || !uid) {              // first run, new token or after a fix: who is this, and can it read comments?
    try {
      const me = await ig.get("me", { fields: "user_id,username" });
      uid = String(me.user_id ?? me.id ?? ""); own = String(me.username ?? "").toLowerCase();
      const media0: Json[] = (await ig.get(`${uid}/media`, { fields: "id", limit: "1" })).data ?? [];
      if (media0[0]) await ig.get(`${media0[0].id}/comments`, { fields: "id", limit: "1" });
      await st.cfg({ state: "ready", note: null, user_id: uid, username: own, checked_at: new Date(now).toISOString(), started_at: cfg.started_at ?? new Date(now).toISOString() });
    } catch (e) {
      const err = e as IGError;
      await st.cfg({ state: err.auth ? "not_connected" : err.perm ? "needs_permission" : "error", checked_at: new Date(now).toISOString(),
        note: err.auth ? "The Instagram token is not valid: generate a new one and save it as INSTAGRAM_LOGIN_TOKEN."
          : err.perm ? "The token needs instagram_business_basic, instagram_business_manage_comments and instagram_business_manage_messages." : `Instagram: ${err.message}` });
      return { state: "not ready", error: err.message };
    }
  }
  const media: Json[] = ((await ig.get(`${uid}/media`, { fields: "id,timestamp", limit: "12" })).data ?? [])
    .filter((m: Json) => minsAgo(m.timestamp, now) < 7 * 1440);
  const cap = Math.max(1, Math.min(MAX_CAP, Number(cfg.cap) || 60));
  const budget = { n: cap - Number(work.sent_last_hour ?? 0) };
  const out: Json = { sent: 0, media: media.length };
  await comments(ig, st, cfg, uid, own, media, out, budget, now);
  if (!out.stop && cfg.inbox !== false) {
    try { await inbox(ig, st, cfg, uid, out, budget, now); }
    catch (e) { out.inbox = { error: String((e as Error).message).slice(0, 160) }; }
  }
  return out;
}

// Instagram Login long-lived tokens last 60 days; refresh one older than 20 days (it must be at least 24 hours old)
export async function refreshToken(token: string, tokenAt: string | null, f: typeof fetch = fetch, now = Date.now()): Promise<string | null> {
  if (!tokenAt || now - ts(tokenAt) < 20 * 86400e3) return null;
  const u = `https://graph.instagram.com/refresh_access_token?${new URLSearchParams({ grant_type: "ig_refresh_token", access_token: token })}`;
  try {
    const r = await f(u); const j = await r.json().catch(() => ({}));
    return r.ok && typeof j.access_token === "string" && j.access_token.length > 20 ? j.access_token : null;
  } catch { return null; }
}
