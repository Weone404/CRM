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
  goal: { website_url?: string; privacy_url?: string; start_date?: string; languages?: string[] };
  plan: any; steps: Record<string, { id?: string; status?: string; error?: string }>; images: Record<string, { hash?: string }>;
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
    const skip = cr.format !== "image" ? `${cr.format === "video" ? "Video" : "Carousel"} ad: upload the ${cr.format === "video" ? "video" : "cards"} and create it in Ads Manager (text is in the plan)`
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

export function formParams(w: BuildWork, f: any, minimal = false): Record<string, string> {
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
    if (f.thank_you?.title) out.thank_you_page = J({ title: String(f.thank_you.title).slice(0, 60), body: String(f.thank_you.body || "").slice(0, 300),
      button_type: "VIEW_WEBSITE", button_text: String(f.thank_you.button_text || "Visit website").slice(0, 30), website_url: site });
  }
  return out;
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
export interface Geo { countries: string[]; regions: { key: string }[]; cities: { key: string; radius?: number; distance_unit?: string }[] }

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

export function targeting(a: any, geo: Geo, interests: { id: string; name: string }[], aud?: Aud) {
  const au = a.audience ?? {};
  const geo_locations: Record<string, unknown> = {};
  if (geo.countries.length) geo_locations.countries = geo.countries;
  if (geo.regions.length) geo_locations.regions = geo.regions;
  if (geo.cities.length) geo_locations.cities = geo.cities;
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
  if (interests.length) t.flexible_spec = [{ interests: interests.slice(0, 25) }];
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

export function creativeParams(w: BuildWork, cr: any, formId: string): Record<string, string> {
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
export function geoQueries(a: any): { name: string; type: "country" | "region" | "city"; radius_km?: number }[] {
  return ((a.audience?.locations ?? []) as any[]).filter((l) => l?.name && ["country", "region", "city"].includes(l.type))
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
