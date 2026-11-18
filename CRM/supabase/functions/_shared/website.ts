// CRM > Website (migration 112): pure helpers for the crm-website Edge Function. No network here, so all of it is unit-tested.
// Sources, all official and free:
//  * Search Console API: searchAnalytics.query (date, query, page, device, country, searchAppearance, query+page),
//    urlInspection.index.inspect (2,000 a day per site), sitemaps.list.
//  * GA4 Data API: runReport (28 days and the 28 before) and runRealtimeReport (last 30 minutes).
//  * PageSpeed Insights API v5: Chrome UX Report field data (real users, p75) plus a Lighthouse lab run.
//  * The site itself: sitemap.xml, robots.txt, llms.txt and each page's HTML (title, description, H1, canonical, schema, links).

export type Win = "cur" | "prev";
export interface WebRow { src: "gsc" | "ga"; kind: string; k1: string; k2: string; win: Win; m: Record<string, number> }

// ---------------------------------------------------------------- Search Console
export const GSC_REPORTS: { kind: string; dims: string[]; limit: number }[] = [
  { kind: "date", dims: ["date"], limit: 100 },              // whole-site totals per day (not cut by the row limit)
  { kind: "query", dims: ["query"], limit: 1000 },
  { kind: "page", dims: ["page"], limit: 500 },
  { kind: "device", dims: ["device"], limit: 10 },
  { kind: "country", dims: ["country"], limit: 50 },
  { kind: "appearance", dims: ["searchAppearance"], limit: 50 },   // must be queried on its own
  { kind: "query_page", dims: ["query", "page"], limit: 2000 },    // two pages competing for one search
];
export function gscBody(dims: string[], start: string, end: string, rowLimit: number, type = "web") {
  return { startDate: start, endDate: end, dimensions: dims, type, rowLimit, dataState: "final" };
}
export function parseGscRows(b: any, kind: string, win: Win): WebRow[] {
  return (Array.isArray(b?.rows) ? b.rows : []).map((r: any) => ({
    src: "gsc" as const, kind, k1: String(r.keys?.[0] ?? "").slice(0, 400), k2: String(r.keys?.[1] ?? "").slice(0, 400), win,
    m: { clicks: Number(r.clicks) || 0, impressions: Number(r.impressions) || 0, ctr: Number(r.ctr) || 0, position: Math.round((Number(r.position) || 0) * 10) / 10 },
  })).filter((r: WebRow) => r.k1);
}

