// Pure helpers for CRM > ADS (no React), unit-tested in supabase/tests/ads/ads_utils.test.mjs.

export const PERIODS = [
  ['today', 'Today'], ['yesterday', 'Yesterday'], ['7d', 'Last 7 days'], ['14d', 'Last 14 days'], ['30d', 'Last 30 days'],
  ['90d', 'Last 90 days'], ['month', 'This month'], ['prev_month', 'Previous month'], ['custom', 'Custom'],
];

const iso = (d) => d.toISOString().slice(0, 10);
const addDays = (s, n) => iso(new Date(Date.parse(`${s}T00:00:00Z`) + n * 86400000));

// Today's date in a time zone, as YYYY-MM-DD.
export function todayIn(tz = 'Asia/Kolkata', now = new Date()) {
  try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now); }
  catch { return iso(now); }
}

// A named period -> {from, to}. "Last N days" includes today.
export function periodRange(key, today, custom = {}) {
  const [y, m] = today.split('-').map(Number);
  switch (key) {
    case 'today': return { from: today, to: today };
    case 'yesterday': { const d = addDays(today, -1); return { from: d, to: d }; }
    case '7d': return { from: addDays(today, -6), to: today };
    case '14d': return { from: addDays(today, -13), to: today };
    case '90d': return { from: addDays(today, -89), to: today };
    case 'month': return { from: `${today.slice(0, 7)}-01`, to: today };
    case 'prev_month': {
      const first = iso(new Date(Date.UTC(y, m - 2, 1)));
      const last = iso(new Date(Date.UTC(y, m - 1, 0)));
      return { from: first, to: last };
    }
    case 'custom': {
      const ok = /^\d{4}-\d{2}-\d{2}$/;
      if (ok.test(custom.from || '') && ok.test(custom.to || '') && custom.from <= custom.to) return { from: custom.from, to: custom.to };
      return { from: addDays(today, -29), to: today };
    }
    default: return { from: addDays(today, -29), to: today };
  }
}

export const isNum = (v) => v !== null && v !== undefined && v !== '' && Number.isFinite(Number(v));

// Money in the given currency. Missing values are "—", never 0.
export function money(v, currency = 'INR', digits) {
  if (!isNum(v)) return '—';
  const n = Number(v);
  const d = digits ?? (Math.abs(n) >= 1000 ? 0 : 2);
  try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency, maximumFractionDigits: d, minimumFractionDigits: 0 }).format(n); }
  catch { return `${currency} ${n.toFixed(d)}`; }
}
export const int = (v) => (isNum(v) ? new Intl.NumberFormat('en-IN', { maximumFractionDigits: 1 }).format(Number(v)) : '—');
export const pct = (v, d = 2) => (isNum(v) ? `${Number(v).toFixed(d)}%` : '—');
export const ratio = (v) => (isNum(v) ? `${Number(v).toFixed(2)}×` : '—');

// % change vs previous period. null when either side is missing or the previous value is 0.
export function delta(cur, prev) {
  if (!isNum(cur) || !isNum(prev) || Number(prev) === 0) return null;
  return ((Number(cur) - Number(prev)) / Math.abs(Number(prev))) * 100;
}

// For a delta, is "up" good? Costs going up are bad.
export const LOWER_IS_BETTER = new Set(['spend', 'cpl', 'qualified_cpl', 'cac', 'cpc', 'cpm']);

export function toCsv(rows, cols) {
  const esc = (v) => {
    if (v === null || v === undefined) return '';
    const s = String(v);
    const safe = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;           // block spreadsheet formula injection
    return /[",\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
  };
  return [cols.map((c) => esc(c[1])).join(','), ...rows.map((r) => cols.map((c) => esc(typeof c[0] === 'function' ? c[0](r) : r[c[0]])).join(','))].join('\n');
}

export const STATUS_LABEL = {
  connected: ['Connected', '#1E7B34', 'rgba(52,199,89,0.14)'],
  not_synced: ['Not checked yet', '#6E6E73', 'rgba(118,118,128,0.14)'],
  auth_required: ['Sign-in needed', '#C4261D', 'rgba(255,59,48,0.12)'],
  permission_missing: ['Permission missing', '#C4261D', 'rgba(255,59,48,0.12)'],
  rate_limited: ['Rate limited', '#B25E00', 'rgba(255,149,0,0.14)'],
  sync_failed: ['Sync failed', '#C4261D', 'rgba(255,59,48,0.12)'],
  unavailable: ['Temporarily unavailable', '#B25E00', 'rgba(255,149,0,0.14)'],
  disabled: ['Disabled', '#6E6E73', 'rgba(118,118,128,0.14)'],
};
