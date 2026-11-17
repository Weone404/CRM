// ads-sync: the CRM's link to Google Ads and Meta.
// Called by pg_cron (header x-cron-token, see migration 077) or from CRM > ADS by a signed-in user.
// Body: {jobs: ["test", "sync", "execute"]}
//   test     Admin. Checks each platform's credentials and every added account; records the result.
//   sync     Viewer. Account details, campaigns and daily metrics for the last `sync_days`, then recommendations.
//   discover Admin. Lists every Google Ads / Meta ad account the saved keys can reach (for "Import existing accounts").
//   gcheck   Admin / agents. {ops: [{kind, payload}]} -> Google validate-only for each (nothing changes).
//   ideas    Admin / agents. {seeds: [...], geos: ["2356"]} -> Keyword Planner ideas (Basic access).
//   execute  Approver. Sends approved changes, reads each campaign back, records verified / failed / outcome_unknown.
//   convert  Approver / cron. Tells Google which ad clicks became CRM enquiries (only for people who allowed ad data sharing).
//   meta_page            Admin. Reads the Page's lead forms, checks the leadgen webhook subscription; {subscribe: true} adds it.
//   meta_leads           Approver / cron. Fetches Meta leads the webhook announced and files them: from an ad -> ADS intake;
//                        without an ad -> normal Leads; Lead Ads Testing Tool leads -> kept as 'test', never filed.
//   meta_leads_reconcile Approver / cron. Reads each active form's last 48 hours and adds any lead the webhook missed.
//   setup                Viewer. Which ADS functions are deployed in the current version (for the Setup checklist).
//   meta_history         Admin / cron. Meta Ads > Insights history (read-only): back-fills up to 37 months of ad-level
//                        numbers month by month (resumable), refreshes the last 30 days daily and the breakdowns weekly,
//                        then builds (and emails, when CRM email is set up) the previous month's summary.
//   meta_test_event      Admin. {test_event_code}: one CRM test event, visible in Events Manager > Test events.
//                        No code: Meta's CRM check - one ordinary event for Meta's newest Verification Lead (a test
//                        lead, never a real one), which Events Manager > Test events > channel CRM waits for.
//   meta_convert         Approver / cron. Reports lead stages to Meta (Conversions API: CRM, website, WhatsApp), per source settings.
//   meta_build           Admin. {strategy_id}: Meta Ads > Strategy > Create in Meta - creates the approved plan in the ad account,
//                        everything PAUSED (lead forms, campaigns, ad sets, image ads). Resumable: each step is saved at once.
//   meta_image           Admin. {strategy_id, creative_key, image_base64, filename}: uploads a creative's picture (PNG / JPEG).
//   lead_alerts          Cron / approver. Speed-to-lead: phone notifications and emails for ad leads still waiting for a first call.
// Every job takes its own lock (svc_ads_run_begin), so overlapping runs skip instead of doubling up.
// Keys come from Vault through the service role and never leave this function (responses and logs are scrubbed).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asUser, cors, cronOk, json, HttpError, rpc } from "../_shared/ads_deno.ts";
import { AdsError, GoogleAds, MetaAds, dateRange, discover, executeOne, scrubSecrets, todayIn, verify, type Platforms, type WorkItem } from "../_shared/ads_core.ts";
import { buildOps, conversionRow, convertOutcome, executeGoogleOp, googleSnapshot, resultNames, type ConvItem, type GoogleOp } from "../_shared/ads_google_ops.ts";
import { ADS_BUILD, buildEvent, crmEvent, ctwaPayload, deployState, EventError, isTestLead, metaLeadPayload, organicPayload, serializeEvents, type CapiItem } from "../_shared/ads_meta.ts";
import { URL_ } from "../_shared/ads_deno.ts";
import { BREAKDOWNS, monthChunks, namesFromDays, parseAd, parseAdDay, parseAdset, parseBreakdown, parseCampaign, monthsBack, type DayRow } from "../_shared/meta_history.ts";
import { findPatterns, reportText } from "../_shared/meta_patterns.ts";
import { smtpSend } from "../_shared/smtp.ts";
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { alertText, type DueAlert } from "../_shared/lead_alerts.ts";
import { adParams, adsetParams, bestMatch, campaignParams, countryCode, creativeParams, formParams, geoQueries, imageKind, MAX_IMAGE_B64,
  planSteps, targeting, type BuildWork, type Geo } from "../_shared/meta_build.ts";

const DEADLINE_MS = 120_000;

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function platforms(s: Record<string, string>): { p: Platforms; missing: Record<string, string[]> } {
  const missing: Record<string, string[]> = { google: [], meta: [] };
  for (const k of ["GOOGLE_ADS_CLIENT_ID", "GOOGLE_ADS_CLIENT_SECRET", "GOOGLE_ADS_REFRESH_TOKEN"]) if (!s[k]) missing.google.push(k);
  if (!s.META_ACCESS_TOKEN) missing.meta.push("META_ACCESS_TOKEN");
  const p: Platforms = {};
  if (!missing.google.length) p.google = new GoogleAds({ clientId: s.GOOGLE_ADS_CLIENT_ID,
    clientSecret: s.GOOGLE_ADS_CLIENT_SECRET, refreshToken: s.GOOGLE_ADS_REFRESH_TOKEN, loginCustomerId: s.GOOGLE_ADS_LOGIN_CUSTOMER_ID,
    version: s.GOOGLE_API_VERSION }, fetch);
  if (!missing.meta.length) p.meta = new MetaAds({ accessToken: s.META_ACCESS_TOKEN, appSecret: s.META_APP_SECRET, version: s.META_API_VERSION, hmac: hmacHex }, fetch);
  return { p, missing };
}

async function runJob(name: string, secrets: Record<string, string>, fn: () => Promise<{ items: number; detail?: string; status?: "ok" | "error" }>) {
  const run = await rpc("svc_ads_run_begin", { p_job: name, p_seconds: 600 });
  if (run === null) return { job: name, status: "skipped" };
  try {
    const r = await fn();
    const st = r.status ?? "ok";
    await rpc("svc_ads_run_end", { p_run: run, p_job: name, p_status: st, p_items: r.items, p_detail: r.detail ? scrubSecrets(r.detail, secrets) : null });
    return { job: name, status: st, items: r.items, detail: r.detail ? scrubSecrets(r.detail, secrets) : undefined };
  } catch (e) {
    const msg = scrubSecrets(e instanceof Error ? e.message : String(e), secrets).slice(0, 900);
    await rpc("svc_ads_run_end", { p_run: run, p_job: name, p_status: "error", p_items: 0, p_detail: msg });
    return { job: name, status: "error", detail: msg };
  }
}

