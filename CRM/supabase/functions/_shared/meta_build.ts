// Meta Ads > Strategy > Create in Meta (migration 104): turns an approved plan into Marketing API calls.
// Pure TypeScript (unit-tested); ads-sync runs the calls one by one and saves each result at once, so a retry never
// makes a second copy. Everything is created PAUSED: the owner checks it in Ads Manager and switches it on there.
//
// Order: lead forms (Page token) -> campaigns -> ad sets -> ad creatives (image ads with an uploaded picture) -> ads.
// Video and carousel creatives, and image creatives without a picture, are listed as "add in Ads Manager".
// API notes (v24+): ad-set budgets need is_adset_budget_sharing_enabled on the campaign; new ad sets need
// targeting_automation.advantage_audience set to 1 or 0; Advantage+ audience keeps age 18-65 as the hard limits and takes
// the plan's ages as a suggestion (age_range).

export interface BuildWork {
  strategy_id: number; version: number; account_id: string; currency: string | null; page_id: string;
  goal: { website_url?: string; privacy_url?: string; start_date?: string; languages?: string[]; phone?: string };
  plan: any; steps: Record<string, { id?: string; status?: string; error?: string }>; images: Record<string, { hash?: string }>;
  videos?: Record<string, { id?: string; thumb_hash?: string }>;
  posts?: Record<string, { ig_media_id?: string }>; ig_user_id?: string | null;
}
export interface Step { key: string; kind: "form" | "campaign" | "adset" | "creative" | "ad"; label: string; needs: string[]; skip?: string }

// INR and most currencies have 2 decimals; Meta takes budgets in the smallest unit.
const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND", "CLP", "COP", "HUF", "ISK", "PYG", "TWD", "IDR"]);
export const minor = (amount: number, currency: string | null) =>
  Math.round(Number(amount) * (ZERO_DECIMAL.has(String(currency ?? "INR").toUpperCase()) ? 1 : 100));

export const tag = (w: BuildWork) => `CRM S${w.strategy_id}`;
const nm = (w: BuildWork, name: string) => `${String(name).slice(0, 80)} · ${tag(w)}`;

// The steps an approved plan needs, in order.
export function planSteps(w: BuildWork): Step[] {
  const p = w.plan ?? {};
  const out: Step[] = [];
  const creatives = new Map<string, any>((p.creatives ?? []).map((c: any) => [String(c.key), c]));
  for (const f of p.forms ?? []) out.push({ key: `form:${f.key}`, kind: "form", label: `Lead form "${f.name}"`, needs: [] });
  for (const c of p.campaigns ?? []) out.push({ key: `campaign:${c.key}`, kind: "campaign", label: `Campaign "${c.name}"`, needs: [] });
  for (const c of p.campaigns ?? []) for (const a of c.adsets ?? [])
    out.push({ key: `adset:${a.key}`, kind: "adset", label: `Ad set "${a.name}"`, needs: [`campaign:${c.key}`] });
  // a creative carries its lead form, so one per creative and form
  const pairs = new Set<string>();
  for (const c of p.campaigns ?? []) for (const a of c.adsets ?? []) for (const k of a.ads ?? []) pairs.add(`${k}|${a.form}`);
  for (const pair of pairs) {
    const [k, f] = pair.split("|");
    const cr = creatives.get(k);
    if (!cr) continue;
    const post = w.posts?.[k]?.ig_media_id && w.ig_user_id;
    const skip = post ? undefined : cr.format === "video"
      ? (w.videos?.[k]?.id && w.videos?.[k]?.thumb_hash ? undefined
        : "Video ad: attach its video in Growth > Content > Ad creatives and press Use in Meta, then press Create in Meta again")
      : cr.format !== "image" ? "Carousel ad: upload the cards and create it in Ads Manager (text is in the plan)"
      : !w.images?.[k]?.hash ? "Add the picture for this creative in the CRM, then press Create in Meta again" : undefined;
    out.push({ key: `creative:${k}:${f}`, kind: "creative", label: `Creative "${cr.name}"`, needs: [`form:${f}`], skip });
  }
  for (const c of p.campaigns ?? []) for (const a of c.adsets ?? []) for (const k of a.ads ?? []) {
    const cr = creatives.get(String(k));
    out.push({ key: `ad:${a.key}:${k}`, kind: "ad", label: `Ad "${cr?.name ?? k}" in "${a.name}"`, needs: [`adset:${a.key}`, `creative:${k}:${a.form}`] });
  }
  return out;
}

