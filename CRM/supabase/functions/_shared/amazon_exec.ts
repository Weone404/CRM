// Executes ONE approved change on Amazon, and reconciles executions whose outcome is unknown.
// Runtime-neutral: the database is passed in as an rpc function, so this is unit-tested locally.
//
// Order for one change:
//   1. claim (approved -> executing, exactly once; a second caller gets nothing)
//   2. re-read the live listing; if Amazon's values moved since the draft -> Stale (nothing sent)
//   3. PATCH in VALIDATION_PREVIEW mode; any ERROR -> Failed (nothing sent for real)
//   4. real PATCH. Throttling is retried inside SpApi (a 429 is never processed by Amazon, so no duplicate);
//      a 5xx / network drop leaves the change in Executing for reconcile() to settle from Amazon's real state
//   5. re-read and verify; suppressed -> alert + rollback draft; fields the API cannot set -> Needs manual
import { SpApi, UnknownOutcome, SpApiError, buildPatches, parseListing, verifyApplied, isSuppressed } from "./amazon.ts";

export type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<any>;

const FIELDS = ["title", "bullets", "description", "backend_terms", "price", "mrp", "country_of_origin", "manufacturer"] as const;
const norm = (v: unknown) => (v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v).trim());
const numish = (k: string, v: unknown) => (k === "price" || k === "mrp") && v != null && v !== "" ? String(Number(v)) : norm(v);

// Fields where Amazon now differs both from what the draft was based on and from what we want.
export function staleFields(before: Record<string, any>, after: Record<string, any>, live: Record<string, any>) {
  return FIELDS.filter((k) => k in after && before && k in before && before[k] != null
    && numish(k, live[k]) !== numish(k, before[k]) && numish(k, live[k]) !== numish(k, after[k]));
}

export async function execute(rpc: Rpc, api: SpApi, secrets: Record<string, string>, id: string,
  opts: { settleMs?: number; sleep?: (ms: number) => Promise<void> } = {}) {
  const q = await rpc("svc_amz_claim", { p_id: id });
  if (!q) return { status: "skipped", reason: "not approved or already running" };
  const finish = (status: string, preview: unknown, error: string | null, suppressed = false) =>
    rpc("svc_amz_finish", { p_id: id, p_status: status, p_preview: preview ?? null, p_error: error, p_suppressed: suppressed });

  if (q.kind === "ads_budget") {
    await finish("needs_manual", null,
      `Set the total daily budget across all campaigns to ₹${q.after?.daily_budget_total} in Amazon Ads Campaign Manager, then mark this done.`);
    return { status: "needs_manual" };
  }
  const seller = secrets.AMZ_SELLER_ID;
  const mk = secrets.MARKETPLACE_ID || api.marketplaceId;
  const lang = secrets.LANGUAGE_TAG || "en_IN";
  const sku = q.seller_sku || q.sku;

  let live;
  try { live = parseListing(await api.getListing(seller, sku), sku); }
  catch (e) { await finish("failed", null, `Could not read the live listing: ${String((e as Error).message).slice(0, 300)}`); return { status: "failed" }; }

  const moved = staleFields(q.before || {}, q.after || {}, live);
  if (moved.length) {
    await finish("stale", null, `Amazon's ${moved.join(", ")} changed since this draft was made. Nothing was sent. Review and approve again.`);
    return { status: "stale", moved };
  }

  const { patches, notPushed } = buildPatches(q.after || {}, mk, lang);
  const productType = q.product_type || live.product_type || "PRODUCT";
  if (!patches.length) {
    await finish("needs_manual", null, `Set by hand in Seller Central: ${notPushed.join(", ")}.`);
    return { status: "needs_manual" };
  }

  // 3. preview
  let preview: any;
  try { preview = await api.patchListing(seller, sku, productType, patches, true); }
  catch (e) {
    const msg = e instanceof SpApiError ? `${e.status} ${e.message}` : String(e);
    // A preview is a read for our purposes: nothing changed on Amazon, so it is safe to mark failed.
    await finish("failed", (e as SpApiError).body ?? null, `Validation preview failed: ${msg.slice(0, 300)}`);
    return { status: "failed" };
  }
  const errors = (preview?.issues || []).filter((i: any) => i.severity === "ERROR");
  if (preview?.status === "INVALID" || errors.length) {
    await finish("failed", preview, `Amazon rejected the preview: ${errors.map((i: any) => i.message).join(" | ").slice(0, 600) || preview?.status}`);
    return { status: "failed", preview };
  }

  // 4. real patch
  let res: any;
  try { res = await api.patchListing(seller, sku, productType, patches, false); }
  catch (e) {
    if (e instanceof UnknownOutcome) return { status: "executing", reason: e.message };   // reconcile() settles it
    await finish("failed", preview, `Amazon refused the change: ${String((e as Error).message).slice(0, 300)}`);
    return { status: "failed" };
  }
  if (res?.status !== "ACCEPTED") {
    await finish("failed", { preview, submit: res }, `Amazon did not accept the change (${res?.status}).`);
    return { status: "failed" };
  }

  // 5. verify (Amazon applies accepted changes asynchronously; give it a moment, reconcile() re-checks later)
  if (opts.settleMs) await (opts.sleep || ((ms) => new Promise((r) => setTimeout(r, ms))))(opts.settleMs);
  const after = parseListing(await api.getListing(seller, sku), sku);
  if (isSuppressed(after)) {
    await finish("live", { preview, submit: res }, "Listing is suppressed after this change.", true);
    return { status: "live", suppressed: true };
  }
  const bad = verifyApplied(q.after || {}, after);
  if (bad.length) return { status: "executing", reason: `waiting for Amazon to apply: ${bad.join(", ")}` };
  if (notPushed.length) {
    await finish("needs_manual", { preview, submit: res }, `Pushed. Still to set by hand in Seller Central: ${notPushed.join(", ")}.`);
    return { status: "needs_manual" };
  }
  await finish("live", { preview, submit: res }, null);
  return { status: "live" };
}

// Changes stuck in Executing (network drop, Amazon still processing): settle them from Amazon's real state.
export async function reconcile(rpc: Rpc, api: SpApi, secrets: Record<string, string>, stuck: any[]) {
  const out: any[] = [];
  for (const q of stuck) {
    const sku = q.sku;
    let live;
    try { live = parseListing(await api.getListing(secrets.AMZ_SELLER_ID, sku), sku); }
    catch (e) { out.push({ id: q.id, status: "unreachable" }); continue; }
    const bad = verifyApplied(q.after || {}, live);
    const suppressed = isSuppressed(live);
    const ageMin = (Date.now() - new Date(q.executed_at).getTime()) / 60000;
    if (!bad.length) {
      await rpc("svc_amz_finish", { p_id: q.id, p_status: "live", p_preview: null, p_error: null, p_suppressed: suppressed });
      out.push({ id: q.id, status: "live", suppressed });
    } else if (ageMin > 60) {
      await rpc("svc_amz_finish", { p_id: q.id, p_status: "failed", p_preview: null,
        p_error: `After an hour Amazon still shows the old ${bad.join(", ")}. Nothing to undo. Re-submit if still wanted.`, p_suppressed: suppressed });
      out.push({ id: q.id, status: "failed" });
    } else {
      out.push({ id: q.id, status: "waiting", fields: bad });
    }
  }
  return out;
}
