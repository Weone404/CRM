// crm-mongo-import: copies new website leads from MongoDB Atlas into the CRM (port of mongo_bridge.py).
//
// Called every minute by pg_cron (job "crm-mongo-import") with header x-cron-token.
// Needs Edge Function secrets: MONGODB_ATLAS_URI (required), MONGODB_DATABASE (default "weoneaviation"),
// MONGODB_COLLECTION (default "leads") — the same values the Render backend uses.
// Only one importer runs at a time: it shares the 'mongo_import' lease with the Render backend, so while
// Render is alive this function skips, and it takes over automatically once Render is switched off.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { MongoClient } from "npm:mongodb@6.10.0";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const str = (v: unknown) => (v == null ? "" : String(v));

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { detail: "Use POST" });
  const { data: ok, error: tErr } = await db.rpc("svc_cron_token_ok", { token: req.headers.get("x-cron-token") ?? "" });
  if (tErr) return json(500, { detail: "Token check failed" });
  if (ok === null) return json(503, { detail: "Cron token is not configured" });
  if (!ok) return json(401, { detail: "Invalid cron token" });

  const uri = Deno.env.get("MONGODB_ATLAS_URI");
  if (!uri) return json(200, { status: "not-configured", detail: "MONGODB_ATLAS_URI secret is not set" });

  const client = new MongoClient(uri, { serverSelectionTimeoutMS: 5000 });
  try {
    await client.connect();
    await client.db("admin").command({ ping: 1 });

    // Lease after a working connection (as before), so a broken importer never blocks a working one.
    const { data: begin, error: bErr } = await db.rpc("svc_mongo_begin");
    if (bErr) throw bErr;
    if (!begin?.ok) return json(200, { status: "skipped", reason: "another importer holds the lease" });

    const coll = client.db(Deno.env.get("MONGODB_DATABASE") || "weoneaviation")
      .collection(Deno.env.get("MONGODB_COLLECTION") || "leads");
    const query = begin.last_imported_at ? { createdAt: { $gt: new Date(begin.last_imported_at) } } : {};
    const found = await coll.find(query).sort({ createdAt: 1 }).limit(1000).toArray();

    const docs = found.map((d: Record<string, unknown>) => ({
      _id: str(d._id), name: str(d.name), phone: str(d.phone), email: str(d.email), course: str(d.course),
      message: str(d.message), source: str(d.source),
      createdAt: d.createdAt instanceof Date ? d.createdAt.toISOString() : null,   // only real dates move the watermark
    }));
    if (!docs.length) return json(200, { status: "ok", imported: 0, deduped: 0 });

    const { data: result, error: iErr } = await db.rpc("svc_mongo_import", { docs });
    if (iErr) throw iErr;
    console.log("mongo import", JSON.stringify(result));
    return json(200, { status: "ok", ...result });
  } catch (e) {
    console.error("mongo import failed", String(e));
    return json(200, { status: "error", detail: String(e).slice(0, 300) });
  } finally {
    await client.close().catch(() => {});
  }
});
