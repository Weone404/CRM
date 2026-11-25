// Google My Business collector against a fake Google and a fake database (139): what gets saved, and what each failure turns into.
import { runJob, type Conn, type Deps, type Work } from "../../functions/_shared/gbp_collect.ts";
import { replyUrl, reviewUrl } from "../../functions/_shared/gbp.ts";

const eq = (a: unknown, b: unknown, what: string) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${what}\n  got      ${JSON.stringify(a)}\n  expected ${JSON.stringify(b)}`);
};
type Reply = { status?: number; body?: unknown; throws?: boolean };
type Route = (url: string, init?: RequestInit) => Reply | undefined;
const QUOTA0 = { status: 429, body: { error: { code: 429, message: "Quota exceeded", details: [{ metadata: { quota_limit_value: "0" } }] } } };

function world(routes: Route[], opts: { expireAfter?: number; queue?: unknown[] } = {}) {
  const inits: { url: string; method: string; body: string }[] = [];
  const calls: string[] = []; const saved: { fn: string; args: Record<string, unknown> }[] = []; let n = 0;
  const deps: Deps = {
    today: "2026-11-24",
    expired: () => opts.expireAfter !== undefined && n >= opts.expireAfter,
    fetch: (url, init) => {
      calls.push(url); n++; inits.push({ url, method: String(init?.method ?? "GET"), body: String(init?.body ?? "") });
      for (const r of routes) {
        const x = r(url, init);
        if (x) { if (x.throws) return Promise.reject(new Error("network")); return Promise.resolve(new Response(JSON.stringify(x.body ?? {}), { status: x.status ?? 200 })); }
      }
      if (/\/localPosts\?|\/media(\/customers)?\?/.test(url)) return Promise.resolve(new Response("{}", { status: 200 }));      // posts and photos: nothing there unless a test says otherwise
      return Promise.resolve(new Response("{}", { status: 404 }));
    },
    rpc: (fn, args) => { saved.push({ fn, args }); if (fn === "svc_gbp_reply_queue" || fn === "svc_gbp_post_queue") return Promise.resolve(opts.queue ?? []);
      const rows = args.p_rows as unknown[] | undefined; return Promise.resolve(Array.isArray(rows) ? rows.length : null); },
  };
  const status = () => saved.filter((s) => s.fn === "svc_gbp_connection_status").map((s) => `${s.args.p_id}:${s.args.p_status}`);
  const results = () => saved.filter((x) => x.fn === "svc_gbp_reply_result").map((x) => `${x.args.p_id}:${x.args.p_state}`);
  return { deps, calls, saved, status, inits, results };
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

// ---------------------------------------------------------------- review replies (140)
const Q = (over: Record<string, unknown> = {}) => ({ id: 7, connection_id: "C1", account: "accounts/9", location: "locations/111", review_id: "AbC-123_x", text: "Thank you, Asha. See you soon.", ...over });
const isReview = (u: string) => /\/reviews\/[A-Za-z0-9_-]+$/.test(u), isReply = (u: string) => u.endsWith("/reply");

Deno.test("reply: the review is read again, then the reply is written once with exactly the approved text", async () => {
  const w = world([token, (u) => isReview(u) ? { body: { reviewId: "AbC-123_x", starRating: "FIVE" } } : undefined, (u, i) => isReply(u) && i?.method === "PUT" ? { body: { comment: "ok" } } : undefined], { queue: [Q()] });
  const r = await runJob(w.deps, "reply", work([{}]));
  eq(r, { status: "ok", detail: "1 sent, 0 not needed, 0 waiting, 0 refused" }, "result");
  eq(w.inits.slice(1).map((x) => `${x.method} ${x.url}`), [`GET ${reviewUrl("accounts/9", "locations/111", "AbC-123_x")}`, `PUT ${replyUrl("accounts/9", "locations/111", "AbC-123_x")}`], "one read, one write, on Google's reviews API");
  eq(JSON.parse(w.inits[2].body), { comment: "Thank you, Asha. See you soon." }, "the body is the approved text, nothing added");
  eq(w.results(), ["7:sent"], "recorded as sent");
});

Deno.test("reply: answered on Google meanwhile, or deleted -> nothing is sent", async () => {
  const answered = world([token, (u) => isReview(u) ? { body: { reviewReply: { comment: "The owner answered from the phone." } } } : undefined], { queue: [Q()] });
  await runJob(answered.deps, "reply", work([{}]));
  eq([answered.results(), answered.inits.some((x) => x.method === "PUT")], [["7:skipped"], false], "already answered");
  const gone = world([token, (u) => isReview(u) ? { status: 404, body: { error: { message: "Requested entity was not found." } } } : undefined], { queue: [Q()] });
  await runJob(gone.deps, "reply", work([{}]));
  eq([gone.results(), gone.inits.some((x) => x.method === "PUT")], [["7:skipped"], false], "review deleted");
  const ours = world([token, (u) => isReview(u) ? { body: { reviewReply: { comment: " Thank you, Asha. See you soon. " } } } : undefined], { queue: [Q()] });
  await runJob(ours.deps, "reply", work([{}]));
  eq([ours.results(), ours.inits.some((x) => x.method === "PUT")], [["7:sent"], false], "our own reply from an earlier try that did arrive: marked sent, not written twice");
});

Deno.test("reply: a dropped connection, a busy Google or a pending approval keeps the reply for later; a refusal is final", async () => {
  const drop = world([token, (u) => isReview(u) ? { body: {} } : undefined, (u) => isReply(u) ? { throws: true } : undefined], { queue: [Q()] });
  const r1 = await runJob(drop.deps, "reply", work([{}]));
  eq([drop.results(), r1.status], [["7:retry"], "error"], "no confirmation from Google is never recorded as sent");
  const quota = world([token, (u) => isReview(u) ? QUOTA0 : undefined], { queue: [Q(), Q({ id: 8, review_id: "r8" })] });
  await runJob(quota.deps, "reply", work([{}]));
  eq([quota.results(), quota.status(), quota.inits.some((x) => x.method === "PUT")], [["7:retry", "8:retry"], ["C1:waiting_google", "C1:waiting_google"], false], "Google has not approved the project: both wait");
  const refused = world([token, (u) => isReview(u) ? { body: {} } : undefined, (u) => isReply(u) ? { status: 400, body: { error: { message: "Reply violates the content policy." } } } : undefined], { queue: [Q()] });
  const r3 = await runJob(refused.deps, "reply", work([{}]));
  eq([refused.results(), /content policy/.test(r3.detail), refused.status()], [["7:failed"], true, []], "Google refuses this reply: failed, with Google's reason; the login is fine");
});

Deno.test("reply: one sign-in per login; a revoked login or a removed one sends nothing; an empty queue costs no calls", async () => {
  const two = world([token, (u) => isReview(u) ? { body: {} } : undefined, (u) => isReply(u) ? { body: {} } : undefined], { queue: [Q(), Q({ id: 8, review_id: "r8" }), Q({ id: 9, connection_id: "C2", review_id: "r9" })] });
  await runJob(two.deps, "reply", work([{}, {}]));
  eq([two.calls.filter((u) => u.includes("oauth2")).length, two.results()], [2, ["7:sent", "8:sent", "9:sent"]], "three replies over two logins: two sign-ins");
  const revoked = world([(u) => u.includes("oauth2") ? { status: 400, body: { error: "invalid_grant" } } : undefined], { queue: [Q(), Q({ id: 8, review_id: "r8" })] });
  await runJob(revoked.deps, "reply", work([{}]));
  eq([revoked.calls.length, revoked.results(), revoked.status()[0]], [1, ["7:retry", "8:retry"], "C1:needs_signin"], "revoked sign-in: asked once, replies kept, login marked");
  const removed = world([token], { queue: [Q({ connection_id: "gone" })] });
  await runJob(removed.deps, "reply", work([{}]));
  eq([removed.calls.length, removed.results()], [0, ["7:retry"]], "the profile's login was removed");
  const empty = world([token], { queue: [] });
  eq([await runJob(empty.deps, "reply", work([{}])), empty.calls.length], [{ status: "ok", detail: "No reply is waiting to be sent." }, 0], "nothing queued");
});

Deno.test("reply: a review id that is not an id never reaches Google; time limit leaves the rest queued", async () => {
  const bad = world([token], { queue: [Q({ review_id: "x/../../accounts/1" })] });
  await runJob(bad.deps, "reply", work([{}]));
  eq([bad.results(), bad.calls.filter((u) => !u.includes("oauth2")).length], [["7:failed"], 0], "malformed id");
  const slow = world([token, (u) => isReview(u) ? { body: {} } : undefined, (u) => isReply(u) ? { body: {} } : undefined], { queue: [Q(), Q({ id: 8, review_id: "r8" })], expireAfter: 3 });
  const r = await runJob(slow.deps, "reply", work([{}]));
  eq([slow.results(), /1 sent, 0 not needed, 1 waiting/.test(r.detail)], [["7:sent"], true], "the second one is simply left in the queue");
});

Deno.test("reviews: the 3-hourly look reads one page of the newest reviews per tracked profile and nothing else", async () => {
  const w = world([token, (u) => u.includes("/reviews?") ? { body: { reviews: [{ reviewId: "n1", starRating: "FIVE", comment: "New" }], averageRating: 4.8, totalReviewCount: 214, nextPageToken: "more" } } : undefined]);
  const r = await runJob(w.deps, "reviews", work([{ locations: [loc(), loc({ id: "L2", name: "locations/222" })] }, {}]));
  eq(r, { status: "ok", detail: "Login 1: 2 review(s) read · Login 2: no tracked profile" }, "result");
  eq([w.calls.filter((u) => u.includes("/reviews?")).length, w.calls.some((u) => u.includes("fetchMulti") || u.includes("searchkeywords") || u.includes("pageToken"))], [2, false], "one page each; no numbers, no words");
});

// ---------------------------------------------------------------- health check, posts, photos (143)
Deno.test("discover also saves what the health check needs, per profile", async () => {
  const w = world([token, (u) => u.includes("mybusinessaccountmanagement") ? { body: { accounts: [{ name: "accounts/9" }] } } : undefined,
    (u) => u.includes("accounts/9/locations") ? { body: { locations: [{ name: "locations/111", title: "We One", profile: { description: "Ground classes." }, metadata: { canOperateLocalPost: false } }] } } : undefined]);
  await runJob(w.deps, "discover", work([{}]));
  const d = w.saved.find((s) => s.fn === "svc_gbp_details_save")!;
  eq([d.args.p_connection, (d.args.p_rows as { name: string; details: { description: string; can_post: boolean } }[]).map((r) => `${r.name}:${r.details.description}:${r.details.can_post}`)], ["C1", ["locations/111:Ground classes.:false"]], "details");
  eq(w.calls.find((u) => u.includes("/locations?"))!.includes("profile,regularHours,specialHours,openInfo,serviceArea"), true, "asked for in the same request, no extra call");
});

Deno.test("sync reads posts and photos (owner's and customers'); a complete read is marked complete", async () => {
  const w = world([token, (u) => u.includes("fetchMulti") ? { body: {} } : undefined, (u) => u.includes("searchkeywords") ? { body: {} } : undefined, (u) => u.includes("/reviews") ? { body: {} } : undefined,
    (u) => u.includes("/localPosts?") && !u.includes("pageToken") ? { body: { localPosts: [{ name: "accounts/9/locations/111/localPosts/p1", state: "LIVE" }], nextPageToken: "n2" } } : undefined,
    (u) => u.includes("/localPosts?") ? { body: { localPosts: [{ name: "accounts/9/locations/111/localPosts/p2", state: "LIVE" }] } } : undefined,
    (u) => u.includes("/media/customers?") ? { body: { mediaItems: [{ name: "accounts/9/locations/111/media/customers/c1" }], totalMediaItemCount: 31 } } : undefined,
    (u) => u.includes("/media?") ? { body: { mediaItems: [{ name: "accounts/9/locations/111/media/m1", locationAssociation: { category: "COVER" } }], totalMediaItemCount: 12 } } : undefined]);
  const r = await runJob(w.deps, "sync", work([{ locations: [loc()] }]));
  eq(r.detail.endsWith(", 2 posts, 2 photos"), true, "counted in the run note");
  const ps = w.saved.find((s) => s.fn === "svc_gbp_posts_save")!.args, ms = w.saved.find((s) => s.fn === "svc_gbp_media_save")!.args;
  eq([(ps.p_rows as { id: string }[]).map((x) => x.id), ps.p_complete], [["p1", "p2"], true], "both pages of posts, marked complete");
  eq([(ms.p_rows as { id: string; by_owner: boolean }[]).map((x) => `${x.id}:${x.by_owner}`), ms.p_owner_total, ms.p_customer_total, ms.p_complete], [["m1:true", "customers/c1:false"], 12, 31, true], "photos with Google's totals");
});

Deno.test("sync: posts not available for this profile does not lose numbers, reviews or photos", async () => {
  const w = world([token, (u) => u.includes("fetchMulti") ? { body: metrics } : undefined, (u) => u.includes("searchkeywords") ? { body: {} } : undefined, (u) => u.includes("/reviews") ? { body: {} } : undefined,
    (u) => u.includes("/localPosts?") ? { status: 403, body: { error: { message: "The caller does not have permission" } } } : undefined]);
  const r = await runJob(w.deps, "sync", work([{ locations: [loc()] }]));
  eq([r.status, w.saved.some((s) => s.fn === "svc_gbp_metrics_save"), w.saved.some((s) => s.fn === "svc_gbp_media_save"), w.saved.some((s) => s.fn === "svc_gbp_posts_save"), /posts\)/.test(r.detail), w.status()],
    ["ok", true, true, false, true, ["C1:connected"]], "the rest is saved and the problem is named");
});

const P = (over: Record<string, unknown> = {}) => ({ id: 3, location_id: "L1", connection_id: "C1", account: "accounts/9", location: "locations/111", summary: "New CPL batch starts 1 December.", cta_type: "LEARN_MORE", cta_url: "https://weoneaviation.in/cpl", photo_url: null, ...over });
const isCreate = (u: string, i?: RequestInit) => u === "https://mybusiness.googleapis.com/v4/accounts/9/locations/111/localPosts" && i?.method === "POST";

Deno.test("post: one request with exactly what the person wrote; shown in the list at once", async () => {
  const w = world([token, (u, i) => isCreate(u, i) ? { body: { name: "accounts/9/locations/111/localPosts/777", state: "LIVE", summary: "New CPL batch starts 1 December.", topicType: "STANDARD", createTime: "2026-11-25T06:00:00Z" } } : undefined], { queue: [P()] });
  const r = await runJob(w.deps, "post", work([{ locations: [loc()] }]));
  eq(r, { status: "ok", detail: "1 published, 0 not published" }, "result");
  eq([w.inits.filter((x) => x.method === "POST" && !x.url.includes("oauth2")).length, JSON.parse(w.inits[1].body)], [1, { languageCode: "en", topicType: "STANDARD", summary: "New CPL batch starts 1 December.", callToAction: { actionType: "LEARN_MORE", url: "https://weoneaviation.in/cpl" } }], "one request, the person's text");
  eq(w.saved.find((s) => s.fn === "svc_gbp_post_result")!.args, { p_id: 3, p_state: "sent", p_error: null, p_name: "accounts/9/locations/111/localPosts/777" }, "recorded with Google's name");
  const shown = w.saved.find((s) => s.fn === "svc_gbp_posts_save")!.args;
  eq([shown.p_location, (shown.p_rows as { id: string }[])[0].id, shown.p_complete], ["L1", "777", false], "added to the list without deleting anything");
});

Deno.test("post: no answer from Google is never retried (it could publish twice); refusals carry Google's reason", async () => {
  const silent = world([token, (u, i) => isCreate(u, i) ? { throws: true } : undefined], { queue: [P()] });
  const r1 = await runJob(silent.deps, "post", work([{}]));
  eq([silent.inits.filter((x) => x.method === "POST" && !x.url.includes("oauth2")).length, (silent.saved.find((s) => s.fn === "svc_gbp_post_result")!.args as { p_state: string }).p_state, /Check the profile on Google before publishing it again/.test(r1.detail)],
    [1, "failed", true], "one attempt only, marked failed with what to check");
  const rejected = world([token, (u, i) => isCreate(u, i) ? { body: { name: "accounts/9/locations/111/localPosts/9", state: "REJECTED" } } : undefined], { queue: [P()] });
  await runJob(rejected.deps, "post", work([{}]));
  eq((rejected.saved.find((s) => s.fn === "svc_gbp_post_result")!.args as { p_state: string; p_error: string }).p_error.includes("rejected the post"), true, "a post Google rejects is not called published");
  const bad = world([token, (u, i) => isCreate(u, i) ? { status: 400, body: { error: { message: "Summary contains a phone number." } } } : undefined], { queue: [P()] });
  const r3 = await runJob(bad.deps, "post", work([{}]));
  eq([/phone number/.test(r3.detail), r3.status, bad.status()], [true, "error", []], "Google's own reason is shown; the login is fine");
  const waiting = world([token, (u, i) => isCreate(u, i) ? QUOTA0 : undefined], { queue: [P()] });
  await runJob(waiting.deps, "post", work([{}]));
  eq(waiting.status(), ["C1:waiting_google"], "not approved by Google yet: the login says so");
  const revoked = world([(u) => u.includes("oauth2") ? { status: 400, body: { error: "invalid_grant" } } : undefined], { queue: [P(), P({ id: 4 })] });
  await runJob(revoked.deps, "post", work([{}]));
  eq([revoked.calls.length, revoked.saved.filter((s) => s.fn === "svc_gbp_post_result").map((s) => `${s.args.p_id}:${s.args.p_state}`)], [1, ["3:failed", "4:failed"]], "sign-in lost: nothing reaches Google");
  const none = world([token], { queue: [] });
  eq([await runJob(none.deps, "post", work([{}])), none.calls.length], [{ status: "ok", detail: "No post is waiting to be published." }, 0], "nothing queued costs no call");
  const inj = world([token], { queue: [P({ location: "locations/111/../../x" })] });
  await runJob(inj.deps, "post", work([{}]));
  eq(inj.calls.filter((u) => !u.includes("oauth2")).length, 0, "a profile name that is not a name never reaches Google");
});
