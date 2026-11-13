// Google Ads operations for ADS (Google only; Meta and Amazon are separate).
// Pure TypeScript, testable without Deno APIs. Every operation:
//   1. is built into googleAds:mutate operations,
//   2. is sent once with validateOnly (Google's own checks, including ad policy; nothing changes),
//   3. is sent for real (atomic: all operations land or none),
//   4. is read back with GAQL; only a successful read-back counts as "verified".
import { AdsError, type GoogleAds } from "./ads_core.ts";

export interface GoogleOp { id: string; kind: string; payload: any; account_external_id: string; login_customer_id?: string | null; status?: string }
type Check = { mode: "exists" | "absent" | "field"; field?: string; value?: unknown };
export interface Built { ops: any[]; checks: Check[] }   // checks[i] verifies the i-th operation's result

const RES: Record<string, string> = {
  adGroupCriteria: "ad_group_criterion", campaignCriteria: "campaign_criterion", sharedCriteria: "shared_criterion",
  adGroupAds: "ad_group_ad", adGroups: "ad_group", campaignSharedSets: "campaign_shared_set", assets: "asset",
  customerAssets: "customer_asset", campaignAssets: "campaign_asset", conversionActions: "conversion_action", campaigns: "campaign",
};
const STATUS_FIELD: Record<string, string> = {
  ad_group_criterion: "status", ad_group_ad: "status", customer_asset: "status", campaign_asset: "status",
  campaign_criterion: "status", ad_group: "status", campaign_shared_set: "status", campaign: "status",
};
const digits = (v: unknown, what: string) => {
  const s = String(v ?? "");
  if (!/^\d+$/.test(s)) throw new AdsError("sync_failed", `${what} must be numeric`);
  return s;
};
const camel = (s: string) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
export const getPath = (row: any, path: string) => path.split(".").reduce((o, k) => (o == null ? undefined : o[camel(k)]), row);