type Acct = { id: string; platform: "google" | "meta"; external_id: string; login_customer_id?: string | null };

async function test(s: Record<string, string>) {
  const { p, missing } = platforms(s);
  const out: Record<string, unknown> = {};
  for (const plat of ["google", "meta"] as const) {
    out[plat] = await runJob(`test_${plat}`, s, async () => {
      if (missing[plat].length) return { items: 0, status: "error", detail: `Not configured: ${missing[plat].join(", ")}` };
      if (plat === "meta") await p.meta!.me();              // token works at all
      const accts = ((await rpc("svc_ads_accounts")) as Acct[]).filter((a) => a.platform === plat);
      if (plat === "google" && !accts.length) return { items: 0, status: "error", detail: "Add a Google Ads account (customer ID) first; the token is checked against it." };
      const problems: string[] = [];
      for (const a of accts) {
        try {
          const info = plat === "google" ? await p.google!.withLogin(a.login_customer_id).account(a.external_id) : await p.meta!.account(a.external_id);
          await rpc("svc_ads_account_status", { p_account: a.id, p_status: "connected", p_error: null, p_name: info.name, p_currency: info.currency, p_timezone: info.timezone });
        } catch (e) {
          const st = e instanceof AdsError ? e.status : "sync_failed";
          const m = scrubSecrets(e instanceof Error ? e.message : String(e), s);
          await rpc("svc_ads_account_status", { p_account: a.id, p_status: st, p_error: m });
          problems.push(`${a.external_id}: ${m}`);
        }
      }
      return problems.length
        ? { items: accts.length, status: "error", detail: problems.join(" | ") }
        : { items: accts.length, detail: accts.length ? `Connected. ${accts.length} account(s) reachable.` : "Connected. No accounts added yet." };
    });
  }
  return out;
}

async function sync(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  return runJob("sync", s, async () => {
    const accts = (await rpc("svc_ads_accounts")) as Acct[];
    const days = Math.min(90, Math.max(1, Number(s.SYNC_DAYS) || 30));
    let campaigns = 0, metrics = 0;
    const problems: string[] = [];
    for (const a of accts) {
      if (Date.now() - t0 > DEADLINE_MS) { problems.push("time limit reached; remaining accounts next run"); break; }
      try {
        const api = a.platform === "google" ? p.google : p.meta;
        if (!api) throw new AdsError("auth_required", `${a.platform === "google" ? "Google Ads" : "Meta"} keys are not set in ADS > Settings`);
        const g = p.google?.withLogin(a.login_customer_id);
        const info = a.platform === "google" ? await g!.account(a.external_id) : await p.meta!.account(a.external_id);
        const { since, until } = dateRange(days, todayIn(info.timezone ?? "Asia/Kolkata"));
        const camps = a.platform === "google" ? await g!.campaigns(a.external_id) : await p.meta!.campaigns(a.external_id, info.currency);
        campaigns += await rpc("svc_ads_upsert_campaigns", { p_account: a.id, p_items: camps });
        const mets = a.platform === "google" ? await g!.metrics(a.external_id, since, until) : await p.meta!.metrics(a.external_id, since, until);
        metrics += await rpc("svc_ads_upsert_metrics", { p_account: a.id, p_items: mets });
        if (a.platform === "google") {                    // account structure for the ADS agents (Google only)
          const snap = await googleSnapshot(p.google!, a.external_id, a.login_customer_id);
          for (const [kind, data] of Object.entries(snap)) await rpc("svc_ads_google_snapshot_save", { p_account: a.id, p_kind: kind, p_data: data });
        }
        await rpc("svc_ads_account_status", { p_account: a.id, p_status: "connected", p_error: null, p_name: info.name, p_currency: info.currency, p_timezone: info.timezone });
      } catch (e) {
        const st = e instanceof AdsError ? e.status : "sync_failed";
        const m = scrubSecrets(e instanceof Error ? e.message : String(e), s);
        await rpc("svc_ads_account_status", { p_account: a.id, p_status: st, p_error: m });
        problems.push(`${a.platform} ${a.external_id}: ${m}`);
      }
    }
    const recs = await rpc("svc_ads_recommend");
    const detail = `${accts.length} account(s), ${campaigns} campaign(s), ${metrics} day-rows, ${recs} new recommendation(s)` +
      (problems.length ? `. Problems: ${problems.join(" | ")}` : "");
    return { items: metrics, detail, status: problems.length ? "error" : "ok" };
  });
}

async function execute(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  const currencies = new Map<string, string | null>();
  if (p.meta) p.metaCurrency = (id) => currencies.get(id) ?? null;
  return runJob("execute", s, async () => {
    if (s.EXECUTION_PAUSED === "true") return { items: 0, detail: "Emergency stop is on; nothing sent." };
    const stopped = (pl: string) => (pl === "google" ? s.GOOGLE_PAUSED : s.META_PAUSED) === "true";   // one platform stopped
    const meta = ((await rpc("svc_ads_accounts")) as Acct[]).filter((a) => a.platform === "meta");
    for (const a of meta) if (p.meta) { try { currencies.set(a.external_id, (await p.meta.account(a.external_id)).currency); } catch { /* resolved per change */ } }
    let n = 0;
    // 1. Re-check changes whose outcome was unknown (never re-sent: only read back)
    for (const w of (await rpc("svc_ads_unknown")) as WorkItem[]) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      const r = await verify(p, w);
      await rpc("svc_ads_finish", { p_id: w.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null, p_verify: r.verify ?? null });
      n++;
    }
    // 2. Approved changes
    for (const w of (await rpc("svc_ads_work")) as WorkItem[]) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      if (stopped(w.platform)) continue;                 // stays approved; sent when that platform is resumed
      if (!(await rpc("svc_ads_claim", { p_id: w.id }))) continue;
      const r = await executeOne(p, w);
      await rpc("svc_ads_finish", { p_id: w.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null, p_verify: r.verify ?? null });
      n++;
    }
    // 3. Google operations (keywords, negatives, ads, locations, assets, goals). Interrupted ones are never re-sent.
    for (const o of (await rpc("svc_ads_google_op_work")) as GoogleOp[]) {
      if (Date.now() - t0 > DEADLINE_MS || stopped("google")) break;
      if (o.status === "executing") {
        await rpc("svc_ads_google_op_finish", { p_id: o.id, p_status: "outcome_unknown", p_error: "Interrupted while sending; check it in Google Ads.", p_result: null, p_verify: null });
        continue;
      }
      if (!p.google) break;
      if (!(await rpc("svc_ads_google_op_claim", { p_id: o.id }))) continue;
      const r = await executeGoogleOp(p.google, o);
      await rpc("svc_ads_google_op_finish", { p_id: o.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null,
        p_result: r.result ?? null, p_verify: r.verify ?? null });
      n++;
    }
    return { items: n, detail: `${n} change(s) processed` };
  });
}

