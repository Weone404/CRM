// crm-content: Reel Studio's only door into the CRM (Growth > Content, migration 116). Called by the Reel Studio worker on the
// office Mac (outbound only), never by a browser. Token: header x-content-token = the Vault secret "Reel Studio"
// (Connections & keys > Sending data into the CRM). Body: {action}
//   ping                       -> {ok}
//   next                       -> {item} (an ad picture/video to make, or a reel/carousel due within 36 hours) or {item: null}
//   update {id, status, ...}   -> producing | ready | posted | held | failed, studio_job, media links, stats, note, posted_at
//   picture {id, size, image_b64} -> an ad picture for a Meta strategy creative (Content > Ad creatives shows it; the owner uses it)
//   signals                    -> the Demand Analyst's brief and what worked, for Reel Studio's own Strategist
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, rpc } from "../_shared/ads_deno.ts";
import { pictureOf, updateOf } from "../_shared/content.ts";

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
      default: return reply(422, { detail: "action must be ping, next, update, picture or signals" });
    }
  } catch (e) {
    console.error("crm-content error", String(e).slice(0, 300));
    return reply(500, { detail: "Something went wrong" });
  }
});
