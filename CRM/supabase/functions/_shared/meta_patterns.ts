// Meta Ads > Insights: proven patterns, budget what-if and the monthly summary text, from api_ads_meta_insights data.
// Pure TypeScript, used by the dashboard (browser) and by ads-sync (monthly email), so both say the same thing.
//
// How a pattern is judged
//   Goal: the furthest CRM result with enough data in the period - admissions (8+), else qualified leads (15+),
//   else Meta-counted leads. Breakdowns (age, region, placement, device, hour, weekday) only know Meta leads.
//   Each group (campaign, ad set, ad, creative trait, audience trait, breakdown bucket) gets cost per result and is
//   compared with the account's average. Better by 20%+ = a win, worse by 40%+ (or money spent with no result) = a loss.
//   "Proven" needs spend of 2x the average cost and, for a win, enough results (admissions 4, qualified 8, leads 20);
//   for a loss, enough spend that the average cost would have bought that many. Otherwise "Early".
//   Small groups (under 3% of spend and under the proven count) are left out, so luck is not shown as a pattern.

export type Goal = "customers" | "qualified" | "meta_leads";
export const GOAL_LABEL: Record<Goal, { one: string; many: string }> = {
  customers: { one: "admission", many: "admissions" },
  qualified: { one: "qualified lead", many: "qualified leads" },
  meta_leads: { one: "lead", many: "leads" },
};
const PROVEN: Record<Goal, number> = { customers: 4, qualified: 8, meta_leads: 20 };

export interface Totals { spend: number; impressions: number; clicks: number; meta_leads: number; crm_leads: number; qualified: number; customers: number; link_clicks?: number }
export interface BoardRow extends Partial<Totals> { ext: string; name: string; spend: number; info?: Record<string, any>; status?: string | null }
export interface Pattern {
  id: string; tone: "win" | "loss" | "info"; group: string; title: string; detail: string;
  cost: number | null; baseline: number | null; ratio: number | null; results: number; spend: number; confidence: "proven" | "early" | null;
}

export const inr = (n: number | null | undefined) => (n === null || n === undefined || !Number.isFinite(n) ? "–"
  : `₹${Math.round(n).toLocaleString("en-IN")}`);
const pct = (r: number) => `${Math.round(Math.abs(1 - r) * 100)}%`;
const N = (v: unknown) => Number(v) || 0;

export function chooseGoal(cur: Partial<Totals>): Goal {
  if (N(cur.customers) >= 8) return "customers";
  if (N(cur.qualified) >= 15) return "qualified";
  return "meta_leads";
}
export const costPer = (spend: number, results: number) => (results > 0 ? spend / results : null);

// ------------------------------------------------------------------ creative and audience traits
const HINGLISH = /\b(aap|aapka|kaise|kya|hai|hain|banein|banna|sapna|abhi|sirf|apna|apne|karein|kare)\b/i;
export function creativeTraits(info: Record<string, any> = {}): Record<string, string> {
  const text = `${info.title ?? ""} ${info.body ?? ""}`.trim();
  const firstLine = String(info.body ?? info.title ?? "").split(/[\n.!]/)[0] ?? "";
  const t: Record<string, string> = {};
  if (info.format) t.format = `${String(info.format)[0].toUpperCase()}${String(info.format).slice(1)} ads`;
  if (info.cta) t.cta = `"${String(info.cta).replace(/_/g, " ").toLowerCase()}" button`;
  if (text) {
    t.hook = /\?/.test(firstLine) ? "Ads opening with a question" : /\d/.test(firstLine) ? "Ads opening with a number" : "Ads opening with a statement";
    t.length = String(info.body ?? "").length > 300 ? "Long ad text (300+ characters)" : "Short ad text";
    t.language = /[ऀ-ॿ]/.test(text) ? "Hindi ad text" : HINGLISH.test(text) ? "Hinglish ad text" : "English ad text";
    if (/(₹|\brs\.?\s?\d|\bfees?\b|\blakh|\bemi\b|\bscholarship)/i.test(text)) t.money = "Ads that mention fees / cost";
    if (/\bdgca\b/i.test(text)) t.dgca = "Ads that mention DGCA";
  }
  return t;
}
export function audienceTraits(info: Record<string, any> = {}): Record<string, string> {
  const t: Record<string, string> = {};
  if (info.age_min || info.age_max) t.age = `Ad sets aimed at ages ${info.age_min ?? 18}–${info.age_max ?? "65+"}`;
  if (Array.isArray(info.genders)) t.gender = info.genders.includes("all") || info.genders.length > 1 ? "Ad sets for all genders" : `Ad sets for ${info.genders[0]} only`;
  const geo = [...(info.cities ?? []), ...(info.regions ?? [])];
  if (geo.length) t.geo = geo.length > 3 ? `Ad sets targeting ${geo.length} places` : `Ad sets targeting ${geo.join(", ")}`;
  else if (Array.isArray(info.countries) && info.countries.length) t.geo = `Ad sets targeting ${info.countries.join(", ")} (country-wide)`;
  if (info.advantage !== undefined) t.advantage = info.advantage ? "Advantage+ audience on" : "Advantage+ audience off";
  if (info.lookalike) t.lookalike = "Ad sets using lookalike audiences";
  else if (info.custom_audiences) t.custom = "Ad sets using custom audiences";
  else if (N(info.interests) > 0) t.interests = "Ad sets using interest targeting";
  if (info.goal) t.goal = `Optimised for ${String(info.goal).replace(/_/g, " ").toLowerCase()}`;
  return t;
}

