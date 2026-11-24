// Google Business Profile: request addresses and answer parsers for the crm-google-business Edge Function.
// Pure functions (no network), so every shape Google can send is tested in supabase/tests/gbp/gbp.test.ts.
// APIs: Account Management v1 (accounts), Business Information v1 (locations), Business Profile Performance v1
// (daily numbers, monthly search words), My Business v4 (reviews). One scope: https://www.googleapis.com/auth/business.manage.

// The daily numbers Google publishes for a profile (food-ordering ones are left out: not a restaurant CRM).
export const DAILY_METRICS = ["BUSINESS_IMPRESSIONS_DESKTOP_MAPS", "BUSINESS_IMPRESSIONS_DESKTOP_SEARCH", "BUSINESS_IMPRESSIONS_MOBILE_MAPS",
  "BUSINESS_IMPRESSIONS_MOBILE_SEARCH", "BUSINESS_CONVERSATIONS", "BUSINESS_DIRECTION_REQUESTS", "CALL_CLICKS", "WEBSITE_CLICKS",
  "MESSAGING_CLICKS", "BUSINESS_BOOKINGS"] as const;

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const p2 = (n: number) => String(n).padStart(2, "0");
const parts = (d: string) => { if (!ISO.test(d)) throw new Error(`bad date ${d}`); const [y, m, day] = d.split("-").map(Number); return { y, m, day }; };
export const addDays = (d: string, n: number) => new Date(Date.UTC(parts(d).y, parts(d).m - 1, parts(d).day + n)).toISOString().slice(0, 10);

// The last n complete months before `today`, newest first: [{y, m, first: "YYYY-MM-01"}].
export function monthsBack(today: string, n: number): { y: number; m: number; first: string }[] {
  const { y, m } = parts(today); const out = [];
  for (let i = 1; i <= n; i++) { const d = new Date(Date.UTC(y, m - 1 - i, 1)); out.push({ y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, first: `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-01` }); }
  return out;
}

const okLoc = (name: string) => { if (!/^locations\/\d+$/.test(name)) throw new Error("bad location name"); return name; };
const okAcc = (name: string) => { if (!/^accounts\/\d+$/.test(name)) throw new Error("bad account name"); return name; };

export function accountsUrl(pageToken?: string | null): string {
  return "https://mybusinessaccountmanagement.googleapis.com/v1/accounts?pageSize=20" + (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : "");
}
export function parseAccounts(b: any): { rows: { name: string; label: string }[]; next: string | null } {
  const rows = (Array.isArray(b?.accounts) ? b.accounts : []).filter((a: any) => /^accounts\/\d+$/.test(String(a?.name)))
    .map((a: any) => ({ name: String(a.name), label: String(a.accountName ?? "") }));
  return { rows, next: b?.nextPageToken ? String(b.nextPageToken) : null };
}

export function locationsUrl(account: string, pageToken?: string | null): string {
  const mask = "name,title,storefrontAddress,websiteUri,phoneNumbers,categories,metadata";
  return `https://mybusinessbusinessinformation.googleapis.com/v1/${okAcc(account)}/locations?readMask=${mask}&pageSize=100` +
    (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : "");
}
export interface LocRow { account: string; name: string; title: string; address: string; phone: string; website: string; category: string; maps_uri: string; place_id: string; verified: boolean | null }
export function parseLocations(b: any, account: string): { rows: LocRow[]; next: string | null } {
  const rows = (Array.isArray(b?.locations) ? b.locations : []).filter((l: any) => /^locations\/\d+$/.test(String(l?.name))).map((l: any) => {
    const a = l.storefrontAddress ?? {};
    const address = [...(Array.isArray(a.addressLines) ? a.addressLines : []), a.locality, a.administrativeArea, a.postalCode].filter((x) => x && String(x).trim()).join(", ");
    return { account, name: String(l.name), title: String(l.title ?? ""), address, phone: String(l.phoneNumbers?.primaryPhone ?? ""),
      website: String(l.websiteUri ?? ""), category: String(l.categories?.primaryCategory?.displayName ?? ""),
      maps_uri: String(l.metadata?.mapsUri ?? ""), place_id: String(l.metadata?.placeId ?? ""),
      verified: typeof l.metadata?.hasVoiceOfMerchant === "boolean" ? l.metadata.hasVoiceOfMerchant : null };
  });
  return { rows, next: b?.nextPageToken ? String(b.nextPageToken) : null };
}

