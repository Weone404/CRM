// wa-admin: the WhatsApp page's actions that need Meta (signed-in staff only; every action first asks the database
// whether this person may do it, through an api_wa_* function called as them).
//   {action: "checks", steps?: [...]}       Setup "Check now": asks Meta and saves ✓/✗ with the exact fix
//   {action: "subscribe"}                   subscribes the Meta app to the WhatsApp account (webhooks start)
//   {action: "register", pin}               registers the phone number on the Cloud API (6-digit PIN)
//   {action: "templates_submit", names?}    sends draft/rejected templates to Meta for approval
//   {action: "templates_sync"}              reads every template's status from Meta
//   {action: "send", conversation, item}    a message typed in the Inbox (queued, then sent at once)
//   {action: "test_welcome", phone, brand}  Setup's test: the welcome template to a test number
//   {action: "simulate", brand, step, text|button}   the flow's answer, nothing sent or saved
//   {action: "flush"}                       send whatever is due now (Manage only)
// The access token never leaves this function; answers never include it.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asUser, cors, HttpError, json, rpc } from "../_shared/ads_deno.ts";
import { decide, graph, templatePayload, WA_BUILD, type Ctx, type Json } from "../_shared/wa.ts";
import { fetchFn, secrets, sendQueue, type Secrets } from "../_shared/wa_run.ts";

type Check = { ok: boolean; detail: string; number?: Json };
const OK_NAMES = new Set(["APPROVED", "AVAILABLE_WITHOUT_REVIEW"]);

async function needManage(req: Request) {
  const a = await asUser(req, "api_wa_access") as { can_manage: boolean };
  if (!a?.can_manage) throw new HttpError(403, "You do not have permission to change WhatsApp settings");
}