// ------------------------------------------------------------------ patterns
interface Item { key: string; group: string; label: string; spend: number; results: number }

function judge(items: Item[], goal: Goal, totalSpend: number, baseline: number | null, out: Pattern[]) {
  if (!baseline || totalSpend <= 0) return;
  for (const it of items) {
    if (it.spend <= 0) continue;
    const share = it.spend / totalSpend;
    if (share < 0.03 && it.results < PROVEN[goal]) continue;
    const cost = costPer(it.spend, it.results);
    // a win needs enough results; a loss needs enough spend that the average cost would have bought enough results
    const proven = it.spend >= 2 * baseline && (it.results >= PROVEN[goal] || (cost !== null && cost >= 1.4 * baseline && it.spend / baseline >= PROVEN[goal]));
    const lbl = GOAL_LABEL[goal];
    if (cost === null) {
      if (it.spend >= 2 * baseline) out.push({ id: it.key, tone: "loss", group: it.group,
        title: `${it.label}: ${inr(it.spend)} spent, no ${lbl.many}`,
        detail: `On average one ${lbl.one} costs ${inr(baseline)}; this spent ${(it.spend / baseline).toFixed(1)}x that without one.`,
        cost: null, baseline, ratio: null, results: 0, spend: it.spend, confidence: "proven" });
      continue;
    }
    const ratio = cost / baseline;
    if (ratio <= 0.8 || ratio >= 1.4) out.push({ id: it.key, tone: ratio <= 0.8 ? "win" : "loss", group: it.group,
      title: `${it.label}: ${inr(cost)} per ${lbl.one}, ${ratio >= 2 ? `${ratio.toFixed(1)}x the average cost` : `${pct(ratio)} ${ratio <= 0.8 ? "cheaper" : "dearer"} than average`}`,
      detail: `${it.results} ${it.results === 1 ? lbl.one : lbl.many} from ${inr(it.spend)} (average ${inr(baseline)} per ${lbl.one}).`,
      cost, baseline, ratio, results: it.results, spend: it.spend, confidence: proven ? "proven" : "early" });
  }
}

function groupBy(rows: BoardRow[], goal: Goal, traits: (info: Record<string, any>) => Record<string, string>, group: string): Item[] {
  const m = new Map<string, Item>();
  for (const r of rows) for (const [k, label] of Object.entries(traits(r.info ?? {}))) {
    const key = `${group}:${k}:${label}`;
    const it = m.get(key) ?? { key, group, label, spend: 0, results: 0 };
    it.spend += N(r.spend); it.results += N((r as any)[goal]); m.set(key, it);
  }
  // only traits that differ between ads (a trait every ad shares says nothing)
  const byTrait = new Map<string, Item[]>();
  for (const it of m.values()) { const t = it.key.split(":")[1]; byTrait.set(t, [...(byTrait.get(t) ?? []), it]); }
  return [...byTrait.values()].filter((xs) => xs.length > 1).flat();
}

