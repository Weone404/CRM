// One-tap contact buttons for a person: Call, WhatsApp, Email, Copy number. Buttons without data are left out.
import Icon from '../icons';
import { showToast } from '../../utils/toast';

const WA = <path d="M20.5 3.5A11.8 11.8 0 0 0 1.9 17.7L.5 23.5l6-1.6A11.8 11.8 0 0 0 20.5 3.5Zm-8.6 18.1c-1.8 0-3.5-.5-5-1.4l-.4-.2-3.6.9 1-3.5-.2-.4a9.8 9.8 0 1 1 8.2 4.6Zm5.4-7.3c-.3-.1-1.7-.9-2-1s-.5-.1-.7.1-.8 1-.9 1.2-.3.2-.6.1a8 8 0 0 1-4-3.5c-.3-.5.3-.5.9-1.6.1-.2 0-.4 0-.5l-.9-2.2c-.2-.6-.5-.5-.7-.5h-.6a1.1 1.1 0 0 0-.8.4 3.4 3.4 0 0 0-1 2.5 5.9 5.9 0 0 0 1.2 3.1 13.4 13.4 0 0 0 5.2 4.6c1.9.8 2.7.9 3.6.7a3.1 3.1 0 0 0 2-1.4 2.5 2.5 0 0 0 .2-1.4c-.1-.1-.3-.2-.6-.3Z" fill="currentColor" stroke="none" />;

// +91 for Indian 10-digit mobiles; anything else is used as dialled (digits only)
export function waNumber(phone) {
  const d = String(phone || '').replace(/\D/g, '').replace(/^0+/, '');
  if (!d) return '';
  return d.length === 10 ? `91${d}` : d;
}

export default function QuickActions({ phone, email, name, waText = '', className = '' }) {
  const p = String(phone || '').trim();
  const items = [
    p && { key: 'call', label: 'Call', href: `tel:${p.replace(/[^\d+]/g, '')}`, icon: <Icon name="phone" size={20} /> },
    p && waNumber(p) && { key: 'wa', label: 'WhatsApp', href: `https://wa.me/${waNumber(p)}${waText ? `?text=${encodeURIComponent(waText)}` : ''}`, ext: true, color: '#1FA855',
      icon: <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">{WA}</svg> },
    email && { key: 'mail', label: 'Email', href: `mailto:${email}`, icon: <Icon name="mail" size={20} /> },
    p && { key: 'copy', label: 'Copy', onClick: () => navigator.clipboard?.writeText(p).then(() => showToast(`${name ? `${name}’s number` : 'Number'} copied`, 'success'), () => showToast('Could not copy', 'error')), icon: <Icon name="copy" size={20} /> },
  ].filter(Boolean);
  if (!items.length) return null;
  const cols = { 1: 'grid-cols-1', 2: 'grid-cols-2', 3: 'grid-cols-3', 4: 'grid-cols-4' }[items.length];
  const cls = 'flex flex-col items-center gap-1 rounded-2xl py-3 text-[12px] font-medium transition hover:brightness-95 active:scale-[0.98]';
  const style = (c) => ({ background: 'rgba(255,255,255,0.75)', boxShadow: '0 0 0 1px rgba(0,0,0,0.06)', color: c || '#007AFF' });
  return (
    <div className={`grid gap-2 ${cols} ${className}`}>
      {items.map((it) => (it.href ? (
        <a key={it.key} href={it.href} className={cls} style={style(it.color)} {...(it.ext ? { target: '_blank', rel: 'noreferrer noopener' } : {})}>{it.icon}{it.label}</a>
      ) : (
        <button key={it.key} type="button" onClick={it.onClick} className={cls} style={style(it.color)}>{it.icon}{it.label}</button>
      )))}
    </div>
  );
}

export function CloseButton({ onClick, label = 'Close' }) {
  return <button type="button" onClick={onClick} className="fb-iconbtn shrink-0" aria-label={label} title={`${label} (Esc)`}><Icon name="close" size={18} /></button>;
}
