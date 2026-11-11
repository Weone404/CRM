// Words for alert emails and phone notifications (pure functions, unit-tested).
export interface Alert { id: number; kind: string; title: string; body?: string | null; link?: string | null; created_at?: string }
export interface Reply { id: number; kind: string; sku?: string | null; asked_by: string; answer?: string | null; question?: string | null }
export interface Decision { summary: string; why?: string | null; product?: string | null; link: string }
export interface Push { title: string; body: string; url: string; tag: string }

const CRM = "https://crm.weoneaviation.in";
const ICON: Record<string, string> = { new_order: "🛒", pickup: "🚚", feedback: "⭐", out_of_stock: "📦", suppressed: "⚠️" };
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const safeLink = (u?: string | null) => (u && /^https:\/\/[^\s"<>]+$/.test(u) ? u : null);

function page(heading: string, rowsHtml: string, button: { url: string; label: string }) {
  return `<!doctype html><html><body style="margin:0;background:#f5f5f7;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1d1d1f">
<div style="max-width:560px;margin:0 auto;padding:24px 16px">
<h2 style="font-size:18px;margin:0 0 14px">${esc(heading)}</h2>
${rowsHtml}
<a href="${esc(button.url)}" style="display:inline-block;margin-top:12px;background:#007aff;color:#fff;text-decoration:none;padding:10px 18px;border-radius:999px;font-weight:600">${esc(button.label)}</a>
<p style="font-size:12px;color:#86868b;margin-top:22px">Sent by We One CRM. Change who gets these in CRM &gt; Amazon &gt; More &gt; Settings.</p>
</div></body></html>`;
}
const card = (title: string, body?: string | null, link?: string | null, linkLabel = "Open") =>
  `<div style="background:#fff;border-radius:14px;padding:12px 14px;margin-bottom:8px">
<div style="font-weight:600">${esc(title)}</div>${body ? `<div style="font-size:14px;color:#3c3c43;margin-top:3px">${esc(body)}</div>` : ""}${
  safeLink(link) ? `<a href="${esc(link)}" style="font-size:13px;color:#007aff">${esc(linkLabel)}</a>` : ""}</div>`;

export function alertEmail(alerts: Alert[]) {
  const n = alerts.length;
  const first = alerts[0];
  const subject = n === 1 ? `${ICON[first.kind] ?? "🔔"} ${first.title}` : `🔔 ${n} Amazon alerts: ${alerts.map((a) => a.title).slice(0, 2).join("; ")}${n > 2 ? "…" : ""}`;
  const text = alerts.map((a) => `${ICON[a.kind] ?? "-"} ${a.title}${a.body ? `\n   ${a.body}` : ""}${safeLink(a.link) ? `\n   ${a.link}` : ""}`).join("\n\n") +
    `\n\nOpen the CRM: ${CRM}/#/amazon`;
  const html = page(n === 1 ? "Amazon alert" : `${n} Amazon alerts`,
    alerts.map((a) => card(`${ICON[a.kind] ?? "🔔"} ${a.title}`, a.body, a.link, a.kind === "feedback" ? "Open Feedback Manager" : "Open in Seller Central")).join(""),
    { url: `${CRM}/#/amazon`, label: "Open the CRM" });
  return { subject: subject.slice(0, 180), text, html };
}

export function digestEmail(items: Decision[], waitingTotal: number) {
  const subject = `✅ ${waitingTotal} Amazon decision${waitingTotal === 1 ? "" : "s"} waiting for you`;
  const text = items.map((d) => `- ${d.summary}${d.product ? ` (${d.product})` : ""}${d.why ? `\n  Why: ${d.why}` : ""}\n  ${d.link}`).join("\n\n") +
    `\n\nAll decisions: ${CRM}/#/amazon/decisions`;
  const html = page(subject.slice(2), items.map((d) => card(d.summary, [d.product, d.why ? `Why: ${d.why}` : ""].filter(Boolean).join(" · "), d.link, "Approve, change or reject")).join(""),
    { url: `${CRM}/#/amazon/decisions`, label: "Open Decisions" });
  return { subject, text, html };
}

// Several alerts at once become one notification, so the phone does not buzz ten times.
export function alertPushes(alerts: Alert[]): Push[] {
  if (alerts.length === 0) return [];
  if (alerts.length > 3) {
    return [{ title: `🔔 ${alerts.length} new Amazon alerts`, body: alerts.map((a) => a.title).slice(0, 4).join(" · ").slice(0, 180),
      url: "/#/amazon", tag: "amz-alerts" }];
  }
  return alerts.map((a) => ({ title: `${ICON[a.kind] ?? "🔔"} ${a.title}`.slice(0, 90), body: String(a.body ?? "").slice(0, 180),
    url: "/#/amazon", tag: `amz-${a.kind}-${a.id}` }));
}

export function replyPush(r: Reply): Push {
  const title = r.kind === "fix" ? "Claude's fixes are ready" : r.kind === "report" ? "Your weekly report is ready" : "Claude replied";
  return { title, body: String(r.answer ?? "").replace(/\s+/g, " ").slice(0, 160),
    url: r.kind === "fix" ? "/#/amazon/decisions" : "/#/amazon/ask", tag: `amz-reply-${r.id}` };
}