const HOUR = (h: string) => { const n = Number(h); return `${n % 12 || 12} ${n < 12 ? "am" : "pm"}`; };
const DOW = ["", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"];
// Meta-only splits, each judged against its own total (every split of the same data has the same total).
// The breakdowns are whole-account, so they are left out when the view is filtered to a campaign or form.
function breakdownSets(data: any): Item[][] {
  const b = data?.breakdowns ?? {};
  const filtered = !!(data?.filters?.campaign || data?.filters?.form);
  const set = (kind: string, group: string, label: (r: any) => string) => (b[kind] ?? []).map((r: any) =>
    ({ key: `b:${kind}:${r.k1}:${r.k2}`, group, label: label(r), spend: N(r.spend), results: N(r.leads) }));
  const sets: Item[][] = filtered ? [] : [
    set("age_gender", "audience", (r) => `Ages ${r.k1}, ${r.k2 === "unknown" ? "gender unknown" : r.k2}`),
    set("region", "audience", (r) => `People in ${r.k1}`),
    set("placement", "audience", (r) => `${String(r.k1).replace(/^\w/, (c: string) => c.toUpperCase())} ${String(r.k2).replace(/_/g, " ")}`),
    set("device", "audience", (r) => `${String(r.k1).replace(/^\w/, (c: string) => c.toUpperCase())} users`),
    set("hour", "timing", (r) => `Around ${HOUR(r.k1)}`),
  ];
  sets.push((data?.weekday ?? []).map((r: any) => ({ key: `w:${r.dow}`, group: "timing", label: `On ${DOW[r.dow]}`, spend: N(r.spend), results: N(r.meta_leads) })));
  return sets.filter((xs) => xs.length > 1);
}

export function findPatterns(data: any): { goal: Goal; baseline: number | null; patterns: Pattern[] } {
  const cur: Totals = data?.current ?? {};
  const goal = chooseGoal(cur);
  const spend = N(cur.spend);
  const baseline = costPer(spend, N((cur as any)[goal]));
  const out: Pattern[] = [];
  const board = data?.board ?? {};
  const asItems = (rows: BoardRow[], group: string, prefix: string): Item[] =>
    rows.map((r) => ({ key: `${group}:${r.ext}`, group, label: `${prefix} "${r.name}"`, spend: N(r.spend), results: N((r as any)[goal]) }));
  judge(asItems(board.campaign ?? [], "campaign", "Campaign"), goal, spend, baseline, out);
  judge(asItems(board.adset ?? [], "adset", "Ad set"), goal, spend, baseline, out);
  judge(asItems(board.ad ?? [], "ad", "Ad"), goal, spend, baseline, out);
  judge(groupBy(board.ad ?? [], goal, creativeTraits, "creative"), goal, spend, baseline, out);
  judge(groupBy(board.adset ?? [], goal, audienceTraits, "targeting"), goal, spend, baseline, out);
  // Meta-only splits (age, region, placement, device, hour, weekday): Meta leads against their own average
  for (const items of breakdownSets(data)) {
    const sp = items.reduce((t, x) => t + x.spend, 0), rs = items.reduce((t, x) => t + x.results, 0);
    judge(items, "meta_leads", sp, costPer(sp, rs), out);
  }
  // ad fatigue
  const fat = (data?.fatigue ?? []).filter((w: any) => N(w.ads) >= 3);
  const drop = fat.find((w: any) => N(w.week) >= 2 && N(w.ctr_index) <= 0.8);
  if (drop) out.push({ id: "fatigue", tone: "info", group: "fatigue",
    title: `Ads tire by week ${drop.week}: click rate ${pct(N(drop.ctr_index))} below their first week`,
    detail: `Across ${drop.ads} ads with 4+ weeks of data. Plan a fresh creative every ${Math.max(1, N(drop.week) - 1)} week(s).`,
    cost: null, baseline: null, ratio: N(drop.ctr_index), results: 0, spend: 0, confidence: N(drop.ads) >= 6 ? "proven" : "early" });
  // proven first, then patterns judged on CRM results before Meta-lead-only splits, then by how much money they move
  const crm = (p: Pattern) => !["audience", "timing"].includes(p.group);
  const impact = (p: Pattern) => (p.confidence === "proven" ? 1e6 : 0) + (crm(p) ? 1e3 : 0) + (p.spend / Math.max(1, spend)) * Math.abs(1 - (p.ratio ?? 2));
  out.sort((a, b) => impact(b) - impact(a));
  const info = out.filter((p) => p.tone === "info");
  return { goal, baseline, patterns: [...out.filter((p) => p.tone !== "info").slice(0, 20), ...info] };
}

// ------------------------------------------------------------------ what-if
// Move `amount` of weekly budget from losing campaigns to proven winning ones, at their own past cost per result.
export function whatIf(data: any, weekly: number): null | { goal: Goal; moved: number; gain: number; from: string[]; to: string[]; winnerCost: number } {
  const { goal, baseline } = findPatterns(data);
  if (!baseline || weekly <= 0) return null;
  const weeks = Math.max(1, N(data?.period?.days) / 7);
  const rows: BoardRow[] = data?.board?.campaign ?? [];
  const scored = rows.map((r) => ({ r, cost: costPer(N(r.spend), N((r as any)[goal])), weeklySpend: N(r.spend) / weeks }));
  const winners = scored.filter((x) => x.cost !== null && x.cost <= 0.8 * baseline && N((x.r as any)[goal]) >= PROVEN[goal]);
  const losers = scored.filter((x) => x.weeklySpend > 0 && (x.cost === null || x.cost >= 1.4 * baseline));
  if (!winners.length || !losers.length) return null;
  const moved = Math.min(weekly, losers.reduce((s, x) => s + x.weeklySpend, 0));
  const winnerCost = winners.reduce((s, x) => s + N(x.r.spend), 0) / winners.reduce((s, x) => s + N((x.r as any)[goal]), 0);
  let lost = 0, left = moved;
  for (const x of losers) { const take = Math.min(left, x.weeklySpend); left -= take; lost += x.cost ? take / x.cost : 0; }
  return { goal, moved, gain: moved / winnerCost - lost, from: losers.map((x) => x.r.name), to: winners.map((x) => x.r.name), winnerCost };
}

// ------------------------------------------------------------------ monthly summary
export function reportText(month: string, data: any, patterns: Pattern[]) {
  const c: Totals = data?.current ?? {}, p: Totals = data?.previous ?? {};
  const label = new Date(`${month}T00:00:00Z`).toLocaleString("en-IN", { month: "long", year: "numeric", timeZone: "UTC" });
  const line = (name: string, a: number, b: number, money = false) => {
    const ch = b ? ` (${a >= b ? "+" : ""}${Math.round(((a - b) / b) * 100)}% vs previous month)` : "";
    return `${name}: ${money ? inr(a) : Math.round(a).toLocaleString("en-IN")}${ch}`;
  };
  const rows = [
    line("Spend", N(c.spend), N(p.spend), true), line("Meta leads", N(c.meta_leads), N(p.meta_leads)),
    line("Leads in the CRM", N(c.crm_leads), N(p.crm_leads)), line("Qualified", N(c.qualified), N(p.qualified)),
    line("Admissions", N(c.customers), N(p.customers)),
    `Cost per lead: ${inr(costPer(N(c.spend), N(c.meta_leads)))} | per qualified: ${inr(costPer(N(c.spend), N(c.qualified)))} | per admission: ${inr(costPer(N(c.spend), N(c.customers)))}`,
  ];
  const by = (tone: string, n: number) => patterns.filter((x) => x.tone === tone && (tone !== "info" || x.confidence === "proven")).slice(0, n);
  const top = [...by("win", 3), ...by("loss", 2), ...by("info", 1)]
    .map((x) => `${x.tone === "win" ? "+" : x.tone === "loss" ? "-" : "*"} ${x.title}${x.confidence === "early" ? " (early)" : ""}`);
  const subject = `Meta Ads summary - ${label}`;
  const text = `${subject}\n\n${rows.join("\n")}\n\nWhat stood out:\n${top.length ? top.join("\n") : "Not enough data for patterns yet."}\n\nFull dashboard: CRM > Meta Ads > Insights`;
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const html = `<div style="font-family:system-ui,sans-serif;max-width:640px"><h2 style="margin:0 0 12px">${esc(subject)}</h2>`
    + `<ul>${rows.map((r) => `<li>${esc(r)}</li>`).join("")}</ul><h3>What stood out</h3>`
    + `<ul>${(top.length ? top : ["Not enough data for patterns yet."]).map((r) => `<li>${esc(r)}</li>`).join("")}</ul>`
    + `<p style="color:#666">Full dashboard: CRM &gt; Meta Ads &gt; Insights</p></div>`;
  return { subject, text, html };
}
