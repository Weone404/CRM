// ig-dm: Instagram comment-to-DM for We One Aviation (migration 135). Called every 2 minutes by pg_cron (crm-ig-dm) with
// the cron token; nobody else can run it. Settings in ads_config 'ig_dm'; the Instagram Login token in Vault
// (ads_instagram_login_token) is read here and never returned or logged. The logic is _shared/ig_dm.ts.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { admin, cronOk, rpc } from "../_shared/ads_deno.ts";
import { httpIG, refreshToken, tick, type Json, type Store } from "../_shared/ig_dm.ts";

const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const now = () => new Date().toISOString();

const store: Store = {
  async known(ids) {
    if (!ids.length) return new Set();
    const { data, error } = await admin.from("ig_dm_log").select("comment_id").in("comment_id", ids);
    if (error) throw new Error(`ig_dm_log: ${error.message}`);
    return new Set((data ?? []).map((r: Json) => String(r.comment_id)));
  },
  async claim(row) {
    const { error } = await admin.from("ig_dm_log").insert({ ...row, created_at: now() });
    if (!error) return true;
    if (error.code === "23505") return false;                        // already claimed: never twice
    throw new Error(`ig_dm_log: ${error.message}`);
  },
  async finish(id, patch) {
    const { error } = await admin.from("ig_dm_log").update(patch).eq("comment_id", id);
    if (error) throw new Error(`ig_dm_log: ${error.message}`);
  },
  async release(id) { await admin.from("ig_dm_log").delete().eq("comment_id", id).eq("state", "sending"); },
  async person(id, username) {
    if (id) {
      const { data } = await admin.from("ig_dm_person").select("*").eq("person", String(id)).maybeSingle();
      if (data) return data;
    }
    if (username) {
      const { data } = await admin.from("ig_dm_person").select("*").ilike("username", String(username).replace(/[%_]/g, "")).order("dm_at", { ascending: false, nullsFirst: false }).limit(1);
      if (data?.[0]) return data[0];
    }
    return null;
  },
  async savePerson(row) {
    const r = { ...row, username: row.username ? String(row.username).toLowerCase() : row.username, updated_at: now() };
    const { error } = await admin.from("ig_dm_person").upsert(r, { onConflict: "person" });
    if (error) throw new Error(`ig_dm_person: ${error.message}`);
  },
  async sent(kind) { await admin.from("ig_dm_send").insert({ kind }); },
  async lead(p) { return await rpc("svc_content_dm_lead", { p }) as Json; },
  async cfg(patch) { await rpc("svc_ig_dm_cfg", { p: patch }); },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { detail: "POST only" });
  if (!(await cronOk(req))) return reply(403, { detail: "cron only" });
  try {
    const work = await rpc("svc_ig_dm_work") as Json;
    if (!work?.cfg?.on || !work?.token) return reply(200, await tick(work ?? {}, null, store));
    const fresh = await refreshToken(String(work.token), work.token_at ?? null);
    if (fresh) { await rpc("svc_ig_dm_token_save", { p_token: fresh }); work.token = fresh; work.token_at = now(); }
    const res = await tick(work, httpIG(String(work.token)), store);
    if (fresh) res.token = "refreshed";
    return reply(200, res);
  } catch (e) {
    return reply(500, { detail: String((e as Error).message ?? e).slice(0, 300) });
  }
});
