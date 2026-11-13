// ADS connectors: Google Ads API (REST) and Meta Marketing API (Graph).
// Pure TypeScript (no Deno APIs) so it can be unit-tested with Node: `fetch` is injected.
// Secrets are passed in, used for one request, and never logged or returned.
//
// Versions come from ads_config (google_api_version, meta_api_version), never hardcoded here.
// Normalised campaign status: ENABLED | PAUSED | REMOVED | OTHER.

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export type ConnStatus = "connected" | "auth_required" | "permission_missing" | "rate_limited" | "sync_failed" | "unavailable";

export class AdsError extends Error {
  status: ConnStatus; http: number; sent: boolean;     // sent = the request may have reached the platform
  constructor(status: ConnStatus, message: string, http = 0, sent = false) {
    super(message); this.status = status; this.http = http; this.sent = sent;
  }
}

export interface CampaignRow {
  external_id: string; name: string | null; status: string; platform_status: string | null;
  objective: string | null; channel: string | null; daily_budget: number | null; budget_ref: string | null;
  raw: Record<string, unknown>;
}
export interface MetricRow {
  campaign_external_id: string; day: string; impressions: number | null; clicks: number | null; spend: number | null;
  conversions: number | null; conversion_value: number | null; reach: number | null; video_views: number | null;
  raw: Record<string, unknown>;
}
export interface AccountInfo { name: string | null; currency: string | null; timezone: string | null }

// ------------------------------------------------------------------ small helpers
export const num = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
export const microsToUnits = (v: unknown): number | null => {
  const n = num(v);
  return n === null ? null : Math.round(n / 10_000) / 100;          // 2 decimals
};
export const unitsToMicros = (v: number): string => String(Math.round(v * 100) * 10_000);

// Meta money fields (budgets) are in the currency's minimum unit. Offset 1 currencies per
// https://developers.facebook.com/docs/marketing-api/currencies ; everything else is 100.
const META_OFFSET_1 = new Set(["CLP", "COP", "CRC", "HUF", "ISK", "IDR", "JPY", "KRW", "PYG", "TWD", "VND"]);
export const metaOffset = (currency: string | null) => (currency && META_OFFSET_1.has(currency.toUpperCase()) ? 1 : 100);
export const metaMinorToUnits = (v: unknown, currency: string | null): number | null => {
  const n = num(v);
  return n === null ? null : Math.round((n / metaOffset(currency)) * 100) / 100;
};
export const unitsToMetaMinor = (v: number, currency: string | null): string => String(Math.round(v * metaOffset(currency)));

export function dateRange(days: number, today: string): { since: string; until: string } {
  const t = new Date(`${today}T00:00:00Z`);
  const s = new Date(t.getTime() - (Math.max(1, days) - 1) * 86_400_000);
  return { since: s.toISOString().slice(0, 10), until: today };
}
// Today's date in a time zone (the account's reporting day).
export function todayIn(tz: string, now = new Date()): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  } catch {
    return now.toISOString().slice(0, 10);
  }
}

