import { lazy, Suspense, useState } from 'react';
import { login } from '../api';
import { USE_SUPABASE } from '../backend/mode';
import Icon from './icons';

// Live globe behind the sign-in card (loads after the form, so signing in is never slowed down).
const Globe3D = lazy(() => import('./Globe3D'));

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
    <div className="relative min-h-screen overflow-hidden flex items-center justify-center p-4 sm:p-8"
      style={{ background: 'radial-gradient(110% 80% at 70% 30%, #0b2540 0%, #050b16 55%, #02060d 100%)' }}>
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center lg:justify-start lg:pl-[6vw] opacity-60 lg:opacity-90">
        <div className="w-[130vw] h-[130vw] max-w-[760px] max-h-[760px] sm:w-[90vw] sm:h-[90vw] lg:w-[46vw] lg:h-[46vw]">
          <Suspense fallback={null}><Globe3D ambient /></Suspense>
        </div>
      </div>
      <div className="relative w-full max-w-5xl grid lg:grid-cols-2 gap-8 items-center">
        <div className="hidden lg:block text-white pr-6">
          <div className="inline-flex items-center gap-2 text-sm font-medium px-3 py-1 rounded-full mb-4" style={{ background: 'rgba(34,211,238,0.12)', color: '#67e8f9', border: '1px solid rgba(34,211,238,0.25)' }}>
            <span className="h-2 w-2 rounded-full" style={{ background: '#22d3ee', boxShadow: '0 0 8px #22d3ee' }} />Live
          </div>
          <h2 className="text-4xl font-bold tracking-tight leading-tight">Every student, every lead,<br />every flying school.</h2>
          <p className="mt-3 text-lg" style={{ color: '#94a3b8' }}>One place for the We One Aviation team.</p>
        </div>
        <div className="glass-strong p-6 sm:p-8 w-full max-w-md mx-auto lg:ml-auto animate-glass-in">
          <div className="flex justify-center mb-3" style={{ color: '#0071e3' }}><Icon name="plane" size={40} strokeWidth={1.6} /></div>
          <h1 className="text-2xl font-bold mb-1 text-center tracking-tight" style={{ color: '#1d1d1f' }}>We One Aviation</h1>
          <p className="text-base mb-6 text-center" style={{ color: '#6e6e73' }}>CRM · Sign in to continue</p>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label htmlFor="login-id" className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>{USE_SUPABASE ? 'Login ID, phone or email' : 'Login ID'}</label>
              <input id="login-id" type="text" value={loginId} onChange={(e) => setLoginId(e.target.value)} className="glass-input w-full px-4 py-3 text-base" placeholder={USE_SUPABASE ? "Login ID, phone or email" : "Your login ID"} autoComplete="username" required autoFocus />
            </div>
            <div>
              <label htmlFor="login-pw" className="block text-sm font-medium mb-1.5" style={{ color: '#424245' }}>Password</label>
              <input id="login-pw" type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="glass-input w-full px-4 py-3 text-base" autoComplete="current-password" required />
            </div>
            {error && <div role="alert" className="rounded-lg px-4 py-3 text-sm" style={{ background: '#fef2f2', border: '1px solid #fca5a5', color: '#991b1b' }}>{error}</div>}
            <button type="submit" disabled={loading} className="glass-btn w-full py-3 text-base">{loading ? (USE_SUPABASE ? 'Signing in…' : 'Signing in… (server may take up to a minute to wake)') : 'Sign in'}</button>
          </form>
          <div className="mt-6 pt-5 grid grid-cols-2 gap-2" style={{ borderTop: '1px solid #e5e5ea' }}>
            <button onClick={onSwitchToEmployee} className="text-sm font-medium rounded-lg min-h-[44px] hover:bg-[var(--accent-light)]" style={{ color: '#0071e3' }}>Employee login</button>
            <button onClick={onSwitchToStudent} className="text-sm font-medium rounded-lg min-h-[44px] hover:bg-[var(--accent-light)]" style={{ color: '#0071e3' }}>Student login</button>
          </div>
        </div>
      </div>
    </div>
  );
}
