// JustDial on the Leads page. Each JustDial listing (We One Aviation, Flying Star, ...) has a secret CRM link; the JustDial
// account manager adds it once, then every enquiry lands in Leads instantly with a "call now" in Today (migration 149,
// crm-leads /justdial). This card shows whether each listing is sending, its latest enquiries, and, for Admin, the link,
// a ready message for JustDial, a test, and the listing settings.
import { useCallback, useEffect, useState } from 'react';
import Icon from '../icons';
import { rpc } from '../adsKit';
import { SUPABASE_URL } from '../../backend/supabaseClient';
import { showToast } from '../../utils/toast';
import { Chip } from './DateTimePicker';
import './leads.css';

const linkOf = (token) => `${SUPABASE_URL}/functions/v1/crm-leads/justdial/${token}`;
const ago = (t) => {
  if (!t) return null;
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`;
};
const FIELDS = 'leadid, leadtype, prefix, name, mobile, phone, email, date, time, category, city, area, brancharea, pincode, company';
const message = (l) => `Hello,

Please switch on the lead API (instant lead push) for our JustDial listing "${l.name}". Please send every new enquiry to this URL:

${linkOf(l.token)}

It accepts HTTP GET or POST with the usual JustDial lead fields (${FIELDS}) and replies "RECEIVED".

Please confirm once it is live. Thank you.`;
const STATUS = {
  created: ['New lead', '#1E7B34', 'rgba(52,199,89,0.14)'],
  repeat: ['Already a lead', '#0A57B5', 'rgba(0,122,255,0.10)'],
  duplicate: ['Sent again', '#6E6E73', 'rgba(118,118,128,0.12)'],
  rejected: ['No phone', '#A42219', 'rgba(255,59,48,0.10)'],
};
const JdMark = ({ size = 32 }) => (
  <span aria-hidden="true" className="inline-grid place-items-center shrink-0 font-extrabold" style={{ width: size, height: size, borderRadius: 10, background: '#FF6F00', color: '#fff', fontSize: size * 0.38, letterSpacing: '-0.5px' }}>Jd</span>
);

function stateOf(l) {
  if (!l.active) return ['Off', '#6E6E73', 'rgba(118,118,128,0.12)'];
  if (l.last_lead_at) return ['Connected', '#1E7B34', 'rgba(52,199,89,0.14)'];
  return ['Waiting for JustDial', '#8A5300', 'rgba(255,149,0,0.14)'];
}

function Settings({ l, people, onDone, onCancel, segment = 'aviation' }) {
  const [f, setF] = useState({ name: l?.name || '', segment: l?.segment || segment, assign_to: l?.assign_to || '', active: l ? l.active : true });
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try { await rpc('api_jd_listing_save', { p_id: l?.id || null, p_name: f.name, p_segment: f.segment, p_assign_to: f.assign_to || null, p_active: f.active }); onDone(); }
    catch (e) { showToast(e.message, 'error'); setBusy(false); }
  };
  return (
    <div className="lp-reveal mt-3 p-3 rounded-2xl flex flex-col gap-3" style={{ background: 'rgba(118,118,128,0.07)' }} data-testid="jd-settings">
      <label className="flex flex-col gap-1"><span className="lp-label m-0">Listing name</span>
        <input className="glass-input min-h-[42px] px-3 text-[15px]" value={f.name} maxLength={60} placeholder="e.g. We One Aviation" onChange={(e) => setF({ ...f, name: e.target.value })} autoFocus={!l} /></label>
      <div><div className="lp-label">Leads go to</div>
        <div className="flex gap-2"><Chip on={f.segment === 'aviation'} onClick={() => setF({ ...f, segment: 'aviation' })}>Aviation</Chip><Chip on={f.segment === 'charter'} onClick={() => setF({ ...f, segment: 'charter' })}>Charter</Chip></div></div>
      <label className="flex flex-col gap-1"><span className="lp-label m-0">Who calls these leads</span>
        <select className="glass-input min-h-[42px] px-3 text-[15px]" value={f.assign_to} onChange={(e) => setF({ ...f, assign_to: e.target.value })}>
          <option value="">Anyone (not assigned)</option>{(people || []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select></label>
      {l && <label className="flex items-center gap-2 text-sm text-glass-primary"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} />Receiving leads (untick to pause this link)</label>}
      <div className="flex gap-2 justify-end">
        <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={onCancel}>Cancel</button>
        <button type="button" className="lp-btn lp-btn-sm lp-btn-primary" disabled={busy || !f.name.trim()} onClick={save}>{busy ? 'Saving…' : l ? 'Save' : 'Add listing'}</button>
      </div>
    </div>
  );
}

function Listing({ l, admin, people, reload, onOpenLeadId }) {
  const [edit, setEdit] = useState(false);
  const [testing, setTesting] = useState(false);
  const [st, color, bg] = stateOf(l);
  const link = l.token ? linkOf(l.token) : '';
  const copy = async (text, what) => { try { await navigator.clipboard.writeText(text); showToast(`${what} copied`, 'success'); } catch { showToast('Copy did not work; select and copy it instead', 'error'); } };
  const test = async () => {
    setTesting(true);
    const before = l.tested_at;
    try {
      const q = new URLSearchParams({ leadid: `TEST-${Date.now()}`, name: 'JustDial test', mobile: '9999999999', category: 'Test enquiry', city: 'Delhi' });
      await fetch(`${link}?${q}`, { mode: 'no-cors' });
    } catch { /* the result is read back below */ }
    for (let i = 0; i < 6; i++) {
      await new Promise((r) => setTimeout(r, 1200));
      const d = await rpc('api_jd_listings').catch(() => null);
      const now = d?.listings?.find((x) => x.id === l.id);
      if (now?.tested_at && now.tested_at !== before) { showToast('The link works. A real JustDial enquiry will appear here as a lead.', 'success'); setTesting(false); reload(); return; }
    }
    setTesting(false);
    showToast('The test did not arrive. Try again in a minute.', 'error');
  };
  const newLink = async () => {
    const { confirmDialog } = await import('../ui/dialogs');
    if (!(await confirmDialog('Make a new link?', { message: 'The old link stops working at once. Send the new link to JustDial, or their leads will not arrive.', confirmText: 'New link', danger: true }))) return;
    try { await rpc('api_jd_listing_new_link', { p_id: l.id }); showToast('New link ready. Send it to JustDial.', 'success'); reload(); } catch (e) { showToast(e.message, 'error'); }
  };
  const remove = async () => {
    const { confirmDialog } = await import('../ui/dialogs');
    if (!(await confirmDialog(`Remove ${l.name}?`, { message: 'Its link stops working. Leads already received stay in Leads.', confirmText: 'Remove', danger: true }))) return;
    try { await rpc('api_jd_listing_remove', { p_id: l.id }); reload(); } catch (e) { showToast(e.message, 'error'); }
  };
  const mailto = `mailto:?subject=${encodeURIComponent(`JustDial lead API for ${l.name}`)}&body=${encodeURIComponent(link ? message(l) : '')}`;
  const wa = `https://wa.me/?text=${encodeURIComponent(link ? message(l) : '')}`;

  return (
    <div className="py-3 border-t first:border-t-0" style={{ borderColor: 'rgba(60,60,67,0.12)' }} data-testid="jd-listing">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-[15px] font-semibold text-glass-primary">{l.name}</span>
            <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full" style={{ color, background: bg }}>{st}</span>
          </div>
          <div className="text-[12px] text-glass-secondary mt-0.5">
            {l.segment === 'charter' ? 'Charter' : 'Aviation'} · {l.leads_30} new lead{l.leads_30 === 1 ? '' : 's'} in 30 days{l.repeats_30 ? ` · ${l.repeats_30} repeat` : ''}
            {l.last_lead_at ? ` · last ${ago(l.last_lead_at)}` : ''}{l.assign_name ? ` · calls: ${l.assign_name}` : ''}
          </div>
        </div>
        {admin && <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => setEdit(!edit)} aria-expanded={edit}><Icon name="settings" size={14} />Settings</button>}
      </div>

      {admin && !l.last_lead_at && l.active && link && (
        <ol className="mt-3 p-3 rounded-2xl text-[13px] text-glass-primary flex flex-col gap-2.5 list-none" style={{ background: 'rgba(255,149,0,0.08)' }} data-testid="jd-steps">
          <li className="flex gap-2"><b className="jd-n">1</b><span className="min-w-0 flex-1">Send this link to your JustDial account manager (they switch it on; JustDial has no self-serve setting).
            <span className="mt-1.5 flex flex-wrap gap-2">
              <a className="lp-btn lp-btn-sm lp-btn-primary" href={mailto}><Icon name="mail" size={14} />Email</a>
              <a className="lp-btn lp-btn-sm lp-btn-green" href={wa} target="_blank" rel="noreferrer noopener">WhatsApp</a>
              <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => copy(message(l), 'Message')}><Icon name="copy" size={14} />Copy message</button>
            </span></span></li>
          <li className="flex gap-2"><b className="jd-n">2</b><span>Once they confirm, every JustDial enquiry appears in Leads at once, with a “call now” in Today.</span></li>
          <li className="flex gap-2"><b className="jd-n">3</b><span className="min-w-0 flex-1">Want to check the link now? <button type="button" className="lp-link" disabled={testing} onClick={test}>{testing ? 'Testing…' : 'Send a test'}</button>{l.tested_at ? <span className="text-glass-secondary"> · worked {ago(l.tested_at)}</span> : null}</span></li>
        </ol>)}

      {admin && link && (l.last_lead_at || !l.active) && (
        <div className="mt-2 flex flex-wrap gap-2">
          <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => copy(link, 'Link')}><Icon name="copy" size={14} />Copy link</button>
          <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" disabled={testing} onClick={test}>{testing ? 'Testing…' : 'Send a test'}</button>
        </div>)}

      {admin && edit && (
        <>
          <Settings l={l} people={people} onCancel={() => setEdit(false)} onDone={() => { setEdit(false); showToast('Saved', 'success'); reload(); }} />
          <div className="mt-2 p-3 rounded-2xl" style={{ background: 'rgba(118,118,128,0.07)' }}>
            <div className="lp-label">The link for JustDial</div>
            <div className="text-[12px] font-mono break-all text-glass-secondary select-all">{link}</div>
            <div className="mt-2 flex flex-wrap gap-2">
              <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={() => copy(link, 'Link')}><Icon name="copy" size={14} />Copy</button>
              <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={newLink}>New link</button>
              <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" style={{ color: '#C4261D' }} onClick={remove}>Remove listing</button>
            </div>
            <p className="m-0 mt-2 text-[12px] text-glass-secondary">Keep it private: anyone with this link can add leads. If it leaks, make a new link and send that to JustDial.</p>
          </div>
        </>)}

      {l.recent?.length > 0 && (
        <ul className="mt-2 flex flex-col">
          {l.recent.map((h, i) => {
            const [lab, c, b] = STATUS[h.status] || STATUS.duplicate;
            return (
              <li key={i}>
                <button type="button" disabled={!h.lead_id} onClick={() => onOpenLeadId(h.lead_id)}
                  className="w-full flex items-center gap-2 py-2 px-1 rounded-xl text-left hover:bg-black/[0.03] disabled:hover:bg-transparent min-w-0">
                  <span className="min-w-0 flex-1">
                    <span className="block text-[14px] font-medium text-glass-primary truncate">{h.name || 'No name'}</span>
                    <span className="block text-[12px] text-glass-secondary truncate">{[h.category, h.place, ago(h.at)].filter(Boolean).join(' · ')}</span>
                  </span>
                  <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0" style={{ color: c, background: b }}>{lab}</span>
                </button>
              </li>);
          })}
        </ul>)}
    </div>
  );
}

