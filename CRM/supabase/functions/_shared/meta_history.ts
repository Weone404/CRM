// Meta Ads history for Meta Ads > Insights (migration 103): turns Graph API rows into what the database stores.
// Pure TypeScript (no Deno APIs, no network), unit-tested. Read-only: nothing here changes an ad.
//
// Meta references (checked 17 Nov 2026):
//   Insights keep totals for 37 months; breakdowns of unique counts and hourly breakdowns 13 months; frequency_value
//   breakdowns 6 months (Ads Insights API metric availability update, effective 12 Jan 2026).
//   https://developers.facebook.com/blog/post/2025/10/16/ads-insights-api-metric-availability-updates/

export interface ObjRow {
  level: "campaign" | "adset" | "ad"; external_id: string; campaign_ext?: string | null; adset_ext?: string | null;
  name?: string | null; status?: string | null; created_time?: string | null; info?: Record<string, unknown>;
}
export interface DayRow {
  ad_ext: string; adset_ext: string | null; campaign_ext: string | null; day: string;
  spend: number; impressions: number; clicks: number; link_clicks: number | null; leads: number; video_views: number | null;
  frequency: number | null;
}
export type BreakdownKind = "age_gender" | "region" | "placement" | "device" | "hour" | "frequency";
export interface BRow { month: string; k1: string; k2: string; spend: number; impressions: number; clicks: number; leads: number }

// All statuses except DELETED (Meta does not list deleted objects; their numbers still arrive by name in insights).
export const META_STATUSES = ["ACTIVE", "PAUSED", "ARCHIVED", "CAMPAIGN_PAUSED", "ADSET_PAUSED", "PENDING_REVIEW", "DISAPPROVED",
  "PREAPPROVED", "PENDING_BILLING_INFO", "IN_PROCESS", "WITH_ISSUES"];

// Account-level breakdowns, and how many months back Meta keeps each.
export const BREAKDOWNS: { kind: BreakdownKind; breakdowns: string; months: number }[] = [
  { kind: "age_gender", breakdowns: "age,gender", months: 13 },
  { kind: "region", breakdowns: "region", months: 13 },
  { kind: "placement", breakdowns: "publisher_platform,platform_position", months: 13 },
  { kind: "device", breakdowns: "device_platform", months: 13 },
  { kind: "hour", breakdowns: "hourly_stats_aggregated_by_advertiser_time_zone", months: 13 },
  { kind: "frequency", breakdowns: "frequency_value", months: 6 },
];

const num = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const id = (v: unknown): string | null => (v !== null && v !== undefined && /^\d{3,25}$/.test(String(v)) ? String(v) : null);
const pick = (list: unknown, type: string): number | null => {
  if (!Array.isArray(list)) return null;
  const a = list.find((x: any) => x?.action_type === type);
  return a ? num((a as any).value) : null;
};

// Leads Meta counted: "lead" is the total (forms + website); older accounts report only the parts.
export function metaLeadCount(actions: unknown): number {
  const total = pick(actions, "lead");
  if (total !== null) return total;
  const parts = (pick(actions, "onsite_conversion.lead_grouped") ?? pick(actions, "leadgen_grouped") ?? 0)
    + (pick(actions, "offsite_conversion.fb_pixel_lead") ?? 0);
  return parts;
}

const GENDER: Record<string, string> = { "1": "male", "2": "female" };
export function parseAdset(r: any): ObjRow {
  const t = r?.targeting ?? {};
  const geo = t.geo_locations ?? {};
  const names = (xs: unknown) => (Array.isArray(xs) ? xs.map((x: any) => String(x?.name ?? x?.key ?? x)).filter(Boolean).slice(0, 10) : []);
  return {
    level: "adset", external_id: String(r.id), campaign_ext: id(r.campaign_id), name: r.name ?? null,
    status: r.effective_status ?? r.status ?? null, created_time: r.created_time ?? null,
    info: {
      goal: r.optimization_goal ?? null,
      age_min: num(t.age_min), age_max: num(t.age_max),
      genders: Array.isArray(t.genders) && t.genders.length ? t.genders.map((g: unknown) => GENDER[String(g)] ?? String(g)) : ["all"],
      countries: Array.isArray(geo.countries) ? geo.countries.slice(0, 10) : [],
      regions: names(geo.regions), cities: names(geo.cities),
      interests: (t.flexible_spec ?? []).reduce((n: number, s: any) => n + (Array.isArray(s?.interests) ? s.interests.length : 0), 0),
      custom_audiences: Array.isArray(t.custom_audiences) && t.custom_audiences.length > 0,
      lookalike: Array.isArray(t.custom_audiences) && t.custom_audiences.some((c: any) => /lookalike/i.test(String(c?.name ?? ""))),
      advantage: Number(t.targeting_automation?.advantage_audience) === 1,
    },
  };
}

