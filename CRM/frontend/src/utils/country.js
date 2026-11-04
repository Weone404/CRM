// Country name from its 2-letter code, for any country (the world sweep covers every one).
let names = null;
try { names = new Intl.DisplayNames(['en'], { type: 'region' }); } catch { names = null; }
const FIX = { GB: 'United Kingdom', US: 'United States' };

export function countryName(code) {
  if (!code) return '';
  const c = String(code).toUpperCase();
  if (FIX[c]) return FIX[c];
  try { return (names && names.of(c)) || c; } catch { return c; }
}

export function timeAgo(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}
