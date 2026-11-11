import { useState, useEffect, lazy, Suspense } from 'react';
import { createPortal } from 'react-dom';
import Login from './components/Login';
import EmployeeLogin from './components/EmployeeLogin';
import StudentLogin from './components/StudentLogin';
import LeadList from './components/LeadList';
import LoadingSpinner from './components/LoadingSpinner';
import BirthdayPopup from './components/BirthdayPopup';
import Icon from './components/icons';
import { apiFetch, fetchConfig, API_URL } from './api';
import { SEGMENTS, segmentOf } from './utils/charter';
import { signOutSupabase } from './backend/router';
import { USE_SUPABASE } from './backend/mode';
import { modalProps } from './components/ui/overlay';
import { showToast } from './utils/toast';
import { useRoute, navigate } from './utils/route';
import LinkTile from './components/ui/LinkTile';

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
const PhoneApp = lazy(() => import('./components/AppAlerts').then((m) => ({ default: m.PhoneApp })));
const BusinessEmail = lazy(() => import('./components/AppAlerts').then((m) => ({ default: m.BusinessEmail })));
const Connections = lazy(() => import('./components/Connections'));
const Amazon = lazy(() => import('./components/Amazon'));
const Ads = lazy(() => import('./components/Ads'));

// Tabs the birthday popup is allowed to appear over: the landing tab plus the
// two people-facing views. Anywhere else it would be an interruption.
const BIRTHDAY_TABS = ['leads', 'team', 'attendance'];
// The Academy section groups these screens, in this order.
const ACADEMY = ['students', 'team', 'attendance', 'tasks'];

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
  // Where we are comes from the address (#/tab/section?filters), so links, Back/Forward and refresh all work.
  const route = useRoute();
  const routeTab = route.tab || 'leads';
  useEffect(() => { window.scrollTo({ top: 0 }); }, [route.tab, route.section]);
  // Aviation (pilot training) or Charter (Book My Charter). Remembered per
  // browser so a charter desk stays on Charter; falls back safely if storage
  // is unavailable.
  const [segment, setSegmentState] = useState(() => {
    try { return localStorage.getItem('lead_segment') === 'charter' ? 'charter' : 'aviation'; } catch { return 'aviation'; }
  });
  const setSegment = (value) => { setSegmentState(value); try { localStorage.setItem('lead_segment', value); } catch { /* ignore */ } };
  const [showChangePassword, setShowChangePassword] = useState(false);
  const [showMore, setShowMore] = useState(false);
  const [showMoreMenu, setShowMoreMenu] = useState(false);
  const [passwordForm, setPasswordForm] = useState({ old_password: '', new_password: '', confirm_password: '' });
  const [passwordError, setPasswordError] = useState('');
  const [birthdays, setBirthdays] = useState([]);
  // Session-scoped dismissal: React state only. localStorage/sessionStorage are
  // unsupported for this, and the popup should come back on the next sign-in.
  const [birthdayDismissed, setBirthdayDismissed] = useState(false);

  const isEmployeeSession = employee?.is_employee_session === true;
  const department = employee?.department || '';
  // FlightBridge AI: CRM admins, plus anyone given a FlightBridge role (research assistant) in FlightBridge AI > Team.
  const [fbRole, setFbRole] = useState(null);
  useEffect(() => {
    if (!employee || department === 'Admin') { setFbRole(null); return; }
    let live = true;
    apiFetch('/api/flightbridge/me', { token: localStorage.getItem('token') })
      .then((r) => (r.ok ? r.json() : null)).then((m) => { if (live) setFbRole(m?.role || null); }).catch(() => {});
    return () => { live = false; };
  }, [employee, department]);
  const canAccessFlightBridge = department === 'Admin' || !!fbRole;
  // Amazon section (Supabase backend only): Admin, plus people Admin grants in Amazon > Settings.
  const [amzAccess, setAmzAccess] = useState(null);
  useEffect(() => {
    if (!employee || !USE_SUPABASE) { setAmzAccess(null); return undefined; }
    let live = true;
    import('./backend/supabaseClient').then(({ supabase }) => supabase?.rpc('api_amz_access'))
      .then((r) => { if (live) setAmzAccess(r && !r.error ? r.data : null); }).catch(() => {});
    return () => { live = false; };
  }, [employee]);
  const canAccessAmazon = USE_SUPABASE && !!amzAccess?.can_view;
  // Keep this phone's notification subscription fresh whenever the CRM opens (not only on the Amazon tab).
  useEffect(() => { if (canAccessAmazon) import('./components/AppAlerts').then((m) => m.syncPush()).catch(() => {}); }, [canAccessAmazon]);
  // ADS section (Supabase backend only): Admin, plus people Admin grants in ADS > Settings > Team access.
  const [adsAccess, setAdsAccess] = useState(null);
  useEffect(() => {
    if (!employee || !USE_SUPABASE) { setAdsAccess(null); return undefined; }
    let live = true;
    import('./backend/supabaseClient').then(({ supabase }) => supabase?.rpc('api_ads_access'))
      .then((r) => { if (live) setAdsAccess(r && !r.error ? r.data : null); }).catch(() => {});
    return () => { live = false; };
  }, [employee]);
  const canAccessAds = USE_SUPABASE && !!adsAccess?.can_view;
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
      showToast('Password changed — please sign in again', 'success'); handleLogout();
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
    canAccessLeads && { id: 'leads', label: 'Leads', icon: 'leads' },
    canAccessLeads && { id: 'students', label: 'Students', icon: 'students' },
    { id: 'tasks', label: isEmployeeSession ? 'My Tasks' : 'Tasks', icon: 'tasks' },
    canAccessCameras && { id: 'attendance', label: 'Attendance', icon: 'attendance' },
    canAccessDirectory && { id: 'team', label: 'Team', icon: 'team' },
    department === 'Admin' && { id: 'policy', label: 'Policy Docs', icon: 'policy' },
    canAccessFlightBridge && { id: 'partnerships', label: 'FlightBridge AI', icon: 'globe' },
    canAccessAmazon && { id: 'amazon', label: 'Amazon', icon: 'cart' },
    canAccessAds && { id: 'ads', label: 'ADS', icon: 'rocket' },
    USE_SUPABASE && department === 'Admin' && { id: 'settings', label: 'Settings', icon: 'settings' },
    isEmployeeSession && { id: 'profile', label: 'My Profile', icon: 'profile' },
    isEmployeeSession && { id: 'leave', label: 'My Leave', icon: 'calendar' },
  ].filter(Boolean);
  // Main sections: Leads, Academy (Students, Team, Attendance, Tasks), Amazon, ADS; everything else is under More.
  // Each screen keeps its own address (#/students, #/tasks ...), so old links and bookmarks still work.
  const academyKids = ACADEMY.map((id) => tabs.find((t) => t.id === id)).filter(Boolean);
  const pick = (id) => tabs.find((t) => t.id === id);
  const primary = [
    pick('leads'),
    academyKids.length > 0 && { id: 'academy', label: 'Academy', logo: true },
    pick('amazon'),
    pick('ads'),
  ].filter(Boolean);
  const moreTabs = tabs.filter((t) => !['leads', 'amazon', 'ads', ...ACADEMY].includes(t.id));
  const lastAcademy = () => { try { const v = localStorage.getItem('academy_tab'); return academyKids.some((k) => k.id === v) ? v : null; } catch { return null; } };
  const wanted = routeTab === 'academy' ? (lastAcademy() || academyKids[0]?.id) : routeTab;
  const activeTab = tabs.some((t) => t.id === wanted) ? wanted : (primary[0]?.id === 'academy' ? academyKids[0]?.id : primary[0]?.id) || tabs[0]?.id || 'tasks';
  const section = ACADEMY.includes(activeTab) ? 'academy' : activeTab;
  const go = (id) => {
    setShowMore(false); setShowMoreMenu(false);
    if (id === 'academy') { navigate(lastAcademy() || academyKids[0]?.id); return; }
    if (ACADEMY.includes(id)) { try { localStorage.setItem('academy_tab', id); } catch { /* ignore */ } }
    navigate(id);
  };
  const moreActive = moreTabs.some((t) => t.id === activeTab);
  const tabIcon = (t, size, active) => (t.logo
    ? <img src="/icons/academy-mark.png" alt="" width={size + 4} height={size} style={{ width: size + 4, height: size }} className={`nav-logo ${active ? 'is-active' : ''}`} />
    : <Icon name={t.icon} size={size} strokeWidth={active ? 2.3 : 1.8} />);

  return (
    <div className="min-h-screen app-shell">
      {/* Top bar + tabs stay together at the top while scrolling */}
      <header className="sticky top-0 z-40 glass-nav safe-top">
      <nav className="px-3 sm:px-6 py-2.5 flex justify-between items-center gap-2 relative">
        <h1 className="text-base sm:text-xl font-bold tracking-tight flex items-center gap-2 min-w-0 text-glass-primary">
          <img src="/icons/crm-mark.png" alt="" width={32} height={32} className="rounded-[9px] shrink-0" style={{ width: 32, height: 32, boxShadow: '0 1px 3px rgba(0,0,0,0.12), 0 0 0 0.5px rgba(0,0,0,0.06)' }} />
          <span className="truncate">CRM</span>
        </h1>
        <div className="flex items-center gap-1.5 sm:gap-2 shrink-0">
          {canAccessLeads && (
            <button onClick={() => setShowOutbox(true)} className="glass-btn-ghost px-3 py-2 text-sm inline-flex items-center gap-1.5 min-h-[40px]" aria-label="Outbox">
              <Icon name="outbox" size={16} /><span className="hidden sm:inline">Outbox</span>
            </button>
          )}
          <span className="hidden lg:inline text-sm text-glass-secondary px-1">{employee.name}</span>
          <button onClick={() => setShowChangePassword(true)} className="glass-btn-ghost px-2.5 py-2 text-sm hidden md:inline-flex items-center min-h-[40px]" title="Change password" aria-label="Change password"><Icon name="lock" size={16} /></button>
          <button onClick={handleLogout} className="glass-btn-ghost px-3 py-2 text-sm hidden md:inline-flex items-center gap-1.5 min-h-[40px]"><Icon name="logout" size={16} />Logout</button>
        </div>
      </nav>

      {/* Tabs: tablet and desktop */}
      <div className="hidden md:flex items-center whitespace-nowrap relative px-2 sm:px-4 pb-1" role="tablist" aria-label="Sections">
        {primary.map((t) => (
          <button key={t.id} role="tab" aria-selected={section === t.id} onClick={() => go(t.id)}
            className={`glass-tab-btn inline-flex items-center gap-2 ${section === t.id ? 'active' : ''}`}>
            {tabIcon(t, 16, section === t.id)}{t.label}
          </button>
        ))}
        {moreTabs.length > 0 && (
          <div className="relative">
            <button type="button" aria-haspopup="menu" aria-expanded={showMoreMenu} onClick={() => setShowMoreMenu((v) => !v)}
              className={`glass-tab-btn inline-flex items-center gap-2 ${moreActive ? 'active' : ''}`}>
              <Icon name="more" size={16} />{moreActive ? tabs.find((t) => t.id === activeTab)?.label : 'More'}<Icon name="chevronDown" size={14} />
            </button>
            {showMoreMenu && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setShowMoreMenu(false)} aria-hidden="true" />
                <div role="menu" aria-label="More" className="absolute left-0 top-full mt-1 z-50 min-w-[220px] more-menu p-1.5 animate-glass-in"
                  onKeyDown={(e) => { if (e.key === 'Escape') setShowMoreMenu(false); }}>
                  {moreTabs.map((t) => (
                    <button key={t.id} role="menuitem" onClick={() => go(t.id)}
                      className={`menu-item w-full flex items-center gap-3 px-3 min-h-[42px] rounded-xl text-sm text-left ${activeTab === t.id ? 'is-active' : ''}`}>
                      <Icon name={t.icon} size={17} />{t.label}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        )}
      </div>
      </header>

      {/* Tabs: phones (bottom bar) */}
      <nav className="md:hidden fixed bottom-0 inset-x-0 z-40 glass-nav tab-bar" aria-label="Sections">
        <div className="grid" style={{ gridTemplateColumns: `repeat(${primary.length + 1}, minmax(0, 1fr))` }}>
          {primary.map((t) => (
            <button key={t.id} onClick={() => go(t.id)} aria-current={section === t.id ? 'page' : undefined} aria-label={t.label}
              className={`tab-bar-btn ${section === t.id ? 'is-active' : ''}`}>
              {tabIcon(t, 22, section === t.id)}<span className="truncate max-w-full px-1">{t.label}</span>
            </button>
          ))}
          <button onClick={() => setShowMore(true)} aria-haspopup="dialog" aria-label="More"
            className={`tab-bar-btn ${moreActive ? 'is-active' : ''}`}>
            <Icon name="more" size={22} strokeWidth={moreActive ? 2.3 : 1.8} /><span>More</span>
          </button>
        </div>
      </nav>

      {showMore && createPortal(
        <div className="md:hidden fixed inset-0 z-50 glass-overlay flex items-end" {...modalProps(() => setShowMore(false))}>
          <div className="w-full glass-strong rounded-b-none p-4 pb-6 animate-glass-in" style={{ paddingBottom: 'calc(1.5rem + env(safe-area-inset-bottom))' }} role="dialog" aria-label="More" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-2">
              <div className="font-semibold text-glass-primary">{employee.name}</div>
              <button onClick={() => setShowMore(false)} className="p-2 rounded-full text-glass-muted min-h-[44px] min-w-[44px] inline-flex items-center justify-center" aria-label="Close"><Icon name="close" size={20} /></button>
            </div>
            <div className="grid grid-cols-1 gap-1">
              {moreTabs.length > 0 && moreTabs.map((t) => (
                <button key={t.id} onClick={() => go(t.id)} className={`flex items-center gap-3 px-3 min-h-[48px] rounded-xl text-base ${activeTab === t.id ? 'bg-[var(--accent-light)] text-[var(--accent)] font-semibold' : 'text-glass-primary'}`}>
                  <Icon name={t.icon} size={20} />{t.label}
                </button>
              ))}
              {moreTabs.length > 0 && <div className="h-px my-1" style={{ background: 'var(--border-subtle)' }} />}
              <button onClick={() => { setShowMore(false); setShowChangePassword(true); }} className="flex items-center gap-3 px-3 min-h-[48px] rounded-xl text-base text-glass-primary"><Icon name="lock" size={20} />Change password</button>
              <button onClick={handleLogout} className="flex items-center gap-3 px-3 min-h-[48px] rounded-xl text-base text-red-600"><Icon name="logout" size={20} />Logout</button>
            </div>
          </div>
        </div>,
        document.body
      )}

      {/* Main Content */}
      <div className="p-4 sm:p-6 max-w-7xl mx-auto">
        {section === 'academy' && academyKids.length > 1 && (
          <div className="seg-control mb-4" role="tablist" aria-label="Academy" style={{ gridTemplateColumns: `repeat(${academyKids.length}, minmax(0, 1fr))` }}>
            {academyKids.map((t) => (
              <button key={t.id} role="tab" aria-selected={activeTab === t.id} onClick={() => go(t.id)} className={activeTab === t.id ? 'is-active' : ''}>
                <Icon name={t.icon} size={16} /><span className="truncate">{t.label}</span>
              </button>
            ))}
          </div>
        )}
        {activeTab === 'leads' && canAccessLeads && leadsError && (
          <div className="glass-card p-6 text-center animate-glass-in" style={{ borderColor: 'rgba(255,59,48,0.35)' }}>
            <div className="text-lg font-semibold text-red-800 mb-1 inline-flex items-center gap-2"><Icon name="alert" size={18} />Couldn't load leads</div>
            <p className="text-sm text-red-700 mb-4">{leadsError}</p>
            <button onClick={syncNow} className="glass-btn px-4 py-2" style={{ background: '#FF3B30' }}>Retry</button>
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
            <div className="grid grid-cols-2 gap-1 mb-4 p-1 rounded-xl" style={{ background: 'rgba(118,118,128,0.12)' }} role="tablist" aria-label="Lead segment">
              {SEGMENTS.map(s => {
                const list = leads.filter(l => segmentOf(l) === s.id);
                const active = segment === s.id;
                const fresh = untouched(list);
                return (
                  <button key={s.id} role="tab" aria-selected={active} onClick={() => setSegment(s.id)}
                    className={`flex items-center justify-center gap-1.5 sm:gap-2 py-2.5 px-2 sm:px-3 rounded-lg text-[13px] sm:text-base font-semibold transition min-w-0 ${active ? 'bg-white text-glass-primary shadow-[0_3px_8px_rgba(0,0,0,0.12),0_3px_1px_rgba(0,0,0,0.04)]' : 'text-glass-secondary hover:text-glass-primary hover:bg-white/50'}`}>
                    <span aria-hidden="true" className="hidden sm:inline">{s.icon}</span><span className="truncate">{s.label}</span>
                    <span className="text-xs font-medium opacity-80 shrink-0">({list.length})</span>
                    {fresh > 0 && <span className="ml-0.5 shrink-0 min-w-[1.25rem] px-1.5 rounded-full bg-orange-500 text-white text-xs leading-5">{fresh}</span>}
                  </button>
                );
              })}
            </div>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <LinkTile to={['leads', '', { filter: 'all' }]} className="glass-stat p-4" title="Show every lead"><div className="text-sm text-glass-secondary">{segment === 'charter' ? 'Charter Enquiries' : 'Total Leads'}</div><div className="text-2xl font-bold text-glass-primary">{segmentLeads.length}</div></LinkTile>
              <LinkTile to={['leads', '', { filter: 'pending' }]} className="glass-stat p-4" title="Show leads nobody has contacted yet"><div className="text-sm text-glass-secondary">Untouched</div><div className="text-2xl font-bold text-orange-600">{untouched(segmentLeads)}</div></LinkTile>
              <button type="button" className="tile-link glass-stat p-4 text-left" title="Show the follow-ups due"
                onClick={() => document.getElementById('lead-followups')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>
                <div className="text-sm text-glass-secondary">Pending Follow-ups</div><div className="text-2xl font-bold text-blue-600">{segmentFollowups.length}</div>
              </button>
            </div>
            {segmentFollowups.length > 0 && (
              <div id="lead-followups" className="glass-card p-4 mb-4" style={{ background: 'rgba(255,149,0,0.10)', borderColor: 'rgba(255,204,0,0.45)' }}>
                <h3 className="font-semibold mb-2 text-glass-primary inline-flex items-center gap-2"><Icon name="clock" size={16} />Follow-ups due</h3>
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
              <div className="flex flex-wrap justify-between items-center gap-2 mb-4">
                <h2 className="text-lg font-semibold text-glass-primary">{segment === 'charter' ? 'Book My Charter Leads' : 'We One Aviation Leads'}</h2>
                <div className="flex gap-2">
                  <button onClick={() => setShowAddQuery(true)} className="glass-btn px-4 py-2 inline-flex items-center gap-1.5 min-h-[40px]" style={{ background: '#248A3D' }}><Icon name="plus" size={16} />{segment === 'charter' ? 'Add Enquiry' : 'Add Query'}</button>
                  <button onClick={syncNow} className="glass-btn px-4 py-2 inline-flex items-center gap-1.5 min-h-[40px]"><Icon name="refresh" size={16} />Sync</button>
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
          {activeTab === 'partnerships' && canAccessFlightBridge && <FlightBridge />}
          {activeTab === 'amazon' && canAccessAmazon && <Amazon access={amzAccess} />}
          {activeTab === 'ads' && canAccessAds && <Ads access={adsAccess} />}
          {activeTab === 'settings' && USE_SUPABASE && department === 'Admin' && <div className="space-y-4"><PhoneApp notifications={canAccessAmazon} /><BusinessEmail /><AIIntegrations /><Connections /></div>}
          {activeTab === 'profile' && isEmployeeSession && <div className="space-y-4"><MyProfile />{USE_SUPABASE && <PhoneApp notifications={canAccessAmazon} />}</div>}
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
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(() => { setShowChangePassword(false); setPasswordForm({ old_password: '', new_password: '', confirm_password: '' }); setPasswordError(''); }, { guard: true })}>
          <div className="glass-strong max-w-md w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
            <h2 className="text-xl font-bold mb-4 text-glass-primary">Change Password</h2>
            {passwordError && <div className="mb-4 p-3 rounded-lg text-sm" style={{ background: 'rgba(255,59,48,0.08)', border: '1px solid rgba(255,59,48,0.35)', color: '#D70015' }}>{passwordError}</div>}
            <form onSubmit={handleChangePassword} className="space-y-4">
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Current Password</label><input type="password" value={passwordForm.old_password} onChange={(e) => setPasswordForm({...passwordForm, old_password: e.target.value})} className="glass-input w-full px-3 py-2" required autoComplete="current-password" /></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">New Password</label><input type="password" value={passwordForm.new_password} onChange={(e) => setPasswordForm({...passwordForm, new_password: e.target.value})} className="glass-input w-full px-3 py-2" required minLength={6} autoComplete="new-password" /><p className="text-xs text-glass-muted mt-1">Minimum 6 characters</p></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Confirm New Password</label><input type="password" value={passwordForm.confirm_password} onChange={(e) => setPasswordForm({...passwordForm, confirm_password: e.target.value})} className="glass-input w-full px-3 py-2" required minLength={6} autoComplete="new-password" /></div>
              <div className="flex gap-3 pt-4">
                <button type="submit" className="glass-btn flex-1 px-4 py-2">Change Password</button>
                <button type="button" onClick={() => { setShowChangePassword(false); setPasswordForm({ old_password: '', new_password: '', confirm_password: '' }); setPasswordError(''); }} className="px-4 py-2 rounded-lg font-medium transition" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Cancel</button>
              </div>
            </form>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