// ------------------------------------------------------------------ request bodies (form-urlencoded values)
const J = (o: unknown) => JSON.stringify(o);

export function formParams(w: BuildWork, f: any, minimal = false, button?: "call" | "whatsapp" | "website"): Record<string, string> {
  let n = 0;
  const questions = (f.questions ?? []).map((q: any) => q.type === "CUSTOM"
    ? { type: "CUSTOM", key: `q${++n}`, label: String(q.label).slice(0, 80),
        ...(Array.isArray(q.options) && q.options.length ? { options: q.options.map((o: string, i: number) => ({ value: String(o).slice(0, 60), key: `q${n}o${i + 1}` })) } : {}) }
    : { type: q.type });
  const site = w.goal.website_url || "https://weoneaviation.in";
  const out: Record<string, string> = {
    name: nm(w, f.name).slice(0, 100), questions: J(questions), locale: "en_US", follow_up_action_url: site,
    privacy_policy: J({ url: w.goal.privacy_url, link_text: "Privacy policy" }),
    is_optimized_for_quality: f.type === "higher_intent" ? "true" : "false",
    block_display_for_non_targeted_viewer: "true",
  };
  if (!minimal) {
    if (f.intro || f.headline) out.context_card = J({ title: String(f.headline || f.name).slice(0, 60), style: "PARAGRAPH_STYLE", content: [String(f.intro || "").slice(0, 700)] });
    if (f.thank_you?.title) out.thank_you_page = J(thankYouPage(w, f, site, button));
  }
  return out;
}

// Thank-you screen button. The plan says it as forms[].thank_you.button_type (Meta's own names: CALL_BUSINESS, WHATSAPP,
// VIEW_WEBSITE) or .button ("call" / "whatsapp" / "website"). CALL_BUSINESS carries the counsellor number
// (thank_you.business_phone_number or .phone, else the plan's or the strategy's goal.phone); WHATSAPP has no number field
// (Meta uses the WhatsApp number connected to the Page); anything else -> VIEW_WEBSITE. Enum from the Graph API
// leadgen_forms reference. website_url is always sent (the Lead Ads guide says the API needs it). No number -> website.
const BUTTON_TYPES: Record<string, "call" | "whatsapp" | "website"> = { CALL_BUSINESS: "call", WHATSAPP: "whatsapp", VIEW_WEBSITE: "website" };
export const thankYouButton = (f: any): "call" | "whatsapp" | "website" => {
  const bt = BUTTON_TYPES[String(f?.thank_you?.button_type ?? "").toUpperCase()];
  if (bt) return bt;
  const b = String(f?.thank_you?.button ?? "").toLowerCase();
  return b === "call" || b === "whatsapp" ? b : "website";
};
export function businessPhone(raw: unknown): { number: string; country: string | null } | null {
  const d = String(raw ?? "").replace(/[^\d+]/g, "").replace(/(?!^)\+/g, "");
  const digits = d.replace(/\D/g, "");
  if (!d.startsWith("+") && digits.length === 10) return { number: `+91${digits}`, country: "IN" };   // Indian mobile without code
  if (!d.startsWith("+") || digits.length < 8 || digits.length > 15) return null;
  return { number: `+${digits}`, country: digits.startsWith("91") && digits.length === 12 ? "IN" : null };
}
function thankYouPage(w: BuildWork, f: any, site: string, button?: "call" | "whatsapp" | "website") {
  const t = f.thank_you;
  const base = { title: String(t.title).slice(0, 60), body: String(t.body || "").slice(0, 300), website_url: site };
  const want = button ?? thankYouButton(f);
  const ph = businessPhone(t.business_phone_number ?? t.phone ?? w.plan?.goal?.phone ?? w.goal.phone);
  if (want === "whatsapp") return { ...base, button_type: "WHATSAPP", button_text: String(t.button_text || "Chat on WhatsApp").slice(0, 30) };
  if (want === "call" && ph) return { ...base, button_type: "CALL_BUSINESS", button_text: String(t.button_text || "Call now").slice(0, 30),
    business_phone_number: ph.number, ...(ph.country ? { country_code: ph.country } : {}) };
  return { ...base, button_type: "VIEW_WEBSITE", button_text: String(want === "website" ? t.button_text || "Visit website" : "Visit website").slice(0, 30) };
}

