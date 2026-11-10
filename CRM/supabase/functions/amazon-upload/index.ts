// amazon-upload: stores ONE product photo and returns its public link (Amazon downloads photos from a public URL).
// POST multipart/form-data {file, sku} with the signed-in user's token. The user must have access to the Amazon section.
// Only JPEG/PNG up to 10 MB, checked by content (magic bytes), not by name. Files go to the public 'amazon-images'
// bucket under <sku>/<random>.<ext>; nothing is sent to Amazon here: the photo is used only after a saved change.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, asUser, cors, json, HttpError, URL_ } from "../_shared/amazon_deno.ts";

const MAX = 10 * 1024 * 1024;

function kind(b: Uint8Array): "jpg" | "png" | null {
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "jpg";
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "png";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  try {
    const access = await asUser(req, "api_amz_access");
    if (!access?.can_view) throw new HttpError(403, "You do not have access to the Amazon section");
    const form = await req.formData().catch(() => null);
    const file = form?.get("file");
    const sku = String(form?.get("sku") ?? "");
    if (!(file instanceof File)) throw new HttpError(400, "No photo received");
    if (!/^[A-Za-z0-9._-]{1,40}$/.test(sku)) throw new HttpError(400, "Missing product");
    if (file.size > MAX) throw new HttpError(413, "Photo is bigger than 10 MB");
    const bytes = new Uint8Array(await file.arrayBuffer());
    const ext = kind(bytes);
    if (!ext) throw new HttpError(415, "Only JPG or PNG photos");
    const path = `${sku}/${crypto.randomUUID()}.${ext}`;
    const { error } = await admin.storage.from("amazon-images").upload(path, bytes, {
      contentType: ext === "jpg" ? "image/jpeg" : "image/png", upsert: false, cacheControl: "31536000" });
    if (error) throw new Error(error.message);
    return json(req, 200, { url: `${URL_}/storage/v1/object/public/amazon-images/${path}` });
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    console.error("amazon-upload", e instanceof Error ? e.message : String(e));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Could not save the photo. Try again." });
  }
});