async function runCheck(step: string, s: Secrets, setup: Json): Promise<Check> {
  const g = (path: string, method = "GET", body?: Json) => graph(fetchFn, s.version, s.token ?? "", path, method, body);
  switch (step) {
    case "app":
      if (!s.app_id) return { ok: false, detail: "Save the App ID (step b)." };
      if (!s.app_secret) return { ok: false, detail: "Paste the App Secret (Meta app > App settings > Basic)." };
      return { ok: true, detail: `App ${s.app_id} and its App Secret are saved.` };
    case "token": {
      if (!s.token) return { ok: false, detail: "Paste the System User access token (step e)." };
      const appTok = s.app_id && s.app_secret ? `${s.app_id}|${s.app_secret}` : s.token;
      const r = await graph(fetchFn, s.version, appTok, `debug_token?input_token=${encodeURIComponent(s.token)}`);
      if (!r.ok) return { ok: false, detail: `Meta could not read the token: ${r.message}` };
      const d = r.data?.data ?? {};
      const scopes: string[] = d.scopes ?? [];
      const missing = ["whatsapp_business_messaging", "whatsapp_business_management"].filter((x) => !scopes.includes(x));
      if (!d.is_valid) return { ok: false, detail: "The token is not valid any more. Generate a new System User token and paste it." };
      if (missing.length) return { ok: false, detail: `The token is missing: ${missing.join(", ")}. Generate it again with both ticked.` };
      if (d.expires_at && d.expires_at !== 0) {
        return { ok: false, detail: `This token expires on ${new Date(d.expires_at * 1000).toDateString()}. Use a System User token with "Never" expiry.` };
      }
      return { ok: true, detail: "Valid, never expires, both WhatsApp permissions present." };
    }
    case "number": case "registered": {
      if (!s.token || !s.phone_number_id) return { ok: false, detail: "Save the token and the Phone Number ID first." };
      const r = await g(`${s.phone_number_id}?fields=display_phone_number,verified_name,name_status,quality_rating,code_verification_status,status`);
      if (!r.ok) return { ok: false, detail: `Meta: ${r.message}` };
      const n = r.data;
      let limit: string | undefined;
      const lim = await g(`${s.phone_number_id}?fields=whatsapp_business_manager_messaging_limit`).catch(() => null);
      if (lim?.ok && lim.data?.whatsapp_business_manager_messaging_limit) limit = String(lim.data.whatsapp_business_manager_messaging_limit);
      const number = { display_phone: n.display_phone_number, verified_name: n.verified_name, name_status: n.name_status,
        quality_rating: n.quality_rating, status: n.status, messaging_limit: limit };
      if (step === "registered") {
        return n.status === "CONNECTED" ? { ok: true, detail: "Connected to the Cloud API.", number }
          : { ok: false, detail: `Status is ${n.status ?? "unknown"}. Press "Register number" with a 6-digit PIN.`, number };
      }
      if (n.code_verification_status && n.code_verification_status !== "VERIFIED") {
        return { ok: false, detail: "Verify the number with the OTP in WhatsApp Manager.", number };
      }
      if (!OK_NAMES.has(String(n.name_status))) {
        return { ok: false, detail: `Display name "${n.verified_name ?? ""}" is ${String(n.name_status ?? "not approved").toLowerCase().replace(/_/g, " ")}. Wait for Meta's approval or change it in WhatsApp Manager.`, number };
      }
      return { ok: true, detail: `${n.display_phone_number} · ${n.verified_name} · quality ${String(n.quality_rating ?? "unknown").toLowerCase()}`, number };
    }
    case "ids": {
      if (!s.token || !s.waba_id || !s.phone_number_id) return { ok: false, detail: "Save the WhatsApp Business Account ID and the Phone Number ID." };
      const r = await g(`${s.waba_id}/phone_numbers?fields=id,display_phone_number`);
      if (!r.ok) return { ok: false, detail: `Meta: ${r.message}` };
      const found = (r.data?.data ?? []).some((p: Json) => String(p.id) === s.phone_number_id);
      return found ? { ok: true, detail: "The phone number belongs to this WhatsApp Business Account." }
        : { ok: false, detail: "This Phone Number ID is not in that WhatsApp Business Account. Copy both from Meta app > WhatsApp > API Setup." };
    }
    case "subscribed": {
      if (!s.token || !s.waba_id) return { ok: false, detail: "Save the token and the WhatsApp Business Account ID first." };
      const r = await g(`${s.waba_id}/subscribed_apps`);
      if (!r.ok) return { ok: false, detail: `Meta: ${r.message}` };
      const apps = (r.data?.data ?? []) as Json[];
      const mine = apps.some((a) => !s.app_id || String(a?.whatsapp_business_api_data?.id ?? a?.id ?? "") === s.app_id);
      return apps.length && mine ? { ok: true, detail: "The app receives this account's messages." }
        : { ok: false, detail: 'Press "Subscribe app" so Meta sends this number\'s messages to the CRM.' };
    }
    case "webhook": {
      if (!setup.webhook_seen_at) return { ok: false, detail: "Paste the Callback URL and Verify token into Meta app > WhatsApp > Configuration, press Verify and save, then subscribe the \"messages\" field." };
      if (!setup.last_inbound_at) return { ok: false, detail: "Meta checked the URL. Now send any WhatsApp message to the business number from your phone, then Check now." };
      return { ok: true, detail: `Messages arrive${setup.gateway_seen_at ? " through the Cloudflare gateway" : ""}. Last one ${new Date(setup.last_inbound_at).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}.` };
    }
    case "templates": {
      const sync = await syncTemplates(s);
      if (!sync.ok) return { ok: false, detail: sync.detail };
      const t = await rpc("svc_wa_template_state") as Json;
      return t.welcome_approved ? { ok: true, detail: `Welcome template approved. ${t.approved} approved, ${t.pending} waiting, ${t.rejected} rejected.` }
        : { ok: false, detail: t.welcome_status === "rejected" ? `Meta rejected the welcome template: ${t.welcome_reason ?? "see Templates"}. Edit it as a new name and submit.`
            : t.welcome_status === "draft" ? 'Press "Submit starter templates".' : "Waiting for Meta to approve the welcome template (usually minutes, up to 24 hours)." };
    }
    case "test": {
      const t = await rpc("svc_wa_test_state") as Json;
      if (!t.delivered) return { ok: false, detail: 'Add your number in Settings > Test numbers, then press "Send test welcome".' };
      if (!t.replied) return { ok: false, detail: "Welcome delivered. Now tap a button on it from your phone." };
      if (!t.bot_answered) return { ok: false, detail: "Your reply arrived but the bot has not answered yet. Wait a few seconds and Check now." };
      return { ok: true, detail: "Welcome delivered, you replied, and the bot answered." };
    }
  }
  return { ok: false, detail: "Unknown step" };
}

