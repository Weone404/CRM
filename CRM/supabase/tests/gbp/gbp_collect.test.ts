// Google My Business collector against a fake Google and a fake database (139): what gets saved, and what each failure turns into.
import { runJob, type Conn, type Deps, type Work } from "../../functions/_shared/gbp_collect.ts";

const eq = (a: unknown, b: unknown, what: string) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${what}\n  got      ${JSON.stringify(a)}\n  expected ${JSON.stringify(b)}`);
};
type Reply = { status?: number; body?: unknown; throws?: boolean };
type Route = (url: string, init?: RequestInit) => Reply | undefined;
const QUOTA0 = { status: 429, body: { error: { code: 429, message: "Quota exceeded", details: [{ metadata: { quota_limit_value: "0" } }] } } };

function world(routes: Route[], opts: { expireAfter?: number } = {}) {
  const calls: string[] = []; const saved: { fn: string; args: Record<string, unknown> }[] = []; let n = 0;
  const deps: Deps = {
    today: "2026-11-24",
    expired: () => opts.expireAfter !== undefined && n >= opts.expireAfter,
    fetch: (url, init) => {
      calls.push(url); n++;
      for (const r of routes) {
        const x = r(url, init);
        if (x) { if (x.throws) return Promise.reject(new Error("network")); return Promise.resolve(new Response(JSON.stringify(x.body ?? {}), { status: x.status ?? 200 })); }
      }
      return Promise.resolve(new Response("{}", { status: 404 }));
    },
    rpc: (fn, args) => { saved.push({ fn, args }); const rows = args.p_rows as unknown[] | undefined; return Promise.resolve(Array.isArray(rows) ? rows.length : null); },
  };
  const status = () => saved.filter((s) => s.fn === "svc_gbp_connection_status").map((s) => `${s.args.p_id}:${s.args.p_status}`);
  return { deps, calls, saved, status };
}
const token: Route = (u) => u.startsWith("https://oauth2.googleapis.com/token") ? { body: { access_token: "ya29.a0TESTaccess" } } : undefined;
const loc = (over: Partial<Conn["locations"][0]> = {}) => ({ id: "L1", account: "accounts/9", name: "locations/111", first: false, reviews_stored: 5, keyword_months: [], ...over });
const work = (conns: Partial<Conn>[]): Work => ({ client_id: "cid", client_secret: "sec",
  connections: conns.map((c, i) => ({ id: `C${i + 1}`, label: `Login ${i + 1}`, refresh_token: "1//0gTESTtoken_abc", locations: [], ...c })) });
const metrics = { multiDailyMetricTimeSeries: [{ dailyMetricTimeSeries: [{ dailyMetric: "CALL_CLICKS", timeSeries: { datedValues: [{ date: { year: 2026, month: 11, day: 20 }, value: "3" }] } }] }] };

Deno.test("discover: lists every account and profile of a login, page by page, and marks it connected", async () => {
  const w = world([token,
    (u) => u.includes("mybusinessaccountmanagement") ? { body: { accounts: [{ name: "accounts/9", accountName: "Nikhil" }, { name: "accounts/7", accountName: "Agency" }] } } : undefined,
    (u) => u.includes("accounts/9/locations") && !u.includes("pageToken") ? { body: { locations: [{ name: "locations/111", title: "We One" }], nextPageToken: "p2" } } : undefined,
    (u) => u.includes("accounts/9/locations") ? { body: { locations: [{ name: "locations/112", title: "We One Noida" }] } } : undefined,
    (u) => u.includes("accounts/7/locations") ? { body: {} } : undefined]);
  const r = await runJob(w.deps, "discover", work([{}]));
  eq(r, { status: "ok", detail: "Login 1: 2 profile(s) in 2 account(s)" }, "result");
  const save = w.saved.find((s) => s.fn === "svc_gbp_locations_save")!;
  eq((save.args.p_rows as { name: string; account: string }[]).map((x) => `${x.account}/${x.name}`), ["accounts/9/locations/111", "accounts/9/locations/112"], "both pages saved under their account");
  eq(w.saved.at(-1)!.args, { p_id: "C1", p_status: "connected", p_error: null, p_email: "Nikhil" }, "connected, with the account name");
  eq(w.calls.filter((u) => !u.includes("oauth2")).every((u) => u.startsWith("https://mybusiness")), true, "only Google's Business Profile hosts are called");
});

Deno.test("discover: Google has not approved the project yet (quota 0) -> 'waiting for Google', nothing saved, other logins still run", async () => {
  let n = 0;
  const w = world([token, (u) => u.includes("mybusinessaccountmanagement") ? (n++ === 0 ? QUOTA0 : { body: { accounts: [] } }) : undefined]);
  const r = await runJob(w.deps, "discover", work([{}, {}]));
  eq(r.status, "error", "the run reports a problem");
  eq(w.status(), ["C1:waiting_google", "C2:connected"], "each login gets its own state");
  eq(w.saved.filter((s) => s.fn === "svc_gbp_locations_save").length, 1, "nothing is saved for the waiting login");
  eq(/approv/i.test(r.detail), true, "the message says Google's approval is pending");
});

Deno.test("sign-in: only Google's 'invalid_grant' asks for a new sign-in; an outage or a dropped connection changes nothing", async () => {
  const revoked = world([(u) => u.includes("oauth2") ? { status: 400, body: { error: "invalid_grant", error_description: "Token has been expired or revoked." } } : undefined]);
  await runJob(revoked.deps, "discover", work([{}]));
  eq(revoked.status(), ["C1:needs_signin"], "revoked token");
  const wrongClient = world([(u) => u.includes("oauth2") ? { status: 401, body: { error: "invalid_client" } } : undefined]);
  const rc = await runJob(wrongClient.deps, "discover", work([{}]));
  eq([wrongClient.status(), /different Google OAuth client/.test(rc.detail)], [["C1:needs_signin"], true], "token made with another OAuth client");
  for (const reply of [{ status: 503, body: {} }, { throws: true }, { status: 429, body: {} }]) {
    const down = world([(u) => u.includes("oauth2") ? reply : undefined]);
    const r = await runJob(down.deps, "sync", work([{ locations: [loc()] }]));
    eq([r.status, down.status(), down.saved.length], ["error", [], 0], `outage ${JSON.stringify(reply)} leaves the login's state alone`);
  }
  const none = world([]);
  await runJob(none.deps, "discover", work([{ refresh_token: null }]));
  eq([none.status(), none.calls.length], [["C1:needs_signin"], 0], "a login without a token never calls Google");
  const noClient = world([]);
  await runJob(noClient.deps, "discover", { client_id: null, client_secret: null, connections: work([{}]).connections });
  eq(noClient.calls.length, 0, "no OAuth client saved: Google is not called");
});