// The creative of an ad: format, headline, main text, call to action, thumbnail and the lead form it opens.
export function creativeInfo(c: any): Record<string, unknown> {
  const s = c?.object_story_spec ?? {};
  const link = s.link_data ?? {}, video = s.video_data ?? {}, feed = c?.asset_feed_spec ?? {};
  const format = feed && Object.keys(feed).length ? "dynamic"
    : c?.video_id || s.video_data ? "video"
    : Array.isArray(link.child_attachments) && link.child_attachments.length ? "carousel"
    : (String(c?.object_type ?? "").toUpperCase() === "VIDEO") ? "video" : "image";
  const first = (xs: unknown) => (Array.isArray(xs) && xs.length ? String((xs[0] as any)?.text ?? "") : null);
  const body = c?.body ?? link.message ?? video.message ?? first(feed.bodies) ?? null;
  const title = c?.title ?? link.name ?? video.title ?? first(feed.titles) ?? null;
  const cta = c?.call_to_action_type ?? link.call_to_action?.type ?? video.call_to_action?.type
    ?? (Array.isArray(feed.call_to_action_types) ? feed.call_to_action_types[0] : null) ?? null;
  const form = id(link.call_to_action?.value?.lead_gen_form_id) ?? id(video.call_to_action?.value?.lead_gen_form_id)
    ?? id(c?.lead_gen_form_id) ?? null;
  return {
    format, title: title ? String(title).slice(0, 200) : null, body: body ? String(body).slice(0, 600) : null,
    cta: cta ? String(cta) : null, thumbnail_url: c?.thumbnail_url ?? c?.image_url ?? null, form_id: form,
    link: link.link ?? video.call_to_action?.value?.link ?? null,
  };
}

export function parseAd(r: any): ObjRow {
  return {
    level: "ad", external_id: String(r.id), campaign_ext: id(r.campaign_id), adset_ext: id(r.adset_id), name: r.name ?? null,
    status: r.effective_status ?? r.status ?? null, created_time: r.created_time ?? null, info: creativeInfo(r.creative),
  };
}

export function parseCampaign(r: any): ObjRow {
  return { level: "campaign", external_id: String(r.id), name: r.name ?? null, status: r.effective_status ?? r.status ?? null,
    created_time: r.created_time ?? null, info: { objective: r.objective ?? null } };
}

export function parseAdDay(r: any): DayRow | null {
  const ad = id(r?.ad_id);
  if (!ad || !/^\d{4}-\d{2}-\d{2}$/.test(String(r?.date_start))) return null;
  return {
    ad_ext: ad, adset_ext: id(r.adset_id), campaign_ext: id(r.campaign_id), day: r.date_start,
    spend: num(r.spend) ?? 0, impressions: num(r.impressions) ?? 0, clicks: num(r.clicks) ?? 0,
    link_clicks: num(r.inline_link_clicks), leads: metaLeadCount(r.actions),
    video_views: pick(r.actions, "video_view"), frequency: num(r.frequency),
  };
}

// Names that arrive with the numbers (also for deleted ads, which Meta no longer lists).
export function namesFromDays(rows: any[]): ObjRow[] {
  const out = new Map<string, ObjRow>();
  for (const r of rows) {
    const c = id(r?.campaign_id), s = id(r?.adset_id), a = id(r?.ad_id);
    if (c && !out.has(`c${c}`)) out.set(`c${c}`, { level: "campaign", external_id: c, name: r.campaign_name ?? null });
    if (s && !out.has(`s${s}`)) out.set(`s${s}`, { level: "adset", external_id: s, campaign_ext: c, name: r.adset_name ?? null });
    if (a && !out.has(`a${a}`)) out.set(`a${a}`, { level: "ad", external_id: a, campaign_ext: c, adset_ext: s, name: r.ad_name ?? null });
  }
  return [...out.values()];
}

export function parseBreakdown(kind: BreakdownKind, r: any): BRow | null {
  const month = String(r?.date_start ?? "").slice(0, 7);
  if (!/^\d{4}-\d{2}$/.test(month)) return null;
  let k1 = "", k2 = "";
  switch (kind) {
    case "age_gender": k1 = r.age ?? ""; k2 = r.gender ?? ""; break;
    case "region": k1 = r.region ?? ""; break;
    case "placement": k1 = r.publisher_platform ?? ""; k2 = r.platform_position ?? ""; break;
    case "device": k1 = r.device_platform ?? ""; break;
    case "hour": k1 = String(r.hourly_stats_aggregated_by_advertiser_time_zone ?? "").slice(0, 2); break;
    case "frequency": k1 = r.frequency_value ?? ""; break;
  }
  if (!k1) return null;
  return { month: `${month}-01`, k1: String(k1), k2: String(k2), spend: num(r.spend) ?? 0, impressions: num(r.impressions) ?? 0,
    clicks: num(r.clicks) ?? 0, leads: metaLeadCount(r.actions) };
}

// Month-by-month ranges from the cursor (a first-of-month date) up to today.
export function monthChunks(cursor: string, today: string): { since: string; until: string; next: string }[] {
  const out: { since: string; until: string; next: string }[] = [];
  let y = Number(cursor.slice(0, 4)), m = Number(cursor.slice(5, 7));
  for (let i = 0; i < 48; i++) {
    const since = `${y}-${String(m).padStart(2, "0")}-01`;
    if (since > today) break;
    const ny = m === 12 ? y + 1 : y, nm = m === 12 ? 1 : m + 1;
    const next = `${ny}-${String(nm).padStart(2, "0")}-01`;
    const last = new Date(Date.UTC(ny, nm - 1, 0)).toISOString().slice(0, 10);
    out.push({ since, until: last < today ? last : today, next });
    y = ny; m = nm;
  }
  return out;
}

// First day of the month `months - 1` months before today's month.
export function monthsBack(today: string, months: number): string {
  const d = new Date(Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 1 - (months - 1), 1));
  return d.toISOString().slice(0, 10);
}
