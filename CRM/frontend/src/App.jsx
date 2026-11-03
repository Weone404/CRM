import { useState, useEffect, lazy, Suspense } from 'react';
import { createPortal } from 'react-dom';
import Login from './components/Login';
import EmployeeLogin from './components/EmployeeLogin';
import StudentLogin from './components/StudentLogin';
import LeadList from './components/LeadList';
import LoadingSpinner from './components/LoadingSpinner';
import BirthdayPopup from './components/BirthdayPopup';
import { apiFetch, fetchConfig, API_URL } from './api';
import { SEGMENTS, segmentOf } from './utils/charter';
import { signOutSupabase } from './backend/router';
import { USE_SUPABASE } from './backend/mode';

// Code-split everything that isn't needed for the first paint. Each of these
// tabs/modals now ships as its own chunk fetched on demand, so a Sales user
// never downloads the 700-line Attendance view, etc. Cuts the initial bundle.
const StudentPortal = lazy(() => import('./components/StudentPortal'));
const LeadDetail = lazy(() => import('./components/LeadDetail'));
const Outbox = lazy(() => import('./components/Outbox'));
const TaskBoard = lazy(() => import('./components/TaskBoard'));
const EmployeeDirectory = lazy(() => import('./components/EmployeeDirectory'));
const MyProfile = lazy(() => import('./components/MyProfile'));
const LeaveCalendar = lazy(() => import('./components/LeaveCalendar'));
const PolicyDocs = lazy(() => import('./components/PolicyDocs'));
const AddQuery = lazy(() => import('./components/AddQuery'));
const StudentDirectory = lazy(() => import('./components/StudentDirectory'));
const Attendance = lazy(() => import('./components/Attendance'));
const FlightBridge = lazy(() => import('./components/FlightBridge'));
const AIIntegrations = lazy(() => import('./components/AIIntegrations'));

// Tabs the birthday popup is allowed to appear over: the landing tab plus the
// two people-facing views. Anywhere else it would be an interruption.
const BIRTHDAY_TABS = ['leads', 'team', 'attendance'];