// Daily numbers for one profile, all metrics in one request (from and to inclusive).
export function metricsUrl(location: string, from: string, to: string): string {
  const f = parts(from), t = parts(to);
  const q = [...DAILY_METRICS.map((m) => `dailyMetrics=${m}`),
    `dailyRange.start_date.year=${f.y}`, `dailyRange.start_date.month=${f.m}`, `dailyRange.start_date.day=${f.day}`,
    `dailyRange.end_date.year=${t.y}`, `dailyRange.end_date.month=${t.m}`, `dailyRange.end_date.day=${t.day}`];
  return `https://businessprofileperformance.googleapis.com/v1/${okLoc(location)}:fetchMultiDailyMetricsTimeSeries?${q.join("&")}`;
}
// -> [{d: "2026-11-01", m: "CALL_CLICKS", v: 3}]. Google leaves "value" out on days with 0; those are kept as 0 so a day is never missing.
export function parseMetrics(b: any): { d: string; m: string; v: number }[] {
  const out: { d: string; m: string; v: number }[] = [];
  for (const multi of Array.isArray(b?.multiDailyMetricTimeSeries) ? b.multiDailyMetricTimeSeries : []) {
    for (const s of Array.isArray(multi?.dailyMetricTimeSeries) ? multi.dailyMetricTimeSeries : []) {
      const m = String(s?.dailyMetric ?? "");
      if (!/^[A-Z_]{3,60}$/.test(m) || s?.dailySubEntityType) continue;      // breakdown rows would double count
      for (const dv of Array.isArray(s?.timeSeries?.datedValues) ? s.timeSeries.datedValues : []) {
        const y = Number(dv?.date?.year), mo = Number(dv?.date?.month), day = Number(dv?.date?.day);
        if (!(y > 2000 && mo >= 1 && mo <= 12 && day >= 1 && day <= 31)) continue;
        const v = Number(dv?.value ?? 0);
        out.push({ d: `${y}-${p2(mo)}-${p2(day)}`, m, v: Number.isFinite(v) && v > 0 ? Math.round(v) : 0 });
      }
    }
  }
  return out;
}

// Search words for ONE month (Google sums whatever range is asked, so months are asked one at a time).
export function keywordsUrl(location: string, y: number, m: number, pageToken?: string | null): string {
  const q = [`monthlyRange.start_month.year=${y}`, `monthlyRange.start_month.month=${m}`, `monthlyRange.end_month.year=${y}`, `monthlyRange.end_month.month=${m}`, "pageSize=100"];
  if (pageToken) q.push(`pageToken=${encodeURIComponent(pageToken)}`);
  return `https://businessprofileperformance.googleapis.com/v1/${okLoc(location)}/searchkeywords/impressions/monthly?${q.join("&")}`;
}
export function parseKeywords(b: any): { rows: { k: string; v: number | null; below: number | null }[]; next: string | null } {
  const rows = [];
  for (const r of Array.isArray(b?.searchKeywordsCounts) ? b.searchKeywordsCounts : []) {
    const k = String(r?.searchKeyword ?? "").trim().toLowerCase();
    const v = r?.insightsValue?.value != null ? Number(r.insightsValue.value) : null;
    const below = r?.insightsValue?.threshold != null ? Number(r.insightsValue.threshold) : null;
    if (!k || (!(v != null && Number.isFinite(v) && v >= 0) && !(below != null && Number.isFinite(below) && below > 0))) continue;
    rows.push({ k: k.slice(0, 200), v: v != null && Number.isFinite(v) ? Math.round(v) : null, below: v == null && below != null ? Math.round(below) : null });
  }
  return { rows, next: b?.nextPageToken ? String(b.nextPageToken) : null };
}

