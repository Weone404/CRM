// Supabase backend for the existing CRM screens.
//
// The React components still call `${API_URL}/api/...` exactly as they did with the
// Render backend. When VITE_BACKEND=supabase, main.jsx routes those calls here, and
// each route answers with the same status codes and JSON shapes Render returned —
// so every screen keeps working unchanged while the data comes from Supabase
// (Postgres functions + Row Level Security + the crm-auth Edge Function).
//
// Routes that are not migrated yet answer 501 so a gap is visible, never silent.
import { supabase, AUTH_FUNCTION_URL, SUPABASE_PUBLISHABLE_KEY } from './supabaseClient';
import { createClient } from '@supabase/supabase-js';

const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const detail = (status, message) => json(status, { detail: message });

// Call a Postgres API function and translate its result/error into a Render-style response.
async function rpc(fn, args = {}) {
  const { data, error, status } = await supabase.rpc(fn, args);
  if (error) {
    const code = /^PT(\d{3})$/.exec(error.code || '');
    const httpStatus = code ? Number(code[1]) : (status && status >= 400 ? status : 500);
    if (httpStatus === 401 || /JWT|not authenticated/i.test(error.message || '')) {
      return detail(401, 'Could not validate credentials');
    }
    return detail(httpStatus, error.message || 'Request failed');
  }
  return json(200, data);
}

async function hasSession() {
  const { data } = await supabase.auth.getSession();
  return Boolean(data.session);
}

