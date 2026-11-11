// amazon-notify: instant alert emails (business email over SMTP 465) and phone notifications (Web Push).
// Called by:
//   - database triggers / cron with x-cron-token: {action:"deliver"} or {action:"digest"}
//   - the CRM (signed-in user):  {action:"init"} make the phone-notification keys once,
//                                {action:"test_push"} notify this user's own devices,
//                                {action:"test_email"} (Admin) send a test from the business email.
// Secrets (SMTP password, VAPID private key) come from Vault via the service role and never leave this function.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { cors, json, HttpError, rpc, asUser, cronOk } from "../_shared/amazon_deno.ts";
import { smtpSend, type SmtpConfig } from "../_shared/smtp.ts";
import { alertEmail, alertPushes, digestEmail, replyPush, type Alert, type Push, type Reply } from "../_shared/notify_text.ts";

type Sub = { id: number; employee_id: string; endpoint: string; keys: { p256dh: string; auth: string } };
type Cfg = { smtp: { host: string; port: number; username: string; from_name?: string; enabled: boolean } | null; smtp_password: string | null;
  smtp_ready: boolean; recipients: string[]; vapid_keys: string | null; vapid_public: string | null };

const CONTACT = "mailto:info@weoneaviation.in";
let server: webpush.ApplicationServer | null = null;

async function appServer(cfg: Cfg) {
  if (server) return server;
  let keysJson = cfg.vapid_keys;
  if (!keysJson) {
    const keys = await webpush.generateVapidKeys({ extractable: true });
    const pub = await webpush.exportApplicationServerKey(keys);
    const stored = await rpc("svc_amz_vapid_init", { p_keys: JSON.stringify(await webpush.exportVapidKeys(keys)), p_public: pub }) as Record<string, string>;
    keysJson = stored.vapid_keys;
  }
  const vapidKeys = await webpush.importVapidKeys(JSON.parse(keysJson!), { extractable: false });
  server = await webpush.ApplicationServer.new({ contactInformation: CONTACT, vapidKeys });
  return server;
}

async function pushAll(cfg: Cfg, subs: Sub[], msgs: Push[]) {
  if (!subs.length || !msgs.length) return { sent: 0 };
  const as = await appServer(cfg);
  const ok = new Set<number>(), gone = new Set<number>(), failed = new Set<number>();
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    const sub = as.subscribe({ endpoint: s.endpoint, keys: s.keys });
    for (const m of msgs) {
      try {
        await sub.pushTextMessage(JSON.stringify(m), { ttl: 12 * 3600, urgency: webpush.Urgency.High });
        ok.add(s.id); sent++;
      } catch (e) {
        const st = e instanceof webpush.PushMessageError ? e.response.status : 0;
        if (st === 404 || st === 410) { gone.add(s.id); break; }
        failed.add(s.id);
        console.error("amazon-notify push", st, e instanceof Error ? e.message : String(e));
      }
    }
  }));
  for (const id of gone) { ok.delete(id); failed.delete(id); }
  for (const id of ok) failed.delete(id);
  await rpc("svc_amz_push_result", { p_ok: [...ok], p_gone: [...gone], p_failed: [...failed] });
  return { sent, removed: gone.size };
}

const smtpOf = (cfg: Cfg): SmtpConfig => ({ host: cfg.smtp!.host, port: cfg.smtp!.port, username: cfg.smtp!.username,
  password: cfg.smtp_password!, fromName: cfg.smtp!.from_name });