// ---------------------------------------------------------------- GA4
export const GA_REPORTS: { kind: string; dims: string[]; metrics: string[]; limit: number }[] = [
  { kind: "date", dims: ["date"], metrics: ["activeUsers", "newUsers", "sessions", "engagedSessions", "userEngagementDuration", "keyEvents", "screenPageViews"], limit: 100 },
  { kind: "channel", dims: ["sessionDefaultChannelGroup"], metrics: ["sessions", "engagedSessions", "keyEvents", "activeUsers"], limit: 30 },
  { kind: "source", dims: ["sessionSource", "sessionMedium"], metrics: ["sessions", "engagedSessions", "keyEvents", "activeUsers"], limit: 200 },
  { kind: "ai_landing", dims: ["sessionSource", "landingPage"], metrics: ["sessions", "keyEvents"], limit: 500 },
  { kind: "device", dims: ["deviceCategory"], metrics: ["activeUsers", "sessions", "engagedSessions"], limit: 10 },
  { kind: "newret", dims: ["newVsReturning"], metrics: ["activeUsers", "sessions"], limit: 5 },
  { kind: "landing", dims: ["landingPage"], metrics: ["sessions", "engagedSessions", "keyEvents", "activeUsers"], limit: 300 },
  { kind: "page", dims: ["pagePath"], metrics: ["screenPageViews", "activeUsers", "userEngagementDuration"], limit: 300 },
  { kind: "city", dims: ["city", "region"], metrics: ["activeUsers", "sessions", "keyEvents"], limit: 100 },
  { kind: "hour", dims: ["dayOfWeek", "hour"], metrics: ["sessions"], limit: 200 },
  { kind: "event", dims: ["eventName"], metrics: ["eventCount", "activeUsers", "keyEvents"], limit: 100 },
];
export function gaBody(r: { dims: string[]; metrics: string[]; limit: number }, start: string, end: string) {
  return { dateRanges: [{ startDate: start, endDate: end }], dimensions: r.dims.map((name) => ({ name })),
    metrics: r.metrics.map((name) => ({ name })), limit: String(r.limit), orderBys: [{ metric: { metricName: r.metrics[0] }, desc: true }] };
}
export function parseGaRows(b: any, kind: string, win: Win): WebRow[] {
  const mh: string[] = (b?.metricHeaders ?? []).map((h: any) => String(h.name));
  return (Array.isArray(b?.rows) ? b.rows : []).map((r: any) => {
    const m: Record<string, number> = {};
    mh.forEach((n, i) => { m[n] = Number(r.metricValues?.[i]?.value) || 0; });
    return { src: "ga" as const, kind, k1: String(r.dimensionValues?.[0]?.value ?? "").slice(0, 400), k2: String(r.dimensionValues?.[1]?.value ?? "").slice(0, 400), win, m };
  }).filter((r: WebRow) => r.k1 && r.k1 !== "(not set)");
}
export const REALTIME_REPORTS = [
  { kind: "total", dims: [] as string[], metrics: ["activeUsers"] },
  { kind: "page", dims: ["unifiedScreenName"], metrics: ["activeUsers", "screenPageViews"] },
  { kind: "city", dims: ["city"], metrics: ["activeUsers"] },
  { kind: "device", dims: ["deviceCategory"], metrics: ["activeUsers"] },
];
export function realtimeBody(r: { dims: string[]; metrics: string[] }) {
  return { dimensions: r.dims.map((name) => ({ name })), metrics: r.metrics.map((name) => ({ name })), limit: "20" };
}
export function parseRealtime(b: any): { k: string; users: number; views?: number }[] {
  return (Array.isArray(b?.rows) ? b.rows : []).map((r: any) => ({
    k: String(r.dimensionValues?.[0]?.value ?? "total"), users: Number(r.metricValues?.[0]?.value) || 0,
    ...(r.metricValues?.[1] ? { views: Number(r.metricValues[1].value) || 0 } : {}),
  }));
}

