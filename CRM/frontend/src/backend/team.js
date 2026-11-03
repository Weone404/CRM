// Tasks + Team (employee directory, profiles, leave calendar) on Supabase.
// Same status codes and JSON shapes as the Render endpoints.
import { json, detail, call, rpc, authFunction, UUID } from './http';

const DATE = '(\\d{4}-\\d{2}-\\d{2})';

export const TEAM_ROUTES = [
  // Tasks
  ['GET', /^\/api\/tasks$/, () => rpc('api_tasks')],
  ['POST', /^\/api\/tasks$/, ({ body }) => rpc('api_task_create', { p_data: body || {} })],
  ['PATCH', new RegExp(`^/api/tasks/${UUID}$`), ({ params, body }) => rpc('api_task_update', { p_id: params[0], p_data: body || {} })],
  ['DELETE', new RegExp(`^/api/tasks/${UUID}$`), ({ params }) => rpc('api_task_delete', { p_id: params[0] })],
  ['GET', new RegExp(`^/api/tasks/${UUID}/comments$`), ({ params }) => rpc('api_task_comments', { p_id: params[0] })],
  ['POST', new RegExp(`^/api/tasks/${UUID}/comments$`), ({ params, body }) => rpc('api_task_comment_add', { p_id: params[0], p_data: body || {} })],

  // Employee directory and profiles
  ['GET', /^\/api\/employees$/, () => rpc('api_employees')],
  ['GET', new RegExp(`^/api/employees/${UUID}$`), ({ params }) => rpc('api_employee_get', { p_id: params[0] })],
  ['POST', /^\/api\/employees$/, async ({ body }) => {
    const r = await call('api_employee_create', { p_data: body || {} });
    if (r.error) return r.error;
    // Create their login right away (first password = their mobile number). Never blocks the save.
    await authFunction({ action: 'provision' }).catch(() => {});
    return json(200, r.data);
  }],
  ['PATCH', new RegExp(`^/api/employees/${UUID}$`), ({ params, body }) => rpc('api_employee_update', { p_id: params[0], p_data: body || {} })],

  // Admin: set an employee's password back to their mobile number
  ['POST', new RegExp(`^/api/employees/${UUID}/reset-password$`), async ({ params }) => {
    await authFunction({ action: 'provision' }).catch(() => {}); // creates the login first if it is missing
    const res = await authFunction({ action: 'reset_password', person_type: 'employee', person_id: params[0] });
    if (!res.ok) return detail(res.status, res.body.error || 'Password reset failed');
    return json(200, { status: 'reset' });
  }],

  // Leave calendar
  ['POST', new RegExp(`^/api/employees/${UUID}/leave$`), ({ params, body }) => rpc('api_leave_mark', { p_id: params[0], p_data: body || {} })],
  ['DELETE', new RegExp(`^/api/employees/${UUID}/leave/${DATE}$`), ({ params }) => rpc('api_leave_unmark', { p_id: params[0], p_date: params[1] })],
];