export function buildOps(cid: string, kind: string, p: any): Built {
  const C = `customers/${cid}`;
  const ops: any[] = [], checks: Check[] = [];
  const add = (op: any, check: Check) => { ops.push(op); checks.push(check); };
  const kw = (k: any) => ({ text: String(k.text).trim(), matchType: String(k.match).toUpperCase() });
  switch (kind) {
    case "keyword_add":
      for (const k of p.keywords) add({ adGroupCriterionOperation: { create: {
        adGroup: `${C}/adGroups/${digits(p.ad_group_id, "ad_group_id")}`, status: "ENABLED", keyword: kw(k) } } }, { mode: "exists" });
      break;
    case "negative_add":
      for (const k of p.keywords) add(p.level === "campaign"
        ? { campaignCriterionOperation: { create: { campaign: `${C}/campaigns/${digits(p.campaign_id, "campaign_id")}`, negative: true, keyword: kw(k) } } }
        : { sharedCriterionOperation: { create: { sharedSet: `${C}/sharedSets/${digits(p.shared_set_id, "shared_set_id")}`, keyword: kw(k) } } },
        { mode: "exists" });
      break;
    case "keyword_status":
    case "ad_status": {
      const key = kind === "keyword_status" ? "adGroupCriterionOperation" : "adGroupAdOperation";
      const st = String(p.status).toUpperCase();
      if (!String(p.resource_name).startsWith(`${C}/`)) throw new AdsError("sync_failed", "resource belongs to another account");
      add(st === "REMOVED" ? { [key]: { remove: p.resource_name } }
                           : { [key]: { update: { resourceName: p.resource_name, status: st }, updateMask: "status" } },
          st === "REMOVED" ? { mode: "absent" } : { mode: "field", field: "status", value: st });
      break;
    }
    case "rsa_create": {
      const rsa: any = { headlines: p.headlines.map((t: string) => ({ text: t.trim() })), descriptions: p.descriptions.map((t: string) => ({ text: t.trim() })) };
      if (p.path1) rsa.path1 = p.path1;
      if (p.path2) rsa.path2 = p.path2;
      add({ adGroupAdOperation: { create: { adGroup: `${C}/adGroups/${digits(p.ad_group_id, "ad_group_id")}`, status: "ENABLED",
        ad: { finalUrls: [p.final_url], responsiveSearchAd: rsa } } } }, { mode: "exists" });
      break;
    }
    case "ad_group_create": {
      const g: any = { campaign: `${C}/campaigns/${digits(p.campaign_id, "campaign_id")}`, name: String(p.name).trim(), status: "ENABLED", type: "SEARCH_STANDARD" };
      if (p.cpc_bid != null) g.cpcBidMicros = String(Math.round(Number(p.cpc_bid) * 100) * 10_000);
      add({ adGroupOperation: { create: g } }, { mode: "exists" });
      break;
    }
    case "campaign_geo": {
      const camp = `${C}/campaigns/${digits(p.campaign_id, "campaign_id")}`;
      if (p.target_type) add({ campaignOperation: { update: { resourceName: camp, geoTargetTypeSetting: { positiveGeoTargetType: String(p.target_type).toUpperCase() } },
        updateMask: "geoTargetTypeSetting.positiveGeoTargetType" } },
        { mode: "field", field: "geo_target_type_setting.positive_geo_target_type", value: String(p.target_type).toUpperCase() });
      for (const g of p.add ?? []) add({ campaignCriterionOperation: { create: { campaign: camp, location: { geoTargetConstant: `geoTargetConstants/${digits(g, "location")}` } } } },
        { mode: "exists" });
      for (const g of p.remove ?? []) add({ campaignCriterionOperation: { remove: `${C}/campaignCriteria/${p.campaign_id}~${digits(g, "location")}` } }, { mode: "absent" });
      break;
    }
    case "shared_set_attach":
      add({ campaignSharedSetOperation: { create: { campaign: `${C}/campaigns/${digits(p.campaign_id, "campaign_id")}`,
        sharedSet: `${C}/sharedSets/${digits(p.shared_set_id, "shared_set_id")}` } } }, { mode: "exists" });
      break;
    case "callout_add":
    case "sitelink_add": {
      const tmp = `${C}/assets/-1`;
      const asset: any = { resourceName: tmp };
      if (kind === "callout_add") asset.calloutAsset = { calloutText: String(p.text).trim() };
      else {
        asset.finalUrls = [p.final_url];
        asset.sitelinkAsset = { linkText: String(p.text).trim(), ...(p.description1 ? { description1: p.description1 } : {}), ...(p.description2 ? { description2: p.description2 } : {}) };
      }
      const field = kind === "callout_add" ? "CALLOUT" : "SITELINK";
      add({ assetOperation: { create: asset } }, { mode: "exists" });
      add(p.campaign_id
        ? { campaignAssetOperation: { create: { campaign: `${C}/campaigns/${digits(p.campaign_id, "campaign_id")}`, asset: tmp, fieldType: field } } }
        : { customerAssetOperation: { create: { asset: tmp, fieldType: field } } }, { mode: "exists" });
      break;
    }
    case "asset_unlink": {
      const rn = String(p.resource_name);
      if (!rn.startsWith(`${C}/`)) throw new AdsError("sync_failed", "resource belongs to another account");
      add(rn.includes("/campaignAssets/") ? { campaignAssetOperation: { remove: rn } } : { customerAssetOperation: { remove: rn } }, { mode: "absent" });
      break;
    }
    case "conversion_goal":
      add({ conversionActionOperation: { update: { resourceName: `${C}/conversionActions/${digits(p.conversion_action_id, "conversion_action_id")}`,
        primaryForGoal: p.primary === true }, updateMask: "primaryForGoal" } }, { mode: "field", field: "primary_for_goal", value: p.primary === true });
      break;
    default:
      throw new AdsError("sync_failed", `unknown operation ${kind}`);
  }
  return { ops, checks };
}

// Resource names from a googleAds:mutate response, in operation order.
export function resultNames(resp: any): string[] {
  return (resp?.mutateOperationResponses ?? []).map((r: any) => {
    const v = Object.values(r ?? {})[0] as any;
    return v?.resourceName ?? "";
  });
}

export async function verifyNames(g: GoogleAds, cid: string, names: string[], checks: Check[]) {
  const out: any[] = [];
  for (let i = 0; i < names.length; i++) {
    const rn = names[i], ck = checks[i];
    const coll = rn.split("/")[2] ?? "";
    const res = RES[coll];
    if (!res) { out.push({ rn, ok: false, why: "unknown resource" }); continue; }
    const fields = [`${res}.resource_name`];
    if (ck.mode === "field" && ck.field) fields.push(`${res}.${ck.field}`);
    if (ck.mode === "absent" && STATUS_FIELD[res]) fields.push(`${res}.${STATUS_FIELD[res]}`);
    const rows = await g.search(cid, `SELECT ${fields.join(", ")} FROM ${res} WHERE ${res}.resource_name = '${rn.replace(/'/g, "")}'`);
    const row = rows[0]?.[camel(res)];
    let ok: boolean;
    if (ck.mode === "exists") ok = !!row;
    else if (ck.mode === "absent") ok = !row || getPath(row, STATUS_FIELD[res] ?? "status") === "REMOVED";
    else ok = !!row && getPath(row, ck.field!) === ck.value;
    out.push({ rn, ok, ...(ck.mode === "field" ? { got: row ? getPath(row, ck.field!) : null, want: ck.value } : {}) });
  }
  return out;
}

