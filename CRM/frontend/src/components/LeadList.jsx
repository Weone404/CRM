import { useEffect, useRef, useState } from 'react';
import { useRoute, setParams } from '../utils/route';
import { FINANCE, STREAMS, TEMP, isPastIso, label, temperature, whenIso } from '../utils/leadPlan';
import { displayPhone } from '../utils/formatters';
import { CLOSURE, charterRef, closureLabel, isPositiveClosure, tripSummary } from '../utils/charter';

function bucketOf(l) {
  if (l.status === 'closed') return 'closed';
  if (!l.first_contacted_at) return 'pending';
  if (l.status === 'Interested') { if (l.interest_track === 'PPL') return 'ppl'; if (l.interest_track === 'Flying') return 'flying'; return 'interested'; }
  if (l.status === 'Not interested') return 'not-interested';
  if (l.status === 'Not reachable') return 'not-reachable';
  if (l.status === 'Callback') return 'callback';
  return 'in-progress';
}

// PPL / Flying are course tracks, so they exist only in the Aviation segment.
const TRACK_TABS = new Set(['ppl', 'flying']);

export default function LeadList({ leads, onSelectLead, segment = 'aviation' }) {
  // The filter lives in the address (#/leads?filter=pending), so the counts above the list can link straight to it.
  const route = useRoute();
  const filter = route.params.filter || 'all';
  const setFilter = (f) => setParams({ filter: f === 'all' ? undefined : f });
  const [closedSub, setClosedSub] = useState('positive');
  const isCharter = segment === 'charter';
  const closure = CLOSURE[segment];

  // Switching segment resets the filter, so a Charter view never opens on a
  // tab (PPL, Flying) that does not exist for it. (Not on first load: a link may have chosen the filter.)
  const lastSegment = useRef(segment);
  useEffect(() => {
    if (lastSegment.current === segment) return;
    lastSegment.current = segment;
    setFilter('all'); setClosedSub('positive');
  }, [segment]); // eslint-disable-line react-hooks/exhaustive-deps

  const buckets = leads.reduce((acc, l) => { const b = bucketOf(l); (acc[b] = acc[b] || []).push(l); return acc; }, {});
  const count = (b) => (buckets[b] || []).length;
  const closedWith = (outcome) => (buckets.closed || []).filter(l => l.closure_outcome === outcome);

  const demoBooked = leads.filter((l) => l.demo?.status === 'scheduled');
  const hot = leads.filter((l) => temperature(l) === 'hot');
  let filteredLeads;
  if (filter === 'all') filteredLeads = leads;
  else if (filter === 'demo') filteredLeads = demoBooked;
  else if (filter === 'hot') filteredLeads = hot;
  else if (filter === 'closed') filteredLeads = closedWith(closure[closedSub].value);
  else filteredLeads = buckets[filter] || [];

  const formatDate = (dateStr) => new Date(dateStr).toLocaleString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });

  const tab = (key, label, activeClass) => (
    (isCharter && TRACK_TABS.has(key)) ? null :
    <button key={key} onClick={() => setFilter(key)} className={`shrink-0 whitespace-nowrap px-3.5 py-1.5 rounded-full text-sm font-medium transition ${filter === key ? activeClass : 'glass-subtle text-glass-secondary hover:text-glass-primary'}`}>{label}</button>
  );

  const badgeClass = (lead) => {
    const base = 'glass-badge ';
    if (lead.status === 'closed') return base + (isPositiveClosure(lead.closure_outcome) ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800');
    if (lead.status === 'Interested') return base + 'bg-green-100 text-green-800';
    if (lead.status === 'Not interested') return base + 'bg-gray-100 text-gray-800';
    if (lead.status === 'Not reachable') return base + 'bg-yellow-100 text-yellow-800';
    if (lead.status === 'Callback') return base + 'bg-purple-100 text-purple-800';
    return base + 'bg-blue-100 text-blue-800';
  };

  return (
    <div>
      <div className="flex gap-2 mb-4 -mx-1 px-1 overflow-x-auto no-scrollbar md:flex-wrap md:overflow-visible" data-testid="lead-filter-chips">
        {tab('all', `All (${leads.length})`, 'bg-indigo-600 text-white')}
        {tab('pending', `Pending (${count('pending')})`, 'bg-orange-600 text-white')}
        {!isCharter && tab('hot', `🔥 Hot (${hot.length})`, 'bg-red-600 text-white')}
        {!isCharter && tab('demo', `Demo booked (${demoBooked.length})`, 'bg-emerald-600 text-white')}
        {tab('in-progress', `In Progress (${count('in-progress')})`, 'bg-sky-600 text-white')}
        {tab('interested', `Interested (${count('interested')})`, 'bg-green-600 text-white')}
        {tab('ppl', `PPL (${count('ppl')})`, 'bg-teal-600 text-white')}
        {tab('flying', `Flying (${count('flying')})`, 'bg-cyan-600 text-white')}
        {tab('callback', `Callback (${count('callback')})`, 'bg-purple-600 text-white')}
        {tab('not-reachable', `Not Reachable (${count('not-reachable')})`, 'bg-yellow-600 text-white')}
        {tab('not-interested', `Not Interested (${count('not-interested')})`, 'bg-gray-600 text-white')}
        {tab('closed', `Closed (${count('closed')})`, 'bg-slate-800 text-white')}
      </div>

      {filter === 'closed' && (
        <div className="flex gap-2 mb-4 flex-wrap">
          <button onClick={() => setClosedSub('positive')} className={`px-3.5 py-1.5 rounded-full text-sm font-medium transition ${closedSub === 'positive' ? 'bg-green-600 text-white' : 'glass-subtle text-green-800'}`}>{closure.positive.plural} ({closedWith(closure.positive.value).length})</button>
          <button onClick={() => setClosedSub('negative')} className={`px-3.5 py-1.5 rounded-full text-sm font-medium transition ${closedSub === 'negative' ? 'bg-red-600 text-white' : 'glass-subtle text-red-800'}`}>{closure.negative.plural} ({closedWith(closure.negative.value).length})</button>
        </div>
      )}

      {filteredLeads.length === 0 && (
        <div className="glass-subtle p-6 text-center text-sm text-glass-secondary">
          {isCharter && leads.length === 0
            ? 'No charter enquiries yet. Requests from bookmycharter.in appear here automatically.'
            : 'No leads in this view.'}
        </div>
      )}

      <div className="space-y-3">
        {filteredLeads.map(lead => (
          <div key={lead.id} onClick={() => onSelectLead(lead, filteredLeads)} className="glass-card p-4 cursor-pointer animate-glass-in tile-link"
            role="button" tabIndex={0} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelectLead(lead, filteredLeads); } }}>
            <div className="flex justify-between items-start mb-2 gap-3">
              <div className="flex-1 min-w-0">
                <div className="font-semibold text-lg text-glass-primary">{lead.name}</div>
                <div className="text-sm text-glass-secondary">{displayPhone(lead.phone)}</div>
                {isCharter ? (
                  <div className="text-sm text-glass-primary font-medium mt-0.5">✈️ {tripSummary(lead.charter_details || {})}</div>
                ) : (
                  <div className="text-sm text-glass-muted">{lead.course_interest}</div>
                )}
              </div>
              <div className="text-right shrink-0">
                <span className={badgeClass(lead)}>{lead.status === 'closed' ? closureLabel(lead.closure_outcome) : lead.status}</span>
                {isCharter && <div className="mt-1 text-xs font-mono text-glass-muted">{charterRef(lead.id)}</div>}
              </div>
            </div>
            <LeadSignals lead={lead} />
            {lead.last_note && <div className="mt-2 p-2 glass-subtle text-sm text-glass-primary text-center">💬 {lead.last_note}</div>}
            <div className="mt-2 text-xs text-glass-muted">📅 Created: {formatDate(lead.created_at)}{isCharter && lead.utm_source ? ` · ${lead.utm_source}` : ''}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

// What the team has recorded, at a glance: Hot/Warm/Cold, demo, next call, Class 12, fees.
function LeadSignals({ lead }) {
  const t = temperature(lead);
  const p = lead.profile || {};
  const chips = [
    t && [TEMP[t].label, TEMP[t].fg, TEMP[t].bg],
    lead.demo?.status === 'scheduled' && [`Demo ${whenIso(lead.demo.at, lead.demo.has_time)}`, '#1E7B34', 'rgba(52,199,89,0.12)'],
    lead.demo?.status === 'attended' && ['Demo attended', '#1E7B34', 'rgba(52,199,89,0.12)'],
    lead.next_followup_at && [`Call ${whenIso(lead.next_followup_at, lead.next_followup_has_time)}`, isPastIso(lead.next_followup_at) ? '#C4261D' : '#A35A00', isPastIso(lead.next_followup_at) ? 'rgba(255,59,48,0.1)' : 'rgba(255,149,0,0.14)'],
    p.class12 && [`12th ${p.class12 === 'not_done' ? 'not done' : p.class12}${p.class12_stream ? ` · ${label(STREAMS, p.class12_stream)}` : ''}`, '#5856D6', 'rgba(88,86,214,0.1)'],
    p.financial_issue && [`Fees${(p.finance_help || []).length ? `: ${p.finance_help.map((k) => label(FINANCE, k)).join(', ')}` : ' concern'}`, '#A35A00', 'rgba(255,149,0,0.12)'],
  ].filter(Boolean);
  if (!chips.length) return null;
  return (
    <div className="flex flex-wrap gap-1.5 mt-1">
      {chips.map(([txt, fg, bg]) => <span key={txt} className="px-2 py-0.5 rounded-full text-[11px] font-semibold" style={{ color: fg, background: bg }}>{txt}</span>)}
    </div>
  );
}