async function syncTemplates(s: Secrets): Promise<{ ok: boolean; detail: string; count?: number }> {
  if (!s.token || !s.waba_id) return { ok: false, detail: "Save the token and the WhatsApp Business Account ID first." };
  const items: Json[] = [];
  let path = `${s.waba_id}/message_templates?fields=name,language,status,category,rejected_reason,id&limit=200`;
  for (let i = 0; i < 5 && path; i++) {
    const r = await graph(fetchFn, s.version, s.token, path);
    if (!r.ok) return { ok: false, detail: `Meta: ${r.message}` };
    items.push(...(r.data?.data ?? []));
    const next = String(r.data?.paging?.next ?? "");
    path = next.startsWith("https://graph.facebook.com/") ? next.replace(/^https:\/\/graph\.facebook\.com\/v[0-9.]+\//, "") : "";
  }
  const n = await rpc("svc_wa_templates_meta", { p_items: items }) as number;
  return { ok: true, detail: `${n} templates updated from Meta.`, count: n };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method === "GET") return json(req, 200, { build: WA_BUILD });
  if (req.method !== "POST") return json(req, 405, { detail: "POST only" });
  try {
    const b = await req.json().catch(() => ({})) as Json;
    switch (b.action) {
      case "checks": {
        await needManage(req);
        const setup = await asUser(req, "api_wa_setup") as Json;
        const s = await secrets(true);
        const all = ["app", "token", "number", "ids", "subscribed", "registered", "webhook", "templates", "test"];
        const steps = (Array.isArray(b.steps) && b.steps.length ? b.steps : all).filter((x: string) => all.includes(x));
        const results: Record<string, Check> = {};
        for (const step of steps) {
          let c: Check;
          try { c = await runCheck(step, s, setup); } catch (e) { c = { ok: false, detail: `Could not check: ${String((e as Error).message ?? e).slice(0, 200)}` }; }
          results[step] = { ok: c.ok, detail: c.detail };
          await rpc("svc_wa_setup_save", { p_step: step, p_ok: c.ok, p_detail: c.detail, p_number: c.number ?? null, p_by: null });
        }
        return json(req, 200, { results });
      }
      case "subscribe": {
        await needManage(req);
        const s = await secrets(true);
        if (!s.token || !s.waba_id) throw new HttpError(422, "Save the token and the WhatsApp Business Account ID first");
        const r = await graph(fetchFn, s.version, s.token, `${s.waba_id}/subscribed_apps`, "POST");
        if (!r.ok) throw new HttpError(422, `Meta: ${r.message}`);
        return json(req, 200, { ok: true });
      }
      case "register": {
        await needManage(req);
        const pin = String(b.pin ?? "");
        if (!/^\d{6}$/.test(pin)) throw new HttpError(422, "The PIN is 6 digits (it becomes the number's two-step verification PIN; keep it safe)");
        const s = await secrets(true);
        if (!s.token || !s.phone_number_id) throw new HttpError(422, "Save the token and the Phone Number ID first");
        const r = await graph(fetchFn, s.version, s.token, `${s.phone_number_id}/register`, "POST", { messaging_product: "whatsapp", pin });
        if (!r.ok) throw new HttpError(422, `Meta: ${r.message}`);
        return json(req, 200, { ok: true });
      }
      case "templates_submit": {
        await needManage(req);
        const s = await secrets(true);
        if (!s.token || !s.waba_id) throw new HttpError(422, "Save the token and the WhatsApp Business Account ID first");
        const list = (await asUser(req, "api_wa_templates") as Json).templates as Json[];
        const want = new Set<string>(Array.isArray(b.names) ? b.names : []);
        const todo = list.filter((t) => (want.size ? want.has(t.name) : true) && ["draft", "rejected"].includes(t.meta_status));
        const results: Json[] = [];
        for (const t of todo) {
          const r = await graph(fetchFn, s.version, s.token, `${s.waba_id}/message_templates`, "POST",
            templatePayload({ name: t.name, language: t.language, category: t.category, body: t.body, footer: t.footer, buttons: t.buttons }));
          results.push(r.ok ? { name: t.name, language: t.language, id: r.data.id, status: r.data.status ?? "PENDING", category: r.data.category }
            : { name: t.name, language: t.language, status: "REJECTED", rejected_reason: r.message });
        }
        if (results.length) await rpc("svc_wa_templates_meta", { p_items: results });
        return json(req, 200, { submitted: results.length, results: results.map((x) => ({ name: x.name, status: x.status, reason: x.rejected_reason ?? null })) });
      }
      case "templates_sync": {
        await asUser(req, "api_wa_templates");
        const r = await syncTemplates(await secrets(true));
        if (!r.ok) throw new HttpError(422, r.detail);
        return json(req, 200, r);
      }
      case "send": {
        const id = await asUser(req, "api_wa_send", { p_conv: b.conversation, p_item: b.item }) as number;
        const r = await sendQueue([id], 1);
        return json(req, 200, { queued: id, ...r });
      }
      case "test_welcome": {
        const id = await asUser(req, "api_wa_test_welcome", { p_phone: b.phone, p_brand: b.brand === "charter" ? "charter" : "aviation" }) as number;
        const r = await sendQueue([id], 1);
        if (r.failed) {
          const t = await rpc("svc_wa_queue_error", { p_id: id }) as string | null;
          throw new HttpError(422, t || "The test message failed: see Inbox for the reason");
        }
        return json(req, 200, { queued: id, ...r });
      }
      case "simulate": {
        const flow = await asUser(req, "api_wa_flow", { p_brand: b.brand === "charter" ? "charter" : "aviation" }) as Json;
        const ctx: Ctx = { conversation: { status: "bot", current_step: b.step ?? null, miss_count: Number(b.miss ?? 0) },
          contact: { opted_out: !!b.opted_out }, steps: flow.steps, rules: flow.rules, vars: flow.vars, brochure: flow.brochure, bot_on: true };
        const d = decide(ctx, { wamid: "sim", from: "0", kind: b.button ? "button" : "text", text: b.text ?? undefined, button_title: b.button ?? undefined });
        return json(req, 200, d);
      }
      case "flush": {
        await needManage(req);
        return json(req, 200, await sendQueue(undefined, 20));
      }
      default:
        throw new HttpError(400, "Unknown action");
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    return json(req, status, { detail: String((e as Error).message ?? e).slice(0, 400) });
  }
});
