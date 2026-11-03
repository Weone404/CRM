// Students module + student portal on Supabase (same responses as the Render API).
// Documents live in the private Storage bucket `student-documents` under
// students/<student id>/; the database row is registered through Postgres functions.
import { supabase } from './supabaseClient';
import { json, detail, call, rpc, authFunction, UUID } from './http';

const BUCKET = 'student-documents';
const MAX_BYTES = 10 * 1024 * 1024;

// --- Image checks (port of _process_image): real type from the file's bytes -----------
async function sniff(file) {
  const head = new Uint8Array(await file.slice(0, 16).arrayBuffer());
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'JPEG';
  if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) return 'PNG';
  const box = String.fromCharCode(...head.slice(4, 8));
  const brand = String.fromCharCode(...head.slice(8, 12));
  if (box === 'ftyp' && /^(heic|heix|hevc|hevx|heim|heis|mif1|msf1)$/.test(brand)) return 'HEIF';
  return null;
}

async function decodable(blob) {
  try { const bmp = await createImageBitmap(blob); bmp.close?.(); return true; } catch { return false; }
}

// Returns { blob, mime, ext } or a Response with the same 400 messages as the old backend.
async function processImage(file) {
  if (!(file instanceof Blob)) return detail(400, 'Unreadable or invalid image file');
  if (file.size > MAX_BYTES) return detail(400, 'File exceeds 10MB limit');
  const kind = await sniff(file);
  if (!kind) return detail(400, 'Unsupported file type. Allowed: JPEG, PNG, HEIF, HEIC');
  if (kind === 'HEIF') {
    try {
      const { default: heic2any } = await import('heic2any');
      const out = await heic2any({ blob: file, toType: 'image/jpeg', quality: 0.9 });
      const jpeg = Array.isArray(out) ? out[0] : out;
      if (jpeg.size > MAX_BYTES) return detail(400, 'File exceeds 10MB limit');
      return { blob: jpeg, mime: 'image/jpeg', ext: 'jpg' };
    } catch {
      return detail(400, 'Unreadable or invalid image file');
    }
  }
  if (!(await decodable(file))) return detail(400, 'Unreadable or invalid image file');
  return kind === 'PNG' ? { blob: file, mime: 'image/png', ext: 'png' } : { blob: file, mime: 'image/jpeg', ext: 'jpg' };
}

// Upload -> register -> remove the replaced file. Rolls the upload back if registering fails.
async function uploadDocument({ studentId, form, register }) {
  const docType = form?.get?.('doc_type');
  const file = form?.get?.('file');
  if (!docType) return detail(400, 'doc_type is required');
  const img = await processImage(file);
  if (img instanceof Response) return img;
  const path = `students/${studentId}/${docType}-${Date.now()}.${img.ext}`;
  const up = await supabase.storage.from(BUCKET).upload(path, img.blob, { contentType: img.mime, upsert: false });
  if (up.error) return detail(502, `Upload failed: ${up.error.message}`);
  const r = await register(path, file.name || `${docType}.${img.ext}`, img.mime, img.blob.size);
  if (r.error) {
    await supabase.storage.from(BUCKET).remove([path]).catch(() => {});
    return r.error;
  }
  if (r.data?.old_path) await supabase.storage.from(BUCKET).remove([r.data.old_path]).catch(() => {});
  return json(200, { status: 'uploaded', id: r.data.id, doc_type: r.data.doc_type });
}

async function signedUrl(path) {
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, 300);
  if (error) return detail(502, `Could not open the document: ${error.message}`);
  return json(200, { url: data.signedUrl, expires_in: 300 });
}

