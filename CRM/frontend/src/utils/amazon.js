// Small pure helpers for the Amazon section (unit-tested in supabase/tests/amazon).
// The database re-checks everything (amazon_rules); these only give instant feedback while typing.

export const utf8Bytes = (s) => new TextEncoder().encode(s || '').length;
export const chars = (s) => [...(s || '')].length;

export const inr = (n) => (n == null || n === '' ? '—' : `₹${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`);
export const pct = (n) => (n == null ? '—' : `${Number(n).toFixed(2)}%`);

// Fields shown in diffs, in this order, with labels.
export const FIELD_LABELS = {
  title: 'Title', item_highlights: 'Item Highlights', bullets: 'Bullet points', description: 'Description',
  backend_terms: 'Backend search terms', price: 'Price', mrp: 'MRP', country_of_origin: 'Country of origin',
  manufacturer: 'Manufacturer', net_quantity: 'Net quantity', main_image: 'Main image', claims: 'Claims',
  daily_budget_total: 'Total daily ad budget',
};

const show = (k, v) => {
  if (v == null || v === '') return '—';
  if (k === 'price' || k === 'mrp' || k === 'daily_budget_total') return inr(v);
  if (Array.isArray(v)) return v.join('\n');
  if (typeof v === 'object') return v.url || `${v.width || '?'}×${v.height || '?'} px`;
  return String(v);
};

// [{key, label, before, after, changed}] for the keys a change touches.
export function diffRows(before = {}, after = {}) {
  return Object.keys(after).filter((k) => k in FIELD_LABELS).map((k) => {
    const b = show(k, before?.[k]); const a = show(k, after[k]);
    return { key: k, label: FIELD_LABELS[k], before: b, after: a, changed: b !== a };
  });
}

// Reads an image file in the browser: size, whether the border is pure white (255,255,255).
// "No text / logo" cannot be detected reliably, so the person confirms it.
export async function measureImage(file) {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise((ok, bad) => { const i = new Image(); i.onload = () => ok(i); i.onerror = bad; i.src = url; });
    const w = img.naturalWidth; const h = img.naturalHeight;
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const ctx = c.getContext('2d', { willReadFrequently: true }); ctx.drawImage(img, 0, 0);
    return { width: w, height: h, white_bg: borderIsWhite(ctx.getImageData(0, 0, w, h).data, w, h) };
  } finally { URL.revokeObjectURL(url); }
}

// Every pixel of a 4-px frame around the edge must be exactly 255,255,255 (alpha 255).
export function borderIsWhite(data, w, h, frame = 4) {
  const white = (x, y) => { const i = (y * w + x) * 4; return data[i] === 255 && data[i + 1] === 255 && data[i + 2] === 255 && data[i + 3] === 255; };
  for (let y = 0; y < h; y++) {
    const edgeRow = y < frame || y >= h - frame;
    for (let x = 0; x < w; x++) {
      if (!edgeRow && x >= frame && x < w - frame) { x = w - frame - 1; continue; }
      if (!white(x, y)) return false;
    }
  }
  return true;
}

export const STATUS_STYLE = {
  pending: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00', label: 'Waiting for approval' },
  approved: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC', label: 'Approved' },
  executing: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC', label: 'Sending to Amazon' },
  live: { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34', label: 'Live' },
  rejected: { bg: 'rgba(118,118,128,0.14)', fg: '#555', label: 'Rejected' },
  stale: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00', label: 'Stale — listing changed' },
  failed: { bg: 'rgba(255,59,48,0.12)', fg: '#C4261D', label: 'Failed' },
  needs_manual: { bg: 'rgba(175,82,222,0.12)', fg: '#7A2EA8', label: 'Needs a manual step' },
  cancelled: { bg: 'rgba(118,118,128,0.14)', fg: '#555', label: 'Cancelled' },
};

export const ageText = (ts) => {
  if (!ts) return 'never';
  const m = Math.round((Date.now() - new Date(ts).getTime()) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
};
