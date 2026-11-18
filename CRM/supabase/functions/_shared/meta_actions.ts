// Meta Ads > Automate (migration 110): pure helpers for the ads-sync job meta_actions (quick actions, rule actions, split tests).
import { minor } from "./meta_build.ts";
import { metaMinorToUnits } from "./ads_core.ts";

export interface Live { status: string | null; effective_status: string | null; daily_budget: number | null; lifetime_budget: number | null; name: string | null }
export const FIELDS: Record<string, string> = {
  campaign: "name,status,effective_status,daily_budget,lifetime_budget",
  adset: "name,status,effective_status,daily_budget,lifetime_budget",
  ad: "name,status,effective_status",
};
export function live(b: any, currency: string | null): Live {
  return { status: b?.status ?? null, effective_status: b?.effective_status ?? null, name: b?.name ?? null,
    daily_budget: metaMinorToUnits(b?.daily_budget, currency), lifetime_budget: metaMinorToUnits(b?.lifetime_budget, currency) };
}

// What to send to Meta for one action, given the object as it is now. "skip" = already in the wanted state.
export function plan(kind: string, level: string, params: any, now: Live, currency: string | null, lo: number, hi: number):
  { send?: Record<string, string>; path?: "object" | "copies"; skip?: string; error?: string; daily?: number } {
  if (now.status === "DELETED" || now.status === "ARCHIVED") return { error: `The ${level} is ${String(now.status).toLowerCase()} in Meta` };
  if (kind === "pause") return now.status === "PAUSED" ? { skip: "Already paused" } : { path: "object", send: { status: "PAUSED" } };
  if (kind === "activate") return now.status === "ACTIVE" ? { skip: "Already on" } : { path: "object", send: { status: "ACTIVE" } };
  if (kind === "duplicate") {
    const send: Record<string, string> = { status_option: "PAUSED", rename_strategy: "ONLY_TOP_LEVEL_RENAME", rename_suffix: " - copy (CRM)" };
    if (level !== "ad") send.deep_copy = "true";
    return { path: "copies", send };
  }
  if (kind === "budget") {
    if (level === "ad") return { error: "Ads have no budget of their own" };
    if (now.daily_budget === null) return { error: now.lifetime_budget !== null ? "This object has a lifetime budget, not a daily one" : `This ${level === "adset" ? "ad set" : level} has no daily budget of its own (the ${level === "adset" ? "campaign" : "ad sets"} hold it)` };
    const target = params?.daily !== undefined && params?.daily !== null ? Number(params.daily) : Math.round(now.daily_budget * (1 + Number(params?.pct) / 100));
    if (!Number.isFinite(target)) return { error: "No new budget given" };
    const daily = Math.min(hi, Math.max(lo, Math.round(target)));
    if (daily === Math.round(now.daily_budget)) return { skip: `Budget already ₹${daily}` };
    return { path: "object", send: { daily_budget: String(minor(daily, currency)) }, daily };
  }
  return { error: `Unknown action ${kind}` };
}

// Did Meta end up where we asked?
export function verified(kind: string, after: Live, daily?: number): boolean {
  if (kind === "pause") return after.status === "PAUSED";
  if (kind === "activate") return after.status === "ACTIVE";
  if (kind === "budget") return after.daily_budget !== null && Math.abs(after.daily_budget - Number(daily)) < 1;
  return true;
}

// A Meta split test (ad study): equal shares, non-overlapping audiences, times in UNIX seconds (IST day boundaries).
export function studyParams(t: { name: string; hypothesis?: string | null; level: string; cells: { name: string; ids: string[] }[]; start_date: string; end_date: string }, nowSec: number) {
  const n = t.cells.length;
  const share = Math.floor(100 / n);
  const key = t.level === "campaign" ? "campaigns" : "adsets";
  const start = Math.max(nowSec + 600, Math.floor(Date.parse(`${t.start_date}T00:00:00+05:30`) / 1000));
  const end = Math.floor(Date.parse(`${t.end_date}T23:59:59+05:30`) / 1000);
  return {
    name: `${t.name} (CRM)`.slice(0, 100), description: String(t.hypothesis ?? "").slice(0, 300), type: "SPLIT_TEST",
    start_time: String(start), end_time: String(end),
    cells: JSON.stringify(t.cells.map((c) => ({ name: c.name, treatment_percentage: share, [key]: c.ids }))),
  };
}
