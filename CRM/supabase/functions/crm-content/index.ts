// crm-content: Reel Studio's only door into the CRM (Growth > Content, migration 116). Called by the Reel Studio worker on the
// office Mac (outbound only), never by a browser. Token: header x-content-token = the Vault secret "Reel Studio"
// (Connections & keys > Sending data into the CRM). Body: {action}
//   ping                       -> {ok}
//   next                       -> {item} (an ad picture/video to make, or a reel/carousel due within 36 hours) or {item: null}
//   update {id, status, ...}   -> producing | ready | posted | held | failed, studio_job, media links, stats, note, posted_at
//   picture {id, size, image_b64} -> an ad picture for a Meta strategy creative (Content > Ad creatives shows it; the owner uses it)
//   signals                    -> the Demand Analyst's brief and what worked, for Reel Studio's own Strategist
//   post_tasks                 -> {tasks}: approved ad videos Reel Studio posts (schedule with time/caption/AI label, or cancel) (120)
//   post_ack {id, state, sig, note} -> scheduled | cancelled | too_late | failed
//   dm_lead {username, phone, name?, source, text?} -> a phone number someone sent the Instagram account becomes a CRM lead (123)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, rpc } from "../_shared/ads_deno.ts";
import { ackOf, dmLeadOf, pictureOf, updateOf } from "../_shared/content.ts";

const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { detail: "POST only" });
  try {
    const ok = await rpc("svc_content_token_ok", { p_token: req.headers.get("x-content-token") ?? "" });
    if (ok !== true) return reply(401, { detail: "Bad or missing Reel Studio token" });
    let b: any = {};
    try { b = await req.json(); } catch { /* empty */ }
    switch (b.action) {
      case "ping": return reply(200, { ok: true });
      case "next": return reply(200, { item: await rpc("svc_content_next") ?? null });
      case "signals": return reply(200, await rpc("svc_content_signals"));
      case "update": {
        const id = Number(b.id);
        if (!Number.isInteger(id)) return reply(422, { detail: "id is required" });
        return reply(200, await rpc("svc_content_update", { p_id: id, p: updateOf(b) }));
      }
      case "post_tasks": return reply(200, { tasks: await rpc("svc_content_post_tasks") ?? [] });   // 120: ad videos Reel Studio posts
      case "post_ack": {
        const a = ackOf(b);
        if (a.problem) return reply(422, { detail: a.problem });
        return reply(200, await rpc("svc_content_post_ack", { p_id: a.id, p_sig: a.sig, p_state: a.state, p_note: a.note }));
      }
      case "dm_lead": {                                  // 123: Instagram comment / DM -> phone number -> Leads
        const l = dmLeadOf(b);
        if (l.problem) return reply(422, { detail: l.problem });
        return reply(200, await rpc("svc_content_dm_lead", { p: l.lead }));
      }
      case "picture": {
        const id = Number(b.id);
        if (!Number.isInteger(id)) return reply(422, { detail: "id is required" });
        const p = pictureOf(b);
        if (p.problem) return reply(422, { detail: p.problem });
        const path = `ad/${id}/${p.size}.${p.ext}`;
        const { error } = await admin.storage.from("content").upload(path, p.bytes!, { contentType: p.type, upsert: true });
        if (error) return reply(500, { detail: `Storage: ${error.message}`.slice(0, 200) });
        const r = await rpc("svc_content_picture", { p_id: id, p_size: p.size, p_path: path });
        return reply(200, r);
      }
      case "adopt": {                                    // a finished ad video made in Reel Studio becomes an Ad creatives item
        return reply(200, await rpc("svc_content_adopt", { p: { studio_job: String(b.studio_job ?? "").slice(0, 80), title: String(b.title ?? "").slice(0, 120),
          script: String(b.script ?? "").slice(0, 3000), summary: String(b.summary ?? "").slice(0, 600) } }));
      }
      case "video_upload": {                             // one-time upload links (the video goes straight to storage, not through here)
        const id = Number(b.id);
        if (!Number.isInteger(id) || id <= 0) return reply(422, { detail: "id is required" });
        const out: Record<string, unknown> = {};
        for (const [k, name] of [["video", "video.mp4"], ["thumb", "thumb.jpg"]]) {
          const { data, error } = await admin.storage.from("content").createSignedUploadUrl(`ad/${id}/${name}`, { upsert: true });
          if (error || !data) return reply(502, { detail: `upload link: ${error?.message ?? "none"}` });
          out[k] = { path: `ad/${id}/${name}`, url: data.signedUrl };
        }
        return reply(200, out);
      }
      case "video_done": {
        const id = Number(b.id);
        if (!Number.isInteger(id) || id <= 0) return reply(422, { detail: "id is required" });
        const secs = Number(b.seconds);
        return reply(200, await rpc("svc_content_video", { p_id: id, p_video: `ad/${id}/video.mp4`, p_thumb: `ad/${id}/thumb.jpg`,
          p_seconds: Number.isFinite(secs) && secs > 0 && secs < 600 ? secs : null }));
      }
      default: return reply(422, { detail: "action must be ping, next, update, picture, signals, adopt, video_upload, video_done, post_tasks or post_ack" });
    }
  } catch (e) {
    console.error("crm-content error", String(e).slice(0, 300));
    return reply(500, { detail: "Something went wrong" });
  }
});
