import { useState, useEffect, useRef, lazy, Suspense } from 'react';
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
import Sidebar, { groupTabs } from './components/ui/Sidebar';
import SignalPill from './components/ui/SignalPill';
import ErrorBoundary from './components/ui/ErrorBoundary';
import Home from './components/Home';
import { markSynced } from './utils/netStatus';

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
const PhoneApp = lazy(() => import('./components/AppAlerts').then((m) => ({ default: m.PhoneApp })));
const BusinessEmail = lazy(() => import('./components/AppAlerts').then((m) => ({ default: m.BusinessEmail })));
const Vault = lazy(() => import('./components/Vault'));
const Website = lazy(() => import('./components/Website'));
const Content = lazy(() => import('./components/Content'));
const Amazon = lazy(() => import('./components/Amazon'));
const Ads = lazy(() => import('./components/Ads'));
const AdsMeta = lazy(() => import('./components/AdsMeta'));
const AdsLeads = lazy(() => import('./components/AdsLeads'));

// Tabs the birthday popup is allowed to appear over: the landing tab plus the
// two people-facing views. Anywhere else it would be an interruption.
const BIRTHDAY_TABS = ['home', 'leads', 'team', 'attendance'];
// Section access (Amazon, ADS). A slow network or a token refresh right after opening the app used to hide the
// section until a reload; now: last known answer first, then up to 4 tries, and again whenever the app comes back to the screen.
function loadAccess(fn, employee, set) {
  const key = `access:${fn}:${employee?.id || employee?.name || ''}`;
  try { const c = JSON.parse(sessionStorage.getItem(key) || 'null'); if (c) set(c); } catch { /* ignore */ }
  let live = true, timer = null;
  const tryLoad = (attempt = 0) => {
    import('./backend/supabaseClient').then(({ supabase }) => supabase?.rpc(fn)).then((r) => {
      if (!live) return;
      if (r && !r.error && r.data) { set(r.data); try { sessionStorage.setItem(key, JSON.stringify(r.data)); } catch { /* ignore */ } return; }
      throw new Error('retry');
    }).catch(() => { if (live && attempt < 3) timer = setTimeout(() => tryLoad(attempt + 1), [1500, 4000, 10000][attempt]); });
  };
  tryLoad();
  const again = () => { if (document.visibilityState === 'visible') tryLoad(); };
  document.addEventListener('visibilitychange', again);
  return () => { live = false; clearTimeout(timer); document.removeEventListener('visibilitychange', again); };
}

// Old links to the former "Academy" group still open one of its screens.
const ACADEMY = ['students', 'team', 'attendance', 'tasks'];