// Which AI assistant a GA4 session source belongs to (referrals and utm_source both land in sessionSource).
const AI_SOURCES: [RegExp, string][] = [
  [/(^|\.)chatgpt\.com$|(^|\.)chat\.openai\.com$|^openai$|^chatgpt$/i, "ChatGPT"],
  [/(^|\.)perplexity\.ai$|^perplexity$/i, "Perplexity"],
  [/(^|\.)gemini\.google\.com$|(^|\.)bard\.google\.com$|^gemini$/i, "Gemini"],
  [/(^|\.)copilot\.microsoft\.com$|(^|\.)copilot\.cloud\.microsoft$|^copilot$/i, "Copilot"],
  [/(^|\.)claude\.ai$|^claude$/i, "Claude"],
  [/(^|\.)chat\.deepseek\.com$|^deepseek$/i, "DeepSeek"],
  [/(^|\.)meta\.ai$/i, "Meta AI"],
  [/(^|\.)grok\.com$|(^|\.)x\.ai$/i, "Grok"],
  [/(^|\.)you\.com$/i, "You.com"],
];
export function aiTool(source: string): string | null {
  const s = String(source ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  for (const [re, name] of AI_SOURCES) if (re.test(s)) return name;
  return null;
}

// ---------------------------------------------------------------- PageSpeed Insights
const CRUX = { LARGEST_CONTENTFUL_PAINT_MS: "lcp", INTERACTION_TO_NEXT_PAINT: "inp", CUMULATIVE_LAYOUT_SHIFT_SCORE: "cls", FIRST_CONTENTFUL_PAINT_MS: "fcp", EXPERIMENTAL_TIME_TO_FIRST_BYTE: "ttfb" } as const;
export function psiUrl(page: string, strategy: "mobile" | "desktop", key?: string | null) {
  const q = new URLSearchParams({ url: page, strategy });
  for (const c of ["performance", "accessibility", "best-practices", "seo"]) q.append("category", c);
  if (key) q.set("key", key);
  return `https://www.googleapis.com/pagespeedonline/v5/runPagespeed?${q}`;
}
export function parsePsi(b: any) {
  const field: Record<string, { p75: number; rating: string }> = {};
  const src = b?.loadingExperience?.metrics && Object.keys(b.loadingExperience.metrics).length ? b.loadingExperience
    : b?.originLoadingExperience;
  for (const [k, short] of Object.entries(CRUX)) {
    const m = src?.metrics?.[k];
    if (m && Number.isFinite(Number(m.percentile))) {
      const p = Number(m.percentile);
      field[short] = { p75: short === "cls" ? p / 100 : p, rating: String(m.category ?? "").toLowerCase().replace("_", " ") };
    }
  }
  const cats = b?.lighthouseResult?.categories ?? {};
  const score = (k: string) => (cats[k]?.score == null ? null : Math.round(Number(cats[k].score) * 100));
  const audits = b?.lighthouseResult?.audits ?? {};
  const fixes = Object.values(audits as Record<string, any>)
    .filter((a: any) => a?.details?.type === "opportunity" && Number(a.details.overallSavingsMs) > 100 && a.score != null && a.score < 0.9)
    .sort((a: any, b2: any) => Number(b2.details.overallSavingsMs) - Number(a.details.overallSavingsMs))
    .slice(0, 4).map((a: any) => ({ title: String(a.title), saves_ms: Math.round(Number(a.details.overallSavingsMs)) }));
  return {
    field, field_scope: src === b?.loadingExperience ? "page" : src ? "site" : null,
    overall: String(src?.overall_category ?? "").toLowerCase() || null,
    scores: { performance: score("performance"), accessibility: score("accessibility"), best_practices: score("best-practices"), seo: score("seo") },
    lab: { lcp_ms: Math.round(Number(audits["largest-contentful-paint"]?.numericValue) || 0) || null, tbt_ms: Math.round(Number(audits["total-blocking-time"]?.numericValue) || 0),
      cls: audits["cumulative-layout-shift"]?.numericValue == null ? null : Math.round(Number(audits["cumulative-layout-shift"].numericValue) * 1000) / 1000 },
    fixes,
  };
}

// ---------------------------------------------------------------- URL Inspection and sitemaps
export function parseInspection(b: any) {
  const i = b?.inspectionResult?.indexStatusResult ?? {};
  const rich = b?.inspectionResult?.richResultsResult;
  return {
    verdict: i.verdict ?? null, coverage: i.coverageState ?? null, robots: i.robotsTxtState ?? null, indexing: i.indexingState ?? null,
    fetch: i.pageFetchState ?? null, last_crawl: i.lastCrawlTime ?? null, google_canonical: i.googleCanonical ?? null,
    user_canonical: i.userCanonical ?? null, crawled_as: i.crawledAs ?? null,
    rich: rich ? { verdict: rich.verdict ?? null, types: (rich.detectedItems ?? []).map((d: any) => String(d.richResultType)) } : null,
    link: b?.inspectionResult?.inspectionResultLink ?? null,
  };
}
export function parseSitemaps(b: any) {
  return (Array.isArray(b?.sitemap) ? b.sitemap : []).map((s: any) => ({
    path: String(s.path ?? ""), last_submitted: s.lastSubmitted ?? null, last_downloaded: s.lastDownloaded ?? null, pending: !!s.isPending,
    errors: Number(s.errors) || 0, warnings: Number(s.warnings) || 0,
    submitted: (s.contents ?? []).reduce((n: number, c: any) => n + (Number(c.submitted) || 0), 0),
  }));
}

// ---------------------------------------------------------------- the site itself
export function sitemapUrls(xml: string): { urls: string[]; nested: string[] } {
  const locs = [...String(xml ?? "").matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)].map((m) => m[1].replace(/&amp;/g, "&"));
  const isIndex = /<sitemapindex[\s>]/i.test(xml ?? "");
  return isIndex ? { urls: [], nested: locs } : { urls: locs, nested: [] };
}

