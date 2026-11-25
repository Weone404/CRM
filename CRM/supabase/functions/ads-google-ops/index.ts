// ADS > Google Ads: runs the owner-only operations of migrations 144-146 (campaign_create, income_filter, ad_schedule, budget_set).
// A small function of its own, so the large ads-sync function is not redeployed for them. Same rules as ads-sync's "execute":
// the gate is re-checked when an operation is claimed, Google's own pre-check runs first (nothing changes), the real request is
// sent once, and only a successful read-back counts as verified. Interrupted operations are never re-sent.
// Called by the crm-ads-google-build schedule (x-cron-token) only; no browser calls this.
// With {"check": "<operation id>"} it only asks Google to validate a waiting operation (nothing changes) and logs the answer.
// With {"read": "billing"} it only reads what Google reports about the account's money (the prepaid balance, migration 146).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cors, cronOk, json, rpc } from "../_shared/ads_deno.ts";
import { GoogleAds, scrubSecrets } from "../_shared/ads_core.ts";
import { dryRunGoogleOp, executeGoogleOp, readBilling, type GoogleOp } from "../_shared/ads_google_ops.ts";

const DEADLINE_MS = 110_000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  const t0 = Date.now();
  let s: Record<string, string> = {};
  try {
    if (!(await cronOk(req))) return json(req, 401, { detail: "Could not validate credentials" });
    s = (await rpc("svc_ads_secrets")) as Record<string, string>;
    if (s.EXECUTION_PAUSED === "true" || s.GOOGLE_PAUSED === "true") return json(req, 200, { done: 0, detail: "Stopped; nothing sent." });
    if (!s.GOOGLE_ADS_CLIENT_ID || !s.GOOGLE_ADS_CLIENT_SECRET || !s.GOOGLE_ADS_REFRESH_TOKEN) return json(req, 200, { done: 0, detail: "Google Ads is not connected." });
    const google = new GoogleAds({ clientId: s.GOOGLE_ADS_CLIENT_ID, clientSecret: s.GOOGLE_ADS_CLIENT_SECRET, refreshToken: s.GOOGLE_ADS_REFRESH_TOKEN,
      loginCustomerId: s.GOOGLE_ADS_LOGIN_CUSTOMER_ID, version: s.GOOGLE_API_VERSION }, fetch);
    // {"check": "<operation id>"}: Google's own dry run of a waiting operation. Nothing is sent for real and nothing changes.
    let body: { check?: string; read?: string } = {};
    try { body = await req.json(); } catch { /* empty body */ }
    // {"read": "billing"}: what Google says about the account's money (read only), saved for the Google Ads home screen.
    if (body.read === "billing") {
      const accs = (await rpc("svc_ads_accounts")) as { id: string; platform: string; external_id: string; status?: string; login_customer_id?: string | null }[];
      const acc = accs.find((a) => a.platform === "google" && a.status === "connected") ?? accs.find((a) => a.platform === "google");
      if (!acc) return json(req, 404, { detail: "No Google Ads account" });
      const data = await readBilling(google, acc.external_id, acc.login_customer_id);
      const saved = await rpc("svc_ads_google_billing_save", { p_account: acc.id, p_data: data });
      return json(req, 200, { read: "billing", saved });
    }
    if (body.check) {
      if (!/^[0-9a-f-]{36}$/i.test(body.check)) return json(req, 422, { detail: "check must be an operation id" });
      const o = (await rpc("svc_ads_google_build_peek", { p_id: body.check })) as GoogleOp | null;
      if (!o) return json(req, 404, { detail: "No waiting operation of that kind" });
      const r = await dryRunGoogleOp(google, o);
      const detail = r.ok ? `Google accepts all ${r.operations} parts.` : scrubSecrets(r.error ?? "", s);
      await rpc("svc_ads_google_build_checked", { p_id: o.id, p_ok: r.ok, p_detail: detail });
      return json(req, 200, { check: o.id, ok: r.ok, operations: r.operations, detail });
    }
    const out: { id: string; kind: string; status: string }[] = [];
    for (const o of (await rpc("svc_ads_google_build_work")) as GoogleOp[]) {
      if (Date.now() - t0 > DEADLINE_MS) break;
      if (o.status === "executing") {
        await rpc("svc_ads_google_op_finish", { p_id: o.id, p_status: "outcome_unknown", p_error: "Interrupted while sending; check it in Google Ads.", p_result: null, p_verify: null });
        out.push({ id: o.id, kind: o.kind, status: "outcome_unknown" });
        continue;
      }
      if (!(await rpc("svc_ads_google_op_claim", { p_id: o.id }))) continue;
      const r = await executeGoogleOp(google, o);
      await rpc("svc_ads_google_op_finish", { p_id: o.id, p_status: r.status, p_error: r.error ? scrubSecrets(r.error, s) : null,
        p_result: r.result ?? null, p_verify: r.verify ?? null });
      out.push({ id: o.id, kind: o.kind, status: r.status });
    }
    return json(req, 200, { done: out.length, operations: out });
  } catch (e) {
    return json(req, 500, { detail: scrubSecrets(String((e as Error)?.message ?? e), s).slice(0, 300) });
  }
});