// The CRM reports its own enquiries to Google, so Google learns which clicks work even though the website has no Google tag.
async function convert(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  return runJob("convert", s, async () => {
    if (s.EXECUTION_PAUSED === "true") return { items: 0, detail: "Emergency stop is on; nothing sent." };
    if (s.GOOGLE_PAUSED === "true") return { items: 0, detail: "Google Ads is stopped; nothing sent." };
    if (!p.google) return { items: 0, status: "error", detail: "Google Ads keys are not set in ADS > Settings" };
    const w = await rpc("svc_ads_conversions_work") as { account: { external_id: string; login_customer_id?: string | null } | null;
      actions: Record<string, string>; missing: { event: string; name: string; category: string; primary: boolean }[]; items: ConvItem[] };
    if (!w?.account) return { items: 0, detail: "No Google Ads account" };
    const g = p.google.withLogin(w.account.login_customer_id), cid = w.account.external_id;
    const actions: Record<string, string> = { ...(w.actions ?? {}) };
    for (const m of w.missing ?? []) {                    // the conversion actions the CRM reports to (made once)
      const found = await g.search(cid, `SELECT conversion_action.id FROM conversion_action WHERE conversion_action.name = '${m.name.replace(/'/g, "")}' ` +
        "AND conversion_action.status != 'REMOVED'");
      let id = found[0]?.conversionAction?.id ? String(found[0].conversionAction.id) : "";
      if (!id) {
        const r = await g.mutate(cid, [{ conversionActionOperation: { create: { name: m.name, type: "UPLOAD_CLICKS", category: m.category, status: "ENABLED",
          countingType: "ONE_PER_CLICK", primaryForGoal: m.primary, clickThroughLookbackWindowDays: 90 } } }]);
        id = resultNames(r)[0]?.split("/").pop() ?? "";
      }
      if (/^\d+$/.test(id)) { await rpc("svc_ads_conversion_action_save", { p_event: m.event, p_id: id }); actions[m.event] = id; }
    }
    let sent = 0, later = 0, failed = 0;
    for (const it of w.items ?? []) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      const row = conversionRow(cid, actions[it.event], it);
      if (!row) continue;
      let out: { status: "sent" | "retry" | "failed"; error?: string };
      try { out = convertOutcome(await g.uploadClickConversion(cid, row)); }
      catch (e) { out = { status: "retry", error: (e as Error).message }; }
      await rpc("svc_ads_conversion_finish", { p_id: it.id, p_status: out.status, p_error: out.error ? scrubSecrets(out.error, s).slice(0, 400) : null });
      if (out.status === "sent") sent++; else if (out.status === "retry") later++; else failed++;
    }
    return { items: sent, detail: `${sent} reported to Google, ${later} to try again later, ${failed} not accepted`, status: failed ? "error" : "ok" };
  });
}

// ------------------------------------------------------------------ Meta lead ads (migration 100)
// The Page token: the saved long-lived Page token if there is one, else read with the System User token.
async function pageApi(s: Record<string, string>, pageId: string): Promise<MetaAds> {
  const { p } = platforms(s);
  if (!p.meta) throw new AdsError("auth_required", "Meta access token is not set in ADS > Settings");
  return p.meta.withToken(s.META_PAGE_TOKEN || await p.meta.pageToken(pageId));
}

async function metaPage(s: Record<string, string>, subscribe: boolean) {
  return runJob("meta_page", s, async () => {
    const pageId = (await rpc("svc_ads_meta_reconcile_work") as { page_id: string | null }).page_id;
    if (!pageId) return { items: 0, status: "error", detail: "Add the Facebook Page ID first." };
    const api = await pageApi(s, pageId);
    const forms = await api.leadgenForms(pageId);
    const n = await rpc("svc_ads_meta_forms_save", { p_forms: forms });
    let subs = (await api.subscribedApps(pageId)).some((a) => a.subscribed_fields.includes("leadgen"));
    if (!subs && subscribe) { await api.subscribeLeadgen(pageId); subs = (await api.subscribedApps(pageId)).some((a) => a.subscribed_fields.includes("leadgen")); }
    return { items: n, status: subs ? "ok" : "error",
      detail: `${n} lead form(s) found. ${subs ? "The Page sends new leads to the CRM (leadgen subscribed)." : "The Page is NOT subscribed to leadgen yet: press Connect Page."}` };
  });
}

async function metaLeads(s: Record<string, string>, t0: number) {
  return runJob("meta_leads", s, async () => {
    const w = await rpc("svc_ads_meta_leads_work") as { page_id: string | null; consent_field: string | null; consent_purpose?: string;
      items: { id: number; source: "instant_form" | "ctwa"; external_id: string; ad_id: string | null; created_time: string | null; payload: any; pipeline: string }[] };
    if (!w.items?.length) return { items: 0, detail: "No Meta lead waiting." };
    const purpose = (w.consent_purpose === "marketing" ? "marketing" : "ad_data_sharing") as "ad_data_sharing" | "marketing";
    let api: MetaAds | null = null, filed = 0, organic = 0, tests = 0, later = 0;
    for (const it of w.items) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      try {
        if (it.source === "ctwa") {
          const r = await rpc("svc_ads_meta_lead_finish", { p_id: it.id, p_status: "fetched", p_payload: ctwaPayload(it), p_pipeline: it.pipeline });
          if ((r as any)?.lead_id) filed++;
          continue;
        }
        if (!w.page_id && !s.META_PAGE_TOKEN) throw new AdsError("sync_failed", "Add the Facebook Page ID in ADS > Settings > Meta");
        api ??= await pageApi(s, w.page_id ?? "");
        const lead = await api.getLead(it.external_id);
        if (isTestLead(lead)) {                      // Lead Ads Testing Tool: proves the path, never filed
          await rpc("svc_ads_meta_lead_finish", { p_id: it.id, p_status: "test" }); tests++; continue;
        }
        if (lead.is_organic === true || lead.is_organic === "1" || !lead.ad_id) {
          // filled without an ad: a normal lead in Leads (migration 101), not an Ads lead
          await rpc("svc_ads_meta_lead_finish", { p_id: it.id, p_status: "organic", p_payload: organicPayload(lead), p_pipeline: it.pipeline });
          organic++; continue;
        }
        const r = await rpc("svc_ads_meta_lead_finish", { p_id: it.id, p_status: "fetched",
          p_payload: metaLeadPayload(lead, { consentField: w.consent_field, consentPurpose: purpose }), p_pipeline: it.pipeline });
        if ((r as any)?.lead_id) filed++;
      } catch (e) {
        const msg = scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 400);
        await rpc("svc_ads_meta_lead_finish", { p_id: it.id, p_status: "retry", p_error: msg });
        later++;
        if (e instanceof AdsError && (e.status === "rate_limited" || e.status === "auth_required")) break;   // stop: the rest waits
      }
    }
    return { items: filed, detail: `${filed} Ads lead(s) filed, ${organic} without an ad (to Leads), ${tests} test lead(s), ${later} to try again`, status: later ? "error" : "ok" };
  });
}

