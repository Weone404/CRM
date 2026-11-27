// WhatsApp section: data helpers and the small pieces every WhatsApp screen shares.
// Data: api_wa_* functions (migration 150) through adsKit's rpc (time limit, friendly errors) and the wa-admin Edge Function.
import { useEffect, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../../backend/supabaseClient';
import { showToast } from '../../utils/toast';
import Icon from '../icons';
export { rpc, run, useLoad, Btn, Spinner } from '../adsKit';

export async function admin(action, body = {}) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/wa-admin`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify({ action, ...body }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || (res.status === 404 ? 'The WhatsApp service is not deployed yet (wa-admin)' : `Request failed (${res.status})`));
  return out;
}

export const SOURCE = { website: 'Website', meta_form: 'Meta form', google: 'Google', charter: 'Book My Charter', justdial: 'JustDial',
  whatsapp_inbound: 'Wrote to us', ctwa: 'WhatsApp ad', test: 'Test', other: 'Other', messaged_us: 'Wrote to us' };
export const BRAND = { aviation: 'We One Aviation', charter: 'Book My Charter' };

export function ago(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 7 * 86400) return `${Math.floor(s / 86400)}d`;
  return new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });
}
export const clock = (iso) => (iso ? new Date(iso).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' }) : '');
export const day = (iso) => (iso ? new Date(iso).toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short' }) : '');
export const phoneOf = (c) => (c?.phone10 ? `${c.phone10.slice(0, 5)} ${c.phone10.slice(5)}` : c?.wa_id ? `+${c.wa_id}` : '');

export function Pill({ tone = 'gray', children, title }) {
  const t = { green: ['rgba(52,199,89,0.14)', '#1E8E3E'], blue: ['rgba(0,122,255,0.12)', '#0A63CE'], orange: ['rgba(255,149,0,0.16)', '#B25E00'],
    red: ['rgba(255,59,48,0.12)', '#C4291F'], gray: ['rgba(118,118,128,0.12)', '#3C3C43'], purple: ['rgba(175,82,222,0.14)', '#8E3BB8'] }[tone] || [];
  return <span title={title} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: t[0], color: t[1] }}>{children}</span>;
}

export const STATUS = { bot: ['Bot', 'blue'], human: ['Needs a person', 'orange'], closed: ['Closed', 'gray'] };

export function Ticks({ status }) {
  if (status === 'failed') return <span title="Not delivered" style={{ color: '#FF3B30' }}><Icon name="alert" size={13} /></span>;
  if (status === 'read') return <span title="Read" className="text-[12px] font-bold" style={{ color: '#34B7F1' }}>✓✓</span>;
  if (status === 'delivered') return <span title="Delivered" className="text-[12px] font-bold text-glass-secondary">✓✓</span>;
  if (status === 'sent') return <span title="Sent" className="text-[12px] font-bold text-glass-secondary">✓</span>;
  return <span title="Sending" className="text-glass-secondary"><Icon name="clock" size={12} /></span>;
}

export function Copy({ value, label = 'Copy' }) {
  return (
    <button type="button" className="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-lg text-xs font-semibold shrink-0"
      style={{ background: 'rgba(0,122,255,0.1)', color: '#007AFF' }}
      onClick={() => navigator.clipboard?.writeText(String(value || '')).then(() => showToast('Copied', 'success'), () => showToast('Could not copy', 'error'))}>
      <Icon name="copy" size={13} />{label}
    </button>
  );
}

export function CopyRow({ label, value, mono = true }) {
  return (
    <div className="flex items-center gap-2 rounded-xl px-3 py-2" style={{ background: 'rgba(118,118,128,0.08)' }}>
      <div className="min-w-0 flex-1">
        <div className="text-[11px] font-semibold uppercase tracking-wide text-glass-secondary">{label}</div>
        <div className={`text-sm text-glass-primary break-all ${mono ? 'font-mono' : ''}`}>{value || '—'}</div>
      </div>
      {value ? <Copy value={value} /> : null}
    </div>
  );
}

export function Empty({ icon = 'inbox', title, children }) {
  return (
    <div className="text-center py-10 px-4">
      <div className="mx-auto h-12 w-12 rounded-2xl inline-flex items-center justify-center mb-3" style={{ background: 'rgba(0,122,255,0.1)', color: '#007AFF' }}>
        <Icon name={icon} size={22} />
      </div>
      <div className="font-semibold text-glass-primary">{title}</div>
      {children && <div className="text-sm text-glass-secondary mt-1 max-w-md mx-auto">{children}</div>}
    </div>
  );
}

export function ErrorBox({ error, onRetry }) {
  if (!error) return null;
  return (
    <div className="rounded-xl p-3 text-sm flex items-center gap-2" style={{ background: 'rgba(255,59,48,0.08)', color: '#C4291F' }}>
      <Icon name="alert" size={16} /><span className="flex-1">{error}</span>
      {onRetry && <button type="button" onClick={onRetry} className="font-semibold underline">Try again</button>}
    </div>
  );
}

// Collapsed details (the CRM's "deep details hidden until opened" rule).
export function More({ title, children, defaultOpen = false }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="rounded-xl" style={{ background: 'rgba(118,118,128,0.06)' }}>
      <button type="button" onClick={() => setOpen(!open)} aria-expanded={open}
        className="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-sm font-semibold text-glass-primary">
        {title}<span style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .2s' }}><Icon name="chevronDown" size={16} /></span>
      </button>
      {open && <div className="px-3 pb-3">{children}</div>}
    </div>
  );
}

export function Field({ label, hint, children }) {
  return (
    <label className="block">
      <span className="block text-[13px] font-semibold text-glass-primary mb-1">{label}</span>
      {children}
      {hint && <span className="block text-xs text-glass-secondary mt-1">{hint}</span>}
    </label>
  );
}

// Re-render every 30 s (relative times, the 24-hour window timer).
export function useTick(ms = 30000) {
  const [, set] = useState(0);
  useEffect(() => { const t = setInterval(() => set((x) => x + 1), ms); return () => clearInterval(t); }, [ms]);
}
