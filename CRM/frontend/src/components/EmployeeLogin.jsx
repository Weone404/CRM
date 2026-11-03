import { useState } from 'react';
import { showToast } from '../utils/toast';
import { API_URL } from '../api';
import { USE_SUPABASE } from '../backend/mode';

export default function EmployeeLogin({ onLogin }) {
  const [loginId, setLoginId] = useState('');
  const [pin, setPin] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault(); setLoading(true);
    try {
      const res = await fetch(`${API_URL}/api/auth/employee-login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ login_id: loginId, pin }) });
      if (res.ok) {
        const data = await res.json();
        localStorage.setItem('token', data.access_token);
        localStorage.setItem('employee', JSON.stringify(data.employee));
        onLogin(data.employee);
        showToast(`Welcome, ${data.employee.name}!`, 'success');
      } else { const error = await res.json(); showToast(error.detail || 'Login failed', 'error'); }
    } catch (error) { showToast('Login error', 'error'); }
    setLoading(false);
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4" style={{ background: 'linear-gradient(135deg, #1d1d1f 0%, #2c2c2e 50%, #1d1d1f 100%)' }}>
      <div className="glass-strong p-8 max-w-md w-full animate-glass-in">
        <div className="text-center mb-8">
          <div className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-4" style={{ background: '#0071e3', boxShadow: '0 4px 12px rgba(0,113,227,0.30)' }}>
            <span className="text-3xl text-white">👤</span>
          </div>
          <h1 className="text-2xl font-bold" style={{ color: '#1d1d1f' }}>Employee Portal</h1>
          <p className="text-sm mt-2" style={{ color: '#6e6e73' }}>Sign in to access your workspace</p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-6">
          <div><label className="block text-sm font-medium mb-2" style={{ color: '#424245' }}>{USE_SUPABASE ? 'Login ID, phone or email' : 'Login ID'}</label><input type="text" value={loginId} onChange={(e) => setLoginId(e.target.value)} className="glass-input w-full px-4 py-3" placeholder="Enter your login ID" required autoFocus /></div>
          <div><label className="block text-sm font-medium mb-2" style={{ color: '#424245' }}>{USE_SUPABASE ? 'Password' : 'PIN (if set)'}</label>{USE_SUPABASE
            ? <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} className="glass-input w-full px-4 py-3" placeholder="Your password (first time: your mobile number)" autoComplete="current-password" required />
            : <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} className="glass-input w-full px-4 py-3" placeholder="4-digit PIN (optional)" maxLength={4} pattern="[0-9]*" />}</div>
          <button type="submit" disabled={loading} className="glass-btn w-full py-3">{loading ? 'Signing In...' : 'Sign In'}</button>
        </form>
        <div className="mt-6 pt-6 text-center" style={{ borderTop: '1px solid #e5e5ea' }}>
          <button onClick={() => window.location.reload()} className="text-sm" style={{ color: '#6e6e73' }}>← Back to Admin Login</button>
        </div>
      </div>
    </div>
  );
}
