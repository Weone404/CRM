import { useEffect, useState } from 'react';
import { supabase } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';

// Settings → AI Integrations (Admin only).
// Keys are stored encrypted in Supabase Vault through Admin-only database functions.
// A saved key is never sent back to the browser: only its last 4 characters are shown.
const PROVIDERS = [
  { id: 'groq', name: 'Groq', hint: 'Starts with gsk_ — console.groq.com/keys' },
  { id: 'gemini', name: 'Google Gemini', hint: 'Google AI Studio → Get API key' },
  { id: 'openai', name: 'OpenAI', hint: 'Starts with sk- — platform.openai.com/api-keys' },
  { id: 'anthropic', name: 'Anthropic (Claude)', hint: 'Starts with sk-ant- — console.anthropic.com' },
  { id: 'openrouter', name: 'OpenRouter', hint: 'Starts with sk-or- — openrouter.ai/keys' },
  { id: 'google_places', name: 'Google Maps / Places', hint: 'Google Cloud console → Credentials' },
];

export default function AIIntegrations() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [editing, setEditing] = useState(null); // provider id being edited
  const [keyInput, setKeyInput] = useState('');
  const [custom, setCustom] = useState('');
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setLoading(true); setError('');
    const { data, error: err } = await supabase.rpc('ai_integrations_list');
    if (err) setError(err.message); else setRows(data || []);
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const saved = Object.fromEntries(rows.map((r) => [r.provider, r]));
  const extra = rows.filter((r) => !PROVIDERS.some((p) => p.id === r.provider))
    .map((r) => ({ id: r.provider, name: r.provider, hint: 'Custom provider' }));
  const list = [...PROVIDERS, ...extra];

  const save = async (provider) => {
    if (keyInput.trim().length < 8) { showToast('That key looks too short.', 'error'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('ai_integration_set', { provider, api_key: keyInput.trim(), enabled: true });
    setBusy(false);
    if (err) { showToast(err.message, 'error'); return; }
    setEditing(null); setKeyInput('');
    showToast('Key saved securely.', 'success');
    load();
  };
  const toggle = async (provider, enabled) => {
    const { error: err } = await supabase.rpc('ai_integration_toggle', { provider, enabled });
    if (err) showToast(err.message, 'error'); else load();
  };
  const remove = async (provider) => {
    if (!window.confirm(`Delete the ${provider} key? Features using it will stop until a new key is added.`)) return;
    const { error: err } = await supabase.rpc('ai_integration_delete', { provider });
    if (err) showToast(err.message, 'error'); else { showToast('Key deleted.', 'success'); load(); }
  };
  const addCustom = () => {
    const id = custom.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_');
    if (!/^[a-z][a-z0-9_]{1,30}$/.test(id)) { showToast('Use letters, numbers and _ only (e.g. mistral).', 'error'); return; }
    setEditing(id); setKeyInput(''); setCustom('');
    if (!list.some((p) => p.id === id)) setRows((r) => [...r]); // row appears once saved
  };

  return (
    <div>
      <div className="mb-4">
        <h2 className="text-xl font-bold text-glass-primary">AI Integrations</h2>
        <p className="text-sm text-glass-secondary mt-1">
          API keys are encrypted in the database. Only the last 4 characters are ever shown, and only Admin can change them.
        </p>
      </div>
      {error && <div className="glass-card p-3 mb-4 text-sm" style={{ color: '#b91c1c' }}>{error}</div>}
      {loading ? <div className="text-sm text-glass-secondary">Loading…</div> : (
        <div className="space-y-2">
          {[...list, ...(editing && !list.some((p) => p.id === editing) ? [{ id: editing, name: editing, hint: 'Custom provider' }] : [])].map((p) => {
            const row = saved[p.id];
            const isEditing = editing === p.id;
            return (
              <div key={p.id} className="glass-card p-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <div className="font-semibold text-glass-primary">{p.name}</div>
                    <div className="text-xs text-glass-muted mt-0.5">{p.hint}</div>
                  </div>
                  <div className="flex items-center gap-2 text-sm">
                    {row ? (
                      <>
                        <span className="px-2 py-0.5 rounded-md" style={{ background: row.enabled ? '#dcfce7' : '#f3f4f6', color: row.enabled ? '#166534' : '#6b7280' }}>
                          {row.enabled ? 'Active' : 'Off'} · ••••{row.last4}
                        </span>
                        <button onClick={() => toggle(p.id, !row.enabled)} className="px-3 py-1.5 rounded-lg font-medium" style={{ background: '#f3f4f6', color: '#424245' }}>{row.enabled ? 'Turn off' : 'Turn on'}</button>
                        <button onClick={() => { setEditing(p.id); setKeyInput(''); }} className="glass-btn px-3 py-1.5">Replace</button>
                        <button onClick={() => remove(p.id)} className="px-3 py-1.5 rounded-lg font-medium" style={{ background: '#fee2e2', color: '#b91c1c' }}>Delete</button>
                      </>
                    ) : (
                      !isEditing && <button onClick={() => { setEditing(p.id); setKeyInput(''); }} className="glass-btn px-3 py-1.5">Add key</button>
                    )}
                  </div>
                </div>
                {row && <div className="text-xs text-glass-muted mt-2">Updated {new Date(row.updated_at).toLocaleString()}{row.updated_by_name ? ` by ${row.updated_by_name}` : ''}</div>}
                {isEditing && (
                  <div className="mt-3 flex flex-wrap gap-2">
                    <input type="password" autoComplete="off" value={keyInput} onChange={(e) => setKeyInput(e.target.value)} placeholder={`Paste the ${p.name} API key`} className="glass-input flex-1 min-w-[220px] px-3 py-2" autoFocus />
                    <button disabled={busy} onClick={() => save(p.id)} className="glass-btn px-4 py-2" style={{ background: '#22c55e' }}>{busy ? 'Saving…' : 'Save'}</button>
                    <button onClick={() => { setEditing(null); setKeyInput(''); }} className="px-4 py-2 rounded-lg font-medium" style={{ background: '#f3f4f6', color: '#424245' }}>Cancel</button>
                  </div>
                )}
              </div>
            );
          })}
          <div className="glass-card p-4 flex flex-wrap gap-2 items-center">
            <span className="text-sm text-glass-secondary">Another provider:</span>
            <input value={custom} onChange={(e) => setCustom(e.target.value)} placeholder="e.g. mistral" className="glass-input px-3 py-2 w-48" />
            <button onClick={addCustom} className="glass-btn px-3 py-2">Add</button>
          </div>
        </div>
      )}
    </div>
  );
}
