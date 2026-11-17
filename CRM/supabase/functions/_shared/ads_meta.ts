// ADS <-> Meta lead signals: webhook parsing, lead -> ADS intake payload, and Conversions API event builders.
// Pure TypeScript (no Deno APIs, no network) so every rule here is unit-tested. Contact details arrive already
// SHA-256 hashed from the database (svc_ads_meta_capi_work); nothing in this file sees a raw phone number or email
// except metaLeadPayload / ctwaPayload, which only hand them to the ADS intake.
//
// Meta references (checked 16 Nov 2026):
//   Webhooks: X-Hub-Signature-256 = "sha256=" + HMAC-SHA256(raw body, App Secret); retries for up to 36 hours;
//             up to 1000 updates per batch.            https://developers.facebook.com/docs/graph-api/webhooks/getting-started
//   Leadgen:  change value {leadgen_id, page_id, form_id, adgroup_id, ad_id, created_time}.
//   CAPI for CRM (Conversion Leads): action_source "system_generated", custom_data.event_source "crm",
//             custom_data.lead_event_source = the CRM's name, user_data.lead_id = the 15-17 digit lead id (a number),
//             event_time in seconds, at most 7 days old.
//   Website events: action_source "website", event_source_url and client_user_agent required, fbc = fb.1.<ms>.<fbclid> (unhashed).
//   Business messaging: action_source "business_messaging", messaging_channel "whatsapp",
//             user_data {whatsapp_business_account_id, ctwa_clid}; event names from Meta's list.

export type MetaSource = "instant_form" | "website" | "ctwa";

// Build stamp of the ADS Edge Functions. The Setup checklist compares it to see whether each function was redeployed.
export const ADS_BUILD = "2026-11-17.meta2";

// Reads what a deploy check got back. Supabase answers 404 NOT_FOUND for a function that is not deployed.
export function deployState(status: number, body: string, wantBuild?: string): "current" | "old" | "missing" | "unknown" {
  if (status === 404 && /NOT_FOUND|not found|Requested function was not found/i.test(body) && !/"detail"/.test(body)) return "missing";
  if (wantBuild) {
    try { const j = JSON.parse(body); if (j?.build === wantBuild) return "current"; } catch { /* not JSON */ }
    return status >= 500 ? "unknown" : "old";
  }
  return status >= 200 && status < 500 ? "current" : "unknown";
}

export const WEBSITE_EVENTS = ["Lead", "Contact", "Schedule", "SubmitApplication", "CompleteRegistration"];
export const CTWA_EVENTS = ["LeadSubmitted", "QualifiedLead"];
export const MAX_EVENT_AGE_S = 7 * 86_400;

// ------------------------------------------------------------------ webhook
const hex = /^[0-9a-f]{64}$/;
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// header is the raw X-Hub-Signature-256 value. hmac(key, msg) returns lowercase hex.
export async function verifySignature(appSecret: string | undefined | null, rawBody: string, header: string | null,
  hmac: (key: string, msg: string) => Promise<string>): Promise<boolean> {
  if (!appSecret || !header) return false;
  const m = /^sha256=([0-9a-fA-F]{64})$/.exec(header.trim());
  if (!m) return false;
  const want = (await hmac(appSecret, rawBody)).toLowerCase();
  return hex.test(want) && safeEqual(want, m[1].toLowerCase());
}

export interface RawItem {
  source: "instant_form" | "ctwa"; external_id: string;
  page_id?: string | null; form_id?: string | null; ad_id?: string | null; adgroup_id?: string | null;
  created_time?: string | number | null;
  payload?: { name?: string | null; phone?: string | null; waba_id?: string | null; source_url?: string | null; headline?: string | null };
}

const idStr = (v: unknown): string | null => (v === null || v === undefined || v === "" ? null : String(v));