// --- Routes ------------------------------------------------------------------------------
export const STUDENT_ROUTES = [
  ['GET', /^\/api\/students$/, ({ query }) => rpc('api_students_list', { p_search: query?.get('search') || '' })],
  ['GET', /^\/api\/students\/prefill-leads$/, () => rpc('api_students_prefill_leads')],
  ['GET', new RegExp(`^/api/students/${UUID}$`), ({ params }) => rpc('api_student_get', { p_id: params[0] })],

  ['POST', /^\/api\/students$/, async ({ body }) => {
    const r = await call('api_student_create', { p_data: body || {} });
    if (r.error) return r.error;
    // Give the new student a login (password = their mobile number). Never blocks the save.
    if (r.data?.status === 'created') await authFunction({ action: 'provision' }).catch(() => {});
    return json(200, r.data);
  }],
  ['PATCH', new RegExp(`^/api/students/${UUID}$`), ({ params, body }) => rpc('api_student_update', { p_id: params[0], p_data: body || {} })],

  ['DELETE', new RegExp(`^/api/students/${UUID}$`), async ({ params }) => {
    const id = params[0];
    // Same order as before: remove every stored file first, verify, then the rows.
    const folder = `students/${id}`;
    const list = await supabase.storage.from(BUCKET).list(folder, { limit: 1000 });
    if (list.error) return detail(502, `Storage delete failed, aborted; no rows removed: ${list.error.message}`);
    const paths = (list.data || []).filter((o) => o.name && o.id).map((o) => `${folder}/${o.name}`);
    if (paths.length) {
      const rm = await supabase.storage.from(BUCKET).remove(paths);
      if (rm.error) return detail(502, `Storage delete failed, aborted; no rows removed: ${rm.error.message}`);
    }
    return rpc('api_student_delete', { p_id: id });
  }],

  ['POST', new RegExp(`^/api/students/${UUID}/documents$`), ({ params, form }) => uploadDocument({
    studentId: params[0],
    form,
    register: (path, filename, mime, size) => call('api_student_doc_register', {
      p_student_id: params[0], p_doc_type: form.get('doc_type'), p_path: path, p_filename: filename, p_mime: mime, p_size: size,
    }),
  })],
  ['GET', new RegExp(`^/api/students/${UUID}/documents/${UUID}/url$`), async ({ params }) => {
    const r = await call('api_student_doc_path', { p_student_id: params[0], p_doc_id: params[1], p_action: 'view' });
    return r.error || signedUrl(r.data.path);
  }],
  ['DELETE', new RegExp(`^/api/students/${UUID}/documents/${UUID}$`), async ({ params }) => {
    const r = await call('api_student_doc_path', { p_student_id: params[0], p_doc_id: params[1], p_action: 'delete' });
    if (r.error) return r.error;
    await supabase.storage.from(BUCKET).remove([r.data.path]).catch(() => {});
    return json(200, { status: 'deleted' });
  }],

  // Student login settings (Admin): on/off switch, and "reset password to mobile number".
  ['POST', new RegExp(`^/api/students/${UUID}/set-pin$`), async ({ params, body }) => {
    const b = body || {};
    const reset = Boolean(b.reset_password || b.pin);
    if (b.login_enabled === undefined && !reset) return detail(400, 'Provide a pin and/or login_enabled');
    const r = await call('api_student_set_login', {
      p_student_id: params[0], p_login_enabled: b.login_enabled ?? null, p_password_reset: reset,
    });
    if (r.error) return r.error;
    if (reset) {
      await authFunction({ action: 'provision' }).catch(() => {}); // creates the login if missing
      const res = await authFunction({ action: 'reset_password', person_type: 'student', person_id: params[0] });
      if (!res.ok) return detail(res.status, res.body.error || 'Password reset failed');
    }
    return json(200, { status: 'updated' });
  }],

  // Student self-service portal
  ['GET', /^\/api\/student\/me$/, () => rpc('api_student_me')],
  ['PATCH', /^\/api\/student\/me$/, ({ body }) => rpc('api_student_update_me', { p_data: body || {} })],
  ['GET', /^\/api\/student\/me\/documents$/, () => rpc('api_student_my_documents')],
  ['GET', new RegExp(`^/api/student/me/documents/${UUID}/url$`), async ({ params }) => {
    const r = await call('api_student_my_doc_path', { p_doc_id: params[0] });
    return r.error || signedUrl(r.data.path);
  }],
  ['POST', /^\/api\/student\/me\/documents$/, async ({ form }) => {
    const me = await call('api_student_me');
    if (me.error) return me.error;
    return uploadDocument({
      studentId: me.data.id,
      form,
      register: (path, filename, mime, size) => call('api_student_my_doc_register', {
        p_doc_type: form.get('doc_type'), p_path: path, p_filename: filename, p_mime: mime, p_size: size,
      }),
    });
  }],
];