// Runs one approved operation end to end. Never reports success without a read-back.
export async function executeGoogleOp(google: GoogleAds, op: GoogleOp):
  Promise<{ status: "verified" | "failed" | "outcome_unknown"; error?: string; result?: any; verify?: any }> {
  const g = google.withLogin(op.login_customer_id);
  const cid = op.account_external_id;
  let built: Built;
  try { built = buildOps(cid, op.kind, op.payload); } catch (e) { return { status: "failed", error: (e as Error).message }; }
  try { await g.mutate(cid, built.ops, true); }
  catch (e) { return { status: "failed", error: `Google rejected it in the pre-check (nothing changed): ${(e as Error).message}` }; }
  let resp: any;
  try { resp = await g.mutate(cid, built.ops, false); }
  catch (e) {
    if (e instanceof AdsError && !e.sent) return { status: "failed", error: e.message };
    return { status: "outcome_unknown", error: `Sent, but no answer from Google: ${(e as Error).message}` };
  }
  const names = resultNames(resp);
  const result = { resource_names: names };
  try {
    const v = await verifyNames(g, cid, names, built.checks);
    const bad = v.filter((x) => !x.ok);
    return bad.length ? { status: "failed", result, verify: v, error: `Google accepted it, but ${bad.length} item(s) do not read back as expected.` }
                      : { status: "verified", result, verify: v };
  } catch (e) {
    return { status: "outcome_unknown", result, error: `Sent, but could not read it back: ${(e as Error).message}` };
  }
}

// Read-only picture of the account for the agents (compact GAQL; ~13 operations per sync).
export const SNAPSHOT_QUERIES: Record<string, string> = {
  campaigns: "SELECT campaign.id, campaign.name, campaign.status, campaign.primary_status, campaign.primary_status_reasons, campaign.bidding_strategy_type, " +
    "campaign.advertising_channel_type, campaign.network_settings.target_search_network, campaign.network_settings.target_content_network, " +
    "campaign.geo_target_type_setting.positive_geo_target_type, campaign_budget.amount_micros FROM campaign WHERE campaign.status != 'REMOVED'",
  locations: "SELECT campaign.id, campaign_criterion.criterion_id, campaign_criterion.location.geo_target_constant, campaign_criterion.negative " +
    "FROM campaign_criterion WHERE campaign_criterion.type = 'LOCATION' AND campaign.status != 'REMOVED'",
  ad_groups: "SELECT campaign.id, ad_group.id, ad_group.name, ad_group.status, ad_group.type, ad_group.cpc_bid_micros FROM ad_group " +
    "WHERE campaign.status != 'REMOVED' AND ad_group.status != 'REMOVED'",
  // keywords of the running campaigns (performance comes from the search terms; keyword_view hides keywords with no traffic)
  keywords: "SELECT campaign.id, ad_group.id, ad_group_criterion.resource_name, ad_group_criterion.keyword.text, ad_group_criterion.keyword.match_type, " +
    "ad_group_criterion.negative, ad_group_criterion.status, ad_group_criterion.quality_info.quality_score FROM ad_group_criterion " +
    "WHERE ad_group_criterion.type = 'KEYWORD' AND ad_group_criterion.status != 'REMOVED' AND campaign.status = 'ENABLED'",
  ads: "SELECT campaign.id, ad_group.id, ad_group_ad.resource_name, ad_group_ad.status, ad_group_ad.ad_strength, ad_group_ad.policy_summary.approval_status, " +
    "ad_group_ad.ad.final_urls, ad_group_ad.ad.responsive_search_ad.headlines, ad_group_ad.ad.responsive_search_ad.descriptions FROM ad_group_ad " +
    "WHERE ad_group_ad.status != 'REMOVED' AND campaign.status != 'REMOVED'",
  account_assets: "SELECT customer_asset.resource_name, customer_asset.field_type, customer_asset.status, asset.id, asset.type, asset.callout_asset.callout_text, " +
    "asset.sitelink_asset.link_text, asset.sitelink_asset.description1, asset.sitelink_asset.description2, asset.final_urls, asset.call_asset.phone_number " +
    "FROM customer_asset WHERE customer_asset.status != 'REMOVED'",
  campaign_assets: "SELECT campaign.id, campaign.status, campaign_asset.resource_name, campaign_asset.field_type, campaign_asset.status, asset.id, asset.callout_asset.callout_text, " +
    "asset.sitelink_asset.link_text, asset.final_urls FROM campaign_asset WHERE campaign_asset.status != 'REMOVED' AND campaign.status != 'REMOVED'",
  conversions: "SELECT conversion_action.id, conversion_action.name, conversion_action.status, conversion_action.type, conversion_action.category, " +
    "conversion_action.primary_for_goal, conversion_action.counting_type FROM conversion_action WHERE conversion_action.status != 'REMOVED'",
  shared_sets: "SELECT shared_set.id, shared_set.name, shared_set.type, shared_set.member_count FROM shared_set WHERE shared_set.status = 'ENABLED'",
  shared_set_links: "SELECT campaign.id, shared_set.id, campaign_shared_set.status FROM campaign_shared_set WHERE campaign_shared_set.status = 'ENABLED'",
  shared_negatives: "SELECT shared_set.id, shared_criterion.keyword.text, shared_criterion.keyword.match_type FROM shared_criterion " +
    "WHERE shared_set.type = 'NEGATIVE_KEYWORDS'",
  search_terms_30d: "SELECT search_term_view.search_term, search_term_view.status, campaign.id, ad_group.id, metrics.clicks, metrics.impressions, " +
    "metrics.cost_micros, metrics.conversions FROM search_term_view WHERE segments.date DURING LAST_30_DAYS ORDER BY metrics.cost_micros DESC LIMIT 500",
};