// Turns one webhook delivery into raw lead rows. Anything that is not a leadgen change or a WhatsApp message carrying an
// ad referral (ctwa_clid) is ignored. Never throws on odd input.
export function parseWebhook(body: unknown): RawItem[] {
  const out: RawItem[] = [];
  const b = body as any;
  if (!b || typeof b !== "object" || !Array.isArray(b.entry)) return out;
  for (const e of b.entry) {
    for (const c of Array.isArray(e?.changes) ? e.changes : []) {
      const v = c?.value;
      if (!v || typeof v !== "object") continue;
      if (b.object === "page" && c.field === "leadgen" && idStr(v.leadgen_id)) {
        out.push({ source: "instant_form", external_id: String(v.leadgen_id), page_id: idStr(v.page_id ?? e.id), form_id: idStr(v.form_id),
          ad_id: idStr(v.ad_id), adgroup_id: idStr(v.adgroup_id), created_time: v.created_time ?? null });
      } else if (b.object === "whatsapp_business_account" && c.field === "messages" && Array.isArray(v.messages)) {
        const names = new Map<string, string>();
        for (const ct of Array.isArray(v.contacts) ? v.contacts : []) if (ct?.wa_id) names.set(String(ct.wa_id), String(ct?.profile?.name ?? ""));
        for (const m of v.messages) {
          const r = m?.referral;
          const clid = idStr(r?.ctwa_clid);
          if (!clid || !m?.from) continue;
          out.push({ source: "ctwa", external_id: clid, ad_id: r?.source_type === "ad" ? idStr(r?.source_id) : null,
            created_time: m.timestamp ?? null,
            payload: { name: names.get(String(m.from)) || null, phone: String(m.from), waba_id: idStr(e?.id),
              source_url: r?.source_url ?? null, headline: r?.headline ?? null } });
        }
      }
    }
  }
  return out;
}

// ------------------------------------------------------------------ Meta lead -> ADS intake payload
const YES = /^(yes|y|true|1|agree|i agree|accept|accepted|ok|haan|ha)$/i;
const NO = /^(no|n|false|0|disagree|decline|declined|nahi|na)$/i;

export function answers(lead: any): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of Array.isArray(lead?.field_data) ? lead.field_data : []) {
    if (!f?.name) continue;
    out[String(f.name)] = Array.isArray(f.values) ? f.values.map(String).join(", ") : String(f.values ?? "");
  }
  return out;
}

// The consent answer for the configured question: a form question (yes/no) or an optional consent checkbox
// (custom_disclaimer_responses). undefined = the form did not ask.
export function consentAnswer(lead: any, field: string | null | undefined): boolean | undefined {
  if (!field) return undefined;
  for (const d of Array.isArray(lead?.custom_disclaimer_responses) ? lead.custom_disclaimer_responses : []) {
    if (d?.checkbox_key === field) return d.is_checked === true || d.is_checked === "1" || d.is_checked === 1;
  }
  const a = answers(lead)[field];
  if (a === undefined) return undefined;
  if (YES.test(a.trim())) return true;
  if (NO.test(a.trim())) return false;
  return undefined;
}

const iso = (t: unknown): string | null => {
  if (t === null || t === undefined || t === "") return null;
  const d = typeof t === "number" || /^\d{9,11}$/.test(String(t)) ? new Date(Number(t) * 1000) : new Date(String(t));
  return Number.isNaN(d.getTime()) ? null : d.toISOString().replace(/\.\d{3}Z$/, "Z");
};

const KNOWN = new Set(["full_name", "first_name", "last_name", "phone_number", "phone", "email", "course_interest", "course"]);

