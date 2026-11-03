import { useState } from 'react';
import { login } from '../api';
import { USE_SUPABASE } from '../backend/mode';

export default function Login({ onLogin, onSwitchToEmployee, onSwitchToStudent }) {
  const [loginId, setLoginId] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault(); setError(''); setLoading(true);
    try {
      const data = await login(loginId, password);
      localStorage.setItem('token', data.access_token);
      localStorage.setItem('employee', JSON.stringify(data.employee));
      onLogin(data.employee);
    } catch (err) { setError(USE_SUPABASE ? (err.message || 'Incorrect login details.') : 'Invalid credentials'); }
    finally { setLoading(false); }
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4" style={{ background: 'linear-gradient(135deg, #1d1d1f 0%, #2c2c2e 50%, #1d1d1f 100%)' }}>
      <div className="glass-strong p-8 w-full max-w-md animate-glass-in">
        <div className="text-5xl text-center mb-3">✈️</div>
        <h1 className="text-2xl font-bold mb-1 text-center tracking-tight" style={{ color: '#1d1d1f' }}>We One Aviation</h1>
        <p className="text-sm mb-7 text-center" style={{ color: '#6e6e73' }}>CRM · Sign in to continue</p>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>{USE_SUPABASE ? 'Login ID, phone or email' : 'Login ID'}</label>
            <input type="text" value={loginId} onChange={(e) => setLoginId(e.target.value)} className="glass-input w-full px-4 py-2.5" placeholder={USE_SUPABASE ? "Login ID, phone or email" : "Your login ID"} autoComplete="username" required autoFocus />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>Password</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="glass-input w-full px-4 py-2.5" autoComplete="current-password" required />
          </div>
          {error && <div className="rounded-lg px-4 py-3 text-sm" style={{ background: '#fef2f2', border: '1px solid #fca5a5', color: '#991b1b' }}>{error}</div>}
          <button type="submit" disabled={loading} className="glass-btn w-full py-2.5">{loading ? 'Signing in… (server may take up to a minute to wake)' : 'Sign in'}</button>
        </form>
        <div className="mt-6 pt-6 text-center flex flex-col gap-3" style={{ borderTop: '1px solid #e5e5ea' }}>
          <button onClick={onSwitchToEmployee} className="text-sm font-medium hover:underline" style={{ color: '#0071e3' }}>Employee Login →</button>
          <button onClick={onSwitchToStudent} className="text-sm font-medium hover:underline" style={{ color: '#0071e3' }}>Student Login →</button>
        </div>
      </div>
    </div>
  );
}
