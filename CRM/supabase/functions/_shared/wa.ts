// WhatsApp (migration 150): the flow engine, Meta message builders, webhook parsing and error rules.
// Pure TypeScript (no Deno APIs; network only through the fetch function passed in), so every rule here is unit-tested
// in supabase/tests/wa/wa.test.ts. The Edge Functions (wa-webhook, wa-worker, wa-admin) only glue this to the database.
//
// Meta references (checked 27 Nov 2026):
//   Send:      POST /{phone_number_id}/messages {messaging_product: "whatsapp", to, type, ...}
//              https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages
//   Window:    free-form messages only within 24 h of the person's last message; templates any time.
//   Webhooks:  X-Hub-Signature-256 = "sha256=" + HMAC-SHA256(raw body, App Secret); anything but 200 is retried with
//              decreasing frequency for up to 7 days and can arrive twice.
//              https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview
//   Errors:    131049 per-user marketing limit (do not retry for 24 h), 131026 undeliverable, 131047 window closed,
//              130429 / 131056 rate limits (retry later), 132xxx template problems, 190 token.
import { safeEqual, verifySignature } from "./ads_meta.ts";
export { safeEqual, verifySignature };

export const WA_BUILD = "2026-11-27.wa1";

// deno-lint-ignore no-explicit-any
export type Json = Record<string, any>;
export type Action = "goto" | "handoff" | "optout" | "book_counselling" | "send_brochure" | "restart" | "end";
export interface Button { id?: string; title: string; goto?: string | null; action?: Action | null }
export interface Step {
  key: string; kind: "text" | "buttons" | "list" | "document"; body: string; buttons?: Button[];
  capture?: string | null; next_key?: string | null; auto_next?: string | null; handoff?: boolean; is_start?: boolean; title?: string | null;
}
export interface Rule {
  id?: string; step_key?: string | null; match_type: "button" | "exact" | "contains" | "synonym"; patterns: string[];
  priority?: number; action: Action; goto_key?: string | null; reply_text?: string | null; active?: boolean;
}
export interface Inbound {
  wamid: string; from: string; profile_name?: string; ts?: string; kind: string;
  text?: string; button_id?: string; button_title?: string; caption?: string;
  media?: { id: string; mime_type?: string; filename?: string }; referral?: Json; payload?: Json; phone_number_id?: string;
}
export interface StatusItem { wamid: string; status: string; error_code?: number; error_text?: string; category?: string }
export type OutItem =
  | { type: "text"; body: string }
  | { type: "buttons"; body: string; buttons: { id: string; title: string }[] }
  | { type: "list"; body: string; button: string; rows: { id: string; title: string }[] }
  | { type: "document"; link: string; filename: string; caption?: string }
  | { type: "template"; name?: string; purpose?: string };
export interface Ctx {
  conversation: Json; contact: Json; steps: Step[]; rules: Rule[];
  vars: Record<string, string>; brochure?: { url?: string | null; name?: string | null }; bot_on?: boolean;
}
export interface WaEvent { kind: string; detail?: Json; notify?: boolean }
export interface Decision { patch: Json; out: OutItem[]; events: WaEvent[]; matched?: string }

