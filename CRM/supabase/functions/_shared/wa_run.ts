// Deno glue for the WhatsApp Edge Functions (wa-webhook, wa-worker, wa-admin): runs the pure logic in wa.ts against the
// database (svc_wa_* functions, migration 150) and Meta. Every rule about who may get what lives in svc_wa_claim, so
// nothing here can send past Pause all, Test mode, an opt-out, quiet hours, the daily cap or the 24-hour window.
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { admin, rpc } from "./ads_deno.ts";
import {
  buildMessage, decide, describe, graph, parseWebhook, pushesFor, sendMessage,
  type Ctx, type FetchFn, type Inbound, type Json, type OutItem, type PushEvent, type Tpl,
} from "./wa.ts";

export type Secrets = { token: string | null; app_secret: string | null; verify_token: string | null; version: string;
  phone_number_id: string | null; waba_id: string | null; app_id: string | null };

export const fetchFn: FetchFn = (url, init) => fetch(url, init);
let cached: { at: number; s: Secrets } | null = null;
export async function secrets(fresh = false): Promise<Secrets> {
  if (!fresh && cached && Date.now() - cached.at < 60_000) return cached.s;
  const s = await rpc("svc_wa_secrets") as Secrets;
  cached = { at: Date.now(), s };
  return s;
}

const clip = (e: unknown) => String((e as Error)?.message ?? e).replace(/\d{8,}/g, "#").slice(0, 300);
async function logError(place: string, e: unknown, ctx: Json = {}) {
  try { await rpc("svc_wa_error", { p_place: place, p_detail: clip(e), p_ctx: ctx }); } catch { /* never throws */ }
}

// ------------------------------------------------------------------ sending
// Claims and sends. ids: only these queue rows (replies right after a message came in); otherwise whatever is due.
export async function sendQueue(ids?: number[], limit = 20): Promise<{ sent: number; failed: number }> {
  const claimed = await rpc("svc_wa_claim", { p_ids: ids ?? null, p_limit: limit }) as Json[];
  let sent = 0, failed = 0;
  if (!claimed?.length) return { sent, failed };
  const s = await secrets();
  for (const c of claimed) {                          // one by one: replies in a chat keep their order
    const item = c.item as OutItem;
    const tpl = c.template as Tpl | null;
    let shown: Json = { kind: item.type, body: (item as { body?: string }).body ?? null };
    try {
      if (!s.token || !s.phone_number_id) throw Object.assign(new Error("WhatsApp is not connected yet (WhatsApp > Setup)"), { noRetry: true });
      if (item.type === "template" && (!tpl?.name || tpl.status !== "approved")) {
        throw Object.assign(new Error(tpl?.name ? `Template ${tpl.name} is not approved by Meta yet` : "No template set for this message"), { noRetry: true });
      }
      const d = describe(item, tpl, c.vars ?? {});
      shown = { kind: d.kind, body: d.body, payload: d.payload, template_name: d.template_name ?? null, category: tpl?.category?.toLowerCase() ?? null };
      const r = await sendMessage(fetchFn, s.version, s.token, s.phone_number_id, buildMessage(String(c.to), item, tpl, c.vars ?? {}));
      await rpc("svc_wa_result", { p_id: c.id, p_ok: r.ok, p_wamid: r.wamid ?? null, p_error_code: r.code ?? null,
        p_error_text: r.text ?? null, p_retry: r.retry, p_sent: shown });
      if (r.ok) sent++; else failed++;
    } catch (e) {
      failed++;
      await rpc("svc_wa_result", { p_id: c.id, p_ok: false, p_wamid: null, p_error_code: null, p_error_text: clip(e),
        p_retry: !(e as { noRetry?: boolean }).noRetry, p_sent: shown }).catch((x) => logError("send_result", x, { id: c.id }));
    }
  }
  return { sent, failed };
}