// What to send when Meta refuses a form: the WhatsApp button needs a WhatsApp number linked to the Page, so try the call
// button next, then the form without the intro / thank-you screens.
export function formAttempts(w: BuildWork, f: any): Record<string, string>[] {
  return [formParams(w, f), ...(f?.thank_you?.title && thankYouButton(f) === "whatsapp" ? [formParams(w, f, false, "call")] : []), formParams(w, f, true)];
}

// Creates a lead form, falling back as above. A fallback is never silent: the warning says what Meta refused and what the
// form lacks, and ads-sync keeps it on the build step (shown in Strategy > Create in Meta) and in the build result.
export async function createLeadForm(w: BuildWork, f: any, create: (p: Record<string, string>) => Promise<string>,
  fatal: (e: unknown) => boolean): Promise<{ id: string; attempt: number; warning: string | null }> {
  const tries = formAttempts(w, f);
  const errs: string[] = [];
  for (let i = 0; ; i++) {
    try {
      const id = await create(tries[i]);
      if (i === 0) return { id, attempt: 0, warning: null };
      const why = (errs[errs.length - 1] ?? "no reason given").slice(0, 200);
      const button = thankYouButton(f) === "whatsapp" ? "WhatsApp" : thankYouButton(f) === "call" ? "Call" : "website";
      const warning = i === tries.length - 1
        ? `Meta refused the form's intro / thank-you screens (${why}), so it was made WITHOUT them: no intro text and no ${button} button. Check it in Ads Manager before switching the ad set on.`
        : `Meta refused the WhatsApp button (${why}), so the form has the Call button instead. Check it in Ads Manager before switching the ad set on.`;
      return { id, attempt: i, warning };
    } catch (e) {
      if (fatal(e) || i === tries.length - 1) throw e;
      errs.push(e instanceof Error ? e.message : String(e));
    }
  }
}

export function campaignParams(w: BuildWork, c: any): Record<string, string> {
  const out: Record<string, string> = { name: nm(w, c.name), objective: "OUTCOME_LEADS", status: "PAUSED", special_ad_categories: "[]", buying_type: "AUCTION" };
  if (c.budget_level === "campaign") {
    out.daily_budget = String(minor(c.daily_budget, w.currency));
    out.bid_strategy = "LOWEST_COST_WITHOUT_CAP";
  } else out.is_adset_budget_sharing_enabled = "false";   // keep the plan's split exactly
  return out;
}

const POS: Record<string, [string, string]> = {
  facebook_feed: ["facebook", "feed"], facebook_reels: ["facebook", "facebook_reels"], facebook_stories: ["facebook", "story"],
  instagram_feed: ["instagram", "stream"], instagram_reels: ["instagram", "reels"], instagram_stories: ["instagram", "story"],
  instagram_explore: ["instagram", "explore"],
};
export interface Geo { countries: string[]; regions: { key: string }[]; cities: { key: string; radius?: number; distance_unit?: string }[]; zips?: { key: string }[] }

// Funnel audiences (migration 107): keys from the Funnel audience library -> Meta ids. Exclusions are hard limits in Meta;
// included custom audiences are a hint under Advantage+ audience. New-people ad sets (funnel "prospecting", the default)
// also get the default exclusions (admissions, recent leads).
export interface Aud { map: Record<string, string>; defaults: string[] }
export function audienceSpec(a: any, aud?: Aud): { include: { id: string }[]; exclude: { id: string }[]; missing: string[] } {
  const au = a?.audience ?? {}, map = aud?.map ?? {}, missing: string[] = [];
  const ids = (keys: unknown) => (Array.isArray(keys) ? keys : []).map(String).flatMap((k) => (map[k] ? [map[k]] : (missing.push(k), [])));
  const funnel = String(au.funnel ?? "prospecting");
  // new-people ad sets: included audiences are hints only under Advantage+ audience; without it they would become the
  // whole audience, so they are left out (migration 109)
  const include = funnel === "prospecting" && au.advantage_audience !== true ? [] : [...new Set(ids(au.include_audiences))];
  const ex = new Set([...ids(au.exclude_audiences), ...(funnel === "prospecting" ? (aud?.defaults ?? []) : [])]);
  for (const i of include) ex.delete(i);
  return { include: include.slice(0, 50).map((id) => ({ id })), exclude: [...ex].slice(0, 50).map((id) => ({ id })), missing };
}