// ------------------------------------------------------------------ text helpers
export function norm(s: string | undefined | null): string {
  return String(s ?? "").toLowerCase().replace(/[’‘`´]/g, "'").replace(/[^\p{L}\p{M}\p{N}' ]+/gu, " ").replace(/'/g, "")
    .replace(/\s+/g, " ").trim();
}
export function fill(text: string, vars: Record<string, string> = {}): string {
  return String(text ?? "").replace(/\{\{\s*(\w+)\s*\}\}/g, (_m, k) => (vars[k] ?? "").toString());
}
function lev1(a: string, b: string): boolean {                // edit distance <= 1
  if (a === b) return true;
  if (Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++edits > 1) return false;
    if (a.length > b.length) i++; else if (b.length > a.length) j++; else { i++; j++; }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}
const has = (input: string, phrase: string) => phrase !== "" && ` ${input} `.includes(` ${phrase} `);

export function ruleMatches(r: Rule, input: string, button: string): boolean {
  const pats = (r.patterns ?? []).map(norm).filter(Boolean);
  switch (r.match_type) {
    case "button": return button !== "" && pats.includes(button);
    case "exact": return pats.includes(input);
    case "contains": return pats.some((p) => has(input, p));
    case "synonym": {
      if (pats.some((p) => p === input || has(input, p))) return true;
      const words = input.split(" ");
      return input.length <= 40 && pats.some((p) => !p.includes(" ") && p.length >= 4 && words.some((w) => w.length >= 4 && lev1(w, p)));
    }
  }
  return false;
}

// ------------------------------------------------------------------ rendering a step
export function renderStep(step: Step, vars: Record<string, string>, brochure?: Ctx["brochure"]): OutItem[] {
  const body = fill(step.body, vars).slice(0, 1024);
  const btns = (step.buttons ?? []).filter((b) => b?.title);
  if (step.kind === "buttons" && btns.length) {
    return [{ type: "buttons", body, buttons: btns.slice(0, 3).map((b, i) => ({ id: (b.id || `b${i + 1}`).slice(0, 256), title: fill(b.title, vars).slice(0, 20) })) }];
  }
  if (step.kind === "list" && btns.length) {
    return [{ type: "list", body, button: "Choose", rows: btns.slice(0, 10).map((b, i) => ({ id: (b.id || `r${i + 1}`).slice(0, 200), title: fill(b.title, vars).slice(0, 24) })) }];
  }
  if (step.kind === "document") {
    if (brochure?.url && /^https:\/\//.test(brochure.url)) {
      return [{ type: "document", link: brochure.url, filename: (brochure.name || "brochure.pdf").slice(0, 240), caption: body }];
    }
    return [{ type: "text", body: `${body} Our counsellor will share it with you shortly.` }];
  }
  return [{ type: "text", body: body.slice(0, 4096) }];
}

// ------------------------------------------------------------------ the engine
const DEFAULT = {
  handoff: "Thanks! Our counsellor will get back to you shortly. You can also call us on {{counsellor_phone}}.",
  booked: "Great! Our counsellor will call you shortly to fix a time. You can also call us on {{counsellor_phone}}.",
  optout: "Done. You will not get more messages from us. Reply START any time to talk again.",
  miss: "Sorry, I didn't catch that. Please tap one of the options below.",
  stuck: "Let me connect you with our counsellor. They will reach you shortly.",
  end: "No problem, {{name}}. Message us here any time and we will help you.",
  noBrochure: "Our counsellor will share the brochure with you shortly.",
};
const START_WORDS = new Set(["start", "subscribe", "resume", "unstop"]);
const SILENT_KINDS = new Set(["reaction", "unsupported", "system", "ephemeral", "request_welcome"]);

export function decide(ctx: Ctx, msg: Inbound, now = Date.now()): Decision {
  const conv = ctx.conversation ?? {}, contact = ctx.contact ?? {};
  const vars = ctx.vars ?? {};
  const steps = new Map((ctx.steps ?? []).map((s) => [s.key, s]));
  const start = (ctx.steps ?? []).find((s) => s.is_start) ?? (ctx.steps ?? [])[0];
  const d: Decision = { patch: {}, out: [], events: [] };
  const input = norm(msg.text ?? msg.button_title ?? msg.caption ?? "");
  const button = norm(msg.button_title ?? "");
  const buttonId = String(msg.button_id ?? "");

  if (SILENT_KINDS.has(msg.kind)) return d;
  if (contact.opted_out) {                                     // stopped: only START brings them back
    if (START_WORDS.has(input) && start) {
      d.patch.opted_in = true; d.events.push({ kind: "opted_in" });
      go(start.key);
    } else d.events.push({ kind: "inbound_opted_out" });
    return d;
  }
  if (ctx.bot_on === false) return d;
  if (conv.status === "human" || (conv.paused_until && Date.parse(conv.paused_until) > now)) {
    d.events.push({ kind: "inbound_for_person", notify: true, detail: { text: (msg.text ?? msg.button_title ?? "").slice(0, 120) } });
    return d;
  }
  if (!start) {                                                 // no flow at all: a person answers
    handoff(DEFAULT.handoff, "no flow");
    return d;
  }

  const rules = (ctx.rules ?? []).filter((r) => r.active !== false);
  const cur = conv.current_step ? steps.get(conv.current_step) : undefined;
  const scoped = (key: string | null, type: Rule["match_type"]) => rules
    .filter((r) => (r.step_key ?? null) === key && r.match_type === type)
    .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));

  // 1. STOP always wins.
  const stop = rules.filter((r) => r.action === "optout").find((r) => ruleMatches(r, input, button));
  if (stop) { act(stop.action, null, stop.reply_text ?? null, "optout"); return d; }

  // 2. No step yet (they wrote first, or the welcome template was never sent): a global rule, or the first step.
  if (!cur) {
    for (const t of ["button", "exact", "contains", "synonym"] as const) {
      const r = scoped(null, t).find((x) => ruleMatches(x, input, button));
      if (r && r.action !== "restart" && r.action !== "end") { act(r.action, r.goto_key ?? null, r.reply_text ?? null, `rule:${r.id ?? t}`); return d; }
    }
    go(start.key);
    d.matched = "start";
    return d;
  }

  // 3. The current step's own buttons (tapped, or the title typed), then rules: button > exact > contains > synonym,
  //    each checked on the current step first and then on every step.
  const own = (cur.buttons ?? []).find((b) => (buttonId && b.id === buttonId) || (norm(b.title) !== "" && (norm(b.title) === button || norm(b.title) === input)));
  if (own) { act(own.action ?? "goto", own.goto ?? null, null, `button:${own.id ?? own.title}`); return d; }
  for (const t of ["button", "exact", "contains", "synonym"] as const) {
    for (const key of [cur.key, null]) {
      const r = scoped(key, t).find((x) => ruleMatches(x, input, button));
      if (r) { act(r.action, r.goto_key ?? null, r.reply_text ?? null, `rule:${r.id ?? t}`); return d; }
    }
  }

  // 4. A step that asks a question (e.g. city): any typed answer is kept and the flow moves on.
  if (cur.capture && input && !button) {
    d.patch.answers = { [cur.capture]: String(msg.text ?? "").slice(0, 300) };
    d.matched = `capture:${cur.capture}`;
    if (cur.next_key && steps.has(cur.next_key)) go(cur.next_key);
    else handoff(DEFAULT.handoff, "capture with no next step");
    return d;
  }

  // 5. Not understood. A step with no options (end of the flow): a person answers. Otherwise show the options again,
  //    and after the second miss a person takes over.
  const options = (cur.buttons ?? []).length > 0;
  if (!options) { handoff(DEFAULT.handoff, "question after the flow", msg.text); return d; }
  const misses = (conv.miss_count ?? 0) + 1;
  if (misses >= 2) { handoff(DEFAULT.stuck, "not understood twice", msg.text); d.patch.miss_count = 0; return d; }
  d.patch.miss_count = misses;
  d.out.push({ type: "text", body: DEFAULT.miss });
  d.out.push(...renderStep(cur, vars, ctx.brochure));
  d.matched = "miss";
  return d;

  // ---------------------------------------------------------------- helpers (hoisted)
  function go(key: string, depth = 0): void {
    const s = steps.get(key);
    if (!s) { handoff(DEFAULT.handoff, `missing step ${key}`); return; }
    d.out.push(...renderStep(s, vars, ctx.brochure));
    if (s.kind === "document" && !(ctx.brochure?.url)) d.events.push({ kind: "brochure_missing", notify: false });
    d.patch.current_step = s.key;
    d.patch.miss_count = 0;
    if (s.handoff) {
      d.patch.status = "human";
      if (!d.events.some((e) => e.kind === "counselling_requested" || e.kind === "handoff")) d.events.push({ kind: "handoff", notify: true, detail: { step: s.key } });
    }
    if (s.auto_next && depth < 4 && s.auto_next !== s.key) go(s.auto_next, depth + 1);
  }
  function handoff(text: string, reason: string, said?: string): void {
    d.out.push({ type: "text", body: fill(text, vars) });
    d.patch.status = "human";
    d.events.push({ kind: "handoff", notify: true, detail: { reason, text: String(said ?? "").slice(0, 120) } });
  }
  function act(action: Action, gotoKey: string | null, reply: string | null, why: string): void {
    d.matched = why;
    d.patch.miss_count = 0;
    const say = () => { if (reply) d.out.push({ type: "text", body: fill(reply, vars) }); };
    switch (action) {
      case "optout":
        d.out.push({ type: "text", body: fill(reply ?? DEFAULT.optout, vars) });
        d.patch.opted_out = true; d.events.push({ kind: "opted_out" });
        return;
      case "handoff":
        handoff(reply ?? DEFAULT.handoff, "asked for a person", msg.text ?? msg.button_title);
        return;
      case "book_counselling":
        d.events.push({ kind: "counselling_requested", notify: true, detail: { text: String(msg.text ?? msg.button_title ?? "").slice(0, 120) } });
        if (steps.has("booked")) { say(); go("booked"); d.patch.status = "human"; }
        else { d.out.push({ type: "text", body: fill(reply ?? DEFAULT.booked, vars) }); d.patch.status = "human"; }
        return;
      case "send_brochure":
        say();
        if (steps.has("brochure")) go("brochure");
        else if (ctx.brochure?.url) d.out.push(...renderStep({ key: "brochure", kind: "document", body: "Here is our brochure." }, vars, ctx.brochure));
        else { d.out.push({ type: "text", body: DEFAULT.noBrochure }); d.events.push({ kind: "brochure_missing", notify: true }); }
        return;
      case "restart":
        say(); go(start.key);
        return;
      case "end":
        say();
        if (steps.has("end")) go("end"); else { d.out.push({ type: "text", body: fill(DEFAULT.end, vars) }); d.patch.current_step = "end"; }
        return;
      case "goto":
      default:
        say();
        if (gotoKey && steps.has(gotoKey)) go(gotoKey); else handoff(DEFAULT.handoff, `missing step ${gotoKey}`);
    }
  }
}

// ------------------------------------------------------------------ webhook parsing
export function parseWebhook(body: unknown): { messages: Inbound[]; statuses: StatusItem[] } {
  const messages: Inbound[] = [], statuses: StatusItem[] = [];
  const entries = Array.isArray((body as Json)?.entry) ? (body as Json).entry : [];
  for (const e of entries) {
    for (const ch of Array.isArray(e?.changes) ? e.changes : []) {
      if (ch?.field !== "messages" || !ch?.value) continue;
      const v = ch.value;
      const pid = String(v?.metadata?.phone_number_id ?? "");
      const names = new Map<string, string>();
      for (const c of Array.isArray(v.contacts) ? v.contacts : []) if (c?.wa_id) names.set(String(c.wa_id), String(c?.profile?.name ?? ""));
      for (const m of Array.isArray(v.messages) ? v.messages : []) {
        if (!m?.id || !m?.from) continue;
        const kind = String(m.type ?? "unsupported");
        const it: Inbound = { wamid: String(m.id), from: String(m.from), profile_name: names.get(String(m.from)) || undefined,
          ts: m.timestamp ? String(m.timestamp) : undefined, kind, phone_number_id: pid || undefined };
        if (kind === "text") it.text = String(m.text?.body ?? "");
        else if (kind === "button") { it.button_title = String(m.button?.text ?? ""); it.button_id = String(m.button?.payload ?? ""); }
        else if (kind === "interactive") {
          const r = m.interactive?.button_reply ?? m.interactive?.list_reply;
          if (r) { it.button_title = String(r.title ?? ""); it.button_id = String(r.id ?? ""); }
          else it.kind = "unsupported";
        } else if (["image", "audio", "video", "document", "sticker", "voice"].includes(kind)) {
          const md = m[kind] ?? {};
          if (md.id) it.media = { id: String(md.id), mime_type: md.mime_type ? String(md.mime_type) : undefined, filename: md.filename ? String(md.filename) : undefined };
          if (md.caption) it.caption = String(md.caption);
        } else if (kind === "location") {
          it.text = `[location] ${m.location?.latitude ?? ""},${m.location?.longitude ?? ""} ${m.location?.name ?? ""}`.trim();
        } else if (kind === "contacts") it.text = "[contact card]";
        if (m.referral) it.referral = { source_url: m.referral.source_url, source_id: m.referral.source_id, source_type: m.referral.source_type,
          headline: m.referral.headline, ctwa_clid: m.referral.ctwa_clid };
        it.payload = { type: kind, ...(it.media ? { media: it.media } : {}), ...(it.referral ? { referral: it.referral } : {}) };
        messages.push(it);
      }
      for (const s of Array.isArray(v.statuses) ? v.statuses : []) {
        if (!s?.id || !s?.status) continue;
        const err = Array.isArray(s.errors) ? s.errors[0] : undefined;
        statuses.push({ wamid: String(s.id), status: String(s.status),
          error_code: err?.code != null ? Number(err.code) : undefined,
          error_text: err ? String(err.error_data?.details ?? err.message ?? err.title ?? "").slice(0, 300) : undefined,
          category: s.pricing?.category ? String(s.pricing.category) : undefined });
      }
    }
  }
  return { messages, statuses };
}

// ------------------------------------------------------------------ sending
export interface Tpl { name: string; language?: string; body?: string; status?: string; category?: string }

export function buildMessage(to: string, item: OutItem, tpl?: Tpl | null, vars: Record<string, string> = {}): Json {
  const base = { messaging_product: "whatsapp", recipient_type: "individual", to };
  switch (item.type) {
    case "text": return { ...base, type: "text", text: { preview_url: false, body: String(item.body).slice(0, 4096) } };
    case "buttons": return { ...base, type: "interactive", interactive: { type: "button", body: { text: String(item.body).slice(0, 1024) },
      action: { buttons: item.buttons.slice(0, 3).map((b) => ({ type: "reply", reply: { id: b.id.slice(0, 256), title: b.title.slice(0, 20) } })) } } };
    case "list": return { ...base, type: "interactive", interactive: { type: "list", body: { text: String(item.body).slice(0, 4096) },
      action: { button: item.button.slice(0, 20), sections: [{ title: "Options", rows: item.rows.slice(0, 10).map((r) => ({ id: r.id.slice(0, 200), title: r.title.slice(0, 24) })) }] } } };
    case "document": return { ...base, type: "document", document: { link: item.link, filename: item.filename, ...(item.caption ? { caption: item.caption.slice(0, 1024) } : {}) } };
    case "template": {
      if (!tpl?.name) throw new Error("Template not found");
      const needsName = /\{\{\s*1\s*\}\}/.test(tpl.body ?? "");
      return { ...base, type: "template", template: { name: tpl.name, language: { code: tpl.language || "en" },
        ...(needsName ? { components: [{ type: "body", parameters: [{ type: "text", text: (vars.name || "there").slice(0, 60) }] }] } : {}) } };
    }
  }
}

// What the chat shows for a sent message.
export function describe(item: OutItem, tpl?: Tpl | null, vars: Record<string, string> = {}): { kind: string; body: string; payload: Json; template_name?: string } {
  switch (item.type) {
    case "template": return { kind: "template", body: String(tpl?.body ?? "").replace(/\{\{\s*1\s*\}\}/g, vars.name || "there"), payload: {}, template_name: tpl?.name };
    case "buttons": return { kind: "buttons", body: item.body, payload: { buttons: item.buttons.map((b) => b.title) } };
    case "list": return { kind: "list", body: item.body, payload: { buttons: item.rows.map((r) => r.title) } };
    case "document": return { kind: "document", body: item.caption || item.filename, payload: { filename: item.filename, link: item.link } };
    default: return { kind: "text", body: item.body, payload: {} };
  }
}

const RETRY_CODES = new Set([1, 2, 4, 17, 341, 80007, 130429, 131000, 131016, 131056, 133004, 133005]);
export function classify(httpStatus: number, code?: number): { retry: boolean } {
  if (code === 131049 || code === 131026 || code === 131047 || code === 190 || code === 100 || code === 368) return { retry: false };
  if (code !== undefined && RETRY_CODES.has(code)) return { retry: true };
  if (code !== undefined && code >= 132000 && code < 133000) return { retry: false };     // template problems
  return { retry: httpStatus === 0 || httpStatus === 429 || httpStatus >= 500 };
}

export type FetchFn = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{ status: number; text(): Promise<string> }>;

export async function graph(fetchFn: FetchFn, version: string, token: string, path: string, method = "GET", body?: Json):
  Promise<{ ok: boolean; status: number; data: Json; code?: number; message?: string }> {
  const url = `https://graph.facebook.com/${version}/${path.replace(/^\//, "")}`;
  let status = 0, txt = "";
  try {
    const r = await fetchFn(url, { method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined });
    status = r.status; txt = await r.text();
  } catch (e) {
    return { ok: false, status: 0, data: {}, message: `Network: ${String((e as Error)?.message ?? e).slice(0, 200)}` };
  }
  let data: Json = {};
  try { data = JSON.parse(txt || "{}"); } catch { data = { raw: txt.slice(0, 200) }; }
  if (status >= 200 && status < 300 && !data.error) return { ok: true, status, data };
  const err = data.error ?? {};
  return { ok: false, status, data, code: err.code != null ? Number(err.code) : undefined,
    message: String(err.error_data?.details || err.message || `HTTP ${status}`).replace(/access_token=[^&\s]+/g, "access_token=***").slice(0, 400) };
}

export async function sendMessage(fetchFn: FetchFn, version: string, token: string, phoneNumberId: string, payload: Json):
  Promise<{ ok: boolean; wamid?: string; code?: number; text?: string; retry: boolean }> {
  const r = await graph(fetchFn, version, token, `${phoneNumberId}/messages`, "POST", payload);
  if (r.ok) {
    const wamid = r.data?.messages?.[0]?.id;
    return wamid ? { ok: true, wamid: String(wamid), retry: false } : { ok: false, text: "Meta did not return a message id", retry: true };
  }
  return { ok: false, code: r.code, text: r.message, retry: classify(r.status, r.code).retry };
}

// Template as Meta's create API wants it.
export function templatePayload(t: { name: string; language?: string; category?: string; body: string; footer?: string | null; buttons?: string[] }): Json {
  const components: Json[] = [];
  const bodyComp: Json = { type: "BODY", text: t.body };
  if (/\{\{\s*1\s*\}\}/.test(t.body)) bodyComp.example = { body_text: [["Rahul"]] };
  components.push(bodyComp);
  if (t.footer) components.push({ type: "FOOTER", text: t.footer.slice(0, 60) });
  if (t.buttons?.length) components.push({ type: "BUTTONS", buttons: t.buttons.slice(0, 3).map((b) => ({ type: "QUICK_REPLY", text: b.slice(0, 25) })) });
  return { name: t.name, language: t.language || "en", category: (t.category || "UTILITY").toUpperCase(), components };
}

// ------------------------------------------------------------------ phone notifications
export interface PushEvent { id: number; kind: string; detail?: Json; conversation_id?: string | null; name?: string | null; brand?: string }
export interface Push { title: string; body: string; url: string; tag: string }
export function pushesFor(events: PushEvent[]): Push[] {
  const one = (e: PushEvent): Push => {
    const who = e.name || "A lead";
    const url = e.conversation_id ? `/#/whatsapp/inbox?c=${e.conversation_id}` : "/#/whatsapp";
    const said = e.detail?.text ? ` "${String(e.detail.text).slice(0, 80)}"` : "";
    const t: Record<string, [string, string]> = {
      handoff: [`💬 ${who} wants a counsellor`, `Open the chat and reply.${said}`],
      counselling_requested: [`📅 ${who} asked for free counselling`, "Call them to fix a time."],
      call_needed: [`📞 Call ${who}`, String(e.detail?.reason ?? "Could not reach them on WhatsApp.")],
      send_failed: [`⚠️ WhatsApp message to ${who} failed`, String(e.detail?.text ?? "Open the chat to see why.")],
      inbound_for_person: [`💬 ${who} replied`, said ? said.trim() : "Open the chat to answer."],
      brochure_missing: ["📄 Brochure link missing", "Add it in WhatsApp > Settings so the bot can send it."],
    };
    const [title, body] = t[e.kind] ?? [`WhatsApp: ${e.kind.replace(/_/g, " ")}`, who];
    return { title: title.slice(0, 90), body: body.slice(0, 180), url, tag: `wa-${e.kind}-${e.conversation_id ?? e.id}` };
  };
  if (events.length > 4) {
    return [{ title: `💬 ${events.length} WhatsApp chats need you`, body: events.slice(0, 4).map((e) => e.name || "Lead").join(" · ").slice(0, 180),
      url: "/#/whatsapp/inbox?f=human", tag: "wa-many" }];
  }
  return events.map(one);
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
