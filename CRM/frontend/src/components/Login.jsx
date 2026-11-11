import { lazy, Suspense, useState } from 'react';
import { login } from '../api';
import { USE_SUPABASE } from '../backend/mode';

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
    <div className="relative min-h-screen overflow-hidden flex items-center justify-center p-4 sm:p-8">
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center lg:justify-start lg:pl-[6vw] opacity-90">
        <div className="w-[130vw] h-[130vw] max-w-[760px] max-h-[760px] sm:w-[90vw] sm:h-[90vw] lg:w-[46vw] lg:h-[46vw]">
          <Suspense fallback={null}><Globe3D ambient /></Suspense>
        </div>
      </div>
      <div className="relative w-full max-w-5xl grid lg:grid-cols-2 gap-8 items-center">
        <div className="hidden lg:block glass-strong p-7 mr-6 self-end mb-8 max-w-lg">
          <div className="inline-flex items-center gap-2 text-sm font-semibold px-3 py-1 mb-4 rounded-full" style={{ color: '#248A3D', background: 'rgba(52,199,89,0.14)' }}>
            <span className="h-2 w-2 rounded-full" style={{ background: '#34C759' }} />Live
          </div>
          <h2 className="text-4xl font-bold tracking-tight leading-tight" style={{ color: 'rgba(0,0,0,0.92)' }}>Every student, every lead,<br />every flying school.</h2>
          <p className="mt-3 text-lg" style={{ color: 'rgba(0,0,0,0.6)' }}>One place for the We One Aviation team.</p>
        </div>
        <div className="glass-strong p-6 sm:p-8 w-full max-w-md mx-auto lg:ml-auto animate-glass-in">
          <div className="flex justify-center mb-3"><img src="/icons/icon-192.png" alt="CRM" width={64} height={64} className="h-16 w-16 rounded-[16px]" style={{ boxShadow: '0 4px 14px rgba(0,0,0,0.12), 0 0 0 0.5px rgba(0,0,0,0.06)' }} /></div>
          <h1 className="text-2xl font-bold mb-1 text-center tracking-tight" style={{ color: 'rgba(0,0,0,0.92)' }}>CRM</h1>
          <p className="text-base mb-6 text-center" style={{ color: 'rgba(0,0,0,0.6)' }}>Sign in to continue</p>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label htmlFor="login-id" className="block text-sm font-medium mb-1.5" style={{ color: 'rgba(0,0,0,0.6)' }}>{USE_SUPABASE ? 'Login ID, phone or email' : 'Login ID'}</label>
              <input id="login-id" type="text" value={loginId} onChange={(e) => setLoginId(e.target.value)} className="glass-input w-full px-4 py-3 text-base" placeholder={USE_SUPABASE ? "Login ID, phone or email" : "Your login ID"} autoComplete="username" required autoFocus />
            </div>
            <div>
              <label htmlFor="login-pw" className="block text-sm font-medium mb-1.5" style={{ color: 'rgba(0,0,0,0.6)' }}>Password</label>
              <input id="login-pw" type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="glass-input w-full px-4 py-3 text-base" autoComplete="current-password" required />
            </div>
            {error && <div role="alert" className="rounded-lg px-4 py-3 text-sm" style={{ background: 'rgba(255,59,48,0.08)', border: '1px solid rgba(255,59,48,0.35)', color: '#D70015' }}>{error}</div>}
            <button type="submit" disabled={loading} className="glass-btn w-full py-3 text-base">{loading ? (USE_SUPABASE ? 'Signing in…' : 'Signing in… (server may take up to a minute to wake)') : 'Sign in'}</button>
          </form>
          <div className="mt-6 pt-5 grid grid-cols-2 gap-2" style={{ borderTop: '1px solid rgba(60,60,67,0.12)' }}>
            <button onClick={onSwitchToEmployee} className="text-sm font-medium rounded-lg min-h-[44px] hover:bg-[var(--accent-light)]" style={{ color: '#007AFF' }}>Employee login</button>
            <button onClick={onSwitchToStudent} className="text-sm font-medium rounded-lg min-h-[44px] hover:bg-[var(--accent-light)]" style={{ color: '#007AFF' }}>Student login</button>
          </div>
        </div>
      </div>
    </div>
  );
}