// income: options Meta's targeting search returned for this account (migration 114), each with its own targeting field
// ("type", e.g. "income"); they form their own flexible_spec entry, so they narrow the interests (AND), not widen them.
export function targeting(a: any, geo: Geo, interests: { id: string; name: string }[], aud?: Aud, income: { id: string; name: string; type: string }[] = []) {
  const au = a.audience ?? {};
  const geo_locations: Record<string, unknown> = {};
  if (geo.countries.length) geo_locations.countries = geo.countries;
  if (geo.regions.length) geo_locations.regions = geo.regions;
  if (geo.cities.length) geo_locations.cities = geo.cities;
  if (geo.zips?.length) geo_locations.zips = geo.zips;
  const t: Record<string, unknown> = { geo_locations };
  const amin = Math.max(18, Number(au.age_min) || 18), amax = Math.min(65, Math.max(amin, Number(au.age_max) || 65));
  if (au.advantage_audience === true) {
    t.age_min = 18; t.age_max = 65;
    if (amin > 18 || amax < 65) t.age_range = [amin, amax];   // a suggestion, not a limit
    t.targeting_automation = { advantage_audience: 1 };
  } else {
    t.age_min = amin; t.age_max = amax;
    if (au.genders === "male") t.genders = [1];
    if (au.genders === "female") t.genders = [2];
    t.targeting_automation = { advantage_audience: 0 };
  }
  const flex: Record<string, unknown>[] = [];
  if (interests.length) flex.push({ interests: interests.slice(0, 25) });
  const inc: Record<string, { id: string; name: string }[]> = {};
  for (const o of income) if (/^[a-z_]{3,40}$/.test(o.type) && o.id) (inc[o.type] ??= []).push({ id: o.id, name: o.name });
  if (Object.keys(inc).length) flex.push(inc);
  if (flex.length) t.flexible_spec = flex;
  const ca = audienceSpec(a, aud);
  if (ca.include.length) t.custom_audiences = ca.include;
  if (ca.exclude.length) t.excluded_custom_audiences = ca.exclude;
  if (Array.isArray(a.placements)) {
    const plat = new Set<string>(), fb: string[] = [], ig: string[] = [];
    for (const p of a.placements) {
      const m = POS[p];
      if (!m) continue;
      plat.add(m[0]);
      (m[0] === "facebook" ? fb : ig).push(m[1]);
    }
    if (plat.size) {
      t.publisher_platforms = [...plat];
      if (fb.length) t.facebook_positions = fb;
      if (ig.length) t.instagram_positions = ig;
    }
  }
  return t;
}

export function adsetParams(w: BuildWork, c: any, a: any, campaignId: string, t: Record<string, unknown>, today: string): Record<string, string> {
  const out: Record<string, string> = {
    name: nm(w, a.name), campaign_id: campaignId, status: "PAUSED", billing_event: "IMPRESSIONS",
    optimization_goal: a.optimization === "QUALITY_LEAD" ? "QUALITY_LEAD" : "LEAD_GENERATION", destination_type: "ON_AD",
    promoted_object: J({ page_id: w.page_id }), targeting: J(t),
  };
  if (c.budget_level !== "campaign") {
    out.daily_budget = String(minor(a.daily_budget, w.currency));
    out.bid_strategy = "LOWEST_COST_WITHOUT_CAP";
  }
  if (w.goal.start_date && w.goal.start_date > today) out.start_time = `${w.goal.start_date}T09:00:00+0530`;
  return out;
}

// Meta retires interests and names the replacement in the error ("deprecated_interest_id" ... "alternative_interest_id").
// Returns the interests with each retired one swapped for its replacement (or dropped when none), or null when the error is
// about something else, so the caller retries once only for this case.
export function swapDeprecated(msg: string, interests: { id: string; name: string }[]): { id: string; name: string }[] | null {
  if (!/deprecated_interest_id/.test(msg)) return null;
  const alts = new Map<string, { id: string; name: string } | null>();
  for (const m of msg.matchAll(/\{[^{}]*"deprecated_interest_id"\s*:\s*"?(\d+)"?[^{}]*\}/g)) {
    const alt = /"alternative_interest_id"\s*:\s*"?(\d+)"?/.exec(m[0]);
    const nm = /"alternative_interest_name"\s*:\s*"([^"]*)"/.exec(m[0]);
    alts.set(m[1], alt ? { id: alt[1], name: nm?.[1] ?? "" } : null);
  }
  if (!alts.size) return null;
  const out: { id: string; name: string }[] = [];
  for (const i of interests) {
    const r = alts.has(i.id) ? alts.get(i.id) : i;
    if (r && !out.some((o) => o.id === r.id)) out.push(r);
  }
  return out;
}

