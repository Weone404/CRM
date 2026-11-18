// CRM > Website helpers (migration 112). Run: deno test --allow-all website.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { aiTool, auditPage, copilotRows, gaBody, gscBody, parseGaRows, parseGscRows, parseInspection, parsePsi, parseRealtime,
  parseSitemaps, psiUrl, robotsAccess, sitemapUrls } from "../../functions/_shared/website.ts";

Deno.test("W01 Search Console rows keep both keys and round position", () => {
  const rows = parseGscRows({ rows: [{ keys: ["cpl fees", "https://x.in/fees"], clicks: 3, impressions: 120, ctr: 0.025, position: 7.46 }, { keys: [""] }] }, "query_page", "cur");
  assertEquals(rows, [{ src: "gsc", kind: "query_page", k1: "cpl fees", k2: "https://x.in/fees", win: "cur", m: { clicks: 3, impressions: 120, ctr: 0.025, position: 7.5 } }]);
  assertEquals(gscBody(["date"], "2026-10-01", "2026-10-28", 100), { startDate: "2026-10-01", endDate: "2026-10-28", dimensions: ["date"], type: "web", rowLimit: 100, dataState: "final" });
});
Deno.test("W02 GA4 rows map metric headers and drop (not set)", () => {
  const b = { metricHeaders: [{ name: "sessions" }, { name: "keyEvents" }], rows: [
    { dimensionValues: [{ value: "chatgpt.com" }, { value: "referral" }], metricValues: [{ value: "12" }, { value: "2" }] },
    { dimensionValues: [{ value: "(not set)" }], metricValues: [{ value: "5" }, { value: "0" }] }] };
  assertEquals(parseGaRows(b, "source", "prev"), [{ src: "ga", kind: "source", k1: "chatgpt.com", k2: "referral", win: "prev", m: { sessions: 12, keyEvents: 2 } }]);
  assertEquals(gaBody({ dims: ["date"], metrics: ["activeUsers"], limit: 100 }, "a", "b").orderBys, [{ metric: { metricName: "activeUsers" }, desc: true }]);
});
Deno.test("W03 AI assistants are recognised from referral sources and utm_source", () => {
  assertEquals(aiTool("chatgpt.com"), "ChatGPT");
  assertEquals(aiTool("https://chat.openai.com/c/1"), "ChatGPT");
  assertEquals(aiTool("perplexity.ai"), "Perplexity");
  assertEquals(aiTool("gemini.google.com"), "Gemini");
  assertEquals(aiTool("copilot.microsoft.com"), "Copilot");
  assertEquals(aiTool("claude.ai"), "Claude");
  assertEquals(aiTool("google"), null);
  assertEquals(aiTool("notchatgpt.com.evil"), null);
});
Deno.test("W04 PageSpeed: page-level field data first, scores, top fixes", () => {
  const b = {
    loadingExperience: { overall_category: "AVERAGE", metrics: {
      LARGEST_CONTENTFUL_PAINT_MS: { percentile: 3100, category: "AVERAGE" }, INTERACTION_TO_NEXT_PAINT: { percentile: 180, category: "FAST" },
      CUMULATIVE_LAYOUT_SHIFT_SCORE: { percentile: 12, category: "AVERAGE" } } },
    lighthouseResult: { categories: { performance: { score: 0.62 }, seo: { score: 1 }, accessibility: { score: 0.9 }, "best-practices": { score: null } },
      audits: { "largest-contentful-paint": { numericValue: 4200.4 }, "total-blocking-time": { numericValue: 310 }, "cumulative-layout-shift": { numericValue: 0.1234 },
        a: { title: "Reduce unused JavaScript", score: 0.3, details: { type: "opportunity", overallSavingsMs: 900 } },
        b: { title: "Serve images in next-gen formats", score: 0.5, details: { type: "opportunity", overallSavingsMs: 1500 } },
        c: { title: "Tiny", score: 0.5, details: { type: "opportunity", overallSavingsMs: 50 } },
        d: { title: "Already fine", score: 1, details: { type: "opportunity", overallSavingsMs: 800 } } } } };
  const p = parsePsi(b);
  assertEquals(p.field.lcp, { p75: 3100, rating: "average" });
  assertEquals(p.field.cls, { p75: 0.12, rating: "average" });
  assertEquals(p.field_scope, "page");
  assertEquals(p.scores, { performance: 62, accessibility: 90, best_practices: null, seo: 100 });
  assertEquals(p.fixes.map((f) => f.title), ["Serve images in next-gen formats", "Reduce unused JavaScript"]);
  assertEquals(p.lab.cls, 0.123);
  const site = parsePsi({ loadingExperience: { metrics: {} }, originLoadingExperience: { metrics: { LARGEST_CONTENTFUL_PAINT_MS: { percentile: 2000, category: "FAST" } } } });
  assertEquals(site.field_scope, "site");
  assert(psiUrl("https://x.in/", "mobile", "K").includes("category=best-practices") && psiUrl("https://x.in/", "mobile", "K").includes("key=K"));
  assert(!psiUrl("https://x.in/", "desktop").includes("key="));
});
Deno.test("W05 URL Inspection and sitemaps", () => {
  const i = parseInspection({ inspectionResult: { inspectionResultLink: "L", indexStatusResult: { verdict: "PASS", coverageState: "Submitted and indexed",
    lastCrawlTime: "2026-11-10T00:00:00Z", googleCanonical: "https://x.in/", userCanonical: "https://x.in/" }, richResultsResult: { verdict: "PASS", detectedItems: [{ richResultType: "FAQ" }] } } });
  assertEquals([i.verdict, i.coverage, i.rich?.types[0], i.link], ["PASS", "Submitted and indexed", "FAQ", "L"]);
  assertEquals(parseSitemaps({ sitemap: [{ path: "https://x.in/sitemap.xml", errors: "2", warnings: "1", contents: [{ submitted: "90" }, { submitted: "10" }] }] })[0],
    { path: "https://x.in/sitemap.xml", last_submitted: null, last_downloaded: null, pending: false, errors: 2, warnings: 1, submitted: 100 });
});
Deno.test("W06 sitemap index vs url set", () => {
  assertEquals(sitemapUrls("<urlset><url><loc>https://x.in/a?b=1&amp;c=2</loc></url><url><loc> https://x.in/b </loc></url></urlset>").urls, ["https://x.in/a?b=1&c=2", "https://x.in/b"]);
  assertEquals(sitemapUrls("<sitemapindex><sitemap><loc>https://x.in/s1.xml</loc></sitemap></sitemapindex>"), { urls: [], nested: ["https://x.in/s1.xml"] });
});
Deno.test("W07 robots.txt: own group beats *, blocked only by Disallow: /", () => {
  const txt = "User-agent: *\nAllow: /\nDisallow: /admin\n\nUser-agent: GPTBot\nUser-agent: CCBot\nDisallow: /\n\nUser-agent: ClaudeBot\nDisallow: /private\n";
  const r = robotsAccess(txt, ["GPTBot", "CCBot", "ClaudeBot", "PerplexityBot"]);
  assertEquals(r, { GPTBot: "blocked", CCBot: "blocked", ClaudeBot: "allowed", PerplexityBot: "allowed" });
  assertEquals(robotsAccess("User-agent: *\nDisallow: /", ["GPTBot"]), { GPTBot: "blocked" });
  assertEquals(robotsAccess("", ["GPTBot"]), { GPTBot: "allowed" });
});
Deno.test("W08 on-page audit finds the usual problems", () => {
  const good = `<html><head><title>CPL Course Fees in Delhi 2027 | We One Aviation</title>
    <meta name="description" content="CPL course fees in Delhi for 2027: ground classes, flying hours and DGCA exams explained with real figures and timelines for students.">
    <link rel="canonical" href="https://x.in/cpl"><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"Organization"},{"@type":"FAQPage"}]}</script>
    </head><body><h1>CPL fees</h1><a href="/fees#top">Fees</a><a href="https://x.in/b">B</a><a href="https://other.com/">x</a><a href="tel:1">t</a></body></html>`;
  const a = auditPage(good, "https://x.in/cpl");
  assertEquals(a.issues, []);
  assertEquals(a.schema, ["Organization", "FAQPage"]);
  assertEquals(a.links, ["https://x.in/fees", "https://x.in/b"]);
  const bad = auditPage(`<html><head><meta name="robots" content="noindex"><script type="application/ld+json">{bad</script></head><body><h1>a</h1><h1>b</h1></body></html>`, "https://x.in/x");
  assertEquals(bad.issues.sort(), ["bad_schema", "many_h1", "no_canonical", "no_description", "no_title", "noindex"].sort());
});
Deno.test("W09 Copilot CSV: grounding queries and pages", () => {
  const q = copilotRows('﻿Grounding Query,Citations,Intent\n"pilot training, delhi",12,Info\ncpl cost,3,Info\n');
  assertEquals(q, { kind: "query", rows: [{ k: "pilot training, delhi", citations: 12 }, { k: "cpl cost", citations: 3 }] });
  const p = copilotRows("Page URL,Citations\r\nhttps://x.in/a,7\r\n");
  assertEquals(p, { kind: "page", rows: [{ k: "https://x.in/a", citations: 7 }] });
});
Deno.test("W10 realtime rows", () => {
  assertEquals(parseRealtime({ rows: [{ dimensionValues: [{ value: "/fees" }], metricValues: [{ value: "3" }, { value: "5" }] }] }), [{ k: "/fees", users: 3, views: 5 }]);
  assertEquals(parseRealtime({ rows: [{ metricValues: [{ value: "4" }] }] }), [{ k: "total", users: 4 }]);
});
