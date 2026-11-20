// Meta Ads > Health (migration 105): turns what Meta reports about the account into a health summary and warnings.
// Pure TypeScript (unit-tested); ads-sync job `meta_health` reads Meta, calls healthWarnings, and the database keeps the
// warnings open until they are no longer found (svc_ads_meta_health_save adds the CRM's own checks).

export interface HealthInput {
  today: string; currency: string | null; account: any; opportunity: any; recommendations: any[];
  campaigns: any[]; adsets: any[]; ads: any[]; days: any[]; errors: string[];
}
export interface Warning { kind: string; entity: string; severity: "high" | "medium" | "low"; title: string; detail?: string; data?: unknown }

const n = (v: unknown) => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
const LEADS = ["lead", "onsite_conversion.lead_grouped", "leadgen_grouped"];
const leadsOf = (r: any) => (Array.isArray(r?.actions) ? r.actions : []).filter((a: any) => LEADS.includes(a?.action_type)).reduce((s: number, a: any) => s + n(a.value), 0);
const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND", "CLP", "COP", "HUF", "ISK", "PYG", "TWD", "IDR"]);
export const units = (minor: unknown, currency: string | null) => n(minor) / (ZERO_DECIMAL.has(String(currency ?? "INR").toUpperCase()) ? 1 : 100);
// Prepaid accounts: Meta shows the money left as text on the payment method ("Available balance (₹423.73 INR)").
// Returns the amount in rupees, or null when the account is not prepaid or the text has no amount.
export function prepaidBalance(account: any): number | null {
  if (!account?.is_prepay_account) return null;
  const t = String(account?.funding_source_details?.display_string ?? "");
  const m = /([\d,]+(?:\.\d+)?)/.exec(t.replace(/\u00a0/g, " "));
  if (!m) return null;
  const v = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(v) ? v : null;
}
const rupees = (v: number) => `₹${Math.round(v).toLocaleString("en-IN")}`;
const ACCOUNT_STATUS: Record<number, string> = { 1: "Active", 2: "Disabled", 3: "Unsettled (payment due)", 7: "Pending risk review", 8: "Pending settlement",
  9: "In grace period", 100: "Pending closure", 101: "Closed", 201: "Any active", 202: "Any closed" };

