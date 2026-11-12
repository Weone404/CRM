// amazon-studio: Studio photos for the signed-in user (Amazon > Studio).
//   multipart {file, sku}                 -> stores the photo in the PRIVATE 'amazon-studio' bucket and queues its check on the Mac
//   {action:"urls", ids:[...]}            -> short-lived links to view Studio photos (private bucket)
//   {action:"send", asset, slot}          -> copies the chosen photo to the public 'amazon-images' bucket (Amazon needs a public
//                                            link) and creates a waiting Decision. Admin / approvers only. Nothing goes to Amazon here.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, asUser, cors, json, HttpError, URL_ } from "../_shared/amazon_deno.ts";

const MAX = 15 * 1024 * 1024;
const kind = (b: Uint8Array): "jpg" | "png" | null =>
  b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff ? "jpg"
  : b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 ? "png" : null;

async function rpcAdmin(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new HttpError(error.code === "PT404" ? 404 : 422, error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  try {
    const access = await asUser(req, "api_amz_access");
    if (!access?.can_view) throw new HttpError(403, "You do not have access to the Amazon section");
    const me = access.employee_id ?? null;
    if ((req.headers.get("content-type") || "").startsWith("multipart/form-data")) {
      const form = await req.formData().catch(() => null);
      const file = form?.get("file");
      const sku = String(form?.get("sku") ?? "");
      if (!(file instanceof File)) throw new HttpError(400, "No photo received");
      if (!/^[A-Za-z0-9._-]{1,40}$/.test(sku)) throw new HttpError(400, "Missing product");
      if (file.size > MAX) throw new HttpError(413, "Photo is bigger than 15 MB");
      const bytes = new Uint8Array(await file.arrayBuffer());
      const ext = kind(bytes);
      if (!ext) throw new HttpError(415, "Only JPG or PNG photos (on iPhone: Settings > Camera > Formats > Most Compatible)");
      const path = `${sku}/up/${crypto.randomUUID()}.${ext}`;
      const { error } = await admin.storage.from("amazon-studio").upload(path, bytes, { contentType: ext === "jpg" ? "image/jpeg" : "image/png" });
      if (error) throw new Error(error.message);
      return json(req, 200, await rpcAdmin("svc_amz_studio_upload", { p_sku: sku, p_path: path, p_bytes: bytes.length, p_by: me }));
    }
    const body = await req.json().catch(() => ({}));
    if (body.action === "urls") {
      const ids = (Array.isArray(body.ids) ? body.ids : []).filter((x: unknown) => typeof x === "string").slice(0, 60);
      if (!ids.length) return json(req, 200, {});
      const { data: rows } = await admin.from("amazon_studio_assets").select("id,path").in("id", ids);
      const out: Record<string, string> = {};
      for (const r of rows || []) {
        const { data } = await admin.storage.from("amazon-studio").createSignedUrl(r.path, 3600);
        if (data?.signedUrl) out[r.id] = data.signedUrl;
      }
      return json(req, 200, out);
    }
    if (body.action === "send") {
      if (!access.can_approve) throw new HttpError(403, "Only Admin can send Studio photos to Decisions");
      const slot = String(body.slot ?? "");
      const { data: a } = await admin.from("amazon_studio_assets").select("id,sku,path,kind,status").eq("id", String(body.asset ?? "")).maybeSingle();
      if (!a || a.status === "deleted") throw new HttpError(404, "Photo not found");
      const { data: file, error: dErr } = await admin.storage.from("amazon-studio").download(a.path);
      if (dErr || !file) throw new Error(dErr?.message || "download failed");
      const bytes = new Uint8Array(await file.arrayBuffer());
      const ext = kind(bytes) || "jpg";
      const pub = `${a.sku}/studio-${crypto.randomUUID()}.${ext}`;
      const { error: uErr } = await admin.storage.from("amazon-images").upload(pub, bytes, {
        contentType: ext === "jpg" ? "image/jpeg" : "image/png", cacheControl: "31536000" });
      if (uErr) throw new Error(uErr.message);
      const url = `${URL_}/storage/v1/object/public/amazon-images/${pub}`;
      return json(req, 200, await rpcAdmin("svc_amz_studio_send", { p_asset: a.id, p_slot: slot, p_url: url, p_by: me }));
    }
    throw new HttpError(400, "Unknown action");
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    console.error("amazon-studio", e instanceof Error ? e.message : String(e));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Studio error. Try again." });
  }
});
