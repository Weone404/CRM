// Growth > Content (migration 116): pure helpers for the crm-content Edge Function (tested in supabase/tests/content).

export const MAX_PICTURE_BYTES = 8 * 1024 * 1024;
const SIZES = new Set(["1080x1350", "1080x1920", "1080x1080"]);

// A picture Reel Studio sends back for an ad: PNG or JPEG, a known size, at most 8 MB. Returns bytes or the reason it is refused.
export function pictureOf(b: { image_b64?: unknown; size?: unknown }): { bytes?: Uint8Array; type?: string; ext?: string; size?: string; problem?: string } {
  const size = String(b.size ?? "");
  if (!SIZES.has(size)) return { problem: "size must be 1080x1350, 1080x1920 or 1080x1080" };
  const s = String(b.image_b64 ?? "").replace(/^data:image\/[a-z]+;base64,/, "");
  if (!s || s.length > Math.ceil(MAX_PICTURE_BYTES / 3) * 4 + 4) return { problem: "picture missing or over 8 MB" };
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); } catch { return { problem: "picture is not base64" }; }
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (!png && !jpg) return { problem: "only PNG or JPEG pictures" };
  return { bytes, type: png ? "image/png" : "image/jpeg", ext: png ? "png" : "jpg", size };
}

// Only these fields of an update reach the database (status, ids, links, numbers, a short note).
export function updateOf(b: any): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (typeof b?.status === "string") out.status = b.status;
  if (typeof b?.studio_job === "string") out.studio_job = b.studio_job.slice(0, 80);
  if (typeof b?.note === "string") out.note = b.note.slice(0, 500);
  if (typeof b?.posted_at === "string" && !Number.isNaN(Date.parse(b.posted_at))) out.posted_at = b.posted_at;
  if (b?.media && typeof b.media === "object") {
    const m: Record<string, string> = {};
    for (const k of ["permalink", "thumbnail", "video"]) if (typeof b.media[k] === "string" && /^https:\/\//.test(b.media[k])) m[k] = b.media[k].slice(0, 600);
    out.media = m;
  }
  if (typeof b?.ig_media_id === "string" && /^[0-9]{5,30}$/.test(b.ig_media_id)) out.ig_media_id = b.ig_media_id;   // 120: the post Reel Studio made
  if (typeof b?.ig_error === "string" && b.ig_error.trim()) out.ig_error = b.ig_error.trim().slice(0, 300);
  if (b?.stats && typeof b.stats === "object") {
    const st: Record<string, number> = {};
    for (const [k, v] of Object.entries(b.stats)) if (/^[a-z_]{2,30}$/.test(k) && Number.isFinite(Number(v))) st[k] = Number(v);
    out.stats = st;
  }
  return out;
}

// 120: Reel Studio's answer to a posting instruction (scheduled with the signature it acted on, cancelled, too_late, failed)
export function ackOf(b: any): { id?: number; sig?: string | null; state?: string; note?: string | null; problem?: string } {
  const id = Number(b?.id);
  if (!Number.isInteger(id) || id <= 0) return { problem: "id is required" };
  const state = String(b?.state ?? "");
  if (!["scheduled", "cancelled", "too_late", "failed"].includes(state)) return { problem: "state must be scheduled, cancelled, too_late or failed" };
  const sig = typeof b?.sig === "string" && /^[0-9a-f]{32}$/.test(b.sig) ? b.sig : null;
  if (state === "scheduled" && !sig) return { problem: "sig is required when scheduled" };
  return { id, sig, state, note: typeof b?.note === "string" ? b.note.slice(0, 300) : null };
}
