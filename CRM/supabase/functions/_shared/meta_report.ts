// Meta Ads > Reports (migration 105): Ads Manager-style reporting read live from Meta's Insights API and cached in the CRM.
// Pure TypeScript (unit-tested). ads-sync job `meta_report` validates the request, asks Meta (paged), parses the rows and
// caches them; the browser applies breakdown-value filters, columns, sorting and compare.
//
// Meta's limits respected here: breakdowns are kept 13 months and frequency 6 months; unique counts (reach, frequency)
// 13 months; hour and region rows carry no off-Meta actions (instant-form leads are on-Meta, so they still count);
// 7-day / 28-day view attribution is gone (the account's own attribution setting is used, as in Ads Manager).

export const LEVELS = ["account", "campaign", "adset", "ad"] as const;
export type Level = typeof LEVELS[number];

// breakdown id -> Meta parameters. Combinations follow Meta's allowed list.
export const BREAKDOWNS: Record<string, { group: string; label: string; breakdowns?: string; time?: "1" | "7" | "monthly"; months: number; disjoint: boolean }> = {
  day: { group: "Time", label: "Day", time: "1", months: 37, disjoint: true },
  week: { group: "Time", label: "Week", time: "7", months: 37, disjoint: true },
  month: { group: "Time", label: "Month", time: "monthly", months: 37, disjoint: true },
  age: { group: "Demographics", label: "Age", breakdowns: "age", months: 13, disjoint: true },
  gender: { group: "Demographics", label: "Gender", breakdowns: "gender", months: 13, disjoint: true },
  age_gender: { group: "Demographics", label: "Age and gender", breakdowns: "age,gender", months: 13, disjoint: true },
  country: { group: "Geography", label: "Country", breakdowns: "country", months: 13, disjoint: true },
  region: { group: "Geography", label: "Region (state)", breakdowns: "region", months: 13, disjoint: true },
  platform: { group: "Delivery", label: "Platform", breakdowns: "publisher_platform", months: 13, disjoint: false },
  placement: { group: "Delivery", label: "Placement", breakdowns: "publisher_platform,platform_position", months: 13, disjoint: false },
  device: { group: "Delivery", label: "Device (mobile / desktop)", breakdowns: "device_platform", months: 13, disjoint: false },
  platform_device: { group: "Delivery", label: "Platform and device", breakdowns: "publisher_platform,impression_device", months: 13, disjoint: false },
  hour: { group: "Delivery", label: "Time of day (account time zone)", breakdowns: "hourly_stats_aggregated_by_advertiser_time_zone", months: 13, disjoint: false },
  frequency: { group: "Delivery", label: "Times seen (frequency)", breakdowns: "frequency_value", months: 6, disjoint: true },
};

export interface ReportParams {
  level: Level; from: string; to: string; compare: { from: string; to: string } | null; breakdown: string | null;
  campaign_ids: string[]; adset_ids: string[]; ad_ids: string[]; statuses: string[]; name: string;
}
export const STATUSES = ["ACTIVE", "PAUSED", "ARCHIVED", "DELETED", "CAMPAIGN_PAUSED", "ADSET_PAUSED", "DISAPPROVED", "WITH_ISSUES", "IN_PROCESS", "PENDING_REVIEW"];
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ID = /^\d{1,25}$/;
const addDays = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 86400e3).toISOString().slice(0, 10);
export const monthsAgo = (today: string, m: number) => addDays(today, -Math.floor(m * 30.44));

export class ReportError extends Error {}

// Checks and cleans a request; throws ReportError with a plain message.
export function cleanParams(raw: any, today: string): ReportParams {
  const r = raw && typeof raw === "object" ? raw : {};
  const level = LEVELS.includes(r.level) ? r.level : "campaign";
  if (!DATE.test(String(r.from)) || !DATE.test(String(r.to))) throw new ReportError("Pick a date range");
  if (r.from > r.to) throw new ReportError("The start date is after the end date");
  if (r.to > today) throw new ReportError("The end date is in the future");
  if (r.from < monthsAgo(today, 37)) throw new ReportError("Meta keeps 37 months of numbers; pick a later start");
  const breakdown = r.breakdown && BREAKDOWNS[r.breakdown] ? String(r.breakdown) : null;
  if (breakdown && r.from < monthsAgo(today, BREAKDOWNS[breakdown].months))
    throw new ReportError(`Meta keeps the ${BREAKDOWNS[breakdown].label.toLowerCase()} split for ${BREAKDOWNS[breakdown].months} months; pick a later start`);
  let compare: ReportParams["compare"] = null;
  if (r.compare && DATE.test(String(r.compare.from)) && DATE.test(String(r.compare.to)) && r.compare.from <= r.compare.to) {
    if (breakdown && r.compare.from < monthsAgo(today, BREAKDOWNS[breakdown].months)) throw new ReportError("The compare period is older than Meta keeps this split");
    if (r.compare.from < monthsAgo(today, 37)) throw new ReportError("The compare period is older than 37 months");
    compare = { from: r.compare.from, to: r.compare.to };
  }
  const ids = (v: unknown) => (Array.isArray(v) ? v.map(String).filter((x) => ID.test(x)).slice(0, 50) : []);
  return {
    level, from: r.from, to: r.to, compare, breakdown,
    campaign_ids: ids(r.campaign_ids), adset_ids: ids(r.adset_ids), ad_ids: ids(r.ad_ids),
    statuses: Array.isArray(r.statuses) ? r.statuses.filter((s: string) => STATUSES.includes(s)) : [],
    name: String(r.name ?? "").replace(/[^\p{L}\p{N} ._|&+-]/gu, "").trim().slice(0, 60),
  };
}