// robots.txt: which AI crawlers may read the site. Group matching follows RFC 9309 (the most specific user-agent wins,
// otherwise "*"); a group allows the site root unless it says "Disallow: /" without an "Allow: /".
export const AI_BOTS = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User", "PerplexityBot",
  "Perplexity-User", "Google-Extended", "Applebot-Extended", "CCBot", "Bingbot", "Googlebot"];
export function robotsAccess(txt: string, bots = AI_BOTS): Record<string, "allowed" | "blocked"> {
  const groups: { agents: string[]; rules: { allow: boolean; path: string }[] }[] = [];
  let cur: (typeof groups)[number] | null = null, lastWasAgent = false;
  for (const raw of String(txt ?? "").split(/\r?\n/)) {
    const line = raw.replace(/#.*/, "").trim();
    const m = /^([a-z-]+)\s*:\s*(.*)$/i.exec(line);
    if (!m) continue;
    const key = m[1].toLowerCase(), val = m[2].trim();
    if (key === "user-agent") {
      if (!cur || !lastWasAgent) { cur = { agents: [], rules: [] }; groups.push(cur); }
      cur.agents.push(val.toLowerCase()); lastWasAgent = true;
    } else if ((key === "allow" || key === "disallow") && cur) {
      cur.rules.push({ allow: key === "allow", path: val }); lastWasAgent = false;
    } else lastWasAgent = false;
  }
  const verdict = (g?: (typeof groups)[number]) => {
    if (!g) return "allowed" as const;
    const root = g.rules.filter((r) => r.path === "/" || r.path === "/*");
    if (root.some((r) => r.allow)) return "allowed" as const;
    return root.some((r) => !r.allow) ? "blocked" as const : "allowed" as const;
  };
  const out: Record<string, "allowed" | "blocked"> = {};
  for (const bot of bots) {
    const b = bot.toLowerCase();
    const own = groups.find((g) => g.agents.includes(b));
    out[bot] = verdict(own ?? groups.find((g) => g.agents.includes("*")));
  }
  return out;
}

const attr = (tag: string, name: string) => {
  const m = new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
  return m ? (m[2] ?? m[3] ?? m[4] ?? "") : null;
};
const decode = (s: string) => s.replace(/&amp;/g, "&").replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/\s+/g, " ").trim();

