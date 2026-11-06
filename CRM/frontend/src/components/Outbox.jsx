import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { API_URL } from '../api';
import { USE_SUPABASE } from '../backend/mode';
import { displayPhone } from '../utils/formatters';
import { modalProps } from './ui/overlay';
import { CloseButton } from './ui/QuickActions';
import { confirmDialog, promptDialog, choiceDialog, alertDialog } from './ui/dialogs';

export default function Outbox({ onClose }) {
  const [messages, setMessages] = useState([]);
  useEffect(() => { loadMessages(); }, []);
  const loadMessages = async () => { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/outbox`, { headers: { 'Authorization': `Bearer ${token}` } }); setMessages(await res.json()); };
  const handleApprove = async (msgId) => { const token = localStorage.getItem('token'); await fetch(`${API_URL}/api/outbox/${msgId}/approve`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}` } }); loadMessages(); };
  const handleMarkSent = async (msgId) => { if (!(await confirmDialog('Mark this quote as sent?', { confirmText: 'Mark sent' }))) return; const token = localStorage.getItem('token'); await fetch(`${API_URL}/api/outbox/${msgId}/sent`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}` } }); loadMessages(); };
  const getWhatsAppLink = (msg) => { const pdfUrl = USE_SUPABASE ? (msg.pdf_share_url || '') : `${API_URL}/api/quotes/${msg.id}/pdf`; const text = `Hi ${msg.lead_name},\n\nPlease find your course quote here: ${pdfUrl}\n\nFor any queries, contact us.\n\n- We One Aviation`; const phone = msg.lead_phone.replace(/\D/g, ''); const phoneWith91 = phone.startsWith('91') ? phone : `91${phone}`; return `https://wa.me/${phoneWith91}?text=${encodeURIComponent(text)}`; };

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(onClose)}>
      <div className="glass-strong max-w-4xl w-full my-8 max-h-[90vh] overflow-y-auto p-6 animate-glass-in">
        <div className="flex justify-between items-start mb-4"><div><h2 className="text-2xl font-bold text-glass-primary">Outbox</h2><p className="text-sm text-glass-secondary">Review quotes before sending via WhatsApp</p></div><CloseButton onClick={onClose} /></div>
        <div className="space-y-3">
          {messages.map(msg => (
            <div key={msg.id} className="glass-card p-4">
              <div className="flex justify-between items-start mb-3">
                <div><div className="font-semibold text-lg text-glass-primary">{msg.lead_name}</div><div className="text-sm text-glass-secondary">{displayPhone(msg.lead_phone)}</div><div className="text-sm text-glass-secondary mt-1">{msg.body}</div><div className="text-xs text-glass-muted mt-1">Created: {new Date(msg.created_at).toLocaleString()}</div></div>
                <span className={`glass-badge ${msg.status === 'pending' ? 'bg-yellow-100 text-yellow-800' : msg.status === 'approved' ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'}`}>{msg.status.toUpperCase()}</span>
              </div>
              {msg.pdf_path && <div className="mb-3 p-2 glass-subtle"><a href={USE_SUPABASE ? msg.pdf_share_url : `${API_URL}/api/quotes/${msg.id}/pdf`} target="_blank" rel="noopener noreferrer" className="text-indigo-600 hover:underline text-sm font-semibold">📄 View Quote PDF</a><p className="text-xs text-orange-600 mt-1">⚠️ Review PDF for PLACEHOLDER values before sending</p></div>}
              <div className="flex gap-2">
                {msg.status === 'pending' && <button onClick={() => handleApprove(msg.id)} className="glass-btn flex-1 py-2" style={{ background: '#34C759' }}>✓ Approve for Sending</button>}
                {msg.status === 'approved' && (<><a href={getWhatsAppLink(msg)} target="_blank" rel="noopener noreferrer" className="glass-btn flex-1 py-2 text-center" style={{ background: '#248A3D' }}>💬 Send via WhatsApp</a><button onClick={() => handleMarkSent(msg.id)} className="glass-btn px-4 py-2 text-sm">Mark as Sent</button></>)}
              </div>
            </div>
          ))}
          {messages.length === 0 && <div className="text-center text-glass-muted py-12">No messages in outbox</div>}
        </div>
      </div>
    </div>,
    document.body
  );
}
