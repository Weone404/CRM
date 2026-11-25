// Google Business Profile: request addresses and every answer shape Google can send (139). deno test supabase/tests/gbp/
import { DAILY_METRICS, accountsUrl, addDays, gbpError, keywordsUrl, locationsUrl, mediaUrl, metricsUrl, monthsBack, parseAccounts, parseDetails, parseKeywords,
  parseLocations, parseMedia, parseMetrics, parsePosts, parseReviews, postBody, postsUrl, reviewsUrl } from "../../functions/_shared/gbp.ts";

const eq = (a: unknown, b: unknown, what: string) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${what}\n  got      ${JSON.stringify(a)}\n  expected ${JSON.stringify(b)}`);
};
const throws = (fn: () => unknown, what: string) => { let t = false; try { fn(); } catch { t = true; } if (!t) throw new Error(`${what}: did not refuse`); };

Deno.test("daily numbers: one request asks for every metric over an inclusive date range", () => {
  const u = metricsUrl("locations/123", "2026-08-28", "2026-11-24");
  eq(u.startsWith("https://businessprofileperformance.googleapis.com/v1/locations/123:fetchMultiDailyMetricsTimeSeries?"), true, "address");
  eq(DAILY_METRICS.every((m) => u.includes(`dailyMetrics=${m}`)), true, "all metrics");
  eq(u.includes("dailyRange.start_date.year=2026&dailyRange.start_date.month=8&dailyRange.start_date.day=28"), true, "start");
  eq(u.includes("dailyRange.end_date.year=2026&dailyRange.end_date.month=11&dailyRange.end_date.day=24"), true, "end");
});

Deno.test("daily numbers: a day Google reports without a value is 0, not missing", () => {
  const b = { multiDailyMetricTimeSeries: [{ dailyMetricTimeSeries: [
    { dailyMetric: "CALL_CLICKS", timeSeries: { datedValues: [{ date: { year: 2026, month: 11, day: 1 }, value: "3" }, { date: { year: 2026, month: 11, day: 2 } }] } },
    { dailyMetric: "WEBSITE_CLICKS", timeSeries: { datedValues: [{ date: { year: 2026, month: 11, day: 1 }, value: "12" }] } }] }] };
  eq(parseMetrics(b), [{ d: "2026-11-01", m: "CALL_CLICKS", v: 3 }, { d: "2026-11-02", m: "CALL_CLICKS", v: 0 }, { d: "2026-11-01", m: "WEBSITE_CLICKS", v: 12 }], "rows");
});

Deno.test("daily numbers: junk, impossible dates, negative values and breakdown rows are never counted", () => {
  const b = { multiDailyMetricTimeSeries: [{ dailyMetricTimeSeries: [
    { dailyMetric: "CALL_CLICKS", dailySubEntityType: { dayOfWeek: "MONDAY" }, timeSeries: { datedValues: [{ date: { year: 2026, month: 11, day: 1 }, value: "9" }] } },
    { dailyMetric: "drop table", timeSeries: { datedValues: [{ date: { year: 2026, month: 11, day: 1 }, value: "9" }] } },
    { dailyMetric: "CALL_CLICKS", timeSeries: { datedValues: [{ date: { year: 2026, month: 13, day: 1 }, value: "9" }, { date: {}, value: "9" }, { value: "4" },
      { date: { year: 2026, month: 11, day: 3 }, value: "-5" }, { date: { year: 2026, month: 11, day: 4 }, value: "abc" }] } }] }] };
  eq(parseMetrics(b), [{ d: "2026-11-03", m: "CALL_CLICKS", v: 0 }, { d: "2026-11-04", m: "CALL_CLICKS", v: 0 }], "only the two real days, as 0");
  for (const x of [null, undefined, {}, [], "text", { multiDailyMetricTimeSeries: "x" }, { multiDailyMetricTimeSeries: [null, { dailyMetricTimeSeries: [null] }] }]) eq(parseMetrics(x), [], "empty");
});

Deno.test("search words: one month per request; rare words come as 'fewer than N'", () => {
  const u = keywordsUrl("locations/123", 2026, 10, "tok/+=");
  eq(u.includes("monthlyRange.start_month.year=2026&monthlyRange.start_month.month=10&monthlyRange.end_month.year=2026&monthlyRange.end_month.month=10"), true, "one month");
  eq(u.endsWith("&pageToken=tok%2F%2B%3D"), true, "page token is escaped");
  const p = parseKeywords({ searchKeywordsCounts: [{ searchKeyword: " Pilot Training Delhi ", insightsValue: { value: "148" } },
    { searchKeyword: "dgca ground classes", insightsValue: { threshold: "15" } }, { searchKeyword: "", insightsValue: { value: "5" } },
    { searchKeyword: "no numbers" }, { insightsValue: { value: "9" } }, null], nextPageToken: "abc" });
  eq(p, { rows: [{ k: "pilot training delhi", v: 148, below: null }, { k: "dgca ground classes", v: null, below: 15 }], next: "abc" }, "rows");
  eq(parseKeywords({}), { rows: [], next: null }, "nothing");
});

Deno.test("months: the last complete months, newest first, across a year end", () => {
  eq(monthsBack("2026-11-24", 3).map((m) => m.first), ["2026-10-01", "2026-09-01", "2026-08-01"], "normal");
  eq(monthsBack("2027-02-01", 3).map((m) => `${m.y}-${m.m}`), ["2027-1", "2026-12", "2026-11"], "over new year");
  eq(addDays("2026-03-01", -1), "2026-02-28", "day before 1 March"); eq(addDays("2028-03-01", -1), "2028-02-29", "leap year");
});

Deno.test("reviews: stars, anonymous reviewers, reply and totals", () => {
  const p = parseReviews({ averageRating: 4.7, totalReviewCount: 213, nextPageToken: "n2", reviews: [
    { reviewId: "r1", reviewer: { displayName: "Asha V" }, starRating: "FIVE", comment: "Great faculty", createTime: "2026-11-20T10:00:00Z", updateTime: "2026-11-20T10:00:00Z",
      reviewReply: { comment: "Thank you, Asha.", updateTime: "2026-11-21T05:00:00Z" } },
    { reviewId: "r2", reviewer: { displayName: "Hidden", isAnonymous: true }, starRating: "TWO", createTime: "not a date" },
    { reviewer: { displayName: "No id" }, starRating: "ONE" }, { reviewId: "r3", starRating: "STAR_RATING_UNSPECIFIED" }] });
  eq(p.total, 213, "total"); eq(p.rating, 4.7, "rating"); eq(p.next, "n2", "next page");
  eq(p.rows[0], { id: "r1", reviewer: "Asha V", stars: 5, comment: "Great faculty", created: "2026-11-20T10:00:00.000Z", updated: "2026-11-20T10:00:00.000Z",
    reply: "Thank you, Asha.", reply_at: "2026-11-21T05:00:00.000Z" }, "full review");
  eq(p.rows[1], { id: "r2", reviewer: "A Google user", stars: 2, comment: "", created: null, updated: null, reply: "", reply_at: null }, "anonymous, no text, bad date");
  eq([p.rows.length, p.rows[2].stars], [3, null], "a review without an id is dropped; an unknown rating is empty, not a guess");
  eq(parseReviews({ averageRating: 9, totalReviewCount: -1 }), { rows: [], total: null, rating: null, next: null }, "impossible totals are ignored");
  eq(reviewsUrl("accounts/9", "locations/123").startsWith("https://mybusiness.googleapis.com/v4/accounts/9/locations/123/reviews?pageSize=50&orderBy=updateTime%20desc"), true, "address");
});

Deno.test("profiles: address in one line, the fields the CRM shows, paging", () => {
  const p = parseLocations({ nextPageToken: "p2", locations: [
    { name: "locations/123", title: "We One Aviation", storefrontAddress: { addressLines: ["Plot 5, Sector 7", " "], locality: "Dwarka", administrativeArea: "Delhi", postalCode: "110075" },
      phoneNumbers: { primaryPhone: "+91 98110 00000" }, websiteUri: "https://weoneaviation.in/", categories: { primaryCategory: { displayName: "Flight school" } },
      metadata: { mapsUri: "https://maps.google.com/?cid=1", placeId: "ChIJ1", hasVoiceOfMerchant: true } },
    { name: "locations/456" }, { name: "accounts/1/locations/9" }, { title: "no name" }] }, "accounts/9");
  eq(p.rows[0], { account: "accounts/9", name: "locations/123", title: "We One Aviation", address: "Plot 5, Sector 7, Dwarka, Delhi, 110075", phone: "+91 98110 00000",
    website: "https://weoneaviation.in/", category: "Flight school", maps_uri: "https://maps.google.com/?cid=1", place_id: "ChIJ1", verified: true,
    details: { description: "", hours: [], special_hours: 0, open_status: null, more_categories: [], can_post: null, pending_edits: false, google_updated: false, review_uri: null, service_area: false } }, "full profile");
  eq([p.rows.length, p.rows[1].title, p.rows[1].verified, p.next], [2, "", null, "p2"], "a bare profile is kept; malformed names are dropped");
  eq(parseAccounts({ accounts: [{ name: "accounts/9", accountName: "Nikhil" }, { name: "x" }, null] }), { rows: [{ name: "accounts/9", label: "Nikhil" }], next: null }, "accounts");
  eq(locationsUrl("accounts/9").includes("readMask=name,title,storefrontAddress,websiteUri,phoneNumbers,categories,metadata,profile,regularHours,specialHours,openInfo,serviceArea&"), true, "read mask");
  eq(accountsUrl("t").endsWith("pageToken=t"), true, "accounts paging");
});

Deno.test("addresses refuse anything that is not a Google account, profile or date (no injected paths)", () => {
  throws(() => metricsUrl("locations/123/../../x", "2026-01-01", "2026-01-02"), "bad location");
  throws(() => metricsUrl("locations/123", "01-01-2026", "2026-01-02"), "bad date");
  throws(() => keywordsUrl("accounts/1", 2026, 1), "account given as location");
  throws(() => reviewsUrl("accounts/1?x=1", "locations/2"), "bad account");
  throws(() => locationsUrl("locations/2"), "location given as account");
});

Deno.test("what a failed Google call means, in plain words", () => {
  const quota0 = { error: { code: 429, status: "RESOURCE_EXHAUSTED", message: "Quota exceeded for quota metric 'Requests' and limit 'Requests per minute'",
    details: [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "RATE_LIMIT_EXCEEDED", metadata: { quota_limit_value: "0", quota_limit: "DefaultRequestsPerMinutePerProject" } }] } };
  eq(gbpError("X", 429, quota0).state, "waiting_google", "quota 0 = Google has not approved the project yet");
  eq(gbpError("X", 429, { error: { message: "Quota exceeded", details: [{ metadata: { quota_limit_value: "300" } }] } }).state, "busy", "a real per-minute limit is temporary");
  eq(gbpError("X", 401, { error: { message: "Request had invalid authentication credentials." } }).state, "needs_signin", "expired sign-in");
  eq(gbpError("X", 400, { error: "invalid_grant", error_description: "Token has been expired or revoked." }).state, "needs_signin", "revoked token");
  eq(gbpError("X", 403, { error: { message: "Request had insufficient authentication scopes.", details: [{ reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }] } }).state, "needs_signin", "made without the Business Profile permission");
  const off = gbpError("Business Profile Performance API", 403, { error: { message: "Business Profile Performance API has not been used in project 123 before or it is disabled.", details: [{ reason: "SERVICE_DISABLED" }] } });
  eq([off.state, off.message.includes('"Business Profile Performance API" is switched off')], ["api_off", true], "API switched off, named");
  eq(gbpError("X", 403, { error: { message: "The caller does not have permission" } }).state, "no_access", "not an owner or manager");
  eq(gbpError("X", 404, { error: { message: "Requested entity was not found." } }).state, "no_access", "profile gone");
  eq(gbpError("X", 500, {}).state, "error", "anything else");
  eq(gbpError("X", 503, null).message.length <= 300 && gbpError("X", 500, { error: { message: "y".repeat(900) } }).message.length <= 300, true, "messages stay short");
});

// ---------------------------------------------------------------- health check, posts, photos (143)
Deno.test("profile details: description, hours as day/open/close, open status, extra categories, what Google allows", () => {
  const d = parseDetails({ profile: { description: "DGCA ground classes in Dwarka." }, regularHours: { periods: [
      { openDay: "MONDAY", openTime: { hours: 9, minutes: 30 }, closeDay: "MONDAY", closeTime: { hours: 18 } }, { openDay: "SUNDAY", openTime: {}, closeDay: "MONDAY", closeTime: { hours: 24 } },
      { openDay: "FUNDAY", openTime: { hours: 1 } }, null] },
    specialHours: { specialHourPeriods: [{}, {}] }, openInfo: { status: "CLOSED_TEMPORARILY" }, serviceArea: { businessType: "CUSTOMER_LOCATION_ONLY" },
    categories: { primaryCategory: { displayName: "Flight school" }, additionalCategories: [{ displayName: " Aviation training institute " }, { displayName: "" }, null] },
    metadata: { canOperateLocalPost: true, hasPendingEdits: true, hasGoogleUpdated: true, newReviewUri: "https://g.page/r/abc/review" } });
  eq(d, { description: "DGCA ground classes in Dwarka.", hours: [{ d: "MONDAY", o: "09:30", c: "18:00" }, { d: "SUNDAY", o: "00:00", c: "24:00" }], special_hours: 2, open_status: "CLOSED_TEMPORARILY",
    more_categories: ["Aviation training institute"], can_post: true, pending_edits: true, google_updated: true, review_uri: "https://g.page/r/abc/review", service_area: true }, "full");
  for (const x of [null, undefined, {}, "x", { regularHours: "9-5", profile: 7, metadata: { newReviewUri: "javascript:alert(1)", canOperateLocalPost: "yes" }, openInfo: { status: "drop table" }, serviceArea: {} }])
    eq(parseDetails(x), { description: x && typeof x === "object" && "profile" in x ? "" : "", hours: [], special_hours: 0, open_status: null, more_categories: [], can_post: null, pending_edits: false, google_updated: false, review_uri: null, service_area: false }, "junk gives empty details, never an error");
});

Deno.test("posts: state, button, first picture, link; ids that are not ids are dropped", () => {
  const p = parsePosts({ nextPageToken: "n", localPosts: [
    { name: "accounts/9/locations/111/localPosts/123abc", topicType: "STANDARD", state: "LIVE", summary: "New batch", callToAction: { actionType: "LEARN_MORE", url: "https://weoneaviation.in/dgca" },
      media: [{ googleUrl: "https://lh3.googleusercontent.com/g", thumbnailUrl: "https://lh3.googleusercontent.com/t" }], searchUrl: "https://local.google.com/place?id=1", createTime: "2026-11-20T10:00:00Z", scheduledTime: "bad" },
    { name: "accounts/9/locations/111/localPosts/2", state: "REJECTED", callToAction: { actionType: "BOOK", url: "javascript:alert(1)" }, media: [{ googleUrl: "http://x/y.jpg" }] },
    { name: "accounts/9/locations/111/localPosts/../../x" }, { summary: "no name" }, null] });
  eq(p.rows[0], { id: "123abc", topic: "STANDARD", state: "LIVE", summary: "New batch", cta_type: "LEARN_MORE", cta_url: "https://weoneaviation.in/dgca", media_url: "https://lh3.googleusercontent.com/t",
    search_url: "https://local.google.com/place?id=1", created: "2026-11-20T10:00:00.000Z", updated: null, scheduled: null }, "full post");
  eq([p.rows.length, p.rows[1].cta_url, p.rows[1].media_url, p.next], [2, "", "", "n"], "links that are not https are dropped; malformed posts are dropped");
  eq(postsUrl("accounts/9", "locations/111", "a b"), "https://mybusiness.googleapis.com/v4/accounts/9/locations/111/localPosts?pageSize=100&pageToken=a%20b", "address");
});

Deno.test("a new post: only what the person wrote; Call carries no link; a photo is a link", () => {
  eq(postBody({ summary: "New CPL batch starts 1 December." }), { languageCode: "en", topicType: "STANDARD", summary: "New CPL batch starts 1 December." }, "text only");
  eq(postBody({ summary: "Hi", cta_type: "LEARN_MORE", cta_url: "https://weoneaviation.in/cpl", photo_url: "https://weoneaviation.in/a.jpg" }),
    { languageCode: "en", topicType: "STANDARD", summary: "Hi", callToAction: { actionType: "LEARN_MORE", url: "https://weoneaviation.in/cpl" }, media: [{ mediaFormat: "PHOTO", sourceUrl: "https://weoneaviation.in/a.jpg" }] }, "button and photo");
  eq(postBody({ summary: "Hi", cta_type: "CALL", cta_url: "https://ignored" }).callToAction, { actionType: "CALL" }, "Call");
});

Deno.test("photos: the owner's by kind, customers' marked as such, Google's own total", () => {
  const o = parseMedia({ totalMediaItemCount: 14, nextPageToken: "p2", mediaItems: [
    { name: "accounts/9/locations/111/media/AF1Qip", mediaFormat: "PHOTO", locationAssociation: { category: "COVER" }, googleUrl: "https://lh3.googleusercontent.com/g", thumbnailUrl: "https://lh3.googleusercontent.com/t", createTime: "2026-11-01T00:00:00Z", description: "Campus" },
    { name: "accounts/9/locations/111/media/x2", mediaFormat: "VIDEO", googleUrl: "javascript:alert(1)" }, { mediaFormat: "PHOTO" }, null] }, true);
  eq(o.rows[0], { id: "AF1Qip", by_owner: true, format: "PHOTO", category: "COVER", thumb: "https://lh3.googleusercontent.com/t", url: "https://lh3.googleusercontent.com/g", description: "Campus", created: "2026-11-01T00:00:00.000Z" }, "owner photo");
  eq([o.rows.length, o.rows[1].url, o.rows[1].category, o.total, o.next], [2, "", "", 14, "p2"], "bad links dropped; items without a name dropped");
  const c = parseMedia({ mediaItems: [{ name: "accounts/9/locations/111/media/customers/c1", mediaFormat: "PHOTO", locationAssociation: { category: "COVER" } }], totalMediaItemCount: -3 }, false);
  eq([c.rows[0].id, c.rows[0].by_owner, c.rows[0].category, c.total], ["customers/c1", false, "CUSTOMER", null], "a customer photo is never counted as a cover; an impossible total is ignored");
  eq(mediaUrl("accounts/9", "locations/111", true).includes("/media/customers?pageSize=100"), true, "customers address");
});
