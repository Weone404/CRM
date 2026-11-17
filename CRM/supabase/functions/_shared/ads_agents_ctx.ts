// Shapes the account context for the ADS agents (pure TypeScript, unit-tested).
import { findPatterns } from "./meta_patterns.ts";
// Big snapshot lists become compact tables ({columns, rows}) with only the rows that matter most, and repeated
// resource names are dropped (ids are kept; the resource names the agents must quote for changes are kept).

const LIMITS: Record<string, number> = { search_terms_30d: 250, search_terms_365d: 300, shared_negatives: 400, keywords: 300, keyword_ideas: 150, ads: 12 };
const KEEP_RN = ["adGroupCriterion.resourceName", "adGroupAd.resourceName", "customerAsset.resourceName", "campaignAsset.resourceName"];
const ENABLED_ONLY = new Set(["campaign_assets", "locations"]);   // paused campaigns' links are noise for the agents

export function trimContext(ctx: any) {
  const snap = ctx?.snapshot ?? {};
  const enabled = new Set(((ctx?.campaigns ?? []) as any[]).filter((c) => c.status === "ENABLED").map((c) => String(c.id)));
  for (const [k, raw] of Object.entries(snap)) {
    if (!Array.isArray(raw)) continue;
    let rows = raw as any[];
    if (ENABLED_ONLY.has(k)) rows = rows.filter((r) => enabled.has(String(r?.["campaign.id"])));
    if (k === "ads") rows = [...rows].sort((a, b) => Number(enabled.has(String(b?.["campaign.id"]))) - Number(enabled.has(String(a?.["campaign.id"]))));
    if (rows.some((r) => r && "metrics.costMicros" in r)) rows = [...rows].sort((a, b) => Number(b["metrics.costMicros"] ?? 0) - Number(a["metrics.costMicros"] ?? 0));
    const lim = LIMITS[k] ?? 200;
    const kept = rows.slice(0, lim).map((r) => {
      const o: Record<string, unknown> = {};
      for (const [f, v] of Object.entries(r ?? {})) {
        if (f.endsWith(".resourceName") && !KEEP_RN.includes(f)) continue;
        if (f === "metrics.costMicros") o["cost_inr"] = Math.round(Number(v ?? 0) / 1e4) / 100;
        else o[f] = v;
      }
      return o;
    });
    const columns = [...new Set(kept.flatMap((o) => Object.keys(o)))];
    snap[k] = { columns, rows: kept.map((o) => columns.map((c) => (c in o ? o[c] : null))) };
    if (rows.length > lim) snap[k].more_rows_not_shown = rows.length - lim;
  }
  return ctx;
}

// Meta strategy steps (migration 104): the 37-month Insights data, cut to what a planner reads, plus the proven
// patterns the CRM itself computes (same engine as Meta Ads > Insights), so every agent starts from the same facts.

const pick = (o: any, keys: string[]) => Object.fromEntries(keys.filter((k) => o?.[k] !== undefined && o?.[k] !== null && o?.[k] !== "").map((k) => [k, o[k]]));
const ROW = ["ext", "name", "status", "spend", "impressions", "clicks", "link_clicks", "meta_leads", "crm_leads", "qualified", "customers",
  "first_day", "last_day", "objective", "campaign_ext", "adset_ext", "days", "video_views"];
const AD_INFO = ["format", "title", "body", "cta", "form_id", "link", "video_id"];
const ADSET_INFO = ["goal", "age_min", "age_max", "genders", "countries", "regions", "cities", "interests", "custom_audiences",
  "lookalike", "advantage"];
export const META_LIMITS = { campaign: 60, adset: 40, ad: 40, text: 600 };

export function trimMetaContext(ctx: any) {
  const ins = ctx?.insights;
  if (!ins || typeof ins !== "object") return ctx;
  let patterns: unknown = [];
  let goal: string | null = null, baseline: number | null = null;
  try {
    const r = findPatterns(ins);
    goal = r.goal; baseline = r.baseline;
    patterns = r.patterns.map((p) => pick(p, ["tone", "group", "title", "detail", "cost", "baseline", "ratio", "results", "spend", "confidence"]));
  } catch { /* patterns are a help, never a blocker */ }
  const cut = (s: unknown) => (typeof s === "string" && s.length > META_LIMITS.text ? `${s.slice(0, META_LIMITS.text)}…` : s);
  const info = (o: any, keys: string[]) => Object.fromEntries(Object.entries(pick(o ?? {}, keys)).map(([k, v]) => [k, cut(v)]));
  const board = ins.board ?? {};
  ctx.insights = {
    period: ins.period, totals: ins.current, coverage: ins.coverage, crm_unplaced: ins.crm_unplaced,
    campaigns: (board.campaign ?? []).slice(0, META_LIMITS.campaign).map((r: any) => pick(r, ROW)),
    adsets: (board.adset ?? []).slice(0, META_LIMITS.adset).map((r: any) => ({ ...pick(r, ROW), targeting: info(r.info, ADSET_INFO) })),
    ads: (board.ad ?? []).slice(0, META_LIMITS.ad).map((r: any) => ({ ...pick(r, ROW), creative: info(r.info, AD_INFO) })),
    rows_not_shown: { campaigns: Math.max(0, (board.campaign ?? []).length - META_LIMITS.campaign),
      adsets: Math.max(0, (board.adset ?? []).length - META_LIMITS.adset), ads: Math.max(0, (board.ad ?? []).length - META_LIMITS.ad) },
    breakdowns: ins.breakdowns, breakdown_months: ins.breakdown_months, weekday: ins.weekday, fatigue: ins.fatigue,
    weekly_trend_last_26: (ins.trend ?? []).slice(-26), notes: ins.notes,
  };
  ctx.patterns = { judged_on: goal, average_cost_per_result: baseline, items: patterns };
  return ctx;
}
