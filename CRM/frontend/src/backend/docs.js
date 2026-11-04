// Policy documents, course quotes and the Outbox PDF links on Supabase.
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './supabaseClient';
import { json, detail, call, rpc, UUID } from './http';

const MAX_DOC_BYTES = 1024 * 1024;
const SHARE_SECONDS = 30 * 24 * 3600; // a quote is valid for 30 days, so its link is too

async function uploadPolicyDoc(form) {
  const file = form?.get?.('file');
  if (!(file instanceof Blob)) return detail(400, 'Choose a file to upload');
  if (file.size > MAX_DOC_BYTES) return detail(400, 'File is too large (max 1 MB of text)');
  let content;
  try {
    content = new TextDecoder('utf-8', { fatal: true }).decode(await file.arrayBuffer());
  } catch {
    return detail(400, 'Only plain-text files (.txt, .md) can be uploaded');
  }
  return rpc('api_policy_doc_create', { p_data: { title: file.name || 'Untitled', content } });
}

async function generateQuote(body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/crm-quotes/generate`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_PUBLISHABLE_KEY,
      Authorization: `Bearer ${data.session?.access_token || ''}`,
    },
    body: JSON.stringify(body || {}),
  });
  const out = await res.json().catch(() => ({ detail: 'Could not create the quote' }));
  return json(res.status, out);
}

async function quotePdf(id) {
  const r = await call('api_quote_pdf_path', { p_id: id });
  if (r.error) return r.error;
  const { data, error } = await supabase.storage.from('quotes').download(r.data.path);
  if (error) return detail(404, 'PDF not found');
  return new Response(data, {
    status: 200,
    headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `inline; filename=quote_${id}.pdf` },
  });
}

// Outbox: same list as before, plus a 30-day link to each quote PDF that the customer can open.
async function outbox() {
  const r = await call('api_outbox');
  if (r.error) return r.error;
  const rows = r.data || [];
  const paths = rows.filter((m) => m.pdf_path).map((m) => m.pdf_path);
  if (paths.length) {
    const { data } = await supabase.storage.from('quotes').createSignedUrls(paths, SHARE_SECONDS);
    const byPath = Object.fromEntries((data || []).filter((d) => d.signedUrl).map((d) => [d.path, d.signedUrl]));
    rows.forEach((m) => { if (m.pdf_path) m.pdf_share_url = byPath[m.pdf_path] || null; });
  }
  return json(200, rows);
}

export const DOCS_ROUTES = [
  ['GET', /^\/api\/policy-docs$/, () => rpc('api_policy_docs')],
  ['POST', /^\/api\/policy-docs$/, ({ body }) => rpc('api_policy_doc_create', { p_data: body || {} })],
  ['POST', /^\/api\/policy-docs\/upload$/, ({ form }) => uploadPolicyDoc(form)],
  ['GET', /^\/api\/policy-docs\/search$/, ({ query }) => rpc('api_policy_doc_search', { p_q: query?.get('q') || '' })],

  ['POST', /^\/api\/quotes\/generate$/, ({ body }) => generateQuote(body)],
  ['GET', new RegExp(`^/api/quotes/${UUID}/pdf$`), ({ params }) => quotePdf(params[0])],
];

// Replaces the plain Outbox list route so quote rows carry their PDF link.
export const OUTBOX_ROUTE = ['GET', /^\/api\/outbox$/, () => outbox()];