export function scrubSecrets(s: string, secrets: Record<string, string>): string {
  let out = s;
  for (const v of Object.values(secrets || {})) if (typeof v === "string" && v.length >= 8) out = out.split(v).join("••••");
  return out.replace(/ya29\.[A-Za-z0-9\-_.]+/g, "ya29.••••").replace(/1\/\/[A-Za-z0-9\-_]{10,}/g, "1//••••")
    .replace(/EAA[A-Za-z0-9]{10,}/g, "EAA••••").replace(/access_token=[^&\s"]+/g, "access_token=••••");
}

async function readJson(r: Response): Promise<any> {
  const t = await r.text();
  try { return t ? JSON.parse(t) : {}; } catch { return { _text: t.slice(0, 300) }; }
}

// ------------------------------------------------------------------ Google Ads
export function googleErrorStatus(http: number, body: any): ConnStatus {
  const s = JSON.stringify(body ?? {});
  if (http === 401 || /UNAUTHENTICATED|invalid_grant|OAUTH_TOKEN/i.test(s)) return "auth_required";
  if (http === 429 || /RESOURCE_EXHAUSTED|RATE_EXCEEDED/i.test(s)) return "rate_limited";
  if (http === 403 || /PERMISSION_DENIED|NOT_APPROVED|CUSTOMER_NOT_ENABLED|ACTION_NOT_PERMITTED/i.test(s)) return "permission_missing";
  if (http >= 500) return "unavailable";
  return "sync_failed";
}
function googleMessage(body: any): string {
  if (/CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION/.test(JSON.stringify(body ?? {})))
    return "Your Google Cloud project only has Test access, which cannot open live accounts. Apply for Explorer/Basic access on the Google Ads API page of the Cloud Console.";
  const e = body?.error ?? (Array.isArray(body) ? body[0]?.error : undefined);
  const detail = e?.details?.[0]?.errors?.[0];
  return [e?.status, detail?.message ?? e?.message ?? body?.error_description ?? body?._text].filter(Boolean).join(": ").slice(0, 400)
    || "Google Ads request failed";
}

// Google retired developer tokens on 2026-09-09: access is now set per Google Cloud project (the project that owns the
// OAuth client), and the developer-token header is ignored (a future version will reject it), so it is not sent.
// https://developers.google.com/google-ads/api/docs/api-policy/access-levels
export interface GoogleCreds {
  developerToken?: string; clientId: string; clientSecret: string; refreshToken: string; loginCustomerId?: string; version: string;
}

export interface DiscoveredAccount {
  platform: "google" | "meta"; external_id: string; name: string | null; currency: string | null; timezone: string | null;
  status: string; active: boolean; login_customer_id?: string | null; business?: string | null;
}

export class GoogleAds {
  private tok: { t: string | null };                 // shared by withLogin() copies, so one sign-in serves every account
  private c: GoogleCreds; private fetchFn: Fetch;
  constructor(c: GoogleCreds, fetchFn: Fetch, tok?: { t: string | null }) {
    this.c = c; this.fetchFn = fetchFn; this.tok = tok ?? { t: null };
    for (const k of ["clientId", "clientSecret", "refreshToken", "version"] as const) {
      if (!c[k]) throw new AdsError("auth_required", `Google Ads ${k} is not set`);
    }
  }
  private async accessToken(): Promise<string> {
    if (this.tok.t) return this.tok.t;
    const r = await this.fetchFn("https://oauth2.googleapis.com/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", client_id: this.c.clientId, client_secret: this.c.clientSecret,
        refresh_token: this.c.refreshToken }).toString(),
    });
    const b = await readJson(r);
    if (!r.ok || !b.access_token) throw new AdsError("auth_required", `Google sign-in failed: ${b.error ?? r.status} ${b.error_description ?? ""}`.trim(), r.status);
    this.tok.t = b.access_token as string;
    return this.tok.t;
  }
  // The same client, calling through a specific manager account (accounts imported from under an MCC).
  withLogin(login?: string | null): GoogleAds {
    return login ? new GoogleAds({ ...this.c, loginCustomerId: login }, this.fetchFn, this.tok) : this;
  }
  // Accounts the signed-in Google user can open directly. login-customer-id is ignored by Google here.
  async listAccessible(): Promise<string[]> {
    let r: Response;
    const headers = { "Authorization": `Bearer ${await this.accessToken()}` };
    try { r = await this.fetchFn(`https://googleads.googleapis.com/${this.c.version}/customers:listAccessibleCustomers`, { method: "GET", headers }); }
    catch (e) { throw new AdsError("unavailable", `Network error talking to Google Ads: ${String(e).slice(0, 200)}`); }
    const b = await readJson(r);
    if (!r.ok) throw new AdsError(googleErrorStatus(r.status, b), googleMessage(b), r.status);
    return (b.resourceNames ?? []).map((n: string) => n.replace(/^customers\//, "")).filter((id: string) => /^\d{10}$/.test(id));
  }
  // Every client account reachable from one accessible account (itself, or the accounts under a manager).
  async hierarchy(rootId: string): Promise<DiscoveredAccount[]> {
    const rows = await this.withLogin(rootId).search(rootId,
      "SELECT customer_client.client_customer, customer_client.descriptive_name, customer_client.currency_code, " +
      "customer_client.time_zone, customer_client.manager, customer_client.status, customer_client.level FROM customer_client " +
      "WHERE customer_client.level <= 1");
    return rows.map((r) => r.customerClient ?? {}).filter((c: any) => c.manager !== true).map((c: any) => {
      const id = String(c.clientCustomer ?? "").replace(/^customers\//, "");
      return { platform: "google" as const, external_id: id, name: c.descriptiveName ?? null, currency: c.currencyCode ?? null,
        timezone: c.timeZone ?? null, status: c.status ?? "UNKNOWN", active: c.status === "ENABLED", login_customer_id: id === rootId ? null : rootId };
    }).filter((a) => /^\d{10}$/.test(a.external_id));
  }
  private async call(path: string, body: unknown, mutate = false): Promise<any> {
    const headers: Record<string, string> = { "Content-Type": "application/json", "Authorization": `Bearer ${await this.accessToken()}` };
    if (this.c.loginCustomerId) headers["login-customer-id"] = this.c.loginCustomerId;
    let r: Response;
    try {
      r = await this.fetchFn(`https://googleads.googleapis.com/${this.c.version}/${path}`, { method: "POST", headers, body: JSON.stringify(body) });
    } catch (e) {
      throw new AdsError("unavailable", `Network error talking to Google Ads: ${String(e).slice(0, 200)}`, 0, mutate);
    }
    const b = await readJson(r);
    if (!r.ok) throw new AdsError(googleErrorStatus(r.status, b), googleMessage(b), r.status, false);
    return b;
  }
  // One atomic googleAds:mutate. validateOnly = Google checks everything (incl. ad policy) and changes nothing.
  async mutate(customerId: string, mutateOperations: unknown[], validateOnly = false): Promise<any> {
    return this.call(`customers/${customerId}/googleAds:mutate`, { mutateOperations, partialFailure: false, validateOnly }, !validateOnly);
  }
  // Keyword Planner ideas (needs Basic access).
  async keywordIdeas(customerId: string, seeds: string[], geoIds: string[], languageId = "1000"): Promise<any[]> {
    const b = await this.call(`customers/${customerId}:generateKeywordIdeas`, {
      language: `languageConstants/${languageId}`, geoTargetConstants: geoIds.map((g) => `geoTargetConstants/${g}`),
      keywordPlanNetwork: "GOOGLE_SEARCH", includeAdultKeywords: false, keywordSeed: { keywords: seeds.slice(0, 20) }, pageSize: 300 });
    return b.results ?? [];
  }
  async search(customerId: string, query: string): Promise<any[]> {
    const out: any[] = [];
    let pageToken: string | undefined;
    for (let i = 0; i < 50; i++) {
      const b = await this.call(`customers/${customerId}/googleAds:search`, pageToken ? { query, pageToken } : { query });
      out.push(...(b.results ?? []));
      pageToken = b.nextPageToken;
      if (!pageToken) break;
    }
    return out;
  }
  async account(customerId: string): Promise<AccountInfo> {
    const r = await this.search(customerId, "SELECT customer.descriptive_name, customer.currency_code, customer.time_zone FROM customer LIMIT 1");
    const c = r[0]?.customer ?? {};
    return { name: c.descriptiveName ?? null, currency: c.currencyCode ?? null, timezone: c.timeZone ?? null };
  }
  async campaigns(customerId: string): Promise<CampaignRow[]> {
    const rows = await this.search(customerId,
      "SELECT campaign.id, campaign.name, campaign.status, campaign.advertising_channel_type, campaign_budget.resource_name, " +
      "campaign_budget.amount_micros, campaign_budget.explicitly_shared, campaign_budget.period, " +
      "campaign.primary_status, campaign.primary_status_reasons, campaign.serving_status FROM campaign WHERE campaign.status != 'REMOVED'");
    return rows.map(parseGoogleCampaign);
  }
  async metrics(customerId: string, since: string, until: string): Promise<MetricRow[]> {
    const rows = await this.search(customerId,
      "SELECT campaign.id, segments.date, metrics.impressions, metrics.clicks, metrics.cost_micros, metrics.conversions, " +
      `metrics.conversions_value, metrics.video_trueview_views FROM campaign WHERE segments.date BETWEEN '${since}' AND '${until}'`);
    return rows.map(parseGoogleMetric);
  }
  async campaignState(customerId: string, campaignId: string): Promise<{ status: string; daily_budget: number | null }> {
    if (!/^\d+$/.test(campaignId)) throw new AdsError("sync_failed", "bad campaign id");
    const r = await this.search(customerId, `SELECT campaign.status, campaign_budget.amount_micros FROM campaign WHERE campaign.id = ${campaignId}`);
    if (!r[0]) throw new AdsError("sync_failed", "Campaign not found in Google Ads");
    return { status: normGoogleStatus(r[0].campaign?.status), daily_budget: microsToUnits(r[0].campaignBudget?.amountMicros) };
  }
  async setBudget(customerId: string, budgetRef: string, units: number) {
    return this.call(`customers/${customerId}/campaignBudgets:mutate`, {
      operations: [{ update: { resourceName: budgetRef, amountMicros: unitsToMicros(units) }, updateMask: "amount_micros" }],
    }, true);
  }
  async setStatus(customerId: string, campaignId: string, status: "ENABLED" | "PAUSED") {
    return this.call(`customers/${customerId}/campaigns:mutate`, {
      operations: [{ update: { resourceName: `customers/${customerId}/campaigns/${campaignId}`, status }, updateMask: "status" }],
    }, true);
  }
}

export const normGoogleStatus = (s: unknown) => (s === "ENABLED" || s === "PAUSED" || s === "REMOVED" ? (s as string) : "OTHER");

export function parseGoogleCampaign(r: any): CampaignRow {
  const c = r.campaign ?? {}, b = r.campaignBudget ?? {};
  const daily = b.period === undefined || b.period === "DAILY";
  const editable = daily && b.explicitlyShared !== true && !!b.resourceName;
  return {
    external_id: String(c.id), name: c.name ?? null, status: normGoogleStatus(c.status), platform_status: c.status ?? null,
    objective: null, channel: c.advertisingChannelType ?? null,
    daily_budget: daily ? microsToUnits(b.amountMicros) : null,
    budget_ref: editable ? b.resourceName : null,
    // Why Google is (not) serving it: CampaignPrimaryStatus + reasons (v26 campaign fields).
    raw: { budget_shared: b.explicitlyShared ?? null, budget_period: b.period ?? null,
      primary_status: c.primaryStatus ?? null, primary_status_reasons: Array.isArray(c.primaryStatusReasons) ? c.primaryStatusReasons : [],
      serving_status: c.servingStatus ?? null },
  };
}
export function parseGoogleMetric(r: any): MetricRow {
  const m = r.metrics ?? {};
  return {
    campaign_external_id: String(r.campaign?.id), day: r.segments?.date,
    impressions: num(m.impressions) ?? 0, clicks: num(m.clicks) ?? 0, spend: microsToUnits(m.costMicros) ?? 0,
    conversions: num(m.conversions) ?? 0, conversion_value: num(m.conversionsValue) ?? 0,
    reach: null, video_views: num(m.videoTrueviewViews), raw: {},   // v26: metrics.video_views was replaced by video_trueview_views
  };
}

// ------------------------------------------------------------------ Meta
export function metaErrorStatus(http: number, body: any): ConnStatus {
  const code = Number(body?.error?.code);
  if (code === 190 || code === 102 || http === 401) return "auth_required";
  if ([4, 17, 32, 613, 80000, 80003, 80004].includes(code) || http === 429) return "rate_limited";
  if (code === 10 || code === 200 || (code >= 200 && code < 300) || code === 270 || http === 403) return "permission_missing";
  if (code === 1 || code === 2 || http >= 500) return "unavailable";
  return "sync_failed";
}
const metaMessage = (b: any) => (b?.error ? `${b.error.type ?? "Error"} ${b.error.code ?? ""}: ${b.error.error_user_msg ?? b.error.message ?? ""}` : (b?._text ?? "Meta request failed")).slice(0, 400);

export interface MetaCreds { accessToken: string; appSecret?: string; version: string; hmac?: (key: string, msg: string) => Promise<string> }

export class MetaAds {
  private c: MetaCreds; private fetchFn: Fetch;
  constructor(c: MetaCreds, fetchFn: Fetch) {
    this.c = c; this.fetchFn = fetchFn;
    if (!c.accessToken) throw new AdsError("auth_required", "Meta access token is not set");
    if (!c.version) throw new AdsError("sync_failed", "Meta API version is not set");
  }
  private async params(extra: Record<string, string> = {}): Promise<URLSearchParams> {
    const p = new URLSearchParams(extra);
    if (this.c.appSecret && this.c.hmac) p.set("appsecret_proof", await this.c.hmac(this.c.appSecret, this.c.accessToken));
    return p;
  }
  private async req(method: "GET" | "POST", pathOrUrl: string, q: Record<string, string> = {}, mutate = false): Promise<any> {
    const url = pathOrUrl.startsWith("https://") ? pathOrUrl : `https://graph.facebook.com/${this.c.version}/${pathOrUrl}`;
    const p = await this.params(q);
    let r: Response;
    try {
      r = method === "GET"
        ? await this.fetchFn(pathOrUrl.startsWith("https://") ? url : `${url}?${p}`, { headers: { Authorization: `Bearer ${this.c.accessToken}` } })
        : await this.fetchFn(url, { method: "POST", headers: { Authorization: `Bearer ${this.c.accessToken}`, "Content-Type": "application/x-www-form-urlencoded" }, body: p.toString() });
    } catch (e) {
      throw new AdsError("unavailable", `Network error talking to Meta: ${String(e).slice(0, 200)}`, 0, mutate);
    }
    const b = await readJson(r);
    if (!r.ok || b?.error) throw new AdsError(metaErrorStatus(r.status, b), metaMessage(b), r.status, false);
    return b;
  }
  private async all(path: string, q: Record<string, string>): Promise<any[]> {
    const out: any[] = [];
    let b = await this.req("GET", path, q);
    for (let i = 0; i < 50; i++) {
      out.push(...(b.data ?? []));
      const next: string | undefined = b.paging?.next;
      if (!next || !next.startsWith("https://graph.facebook.com/")) break;
      b = await this.req("GET", next);
    }
    return out;
  }
  async me() { return this.req("GET", "me", { fields: "id,name" }); }
  // Ad accounts the token can use (needs ads_read).
  async adAccounts(): Promise<DiscoveredAccount[]> {
    const rows = await this.all("me/adaccounts", { fields: "account_id,name,currency,timezone_name,account_status,business{name}", limit: "200" });
    return rows.map((r) => ({ platform: "meta" as const, external_id: String(r.account_id ?? "").replace(/^act_/, ""), name: r.name ?? null,
      currency: r.currency ?? null, timezone: r.timezone_name ?? null, status: META_ACCOUNT_STATUS[Number(r.account_status)] ?? `status ${r.account_status}`,
      active: Number(r.account_status) === 1, business: r.business?.name ?? null })).filter((a) => /^\d{5,25}$/.test(a.external_id));
  }
  async account(accountId: string): Promise<AccountInfo> {
    const b = await this.req("GET", `act_${accountId}`, { fields: "name,currency,timezone_name,account_status" });
    return { name: b.name ?? null, currency: b.currency ?? null, timezone: b.timezone_name ?? null };
  }
  async campaigns(accountId: string, currency: string | null): Promise<CampaignRow[]> {
    const rows = await this.all(`act_${accountId}/campaigns`, { fields: "id,name,status,effective_status,objective,daily_budget,lifetime_budget", limit: "200" });
    return rows.map((r) => parseMetaCampaign(r, currency));
  }
  async metrics(accountId: string, since: string, until: string): Promise<MetricRow[]> {
    const rows = await this.all(`act_${accountId}/insights`, {
      level: "campaign", fields: "campaign_id,spend,impressions,clicks,reach,actions,action_values,video_play_actions",
      time_range: JSON.stringify({ since, until }), time_increment: "1", limit: "500",
    });
    return rows.map(parseMetaInsight);
  }
  async campaignState(campaignId: string, currency: string | null) {
    const b = await this.req("GET", campaignId, { fields: "status,daily_budget" });
    return { status: normMetaStatus(b.status), daily_budget: metaMinorToUnits(b.daily_budget, currency) };
  }
  async setBudget(campaignId: string, units: number, currency: string | null) {
    return this.req("POST", campaignId, { daily_budget: unitsToMetaMinor(units, currency) }, true);
  }
  async setStatus(campaignId: string, status: "ENABLED" | "PAUSED") {
    return this.req("POST", campaignId, { status: status === "ENABLED" ? "ACTIVE" : "PAUSED" }, true);
  }
}

// Ad account account_status values (Marketing API, Ad Account reference).
export const META_ACCOUNT_STATUS: Record<number, string> = { 1: "ACTIVE", 2: "DISABLED", 3: "UNSETTLED", 7: "PENDING_RISK_REVIEW",
  8: "PENDING_SETTLEMENT", 9: "IN_GRACE_PERIOD", 100: "PENDING_CLOSURE", 101: "CLOSED", 201: "ANY_ACTIVE", 202: "ANY_CLOSED" };

export const normMetaStatus = (s: unknown) => (s === "ACTIVE" ? "ENABLED" : s === "PAUSED" ? "PAUSED" : s === "DELETED" || s === "ARCHIVED" ? "REMOVED" : "OTHER");

export function parseMetaCampaign(r: any, currency: string | null): CampaignRow {
  const hasDaily = r.daily_budget !== undefined && r.daily_budget !== null && r.daily_budget !== "" && r.daily_budget !== "0";
  return {
    external_id: String(r.id), name: r.name ?? null, status: normMetaStatus(r.status), platform_status: r.effective_status ?? r.status ?? null,
    objective: r.objective ?? null, channel: null,
    daily_budget: hasDaily ? metaMinorToUnits(r.daily_budget, currency) : null,
    budget_ref: hasDaily ? "campaign" : null,            // ad-set budgets (ABO) and lifetime budgets are not changed from here
    raw: { lifetime_budget: r.lifetime_budget ?? null },
  };
}

// Platform conversions for Meta: the "lead" action (Meta's own total across lead types); value from "purchase".
// The full actions list is kept in raw so nothing is lost.
const pick = (arr: any[] | undefined, type: string) => num((arr ?? []).find((a) => a?.action_type === type)?.value);
export function parseMetaInsight(r: any): MetricRow {
  return {
    campaign_external_id: String(r.campaign_id), day: r.date_start,
    impressions: num(r.impressions) ?? 0, clicks: num(r.clicks) ?? 0, spend: num(r.spend) ?? 0,
    conversions: pick(r.actions, "lead") ?? pick(r.actions, "purchase") ?? 0,
    conversion_value: pick(r.action_values, "purchase") ?? 0,
    reach: num(r.reach), video_views: pick(r.video_play_actions, "video_view"),
    raw: { actions: r.actions ?? [], action_values: r.action_values ?? [] },
  };
}

// ------------------------------------------------------------------ execution of one approved change
export interface WorkItem {
  id: string; kind: "budget" | "status"; after: { daily_budget?: number; status?: string };
  platform: "google" | "meta"; account_external_id: string; campaign_external_id: string; budget_ref: string | null;
  login_customer_id?: string | null;
}
export interface Platforms { google?: GoogleAds; meta?: MetaAds; metaCurrency?: (accountExternalId: string) => string | null }

const matches = (w: WorkItem, s: { status: string; daily_budget: number | null }) =>
  w.kind === "budget" ? s.daily_budget !== null && Math.abs(s.daily_budget - Number(w.after.daily_budget)) < 0.01
                      : s.status === String(w.after.status).toUpperCase();

export async function readState(p: Platforms, w: WorkItem) {
  if (w.platform === "google") {
    if (!p.google) throw new AdsError("auth_required", "Google Ads is not configured");
    return p.google.withLogin(w.login_customer_id).campaignState(w.account_external_id, w.campaign_external_id);
  }
  if (!p.meta) throw new AdsError("auth_required", "Meta is not configured");
  return p.meta.campaignState(w.campaign_external_id, p.metaCurrency?.(w.account_external_id) ?? null);
}

// Sends one change, then reads the platform back. Never reports success because a request was sent.
// Result: verified (platform shows the new value), failed (platform refused, or shows the old value),
// outcome_unknown (the request may or may not have landed; it will be re-checked, never blindly re-sent).
export async function executeOne(p: Platforms, w: WorkItem): Promise<{ status: "verified" | "failed" | "outcome_unknown"; error?: string; verify?: unknown }> {
  try {
    if (w.platform === "google") {
      if (!p.google) throw new AdsError("auth_required", "Google Ads is not configured");
      if (w.kind === "budget") {
        if (!w.budget_ref) throw new AdsError("sync_failed", "No campaign budget to change");
        await p.google.withLogin(w.login_customer_id).setBudget(w.account_external_id, w.budget_ref, Number(w.after.daily_budget));
      } else await p.google.withLogin(w.login_customer_id).setStatus(w.account_external_id, w.campaign_external_id, String(w.after.status).toUpperCase() as "ENABLED" | "PAUSED");
    } else {
      if (!p.meta) throw new AdsError("auth_required", "Meta is not configured");
      if (w.kind === "budget") {
        if (w.budget_ref !== "campaign") throw new AdsError("sync_failed", "This campaign has no campaign-level daily budget");
        await p.meta.setBudget(w.campaign_external_id, Number(w.after.daily_budget), p.metaCurrency?.(w.account_external_id) ?? null);
      } else await p.meta.setStatus(w.campaign_external_id, String(w.after.status).toUpperCase() as "ENABLED" | "PAUSED");
    }
  } catch (e) {
    if (e instanceof AdsError && !e.sent) return { status: "failed", error: e.message };
    return { status: "outcome_unknown", error: e instanceof Error ? e.message : String(e) };
  }
  return verify(p, w);
}

export async function verify(p: Platforms, w: WorkItem): Promise<{ status: "verified" | "failed" | "outcome_unknown"; error?: string; verify?: unknown }> {
  try {
    const s = await readState(p, w);
    return matches(w, s) ? { status: "verified", verify: s }
      : { status: "failed", error: "The platform does not show the new value after the change.", verify: s };
  } catch (e) {
    return { status: "outcome_unknown", error: `Sent, but could not read the campaign back: ${e instanceof Error ? e.message : String(e)}` };
  }
}

// Finds every Google Ads and Meta ad account the saved keys can reach, for "Import existing accounts".
// Each platform is independent: one failing (or not configured) never hides the other's results.
export async function discover(p: Platforms, maxRoots = 20): Promise<Record<"google" | "meta", { ok: boolean; error?: string; accounts: DiscoveredAccount[] }>> {
  const out = { google: { ok: false, accounts: [] as DiscoveredAccount[] } as { ok: boolean; error?: string; accounts: DiscoveredAccount[] },
                meta: { ok: false, accounts: [] as DiscoveredAccount[] } as { ok: boolean; error?: string; accounts: DiscoveredAccount[] } };
  if (!p.google) out.google.error = "Google Ads keys are not set";
  else {
    try {
      const roots = (await p.google.listAccessible()).slice(0, maxRoots);
      const seen = new Map<string, DiscoveredAccount>();
      const problems: string[] = [];
      for (const root of roots) {
        try {
          for (const a of await p.google.hierarchy(root)) {
            const prev = seen.get(a.external_id);
            if (!prev || (prev.login_customer_id && !a.login_customer_id)) seen.set(a.external_id, a);   // prefer direct access
          }
        } catch (e) { problems.push(`${root}: ${e instanceof Error ? e.message : String(e)}`); }
      }
      out.google = { ok: true, accounts: [...seen.values()].sort((x, y) => Number(y.active) - Number(x.active) || String(x.name).localeCompare(String(y.name))),
        ...(problems.length ? { error: problems.slice(0, 3).join(" | ") } : {}) };
    } catch (e) { out.google.error = e instanceof Error ? e.message : String(e); }
  }
  if (!p.meta) out.meta.error = "Meta access token is not set";
  else {
    try {
      const accts = await p.meta.adAccounts();
      out.meta = { ok: true, accounts: accts.sort((x, y) => Number(y.active) - Number(x.active) || String(x.name).localeCompare(String(y.name))) };
    } catch (e) { out.meta.error = e instanceof Error ? e.message : String(e); }
  }
  return out;
}
