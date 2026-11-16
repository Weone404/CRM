// ads-meta-webhook: Meta calls this when a Meta lead form is submitted (Page "leadgen") or a WhatsApp message arrives
// from a Click-to-WhatsApp ad (WhatsApp "messages" with a referral). ADS only.
//
//   GET  ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...   Meta's one-time check when the callback URL is saved.
//                                                                     Answers the challenge only if the verify token matches
//                                                                     ADS > Settings > Meta webhook verify token.
//   POST (Meta's notification)   Checks X-Hub-Signature-256 against the Meta App Secret, stores each lead id once
//                                (svc_ads_meta_raw_add, only for sources switched on), answers 200 at once.
//                                ads-sync fetches and files the leads (every 2 minutes, see migration 100).
// A 500 makes Meta try again (for up to 36 hours), so a database hiccup does not lose a lead; a repeat is ignored.
// verify_jwt is off: Meta has no CRM account. Nothing about the person is logged.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { rpc } from "../_shared/ads_deno.ts";
import { parseWebhook, verifySignature, safeEqual } from "../_shared/ads_meta.ts";

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type Cfg = { app_secret: string | null; verify_token: string | null; intake: { instant_form: boolean; ctwa: boolean } };

Deno.serve(async (req) => {
  try {
    if (req.method === "GET") {
      const u = new URL(req.url);
      const mode = u.searchParams.get("hub.mode"), token = u.searchParams.get("hub.verify_token") ?? "", challenge = u.searchParams.get("hub.challenge") ?? "";
      const cfg = (await rpc("svc_ads_meta_webhook_cfg")) as Cfg;
      if (mode === "subscribe" && cfg.verify_token && safeEqual(token, cfg.verify_token) && /^[0-9A-Za-z_\-]{1,200}$/.test(challenge)) {
        await rpc("svc_ads_meta_webhook_seen");      // shows as "Meta checked the callback URL" in Setup
        return new Response(challenge, { status: 200, headers: { "Content-Type": "text/plain" } });
      }
      return new Response("Forbidden", { status: 403 });
    }
    if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
    const raw = await req.text();
    if (raw.length > 2_000_000) return new Response("Too large", { status: 413 });
    const cfg = (await rpc("svc_ads_meta_webhook_cfg")) as Cfg;
    if (!(await verifySignature(cfg.app_secret, raw, req.headers.get("x-hub-signature-256"), hmacHex))) {
      console.warn("ads-meta-webhook: signature missing or wrong");
      return new Response("Invalid signature", { status: 403 });
    }
    let body: unknown;
    try { body = JSON.parse(raw); } catch { return new Response("EVENT_RECEIVED", { status: 200 }); }
    const items = parseWebhook(body).filter((i) => cfg.intake?.[i.source]);
    if (items.length) await rpc("svc_ads_meta_raw_add", { p_items: items, p_via: "webhook" });
    return new Response("EVENT_RECEIVED", { status: 200 });
  } catch (e) {
    console.error("ads-meta-webhook error", String(e).replace(/\d{6,}/g, "#").slice(0, 200));
    return new Response("Error", { status: 500 });
  }
});