// The previous period of the same length (Ads Manager's default compare).
export function previousPeriod(from: string, to: string) {
  const days = Math.round((Date.parse(to) - Date.parse(from)) / 86400e3) + 1;
  return { from: addDays(from, -days), to: addDays(from, -1) };
}

const BASE = ["spend", "impressions", "clicks", "inline_link_clicks", "ctr", "inline_link_click_ctr", "cpc", "cpm", "cost_per_inline_link_click", "actions"];
const VIDEO = ["video_play_actions", "video_p25_watched_actions", "video_p50_watched_actions", "video_p75_watched_actions", "video_p100_watched_actions",
  "video_thruplay_watched_actions"];
const NAMES: Record<Level, string[]> = { account: [], campaign: ["campaign_id", "campaign_name", "objective"],
  adset: ["campaign_id", "campaign_name", "adset_id", "adset_name"], ad: ["campaign_id", "campaign_name", "adset_id", "adset_name", "ad_id", "ad_name"] };

export function fieldsFor(p: ReportParams, from: string, today: string): string[] {
  const b = p.breakdown;
  if (b === "frequency") return [...NAMES[p.level], "reach", "impressions", "spend"];
  const f = [...NAMES[p.level], ...BASE, ...VIDEO];
  // unique counts: 13 months, and not with hourly rows
  if (from >= monthsAgo(today, 13) && b !== "hour") f.push("reach", "frequency");
  if (p.level === "ad" && !b) f.push("quality_ranking", "engagement_rate_ranking", "conversion_rate_ranking");
  return f;
}

// Query string values for GET act_<id>/insights (one period).
export function insightsQuery(p: ReportParams, period: { from: string; to: string }, today: string, totals = false): Record<string, string> {
  const q: Record<string, string> = {
    level: totals ? "account" : p.level,
    fields: (totals ? fieldsFor({ ...p, level: "account", breakdown: null }, period.from, today) : fieldsFor(p, period.from, today)).join(","),
    time_range: JSON.stringify({ since: period.from, until: period.to }), limit: "500",
  };
  const bd = !totals && p.breakdown ? BREAKDOWNS[p.breakdown] : null;
  if (bd?.breakdowns) q.breakdowns = bd.breakdowns;
  if (bd?.time) q.time_increment = bd.time;
  const filtering: { field: string; operator: string; value: unknown }[] = [];
  if (p.campaign_ids.length) filtering.push({ field: "campaign.id", operator: "IN", value: p.campaign_ids });
  if (p.adset_ids.length) filtering.push({ field: "adset.id", operator: "IN", value: p.adset_ids });
  if (p.ad_ids.length) filtering.push({ field: "ad.id", operator: "IN", value: p.ad_ids });
  if (p.statuses.length) filtering.push({ field: `${p.level === "account" ? "campaign" : p.level}.effective_status`, operator: "IN", value: p.statuses });
  if (p.name) filtering.push({ field: `${p.level === "account" ? "campaign" : p.level}.name`, operator: "CONTAIN", value: p.name });
  if (filtering.length) q.filtering = JSON.stringify(filtering);
  return q;
}

const n = (v: unknown) => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
const act = (list: any, types: string[]) => (Array.isArray(list) ? list : []).filter((a) => types.includes(a?.action_type)).reduce((s, a) => s + n(a.value), 0);
const first = (list: any) => (Array.isArray(list) && list.length ? n(list[0].value) : 0);
const LEAD_TYPES = ["lead", "onsite_conversion.lead_grouped", "leadgen_grouped"];

export interface Row {
  key: string; label: string; id: string | null; campaign_id?: string; campaign_name?: string; adset_id?: string; adset_name?: string;
  ad_id?: string; ad_name?: string; objective?: string; dims: Record<string, string>;
  spend: number; impressions: number; reach: number | null; frequency: number | null; clicks: number; link_clicks: number;
  leads: number; video_3s: number; p25: number; p50: number; p75: number; p100: number; thruplay: number;
  quality?: string; engagement?: string; conversion?: string;
}

