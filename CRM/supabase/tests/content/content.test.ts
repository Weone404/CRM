import { test } from "node:test";
import assert from "node:assert/strict";
import { pictureOf, updateOf } from "../../functions/_shared/content.ts";

const png = btoa(String.fromCharCode(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3));
const jpg = btoa(String.fromCharCode(0xff, 0xd8, 0xff, 0xe0, 1, 2));

test("CC01 ad pictures: PNG or JPEG, a known size, base64 (data: prefix allowed)", () => {
  assert.deepEqual([pictureOf({ image_b64: png, size: "1080x1350" }).type, pictureOf({ image_b64: `data:image/jpeg;base64,${jpg}`, size: "1080x1920" }).ext], ["image/png", "jpg"]);
  assert.match(pictureOf({ image_b64: png, size: "500x500" }).problem!, /size/);
  assert.match(pictureOf({ image_b64: btoa("GIF89a....."), size: "1080x1350" }).problem!, /PNG or JPEG/);
  assert.match(pictureOf({ image_b64: "%%%", size: "1080x1350" }).problem!, /base64/);
  assert.match(pictureOf({ size: "1080x1350" }).problem!, /missing/);
});

test("CC02 updates keep only known fields: https links, numeric stats, short notes", () => {
  const u = updateOf({ status: "posted", studio_job: "j1", posted_at: "2026-11-24T08:00:00Z", note: "x".repeat(900), evil: 1,
    media: { permalink: "https://www.instagram.com/reel/a/", thumbnail: "javascript:alert(1)", other: "https://x" },
    stats: { views: "1200", shares: 3, "bad key!": 1, reach: "lots" } }) as any;
  assert.deepEqual(Object.keys(u).sort(), ["media", "note", "posted_at", "stats", "status", "studio_job"]);
  assert.deepEqual(u.media, { permalink: "https://www.instagram.com/reel/a/" });
  assert.deepEqual(u.stats, { views: 1200, shares: 3 });
  assert.equal(u.note.length, 500);
  assert.equal("posted_at" in updateOf({ posted_at: "yesterday" }), false);
});