export default function App() {
  const [employee, setEmployee] = useState(null);
  const [showEmployeeLogin, setShowEmployeeLogin] = useState(false);
  const [student, setStudent] = useState(null);
  const [showStudentLogin, setShowStudentLogin] = useState(false);
  const [leads, setLeads] = useState([]);
  const [leadsError, setLeadsError] = useState('');
  const [leadsReady, setLeadsReady] = useState(false);
  // When a refresh fails but we already have data: keep showing it, say how old it is, retry quietly.
  const [staleSince, setStaleSince] = useState(0);
  const haveLeadsRef = useRef(false);
  const lastSyncRef = useRef(0);
  const retryRef = useRef({ timer: null, fails: 0 });
  const syncingRef = useRef(null);
  const [followups, setFollowups] = useState([]);
  const [selectedLead, setSelectedLead] = useState(null);
  const [showOutbox, setShowOutbox] = useState(false);
  const [showAddQuery, setShowAddQuery] = useState(false);
  const [config, setConfig] = useState({});
  // Where we are comes from the address (#/tab/section?filters), so links, Back/Forward and refresh all work.
  const route = useRoute();
  const routeTab = route.tab || 'home';
  useEffect(() => { window.scrollTo({ top: 0 }); }, [route.tab, route.section]);
  // Aviation (pilot training) or Charter (Book My Charter). Remembered per
  // browser so a charter desk stays on Charter; falls back safely if storage
  // is unavailable.
  const [segment, setSegmentState] = useState(() => {
    try { const v = localStorage.getItem('lead_segment'); return v === 'charter' || v === 'meta' ? v : 'aviation'; } catch { return 'aviation'; }
  });
  const setSegment = (value) => { setSegmentState(value); try { localStorage.setItem('lead_segment', value); } catch { /* ignore */ } };
  const [showChangePassword, setShowChangePassword] = useState(false);
  const [showMore, setShowMore] = useState(false);
  const [vw, setVw] = useState(() => (typeof window === 'undefined' ? 390 : window.innerWidth));
  useEffect(() => { const f = () => setVw(window.innerWidth); window.addEventListener('resize', f); return () => window.removeEventListener('resize', f); }, []);
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
    return loadAccess('api_amz_access', employee, setAmzAccess);
  }, [employee]);
  const canAccessAmazon = USE_SUPABASE && !!amzAccess?.can_view;
  // Keep this phone's notification subscription fresh whenever the CRM opens (not only on the Amazon tab).
  useEffect(() => { if (canAccessAmazon) import('./components/AppAlerts').then((m) => m.syncPush()).catch(() => {}); }, [canAccessAmazon]);
  // ADS section (Supabase backend only): Admin, plus people Admin grants in ADS > Settings > Team access.
  const [adsAccess, setAdsAccess] = useState(null);
  useEffect(() => {
    if (!employee || !USE_SUPABASE) { setAdsAccess(null); return undefined; }
    return loadAccess('api_ads_access', employee, setAdsAccess);
  }, [employee]);
  const canAccessAds = USE_SUPABASE && !!adsAccess?.can_view;
  // Leads > Meta Leads: the same records as Meta Ads > Leads (people who filled the Meta lead form), counted here for the tab.
  const [metaCount, setMetaCount] = useState(null);
  useEffect(() => {
    if (!canAccessAds || routeTab !== 'leads') return undefined;
    let live = true;
    const pull = () => import('./components/adsKit').then((m) => m.rpc('api_ads_lead_board', { p_platform: 'meta', p_limit: 1 }))
      .then((b) => { if (live) setMetaCount(b?.stats || null); }, () => {});
    pull(); const i = setInterval(pull, 60000);
    return () => { live = false; clearInterval(i); };
  }, [canAccessAds, routeTab]);
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
    if (!employee) return undefined;
    syncNow();
    // Refresh every minute while the CRM is on screen; a hidden tab does not poll (saves battery and server load).
    const interval = setInterval(() => { if (document.visibilityState === 'visible') syncNow(); }, 60000);
    // Coming back to the tab or back online: refresh straight away if the data is older than 20 s.
    const back = () => { if (document.visibilityState === 'visible' && Date.now() - lastSyncRef.current > 20000) syncNow(); };
    document.addEventListener('visibilitychange', back);
    window.addEventListener('online', back);
    return () => {
      clearInterval(interval); clearTimeout(retryRef.current.timer);
      document.removeEventListener('visibilitychange', back); window.removeEventListener('online', back);
    };
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
    if (syncingRef.current) return syncingRef.current;          // one refresh at a time; extra clicks share it
    const run = (async () => {
      const failed = (message) => {
        if (haveLeadsRef.current) {
          // We already show data: keep it, mark it as saved data, retry with growing gaps (10 s, 20 s, 40 s, 60 s).
          setStaleSince((t) => t || lastSyncRef.current || Date.now());
          const r = retryRef.current; r.fails += 1; clearTimeout(r.timer);
          r.timer = setTimeout(() => syncNow(), Math.min(60000, 10000 * 2 ** (r.fails - 1)));
        } else {
          setLeadsError(message);
        }
      };
      try {
        const [leadsRes, followupsRes] = await Promise.all([
          apiFetch('/api/leads', { token }),
          apiFetch('/api/followups/pending', { token }),
        ]);
        if (!leadsRes.ok) {
          let detail = '';
          try { detail = (await leadsRes.json()).detail || ''; } catch { }
          failed(leadsRes.status >= 500 && /reach|internet|in time/i.test(detail) ? detail : `Server error (HTTP ${leadsRes.status})${detail ? `: ${detail}` : ''}. Data was not loaded.`);
          return;
        }
        setLeads(await leadsRes.json()); setLeadsError(''); setLeadsReady(true);
        haveLeadsRef.current = true; lastSyncRef.current = Date.now(); setStaleSince(0);
        clearTimeout(retryRef.current.timer); retryRef.current.fails = 0;
        markSynced();
        if (followupsRes.ok) setFollowups(await followupsRes.json());
      } catch (err) {
        console.error('Sync failed:', err);
        failed('Could not reach the server. Check your connection and retry.');
      }
    })();
    syncingRef.current = run;
    try { await run; } finally { syncingRef.current = null; }
  };

  const handleContact = async (leadId, data) => {
    const token = localStorage.getItem('token');
    const post = (path, body) => fetch(`${API_URL}/api/leads/${leadId}/${path}`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    let res;
    try {
      if (data.closure_outcome) res = await post('close', { closure_outcome: data.closure_outcome, note: data.note });
      else if (data.followup) res = await post('followup', { due_date: data.due_date, reason: data.reason });
      else res = await post('contact', data);
    } catch { res = null; }
    if (!res || !res.ok) {
      const msg = res ? ((await res.json().catch(() => ({}))).detail || `HTTP ${res.status}`) : 'No connection';
      showToast(`Not saved: ${msg}. Please try again.`, 'error');
      throw new Error(msg);                                      // lets the lead panel keep what was typed
    }
    await syncNow();
  };

  const handleLogout = () => {
    if (USE_SUPABASE) signOutSupabase();
    localStorage.removeItem('token'); localStorage.removeItem('employee');
    try { Object.keys(sessionStorage).filter((k) => k.startsWith('access:')).forEach((k) => sessionStorage.removeItem(k)); } catch { /* ignore */ }
    setEmployee(null);
  };
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
    { id: 'home', label: 'Home', icon: 'home' },
    canAccessLeads && { id: 'leads', label: 'Leads', icon: 'leads' },
    canAccessLeads && { id: 'students', label: 'Students', icon: 'students' },
    { id: 'tasks', label: isEmployeeSession ? 'My Tasks' : 'Tasks', icon: 'tasks' },
    canAccessCameras && { id: 'attendance', label: 'Attendance', icon: 'attendance' },
    canAccessDirectory && { id: 'team', label: 'Team', icon: 'team' },
    department === 'Admin' && { id: 'policy', label: 'Policy Docs', icon: 'policy' },
    canAccessFlightBridge && { id: 'partnerships', label: 'FlightBridge AI', icon: 'globe' },
    canAccessAmazon && { id: 'amazon', label: 'Amazon', icon: 'cart' },
    (canAccessAds || (USE_SUPABASE && department === 'Admin')) && { id: 'website', label: 'Website', icon: 'chart' },
    (canAccessAds || (USE_SUPABASE && department === 'Admin')) && { id: 'content', label: 'Content', icon: 'image' },
    canAccessAds && { id: 'ads', label: 'Google Ads', icon: 'rocket' },
    canAccessAds && { id: 'metaads', label: 'Meta Ads', icon: 'send' },
    USE_SUPABASE && department === 'Admin' && { id: 'connections', label: 'Connections & keys', icon: 'lock' },
    USE_SUPABASE && department === 'Admin' && { id: 'settings', label: 'Settings', icon: 'settings' },
    isEmployeeSession && { id: 'profile', label: 'My Profile', icon: 'profile' },
    isEmployeeSession && { id: 'leave', label: 'My Leave', icon: 'calendar' },
  ].filter(Boolean);
  // Change password and Logout live in an Account card: in Settings (Admin), My Profile (staff), or an Account page for everyone else.
  if (!tabs.some((t) => t.id === 'settings' || t.id === 'profile')) tabs.push({ id: 'account', label: 'Account', icon: 'profile' });
  const accountCard = (
    <div className="glass-card p-4 flex flex-wrap items-center justify-between gap-3">
      <div className="min-w-0">
        <div className="text-xs font-semibold uppercase tracking-wide text-glass-muted">Signed in as</div>
        <div className="font-semibold text-glass-primary truncate">{employee.name}{department ? <span className="font-normal text-glass-secondary"> · {department}</span> : null}</div>
      </div>
      <div className="flex items-center gap-2">
        <button type="button" onClick={() => setShowChangePassword(true)} className="glass-btn-ghost px-4 py-2 text-sm inline-flex items-center gap-2 min-h-[40px]"><Icon name="lock" size={16} />Change password</button>
        <button type="button" onClick={handleLogout} className="glass-btn-ghost px-4 py-2 text-sm inline-flex items-center gap-2 min-h-[40px] text-red-600"><Icon name="logout" size={16} />Logout</button>
      </div>
    </div>
  );
  // Navigation: grouped sidebar on laptops (Home / People / Growth / Setup), bottom bar + grouped sheet on phones and tablets.
  // Each screen keeps its own address (#/students, #/tasks ...), so old links and bookmarks still work.
  const lastAcademy = () => { try { const v = localStorage.getItem('academy_tab'); return ACADEMY.includes(v) && tabs.some((t) => t.id === v) ? v : null; } catch { return null; } };
  const wanted = routeTab === 'academy' ? (lastAcademy() || ACADEMY.find((id) => tabs.some((t) => t.id === id))) : routeTab;
  const activeTab = tabs.some((t) => t.id === wanted) ? wanted : 'home';
  const section = activeTab;
  const go = (id) => {
    setShowMore(false);
    if (ACADEMY.includes(id)) { try { localStorage.setItem('academy_tab', id); } catch { /* ignore */ } }
    navigate(id);
  };
  const untouchedCount = canAccessLeads ? leads.filter((l) => !l.first_contacted_at && !l.closed && !l.closure_outcome).length : 0;
  const navBadges = { leads: untouchedCount || 0 };
  // Phones: the most used sections in the bar (about 72px each); everything else in the grouped "More" sheet.
  const PHONE_FIRST = ['home', 'leads', 'tasks', 'students', 'ads', 'metaads'];
  const ordered = [...PHONE_FIRST.map((id) => tabs.find((t) => t.id === id)).filter(Boolean), ...tabs.filter((t) => !PHONE_FIRST.includes(t.id))];
  const slots = Math.min(5, Math.max(3, Math.floor(vw / 72)));
  const barItems = ordered.length <= slots ? ordered : ordered.slice(0, slots - 1);
  const sheetItems = ordered.slice(barItems.length);
  const sheetActive = sheetItems.some((t) => t.id === section);
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
          <SignalPill />
          {canAccessLeads && (
            <button onClick={() => setShowOutbox(true)} className="glass-btn-ghost px-3 py-2 text-sm inline-flex items-center gap-1.5 min-h-[40px]" aria-label="Outbox">
              <Icon name="outbox" size={16} /><span className="hidden sm:inline">Outbox</span>
            </button>
          )}
          <span className="hidden lg:inline text-sm text-glass-secondary px-1">{employee.name}</span>
        </div>
      </nav>

      </header>

      {/* Tabs: phones and tablets (bottom bar) */}
      <nav className="lg:hidden fixed bottom-0 inset-x-0 z-40 glass-nav tab-bar" aria-label="Sections">
        <div className="grid" style={{ gridTemplateColumns: `repeat(${barItems.length + (sheetItems.length > 0 ? 1 : 0)}, minmax(0, 1fr))` }}>
          {barItems.map((t) => (
            <button key={t.id} onClick={() => go(t.id)} aria-current={section === t.id ? 'page' : undefined} aria-label={t.label}
              className={`tab-bar-btn ${section === t.id ? 'is-active' : ''}`}>
              {tabIcon(t, 22, section === t.id)}<span className="truncate max-w-full px-1">{t.label}</span>
            </button>
          ))}
          {sheetItems.length > 0 && (
            <button onClick={() => setShowMore(true)} aria-haspopup="dialog" aria-label="More" title="More"
              className={`tab-bar-btn ${sheetActive ? 'is-active' : ''}`}>
              <span className="nav-dots-mobile"><Icon name="more" size={24} strokeWidth={2.4} /></span>
            </button>
          )}
        </div>
      </nav>

      {showMore && createPortal(
        <div className="lg:hidden fixed inset-0 z-50 glass-overlay flex items-end" {...modalProps(() => setShowMore(false))}>
          <div className="w-full glass-strong rounded-b-none p-4 pb-6 animate-glass-in" style={{ paddingBottom: 'calc(1.5rem + env(safe-area-inset-bottom))' }} role="dialog" aria-label="More" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-2">
              <div className="font-semibold text-glass-primary">{employee.name}</div>
              <button onClick={() => setShowMore(false)} className="p-2 rounded-full text-glass-muted min-h-[44px] min-w-[44px] inline-flex items-center justify-center" aria-label="Close"><Icon name="close" size={20} /></button>
            </div>
            {groupTabs(sheetItems).map((g) => (
              <div key={g.id} className="mb-2">
                {g.label && <div className="px-3 pt-2 pb-1 text-[11px] font-semibold uppercase tracking-[0.05em] text-glass-secondary">{g.label}</div>}
                <div className="grid grid-cols-1 gap-1">
                  {g.items.map((t) => (
                    <button key={t.id} onClick={() => go(t.id)} className={`flex items-center gap-3 px-3 min-h-[48px] rounded-xl text-base ${section === t.id ? 'bg-[var(--accent-light)] text-[var(--accent)] font-semibold' : 'text-glass-primary'}`}>
                      {tabIcon(t, 20, section === t.id)}{t.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>,
        document.body
      )}

      {/* Sidebar (laptops) + the open section */}
      <div className="flex items-start">
      <Sidebar tabs={tabs} active={section} onSelect={go} badges={navBadges} />
      <main className="flex-1 min-w-0 p-4 sm:p-6">
      <div className="max-w-7xl mx-auto">
      <ErrorBoundary name={tabs.find((t) => t.id === activeTab)?.label} resetKey={activeTab}>
        {activeTab === 'home' && (
          <Home employee={employee} leads={leads} followups={followups} leadsReady={leadsReady}
            canAccessLeads={canAccessLeads} canAccessAds={canAccessAds} canOpenKeys={USE_SUPABASE && department === 'Admin'} onOpenTab={(tab, sec, params) => navigate(tab, sec, params)} />
        )}
        {activeTab === 'leads' && canAccessLeads && staleSince > 0 && !leadsError && (
          <div className="crm-stale mb-4" role="status">
            <Icon name="clock" size={15} />
            <span>Couldn't refresh. Showing leads from {new Date(staleSince).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' })}; retrying automatically.</span>
            <button type="button" onClick={syncNow} className="ml-auto font-medium underline">Retry now</button>
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
          const segTabs = canAccessAds ? [...SEGMENTS, { id: 'meta', label: 'Meta Leads', icon: '📣' }] : SEGMENTS;
          const seg = segment === 'meta' && !canAccessAds ? 'aviation' : segment;
          const SHORT = { aviation: 'Aviation', charter: 'Charter', meta: 'Meta' };
          const segmentLeads = leads.filter(l => segmentOf(l) === seg);
          const segmentIds = new Set(segmentLeads.map(l => l.id));
          const segmentFollowups = followups.filter(f => segmentIds.has(f.lead_id));
          const untouched = (list) => list.filter(l => !l.first_contacted_at).length;
          return (
          <>
            {/* Aviation / Charter switch. Each segment has its own counts,
                follow-ups, filters and Add Query form. */}
            <div className={`grid ${segTabs.length === 3 ? 'grid-cols-3' : 'grid-cols-2'} gap-1 mb-4 p-1 rounded-xl`} style={{ background: 'rgba(118,118,128,0.12)' }} role="tablist" aria-label="Lead segment" data-testid="lead-segments">
              {segTabs.map(s => {
                const isMeta = s.id === 'meta';
                const list = isMeta ? null : leads.filter(l => segmentOf(l) === s.id);
                const active = seg === s.id;
                const total = isMeta ? metaCount?.total : list.length;
                const fresh = isMeta ? (metaCount?.not_contacted || 0) : untouched(list);
                return (
                  <button key={s.id} role="tab" aria-selected={active} onClick={() => setSegment(s.id)}
                    className={`flex items-center justify-center gap-1 sm:gap-2 py-2.5 px-1.5 sm:px-3 rounded-lg text-[13px] sm:text-base font-semibold transition min-w-0 ${active ? 'bg-white text-glass-primary shadow-[0_3px_8px_rgba(0,0,0,0.12),0_3px_1px_rgba(0,0,0,0.04)]' : 'text-glass-secondary hover:text-glass-primary hover:bg-white/50'}`}>
                    <span aria-hidden="true" className="hidden sm:inline">{s.icon}</span>
                    <span className="truncate"><span className="md:hidden">{SHORT[s.id]}</span><span className="hidden md:inline">{s.label}</span></span>
                    {total !== undefined && total !== null && <span className="text-xs font-medium opacity-80 shrink-0">({total})</span>}
                    {fresh > 0 && <span className="shrink-0 min-w-[1.25rem] px-1.5 rounded-full bg-orange-500 text-white text-xs leading-5">{fresh}</span>}
                  </button>
                );
              })}
            </div>
            {seg === 'meta' ? (
              <Suspense fallback={<LoadingSpinner />}><AdsLeads access={adsAccess} platform="meta" inLeads /></Suspense>
            ) : <>
            <div className="grid grid-cols-3 gap-2 sm:gap-4 mb-4" data-testid="lead-counters">
              <LinkTile to={['leads', '', { filter: 'all' }]} className="glass-stat p-3 sm:p-4" title="Show every lead"><div className="text-xs sm:text-sm text-glass-secondary truncate">{seg === 'charter' ? 'Enquiries' : 'Total'}<span className="hidden sm:inline">{seg === 'charter' ? '' : ' Leads'}</span></div><div className="text-xl sm:text-2xl font-bold text-glass-primary">{segmentLeads.length}</div></LinkTile>
              <LinkTile to={['leads', '', { filter: 'pending' }]} className="glass-stat p-3 sm:p-4" title="Show leads nobody has contacted yet"><div className="text-xs sm:text-sm text-glass-secondary truncate">Untouched</div><div className="text-xl sm:text-2xl font-bold text-orange-600">{untouched(segmentLeads)}</div></LinkTile>
              <button type="button" className="tile-link glass-stat p-3 sm:p-4 text-left min-w-0" title="Show the follow-ups due"
                onClick={() => document.getElementById('lead-followups')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>
                <div className="text-xs sm:text-sm text-glass-secondary truncate"><span className="hidden sm:inline">Pending </span>Follow-ups</div><div className="text-xl sm:text-2xl font-bold text-blue-600">{segmentFollowups.length}</div>
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
                <h2 className="text-lg font-semibold text-glass-primary">{seg === 'charter' ? 'Book My Charter Leads' : 'We One Aviation Leads'}</h2>
                <div className="flex gap-2 w-full sm:w-auto">
                  <button onClick={() => setShowAddQuery(true)} className="glass-btn px-4 py-2 inline-flex items-center justify-center gap-1.5 min-h-[40px] flex-1 sm:flex-none" style={{ background: '#248A3D' }}><Icon name="plus" size={16} />{seg === 'charter' ? 'Add Enquiry' : 'Add Query'}</button>
                  <button onClick={syncNow} className="glass-btn px-4 py-2 inline-flex items-center justify-center gap-1.5 min-h-[40px] flex-1 sm:flex-none"><Icon name="refresh" size={16} />Sync</button>
                </div>
              </div>
              <LeadList leads={segmentLeads} segment={seg} onSelectLead={setSelectedLead} />
            </div>
            </>}
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
          {activeTab === 'metaads' && canAccessAds && <AdsMeta access={adsAccess} />}
          {activeTab === 'settings' && USE_SUPABASE && department === 'Admin' && <div className="space-y-4">{accountCard}<PhoneApp notifications={canAccessAmazon} /><BusinessEmail />
            <button type="button" onClick={() => navigate('connections')} className="glass-card tile-link w-full p-4 flex items-center justify-between gap-3 text-left">
              <span><span className="block font-semibold text-glass-primary">API keys, tokens and connections</span><span className="block text-sm text-glass-secondary">Now all in one place: Setup &gt; Connections &amp; keys</span></span>
              <Icon name="lock" size={18} />
            </button></div>}
          {activeTab === 'profile' && isEmployeeSession && <div className="space-y-4">{accountCard}<MyProfile />{USE_SUPABASE && <PhoneApp notifications={canAccessAmazon} />}</div>}
          {activeTab === 'account' && <div className="space-y-4">{accountCard}{USE_SUPABASE && <PhoneApp notifications={canAccessAmazon} />}</div>}
          {activeTab === 'leave' && isEmployeeSession && <LeaveCalendar employeeId={employee.id} />}
          {activeTab === 'connections' && USE_SUPABASE && department === 'Admin' && <Vault />}
          {activeTab === 'website' && <Website />}
          {activeTab === 'content' && <Content />}
        </Suspense>
      </ErrorBoundary>
      </div>
      </main>
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
