import { useState, useEffect, useCallback, Fragment } from 'react';
import { API_URL } from '../api';
import AppleSelect from './ui/AppleSelect';

const todayStr = () => new Date().toISOString().slice(0, 10);
const thisMonthStr = () => new Date().toISOString().slice(0, 7);

// Canonical roles are student | employee | visitor. Legacy rows may say 'staff';
// biometric rows that haven't been mapped to a CRM person are 'unmapped'.
const normRole = (r) => (r === 'staff' ? 'employee' : r || 'student');

const ROLE_BADGE = {
  student: 'bg-indigo-100 text-indigo-700',
  employee: 'bg-amber-100 text-amber-800',
  visitor: 'bg-purple-100 text-purple-700',
  unmapped: 'bg-rose-100 text-rose-700',
};

const ROLE_FILTERS = [
  { key: 'all', label: 'All' },
  { key: 'student', label: 'Students' },
  { key: 'employee', label: 'Employees' },
  { key: 'visitor', label: 'Visitors' },
];

const authHeaders = () => ({ Authorization: `Bearer ${localStorage.getItem('token')}` });

// Only the Admin department may edit/override a day. Same idiom as the rest of the app.
const isAdmin = () => {
  try { return JSON.parse(localStorage.getItem('employee') || '{}').department === 'Admin'; }
  catch { return false; }
};

const roleBadge = (role) => (
  <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-medium capitalize ${
    ROLE_BADGE[role] || ROLE_BADGE.student
  }`}>{role}</span>
);

// Day-status classification. short_day / missing_exit are REVIEW states — shown
// in distinct warning colours, never hidden or treated as a plain full day.
const DAY_STATUS_META = {
  full_day:     { label: 'Full Day',     cls: 'bg-green-100 text-green-800' },
  half_day:     { label: 'Half Day',     cls: 'bg-yellow-100 text-yellow-800' },
  short_day:    { label: 'Short Day',    cls: 'bg-orange-100 text-orange-800' },
  missing_exit: { label: 'Missing Exit', cls: 'bg-red-100 text-red-700' },
  absent:       { label: 'Absent',       cls: 'bg-rose-100 text-rose-700' },
  leave:        { label: 'Leave',        cls: 'bg-blue-100 text-blue-800' },
};

const dayStatusBadge = (status, overridden) => {
  const meta = DAY_STATUS_META[status];
  if (!meta) return <span className="text-slate-400">—</span>;
  return (
    <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-medium ${meta.cls}`}
      title={overridden ? 'Manually overridden by Admin' : undefined}>
      {meta.label}{overridden ? ' •' : ''}
    </span>
  );
};

// Values Admin can force via the override dropdown ('' = clear / use computed).
const OVERRIDE_OPTIONS = [
  { value: '', label: '(auto — from times)' },
  { value: 'full_day', label: 'Full Day' },
  { value: 'half_day', label: 'Half Day' },
  { value: 'absent', label: 'Absent' },
  { value: 'leave', label: 'Leave' },
];

export default function Attendance() {
  const [view, setView] = useState('day'); // 'day' | 'month' | 'devices'

  return (
    <div className="space-y-4 animate-glass-in">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-glass-primary">Attendance</h2>
          <p className="text-sm text-glass-muted">
            Captured by the biometric fingerprint terminal at the institute.
          </p>
        </div>
        <div className="flex items-center gap-1 glass-tabs rounded-lg p-1">
          {[
            { key: 'day', label: 'Day' },
            { key: 'month', label: 'Month' },
            { key: 'devices', label: 'Device People' },
          ].map((v) => (
            <button
              key={v.key}
              onClick={() => setView(v.key)}
              className={`px-3 py-1.5 text-sm font-medium rounded-md ${
                view === v.key ? 'bg-white text-glass-primary shadow-sm' : 'text-glass-muted hover:text-slate-700'
              }`}
            >
              {v.label}
            </button>
          ))}
        </div>
      </div>

      {view === 'day' && <DayView />}
      {view === 'month' && <MonthView />}
      {view === 'devices' && <DevicePeople />}
    </div>
  );
}

