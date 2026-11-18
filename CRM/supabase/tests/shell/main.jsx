// Test-only page: the new CRM shell pieces (sidebar, signal indicator, Home, section error guard) plus hooks for the checks.
import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import '../../../frontend/src/index.css';
import Sidebar from '../../../frontend/src/components/ui/Sidebar';
import SignalPill from '../../../frontend/src/components/ui/SignalPill';
import ErrorBoundary from '../../../frontend/src/components/ui/ErrorBoundary';
import Home, { homeNumbers } from '../../../frontend/src/components/Home';
import { supabase, timedFetch, LIMITS } from '../../../frontend/src/backend/supabaseClient';
import { handleApiRequest } from '../../../frontend/src/backend/router';
import * as net from '../../../frontend/src/utils/netStatus';
import { renewSession, _resetRenew } from '../../../frontend/src/utils/session';

const DAY = 86400000, now = Date.now();
const lead = (daysAgo, extra = {}) => ({ id: String(Math.random()), name: 'x', created_at: new Date(now - daysAgo * DAY).toISOString(), status: 'new', utm_source: 'website', ...extra });
const LEADS = [lead(1), lead(2, { first_contacted_at: 'x', status: 'Interested' }), lead(3, { first_contacted_at: 'x', status: 'Not reachable' }),
  lead(9, { first_contacted_at: 'x', status: 'Not reachable', utm_source: 'Book My Charter website' }), lead(20, { first_contacted_at: 'x', status: 'Not reachable' }), lead(40, { first_contacted_at: 'x' })];
const TABS = [
  { id: 'home', label: 'Home', icon: 'home' }, { id: 'leads', label: 'Leads', icon: 'leads' }, { id: 'tasks', label: 'Tasks', icon: 'tasks' },
  { id: 'ads', label: 'Google Ads', icon: 'rocket' }, { id: 'metaads', label: 'Meta Ads', icon: 'send' }, { id: 'settings', label: 'Settings', icon: 'settings' },
  { id: 'brandnew', label: 'Brand new', icon: 'zap' },
];
function Crasher({ on }) { if (on) throw new Error('boom'); return <p>section fine</p>; }
function Shell() {
  const [active, setActive] = useState('home');
  const [crash, setCrash] = useState(false);
  return (
    <div>
      <header style={{ display: 'flex', justifyContent: 'flex-end', padding: 8 }}><SignalPill /></header>
      <div className="flex items-start">
        <Sidebar tabs={TABS} active={active} onSelect={(id) => { setActive(id); setCrash(false); }} badges={{ leads: 1 }} />
        <main className="flex-1 p-4">
          <button id="crash" onClick={() => setCrash(true)}>crash</button>
          <ErrorBoundary name="Test section" resetKey={active}><Crasher on={crash && active === 'home'} /></ErrorBoundary>
          <div id="active">{active}</div>
          <Home employee={{ name: 'Nikhil Bisht' }} leads={LEADS} followups={[{ id: 'f1' }]} leadsReady canAccessLeads canAccessAds onOpenTab={(t) => setActive(t)} />
        </main>
      </div>
    </div>
  );
}
window.__t = { supabase, timedFetch, LIMITS, handleApiRequest, net, renewSession, _resetRenew, homeNumbers, LEADS };
createRoot(document.getElementById('root')).render(<Shell />);