// ---- Sign-in (crm-auth Edge Function) ------------------------------------------
async function signIn(identifier, password) {
  const res = await fetch(AUTH_FUNCTION_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY },
    body: JSON.stringify({ action: 'login', identifier, password }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { error: body.error || 'Login failed', status: res.status };
  const { error } = await supabase.auth.setSession({
    access_token: body.session.access_token,
    refresh_token: body.session.refresh_token,
  });
  if (error) return { error: 'Could not start the session. Please try again.', status: 500 };
  return { session: body.session, profile: body.profile };
}

async function employeeLogin(identifier, password, isEmployeeSession) {
  if (!identifier || !password) return detail(400, 'Enter your login ID / phone / email and password.');
  const r = await signIn(identifier, password);
  if (r.error) return detail(r.status === 429 ? 429 : 401, r.error);
  if (r.profile?.person_type !== 'employee') {
    await supabase.auth.signOut();
    return detail(401, 'Incorrect login details.');
  }
  const me = await supabase.rpc('api_me');
  if (me.error) { await supabase.auth.signOut(); return detail(401, 'Incorrect login details.'); }
  return json(200, {
    access_token: r.session.access_token,
    employee: { ...me.data, is_employee_session: isEmployeeSession },
  });
}

async function studentLogin(mobile, password) {
  const digits = String(mobile || '').replace(/\D/g, '');
  if (digits.length < 9) return detail(400, 'Enter a valid 10-digit mobile number');
  const r = await signIn(digits, password);
  if (r.error) return detail(r.status === 429 ? 429 : 401, r.status === 429 ? r.error : 'Invalid mobile number or password');
  if (r.profile?.person_type !== 'student') {
    await supabase.auth.signOut();
    return detail(401, 'Invalid mobile number or password');
  }
  const { data: s } = await supabase.from('student').select('id, first_name, last_name').eq('id', r.profile.person_id).single();
  return json(200, {
    access_token: r.session.access_token,
    student: {
      id: r.profile.person_id,
      first_name: s?.first_name ?? null,
      last_name: s?.last_name ?? null,
      name: [s?.first_name, s?.last_name].filter(Boolean).join(' ') || r.profile.name,
    },
  });
}

async function changePassword(body) {
  const { old_password: oldPw, new_password: newPw } = body || {};
  if (!oldPw || !newPw) return detail(400, 'Old and new passwords required');
  if (String(newPw).length < 6) return detail(400, 'New password must be at least 6 characters');
  const { data: u } = await supabase.auth.getUser();
  if (!u?.user?.email) return detail(401, 'Could not validate credentials');
  // Verify the current password on a throw-away client so the live session is untouched.
  const probe = createClient(import.meta.env.VITE_SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: wrong } = await probe.auth.signInWithPassword({ email: u.user.email, password: oldPw });
  if (wrong) return detail(401, 'Current password is incorrect');
  await probe.auth.signOut().catch(() => {});
  const { error } = await supabase.auth.updateUser({ password: newPw });
  if (error) return detail(400, error.message);
  return json(200, { status: 'success', message: 'Password changed successfully' });
}

// ---- Route table ------------------------------------------------------------------
// [method, path pattern, handler({ params, body, query })]
const ROUTES = [
  ['POST', /^\/api\/auth\/login$/, ({ body }) => employeeLogin(body?.login_id, body?.password, false)],
  ['POST', /^\/api\/auth\/employee-login$/, ({ body }) => employeeLogin(body?.login_id, body?.pin ?? body?.password, true)],
  ['POST', /^\/api\/auth\/student-login$/, ({ body }) => studentLogin(body?.mobile, body?.pin ?? body?.password)],
  ['POST', /^\/api\/auth\/change-password$/, ({ body }) => changePassword(body)],

  ['GET', /^\/api\/me$/, () => rpc('api_me')],
  ['GET', /^\/api\/config$/, () => rpc('api_config')],
  ['GET', /^\/api\/birthdays\/today$/, () => rpc('api_birthdays_today')],

  ['GET', /^\/api\/leads$/, () => rpc('api_leads')],
  ['POST', /^\/api\/leads\/query$/, ({ body }) => rpc('api_lead_query', { p_data: body || {} })],
  ['POST', /^\/api\/leads\/([0-9a-f-]{36})\/contact$/, ({ params, body }) => rpc('api_lead_contact', { p_lead_id: params[0], p_data: body || {} })],
  ['POST', /^\/api\/leads\/([0-9a-f-]{36})\/close$/, ({ params, body }) => rpc('api_lead_close', { p_lead_id: params[0], p_data: body || {} })],
  ['POST', /^\/api\/leads\/([0-9a-f-]{36})\/followup$/, ({ params, body }) => rpc('api_lead_followup', { p_lead_id: params[0], p_data: body || {} })],
  ['GET', /^\/api\/followups\/pending$/, () => rpc('api_followups_pending')],
  ['GET', /^\/api\/reports\/funnel$/, () => rpc('api_funnel')],

  ['GET', /^\/api\/dispositions\/stats$/, () => rpc('api_disposition_stats')],
  ['GET', /^\/api\/dispositions\/(interested|not-interested|not-reachable|callback)$/, ({ params }) => rpc('api_disposition_list', { p_kind: params[0] })],

  ['GET', /^\/api\/courses$/, () => rpc('api_courses')],
  ['PATCH', /^\/api\/courses\/([0-9a-f-]{36})\/installments$/, ({ params, body }) => rpc('api_course_installments', { p_course_id: params[0], p_data: body || {} })],

  ['GET', /^\/api\/outbox$/, () => rpc('api_outbox')],
  ['POST', /^\/api\/outbox\/([0-9a-f-]{36})\/approve$/, ({ params }) => rpc('api_outbox_set_status', { p_message_id: params[0], p_status: 'approved' })],
  ['POST', /^\/api\/outbox\/([0-9a-f-]{36})\/sent$/, ({ params }) => rpc('api_outbox_set_status', { p_message_id: params[0], p_status: 'sent' })],
];

const PUBLIC_PATHS = /^\/api\/auth\/(login|employee-login|student-login)$/;

export async function handleApiRequest(method, path, query, rawBody) {
  if (!supabase) return detail(500, 'Supabase is not configured (VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY).');
  let body = null;
  if (typeof rawBody === 'string' && rawBody) {
    try { body = JSON.parse(rawBody); } catch { body = null; }
  }
  for (const [m, pattern, handler] of ROUTES) {
    if (m !== method) continue;
    const match = pattern.exec(path);
    if (!match) continue;
    if (!PUBLIC_PATHS.test(path) && !(await hasSession())) {
      return detail(401, 'Could not validate credentials');
    }
    try {
      return await handler({ params: match.slice(1), body, query });
    } catch (err) {
      console.error('[supabase-backend]', method, path, err);
      return detail(500, 'Something went wrong. Please try again.');
    }
  }
  return detail(501, `Not moved to the new backend yet: ${method} ${path}`);
}

// FlightBridge stays on the Render API (its engine runs there). Its calls go to Render unchanged,
// carrying the Supabase session token, which Render verifies (CRM/backend/supabase_jwt.py).
export const isRenderPassthrough = (path) => path.startsWith('/api/flightbridge/');

export async function withSupabaseAuth(init = {}) {
  const { data } = supabase ? await supabase.auth.getSession() : { data: {} };
  const token = data?.session?.access_token;
  const headers = new Headers(init.headers || {});
  if (token) headers.set('Authorization', `Bearer ${token}`);
  return { ...init, headers };
}

// Clear the Supabase session too when the app logs out (App removes 'token').
export async function signOutSupabase() {
  if (supabase) await supabase.auth.signOut().catch(() => {});
}
