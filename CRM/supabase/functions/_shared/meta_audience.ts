// Meta Ads > Funnel > Audience library (migration 107): pure helpers for the daily audience job in ads-sync.
// Engagement audiences follow Meta's rule format (inclusions / exclusions, event_sources, retention_seconds, filter on
// "event"); lead-ad audiences keep 90 days at most, Page and Instagram 730. CRM lists are customer-file audiences
// (subtype CUSTOM, customer_file_source USER_PROVIDED_ONLY) filled with the Replace API in batches.

export const MAX_DAYS: Record<string, number> = { lead: 90, ig: 730, page: 730, "page+ig": 730 };
export const BATCH = 10000;
export const PREFIX = "CRM · ";

export interface Ids { page_id: string | null; ig_id: string | null; forms: string[] }
type Src = { id: string; type: string };
const rule = (sources: Src[], event: string, days: number) => ({
  event_sources: sources, retention_seconds: days * 86400,
  filter: { operator: "and", filters: [{ field: "event", operator: "eq", value: event }] },
});

// The rule for one engagement audience, or the reason it cannot be made yet.
export function engagementRule(spec: any, ids: Ids): { rule?: unknown; missing?: string } {
  const source = String(spec?.source ?? "");
  const days = Math.max(1, Math.min(MAX_DAYS[source] ?? 365, Number(spec?.days) || 30));
  const event = String(spec?.event ?? "");
  if (source === "lead") {
    const forms = ids.forms.filter((f) => /^\d{5,25}$/.test(f)).slice(0, 25);
    if (!forms.length) return { missing: "No lead forms found on the Page yet (Setup > lead forms)" };
    const sources = forms.flatMap((f) => [{ id: f, type: "lead" }, { id: f, type: "ig_lead_generation" }]);
    return { rule: { inclusions: { operator: "or", rules: sources.map((s) => rule([s], event, days)) } } };
  }
  if (source === "page") {
    if (!ids.page_id) return { missing: "The Facebook Page is not set (Setup > Page)" };
    return { rule: { inclusions: { operator: "or", rules: [rule([{ id: ids.page_id, type: "page" }], event, days)] } } };
  }
  if (source === "ig") {
    if (!ids.ig_id) return { missing: "No Instagram professional account is linked to the Page" };
    return { rule: { inclusions: { operator: "or", rules: [rule([{ id: ids.ig_id, type: "ig_business" }], event, days)] } } };
  }
  if (source === "page+ig" && event === "messaged") {
    const rules = [];
    if (ids.page_id) rules.push(rule([{ id: ids.page_id, type: "page" }], "page_messaged", days));
    if (ids.ig_id) rules.push(rule([{ id: ids.ig_id, type: "ig_business" }], "ig_user_messaged_business", days));
    if (!rules.length) return { missing: "The Facebook Page is not set (Setup > Page)" };
    return { rule: { inclusions: { operator: "or", rules } } };
  }
  return { missing: `Unknown audience source ${source}` };
}

// Replace-API batches for a CRM list: rows are [phone hash, email hash or null].
export function replaceBatches(rows: [string, string | null][], sessionId: number) {
  const clean = rows.filter((r) => Array.isArray(r) && /^[0-9a-f]{64}$/.test(String(r[0] ?? "")))
    .map((r) => [r[0], /^[0-9a-f]{64}$/.test(String(r[1] ?? "")) ? r[1] : ""]);
  const out: { payload: string; session: string }[] = [];
  const n = Math.ceil(clean.length / BATCH);
  for (let i = 0; i < n; i++) {
    out.push({
      payload: JSON.stringify({ schema: ["PHONE", "EMAIL"], data: clean.slice(i * BATCH, (i + 1) * BATCH) }),
      session: JSON.stringify({ session_id: sessionId, batch_seq: i + 1, last_batch_flag: i === n - 1, estimated_num_total: clean.length }),
    });
  }
  return { batches: out, total: clean.length };
}

// A plain message for the errors people actually hit.
export function audienceError(msg: string, accountId: string): string {
  if (/terms|tos\b/i.test(msg)) return `Accept Meta's Custom Audience terms once for this ad account: https://business.facebook.com/ads/manage/customaudiences/tos/?act=${accountId}`;
  if (/permission|\(#200\)|\(#10\)/i.test(msg)) return "The Meta token cannot manage audiences: it needs ads_management on this ad account (Setup > Meta connection).";
  if (/414|replace in progress/i.test(msg)) return "Meta is still applying the last update to this list; it will be refreshed tomorrow.";
  return msg.slice(0, 300);
}

export const sizeOf = (b: any) => ({
  size_low: Number.isFinite(Number(b?.approximate_count_lower_bound)) && Number(b.approximate_count_lower_bound) >= 0 ? Number(b.approximate_count_lower_bound) : null,
  size_high: Number.isFinite(Number(b?.approximate_count_upper_bound)) && Number(b.approximate_count_upper_bound) >= 0 ? Number(b.approximate_count_upper_bound) : null,
});
