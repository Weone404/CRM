import { useState } from 'react';
import { createPortal } from 'react-dom';
import { API_URL } from '../api';
import { showToast } from '../utils/toast';
import { COURSES } from '../constants/courses';
import { modalProps } from './ui/overlay';
import { CloseButton } from './ui/QuickActions';
import { confirmDialog, promptDialog, choiceDialog, alertDialog } from './ui/dialogs';

const SOURCES = ['We One Aviation', 'JustDial', 'Walk-in', 'Direct Call', 'Direct Message', 'Flying Star'];
const QUALIFICATIONS = ['10th', '12th with Physics & Maths', '12th without Physics & Maths', 'Graduation'];

const CHARTER_SOURCES = ['Direct Call', 'WhatsApp', 'Walk-in', 'Referral', 'Email', 'Other'];

// Charter enquiry taken by phone / WhatsApp / walk-in. Only name, phone and
// route are required: a first call often has no fixed date or head-count yet.
function CharterQuery({ onClose, onCreated, onOpenExisting }) {
  const [form, setForm] = useState({ utm_source: '', name: '', phone: '', email: '', from: '', to: '', departureDate: '', departureTime: '', passengers: '', additionalRequirements: '' });
  const [saving, setSaving] = useState(false);
  const set = (k, v) => setForm({ ...form, [k]: v });
  const input = "glass-input w-full px-3 py-2";

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!form.utm_source || !form.name || !form.phone || !form.from || !form.to) { showToast('Fill all required fields', 'error'); return; }
    setSaving(true);
    try {
      const token = localStorage.getItem('token');
      const body = { segment: 'charter', ...form, passengers: form.passengers ? Number(form.passengers) : undefined };
      Object.keys(body).forEach((k) => (body[k] === '' || body[k] === undefined) && delete body[k]);
      const res = await fetch(`${API_URL}/api/leads/query`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const data = await res.json(); setSaving(false);
      if (!res.ok) { showToast(data.detail || 'Failed to add enquiry', 'error'); return; }
      if (data.status === 'duplicate') { if (await confirmDialog(`This trip is already in the CRM${data.name ? ` (${data.name})` : ''}.`, { title: 'Already in the CRM', confirmText: 'Open it' })) onOpenExisting(data.lead_id); return; }
      showToast(`Charter enquiry added (${data.reference})`, 'success'); onCreated();
    } catch { setSaving(false); showToast('Failed to add enquiry', 'error'); }
  };

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(onClose, { guard: true })}>
      <div className="glass-strong max-w-lg w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
        <div className="flex justify-between items-start mb-4"><h2 className="text-xl font-bold text-glass-primary">Add Charter Enquiry</h2><CloseButton onClick={onClose} /></div>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div><label className="block text-sm font-semibold mb-1 text-glass-primary">Enquiry From *</label><select value={form.utm_source} onChange={(e) => set('utm_source', e.target.value)} className={input} required><option value="">-- Select Source --</option>{CHARTER_SOURCES.map(s => <option key={s} value={s}>{s}</option>)}</select></div>
          <input className={input} placeholder="Name *" value={form.name} onChange={(e) => set('name', e.target.value)} required />
          <input className={input} type="tel" placeholder="Phone Number *" value={form.phone} onChange={(e) => set('phone', e.target.value)} required />
          <input className={input} type="email" placeholder="Email ID" value={form.email} onChange={(e) => set('email', e.target.value)} />
          <div className="grid grid-cols-2 gap-2">
            <input className={input} placeholder="From (city / airport) *" value={form.from} onChange={(e) => set('from', e.target.value)} required />
            <input className={input} placeholder="To (city / airport) *" value={form.to} onChange={(e) => set('to', e.target.value)} required />
          </div>
          <div className="grid grid-cols-3 gap-2">
            <div><label className="block text-xs font-semibold mb-1 text-glass-secondary">Date</label><input className={input} type="date" value={form.departureDate} onChange={(e) => set('departureDate', e.target.value)} /></div>
            <div><label className="block text-xs font-semibold mb-1 text-glass-secondary">Time</label><input className={input} type="time" value={form.departureTime} onChange={(e) => set('departureTime', e.target.value)} /></div>
            <div><label className="block text-xs font-semibold mb-1 text-glass-secondary">Passengers</label><input className={input} type="number" min="1" max="500" value={form.passengers} onChange={(e) => set('passengers', e.target.value)} /></div>
          </div>
          <textarea className={input} rows={3} placeholder="Requirements (aircraft, luggage, return trip...)" value={form.additionalRequirements} onChange={(e) => set('additionalRequirements', e.target.value)} />
          <button type="submit" disabled={saving} className="glass-btn w-full py-3" style={{ background: '#34C759' }}>{saving ? 'Saving...' : 'Save Enquiry'}</button>
        </form>
      </div>
    </div>,
    document.body
  );
}