async function metaReconcile(s: Record<string, string>, t0: number) {
  return runJob("meta_leads_reconcile", s, async () => {
    const w = await rpc("svc_ads_meta_reconcile_work") as { page_id: string | null; enabled: boolean; forms: { form_id: string; since: number }[] };
    if (!w.enabled) return { items: 0, detail: "Meta lead forms are switched off." };
    if (!w.page_id) return { items: 0, status: "error", detail: "Add the Facebook Page ID first." };
    const api = await pageApi(s, w.page_id);
    let added = 0;
    for (const f of w.forms ?? []) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      const rows = await api.formLeads(f.form_id, f.since);
      added += Number(await rpc("svc_ads_meta_raw_add", { p_items: rows.map((r) => ({ source: "instant_form", external_id: String(r.id),
        form_id: f.form_id, ad_id: r.ad_id ?? null, adgroup_id: r.adset_id ?? null, created_time: r.created_time ?? null })), p_via: "reconcile" })) || 0;
      await rpc("svc_ads_meta_reconciled", { p_form: f.form_id });
    }
    return { items: added, detail: `${(w.forms ?? []).length} form(s) checked, ${added} lead(s) the webhook had missed` };
  });
}

// One request per batch; a batch Meta refuses is retried one event at a time so one bad event cannot block the rest.
async function metaConvert(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  return runJob("meta_convert", s, async () => {
    if (s.EXECUTION_PAUSED === "true" || s.META_PAUSED === "true") return { items: 0, detail: "Meta Ads is stopped; nothing sent." };
    if (!p.meta) return { items: 0, status: "error", detail: "Meta access token is not set in Meta Ads > Settings" };
    const w = await rpc("svc_ads_meta_capi_work") as { paused?: boolean; crm_name: string; datasets: Record<string, string>; items: CapiItem[] };
    if (w.paused) return { items: 0, detail: "Emergency stop is on; nothing sent." };
    let sent = 0, later = 0, failed = 0, stop = false;
    const finish = async (id: number, st: "sent" | "retry" | "failed", err?: string) => {
      await rpc("svc_ads_meta_capi_finish", { p_id: id, p_status: st, p_error: err ? scrubSecrets(err, s).slice(0, 400) : null });
      if (st === "sent") sent++; else if (st === "retry") later++; else failed++;
    };
    const send = async (dataset: string, batch: { it: CapiItem; ev: Record<string, unknown> }[]): Promise<void> => {
      try {
        const r = await p.meta!.sendEvents(dataset, serializeEvents(batch.map((b) => b.ev)));
        if (r.events_received === batch.length) { for (const b of batch) await finish(b.it.id, "sent"); return; }
        for (const b of batch) await finish(b.it.id, "retry", `Meta received ${r.events_received ?? 0} of ${batch.length}`);
      } catch (e) {
        const ae = e instanceof AdsError ? e : null;
        if (ae && (ae.status === "rate_limited" || ae.status === "auth_required" || ae.status === "permission_missing" || ae.status === "unavailable" || ae.http === 0)) {
          for (const b of batch) await finish(b.it.id, "retry", ae.message);
          stop = ae.status === "rate_limited" || ae.status === "auth_required";
          return;
        }
        if (batch.length > 1) { for (const b of batch) { if (stop) break; await send(dataset, [b]); } return; }
        await finish(batch[0].it.id, "failed", e instanceof Error ? e.message : String(e));   // Meta refused this event
      }
    };
    const bySource = new Map<string, { it: CapiItem; ev: Record<string, unknown> }[]>();
    for (const it of w.items ?? []) {
      try { const ev = buildEvent(it, w.crm_name); bySource.set(it.source, [...(bySource.get(it.source) ?? []), { it, ev }]); }
      catch (e) { await finish(it.id, "failed", e instanceof EventError ? e.message : String(e)); }
    }
    for (const [source, list] of bySource) {
      const dataset = w.datasets?.[source];
      if (!dataset) { for (const b of list) await finish(b.it.id, "retry", "No dataset ID for this source"); continue; }
      for (let i = 0; i < list.length && !stop; i += 50) {
        if (Date.now() - t0 > DEADLINE_MS) { stop = true; break; }
        await send(dataset, list.slice(i, i + 50));
      }
    }
    return { items: sent, detail: `${sent} reported to Meta, ${later} to try again later, ${failed} not accepted`, status: failed ? "error" : "ok" };
  });
}

// Which ADS functions are deployed, and in which version. Checked from here (server to server), not from the browser.
async function setupCheck() {
  const probe = async (path: string, want?: string) => {
    try {
      const r = await fetch(`${URL_}/functions/v1/${path}`, { method: "GET", signal: AbortSignal.timeout(8000) });
      return deployState(r.status, (await r.text()).slice(0, 500), want);
    } catch { return "unknown" as const; }
  };
  return { build: ADS_BUILD, functions: { "ads-sync": "current", "ads-intake": await probe("ads-intake/version", ADS_BUILD),
    "ads-meta-webhook": await probe("ads-meta-webhook"), "ads-agents": await probe("ads-agents/version", ADS_BUILD) } };
}

// ---------------------------------------------------------------- Meta Ads > Insights history (read-only)
type HistPlan = { accounts: { id: string; external_id: string; timezone: string | null; currency: string | null }[];
  months: number; start: string; cursor: string; done: boolean; recent_due: boolean; breakdowns_due: boolean; report_month: string | null };