Deno.test("sync: first read takes 180 days and 6 months of words; later reads take 35 days and only the months not stored", async () => {
  const routes: Route[] = [token,
    (u) => u.includes("fetchMultiDailyMetricsTimeSeries") ? { body: metrics } : undefined,
    (u) => u.includes("searchkeywords") ? { body: { searchKeywordsCounts: [{ searchKeyword: "pilot training", insightsValue: { value: "10" } }] } } : undefined,
    (u) => u.includes("/reviews") ? { body: { reviews: [{ reviewId: "r1", starRating: "FIVE" }], averageRating: 4.5, totalReviewCount: 12 } } : undefined];
  const first = world(routes);
  const r1 = await runJob(first.deps, "sync", work([{ locations: [loc({ first: true, reviews_stored: 0 })] }]));
  eq(r1, { status: "ok", detail: "Login 1: 1 profile(s), 1 day-numbers, 6 search words, 1 reviews" }, "first read");
  const m1 = first.calls.find((u) => u.includes("fetchMulti"))!;
  eq(m1.includes("dailyRange.start_date.year=2026&dailyRange.start_date.month=5&dailyRange.start_date.day=28"), true, "180 days back");
  eq(first.saved.filter((s) => s.fn === "svc_gbp_keywords_save").map((s) => s.args.p_month), ["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01", "2026-06-01", "2026-05-01"], "six complete months");
  eq(first.saved.find((s) => s.fn === "svc_gbp_reviews_save")!.args, { p_location: "L1", p_rows: [{ id: "r1", reviewer: "A Google user", stars: 5, comment: "", created: null, updated: null, reply: "", reply_at: null }], p_total: 12, p_rating: 4.5 }, "reviews with Google's totals");
  const later = world(routes);
  await runJob(later.deps, "sync", work([{ locations: [loc({ keyword_months: ["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01"] })] }]));
  eq(later.calls.find((u) => u.includes("fetchMulti"))!.includes("dailyRange.start_date.month=10&dailyRange.start_date.day=20"), true, "35 days back");
  eq(later.saved.filter((s) => s.fn === "svc_gbp_keywords_save").map((s) => s.args.p_month), ["2026-10-01", "2026-06-01", "2026-05-01"], "the latest month again, plus the months not stored yet");
  eq(later.status(), ["C1:connected"], "connected");
});

