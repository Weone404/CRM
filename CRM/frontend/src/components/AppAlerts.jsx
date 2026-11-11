import { useCallback, useEffect, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { ageText } from '../utils/amazon';

// CRM-wide: install the CRM as a phone app, phone notifications, and sending alerts from the business email.
// Shown in Settings (Admin) and My Profile. Notifications need Amazon access today (Amazon is the only alert source).
const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function edge(name, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body) });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
const Chip = ({ children, style }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: 'rgba(118,118,128,0.14)', color: '#3C3C43', ...style }}>{children}</span>
);
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const RED = { background: 'rgba(255,59,48,0.12)', color: '#C4261D' };
const GREEN = { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' };

// ---------------------------------------------------------------- Settings: send alerts from the business email (HIOX)
export function BusinessEmail() {
  const [c, setC] = useState(null);
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState('');
  const load = () => rpc('api_amz_smtp', { p_cfg: null }).then((r) => setC(r)).catch(() => setC(null));
  useEffect(() => { load(); }, []);
  if (!c) return null;
  const set = (k) => (e) => setC({ ...c, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const save = async (enabled = c.enabled) => {
    setBusy('save');
    try {
      const r = await rpc('api_amz_smtp', { p_cfg: { host: c.host, port: Number(c.port), username: c.username, from_name: c.from_name || '', enabled, ...(pw ? { password: pw } : {}) } });
      setC(r); setPw(''); showToast('Email settings saved', 'success'); return true;
    } catch (e) { showToast(e.message, 'error'); return false; } finally { setBusy(''); }
  };
  const test = async () => {
    if (!(await save())) return;
    setBusy('test');
    try { const r = await edge('amazon-notify', { action: 'test_email' }); showToast(`Test email sent to ${r.to.join(', ')}. Check the inbox (and spam).`, 'success'); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(''); load(); }
  };
  const t = c.last_test;
  return (
    <div className="glass-card p-4 space-y-3">
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-bold">Send alerts from {c.username || 'your business email'}</h3>
        <label className="inline-flex items-center gap-2 text-sm font-semibold"><input type="checkbox" aria-label="Business email on" checked={!!c.enabled}
          onChange={async (e) => { const on = e.target.checked; setC({ ...c, enabled: on }); if (!(await save(on))) setC({ ...c, enabled: !on }); }} />{c.enabled ? 'On' : 'Off'}</label>
      </div>
      <div className="text-xs text-glass-secondary">Alerts are sent the moment they happen through your HIOX mail server (SSL, port 465). The password is stored encrypted and never shown again.</div>
      <div className="grid sm:grid-cols-2 gap-2">
        <label className="text-sm"><span className="font-semibold">Email address</span>
          <input aria-label="Business email address" type="email" className="glass-input w-full px-3 py-2 mt-1" value={c.username || ''} onChange={set('username')} /></label>
        <label className="text-sm"><span className="font-semibold">Email password</span>
          <input aria-label="Business email password" type="password" autoComplete="new-password" className="glass-input w-full px-3 py-2 mt-1" value={pw}
            placeholder={c.password_set ? '•••••••• saved (type to change)' : 'Password of this mailbox'} onChange={(e) => setPw(e.target.value)} /></label>
        <label className="text-sm"><span className="font-semibold">Sender name</span>
          <input aria-label="Sender name" className="glass-input w-full px-3 py-2 mt-1" maxLength={60} value={c.from_name || ''} onChange={set('from_name')} placeholder="We One CRM" /></label>
        <div className="grid grid-cols-3 gap-2">
          <label className="text-sm col-span-2"><span className="font-semibold">Mail server</span>
            <input aria-label="Mail server" className="glass-input w-full px-3 py-2 mt-1" value={c.host || ''} onChange={set('host')} /></label>
          <label className="text-sm"><span className="font-semibold">Port</span>
            <input aria-label="Mail port" inputMode="numeric" className="glass-input w-full px-3 py-2 mt-1" value={c.port || ''} onChange={set('port')} /></label>
        </div>
      </div>
      {t && <div className="text-sm flex items-start gap-2"><Chip style={t.ok ? GREEN : RED}>{t.ok ? 'Working' : 'Problem'}</Chip><span className="text-glass-secondary">{t.detail} <span className="text-glass-muted text-xs">({ageText(t.at)})</span></span></div>}
      {c.enabled && !c.ready && <div className="text-xs" style={{ color: '#B25E00' }}>Add at least one person under Alert emails below.</div>}
      <div className="flex flex-wrap gap-2">
        <button type="button" aria-label="Save email settings" className="glass-btn px-4 py-2 text-sm" disabled={!!busy} onClick={() => save()}>{busy === 'save' ? 'Saving…' : 'Save'}</button>
        <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" disabled={!!busy || (!c.password_set && !pw)} onClick={test}>{busy === 'test' ? 'Sending…' : 'Send a test email'}</button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Phone app + notifications
const b64ToBytes = (b64) => {
  const s = atob((b64 + '='.repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(s, (ch) => ch.charCodeAt(0));
};
const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isStandalone = () => window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true;
const pushSupported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
const deviceName = () => (isIOS() ? 'iPhone' : /Android/i.test(navigator.userAgent) ? 'Android phone' : /Mac/i.test(navigator.userAgent) ? 'Mac' : 'Computer');
async function currentSub() {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.getRegistration();
  return reg ? reg.pushManager.getSubscription() : null;
}
// Called when the Amazon section opens: keeps this phone's subscription fresh on the server.
export async function syncPush() {
  try {
    if (!pushSupported() || Notification.permission !== 'granted') return;
    const sub = await currentSub();
    if (sub) await rpc('api_amz_push_subscribe', { p_sub: sub.toJSON(), p_device: null });
  } catch { /* best effort */ }
}

export function PhoneApp({ notifications = true }) {
  const [st, setSt] = useState(null);
  const [busy, setBusy] = useState(false);
  const [canInstall, setCanInstall] = useState(!!window.__installPrompt);
  const load = useCallback(async () => {
    const sub = await currentSub().catch(() => null);
    const r = notifications ? await rpc('api_amz_push_status', { p_endpoint: sub?.endpoint || null }).catch(() => null) : null;
    setSt({ ...(r || {}), on: !!(sub && r?.this_device), perm: 'Notification' in window ? Notification.permission : 'unsupported' });
  }, [notifications]);
  useEffect(() => {
    load();
    const h = (e) => { window.__installPrompt = e; setCanInstall(true); };
    window.addEventListener('beforeinstallprompt', h);
    return () => window.removeEventListener('beforeinstallprompt', h);
  }, [load]);
  const turnOn = async () => {
    setBusy(true);
    try {
      if ((await Notification.requestPermission()) !== 'granted') throw new Error('Notifications are blocked. Allow them for this app in the phone settings, then try again.');
      let key = st?.vapid_public;
      if (!key) key = (await edge('amazon-notify', { action: 'init' })).vapid_public;
      const reg = (await navigator.serviceWorker.getRegistration()) || (await navigator.serviceWorker.register('/sw.js'));
      await navigator.serviceWorker.ready;
      const sub = (await reg.pushManager.getSubscription()) || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) }));
      await rpc('api_amz_push_subscribe', { p_sub: sub.toJSON(), p_device: deviceName() });
      showToast('Notifications are on for this device', 'success');
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); load(); }
  };
  const turnOff = async () => {
    setBusy(true);
    try { const sub = await currentSub(); if (sub) { await rpc('api_amz_push_unsubscribe', { p_endpoint: sub.endpoint }); await sub.unsubscribe(); } showToast('Notifications off for this device', 'success'); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); load(); }
  };
  const test = async () => {
    try { const r = await edge('amazon-notify', { action: 'test_push' }); showToast(`Test sent to ${r.devices} device(s). It should appear in a few seconds.`, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const install = async () => { const p = window.__installPrompt; if (!p) return; p.prompt(); await p.userChoice.catch(() => null); window.__installPrompt = null; setCanInstall(false); };
  const ios = isIOS(), standalone = isStandalone();
  const needsInstall = ios && !standalone;
  return (
    <div className="space-y-4">
      <div className="glass-card p-4 space-y-3">
        <div className="flex items-center gap-3">
          <img src="/icons/icon-192.png" alt="" className="w-12 h-12 rounded-[12px]" />
          <div><h3 className="font-bold">Install We One CRM on your phone</h3>
            <div className="text-xs text-glass-secondary">{standalone ? 'Installed. You are using the app.' : 'The full CRM (Leads, Students, Tasks, Attendance, Amazon and everything else) opens full screen from its own icon. Free, no App Store needed.'}</div></div>
        </div>
        {!standalone && (ios ? (
          <ol className="text-sm list-decimal pl-5 space-y-1">
            <li>Open <b>crm.weoneaviation.in</b> in <b>Safari</b>.</li>
            <li>Tap the <b>Share</b> button (square with an arrow), then <b>Add to Home Screen</b>, then <b>Add</b>.</li>
            <li>Open <b>We One CRM</b> from the new icon, sign in, and come back here to turn on notifications.</li>
          </ol>
        ) : canInstall ? (
          <button type="button" className="glass-btn px-4 py-2 text-sm" onClick={install}>Install app</button>
        ) : /Android/i.test(navigator.userAgent) ? (
          <ol className="text-sm list-decimal pl-5 space-y-1">
            <li>Open <b>crm.weoneaviation.in</b> in <b>Chrome</b>.</li>
            <li>Tap the <b>⋮</b> menu, then <b>Install app</b> (or <b>Add to Home screen</b>).</li>
          </ol>
        ) : (
          <div className="text-sm">On your phone, open <b>crm.weoneaviation.in</b> and come to this page for the steps. On a computer, Chrome and Edge show an install icon in the address bar.</div>
        ))}
      </div>
      <div className="glass-card p-4 space-y-3">
        <div className="flex items-center justify-between gap-2">
          <h3 className="font-bold">Notifications on this device</h3>
          {st?.on && <Chip style={GREEN}>On</Chip>}
        </div>
        <div className="text-xs text-glass-secondary">New orders, the 11 AM pickup reminder, 1–2 star feedback, out of stock and Claude's replies pop up on the lock screen within about a minute.</div>
        {!notifications ? (
          <div className="text-sm text-glass-secondary">Alerts come from the Amazon section today. Ask Admin for Amazon access to get them on this phone.</div>
        ) : !st ? <Empty>Loading…</Empty> : needsInstall ? (
          <div className="text-sm" style={{ color: '#B25E00' }}>On iPhone, notifications work only in the installed app (iOS 16.4 or newer). Install it first using the steps above.</div>
        ) : !pushSupported() ? (
          <div className="text-sm" style={{ color: '#B25E00' }}>This browser cannot show notifications. Use Chrome on Android, or the installed app on iPhone.</div>
        ) : st.perm === 'denied' ? (
          <div className="text-sm" style={{ color: '#C4261D' }}>Notifications are blocked for this app. Allow them in the phone's settings (Settings &gt; Notifications &gt; We One CRM), then come back.</div>
        ) : (
          <div className="flex flex-wrap gap-2">
            {st.on
              ? <><button type="button" className="glass-btn px-4 py-2 text-sm" onClick={test}>Send a test notification</button>
                  <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" disabled={busy} onClick={turnOff}>Turn off</button></>
              : <button type="button" className="glass-btn px-4 py-2 text-sm" disabled={busy} onClick={turnOn}>{busy ? 'Turning on…' : 'Turn on notifications'}</button>}
          </div>
        )}
        {st && st.my_devices > 0 && <div className="text-xs text-glass-muted">Your devices with notifications: {st.my_devices}</div>}
      </div>
    </div>
  );
}
