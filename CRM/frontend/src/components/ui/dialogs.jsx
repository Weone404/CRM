// In-app replacements for the browser's confirm(), alert() and prompt() boxes, in the same window style as the rest of
// the CRM: a small centred window (a bottom sheet on phones) that closes on Esc or a tap outside (= Cancel).
//   if (!(await confirmDialog('Delete this?', { danger: true, confirmText: 'Delete' }))) return;
//   await alertDialog('Saved');
//   const reason = await promptDialog('Abort reason', { required: true });         // null when cancelled
//   const pick = await choiceDialog('Leave type', [{ value: 'leave', label: 'Leave', hint: '…' }, …]);  // null when cancelled
import { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import Icon from '../icons';
import { modalProps } from './overlay';

function mount(render) {
  return new Promise((resolve) => {
    const host = document.createElement('div');
    document.body.appendChild(host);
    const root = createRoot(host);
    const done = (value) => { resolve(value); setTimeout(() => { root.unmount(); host.remove(); }, 0); };
    root.render(render(done));
  });
}

function Shell({ title, message, icon, tone, onCancel, children }) {
  return (
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-[100]" {...modalProps(onCancel)}>
      <div className="glass-strong w-full max-w-sm p-5 animate-glass-in" role="alertdialog" aria-modal="true" aria-labelledby="ui-dialog-title">
        <div className="flex items-start gap-3">
          {icon && <span className="mt-0.5 shrink-0" style={{ color: tone }}><Icon name={icon} size={24} /></span>}
          <div className="min-w-0 flex-1">
            {title && <h2 id="ui-dialog-title" className="text-[17px] font-semibold text-glass-primary">{title}</h2>}
            {message && <p className="text-sm text-glass-secondary mt-1 whitespace-pre-line">{message}</p>}
          </div>
        </div>
        {children}
      </div>
    </div>
  );
}

const btn = 'px-4 py-2.5 rounded-xl text-sm font-semibold transition';
const cancelBtn = `${btn} text-glass-primary`;
const cancelStyle = { background: 'rgba(118,118,128,0.14)' };

export function confirmDialog(message, { title, confirmText = 'OK', cancelText = 'Cancel', danger = false } = {}) {
  const head = title || (message.length <= 70 ? message : null);
  const body = head === message ? null : message;
  return mount((done) => (
    <Shell title={head || 'Please confirm'} message={body} icon={danger ? 'alert' : null} tone="#FF3B30" onCancel={() => done(false)}>
      <div className="grid grid-cols-2 gap-2 mt-5">
        <button autoFocus={danger} className={cancelBtn} style={cancelStyle} onClick={() => done(false)}>{cancelText}</button>
        <button autoFocus={!danger} className={`${btn} text-white`} style={{ background: danger ? '#FF3B30' : '#007AFF' }} onClick={() => done(true)}>{confirmText}</button>
      </div>
    </Shell>
  ));
}

export function alertDialog(message, { title, tone = 'info' } = {}) {
  const icon = { info: null, error: 'xCircle', success: 'checkCircle', warning: 'alert' }[tone];
  const color = { error: '#FF3B30', success: '#34C759', warning: '#FF9500' }[tone];
  return mount((done) => (
    <Shell title={title || message} message={title ? message : null} icon={icon} tone={color} onCancel={() => done()}>
      <button autoFocus className={`${btn} text-white w-full mt-5`} style={{ background: '#007AFF' }} onClick={() => done()}>OK</button>
    </Shell>
  ));
}

function PromptBody({ done, label, placeholder, required, confirmText, multiline }) {
  const [v, setV] = useState('');
  const ref = useRef(null);
  useEffect(() => { ref.current?.focus(); }, []);
  const ok = !required || v.trim().length > 0;
  const Field = multiline ? 'textarea' : 'input';
  return (
    <form className="mt-4 space-y-4" onSubmit={(e) => { e.preventDefault(); if (ok) done(v.trim()); }}>
      <Field ref={ref} rows={multiline ? 3 : undefined} className="glass-input w-full px-3 py-2.5 text-sm" placeholder={placeholder || label}
        value={v} onChange={(e) => setV(e.target.value)} aria-label={label} />
      <div className="grid grid-cols-2 gap-2">
        <button type="button" className={cancelBtn} style={cancelStyle} onClick={() => done(null)}>Cancel</button>
        <button type="submit" disabled={!ok} className={`${btn} text-white disabled:opacity-40`} style={{ background: '#007AFF' }}>{confirmText}</button>
      </div>
    </form>
  );
}

export function promptDialog(title, { message, placeholder, required = false, confirmText = 'OK', multiline = false } = {}) {
  return mount((done) => (
    <Shell title={title} message={message} onCancel={() => done(null)}>
      <PromptBody done={done} label={title} placeholder={placeholder} required={required} confirmText={confirmText} multiline={multiline} />
    </Shell>
  ));
}

export function choiceDialog(title, options, { message } = {}) {
  return mount((done) => (
    <Shell title={title} message={message} onCancel={() => done(null)}>
      <div className="mt-4 space-y-2">
        {options.map((o, i) => (
          <button key={o.value} autoFocus={i === 0} disabled={o.disabled} onClick={() => done(o.value)}
            className="w-full text-left px-4 py-3 rounded-xl transition hover:bg-blue-50 disabled:opacity-40 disabled:hover:bg-transparent"
            style={{ background: 'rgba(118,118,128,0.08)' }}>
            <span className="block text-sm font-semibold text-glass-primary">{o.label}</span>
            {o.hint && <span className="block text-xs text-glass-muted mt-0.5">{o.hint}</span>}
          </button>
        ))}
        <button className={`${cancelBtn} w-full`} style={cancelStyle} onClick={() => done(null)}>Cancel</button>
      </div>
    </Shell>
  ));
}