async function deliver() {
  const cfg = await rpc("svc_amz_notify_config") as Cfg;
  const c = await rpc("svc_amz_notify_claim") as { push: Alert[]; replies: Reply[]; email: Alert[]; subs: Sub[] };
  const out: Record<string, unknown> = {};
  // Phone notifications: alerts to everyone with notifications on; Claude replies only to the person who asked.
  if (c.subs.length) {
    out.alerts_pushed = (await pushAll(cfg, c.subs, alertPushes(c.push))).sent;
    let replies = 0;
    for (const r of c.replies) replies += (await pushAll(cfg, c.subs.filter((s) => s.employee_id === r.asked_by), [replyPush(r)])).sent;
    out.replies_pushed = replies;
  }
  if (c.email.length) {
    try {
      await smtpSend(smtpOf(cfg), { to: cfg.recipients, ...alertEmail(c.email) });
      out.emailed = c.email.length;
    } catch (e) {
      await rpc("svc_amz_notify_unclaim_email", { p_ids: c.email.map((a) => a.id) });   // the hourly Gmail task will send them
      await rpc("svc_amz_smtp_test_save", { p_ok: false, p_detail: `Alert email failed: ${e instanceof Error ? e.message : e}` });
      out.email_error = e instanceof Error ? e.message : String(e);
    }
  }
  return out;
}

async function digest() {
  const d = await rpc("svc_amz_notify_digest") as { items: { summary: string; why?: string; product?: string; link: string }[]; waiting_total: number };
  if (!d.items.length) return { emailed: 0 };
  const cfg = await rpc("svc_amz_notify_config") as Cfg;
  await smtpSend(smtpOf(cfg), { to: cfg.recipients, ...digestEmail(d.items, d.waiting_total) });
  return { emailed: d.items.length };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { detail: "Use POST" });
  try {
    const body = await req.json().catch(() => ({}));
    if (req.headers.get("x-cron-token")) {
      if (!(await cronOk(req))) throw new HttpError(401, "Bad cron token");
      if (body.action === "deliver") return json(req, 200, await deliver());
      if (body.action === "digest") return json(req, 200, await digest());
      throw new HttpError(400, "Unknown action");
    }
    const me = await asUser(req, "api_amz_notify_me") as { employee_id: string; is_admin: boolean };
    const cfg = await rpc("svc_amz_notify_config") as Cfg;
    switch (body.action) {
      case "init": {
        await appServer(cfg);
        const fresh = await rpc("svc_amz_notify_config") as Cfg;
        return json(req, 200, { vapid_public: fresh.vapid_public });
      }
      case "test_push": {
        const mine = await rpc("svc_amz_push_subs_for", { p_employee: me.employee_id }) as Sub[];
        if (!mine.length) throw new HttpError(409, "Notifications are not on for this account yet");
        const r = await pushAll(cfg, mine, [{ title: "✅ Notifications work", body: "New orders, the pickup reminder, bad feedback and Claude's replies will show up like this.",
          url: "/#/amazon", tag: "amz-test" }]);
        return json(req, 200, { sent: r.sent, devices: mine.length });
      }
      case "test_email": {
        if (!me.is_admin) throw new HttpError(403, "Only Admin can send a test email");
        if (!cfg.smtp || !cfg.smtp_password) throw new HttpError(409, "Save the email settings and password first");
        const to = cfg.recipients.length ? cfg.recipients : [cfg.smtp.username];
        try {
          await smtpSend(smtpOf(cfg), { to, subject: "✅ Test: CRM alerts from your business email",
            text: "This is a test from your CRM. Amazon alerts will now come from this address.",
            html: "<p>This is a test from your <b>CRM</b>. Amazon alerts will now come from this address.</p>" });
          await rpc("svc_amz_smtp_test_save", { p_ok: true, p_detail: `Sent to ${to.join(", ")}` });
          return json(req, 200, { ok: true, to });
        } catch (e) {
          const m = e instanceof Error ? e.message : String(e);
          await rpc("svc_amz_smtp_test_save", { p_ok: false, p_detail: m });
          throw new HttpError(502, m);
        }
      }
      default:
        throw new HttpError(400, "Unknown action");
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error("amazon-notify", e instanceof Error ? e.message : String(e));
    return json(req, status, { detail: e instanceof HttpError ? e.message : "Notification error" });
  }
});
