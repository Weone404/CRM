// CSV reading for uploads (same rules as supabase/functions/_shared/website.ts parseCsv / copilotRows).
export function parseCsv(text) {
  const rows = []; let row = [], cell = '', q = false;
  const s = String(text ?? '').replace(/^﻿/, '');
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; continue; }
    if (c === '"') q = true; else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && s[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((x) => x.trim()));
}
// Bing Webmaster Tools > AI Performance export: grounding queries or pages, with their citations.
export function copilotRows(text) {
  const [head = [], ...body] = parseCsv(text);
  const cols = head.map((h) => h.trim().toLowerCase());
  const kCol = cols.findIndex((c) => /grounding|query|page|url/.test(c));
  const nCol = cols.findIndex((c) => /citation/.test(c) && !/share|unique|page/.test(c));
  const kind = /page|url/.test(cols[kCol] ?? '') && !/query/.test(cols[kCol] ?? '') ? 'page' : 'query';
  if (kCol < 0) return { kind, rows: [] };
  const n = (v) => Number(String(v ?? '').replace(/[^0-9.]/g, '')) || 0;
  return { kind, rows: body.map((r) => ({ k: String(r[kCol] ?? '').trim().slice(0, 400), citations: nCol >= 0 ? n(r[nCol]) : 0 })).filter((r) => r.k).slice(0, 5000) };
}
