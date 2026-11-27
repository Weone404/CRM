// wa-worker: every minute (pg_cron crm-wa-worker, migration 150) and straight after a new lead is queued (wa_kick).
// Only the cron token can run it. One pass:
//   1. deliveries that arrived but were not processed (a crash, a timeout) go through the flow again;
//   2. follow-ups that are due are queued (only people who never replied);
//   3. everything due is sent, in batches, until about 45 seconds have passed;
//   4. phone notifications for chats that need a person.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cronOk, rpc } from "../_shared/ads_deno.ts";
import { WA_BUILD } from "../_shared/wa.ts";
import { logError, processRaw, pushAlerts, sendQueue } from "../_shared/wa_run.ts";

const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { detail: "POST only" });
  if (!(await cronOk(req))) return reply(403, { detail: "cron only" });
  const t0 = Date.now();
  const out: Record<string, unknown> = { build: WA_BUILD };
  try {
    const raws = await rpc("svc_wa_raw_pending", { p_limit: 25 }) as { id: number; body: unknown }[];
    let redone = 0;
    for (const r of raws ?? []) {
      try { await processRaw(r.id, r.body); redone++; } catch (e) { await logError("raw_retry", e, { id: r.id }); }
    }
    out.webhooks_retried = redone;
    out.followups_queued = await rpc("svc_wa_followups_due");
    let sent = 0, failed = 0;
    for (let i = 0; i < 10 && Date.now() - t0 < 45_000; i++) {
      const r = await sendQueue(undefined, 20);
      sent += r.sent; failed += r.failed;
      if (r.sent + r.failed < 20) break;
    }
    Object.assign(out, { sent, failed });
    out.alerts = await pushAlerts().catch(async (e) => { await logError("push", e); return 0; });
    return reply(200, out);
  } catch (e) {
    await logError("worker", e);
    return reply(500, { ...out, detail: String((e as Error).message ?? e).slice(0, 300) });
  }
});