// ---------------------------------------------------------------------------
// DAY VIEW (the original single-day table)
// ---------------------------------------------------------------------------
function DayView() {
  const [date, setDate] = useState(todayStr());
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [roleFilter, setRoleFilter] = useState('all');

  const load = useCallback(async (d) => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${API_URL}/api/attendance?date=${d}`, { headers: authHeaders() });
      if (res.status === 403) {
        setError('Only the Admin department can view CCTV attendance.');
        setData(null);
        return;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError('Could not load attendance. Is the CRM server reachable?');
      setData(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(date); }, [date, load]);

  const rows = data?.rows || [];
  const visitorCount = rows.filter((r) => normRole(r.role) === 'visitor').length;
  const filteredRows =
    roleFilter === 'all' ? rows : rows.filter((r) => normRole(r.role) === roleFilter);
  const isSunday = new Date(date + 'T12:00:00').getDay() === 0;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-end gap-2">
        <input
          type="date"
          value={date}
          max={todayStr()}
          onChange={(e) => setDate(e.target.value)}
          className="glass-input px-3 py-2 text-sm"
        />
        <button
          onClick={() => load(date)}
          className="px-4 py-2 text-sm font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50"
        >
          ↻ Refresh
        </button>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-6 gap-3">
        {[
          { label: 'Marked present', value: data ? data.present : '—' },
          { label: 'Currently inside', value: data ? data.inside : '—', accent: 'text-emerald-600' },
          { label: 'Left for the day', value: data ? data.present - data.inside : '—', accent: 'text-glass-muted' },
          { label: 'Needs review', value: data ? (data.needs_review ?? 0) : '—', accent: 'text-orange-600' },
          { label: 'Visitors today', value: data ? visitorCount : '—', accent: 'text-purple-600' },
          { label: 'Date', value: date, small: true },
        ].map((c) => (
          <div key={c.label} className="glass-card p-4">
            <div className={`${c.small ? 'text-base' : 'text-2xl'} font-bold ${c.accent || 'text-glass-primary'}`}>
              {c.value}
            </div>
            <div className="text-xs text-glass-muted mt-1">{c.label}</div>
          </div>
        ))}
      </div>

      {error && (
        <div className="glass-subtle rounded-xl p-4 text-sm text-red-700" style={{ backgroundColor: 'rgba(255,59,48,0.08)' }}>{error}</div>
      )}

      <div className="flex flex-wrap items-center gap-2">
        {ROLE_FILTERS.map((f) => (
          <button
            key={f.key}
            onClick={() => setRoleFilter(f.key)}
            className={`px-3 py-1.5 text-sm font-medium rounded-lg border ${
              roleFilter === f.key
                ? 'bg-indigo-600 text-white border-indigo-600'
                : 'bg-white text-glass-secondary border-slate-300 hover:bg-slate-50'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      <div className="glass-table overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="glass-subtle text-left text-xs uppercase tracking-wide text-glass-muted">
                <th className="px-4 py-3">Name</th>
                <th className="px-4 py-3">Role</th>
                <th className="px-4 py-3">Entry</th>
                <th className="px-4 py-3">Exit</th>
                <th className="px-4 py-3">Presence</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filteredRows.map((r) => (
                <DayRow key={r.record_id ?? r.person_id} row={r} onChanged={() => load(date)} />
              ))}
              {!loading && filteredRows.length === 0 && !error && (
                <tr>
                  <td colSpan="5" className="px-4 py-10 text-center text-slate-400">
                    {rows.length > 0
                      ? 'No people match this role filter.'
                      : isSunday
                        ? 'Sunday — attendance is not taken.'
                        : 'No attendance synced for this date yet.'}
                  </td>
                </tr>
              )}
              {loading && (
                <tr><td colSpan="5" className="px-4 py-10 text-center text-slate-400">Loading…</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// One attendance row. The table shows only Name/Role/Entry/Exit/Presence; clicking
// an Admin's row opens the inline editor to fix times / override the day status
// (hours + day status live in the Month view and employee profile). Non-Admins get
// a plain, non-clickable row. The PATCH endpoint also enforces Admin server-side.
function DayRow({ row, onChanged }) {
  const [editing, setEditing] = useState(false);
  const [entry, setEntry] = useState(row.entry_time || '');
  const [exit, setExit] = useState(row.exit_time || '');
  const [override, setOverride] = useState(row.status_override || '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const open = () => {
    setEntry(row.entry_time || '');
    setExit(row.exit_time || '');
    setOverride(row.status_override || '');
    setErr('');
    setEditing(true);
  };

  const save = async () => {
    setBusy(true); setErr('');
    try {
      const res = await fetch(`${API_URL}/api/attendance/${row.record_id}`, {
        method: 'PATCH',
        headers: { ...authHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify({
          entry_time: entry.trim() || null,
          exit_time: exit.trim() || null,
          status_override: override || null,
        }),
      });
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).detail || `HTTP ${res.status}`);
      setEditing(false);
      onChanged();
    } catch (e) {
      setErr(typeof e.message === 'string' ? e.message : 'Save failed.');
    } finally {
      setBusy(false);
    }
  };

  const clickable = isAdmin() && row.record_id != null;

  return (
    <Fragment>
      <tr
        onClick={clickable ? (editing ? () => setEditing(false) : open) : undefined}
        className={clickable ? 'cursor-pointer hover:bg-slate-50' : ''}
      >
        <td className="px-4 py-3 font-medium text-glass-primary">{row.name}</td>
        <td className="px-4 py-3">{roleBadge(normRole(row.role))}</td>
        <td className="px-4 py-3 tabular-nums">{row.entry_time || '—'}</td>
        <td className="px-4 py-3 tabular-nums">{row.exit_time || '—'}</td>
        <td className="px-4 py-3">
          {row.exit_time ? (
            <span className="inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-slate-100 text-slate-600">Left</span>
          ) : (
            <span className="inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-emerald-100 text-emerald-700">Inside</span>
          )}
        </td>
      </tr>
      {editing && (
        <tr className="bg-slate-50/60">
          <td colSpan="5" className="px-4 py-3">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 items-end">
              <div>
                <label className="block text-xs font-medium text-glass-muted mb-1">Entry (HH:MM:SS)</label>
                <input value={entry} onChange={(e) => setEntry(e.target.value)} placeholder="09:00:00"
                  className="w-full glass-input px-3 py-2 text-sm tabular-nums" />
              </div>
              <div>
                <label className="block text-xs font-medium text-glass-muted mb-1">Exit (HH:MM:SS)</label>
                <input value={exit} onChange={(e) => setExit(e.target.value)} placeholder="17:00:00"
                  className="w-full glass-input px-3 py-2 text-sm tabular-nums" />
              </div>
              <div>
                <label className="block text-xs font-medium text-glass-muted mb-1">Override status</label>
                <AppleSelect value={override} onChange={(e) => setOverride(e.target.value)}
                  className="w-full glass-input px-3 py-2 text-sm">
                  {OVERRIDE_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>{o.label}</option>
                  ))}
                </AppleSelect>
              </div>
              <div className="flex gap-2">
                <button onClick={save} disabled={busy}
                  className="glass-btn px-4 py-2 text-sm font-medium disabled:opacity-40">
                  {busy ? 'Saving…' : 'Save'}
                </button>
                <button onClick={() => setEditing(false)}
                  className="px-3 py-2 text-sm font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50">Cancel</button>
              </div>
              {err && <div className="sm:col-span-2 lg:col-span-4 text-xs text-rose-600">{err}</div>}
              <p className="sm:col-span-2 lg:col-span-4 text-xs text-glass-muted">
                Editing times recomputes the day status. An override forces the status regardless of times.
                Clearing both times leaves the day as “missing exit”.
              </p>
            </div>
          </td>
        </tr>
      )}
    </Fragment>
  );
}

// ---------------------------------------------------------------------------
// MONTH VIEW (people x days-present, expandable per-day breakdown, CSV export)
// ---------------------------------------------------------------------------
function MonthView() {
  const [month, setMonth] = useState(thisMonthStr());
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState({});

  const load = useCallback(async (m) => {
    setLoading(true);
    setError('');
    setExpanded({});
    try {
      const res = await fetch(`${API_URL}/api/attendance/monthly?month=${m}`, { headers: authHeaders() });
      if (res.status === 403) { setError('Only the Admin department can view CCTV attendance.'); setData(null); return; }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError('Could not load monthly attendance. Is the CRM server reachable?');
      setData(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(month); }, [month, load]);

  const people = data?.people || [];

  const exportCsv = () => {
    const header = ['Name', 'Role', 'Days Present', 'Full Days', 'Half Days', 'Needs Review',
      'First Seen', 'Last Seen', 'Date', 'Entry', 'Exit', 'Hours', 'Status'];
    const lines = [header.join(',')];
    const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const statusLabel = (s) => DAY_STATUS_META[s]?.label || '';
    people.forEach((p) => {
      const summary = [p.name, p.role, p.days_present, p.full_days ?? '', p.half_days ?? '',
        p.days_needing_review ?? '', p.first_seen, p.last_seen];
      if (!p.days.length) {
        lines.push([...summary, '', '', '', '', ''].map(esc).join(','));
      }
      p.days.forEach((d) => {
        lines.push([...summary, d.date, d.entry_time || '', d.exit_time || '',
          d.hours_worked ?? '', statusLabel(d.status)].map(esc).join(','));
      });
    });
    const blob = new Blob([lines.join('\n')], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `attendance-${month}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-end gap-2">
        <input
          type="month"
          value={month}
          max={thisMonthStr()}
          onChange={(e) => setMonth(e.target.value)}
          className="glass-input px-3 py-2 text-sm"
        />
        <button onClick={() => load(month)}
          className="px-4 py-2 text-sm font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50">
          ↻ Refresh
        </button>
        <button onClick={exportCsv} disabled={!people.length}
          className="glass-btn px-4 py-2 text-sm font-medium disabled:opacity-40">
          ⬇ Export CSV
        </button>
      </div>

      {error && (
        <div className="glass-subtle rounded-xl p-4 text-sm text-red-700" style={{ backgroundColor: 'rgba(255,59,48,0.08)' }}>{error}</div>
      )}

      <div className="glass-table overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="glass-subtle text-left text-xs uppercase tracking-wide text-glass-muted">
                <th className="px-4 py-3 w-8"></th>
                <th className="px-4 py-3">Name</th>
                <th className="px-4 py-3">Role</th>
                <th className="px-4 py-3">Days Present</th>
                <th className="px-4 py-3">First Seen</th>
                <th className="px-4 py-3">Last Seen</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {people.map((p) => (
                <Fragment key={p.source_person_id}>
                  <tr className="hover:bg-slate-50 cursor-pointer"
                    onClick={() => setExpanded((e) => ({ ...e, [p.source_person_id]: !e[p.source_person_id] }))}>
                    <td className="px-4 py-3 text-slate-400">{expanded[p.source_person_id] ? '▾' : '▸'}</td>
                    <td className="px-4 py-3 font-medium text-glass-primary">{p.name}</td>
                    <td className="px-4 py-3">{roleBadge(normRole(p.role))}</td>
                    <td className="px-4 py-3 tabular-nums font-semibold">{p.days_present}</td>
                    <td className="px-4 py-3 tabular-nums">{p.first_seen}</td>
                    <td className="px-4 py-3 tabular-nums">{p.last_seen}</td>
                  </tr>
                  {expanded[p.source_person_id] && (
                    <tr className="bg-slate-50/60">
                      <td></td>
                      <td colSpan="5" className="px-4 py-3">
                        <div className="mb-2 flex flex-wrap gap-3 text-xs text-glass-muted">
                          <span>Full days: <span className="font-semibold text-green-700">{p.full_days ?? 0}</span></span>
                          <span>Half days: <span className="font-semibold text-yellow-700">{p.half_days ?? 0}</span></span>
                          <span>Needs review: <span className="font-semibold text-orange-700">{p.days_needing_review ?? 0}</span></span>
                        </div>
                        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-2">
                          {p.days.map((d) => (
                            <div key={d.date} className="text-xs glass-subtle rounded-lg px-3 py-2">
                              <div className="flex items-center justify-between gap-2">
                                <span className="font-medium text-slate-700">{d.date}</span>
                                {dayStatusBadge(d.status, false)}
                              </div>
                              <div className="tabular-nums text-glass-muted">
                                {(d.entry_time || '—')} → {(d.exit_time || '—')}
                                {d.hours_worked != null ? ` · ${d.hours_worked}h` : ''}
                              </div>
                            </div>
                          ))}
                        </div>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
              {!loading && people.length === 0 && !error && (
                <tr><td colSpan="6" className="px-4 py-10 text-center text-slate-400">No attendance recorded for this month.</td></tr>
              )}
              {loading && (
                <tr><td colSpan="6" className="px-4 py-10 text-center text-slate-400">Loading…</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// DEVICE PEOPLE (map raw biometric ids to CRM employees/students)
// ---------------------------------------------------------------------------
function DevicePeople() {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  // The employee list is the same for every row's picker, so fetch it ONCE here
  // and pass it down. Previously each DevicePersonRow fetched /api/employees on
  // mount (and again on every keystroke), producing a burst of ~20 identical
  // GET /api/employees (and their CORS OPTIONS preflights) per page load.
  const [employees, setEmployees] = useState([]);

  useEffect(() => {
    let alive = true;
    fetch(`${API_URL}/api/employees`, { headers: authHeaders() })
      .then((r) => (r.ok ? r.json() : []))
      .then((list) => { if (alive) setEmployees(Array.isArray(list) ? list : []); })
      .catch(() => { if (alive) setEmployees([]); });
    return () => { alive = false; };
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${API_URL}/api/attendance/device-people`, { headers: authHeaders() });
      if (res.status === 403) { setError('Only the Admin department can manage attendance.'); setData(null); return; }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError('Could not load device people. Is the CRM server reachable?');
      setData(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const people = data?.people || [];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-glass-muted">
          Bind each biometric device id to a CRM person. Unmapped ids are shown first.
          {data ? ` ${data.unmapped} unmapped.` : ''}
        </p>
        <button onClick={load}
          className="px-4 py-2 text-sm font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50">
          ↻ Refresh
        </button>
      </div>

      {error && (
        <div className="glass-subtle rounded-xl p-4 text-sm text-red-700" style={{ backgroundColor: 'rgba(255,59,48,0.08)' }}>{error}</div>
      )}

      <div className="space-y-3">
        {people.map((p) => (
          <DevicePersonRow key={p.source_person_id} person={p} employees={employees} onChanged={load} />
        ))}
        {!loading && people.length === 0 && !error && (
          <div className="glass-card p-10 text-center text-slate-400 text-sm">
            No device people have punched in yet.
          </div>
        )}
        {loading && (
          <div className="glass-card p-10 text-center text-slate-400 text-sm">Loading…</div>
        )}
      </div>
    </div>
  );
}

function DevicePersonRow({ person, employees = [], onChanged }) {
  const [personType, setPersonType] = useState(person.mapping?.person_type || 'employee');
  const [query, setQuery] = useState('');
  const [candidates, setCandidates] = useState([]);
  const [selected, setSelected] = useState(null); // { id, name }
  const [displayName, setDisplayName] = useState(person.mapping?.display_name || person.device_name || '');
  const [busy, setBusy] = useState(false);
  const [rowError, setRowError] = useState('');
  const [editing, setEditing] = useState(!person.is_mapped);

  // Employees come from the parent (fetched once for the whole list) and are
  // filtered client-side, so only STUDENTS need a per-row, server-side search
  // fetch when the picker is open.
  useEffect(() => {
    if (!editing || personType !== 'student') return;
    let alive = true;
    fetch(`${API_URL}/api/students?search=${encodeURIComponent(query)}`, { headers: authHeaders() })
      .then((r) => (r.ok ? r.json() : []))
      .then((list) => { if (alive) setCandidates(Array.isArray(list) ? list : []); })
      .catch(() => { if (alive) setCandidates([]); });
    return () => { alive = false; };
  }, [personType, query, editing]);

  const filtered = personType === 'employee'
    ? employees.filter((c) => (c.name || '').toLowerCase().includes(query.toLowerCase()))
    : candidates; // students already filtered server-side

  const pick = (c) => {
    setSelected({ id: c.id, name: c.name });
    setDisplayName(c.name);
  };

  const save = async () => {
    if (!selected) { setRowError('Pick a CRM person first.'); return; }
    setBusy(true); setRowError('');
    try {
      const res = await fetch(
        `${API_URL}/api/attendance/device-people/${encodeURIComponent(person.device_person_id)}/map`,
        {
          method: 'POST',
          headers: { ...authHeaders(), 'Content-Type': 'application/json' },
          body: JSON.stringify({
            person_type: personType,
            crm_person_id: selected.id,
            display_name: displayName.trim() || selected.name,
            role: personType,
          }),
        });
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).detail || `HTTP ${res.status}`);
      onChanged();
    } catch (e) {
      setRowError(typeof e.message === 'string' ? e.message : 'Save failed.');
    } finally {
      setBusy(false);
    }
  };

  const unlink = async () => {
    setBusy(true); setRowError('');
    try {
      const res = await fetch(
        `${API_URL}/api/attendance/device-people/${encodeURIComponent(person.device_person_id)}/map`,
        { method: 'DELETE', headers: authHeaders() });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      onChanged();
    } catch (e) {
      setRowError('Unlink failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={`glass-card p-4 ${person.is_mapped ? 'border-slate-200' : 'border-rose-200'}`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="font-mono text-sm glass-subtle rounded px-2 py-1 text-slate-700">
            #{person.device_person_id}
          </span>
          <div>
            <div className="font-medium text-glass-primary">
              {person.is_mapped ? person.mapping.display_name : person.device_name || '(no name from device)'}
            </div>
            <div className="text-xs text-slate-400">
              device name: {person.device_name || '—'} · last seen {person.last_seen || '—'}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {person.is_mapped
            ? roleBadge(normRole(person.mapping.role))
            : <span className="inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-rose-100 text-rose-700">Unmapped</span>}
          {person.is_mapped && !editing && (
            <>
              <button onClick={() => setEditing(true)}
                className="px-3 py-1.5 text-xs font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50">Remap</button>
              <button onClick={unlink} disabled={busy}
                className="px-3 py-1.5 text-xs font-medium bg-white border border-rose-300 text-rose-600 rounded-lg hover:bg-rose-50 disabled:opacity-40">Unlink</button>
            </>
          )}
        </div>
      </div>

      {editing && (
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4 items-end border-t border-slate-100 pt-4">
          <div>
            <label className="block text-xs font-medium text-glass-muted mb-1">Type</label>
            <AppleSelect value={personType}
              onChange={(e) => { setPersonType(e.target.value); setSelected(null); setQuery(''); }}
              className="w-full glass-input px-3 py-2 text-sm">
              <option value="employee">Employee</option>
              <option value="student">Student</option>
            </AppleSelect>
          </div>
          <div>
            <label className="block text-xs font-medium text-glass-muted mb-1">Search CRM person</label>
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Type a name…"
              className="w-full glass-input px-3 py-2 text-sm" />
            {query && filtered.length > 0 && !selected && (
              <div className="mt-1 max-h-40 overflow-y-auto border border-slate-200 rounded-lg bg-white shadow-sm">
                {filtered.slice(0, 25).map((c) => (
                  <button key={c.id} onClick={() => pick(c)}
                    className="block w-full text-left px-3 py-2 text-sm hover:bg-indigo-50">
                    {c.name}{c.employee_id ? ` · ${c.employee_id}` : ''}{c.course ? ` · ${c.course}` : ''}
                  </button>
                ))}
              </div>
            )}
            {selected && <div className="mt-1 text-xs text-emerald-600">Selected: {selected.name}</div>}
          </div>
          <div>
            <label className="block text-xs font-medium text-glass-muted mb-1">Display name</label>
            <input value={displayName} onChange={(e) => setDisplayName(e.target.value)}
              className="w-full glass-input px-3 py-2 text-sm" />
          </div>
          <div className="flex gap-2">
            <button onClick={save} disabled={busy || !selected}
              className="glass-btn px-4 py-2 text-sm font-medium disabled:opacity-40">
              {busy ? 'Saving…' : 'Save'}
            </button>
            {person.is_mapped && (
              <button onClick={() => setEditing(false)}
                className="px-3 py-2 text-sm font-medium bg-white border border-slate-300 rounded-lg hover:bg-slate-50">Cancel</button>
            )}
          </div>
          {rowError && <div className="sm:col-span-2 lg:col-span-4 text-xs text-rose-600">{rowError}</div>}
        </div>
      )}
    </div>
  );
}