export default function AddQuery({ segment = 'aviation', ...props }) {
  if (segment === 'charter') return <CharterQuery {...props} />;
  return <AviationQuery {...props} />;
}

function AviationQuery({ requiredQualification, onClose, onCreated, onOpenExisting }) {
  const [form, setForm] = useState({ utm_source: '', name: '', guardian_name: '', phone: '', email: '', address: '', course_interest: '' });
  const [qualifications, setQualifications] = useState([]);
  const [niosInterested, setNiosInterested] = useState(null);
  const [saving, setSaving] = useState(false);
  const set = (k, v) => setForm({ ...form, [k]: v });
  const isEligible = qualifications.includes(requiredQualification);
  const toggleQual = (q) => setQualifications(qualifications.includes(q) ? qualifications.filter(x => x !== q) : [...qualifications, q]);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!form.utm_source || !form.name || !form.phone || !form.course_interest) { showToast('Fill all required fields', 'error'); return; }
    if (!isEligible && niosInterested === null) { showToast('Answer "Interested in NIOS?"', 'error'); return; }
    setSaving(true);
    try {
      const token = localStorage.getItem('token');
      const res = await fetch(`${API_URL}/api/leads/query`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ ...form, qualifications, nios_interested: isEligible ? null : niosInterested }) });
      const data = await res.json(); setSaving(false);
      if (!res.ok) { showToast(data.detail || 'Failed to add query', 'error'); return; }
      if (data.status === 'duplicate') { if (await confirmDialog(`A lead with this phone already exists${data.name ? ` (${data.name})` : ''}.`, { title: 'Already in the CRM', confirmText: 'Open existing' })) onOpenExisting(data.lead_id); return; }
      showToast('Query added', 'success'); onCreated();
    } catch { setSaving(false); showToast('Failed to add query', 'error'); }
  };

  const input = "glass-input w-full px-3 py-2";

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(onClose, { guard: true })}>
      <div className="glass-strong max-w-lg w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
        <div className="flex justify-between items-start mb-4"><h2 className="text-xl font-bold text-glass-primary">Add Query</h2><CloseButton onClick={onClose} /></div>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div><label className="block text-sm font-semibold mb-1 text-glass-primary">Lead From *</label><select value={form.utm_source} onChange={(e) => set('utm_source', e.target.value)} className={input} required><option value="">-- Select Source --</option>{SOURCES.map(s => <option key={s} value={s}>{s}</option>)}</select></div>
          <input className={input} placeholder="Name *" value={form.name} onChange={(e) => set('name', e.target.value)} required />
          <input className={input} placeholder="Parent's / Guardian's Name" value={form.guardian_name} onChange={(e) => set('guardian_name', e.target.value)} />
          <input className={input} type="tel" placeholder="Phone Number *" value={form.phone} onChange={(e) => set('phone', e.target.value)} required />
          <input className={input} type="email" placeholder="Email ID" value={form.email} onChange={(e) => set('email', e.target.value)} />
          <input className={input} placeholder="Address" value={form.address} onChange={(e) => set('address', e.target.value)} />
          <div><label className="block text-sm font-semibold mb-1 text-glass-primary">Course Interested *</label><select value={form.course_interest} onChange={(e) => set('course_interest', e.target.value)} className={input} required><option value="">-- Select Course --</option>{COURSES.map(c => <option key={c} value={c}>{c}</option>)}</select></div>
          <div><label className="block text-sm font-semibold mb-1 text-glass-primary">Educational Qualification</label><div className="space-y-1">{QUALIFICATIONS.map(q => <label key={q} className="flex items-center gap-2 text-sm text-glass-primary"><input type="checkbox" checked={qualifications.includes(q)} onChange={() => toggleQual(q)} />{q}</label>)}</div></div>
          {qualifications.length > 0 && !isEligible && (<div className="p-3 rounded" style={{ background: 'rgba(255,59,48,0.08)', border: '1px solid rgba(255,59,48,0.35)' }}><p className="text-sm text-red-700 mb-2">Not eligible (requires "{requiredQualification}"). Interested in NIOS? *</p><div className="flex gap-2"><button type="button" onClick={() => setNiosInterested(true)} className={`px-4 py-2 rounded border-2 font-semibold ${niosInterested === true ? 'border-green-600 bg-green-50 text-green-700' : 'glass-subtle text-glass-secondary'}`}>Yes</button><button type="button" onClick={() => setNiosInterested(false)} className={`px-4 py-2 rounded border-2 font-semibold ${niosInterested === false ? 'border-red-600 bg-red-50 text-red-700' : 'glass-subtle text-glass-secondary'}`}>No</button></div></div>)}
          <button type="submit" disabled={saving} className="glass-btn w-full py-3" style={{ background: '#34C759' }}>{saving ? 'Saving...' : 'Save Query'}</button>
        </form>
      </div>
    </div>,
    document.body
  );
}
