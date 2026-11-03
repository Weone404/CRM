import { toMobile10 } from '../utils/formatters';
import { useState } from 'react';
import { API_URL } from '../api';
import { USE_SUPABASE } from '../backend/mode';

export default function StudentLogin({ onLogin, onBack }) {
  const [mobile, setMobile] = useState('');
  const [pin, setPin] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault(); setError(''); setLoading(true);
    try {
      const res = await fetch(`${API_URL}/api/auth/student-login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mobile: toMobile10(mobile), pin }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { setError(data.detail || `Login failed (${res.status})`); return; }
      localStorage.setItem('student_token', data.access_token);
      localStorage.setItem('student', JSON.stringify(data.student));
      onLogin(data.student);
    } catch (err) { setError('Could not reach the server. Check your connection and retry.'); }
    finally { setLoading(false); }
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4" style={{ background: 'linear-gradient(135deg, #1d1d1f 0%, #2c2c2e 50%, #1d1d1f 100%)' }}>
      <div className="glass-strong p-8 w-full max-w-md animate-glass-in">
        <div className="text-5xl text-center mb-3">🎓</div>
        <h1 className="text-2xl font-bold mb-1 text-center tracking-tight" style={{ color: '#1d1d1f' }}>Student Portal</h1>
        <p className="text-sm mb-7 text-center" style={{ color: '#6e6e73' }}>We One Aviation · Sign in to continue</p>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div><label className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>Mobile Number</label><input type="tel" inputMode="numeric" value={mobile} onChange={(e) => setMobile(e.target.value.replace(/[^\d+\s()-]/g, '').slice(0, 18))} className="glass-input w-full px-4 py-2.5 tracking-widest" placeholder="10-digit mobile number" autoComplete="username" required autoFocus /></div>
          <div><label className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>{USE_SUPABASE ? 'Password' : 'PIN'}</label>{USE_SUPABASE
            ? <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} className="glass-input w-full px-4 py-2.5" placeholder="Your password (first time: your mobile number)" autoComplete="current-password" required />
            : <input type="password" inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))} className="glass-input w-full px-4 py-2.5 tracking-widest" placeholder="4-digit PIN" maxLength={4} autoComplete="current-password" required />}</div>
          {error && <div className="rounded-lg px-4 py-3 text-sm" style={{ background: '#fef2f2', border: '1px solid #fca5a5', color: '#991b1b' }}>{error}</div>}
          <button type="submit" disabled={loading} className="glass-btn w-full py-2.5">{loading ? 'Signing in… (server may take up to a minute to wake)' : 'Sign in'}</button>
        </form>
        <div className="mt-6 pt-6 text-center" style={{ borderTop: '1px solid #e5e5ea' }}>
          <button onClick={onBack} className="text-sm" style={{ color: '#6e6e73' }}>← Back to Login</button>
        </div>
      </div>
    </div>
  );
}
