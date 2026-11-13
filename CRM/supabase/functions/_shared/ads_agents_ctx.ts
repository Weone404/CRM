// Shapes the account context for the ADS agents (pure TypeScript, unit-tested).
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