// Flattens a GAQL row into {resource_field: value} with short names (keeps the snapshot small and readable for the agents).
export function flatRow(row: any, prefix = "", out: Record<string, unknown> = {}): Record<string, unknown> {
  for (const [k, v] of Object.entries(row ?? {})) {
    if (k === "resourceName" && prefix.split(".").length > 2) continue;
    const key = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === "object" && !Array.isArray(v)) flatRow(v, key, out);
    else out[key] = v;
  }
  return out;
}

// Search terms over the past year (all campaigns, paused included): what people really typed and what it cost.
export function historyQuery(today: string): string {
  const d = new Date(`${today}T00:00:00Z`);
  const from = new Date(d.getTime() - 365 * 86_400_000).toISOString().slice(0, 10);
  return "SELECT search_term_view.search_term, campaign.id, metrics.clicks, metrics.impressions, metrics.cost_micros, metrics.conversions " +
    `FROM search_term_view WHERE segments.date BETWEEN '${from}' AND '${today}' AND metrics.clicks > 0 ORDER BY metrics.cost_micros DESC LIMIT 400`;
}

export async function googleSnapshot(google: GoogleAds, cid: string, login?: string | null, today = new Date().toISOString().slice(0, 10)) {
  const g = google.withLogin(login);
  const out: Record<string, unknown[] | { error: string }> = {};
  for (const [k, q] of Object.entries({ ...SNAPSHOT_QUERIES, search_terms_365d: historyQuery(today) })) {
    try { out[k] = (await g.search(cid, q)).map((r) => flatRow(r)); }
    catch (e) { out[k] = { error: (e as Error).message.slice(0, 300) }; }
  }
  // Keyword Planner ideas for the agents (India, English), seeded with the running keywords. The agents never call Google.
  try {
    const kws = Array.isArray(out.keywords) ? out.keywords as any[] : [];
    const seeds = [...new Set(kws.filter((k) => !k["adGroupCriterion.negative"]).map((k) => String(k["adGroupCriterion.keyword.text"] ?? "")).filter(Boolean))].slice(0, 10);
    const rows = await g.keywordIdeas(cid, seeds.length ? seeds : ["pilot training", "dgca ground classes", "commercial pilot license"], ["2356"]);
    out.keyword_ideas = rows.map((r: any) => ({ text: r.text, avg_monthly: Number(r.keywordIdeaMetrics?.avgMonthlySearches ?? 0) || null,
      competition: r.keywordIdeaMetrics?.competition ?? null, low_bid: Number(r.keywordIdeaMetrics?.lowTopOfPageBidMicros ?? 0) / 1e6 || null,
      high_bid: Number(r.keywordIdeaMetrics?.highTopOfPageBidMicros ?? 0) / 1e6 || null }))
      .sort((a: any, b: any) => (b.avg_monthly ?? 0) - (a.avg_monthly ?? 0)).slice(0, 150);
  } catch (e) { out.keyword_ideas = { error: (e as Error).message.slice(0, 300) }; }
  return out;
}