// One page's on-page facts and problems. Thresholds follow common SERP display limits (title about 60 characters,
// description about 160); they are guides, not Google rules, and are worded that way in the CRM.
export function auditPage(html: string, url: string) {
  const h = String(html ?? "");
  const title = decode((/<title[^>]*>([\s\S]*?)<\/title>/i.exec(h)?.[1] ?? "").replace(/<[^>]+>/g, ""));
  const metaTags = [...h.matchAll(/<meta\b[^>]*>/gi)].map((m) => m[0]);
  const meta = (n: string) => { const t = metaTags.find((x) => (attr(x, "name") ?? attr(x, "property") ?? "").toLowerCase() === n); return t ? decode(attr(t, "content") ?? "") : null; };
  const description = meta("description");
  const robots = (meta("robots") ?? "").toLowerCase();
  const canonTag = [...h.matchAll(/<link\b[^>]*>/gi)].map((m) => m[0]).find((x) => (attr(x, "rel") ?? "").toLowerCase() === "canonical");
  const canonical = canonTag ? attr(canonTag, "href") : null;
  const h1 = [...h.matchAll(/<h1\b[^>]*>([\s\S]*?)<\/h1>/gi)].map((m) => decode(m[1].replace(/<[^>]+>/g, "")));
  const schema: string[] = [];
  for (const m of h.matchAll(/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try {
      const walk = (n: any) => { if (!n || typeof n !== "object") return; if (Array.isArray(n)) { n.forEach(walk); return; }
        const t = n["@type"]; (Array.isArray(t) ? t : t ? [t] : []).forEach((x: string) => schema.push(String(x))); if (n["@graph"]) walk(n["@graph"]); };
      walk(JSON.parse(m[1]));
    } catch { schema.push("(invalid JSON-LD)"); }
  }
  let origin = "";
  try { origin = new URL(url).origin; } catch { /* keep empty */ }
  const links = new Set<string>();
  for (const m of h.matchAll(/<a\b[^>]*\bhref\s*=\s*("([^"]*)"|'([^']*)')/gi)) {
    const href = (m[2] ?? m[3] ?? "").trim();
    if (!href || /^(#|mailto:|tel:|javascript:|whatsapp:)/i.test(href)) continue;
    try { const u = new URL(href, url); if (u.origin === origin) { u.hash = ""; links.add(u.toString()); } } catch { /* ignore */ }
  }
  const issues: string[] = [];
  if (!title) issues.push("no_title"); else if (title.length > 60) issues.push("long_title"); else if (title.length < 20) issues.push("short_title");
  if (!description) issues.push("no_description"); else if (description.length > 160) issues.push("long_description"); else if (description.length < 70) issues.push("short_description");
  if (h1.length === 0) issues.push("no_h1"); else if (h1.length > 1) issues.push("many_h1");
  if (!canonical) issues.push("no_canonical");
  if (/noindex/.test(robots)) issues.push("noindex");
  if (schema.length === 0) issues.push("no_schema");
  if (schema.includes("(invalid JSON-LD)")) issues.push("bad_schema");
  return { title, title_len: title.length, description, description_len: description?.length ?? 0, h1: h1.slice(0, 3), h1_count: h1.length,
    canonical, noindex: /noindex/.test(robots), schema: [...new Set(schema)].slice(0, 12), links: [...links].slice(0, 400), issues };
}

// ---------------------------------------------------------------- Bing / Copilot CSV export
// Bing Webmaster Tools > AI Performance has no API yet; its CSV export is uploaded instead. Column names vary, so match loosely.
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []; let row: string[] = [], cell = "", q = false;
  const s = String(text ?? "").replace(/^﻿/, "");
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; continue; }
    if (c === '"') q = true; else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") { if (c === "\r" && s[i + 1] === "\n") i++; row.push(cell); rows.push(row); row = []; cell = ""; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((x) => x.trim()));
}
export function copilotRows(text: string): { kind: "query" | "page"; rows: { k: string; citations: number }[] } {
  const [head = [], ...body] = parseCsv(text);
  const cols = head.map((h) => h.trim().toLowerCase());
  const kCol = cols.findIndex((c) => /grounding|query|page|url/.test(c));
  const nCol = cols.findIndex((c) => /citation/.test(c) && !/share|unique|page/.test(c));
  const kind = /page|url/.test(cols[kCol] ?? "") && !/query/.test(cols[kCol] ?? "") ? "page" : "query";
  if (kCol < 0) return { kind, rows: [] };
  const n = (v: string) => Number(String(v ?? "").replace(/[^0-9.]/g, "")) || 0;
  return { kind, rows: body.map((r) => ({ k: String(r[kCol] ?? "").trim().slice(0, 400), citations: nCol >= 0 ? n(r[nCol]) : 0 })).filter((r) => r.k).slice(0, 5000) };
}