export function metaLeadPayload(lead: any, opts: { consentField?: string | null; consentPurpose?: "ad_data_sharing" | "marketing" }): Record<string, unknown> {
  const a = answers(lead);
  const name = a.full_name || [a.first_name, a.last_name].filter(Boolean).join(" ") || null;
  const at = iso(lead?.created_time);
  const ft: Record<string, unknown> = { utm_source: "facebook", utm_medium: "paid_social", meta_source: "instant_form",
    leadgen_id: String(lead.id), form_id: idStr(lead.form_id), ad_id: idStr(lead.ad_id), adset_id: idStr(lead.adset_id),
    utm_campaignid: idStr(lead.campaign_id), meta_platform: idStr(lead.platform), at };
  const consent: Record<string, unknown> = { notice_version: "meta_instant_form" };
  const c = consentAnswer(lead, opts.consentField);
  if (c !== undefined) consent[opts.consentPurpose ?? "ad_data_sharing"] = c;
  const extra = Object.fromEntries(Object.entries(a).filter(([k]) => !KNOWN.has(k) && k !== opts.consentField).slice(0, 30)
    .map(([k, v]) => [k.slice(0, 80), v.slice(0, 500)]));
  return stripNull({ name, phone: a.phone_number || a.phone || null, email: a.email || null,
    course_interest: a.course_interest || a.course || null, submission_id: `meta-lead-${lead.id}`,
    utm_source: "facebook", utm_medium: "paid_social", site: "facebook.com", touch_at: at,
    first_touch: stripNull(ft), consent, meta_answers: Object.keys(extra).length ? extra : null });
}

// Meta's Lead Ads Testing Tool fills every answer with "test lead: dummy data for <field>" (some versions wrap it
// in < >). Such a lead proves the path works; it is never filed as a lead.
const TEST_VALUE = /^<?\s*test lead\s*:\s*dummy data/i;
export function isTestLead(lead: any): boolean {
  const vals = Object.values(answers(lead));
  return vals.length > 0 && vals.some((v) => TEST_VALUE.test(v.trim()));
}

// A form filled without an ad (opened from the Page): a normal CRM lead, not an Ads lead (migration 101).
// utm_campaign is filled in by the database with the form's name.
export function organicPayload(lead: any): Record<string, unknown> {
  const a = answers(lead);
  const name = a.full_name || [a.first_name, a.last_name].filter(Boolean).join(" ") || null;
  const extra = Object.fromEntries(Object.entries(a).filter(([k]) => !KNOWN.has(k)).slice(0, 30)
    .map(([k, v]) => [k.slice(0, 80), v.slice(0, 500)]));
  return stripNull({ name, phone: a.phone_number || a.phone || null, email: a.email || null,
    course_interest: a.course_interest || a.course || null, utm_source: "Meta lead form", utm_medium: "organic",
    meta_answers: Object.keys(extra).length ? extra : null });
}

export function ctwaPayload(item: { external_id: string; ad_id?: string | null; created_time?: string | null;
  payload?: { name?: string | null; phone?: string | null; waba_id?: string | null; source_url?: string | null; headline?: string | null } }): Record<string, unknown> {
  const p = item.payload ?? {};
  const at = iso(item.created_time);
  return stripNull({ name: p.name || null, phone: p.phone || null, submission_id: `meta-ctwa-${item.external_id}`,
    utm_source: "facebook", utm_medium: "paid_social", site: "wa.me", touch_at: at,
    first_touch: stripNull({ utm_source: "facebook", utm_medium: "paid_social", meta_source: "ctwa", ctwa_clid: item.external_id,
      ad_id: item.ad_id ?? null, waba_id: p.waba_id ?? null, source_url: p.source_url ?? null, at }),
    consent: { notice_version: "meta_ctwa" } });
}

function stripNull<T extends Record<string, unknown>>(o: T): T {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined && v !== "")) as T;
}

// ------------------------------------------------------------------ Conversions API events
export interface CapiItem {
  id: number; source: MetaSource; event_name: string; event_id: string; event_time: number;
  lead_id?: string | null; ctwa_clid?: string | null; waba_id?: string | null;
  fbc?: string | null; event_source_url?: string | null; client_user_agent?: string | null;
  em?: string | null; ph?: string | null;           // SHA-256 hex, from the database
}
export class EventError extends Error {}

