// wa-webhook: Meta calls this for WhatsApp messages and delivery receipts (directly, or through the Cloudflare gateway
// in tools/wa-gateway, which keeps a copy and re-sends anything that did not get a 200 here).
//
//   GET  ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...   Meta's check when the Callback URL is saved.
//   POST                                                              Checks X-Hub-Signature-256 with the App Secret,
//        stores the delivery once (svc_wa_raw_add), answers 200, then runs it through the flow in the background.
//        If storing fails the answer is 500, so Meta (or the gateway) tries again: nothing is lost.
//        If the background run fails, wa-worker picks the stored delivery up again within a minute.
// verify_jwt is off (Meta has no CRM account): deploy with --no-verify-jwt. Nothing about the person is logged.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { rpc } from "../_shared/ads_deno.ts";
import { hmacHex, safeEqual, sha256Hex, verifySignature, WA_BUILD } from "../_shared/wa.ts";
import { processRaw, secrets } from "../_shared/wa_run.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;
const text = (status: number, body: string) => new Response(body, { status, headers: { "Content-Type": "text/plain" } });

Deno.serve(async (req) => {
  try {
    const via = req.headers.get("x-wa-gateway") ? "gateway" : "direct";
    if (req.method === "GET") {
      const u = new URL(req.url);
      if (u.searchParams.get("build") === "1") return text(200, WA_BUILD);
      const mode = u.searchParams.get("hub.mode"), token = u.searchParams.get("hub.verify_token") ?? "", challenge = u.searchParams.get("hub.challenge") ?? "";
      const s = await secrets(true);
      if (mode === "subscribe" && s.verify_token && safeEqual(token, s.verify_token) && /^[0-9A-Za-z_\-]{1,200}$/.test(challenge)) {
        await rpc("svc_wa_webhook_seen", { p_via: via });
        return text(200, challenge);
      }
      return text(403, "Forbidden");
    }
    if (req.method !== "POST") return text(405, "Method not allowed");
    const raw = await req.text();
    if (raw.length > 3_500_000) return text(413, "Too large");
    const s = await secrets();
    if (!(await verifySignature(s.app_secret, raw, req.headers.get("x-hub-signature-256"), hmacHex))) {
      const again = await secrets(true);           // the App Secret may have just been saved
      if (!(await verifySignature(again.app_secret, raw, req.headers.get("x-hub-signature-256"), hmacHex))) {
        console.warn("wa-webhook: signature missing or wrong");
        return text(403, "Invalid signature");
      }
    }
    let body: unknown;
    try { body = JSON.parse(raw); } catch { return text(200, "EVENT_RECEIVED"); }
    const id = await rpc("svc_wa_raw_add", { p_body: body, p_sha: await sha256Hex(raw), p_via: via }) as number | null;
    if (id) {
      const work = processRaw(id, body).catch((e) => console.error("wa-webhook process", String(e).replace(/\d{8,}/g, "#").slice(0, 200)));
      if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(work); else await work;
    }
    return text(200, "EVENT_RECEIVED");
  } catch (e) {
    console.error("wa-webhook error", String(e).replace(/\d{8,}/g, "#").slice(0, 200));
    return text(500, "Try again");
  }
});