export function reviewsUrl(account: string, location: string, pageToken?: string | null): string {
  return `https://mybusiness.googleapis.com/v4/${okAcc(account)}/${okLoc(location)}/reviews?pageSize=50&orderBy=${encodeURIComponent("updateTime desc")}` +
    (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : "");
}
const STARS: Record<string, number> = { ONE: 1, TWO: 2, THREE: 3, FOUR: 4, FIVE: 5 };
const iso = (t: unknown) => { const d = new Date(String(t ?? "")); return Number.isNaN(d.getTime()) ? null : d.toISOString(); };
export interface ReviewRow { id: string; reviewer: string; stars: number | null; comment: string; created: string | null; updated: string | null; reply: string; reply_at: string | null }
export function parseReviews(b: any): { rows: ReviewRow[]; total: number | null; rating: number | null; next: string | null } {
  const rows = (Array.isArray(b?.reviews) ? b.reviews : []).filter((r: any) => r?.reviewId).map((r: any) => ({
    id: String(r.reviewId), reviewer: r.reviewer?.isAnonymous ? "A Google user" : String(r.reviewer?.displayName ?? "A Google user").slice(0, 120),
    stars: STARS[String(r.starRating)] ?? null, comment: String(r.comment ?? ""), created: iso(r.createTime), updated: iso(r.updateTime),
    reply: String(r.reviewReply?.comment ?? ""), reply_at: r.reviewReply ? iso(r.reviewReply.updateTime) : null }));
  const total = Number(b?.totalReviewCount), rating = Number(b?.averageRating);
  return { rows, total: Number.isInteger(total) && total >= 0 ? total : null, rating: rating >= 1 && rating <= 5 ? rating : null,
    next: b?.nextPageToken ? String(b.nextPageToken) : null };
}

// What a failed Google call means for the person looking at the screen.
//   waiting_google  the Cloud project is not approved for the Business Profile APIs yet (quota 0)
//   needs_signin    the saved login no longer works, or was made without the Business Profile permission
//   api_off         one of the APIs is switched off in the Cloud project
//   no_access       this Google user does not manage the profile
//   busy            Google's per-minute limit; the next run continues
export type GbpState = "waiting_google" | "needs_signin" | "api_off" | "no_access" | "busy" | "error";
export function gbpError(api: string, status: number, b: any): { state: GbpState; message: string } {
  // Google's own words are shown, but never anything shaped like a token or key (defence in depth: Google does not echo them).
  const e = b?.error ?? {}, all = JSON.stringify(b ?? {});
  const msg = String(typeof e === "string" ? e : (e.message ?? status)).replace(/(1\/\/|ya29\.|AIza|GOCSPX-)[A-Za-z0-9._\/-]{6,}/g, "[hidden]");
  if (status === 401 || /invalid_grant|invalid credentials|UNAUTHENTICATED/i.test(all))
    return { state: "needs_signin", message: "Google no longer accepts this sign-in. Sign in again and save the new token." };
  if (status === 403 && /insufficient.{0,40}scope|ACCESS_TOKEN_SCOPE_INSUFFICIENT/i.test(all))
    return { state: "needs_signin", message: "This sign-in was made without the Business Profile permission. Make a new one that includes the business.manage scope." };
  if (status === 403 && /SERVICE_DISABLED|has not been used in project|it is disabled/i.test(all))
    return { state: "api_off", message: `"${api}" is switched off in the Google Cloud project. Turn it on under APIs & Services > Library, then refresh.` };
  if (status === 429 && /quota_limit_value\\?"\s*:\s*\\?"0\\?"/.test(all))
    return { state: "waiting_google", message: "Google has not approved this Cloud project for the Business Profile APIs yet (the quota is 0). Nothing can be read until Google's approval email arrives." };
  if (status === 429) return { state: "busy", message: "Google's per-minute limit was reached. The next run continues from here." };
  if (status === 403 || status === 404)
    return { state: "no_access", message: `${api}: this Google user is not an owner or manager of the profile (or it no longer exists). ${msg}`.slice(0, 300) };
  return { state: "error", message: `${api}: ${msg}`.slice(0, 300) };
}