export default function App() {
  const [employee, setEmployee] = useState(null);
  const [showEmployeeLogin, setShowEmployeeLogin] = useState(false);
  const [student, setStudent] = useState(null);
  const [showStudentLogin, setShowStudentLogin] = useState(false);
  const [leads, setLeads] = useState([]);
  const [leadsError, setLeadsError] = useState('');
  const [followups, setFollowups] = useState([]);
  const [selectedLead, setSelectedLead] = useState(null);
  const [showOutbox, setShowOutbox] = useState(false);
  const [showAddQuery, setShowAddQuery] = useState(false);
  const [config, setConfig] = useState({});
  const [activeTab, setActiveTab] = useState('leads');
  // Aviation (pilot training) or Charter (Book My Charter). Remembered per
  // browser so a charter desk stays on Charter; falls back safely if storage
  // is unavailable.
  const [segment, setSegmentState] = useState(() => {
    try { return localStorage.getItem('lead_segment') === 'charter' ? 'charter' : 'aviation'; } catch { return 'aviation'; }
  });
  const setSegment = (value) => { setSegmentState(value); try { localStorage.setItem('lead_segment', value); } catch { /* ignore */ } };
  const [showChangePassword, setShowChangePassword] = useState(false);
  const [passwordForm, setPasswordForm] = useState({ old_password: '', new_password: '', confirm_password: '' });
  const [passwordError, setPasswordError] = useState('');
  const [birthdays, setBirthdays] = useState([]);
  // Session-scoped dismissal: React state only. localStorage/sessionStorage are
  // unsupported for this, and the popup should come back on the next sign-in.
  const [birthdayDismissed, setBirthdayDismissed] = useState(false);

  const isEmployeeSession = employee?.is_employee_session === true;
  const department = employee?.department || '';
  const canAccessLeads = department === 'Admin' || department === 'Sales';
  const canAccessDirectory = department === 'Admin';
  const canAccessAllTasks = department === 'Admin';
  const canAccessCameras = department === 'Admin';

  useEffect(() => {
    const token = localStorage.getItem('token');
    const empStr = localStorage.getItem('employee');
    if (token && empStr) { setEmployee(JSON.parse(empStr)); return; }
    const studentToken = localStorage.getItem('student_token');
    const studentStr = localStorage.getItem('student');
    if (studentToken && studentStr) { setStudent(JSON.parse(studentStr)); }
  }, []);

  // Poll only the live data (leads + follow-ups). This used to also pull the
  // heavy /api/sync snapshot (all employees + 500 leads + 1000 contact attempts)
  // every 60s and throw almost all of it away — pure wasted bandwidth/CPU.
  useEffect(() => {
    if (employee) {
      syncNow();
      const interval = setInterval(syncNow, 60000);
      return () => clearInterval(interval);
    }
  }, [employee]);

  // Config barely ever changes, so load it once per session instead of on every
  // poll. Only lead-capable roles can open AddQuery (its only consumer).
  useEffect(() => {
    const token = localStorage.getItem('token');
    if (!employee || !token) return;
    if (isEmployeeSession && !canAccessLeads) return;
    fetchConfig(token).then(setConfig).catch(() => { /* keep defaults */ });
  }, [employee]);

  // Today's birthdays: fetched ONCE when the session starts and passed down.
  // Deliberately not part of syncNow() — it changes at most once a day, so
  // polling it every 60s alongside the leads would be pure waste.
  useEffect(() => {
    const token = localStorage.getItem('token');
    if (!employee || !token) return;
    apiFetch('/api/birthdays/today', { token })
      .then((res) => (res.ok ? res.json() : []))
      .then((data) => setBirthdays(Array.isArray(data) ? data : []))
      .catch(() => { /* a missed birthday must never break the app */ });
  }, [employee]);

  const syncNow = async () => {
    const token = localStorage.getItem('token');
    if (!token) return;
    const shouldFetchLeads = !isEmployeeSession || canAccessLeads;
    if (!shouldFetchLeads) return;
    try {
      // Fetch leads + pending follow-ups concurrently (was sequential).
      const [leadsRes, followupsRes] = await Promise.all([
        apiFetch('/api/leads', { token }),
        apiFetch('/api/followups/pending', { token }),
      ]);
      if (leadsRes.ok) {
        setLeads(await leadsRes.json()); setLeadsError('');
      } else {
        let detail = '';
        try { detail = (await leadsRes.json()).detail || ''; } catch { }
        setLeadsError(`Server error (HTTP ${leadsRes.status})${detail ? `: ${detail}` : ''}. Data was not loaded.`);
        return;
      }
      if (followupsRes.ok) setFollowups(await followupsRes.json());
    } catch (err) {
      console.error('Sync failed:', err);
      setLeadsError('Could not reach the server. Check your connection and retry.');
    }
  };

  const handleContact = async (leadId, data) => {
    const token = localStorage.getItem('token');
    if (data.closure_outcome) {
      await fetch(`${API_URL}/api/leads/${leadId}/close`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ closure_outcome: data.closure_outcome, note: data.note }) });
      await syncNow(); return;
    }
    if (data.followup) {
      await fetch(`${API_URL}/api/leads/${leadId}/followup`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ due_date: data.due_date, reason: data.reason }) });
    } else {
      await fetch(`${API_URL}/api/leads/${leadId}/contact`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
    }
    await syncNow();
  };

  const handleLogout = () => { if (USE_SUPABASE) signOutSupabase(); localStorage.removeItem('token'); localStorage.removeItem('employee'); setEmployee(null); };
  const handleStudentLogout = () => { if (USE_SUPABASE) signOutSupabase(); localStorage.removeItem('student_token'); localStorage.removeItem('student'); setStudent(null); setShowStudentLogin(false); };

  const handleChangePassword = async (e) => {
    e.preventDefault(); setPasswordError('');
    if (passwordForm.new_password !== passwordForm.confirm_password) { setPasswordError('New passwords do not match'); return; }
    if (passwordForm.new_password.length < 6) { setPasswordError('Password must be at least 6 characters'); return; }
    try {
      const token = localStorage.getItem('token');
      const res = await fetch(`${API_URL}/api/auth/change-password`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ old_password: passwordForm.old_password, new_password: passwordForm.new_password }) });
      if (!res.ok) { const error = await res.json(); setPasswordError(error.detail || 'Failed to change password'); return; }
      alert('Password changed successfully! Please login again.'); handleLogout();
    } catch (error) { setPasswordError('Failed to change password'); }
  };

  if (student && !employee) return (
    <Suspense fallback={<LoadingSpinner />}>
      <StudentPortal onLogout={handleStudentLogout} />
    </Suspense>
  );
  if (!employee) {
    if (showStudentLogin) return <StudentLogin onLogin={setStudent} onBack={() => setShowStudentLogin(false)} />;
    return showEmployeeLogin ? <EmployeeLogin onLogin={setEmployee} /> : <Login onLogin={setEmployee} onSwitchToEmployee={() => setShowEmployeeLogin(true)} onSwitchToStudent={() => setShowStudentLogin(true)} />;
  }

  const tabs = [
    canAccessLeads && { id: 'leads', label: 'Leads' },
    canAccessLeads && { id: 'students', label: 'Students' },
    { id: 'tasks', label: isEmployeeSession ? 'My Tasks' : 'Tasks' },
    canAccessCameras && { id: 'attendance', label: '📷 Attendance' },
    canAccessDirectory && { id: 'team', label: 'Team' },
    department === 'Admin' && { id: 'policy', label: 'Policy Docs' },
    department === 'Admin' && { id: 'partnerships', label: 'FlightBridge AI' },
    USE_SUPABASE && department === 'Admin' && { id: 'settings', label: '⚙️ Settings' },
    isEmployeeSession && { id: 'profile', label: 'My Profile' },
    isEmployeeSession && { id: 'leave', label: 'My Leave' },
  ].filter(Boolean);

  return (
    <div className="min-h-screen" style={{ background: "#f5f5f7" }}>
      {/* Glass Navigation */}
      <nav className="glass-nav text-white px-4 sm:px-6 py-3 flex justify-between items-center sticky top-0 z-40">
        <h1 className="text-lg sm:text-xl font-bold tracking-tight">
          ✈️ We One Aviation <span className="font-normal text-indigo-200">· CRM</span>
        </h1>
        <div className="flex items-center gap-2 sm:gap-3">
          {canAccessLeads && (
            <button onClick={() => setShowOutbox(true)} className="glass-btn-ghost px-3 py-1.5 text-sm">📤 Outbox</button>
          )}
          <span className="hidden sm:inline text-sm text-indigo-100">👤 {employee.name}</span>
          <button onClick={() => setShowChangePassword(true)} className="glass-btn-ghost px-2.5 py-1.5 text-sm" title="Change Password">🔒</button>
          <button onClick={handleLogout} className="glass-btn-ghost px-3 py-1.5 text-sm">Logout</button>
        </div>
      </nav>

      {/* Glass Tab Bar */}
      <div className="glass-tabs overflow-x-auto whitespace-nowrap sticky top-[57px] z-30">
        {tabs.map((t) => (
          <button key={t.id} onClick={() => setActiveTab(t.id)} className={`glass-tab-btn ${activeTab === t.id ? 'active' : ''}`}>{t.label}</button>
        ))}
      </div>

      {/* Main Content */}
      <div className="p-4 sm:p-6 max-w-7xl mx-auto">
        {activeTab === 'leads' && canAccessLeads && leadsError && (
          <div className="glass-card p-6 text-center animate-glass-in" style={{ borderColor: '#fca5a5' }}>
            <div className="text-lg font-semibold text-red-800 mb-1">⚠️ Couldn't load leads</div>
            <p className="text-sm text-red-700 mb-4">{leadsError}</p>
            <button onClick={syncNow} className="glass-btn px-4 py-2" style={{ background: '#ef4444' }}>Retry</button>
          </div>
        )}

        {activeTab === 'leads' && canAccessLeads && !leadsError && (() => {
          const segmentLeads = leads.filter(l => segmentOf(l) === segment);
          const segmentIds = new Set(segmentLeads.map(l => l.id));
          const segmentFollowups = followups.filter(f => segmentIds.has(f.lead_id));
          const untouched = (list) => list.filter(l => !l.first_contacted_at).length;
          return (
          <>
            {/* Aviation / Charter switch. Each segment has its own counts,
                follow-ups, filters and Add Query form. */}
            <div className="grid grid-cols-2 gap-2 mb-4 p-1 rounded-xl" style={{ background: 'rgba(0,0,0,0.05)' }} role="tablist" aria-label="Lead segment">
              {SEGMENTS.map(s => {
                const list = leads.filter(l => segmentOf(l) === s.id);
                const active = segment === s.id;
                const fresh = untouched(list);
                return (
                  <button key={s.id} role="tab" aria-selected={active} onClick={() => setSegment(s.id)}
                    className={`flex items-center justify-center gap-2 py-2.5 px-3 rounded-lg text-sm sm:text-base font-semibold transition ${active ? 'bg-indigo-600 text-white shadow' : 'text-glass-secondary hover:text-glass-primary hover:bg-white/60'}`}>
                    <span aria-hidden="true">{s.icon}</span>{s.label}
                    <span className="text-xs font-medium opacity-80">({list.length})</span>
                    {fresh > 0 && <span className="ml-1 min-w-[1.25rem] px-1.5 rounded-full bg-orange-500 text-white text-xs leading-5">{fresh}</span>}
                  </button>
                );
              })}
            </div>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <div className="glass-stat p-4"><div className="text-sm text-glass-secondary">{segment === 'charter' ? 'Charter Enquiries' : 'Total Leads'}</div><div className="text-2xl font-bold text-glass-primary">{segmentLeads.length}</div></div>
              <div className="glass-stat p-4"><div className="text-sm text-glass-secondary">Untouched</div><div className="text-2xl font-bold text-orange-600">{untouched(segmentLeads)}</div></div>
              <div className="glass-stat p-4"><div className="text-sm text-glass-secondary">Pending Follow-ups</div><div className="text-2xl font-bold text-blue-600">{segmentFollowups.length}</div></div>
            </div>
            {segmentFollowups.length > 0 && (
              <div className="glass-card p-4 mb-4" style={{ background: '#fffbe6', borderColor: '#fde047' }}>
                <h3 className="font-semibold mb-2 text-glass-primary">⏰ Follow-ups Due</h3>
                <div className="space-y-2">
                  {segmentFollowups.slice(0, 3).map(f => (
                    <div key={f.id} className="flex justify-between items-center text-sm">
                      <span className="text-glass-primary"><span className="font-semibold">{f.lead_name}</span> - {f.reason}</span>
                      <button onClick={() => { const lead = leads.find(l => l.id === f.lead_id); if (lead) setSelectedLead(lead); }} className="text-indigo-600 hover:underline font-medium">Contact</button>
                    </div>
                  ))}
                </div>
              </div>
            )}
            <div className="glass-card p-4">
              <div className="flex justify-between items-center mb-4">
                <h2 className="text-lg font-semibold text-glass-primary">{segment === 'charter' ? 'Charter Leads' : 'Aviation Leads'}</h2>
                <div className="flex gap-2">
                  <button onClick={() => setShowAddQuery(true)} className="glass-btn px-4 py-2" style={{ background: '#22c55e' }}>＋ {segment === 'charter' ? 'Add Enquiry' : 'Add Query'}</button>
                  <button onClick={syncNow} className="glass-btn px-4 py-2">Sync</button>
                </div>
              </div>
              <LeadList leads={segmentLeads} segment={segment} onSelectLead={setSelectedLead} />
            </div>
          </>
          );
        })()}

        <Suspense fallback={<LoadingSpinner />}>
          {activeTab === 'students' && canAccessLeads && <StudentDirectory />}
          {activeTab === 'tasks' && <TaskBoard />}
          {activeTab === 'attendance' && canAccessCameras && <Attendance />}
          {activeTab === 'team' && canAccessDirectory && <EmployeeDirectory />}
          {activeTab === 'policy' && department === 'Admin' && <PolicyDocs />}
          {activeTab === 'partnerships' && department === 'Admin' && <FlightBridge />}
          {activeTab === 'settings' && USE_SUPABASE && department === 'Admin' && <AIIntegrations />}
          {activeTab === 'profile' && isEmployeeSession && <MyProfile />}
          {activeTab === 'leave' && isEmployeeSession && <LeaveCalendar employeeId={employee.id} />}
        </Suspense>
      </div>

      <Suspense fallback={null}>
        {selectedLead && <LeadDetail lead={selectedLead} onClose={() => setSelectedLead(null)} onContact={handleContact} />}
        {showOutbox && <Outbox onClose={() => setShowOutbox(false)} />}
        {showAddQuery && <AddQuery segment={segment} requiredQualification={config.eligibility_required_qualification || '12th with Physics & Maths'} onClose={() => setShowAddQuery(false)} onCreated={() => { setShowAddQuery(false); syncNow(); }} onOpenExisting={(leadId) => { setShowAddQuery(false); const existing = leads.find(l => l.id === leadId); if (existing) setSelectedLead(existing); }} />}
      </Suspense>

      {/* Only on the landing tab and the two people-facing tabs. BirthdayPopup
          itself renders nothing when nobody has a birthday today. */}
      {!birthdayDismissed && BIRTHDAY_TABS.includes(activeTab) && (
        <BirthdayPopup people={birthdays} onClose={() => setBirthdayDismissed(true)} />
      )}

      {showChangePassword && createPortal(
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
          <div className="glass-strong max-w-md w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
            <h2 className="text-xl font-bold mb-4 text-glass-primary">Change Password</h2>
            {passwordError && <div className="mb-4 p-3 rounded-lg text-sm" style={{ background: '#fef2f2', border: '1px solid #fca5a5', color: '#991b1b' }}>{passwordError}</div>}
            <form onSubmit={handleChangePassword} className="space-y-4">
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Current Password</label><input type="password" value={passwordForm.old_password} onChange={(e) => setPasswordForm({...passwordForm, old_password: e.target.value})} className="glass-input w-full px-3 py-2" required autoComplete="current-password" /></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">New Password</label><input type="password" value={passwordForm.new_password} onChange={(e) => setPasswordForm({...passwordForm, new_password: e.target.value})} className="glass-input w-full px-3 py-2" required minLength={6} autoComplete="new-password" /><p className="text-xs text-glass-muted mt-1">Minimum 6 characters</p></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Confirm New Password</label><input type="password" value={passwordForm.confirm_password} onChange={(e) => setPasswordForm({...passwordForm, confirm_password: e.target.value})} className="glass-input w-full px-3 py-2" required minLength={6} autoComplete="new-password" /></div>
              <div className="flex gap-3 pt-4">
                <button type="submit" className="glass-btn flex-1 px-4 py-2">Change Password</button>
                <button type="button" onClick={() => { setShowChangePassword(false); setPasswordForm({ old_password: '', new_password: '', confirm_password: '' }); setPasswordError(''); }} className="px-4 py-2 rounded-lg font-medium transition" style={{ background: '#f3f4f6', color: '#424245' }}>Cancel</button>
              </div>
            </form>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