export function creativeParams(w: BuildWork, cr: any, formId: string): Record<string, string> {
  const post = w.posts?.[cr.key]?.ig_media_id;
  if (post && w.ig_user_id) {                    // the Instagram post itself becomes the ad: likes and comments stay on one post
    return {
      name: nm(w, cr.name), object_id: String(w.page_id), instagram_user_id: String(w.ig_user_id), source_instagram_media_id: String(post),
      // Meta needs a link next to the form on a creative made from an Instagram post ("The link field is required")
      call_to_action: J({ type: cr.cta || "LEARN_MORE", value: { lead_gen_form_id: formId, link: w.goal.website_url || "https://weoneaviation.in" } }),
    };
  }
  const v = w.videos?.[cr.key];
  if (cr.format === "video" && v?.id) {
    return {
      name: nm(w, cr.name),
      object_story_spec: J({ page_id: w.page_id, video_data: {
        video_id: v.id, image_hash: v.thumb_hash, message: String(cr.primary_text ?? ""), title: String(cr.headline ?? "").slice(0, 255),
        ...(cr.description ? { link_description: String(cr.description) } : {}),
        call_to_action: { type: cr.cta || "LEARN_MORE", value: { lead_gen_form_id: formId } } } }),
    };
  }
  return {
    name: nm(w, cr.name),
    object_story_spec: J({ page_id: w.page_id, link_data: {
      image_hash: w.images[cr.key]?.hash, link: w.goal.website_url || "https://weoneaviation.in",
      message: String(cr.primary_text ?? ""), name: String(cr.headline ?? "").slice(0, 255),
      ...(cr.description ? { description: String(cr.description) } : {}),
      call_to_action: { type: cr.cta || "LEARN_MORE", value: { lead_gen_form_id: formId } } } }),
  };
}

export const adParams = (w: BuildWork, label: string, adsetId: string, creativeId: string): Record<string, string> =>
  ({ name: nm(w, label).slice(0, 120), adset_id: adsetId, creative: J({ creative_id: creativeId }), status: "PAUSED" });

// What to search for each plan location (Meta needs its own location keys).
export function geoQueries(a: any): { name: string; type: "country" | "region" | "city" | "zip"; radius_km?: number }[] {
  return ((a.audience?.locations ?? []) as any[]).filter((l) => l?.name && ["country", "region", "city", "zip"].includes(l.type)
      && (l.type !== "zip" || /^[1-9][0-9]{5}$/.test(String(l.name))))
    .map((l) => ({ name: String(l.name).slice(0, 80), type: l.type, ...(l.type === "city" && Number(l.radius_km) > 0 ? { radius_km: Math.min(80, Math.max(10, Number(l.radius_km))) } : {}) }));
}
const COUNTRY: Record<string, string> = { india: "IN", "united arab emirates": "AE", uae: "AE", nepal: "NP" };
export const countryCode = (name: string) => (/^[A-Z]{2}$/.test(name) ? name : COUNTRY[name.toLowerCase()] ?? null);

// The best match from Meta's search: same name first, then the first result (India first for places).
export function bestMatch<T extends { name?: string; country_code?: string }>(rows: T[], name: string): T | null {
  if (!rows?.length) return null;
  const n = name.trim().toLowerCase();
  return rows.find((r) => String(r.name ?? "").toLowerCase() === n && (!r.country_code || r.country_code === "IN"))
    ?? rows.find((r) => String(r.name ?? "").toLowerCase() === n)
    ?? rows.find((r) => !r.country_code || r.country_code === "IN") ?? rows[0];
}

// Picture checks before uploading (PNG or JPEG, up to 8 MB).
export function imageKind(b64: string): "png" | "jpeg" | null {
  const head = b64.slice(0, 16);
  if (head.startsWith("iVBORw0KGgo")) return "png";
  if (head.startsWith("/9j/")) return "jpeg";
  return null;
}
export const MAX_IMAGE_B64 = Math.ceil((8 * 1024 * 1024 * 4) / 3);