async function saveDays(accountId: string, raw: any[]) {
  const days = raw.map(parseAdDay).filter((x): x is DayRow => x !== null);
  for (let i = 0; i < days.length; i += 1000) await rpc("svc_ads_meta_ad_days_save", { p_account: accountId, p_items: days.slice(i, i + 1000) });
  const names = namesFromDays(raw);
  for (let i = 0; i < names.length; i += 1000) await rpc("svc_ads_meta_objects_save", { p_account: accountId, p_items: names.slice(i, i + 1000) });
  return days.length;
}
async function metaHistory(s: Record<string, string>, t0: number) {
  const { p } = platforms(s);
  return runJob("meta_history", s, async () => {
    if (!p.meta) return { items: 0, status: "error", detail: "Meta access token is not set" };
    const plan = await rpc("svc_ads_meta_history_plan") as HistPlan;
    if (!plan.accounts.length) return { items: 0, detail: "No connected Meta ad account." };
    const time = () => Date.now() - t0 < DEADLINE_MS - 15_000;
    let rows = 0, cursor = plan.cursor, done = plan.done;
    const did: string[] = [], problems: string[] = [];
    for (const a of plan.accounts) {
      const today = todayIn(a.timezone ?? "Asia/Kolkata");
      try {
        // 1. structure: campaigns, ad sets (targeting) and ads (creative) - daily, and before the first back-fill
        if (plan.recent_due && time()) {
          // each level on its own: a refusal for one never stops the numbers (names also arrive with them)
          let n = 0;
          for (const [what, get, parse] of [["campaigns", () => p.meta!.historyCampaigns(a.external_id), parseCampaign],
              ["ad sets", () => p.meta!.historyAdsets(a.external_id), parseAdset], ["ads", () => p.meta!.historyAds(a.external_id), parseAd]] as const) {
            try {
              const objs = (await get()).map(parse as (r: any) => unknown);
              for (let i = 0; i < objs.length; i += 500) await rpc("svc_ads_meta_objects_save", { p_account: a.id, p_items: objs.slice(i, i + 500) });
              n += objs.length;
            } catch (e) { problems.push(`${what}: ${scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 160)}`); }
          }
          did.push(`${n} campaigns/ad sets/ads`);
        }
        // 2. back-fill month by month from the cursor (resumes next hour if time runs out)
        if (!done) {
          let months = 0;
          for (const ch of monthChunks(cursor < plan.start ? plan.start : cursor, today)) {
            if (!time()) break;
            rows += await saveDays(a.id, await p.meta.adDays(a.external_id, ch.since, ch.until));
            cursor = ch.next; months++;
            await rpc("svc_ads_meta_history_mark", { p: { cursor } });
          }
          if (cursor > today) { done = true; await rpc("svc_ads_meta_history_mark", { p: { done: true } }); }
          did.push(done ? `history complete (${months} month(s) this run)` : `${months} month(s) of history, continues next hour`);
        }
        // 3. once complete: the last 30 days daily (Meta adjusts recent numbers for a few days)
        if (done && plan.recent_due && time()) {
          rows += await saveDays(a.id, await p.meta.adDays(a.external_id, dateRange(30, today).since, today));
          await rpc("svc_ads_meta_history_mark", { p: { recent: true } });
          did.push("last 30 days refreshed");
        }
        // 4. breakdowns weekly: 13 months (6 for frequency), whole account
        if (plan.breakdowns_due && time()) {
          let kinds = 0;
          for (const b of BREAKDOWNS) {
            if (!time()) break;
            const since = monthsBack(today, b.months);
            try {
              const items = (await p.meta.breakdown(a.external_id, b.breakdowns, since, today)).map((r) => parseBreakdown(b.kind, r)).filter(Boolean);
              await rpc("svc_ads_meta_breakdowns_save", { p_account: a.id, p_kind: b.kind, p_from: since, p_items: items });
              kinds++;
            } catch (e) { problems.push(`${b.kind}: ${scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 160)}`); }
          }
          if (kinds) await rpc("svc_ads_meta_history_mark", { p: { breakdowns: true } });
          did.push(`${kinds} breakdown(s)`);
        }
      } catch (e) {
        problems.push(`${a.external_id}: ${scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 200)}`);
      }
    }
    // 5. last month's summary, once the history is complete
    if (plan.report_month && done && time()) {
      const data = await rpc("svc_ads_meta_report_data", { p_month: plan.report_month });
      const pats = findPatterns(data).patterns;
      let emailed = false, err: string | null = null;
      const mc = await rpc("svc_ads_meta_mail_config") as { ready: boolean; smtp?: any; password?: string; to?: string[] };
      if (mc.ready && mc.to?.length) {
        try {
          const m = reportText(plan.report_month, data, pats);
          await smtpSend({ host: mc.smtp.host, port: Number(mc.smtp.port) || 465, username: mc.smtp.username, password: mc.password!,
            fromName: mc.smtp.from_name ?? "We One CRM" }, { to: mc.to, subject: m.subject, text: m.text, html: m.html });
          emailed = true;
        } catch (e) { err = e instanceof Error ? e.message : String(e); }
      } else err = mc.ready ? "No recipients set (Meta Ads > Insights > Monthly summaries)" : "CRM email is not set up";
      await rpc("svc_ads_meta_report_save", { p_month: plan.report_month, p_data: data, p_patterns: pats, p_emailed: emailed, p_error: err });
      did.push(`summary for ${plan.report_month.slice(0, 7)} saved${emailed ? " and emailed" : ""}`);
    }
    return { items: rows, status: problems.length ? "error" : "ok",
      detail: `${rows} ad-day rows. ${did.join("; ") || "Nothing due"}${problems.length ? `. Problems: ${problems.join(" | ")}` : ""}` };
  });
}