Deno.test("sync: reviews are read newest first; every page on the first read, two pages afterwards", async () => {
  const routes: Route[] = [token, (u) => u.includes("fetchMulti") ? { body: {} } : undefined, (u) => u.includes("searchkeywords") ? { body: {} } : undefined,
    (u) => u.includes("/reviews") ? { body: { reviews: [{ reviewId: "r" + u.length, starRating: "FOUR" }], nextPageToken: "more" } } : undefined];
  const first = world(routes); await runJob(first.deps, "sync", work([{ locations: [loc({ reviews_stored: 0 })] }]));
  const later = world(routes); await runJob(later.deps, "sync", work([{ locations: [loc({ reviews_stored: 40 })] }]));
  eq([first.calls.filter((u) => u.includes("/reviews")).length, later.calls.filter((u) => u.includes("/reviews")).length], [20, 2], "pages");
  eq(later.calls.filter((u) => u.includes("/reviews"))[1].includes("pageToken=more"), true, "the second page uses Google's page token");
});

Deno.test("sync: the reviews API switched off, or one profile without access, does not lose the rest", async () => {
  const w = world([token, (u) => u.includes("fetchMulti") && u.includes("locations/111") ? { body: metrics } : undefined,
    (u) => u.includes("locations/222") ? { status: 403, body: { error: { message: "The caller does not have permission" } } } : undefined,
    (u) => u.includes("searchkeywords") ? { body: {} } : undefined,
    (u) => u.includes("/reviews") ? { status: 403, body: { error: { message: "Google My Business API has not been used in project 1 before or it is disabled.", details: [{ reason: "SERVICE_DISABLED" }] } } } : undefined]);
  const r = await runJob(w.deps, "sync", work([{ locations: [loc(), loc({ id: "L2", name: "locations/222" })] }]));
  eq(r.status, "ok", "the run is not a failure");
  eq(w.saved.filter((s) => s.fn === "svc_gbp_metrics_save").map((s) => s.args.p_location), ["L1"], "the readable profile's numbers are saved");
  eq([/switched off/.test(r.detail), /permission|access/i.test(r.detail)], [true, true], "both problems are named in the run note");
  eq(w.status(), ["C1:connected"], "the login stays connected");
  const allOff = world([token, () => ({ status: 403, body: { error: { message: "API has not been used in project 1 before or it is disabled.", details: [{ reason: "SERVICE_DISABLED" }] } } })]);
  const r2 = await runJob(allOff.deps, "sync", work([{ locations: [loc()] }]));
  eq([r2.status, allOff.status()], ["error", ["C1:api_off"]], "when nothing at all can be read, that is the login's state");
});

Deno.test("sync: quota 0 mid-way marks 'waiting for Google'; a busy Google keeps the state; logins without tracked profiles cost no calls", async () => {
  const w = world([token, () => QUOTA0]);
  await runJob(w.deps, "sync", work([{ locations: [loc()] }, {}]));
  eq([w.status(), w.calls.length], [["C1:waiting_google"], 2], "one sign-in and one refused call; the login with nothing tracked calls nothing");
  const busy = world([token, () => ({ status: 429, body: { error: { message: "Quota exceeded", details: [{ metadata: { quota_limit_value: "300" } }] } } })]);
  const r = await runJob(busy.deps, "sync", work([{ locations: [loc()] }]));
  eq([r.status, busy.status()], ["error", []], "a real per-minute limit is temporary");
  const dead = world([token, (u) => u.includes("fetchMulti") ? { throws: true } : undefined]);
  eq([(await runJob(dead.deps, "sync", work([{ locations: [loc()] }]))).status, dead.status()], ["error", []], "a dropped connection is temporary too");
});

Deno.test("time limit: the run stops starting new work and says so; nothing is half-marked", async () => {
  const routes: Route[] = [token, (u) => u.includes("fetchMulti") ? { body: metrics } : undefined, (u) => u.includes("searchkeywords") ? { body: {} } : undefined, (u) => u.includes("/reviews") ? { body: {} } : undefined];
  const w = world(routes, { expireAfter: 2 });
  const r = await runJob(w.deps, "sync", work([{ locations: [loc(), loc({ id: "L2", name: "locations/222" })] }]));
  eq([/time limit reached/.test(r.detail), w.saved.filter((s) => s.fn === "svc_gbp_metrics_save").length, w.status()], [true, 1, ["C1:connected"]], "first profile saved, second left for the next run");
  const none = world([]);
  eq(await runJob(none.deps, "sync", { client_id: "c", client_secret: "s", connections: [] }), { status: "ok", detail: "No Google login is saved yet." }, "no logins at all");
});

Deno.test("nothing secret is written to the database or the run note", async () => {
  const w = world([token, () => ({ status: 500, body: { error: { message: "backend error for token 1//0gTESTtoken_abc ya29.a0TESTaccess" } } })]);
  const r = await runJob(w.deps, "sync", work([{ locations: [loc()] }]));
  const all = JSON.stringify(w.saved) + r.detail;
  eq([all.includes("1//0gTESTtoken_abc"), all.includes("ya29.a0TESTaccess"), all.includes('"sec"')], [false, false, false], "no refresh token, access token or client secret");
});
