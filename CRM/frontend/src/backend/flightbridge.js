// FlightBridge AI tab on Supabase (was the Render API /api/flightbridge/*).
// Screens read and write through the api_fb_* database functions; saving/testing API keys, adding an area by
// name (Google finds it) and the Hostinger webhook go through the crm-flightbridge Edge Function.
// Nothing here sends email: approvals are recorded and the FlightBridge engine's gates decide what may be sent.
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './supabaseClient';
import { json, detail, rpc } from './http';

const FB = '^/api/flightbridge';
const ID = '([^/]+)';
const r = (path) => new RegExp(`${FB}${path}$`);
const dec = (s) => decodeURIComponent(s);

// Whole-number query parameter, like the old API (a bad value answered 422).
function intParam(query, key, fallback) {
  const raw = query?.get(key);
  if (raw === null || raw === undefined || raw === '') return { value: fallback };
  if (!/^\s*-?\d+\s*$/.test(raw)) return { error: detail(422, `${key} must be a whole number`) };
  return { value: Number(raw) };
}
const truthy = (v) => ['true', '1', 'yes', 'on', 't', 'y'].includes(String(v || '').toLowerCase());

async function edge(path, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/crm-flightbridge${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_PUBLISHABLE_KEY,
      Authorization: `Bearer ${data.session?.access_token || ''}`,
    },
    body: JSON.stringify(body || {}),
  });
  const out = await res.json().catch(() => ({ detail: `HTTP ${res.status}` }));
  return json(res.status, out);
}

function withLimit(query, fn, key, fallback, extra = {}) {
  const lim = intParam(query, 'limit', fallback);
  if (lim.error) return lim.error;
  return rpc(fn, { ...extra, [key]: lim.value });
}

function schoolFilters(query) {
  const f = {};
  for (const k of ['country', 'status', 'q', 'region', 'eligibility', 'kind', 'area_id', 'limit']) {
    const v = query?.get(k);
    if (v !== null && v !== undefined && v !== '') f[k] = v;
  }
  return f;
}
const schools = (query) => rpc('api_fb_schools', { p_filters: schoolFilters(query) });
// True counts per eligibility section for the same filters (the list itself is capped at 1,000 rows).
const schoolCounts = (query) => rpc('api_fb_school_counts', { p_filters: schoolFilters(query) });

const hasCoords = (b) => typeof b?.lat === 'number' && typeof b?.lng === 'number';