// Meta's CRM check: Events Manager > Test events > channel CRM shows a Verification Lead and waits for an ordinary event
// for that lead id (Meta gives no test code there). Only a lead kept as 'test' (Testing Tool / Verification Lead) is
// ever used, so no real lead is reported by this.
async function metaVerificationEvent(s: Record<string, string>, meta: MetaAds | undefined): Promise<{ items: number; detail?: string; status?: "ok" | "error" }> {
  if (s.EXECUTION_PAUSED === "true" || s.META_PAUSED === "true") return { items: 0, status: "error", detail: "Meta Ads is stopped; resume it in Settings first." };
  if (!meta) return { items: 0, status: "error", detail: "Meta access token is not set" };
  const v = await rpc("svc_ads_meta_verification_lead") as { lead_id: string; dataset_id: string | null; crm_name: string; event_name: string } | null;
  if (!v?.lead_id) return { items: 0, status: "error", detail: "No Meta Verification Lead in the CRM yet: in Events Manager > Test events pick channel CRM, wait until step 8 shows a new test lead, then press again." };
  if (!v.dataset_id) return { items: 0, status: "error", detail: "Add the dataset ID first (step before)." };
  const ev = crmEvent({ id: 0, source: "instant_form", event_name: v.event_name, event_id: `verify:${v.lead_id}`,
    event_time: Math.floor(Date.now() / 1000) - 5, lead_id: v.lead_id }, v.crm_name);
  const r = await meta.sendEvents(v.dataset_id, serializeEvents([ev]));
  return r.events_received === 1
    ? { items: 1, detail: `Meta received the event for its Verification Lead ${v.lead_id}. Events Manager > Test events (channel CRM) shows it within a minute.` }
    : { items: 0, status: "error", detail: `Meta received ${r.events_received ?? 0} events` };
}

// One CRM test event for the newest Meta form lead, sent with Meta's test_event_code: it shows in Events Manager >
// Test events and is not used for optimisation.
async function metaTestEvent(s: Record<string, string>, code: string) {
  const { p } = platforms(s);
  return runJob("meta_test_event", s, async () => {
    if (!code) return await metaVerificationEvent(s, p.meta);
    if (!/^TEST[0-9A-Za-z]{2,30}$/.test(code)) return { items: 0, status: "error", detail: "Paste the test code from Events Manager > Test events (it starts with TEST)." };
    if (!p.meta) return { items: 0, status: "error", detail: "Meta access token is not set" };
    const t = await rpc("svc_ads_meta_test_lead") as { lead_id: string; em: string | null; ph: string | null; dataset_id: string | null; crm_name: string } | null;
    if (!t?.lead_id) return { items: 0, status: "error", detail: "No Meta form lead yet: send a test lead first (step before)." };
    if (!t.dataset_id) return { items: 0, status: "error", detail: "Add the dataset ID for Meta lead forms first." };
    const ev = crmEvent({ id: 0, source: "instant_form", event_name: "lead_created", event_id: `test:${Date.now()}`,
      event_time: Math.floor(Date.now() / 1000) - 60, lead_id: t.lead_id, em: t.em, ph: t.ph }, t.crm_name);
    const r = await p.meta.sendTestEvents(t.dataset_id, serializeEvents([ev]), code);
    return r.events_received === 1 ? { items: 1, detail: "Meta received the test event. Open Events Manager > Test events to see it." }
      : { items: 0, status: "error", detail: `Meta received ${r.events_received ?? 0} events` };
  });
}

// ------------------------------------------------------------------ Meta Ads > Strategy > Create in Meta (migration 104)
async function metaBuild(s: Record<string, string>, strategyId: number, t0: number) {
  return runJob("meta_build", s, async () => {
    if (!Number.isInteger(strategyId) || strategyId <= 0) return { items: 0, status: "error", detail: "strategy_id is required" };
    const { p } = platforms(s);
    if (!p.meta) return { items: 0, status: "error", detail: "Meta access token is not set" };
    const w = await rpc("svc_ads_meta_build_work", { p_id: strategyId }) as BuildWork | null;
    if (!w) return { items: 0, status: "error", detail: "Nothing to create: approve the plan and press Create in Meta first." };
    if (!w.goal?.privacy_url && (w.plan?.forms ?? []).some((f: any) => !w.steps[`form:${f.key}`]?.id)) {
      await rpc("svc_ads_meta_build_end", { p_id: strategyId, p_status: "error", p_detail: "Add the privacy policy link to the goal (Meta requires it on lead forms)." });
      return { items: 0, status: "error", detail: "privacy policy link missing" };
    }
    const meta = p.meta, act = `act_${w.account_id}`;
    let page: MetaAds | null = null;
    const steps = planSteps(w);
    const ids: Record<string, string> = Object.fromEntries(Object.entries(w.steps ?? {}).filter(([, v]) => v?.id).map(([k, v]) => [k, String(v.id)]));
    const today = todayIn("Asia/Kolkata");
    const P = w.plan;
    const find = (kind: string, key: string) => kind === "form" ? P.forms.find((f: any) => f.key === key)
      : kind === "campaign" ? P.campaigns.find((c: any) => c.key === key)
      : kind === "adset" ? P.campaigns.flatMap((c: any) => (c.adsets ?? []).map((a: any) => ({ ...a, _c: c }))).find((a: any) => a.key === key)
      : P.creatives.find((c: any) => c.key === key);
    const save = (key: string, step: Record<string, unknown>) => rpc("svc_ads_meta_build_step", { p_id: strategyId, p_key: key, p_step: step });
    let made = 0, waiting = 0, failed = 0, manual = 0, stopped = false;
    for (const st of steps) {
      if (ids[st.key]) continue;
      if (Date.now() - t0 > DEADLINE_MS - 15_000) { stopped = true; break; }
      if (st.skip) { manual++; await save(st.key, { status: "manual", note: st.skip }); continue; }
      const missing = st.needs.filter((k) => !ids[k]);
      if (missing.length) { waiting++; await save(st.key, { status: "waiting", note: `Needs ${missing.join(", ")} first` }); continue; }
      const [kind, k1, k2] = st.key.split(":");
      let note: string | undefined;
      try {
        let id: string;
        if (kind === "form") {
          page ??= await pageApi(s, w.page_id);
          const f = find("form", k1);
          try { id = await page.create(`${w.page_id}/leadgen_forms`, formParams(w, f)); }
          catch (e) {   // the intro / thank-you screens are extras: retry without them rather than fail the form
            if (e instanceof AdsError && (e.status === "auth_required" || e.status === "rate_limited")) throw e;
            id = await page.create(`${w.page_id}/leadgen_forms`, formParams(w, f, true));
          }
        } else if (kind === "campaign") {
          id = await meta.create(`${act}/campaigns`, campaignParams(w, find("campaign", k1)));
        } else if (kind === "adset") {
          const a = find("adset", k1);
          const geo: Geo = { countries: [], regions: [], cities: [] };
          const notFound: string[] = [];
          for (const q of geoQueries(a)) {
            if (q.type === "country" && countryCode(q.name)) { geo.countries.push(countryCode(q.name)!); continue; }
            const hit = bestMatch(await meta.search({ type: "adgeolocation", q: q.name, location_types: JSON.stringify([q.type]) }), q.name) as any;
            if (!hit?.key) { notFound.push(q.name); continue; }
            if (q.type === "country") geo.countries.push(String(hit.country_code ?? hit.key));
            else if (q.type === "region") geo.regions.push({ key: String(hit.key) });
            else geo.cities.push({ key: String(hit.key), ...(q.radius_km ? { radius: q.radius_km, distance_unit: "kilometer" } : {}) });
          }
          if (!geo.countries.length && !geo.regions.length && !geo.cities.length) throw new AdsError("sync_failed", `Meta did not find the locations: ${notFound.join(", ")}`);
          const interests: { id: string; name: string }[] = [];
          for (const name of (a.audience?.interests ?? []).slice(0, 15)) {
            const hit = bestMatch(await meta.search({ type: "adinterest", q: String(name) }), String(name)) as any;
            if (hit?.id) interests.push({ id: String(hit.id), name: String(hit.name) });
          }
          id = await meta.create(`${act}/adsets`, adsetParams(w, a._c, a, ids[`campaign:${a._c.key}`], targeting(a, geo, interests), today));
          if (notFound.length) note = `Not found by Meta, left out: ${notFound.join(", ")}`;
        } else if (kind === "creative") {
          id = await meta.create(`${act}/adcreatives`, creativeParams(w, find("creative", k1), ids[`form:${k2}`]));
        } else {
          const cr = find("creative", k2);
          id = await meta.create(`${act}/ads`, adParams(w, cr?.name ?? k2, ids[`adset:${k1}`], ids[`creative:${k2}:${find("adset", k1).form}`]));
        }
        await save(st.key, { id, status: "done", ...(note ? { note } : {}) });
        ids[st.key] = id; made++;
      } catch (e) {
        failed++;
        const msg = scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 400);
        await save(st.key, { status: "error", error: msg });
        if (e instanceof AdsError && (e.status === "auth_required" || e.status === "rate_limited" || e.status === "permission_missing")) { stopped = true; break; }
      }
    }
    const left = steps.filter((x) => !ids[x.key]).length;
    const status = left === 0 ? "done" : stopped || failed ? "error" : "partial";
    const detail = `${made} created now, ${Object.keys(ids).length} of ${steps.length} in Meta (all paused)`
      + (manual ? `, ${manual} to add in Ads Manager` : "") + (failed ? `, ${failed} failed` : "") + (waiting ? `, ${waiting} waiting on those` : "")
      + (stopped && !failed ? ", more to do: press Create in Meta again" : "");
    await rpc("svc_ads_meta_build_end", { p_id: strategyId, p_status: status, p_detail: detail });
    return { items: made, detail, status: failed ? "error" : "ok" };
  });
}