// ------------------------------------------------------------------ webhook processing
// One stored delivery: receipts first, then each message through the flow. Safe to run twice (wamid is unique).
export async function processRaw(id: number, body: unknown): Promise<{ messages: number; statuses: number }> {
  try {
    const { messages, statuses } = parseWebhook(body);
    if (statuses.length) await rpc("svc_wa_status", { p_items: statuses });
    for (const m of messages) await handleInbound(m);
    await rpc("svc_wa_raw_done", { p_id: id, p_error: null });
    return { messages: messages.length, statuses: statuses.length };
  } catch (e) {
    await rpc("svc_wa_raw_done", { p_id: id, p_error: clip(e) }).catch(() => {});
    throw e;
  }
}

async function handleInbound(m: Inbound) {
  const ctx = await rpc("svc_wa_inbound", { p: m }) as Json;
  if (!ctx || ctx.duplicate || ctx.skip) return;
  const conv = String(ctx.conversation_id);
  const d = decide(ctx as unknown as Ctx, m);
  const ids = await rpc("svc_wa_apply", { p_conv: conv, p_patch: d.patch, p_out: d.out, p_events: d.events, p_ref: m.wamid }) as number[];
  if (ids?.length) await sendQueue(ids, ids.length).catch((e) => logError("reply_send", e, { conversation: conv }));
  if (m.media?.id) await saveMedia(m, conv).catch((e) => logError("media", e, { wamid: m.wamid }));
}

const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "audio/ogg": "ogg", "audio/mpeg": "mp3",
  "audio/mp4": "m4a", "audio/aac": "aac", "video/mp4": "mp4", "application/pdf": "pdf" };
async function saveMedia(m: Inbound, conv: string) {
  const s = await secrets();
  if (!s.token || !m.media?.id) return;
  const meta = await graph(fetchFn, s.version, s.token, m.media.id);
  if (!meta.ok || !meta.data?.url) throw new Error(meta.message ?? "No media URL from Meta");
  if (Number(meta.data.file_size ?? 0) > 16_000_000) throw new Error("Media larger than 16 MB, not stored");
  const r = await fetch(String(meta.data.url), { headers: { Authorization: `Bearer ${s.token}` } });
  if (!r.ok) throw new Error(`Media download ${r.status}`);
  const bytes = new Uint8Array(await r.arrayBuffer());
  const type = String(meta.data.mime_type ?? m.media.mime_type ?? "application/octet-stream").split(";")[0];
  const path = `${conv}/${m.wamid.replace(/[^A-Za-z0-9._-]/g, "_")}.${EXT[type] ?? (m.media.filename?.split(".").pop() || "bin")}`;
  const up = await admin.storage.from("wa-media").upload(path, bytes, { contentType: type, upsert: true });
  if (up.error) throw new Error(up.error.message);
  await rpc("svc_wa_media_saved", { p_wamid: m.wamid, p_path: path });
}

// ------------------------------------------------------------------ phone notifications (the CRM's existing push setup)
let server: webpush.ApplicationServer | null = null;
export async function pushAlerts(): Promise<number> {
  const w = await rpc("svc_wa_push_work") as { events: PushEvent[]; subs: { id: number; endpoint: string; keys: { p256dh: string; auth: string } }[]; vapid_keys?: string | null };
  if (!w?.events?.length) return 0;
  const ids = w.events.map((e) => e.id);
  if (w.subs?.length && w.vapid_keys) {
    if (!server) {
      const keys = await webpush.importVapidKeys(JSON.parse(w.vapid_keys), { extractable: false });
      server = await webpush.ApplicationServer.new({ contactInformation: "mailto:info@weoneaviation.in", vapidKeys: keys });
    }
    const msgs = pushesFor(w.events);
    await Promise.all(w.subs.map(async (sub) => {
      const target = server!.subscribe({ endpoint: sub.endpoint, keys: sub.keys });
      for (const p of msgs) {
        try { await target.pushTextMessage(JSON.stringify(p), { ttl: 6 * 3600, urgency: webpush.Urgency.High }); }
        catch (e) {
          const st = e instanceof webpush.PushMessageError ? e.response.status : 0;
          if (st === 404 || st === 410) break;        // phone unsubscribed: the Amazon/ADS cleanup removes it
          console.error("wa push", st);
        }
      }
    }));
  }
  await rpc("svc_wa_push_done", { p_ids: ids });
  return ids.length;
}

export { logError };