export const FLIGHTBRIDGE_ROUTES = [
  ['GET', r('/summary'), () => rpc('api_fb_summary')],
  ['GET', r('/approvals'), ({ query }) => rpc('api_fb_approvals', { p_status: query?.get('status') ?? 'open' })],
  ['GET', r(`/approvals/${ID}`), ({ params }) => rpc('api_fb_approval', { p_id: dec(params[0]) })],
  ['POST', r(`/approvals/${ID}/decision`), ({ params, body }) => rpc('api_fb_decision', { p_id: dec(params[0]), p_data: body || {} })],

  ['GET', r('/outbound'), ({ query }) => withLimit(query, 'api_fb_outbound', 'p_limit', 50)],
  ['GET', r(`/outbound/${ID}`), ({ params }) => rpc('api_fb_outbound_get', { p_id: dec(params[0]) })],
  ['POST', r(`/outbound/${ID}/recheck`), ({ params }) => rpc('api_fb_outbound_recheck', { p_id: dec(params[0]) })],

  ['POST', r('/evidence'), ({ body }) => rpc('api_fb_evidence_add', { p_data: body || {} })],
  ['GET', r('/suppressions'), () => rpc('api_fb_suppressions')],
  ['POST', r('/suppressions'), ({ body }) => rpc('api_fb_suppression_add', { p_data: body || {} })],
  ['POST', r('/kill-switch'), ({ body }) => rpc('api_fb_kill_switch', { p_data: body || {} })],

  ['GET', r('/templates'), () => rpc('api_fb_templates')],
  ['POST', r('/templates'), ({ body }) => rpc('api_fb_template_save', { p_data: body || {} })],
  ['GET', r('/templates/brief'), () => rpc('api_fb_template_brief')],
  ['POST', r('/templates/generate'), ({ body }) => edge('/templates/generate', body)],
  ['POST', r('/templates/followups'), () => edge('/templates/followups', {})],
  ['POST', r(`/templates/${ID}/approve`), ({ params }) => rpc('api_fb_template_approve', { p_id: dec(params[0]) })],

  ['GET', r('/inbox'), ({ query }) => withLimit(query, 'api_fb_inbox', 'p_limit', 100,
    { p_risk: query?.get('risk') || null, p_unmatched: truthy(query?.get('unmatched')) })],
  ['GET', r('/settings'), () => rpc('api_fb_settings')],
  ['POST', r('/settings/followups'), ({ body }) => rpc('api_fb_followups_set', { p_data: body || {} })],
  ['GET', r('/metrics'), () => rpc('api_fb_metrics')],
  ['GET', r('/detector'), () => rpc('api_fb_detector')],

  ['GET', r('/me'), () => rpc('api_fb_me')],
  ['GET', r('/team'), () => rpc('api_fb_team')],
  ['POST', r(`/team/${ID}/role`), ({ params, body }) => rpc('api_fb_team_role', { p_id: dec(params[0]), p_data: body || {} })],

  ['GET', r('/schools'), ({ query }) => schools(query)],
  ['GET', r('/school-counts'), ({ query }) => schoolCounts(query)],
  ['GET', r(`/schools/${ID}`), ({ params }) => rpc('api_fb_school', { p_id: dec(params[0]) })],
  ['POST', r(`/schools/${ID}/review`), ({ params, body }) => rpc('api_fb_school_review', { p_id: dec(params[0]), p_data: body || {} })],
  ['POST', r(`/schools/${ID}/regulatory/(\\d+)/verify`), ({ params }) =>
    rpc('api_fb_regulatory_verify', { p_org: dec(params[0]), p_approval: Number(params[1]) })],
  ['POST', r(`/schools/${ID}/eligibility`), ({ params, body }) => rpc('api_fb_eligibility', { p_id: dec(params[0]), p_data: body || {} })],
  ['GET', r('/regions'), () => rpc('api_fb_regions')],

  ['GET', r('/send-autopilot'), () => rpc('api_fb_send_autopilot')],
  ['POST', r('/send-autopilot'), ({ body }) => rpc('api_fb_send_autopilot_set', { p_data: body || {} })],
  ['GET', r('/pipeline'), ({ query }) => rpc('api_fb_pipeline', { p_data: Object.fromEntries(['stage', 'q', 'limit']
    .map((k) => [k, query?.get(k)]).filter(([, v]) => v !== null && v !== undefined && v !== '')) })],
  ['POST', r('/pipeline/move'), ({ body }) => rpc('api_fb_pipeline_move', { p_data: body || {} })],
  ['GET', r('/automation'), () => rpc('api_fb_automation')],
  ['POST', r('/automation/run'), ({ body }) => rpc('api_fb_run', { p_data: body || {} })],
  ['POST', r('/automation/settings'), ({ body }) => rpc('api_fb_autopilot_set', { p_data: body || {} })],

  ['GET', r('/integrations'), () => rpc('api_fb_integrations')],
  ['GET', r('/register-uploads'), () => rpc('api_fb_register_uploads')],
  ['POST', r('/register-uploads'), ({ body }) => rpc('api_fb_register_upload', { p_data: body || {} })],
  ['POST', r('/integrations/([a-z_]+)/test'), ({ params }) => edge(`/integrations/${params[0]}/test`)],
  ['POST', r('/integrations/([a-z_]+)'), ({ params, body }) => edge(`/integrations/${params[0]}`, body)],
  ['DELETE', r(`/integrations/${ID}`), ({ params }) => rpc('api_fb_integration_delete', { p_name: dec(params[0]) })],
  ['POST', r('/integrations-settings'), ({ body }) => rpc('api_fb_integration_settings', { p_data: body || {} })],

  ['GET', r('/areas'), () => rpc('api_fb_areas')],
  ['POST', r('/areas'), ({ body }) => (hasCoords(body) ? rpc('api_fb_area_add', { p_data: body }) : edge('/areas', body))],
  ['PATCH', r('/areas/(\\d+)'), ({ params, body }) => rpc('api_fb_area_patch', { p_id: Number(params[0]), p_data: body || {} })],
];