async function metaImage(s: Record<string, string>, strategyId: number, key: string, b64: string, filename: string) {
  if (!Number.isInteger(strategyId) || !/^[A-Za-z0-9_-]{1,40}$/.test(key)) throw new HttpError(422, "strategy_id and creative_key are required");
  const data = b64.replace(/^data:image\/[a-z]+;base64,/, "");
  if (!imageKind(data)) throw new HttpError(422, "Use a PNG or JPEG picture");
  if (data.length > MAX_IMAGE_B64) throw new HttpError(422, "The picture is over 8 MB");
  const { p } = platforms(s);
  if (!p.meta) throw new HttpError(409, "Meta access token is not set");
  const w = await rpc("svc_ads_meta_build_work_peek", { p_id: strategyId }) as { account_id: string } | null;
  if (!w?.account_id) throw new HttpError(409, "Connect the Meta ad account first");
  try {
    const hash = await p.meta.uploadImage(w.account_id, data, filename || `${key}.${imageKind(data) === "png" ? "png" : "jpg"}`);
    await rpc("svc_ads_meta_build_image", { p_id: strategyId, p_key: key, p_hash: hash, p_name: filename || key });
    return { ok: true, hash };
  } catch (e) {
    throw new HttpError(502, scrubSecrets(e instanceof Error ? e.message : String(e), s).slice(0, 300));
  }
}

