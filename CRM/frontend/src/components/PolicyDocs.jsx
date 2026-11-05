import { useState, useEffect } from 'react';
import { API_URL } from '../api';

export default function PolicyDocs() {
  const [docs, setDocs] = useState([]);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({ title: '', content: '' });
  const [uploading, setUploading] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');

  useEffect(() => { loadDocs(); }, []);
  const loadDocs = async () => { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/policy-docs`, { headers: { 'Authorization': `Bearer ${token}` } }); setDocs(await res.json()); };
  const handleSearch = async () => { if (!searchQuery.trim()) { loadDocs(); return; } const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/policy-docs/search?q=${encodeURIComponent(searchQuery)}`, { headers: { 'Authorization': `Bearer ${token}` } }); setDocs(await res.json()); };
  const handleCreate = async (e) => { e.preventDefault(); const token = localStorage.getItem('token'); await fetch(`${API_URL}/api/policy-docs`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(formData) }); setFormData({ title: '', content: '' }); setShowForm(false); loadDocs(); };
  const handleUpload = async (e) => { const file = e.target.files[0]; if (!file) return; setUploading(true); const token = localStorage.getItem('token'); const fd = new FormData(); fd.append('file', file); await fetch(`${API_URL}/api/policy-docs/upload`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}` }, body: fd }); setUploading(false); loadDocs(); };

  return (
    <div>
      <div className="flex justify-between items-center mb-4"><h2 className="text-xl font-bold text-glass-primary">Policy Documents</h2><div className="flex gap-2"><label className="glass-btn px-3 py-2 cursor-pointer text-sm" style={{ background: '#34C759' }}>{uploading ? 'Uploading...' : '📄 Upload'}<input type="file" onChange={handleUpload} className="hidden" accept=".txt,.md" disabled={uploading} /></label><button onClick={() => setShowForm(!showForm)} className="glass-btn px-3 py-2 text-sm">+ Add</button></div></div>
      <div className="mb-4 flex gap-2"><input type="text" placeholder="Search documents..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && handleSearch()} className="glass-input flex-1 px-3 py-2" /><button onClick={handleSearch} className="glass-btn px-4 py-2">Search</button><button onClick={() => { setSearchQuery(''); loadDocs(); }} className="px-4 py-2 rounded-lg font-medium" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Clear</button></div>
      {showForm && (<form onSubmit={handleCreate} className="glass-card p-4 mb-4"><div className="mb-3"><input type="text" placeholder="Document title" value={formData.title} onChange={(e) => setFormData({...formData, title: e.target.value})} className="glass-input w-full px-3 py-2" required /></div><div className="mb-3"><textarea placeholder="Document content" value={formData.content} onChange={(e) => setFormData({...formData, content: e.target.value})} className="glass-input w-full px-3 py-2" rows={6} required /></div><div className="flex gap-2"><button type="submit" className="glass-btn px-4 py-2" style={{ background: '#34C759' }}>Create</button><button type="button" onClick={() => setShowForm(false)} className="px-4 py-2 rounded-lg font-medium" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Cancel</button></div></form>)}
      <div className="space-y-2">{docs.map(doc => <div key={doc.id} className="glass-card p-3"><div className="font-semibold text-glass-primary">{doc.title}</div><div className="text-sm text-glass-secondary mt-1">{doc.content}</div><div className="text-xs text-glass-muted mt-1">Added: {new Date(doc.created_at).toLocaleDateString()}</div></div>)}</div>
    </div>
  );
}