const hashes = (v?: string | null) => (v && hex.test(v) ? [v] : undefined);
function fresh(t: number, now: number) {
  if (!Number.isInteger(t) || t <= 0) throw new EventError("event_time is not a Unix time in seconds");
  if (t > now + 300) throw new EventError("event_time is in the future");
  if (now - t > MAX_EVENT_AGE_S) throw new EventError("Older than 7 days; Meta discards events that old");
}

export function crmEvent(it: CapiItem, crmName: string, now = Math.floor(Date.now() / 1000)): Record<string, unknown> {
  fresh(it.event_time, now);
  if (!/^[A-Za-z0-9][A-Za-z0-9 _\-]{0,49}$/.test(it.event_name)) throw new EventError("Invalid CRM event name");
  if (!it.lead_id || !/^\d{5,25}$/.test(it.lead_id)) throw new EventError("No Meta lead id for this lead");
  const user_data: Record<string, unknown> = { lead_id: it.lead_id };
  if (hashes(it.em)) user_data.em = hashes(it.em);
  if (hashes(it.ph)) user_data.ph = hashes(it.ph);
  return { event_name: it.event_name, event_time: it.event_time, action_source: "system_generated", user_data,
    custom_data: { event_source: "crm", lead_event_source: crmName || "We One CRM" } };
}

export function webEvent(it: CapiItem, now = Math.floor(Date.now() / 1000)): Record<string, unknown> {
  fresh(it.event_time, now);
  if (!WEBSITE_EVENTS.includes(it.event_name)) throw new EventError(`Website event must be one of ${WEBSITE_EVENTS.join(", ")}`);
  if (!it.event_source_url || !/^https?:\/\//.test(it.event_source_url)) throw new EventError("No page address for this enquiry");
  if (!it.client_user_agent) throw new EventError("No browser details for this enquiry");
  if (!it.fbc || !/^fb\.\d\.\d{10,13}\.\S+$/.test(it.fbc)) throw new EventError("No Meta click id (fbclid) for this enquiry");
  const user_data: Record<string, unknown> = { fbc: it.fbc, client_user_agent: it.client_user_agent };
  if (hashes(it.em)) user_data.em = hashes(it.em);
  if (hashes(it.ph)) user_data.ph = hashes(it.ph);
  return { event_name: it.event_name, event_time: it.event_time, event_id: it.event_id, action_source: "website",
    event_source_url: it.event_source_url, user_data };
}

export function messagingEvent(it: CapiItem, now = Math.floor(Date.now() / 1000)): Record<string, unknown> {
  fresh(it.event_time, now);
  if (!CTWA_EVENTS.includes(it.event_name)) throw new EventError(`WhatsApp event must be one of ${CTWA_EVENTS.join(", ")}`);
  if (!it.waba_id || !/^\d{5,25}$/.test(it.waba_id)) throw new EventError("WhatsApp Business Account id is not set");
  if (!it.ctwa_clid) throw new EventError("No WhatsApp ad click id (ctwa_clid) for this lead");
  return { event_name: it.event_name, event_time: it.event_time, event_id: it.event_id, action_source: "business_messaging",
    messaging_channel: "whatsapp", user_data: { whatsapp_business_account_id: it.waba_id, ctwa_clid: it.ctwa_clid } };
}

export function buildEvent(it: CapiItem, crmName: string, now?: number): Record<string, unknown> {
  return it.source === "instant_form" ? crmEvent(it, crmName, now) : it.source === "website" ? webEvent(it, now) : messagingEvent(it, now);
}

// Meta's example sends lead_id as a JSON number. A 16-17 digit id does not fit in a JS number without losing digits,
// so it is written into the JSON text as digits directly (the builders guarantee digits only).
export function serializeEvents(events: Record<string, unknown>[]): string {
  return JSON.stringify(events).replace(/"lead_id":"(\d{5,25})"/g, '"lead_id":$1');
}
