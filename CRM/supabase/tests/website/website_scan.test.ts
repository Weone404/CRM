// The whole site scan against a local test site: robots.txt, llms.txt, sitemap index, page checks, broken links.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { scanSite } from "../../functions/_shared/website_scan.ts";

Deno.test("WS01 scan finds AI crawler rules, llms.txt, page problems and broken links", async () => {
  let base = "";
  const page = (title: string, extra = "") => `<html><head><title>${title}</title>${extra}</head><body><h1>x</h1>
    <a href="/ok-not-in-sitemap">a</a><a href="/missing">b</a><a href="https://other.example/">c</a></body></html>`;
  const routes: Record<string, [number, string]> = {
    "/": [200, page("We One Aviation: Pilot Training in Delhi", `<meta name="description" content="${"d".repeat(120)}"><link rel="canonical" href="/"><script type="application/ld+json">{"@type":"Organization"}</script>`)],
    "/robots.txt": [200, "User-agent: *\nAllow: /\n\nUser-agent: GPTBot\nDisallow: /\n\nSitemap: __BASE__/sitemap_index.xml\n"],
    "/llms.txt": [404, "<html>not found</html>"],
    "/sitemap_index.xml": [200, "<sitemapindex><sitemap><loc>__BASE__/pages.xml</loc></sitemap></sitemapindex>"],
    "/pages.xml": [200, "<urlset><url><loc>__BASE__/</loc></url><url><loc>__BASE__/cpl</loc></url><url><loc>__BASE__/gone</loc></url><url><loc>https://elsewhere.example/x</loc></url></urlset>"],
    "/cpl": [200, page("CPL", '<meta name="robots" content="noindex">')],
    "/gone": [410, "gone"],
    "/ok-not-in-sitemap": [200, "ok"],
  };
  const ac = new AbortController();
  const server = Deno.serve({ port: 0, signal: ac.signal, onListen: () => {} }, (req) => {
    const r = routes[new URL(req.url).pathname] ?? [404, "nope"];
    return new Response(req.method === "HEAD" ? null : r[1].replaceAll("__BASE__", base), { status: r[0], headers: { "Content-Type": "text/html" } });
  });
  base = `http://localhost:${server.addr.port}`;
  const checks: Record<string, any> = {}; let saved: any[] = [];
  try {
    const msg = await scanSite(`${base}/`, Date.now() + 60000, async (k, d) => { checks[k] = d; }, async (rows) => { saved = rows; return rows.length; });
    assertEquals(checks.robots.bots.GPTBot, "blocked");
    assertEquals(checks.robots.bots.ClaudeBot, "allowed");
    assertEquals(checks.llms.status, "missing");
    assertEquals(checks.home.status, 200);
    assertEquals(saved.map((p) => p.url).sort(), [`${base}/`, `${base}/cpl`, `${base}/gone`].sort(), "only same-site sitemap pages, via the sitemap index");
    const home = saved.find((p) => p.url === `${base}/`);
    assertEquals(home.issues, []);
    assertEquals(home.broken, [{ url: `${base}/missing`, status: 404 }], "the missing internal link is reported; the working one and the external one are not");
    const cpl = saved.find((p) => p.url === `${base}/cpl`);
    assert(cpl.noindex && cpl.issues.includes("noindex") && cpl.issues.includes("no_description"));
    assertEquals(saved.find((p) => p.url === `${base}/gone`).status, 410);
    assert(/Site scan: 3 pages, 2 other links checked/.test(msg), msg);
  } finally { ac.abort(); await server.finished; }
});