// ------------------------------------------------------------------ speed-to-lead alerts (migration 104)
async function leadAlerts(s: Record<string, string>) {
  return runJob("lead_alerts", s, async () => {
    const c = await rpc("svc_ads_lead_alerts_claim") as { alerts: DueAlert[]; vapid_keys: string | null;
      mail: { ready: boolean; smtp?: any; password?: string } };
    if (!c?.alerts?.length) return { items: 0, detail: "No lead waiting." };
    let server: webpush.ApplicationServer | null = null;
    if (c.vapid_keys && c.alerts.some((a) => a.subs.length)) {
      try {
        const vapidKeys = await webpush.importVapidKeys(JSON.parse(c.vapid_keys), { extractable: false });
        server = await webpush.ApplicationServer.new({ contactInformation: "mailto:info@weoneaviation.in", vapidKeys });
      } catch (e) { console.error("lead_alerts push keys", String(e).slice(0, 200)); }
    }
    const results: { lead_id: string; level: number; sent: Record<string, unknown> }[] = [];
    let pushed = 0, emailed = 0;
    for (const a of c.alerts) {
      const m = alertText(a);
      const sent: Record<string, unknown> = { push: 0, email: 0 };
      if (server) for (const sub of a.subs) {
        try { await server.subscribe({ endpoint: sub.endpoint, keys: sub.keys }).pushTextMessage(JSON.stringify(m), { ttl: 3600, urgency: webpush.Urgency.High });
          sent.push = Number(sent.push) + 1; pushed++; }
        catch (e) { sent.push_error = String(e instanceof Error ? e.message : e).slice(0, 120); }
      }
      if (c.mail?.ready && a.emails.length) {
        try {
          await smtpSend({ host: c.mail.smtp.host, port: Number(c.mail.smtp.port) || 465, username: c.mail.smtp.username, password: c.mail.password!,
            fromName: c.mail.smtp.from_name ?? "We One CRM" }, { to: a.emails, subject: m.title, text: `${m.body}\n\nOpen the CRM: ${m.url}`,
            html: `<p>${m.body.replace(/[&<>]/g, (x) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[x]!))}</p><p><a href="${m.url}">Open the CRM</a></p>` });
          sent.email = a.emails.length; emailed++;
        } catch (e) { sent.email_error = String(e instanceof Error ? e.message : e).slice(0, 160); }
      }
      if (!a.subs.length && !(c.mail?.ready && a.emails.length)) sent.note = "No phone notifications or email set up for the people to alert";
      results.push({ lead_id: a.lead_id, level: a.level, sent });
    }
    await rpc("svc_ads_lead_alerts_done", { p_results: results });
    return { items: c.alerts.length, detail: `${c.alerts.length} alert(s): ${pushed} phone notification(s), ${emailed} email(s)` };
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now();
  try {
    let body: { jobs?: string[]; ops?: { kind: string; payload: unknown }[]; seeds?: string[]; geos?: string[]; subscribe?: boolean; test_event_code?: string;
      strategy_id?: number; creative_key?: string; image_base64?: string; filename?: string } = {};
    try { body = await req.json(); } catch { /* empty body */ }
    const jobs = (body.jobs ?? ["sync"]).filter((j) => ["test", "discover", "sync", "execute", "gcheck", "ideas", "convert",
      "meta_page", "meta_leads", "meta_leads_reconcile", "meta_convert", "setup", "meta_test_event", "meta_history", "meta_build", "meta_image",
      "lead_alerts"].includes(j));
    if (!jobs.length) return json(req, 422, { detail: "jobs must include test, discover, sync or execute" });
    if (!(await cronOk(req))) {
      const access = await asUser(req, "api_ads_access") as { can_view: boolean; can_approve: boolean; is_admin: boolean };
      if (!access?.can_view) throw new HttpError(403, "You do not have access to the ADS section");
      if ((jobs.includes("test") || jobs.includes("discover") || jobs.includes("gcheck") || jobs.includes("ideas") || jobs.includes("meta_page") || jobs.includes("meta_test_event") || jobs.includes("meta_history")) && !access.is_admin) throw new HttpError(403, "Only Admin can test connections or find accounts");
      if ((jobs.includes("meta_build") || jobs.includes("meta_image")) && !access.is_admin) throw new HttpError(403, "Only Admin can create campaigns in Meta");
      if ((jobs.includes("execute") || jobs.includes("convert") || jobs.includes("lead_alerts") || jobs.some((j) => j.startsWith("meta_") && !["meta_page", "meta_test_event", "meta_history", "meta_build", "meta_image"].includes(j))) && !access.can_approve) throw new HttpError(403, "Only approvers can run changes");
    }
    if (jobs.length === 1 && jobs[0] === "setup") return json(req, 200, { results: { setup: await setupCheck() } });   // no keys needed
    const secrets = (await rpc("svc_ads_secrets")) as Record<string, string>;
    const results: Record<string, unknown> = {};
    if (jobs.includes("test")) results.test = await test(secrets);
    if (jobs.includes("discover")) {
      const found = await discover(platforms(secrets).p);
      for (const k of ["google", "meta"] as const) if (found[k].error) found[k].error = scrubSecrets(found[k].error!, secrets);
      results.discover = { ...found, known: await rpc("svc_ads_known_accounts") };
    }
    if (jobs.includes("gcheck") || jobs.includes("ideas")) {
      const { p } = platforms(secrets);
      const acct = ((await rpc("svc_ads_accounts")) as Acct[]).find((a) => a.platform === "google");
      if (!p.google || !acct) throw new HttpError(409, "Google Ads is not connected");
      const g = p.google.withLogin(acct.login_customer_id);
      if (jobs.includes("gcheck")) {
        const out = [];
        for (const o of (body.ops ?? []).slice(0, 20)) {
          try { await g.mutate(acct.external_id, buildOps(acct.external_id, o.kind, o.payload).ops, true); out.push({ kind: o.kind, ok: true }); }
          catch (e) { out.push({ kind: o.kind, ok: false, error: scrubSecrets((e as Error).message, secrets).slice(0, 600) }); }
        }
        results.gcheck = out;
      }
      if (jobs.includes("ideas")) {
        try {
          const rows = await g.keywordIdeas(acct.external_id, (body.seeds ?? []).map(String), (body.geos ?? ["2356"]).map(String));
          results.ideas = rows.map((r: any) => ({ text: r.text, avg_monthly: Number(r.keywordIdeaMetrics?.avgMonthlySearches ?? 0) || null,
            competition: r.keywordIdeaMetrics?.competition ?? null, low_bid: Number(r.keywordIdeaMetrics?.lowTopOfPageBidMicros ?? 0) / 1e6 || null,
            high_bid: Number(r.keywordIdeaMetrics?.highTopOfPageBidMicros ?? 0) / 1e6 || null }));
        } catch (e) { results.ideas = { error: scrubSecrets((e as Error).message, secrets).slice(0, 600) }; }
      }
    }
    if (jobs.includes("sync")) results.sync = await sync(secrets, t0);
    if (jobs.includes("execute")) results.execute = await execute(secrets, t0);
    if (jobs.includes("convert")) results.convert = await convert(secrets, t0);
    if (jobs.includes("setup")) results.setup = await setupCheck();
    if (jobs.includes("meta_history")) results.meta_history = await metaHistory(secrets, t0);
    if (jobs.includes("meta_test_event")) results.meta_test_event = await metaTestEvent(secrets, String(body.test_event_code ?? "").trim());
    if (jobs.includes("meta_page")) results.meta_page = await metaPage(secrets, body.subscribe === true);
    if (jobs.includes("meta_leads_reconcile")) results.meta_leads_reconcile = await metaReconcile(secrets, t0);
    if (jobs.includes("meta_leads")) results.meta_leads = await metaLeads(secrets, t0);
    if (jobs.includes("meta_convert")) results.meta_convert = await metaConvert(secrets, t0);
    if (jobs.includes("meta_image")) results.meta_image = await metaImage(secrets, Number(body.strategy_id), String(body.creative_key ?? ""),
      String(body.image_base64 ?? ""), String(body.filename ?? "").replace(/[^\w. -]/g, "").slice(0, 100));
    if (jobs.includes("meta_build")) results.meta_build = await metaBuild(secrets, Number(body.strategy_id), t0);
    if (jobs.includes("lead_alerts")) results.lead_alerts = await leadAlerts(secrets);
    return json(req, 200, { results });
  } catch (e) {
    if (e instanceof HttpError) return json(req, e.status, { detail: e.message });
    console.error("ads-sync error", String(e).slice(0, 300));
    return json(req, 500, { detail: "Something went wrong" });
  }
});
