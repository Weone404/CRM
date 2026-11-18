// CRM > Website: the site scan (robots.txt AI crawlers, llms.txt, sitemap pages, on-page checks, broken internal links).
// Network and storage are passed in, so the whole scan runs in tests against a local server.
import { AI_BOTS, auditPage, robotsAccess, sitemapUrls } from "./website.ts";

export const UA = "Mozilla/5.0 (compatible; WeOneCRM-SiteCheck/1.0; +https://crm.weoneaviation.in)";
type Save = (key: string, data: unknown) => Promise<unknown>;
type SavePages = (rows: unknown[]) => Promise<number>;

async function timed(url: string, init: RequestInit = {}, ms = 15000) {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), ms);
  const started = performance.now();
  try {
    const res = await fetch(url, { redirect: "follow", ...init, signal: ctl.signal });
    return { res, ms: Math.round(performance.now() - started) };
  } finally { clearTimeout(t); }
}
export async function pool<T, R>(items: T[], n: number, deadline: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = []; let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length && Date.now() < deadline) { const k = i++; out[k] = await fn(items[k]); }
  }));
  return out.filter((x) => x !== undefined);
}

export async function scanSite(siteUrl: string, deadline: number, save: Save, savePages: SavePages, maxPages = 200) {
  const base = new URL(siteUrl);
  const get = async (u: string, ms = 15000) => {
    try {
      const { res, ms: t } = await timed(u, { headers: { "User-Agent": UA, Accept: "text/html,application/xml,text/plain,*/*" } }, ms);
      return { status: res.status, ms: t, text: await res.text(), final: res.url || u };
    } catch { return { status: 0, ms, text: "", final: u }; }
  };
  const home = await get(base.toString());
  await save("home", { status: home.status, ms: home.ms, https: home.final.startsWith("https://"), final_url: home.final });
  const robots = await get(new URL("/robots.txt", base).toString());
  const smFromRobots = [...robots.text.matchAll(/^\s*sitemap\s*:\s*(\S+)/gim)].map((m) => m[1]);
  await save("robots", { status: robots.status, bots: robots.status === 200 ? robotsAccess(robots.text, AI_BOTS) : {}, sitemaps: smFromRobots });
  const llms = await get(new URL("/llms.txt", base).toString());
  await save("llms", { status: llms.status === 200 && llms.text.trim() && !/<html/i.test(llms.text) ? "found" : "missing", http: llms.status, bytes: llms.text.length });

  const queue = smFromRobots.length ? [...smFromRobots] : [new URL("/sitemap.xml", base).toString()];
  const urls = new Set<string>();
  for (let i = 0; i < queue.length && i < 6; i++) {
    const r = await get(queue[i]);
    const p = sitemapUrls(r.text);
    p.nested.slice(0, 5).forEach((x) => queue.push(x));
    p.urls.forEach((u) => { try { const x = new URL(u); if (x.host === base.host) urls.add(x.toString()); } catch { /* skip */ } });
  }
  if (!urls.size) urls.add(base.toString());
  const list = [...urls].slice(0, maxPages);
  const known = new Map<string, number>();
  const pages = await pool(list, 6, deadline - 25000, async (u) => {
    const r = await get(u);
    known.set(u, r.status);
    const a = r.status >= 200 && r.status < 300 ? auditPage(r.text, r.final || u) : null;
    return { url: u, status: r.status, ms: r.ms, links: a?.links ?? [], ...(a ? { title: a.title, title_len: a.title_len, description_len: a.description_len,
      h1_count: a.h1_count, canonical: a.canonical, noindex: a.noindex, schema: a.schema, issues: a.issues } : { issues: r.status ? [] : ["unreachable"] }) };
  });
  const extra = [...new Set(pages.flatMap((p) => p.links))].filter((u) => !known.has(u)).slice(0, 300);
  await pool(extra, 8, deadline - 5000, async (u) => {
    try {
      const { res } = await timed(u, { method: "HEAD", headers: { "User-Agent": UA } }, 10000);
      let st = res.status;
      await res.body?.cancel();
      if (st === 405 || st === 403) st = (await get(u, 10000)).status;
      known.set(u, st);
    } catch { known.set(u, 0); }
  });
  const rows = pages.map((p) => ({ ...p, links: p.links.length,
    broken: p.links.filter((u) => { const s = known.get(u); return s !== undefined && (s === 0 || s >= 400); }).slice(0, 30).map((u) => ({ url: u, status: known.get(u) })) }));
  const n = await savePages(rows);
  return `Site scan: ${n} pages, ${extra.length} other links checked${list.length < urls.size ? ` (first ${list.length} of ${urls.size} pages)` : ""}`;
}
