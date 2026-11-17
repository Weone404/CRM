// Speed-to-lead alert text (migration 104): one phone notification / email per ad lead still waiting for a first call.
export type AlertSub = { id: number; endpoint: string; keys: { p256dh: string; auth: string } };
export type DueAlert = { lead_id: string; level: number; waited_min: number; first_name: string; course: string | null; platform: string;
  emails: string[]; subs: AlertSub[] };
export const CRM_URL = "https://crm.weoneaviation.in";

export function alertText(a: DueAlert) {
  const who = `${a.first_name}${a.course ? ` (${a.course})` : ""}`;
  const src = a.platform === "meta" ? "Meta ad" : a.platform === "google" ? "Google ad" : "ad";
  const title = a.level === 2 ? `Still not called: ${who}` : `Call now: ${who}`;
  const body = a.level === 2 ? `A ${src} lead has waited ${a.waited_min} minutes for a first call.`
    : `New ${src} lead, waiting ${a.waited_min} minutes. Call while they are still looking.`;
  return { title, body, url: `${CRM_URL}/#/${a.platform === "google" ? "ads" : "metaads"}/leads`, tag: `lead-${a.lead_id}` };
}
