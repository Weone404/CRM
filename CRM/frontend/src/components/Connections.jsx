import { useEffect, useState } from 'react';
import { supabase, SUPABASE_URL } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog, choiceDialog, alertDialog } from './ui/dialogs';

// Settings → Connections (Admin only).
// The addresses and tokens that outside systems use to send data to the CRM. Copy them from here and paste
// them into each system. Tokens live in Supabase Vault; viewing or replacing one is audit-logged.
const FN = `${SUPABASE_URL}/functions/v1`;
const CONNECTIONS = [
  { id: 'website', name: 'Website enquiry forms', where: 'weoneaviation.in / .com and pilotschool.in — the form "send to" address',
    url: `${FN}/crm-leads/ingest` },
  { id: 'charter', name: 'BookMyCharter', where: 'bookmycharter.in settings (Vercel) — CRM address and token',
    url: `${FN}/crm-leads/charter`, header: true },
  { id: 'hikvision', name: 'Hikvision attendance machine', where: 'Machine web page → Network → HTTP Listening / Event push',
    url: `${FN}/crm-attendance/hikvision?token=`, inUrl: true },
  { id: 'partner', name: 'Partner apps (e.g. DGCA prep)', where: `DGCA prep (Vercel): CRM_API_URL = ${typeof window !== 'undefined' ? window.location.origin : ''} and CRM_PARTNER_TOKEN = the token. Other apps: the address below + ?mobile=…&month=YYYY-MM.`,
    url: `${FN}/crm-attendance/partner/attendance/by-mobile`, header: true },
];

const copy = async (text, what) => {
  try { await navigator.clipboard.writeText(text); }
  catch {
    const t = document.createElement('textarea'); t.value = text; document.body.appendChild(t);
    t.select(); document.execCommand('copy'); t.remove();
  }
  showToast(`${what} copied.`, 'success');
};

export default function Connections() {
  const [info, setInfo] = useState({});
  const [shown, setShown] = useState({}); // id -> full token, after "Show"
  const [busy, setBusy] = useState('');

  const load = async () => {
    const { data, error } = await supabase.rpc('api_connections');
    if (error) showToast(error.message, 'error'); else setInfo(data || {});
  };
  useEffect(() => { load(); }, []);

  const token = async (id) => {
    if (shown[id]) return shown[id];
    const { data, error } = await supabase.rpc('api_connection_token', { p_id: id });
    if (error) { showToast(error.message, 'error'); return null; }
    setShown((s) => ({ ...s, [id]: data }));
    return data;
  };
  const rotate = async (c) => {
    if (!(await confirmDialog(`Make a new token for ${c.name}?`, { message: `The old one stops working immediately. ${c.name} will stop sending data until you paste the new one there.`, confirmText: 'Make new token', danger: true }))) return;
    setBusy(c.id);
    const { data, error } = await supabase.rpc('api_connection_rotate', { p_id: c.id });
    setBusy('');
    if (error) { showToast(error.message, 'error'); return; }
    setShown((s) => ({ ...s, [c.id]: data }));
    showToast('New token made. Paste it into ' + c.name + ' now.', 'success');
    load();
  };

  const btn = 'px-3 py-1.5 rounded-lg font-medium text-sm';
  const grey = { background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' };

  return (
    <div className="mt-8">
      <div className="mb-4">
        <h2 className="text-xl font-bold text-glass-primary">Connections</h2>
        <p className="text-sm text-glass-secondary mt-1">
          Addresses and tokens your other systems use to send data to the CRM. Copy them from here and paste them into each system.
        </p>
      </div>
      <div className="space-y-2">
        {CONNECTIONS.map((c) => {
          const meta = info[c.id];
          const full = shown[c.id];
          const hasToken = c.header || c.inUrl;
          const mask = meta ? `••••${meta.last4}` : '••••';
          const urlShown = c.inUrl ? c.url + (full || mask) : c.url;
          return (
            <div key={c.id} className="glass-card p-4">
              <div className="font-semibold text-glass-primary">{c.name}</div>
              <div className="text-xs text-glass-muted mt-0.5">Paste into: {c.where}</div>

              <div className="mt-3 text-xs text-glass-secondary">Address</div>
              <div className="flex flex-wrap gap-2 mt-1">
                <code className="glass-input flex-1 min-w-[220px] px-3 py-2 text-xs break-all">{urlShown}</code>
                <button className={btn} style={grey} data-testid={`copy-url-${c.id}`}
                  onClick={async () => { const t = c.inUrl ? await token(c.id) : ''; if (!c.inUrl || t) copy(c.url + (t || ''), 'Address'); }}>
                  Copy address
                </button>
              </div>

              {hasToken && (
                <>
                  <div className="mt-3 text-xs text-glass-secondary">
                    Token{c.header ? ' — send as header  Authorization: Bearer <token>' : ' — already inside the address above'}
                  </div>
                  <div className="flex flex-wrap items-center gap-2 mt-1">
                    <code className="glass-input flex-1 min-w-[220px] px-3 py-2 text-xs break-all" data-testid={`token-${c.id}`}>{full || mask}</code>
                    {!full && <button className={btn} style={grey} onClick={() => token(c.id)}>Show</button>}
                    {full && <button className={btn} style={grey} onClick={() => setShown((s) => { const n = { ...s }; delete n[c.id]; return n; })}>Hide</button>}
                    <button className={btn} style={grey} onClick={async () => { const t = await token(c.id); if (t) copy(t, 'Token'); }}>Copy token</button>
                    <button className={btn} style={{ background: 'rgba(255,59,48,0.12)', color: '#D70015' }} disabled={busy === c.id} onClick={() => rotate(c)}>
                      {busy === c.id ? 'Making…' : 'New token'}
                    </button>
                  </div>
                  {meta && <div className="text-xs text-glass-muted mt-2">Token last changed {new Date(meta.updated_at).toLocaleString()}</div>}
                </>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
