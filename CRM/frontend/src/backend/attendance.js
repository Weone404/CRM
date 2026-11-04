// Attendance (Hikvision terminal / CCTV) on Supabase — same responses as the Render endpoints.
// The device itself posts to the crm-attendance Edge Function, not through here.
import { rpc, UUID } from './http';

const DEVICE_ID = '([^/]+)';

export const ATTENDANCE_ROUTES = [
  ['GET', /^\/api\/attendance$/, ({ query }) => rpc('api_attendance_day', { p_date: query?.get('date') || null })],
  ['PATCH', /^\/api\/attendance\/(\d+)$/, ({ params, body }) =>
    rpc('api_attendance_override', { p_id: Number(params[0]), p_data: body || {} })],
  ['GET', /^\/api\/attendance\/device-people$/, () => rpc('api_attendance_device_people')],
  ['POST', new RegExp(`^/api/attendance/device-people/${DEVICE_ID}/map$`), ({ params, body }) =>
    rpc('api_attendance_map', { p_device_id: decodeURIComponent(params[0]), p_data: body || {} })],
  ['DELETE', new RegExp(`^/api/attendance/device-people/${DEVICE_ID}/map$`), ({ params }) =>
    rpc('api_attendance_unmap', { p_device_id: decodeURIComponent(params[0]) })],
  ['GET', /^\/api\/attendance\/monthly$/, ({ query }) => rpc('api_attendance_monthly', { p_month: query?.get('month') || null })],
  ['GET', /^\/api\/attendance\/summary$/, ({ query }) =>
    rpc('api_attendance_summary', { p_months: Number(query?.get('months')) || 12 })],
  ['GET', new RegExp(`^/api/employees/${UUID}/attendance/(\\d{4})/(\\d{1,2})$`), ({ params }) =>
    rpc('api_employee_attendance', { p_id: params[0], p_year: Number(params[1]), p_month: Number(params[2]) })],
];
