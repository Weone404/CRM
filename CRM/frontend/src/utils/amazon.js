// Small pure helpers for the Amazon section (unit-tested in supabase/tests/amazon).
// The database re-checks everything (amazon_rules); these only give instant feedback while typing.

export const utf8Bytes = (s) => new TextEncoder().encode(s || '').length;
export const chars = (s) => [...(s || '')].length;

export const inr = (n) => (n == null || n === '' ? '—' : `₹${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`);
export const pct = (n) => (n == null ? '—' : `${Number(n).toFixed(2)}%`);

// Fields shown in diffs, in this order, with labels.
export const FIELD_LABELS = {
  title: 'Product name', item_highlights: 'Short highlight', bullets: 'Key points', description: 'Description',
  backend_terms: 'Hidden search words', price: 'Price', mrp: 'MRP', country_of_origin: 'Made in (country)',
  manufacturer: 'Maker name & address', net_quantity: 'Quantity in the box', main_image: 'Main photo', claims: 'Claims',
  daily_budget_total: 'Daily ad budget (all ads)', handling_days: 'Dispatch time',
};

// Dispatch (handling) time in plain words. 0 = same day, 1 = next day.
export const dispatchText = (d) => (d == null || d === '' ? 'Not known yet'
  : Number(d) === 0 ? 'Same day' : Number(d) === 1 ? 'Next day' : `${d} days`);

// Audit rule codes in plain words: what is wrong, and what to do.
export const PLAIN = {
  title_max_chars: ['Product name is too long', 'Amazon allows 75 letters. Shorten it.'],
  title_word_repeat: ['Product name repeats a word', 'Use each word at most twice.'],
  title_promo_words: ['Product name has sales words', 'Remove words like "best", "sale", "free".'],
  title_special_chars: ['Product name has odd symbols', 'Remove symbols like !, *, $.'],
  stale_year: ['Product name shows an old year', 'Update the year, e.g. 2027.'],
  title_drift: ['Product name was changed outside the CRM', 'Check it is still right.'],
  buybox_lost: ['Another seller is winning the "Add to Cart" button', 'Check the price (never below ₹299).'],
  buybox_none: ['Nobody has the "Add to Cart" button', 'Check price, stock and dispatch time.'],
  legal_fields: ['Required details missing', 'Add MRP, maker, country and quantity.'],
  highlights_max_chars: ['Short highlight is too long', 'Keep it under 125 letters.'],
  backend_terms_bytes: ['Hidden search words are too long', 'Remove some words.'],
  backend_no_emoji: ['Hidden search words have emoji', 'Remove the emoji.'],
  main_image: ['Main photo breaks Amazon rules', 'White background, no text, at least 1000 px.'],
  suppressed_after_change: ['Product is hidden on Amazon after a change', 'Approve the undo in Approve Changes.'],
  price_floor: ['Price is below ₹299', 'Raise the price.'],
  mrp_gte_price: ['MRP is lower than the price', 'MRP must be equal or higher.'],
};
export const plain = (code, fallback) => PLAIN[code] || [fallback || 'Needs a look', ''];

const show = (k, v) => {
  if (k === 'handling_days') return dispatchText(v);
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
  pending: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00', label: 'Waiting for your OK' },
  approved: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC', label: 'Approved' },
  executing: { bg: 'rgba(0,122,255,0.12)', fg: '#0062CC', label: 'Sending to Amazon' },
  live: { bg: 'rgba(52,199,89,0.14)', fg: '#1E7B34', label: 'Live on Amazon' },
  rejected: { bg: 'rgba(118,118,128,0.14)', fg: '#555', label: 'Rejected' },
  stale: { bg: 'rgba(255,149,0,0.14)', fg: '#B25E00', label: 'Out of date' },
  failed: { bg: 'rgba(255,59,48,0.12)', fg: '#C4261D', label: 'Amazon said no' },
  needs_manual: { bg: 'rgba(175,82,222,0.12)', fg: '#7A2EA8', label: 'One step left for you' },
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