const HOUR = (v: string) => String(v ?? "").slice(0, 5);
export function dimsOf(raw: any, p: ReportParams): Record<string, string> {
  const d: Record<string, string> = {};
  switch (p.breakdown) {
    case "day": case "week": case "month": d.period = p.breakdown === "month" ? String(raw.date_start).slice(0, 7) : String(raw.date_start); break;
    case "age": d.age = raw.age; break;
    case "gender": d.gender = raw.gender; break;
    case "age_gender": d.age = raw.age; d.gender = raw.gender; break;
    case "country": d.country = raw.country; break;
    case "region": d.region = raw.region; break;
    case "platform": d.platform = raw.publisher_platform; break;
    case "placement": d.platform = raw.publisher_platform; d.placement = raw.platform_position; break;
    case "device": d.device = raw.device_platform; break;
    case "platform_device": d.platform = raw.publisher_platform; d.device = raw.impression_device; break;
    case "hour": d.hour = HOUR(raw.hourly_stats_aggregated_by_advertiser_time_zone); break;
    case "frequency": d.frequency = String(raw.frequency_value); break;
  }
  for (const k of Object.keys(d)) d[k] = String(d[k] ?? "unknown");
  return d;
}

export function parseRow(raw: any, p: ReportParams): Row {
  const id = p.level === "ad" ? raw.ad_id : p.level === "adset" ? raw.adset_id : p.level === "campaign" ? raw.campaign_id : null;
  const label = p.level === "ad" ? raw.ad_name : p.level === "adset" ? raw.adset_name : p.level === "campaign" ? raw.campaign_name : "Whole account";
  const dims = dimsOf(raw, p);
  const reach = raw.reach === undefined ? null : n(raw.reach);
  return {
    key: [id ?? "account", ...Object.values(dims)].join("|"), label: String(label ?? id ?? ""), id: id ? String(id) : null,
    ...(raw.campaign_id ? { campaign_id: String(raw.campaign_id), campaign_name: raw.campaign_name } : {}),
    ...(raw.adset_id ? { adset_id: String(raw.adset_id), adset_name: raw.adset_name } : {}),
    ...(raw.ad_id ? { ad_id: String(raw.ad_id), ad_name: raw.ad_name } : {}),
    ...(raw.objective ? { objective: raw.objective } : {}), dims,
    spend: n(raw.spend), impressions: n(raw.impressions), reach, frequency: raw.frequency === undefined ? (p.breakdown === "frequency" ? n(raw.frequency_value) : null) : n(raw.frequency),
    clicks: n(raw.clicks), link_clicks: n(raw.inline_link_clicks), leads: act(raw.actions, LEAD_TYPES),
    video_3s: act(raw.actions, ["video_view"]) || first(raw.video_play_actions), p25: first(raw.video_p25_watched_actions), p50: first(raw.video_p50_watched_actions),
    p75: first(raw.video_p75_watched_actions), p100: first(raw.video_p100_watched_actions), thruplay: first(raw.video_thruplay_watched_actions),
    ...(raw.quality_ranking ? { quality: raw.quality_ranking, engagement: raw.engagement_rate_ranking, conversion: raw.conversion_rate_ranking } : {}),
  };
}

// Sums rows (for totals after the browser filters breakdown values). Reach adds up only across disjoint splits.
export function sumRows(rows: Row[], disjoint: boolean): Omit<Row, "key" | "label" | "id" | "dims"> {
  const t: any = { spend: 0, impressions: 0, clicks: 0, link_clicks: 0, leads: 0, video_3s: 0, p25: 0, p50: 0, p75: 0, p100: 0, thruplay: 0, reach: 0 };
  let reachKnown = disjoint;
  for (const r of rows) {
    for (const k of ["spend", "impressions", "clicks", "link_clicks", "leads", "video_3s", "p25", "p50", "p75", "p100", "thruplay"]) t[k] += (r as any)[k] ?? 0;
    if (r.reach === null) reachKnown = false; else t.reach += r.reach;
  }
  t.reach = reachKnown && rows.length ? t.reach : null;
  t.frequency = t.reach ? t.impressions / t.reach : null;
  return t;
}

// Derived metrics, the same formulas Ads Manager uses.
export function derived(r: { spend: number; impressions: number; clicks: number; link_clicks: number; leads: number; video_3s: number; thruplay: number; reach?: number | null }) {
  const div = (a: number, b: number) => (b > 0 ? a / b : null);
  return {
    ctr: div(r.clicks * 100, r.impressions), link_ctr: div(r.link_clicks * 100, r.impressions), cpc: div(r.spend, r.clicks),
    cplc: div(r.spend, r.link_clicks), cpm: div(r.spend * 1000, r.impressions), cpl: div(r.spend, r.leads),
    lead_rate: div(r.leads * 100, r.link_clicks), hook: div(r.video_3s * 100, r.impressions), hold: div(r.thruplay * 100, r.video_3s),
    cpr: r.reach ? div(r.spend * 1000, r.reach) : null,
  };
}

// How long a cached answer stays fresh: recent days change (late conversions, today's spend), old ones do not.
export const cacheHours = (p: ReportParams, today: string) =>
  (p.to >= addDays(today, -2) || (p.compare && p.compare.to >= addDays(today, -2)) ? 3 : 24 * 7);

export async function cacheKey(p: ReportParams, account: string) {
  const s = JSON.stringify({ a: account, ...p, campaign_ids: [...p.campaign_ids].sort(), adset_ids: [...p.adset_ids].sort(),
    ad_ids: [...p.ad_ids].sort(), statuses: [...p.statuses].sort() });
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