export default function JustDialCard({ segment, leads, onOpenLead, refreshKey }) {
  const [d, setD] = useState(null);
  const [open, setOpen] = useState(() => { try { return localStorage.getItem('jd-open') === '1'; } catch { return false; } });
  const [adding, setAdding] = useState(false);
  const load = useCallback(() => rpc('api_jd_listings').then(setD).catch(() => setD({ listings: [] })), []);
  useEffect(() => { load(); }, [load, refreshKey]);
  const toggle = () => { const v = !open; setOpen(v); try { localStorage.setItem('jd-open', v ? '1' : '0'); } catch { /* private mode */ } };
  if (!d) return null;
  const mine = (d.listings || []).filter((l) => l.segment === segment);
  if (!mine.length && !d.is_admin) return null;
  const n30 = mine.reduce((a, l) => a + Number(l.leads_30 || 0), 0);
  const waiting = mine.filter((l) => l.active && !l.last_lead_at).length;
  const last = mine.map((l) => l.last_lead_at).filter(Boolean).sort().pop();
  const byId = new Map((leads || []).map((l) => [l.id, l]));
  const openId = (id) => { const l = byId.get(id); if (l) onOpenLead(l); else showToast('This lead is in the other section or was removed', 'info'); };

  return (
    <section className="lp-section mb-4" data-testid="jd-card">
      <button type="button" className="w-full flex items-center gap-3 text-left" onClick={toggle} aria-expanded={open}>
        <JdMark />
        <span className="flex-1 min-w-0">
          <span className="block text-[15px] font-semibold text-glass-primary">JustDial</span>
          <span className="block text-[12px] text-glass-secondary truncate">
            {mine.length ? `${n30} lead${n30 === 1 ? '' : 's'} in 30 days${last ? ` · last ${ago(last)}` : ''}${waiting ? ` · ${waiting} listing${waiting === 1 ? '' : 's'} waiting for JustDial` : ''}` : 'Connect a JustDial listing'}
          </span>
        </span>
        {waiting > 0 && <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0" style={{ color: '#8A5300', background: 'rgba(255,149,0,0.14)' }}>Set up</span>}
        <span className="shrink-0 text-glass-secondary transition-transform" style={{ transform: open ? 'rotate(180deg)' : 'none' }}><Icon name="chevronDown" size={18} /></span>
      </button>
      {open && (
        <div className="lp-reveal mt-2">
          {mine.map((l) => <Listing key={l.id} l={l} admin={d.is_admin} people={d.people} reload={load} onOpenLeadId={openId} />)}
          {!mine.length && <p className="m-0 py-2 text-[13px] text-glass-secondary">No JustDial listing sends to {segment === 'charter' ? 'Charter' : 'Aviation'} yet.</p>}
          {d.is_admin && (adding
            ? <Settings l={null} segment={segment} people={d.people} onCancel={() => setAdding(false)} onDone={() => { setAdding(false); showToast('Listing added. Send its link to JustDial.', 'success'); load(); }} />
            : <button type="button" className="lp-link mt-2" onClick={() => setAdding(true)}>+ Add a JustDial listing</button>)}
        </div>)}
    </section>
  );
}