export function healthWarnings(i: HealthInput): { data: any; warnings: Warning[] } {
  const w: Warning[] = [];
  const cur = i.currency;
  // account
  const status = n(i.account?.account_status);
  if (status && status !== 1) w.push({ kind: "account_status", entity: "account", severity: "high",
    title: `Ad account is ${ACCOUNT_STATUS[status] ?? `status ${status}`}`, detail: "Ads cannot run until this is fixed in Meta Business Settings > Billing / Account quality." });
  const cap = units(i.account?.spend_cap, cur), spent = units(i.account?.amount_spent, cur);
  if (cap > 0 && spent / cap >= 0.9) w.push({ kind: "spend_cap", entity: "account", severity: spent >= cap ? "high" : "medium",
    title: `Account spending limit ${Math.round((spent / cap) * 100)}% used`, detail: `${rupees(spent)} of ${rupees(cap)}. Ads stop at the limit; raise or reset it in Billing.` });

  // money left: the lower of the prepaid balance and the account spending limit decides when ads stop
  const prepaid = prepaidBalance(i.account);
  const capLeft = cap > 0 ? Math.max(0, cap - spent) : null;
  const available = [prepaid, capLeft].filter((v): v is number => v !== null).reduce((a, b) => Math.min(a, b), Infinity);
  const funds = { prepaid, cap_left: capLeft, available: Number.isFinite(available) ? available : null, prepay: !!i.account?.is_prepay_account,
    funding_text: i.account?.funding_source_details?.display_string ? String(i.account.funding_source_details.display_string).slice(0, 120) : null };

  // delivery problems
  for (const a of i.ads ?? []) {
    if (a.effective_status === "DISAPPROVED") {
      const fb = a.ad_review_feedback?.global ? Object.entries(a.ad_review_feedback.global).map(([k, v]) => `${k}: ${v}`).join("; ") : "";
      w.push({ kind: "ad_rejected", entity: String(a.id), severity: "high", title: `Ad rejected: ${a.name}`, detail: fb.slice(0, 600) || "See Account quality in Meta for the reason and to request a review." });
    } else if (a.effective_status === "WITH_ISSUES" || (Array.isArray(a.issues_info) && a.issues_info.length)) {
      const msg = (a.issues_info ?? []).map((x: any) => x.error_summary || x.error_message).filter(Boolean).join("; ");
      w.push({ kind: "ad_issue", entity: String(a.id), severity: "medium", title: `Ad has an issue: ${a.name}`, detail: msg.slice(0, 600) || undefined });
    }
  }
  const learning = { learning: 0, limited: 0, done: 0 };
  for (const s of i.adsets ?? []) {
    const st = String(s.learning_stage_info?.status ?? "");
    if (st === "LEARNING") learning.learning++;
    else if (st === "FAIL") { learning.limited++; w.push({ kind: "learning_limited", entity: String(s.id), severity: "medium", title: `Learning limited: ${s.name}`,
      detail: "Meta cannot get enough results to finish learning. Combine ad sets, widen the audience or raise the budget." }); }
    else if (st === "SUCCESS") learning.done++;
  }
  for (const c of i.campaigns ?? []) if (Array.isArray(c.issues_info) && c.issues_info.length)
    w.push({ kind: "campaign_issue", entity: String(c.id), severity: "medium", title: `Campaign has an issue: ${c.name}`,
      detail: c.issues_info.map((x: any) => x.error_summary || x.error_message).filter(Boolean).join("; ").slice(0, 600) || undefined });

  // budgets and pacing (today, account time)
  const dailyBudget = [...(i.campaigns ?? []).map((c) => units(c.daily_budget, cur)), ...(i.adsets ?? []).map((s) => units(s.daily_budget, cur))].reduce((a, b) => a + b, 0);
  // GST (18%) is charged on top of ad spend in India, so a day of ads uses about 1.18 × the budget from the balance
  if (funds.available !== null && dailyBudget > 0 && funds.available < dailyBudget * 1.18 * 3)
    w.push({ kind: "low_funds", entity: "account", severity: "high",   // high: the owner gets a phone/email alert
      title: `Ad money low: ${rupees(funds.available)} left`, detail: `About ${Math.max(0, Math.floor(funds.available / (dailyBudget * 1.18)))} day(s) at ${rupees(dailyBudget)}/day plus GST. Add funds in Meta Billing${capLeft !== null && capLeft === funds.available ? " and raise the account spending limit" : ""}.` });
  const byDay = new Map<string, { spend: number; leads: number; clicks: number; impressions: number }>();
  for (const d of i.days ?? []) byDay.set(String(d.date_start), { spend: n(d.spend), leads: leadsOf(d), clicks: n(d.inline_link_clicks), impressions: n(d.impressions) });
  const day = (k: number) => { const t = new Date(Date.parse(`${i.today}T00:00:00Z`) - k * 86400e3).toISOString().slice(0, 10); return byDay.get(t) ?? { spend: 0, leads: 0, clicks: 0, impressions: 0 }; };
  const sum = (from: number, to: number) => { const t = { spend: 0, leads: 0 }; for (let k = from; k <= to; k++) { const d = day(k); t.spend += d.spend; t.leads += d.leads; } return t; };
  const today = day(0), yesterday = day(1), last3 = sum(1, 3), prev14 = sum(4, 17);
  const cpl14 = prev14.leads > 0 ? prev14.spend / prev14.leads : null;
  const avgSpend14 = prev14.spend / 14;
  if (yesterday.spend > 0 && yesterday.leads === 0 && cpl14 && yesterday.spend >= 2 * cpl14)
    w.push({ kind: "no_leads", entity: "account", severity: "high", title: `No leads yesterday after ${rupees(yesterday.spend)} spend`,
      detail: `That is ${(yesterday.spend / cpl14).toFixed(1)}× the usual cost per lead (${rupees(cpl14)}). Check the forms, rejected ads and the webhook.` });
  const cpl3 = last3.leads > 0 ? last3.spend / last3.leads : null;
  if (cpl3 && cpl14 && prev14.leads >= 5 && cpl3 > cpl14 * 1.3)
    w.push({ kind: "cpl_up", entity: "account", severity: "medium", title: `Cost per lead up ${Math.round((cpl3 / cpl14 - 1) * 100)}%`,
      detail: `Last 3 days ${rupees(cpl3)} against ${rupees(cpl14)} in the 14 days before. Look for fatigue (frequency) or a weak new ad in Reports.` });
  if (avgSpend14 > 0 && yesterday.spend > avgSpend14 * 1.5 && yesterday.spend - avgSpend14 > 500)
    w.push({ kind: "spend_jump", entity: "account", severity: "medium", title: `Spend jumped to ${rupees(yesterday.spend)} yesterday`,
      detail: `Usual daily spend is about ${rupees(avgSpend14)}. Check budget changes.` });

  const recs = (Array.isArray(i.recommendations) ? i.recommendations : []).slice(0, 20).map((r: any) => ({
    type: r.type ?? r.recommendation_type ?? null, title: String(r.title ?? r.recommendation_content?.title ?? r.type ?? "Recommendation").slice(0, 160),
    body: String(r.body ?? r.recommendation_content?.body ?? r.message ?? "").slice(0, 400),
    lift: r.lift_estimate ?? r.recommendation_content?.lift_estimate ?? null,
    score_lift: n(r.opportunity_score_lift ?? r.recommendation_content?.opportunity_score_lift) || null,
    url: typeof (r.url ?? r.recommendation_content?.url) === "string" && String(r.url ?? r.recommendation_content?.url).startsWith("https://") ? String(r.url ?? r.recommendation_content?.url) : null,
    object_ids: r.object_ids ?? null }));

  const score = i.opportunity?.opportunity_score;
  const data = {
    account: { name: i.account?.name ?? null, status: status || null, status_text: status ? ACCOUNT_STATUS[status] ?? String(status) : null,
      spend_cap: cap || null, amount_spent: spent || null, currency: cur, ...funds },
    opportunity: { score: score === undefined || score === null ? null : n(typeof score === "object" ? score.score ?? score.value : score), recommendations: recs },
    delivery: { campaigns: (i.campaigns ?? []).length, adsets: (i.adsets ?? []).length, ads: (i.ads ?? []).length, learning,
      rejected: (i.ads ?? []).filter((a) => a.effective_status === "DISAPPROVED").length },
    pacing: { daily_budget: dailyBudget, today_spend: today.spend, today_leads: today.leads, yesterday, cpl_3d: cpl3, cpl_14d: cpl14, avg_spend_14d: avgSpend14 },
    month: (() => { const m = i.today.slice(0, 7); let s = 0, l = 0; for (const [k, v] of byDay) if (k.startsWith(m)) { s += v.spend; l += v.leads; } return { spend: s, leads: l }; })(),
    errors: i.errors,
  };
  return { data, warnings: w };
}
