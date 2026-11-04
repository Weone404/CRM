import { useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { API_URL } from '../api';
import { formatDate, displayPhone } from '../utils/formatters';
import { showToast } from '../utils/toast';
import { COURSES } from '../constants/courses';
import { USE_SUPABASE } from '../backend/mode';

// FastAPI sends `detail` as a string for HTTPException but as a list of
// {loc, msg} objects for 422s — flatten both so the toast never shows [object Object].
function errorDetail(data) {
  const d = data?.detail;
  if (typeof d === 'string') return d;
  if (Array.isArray(d)) {
    return d.map((e) => (typeof e === 'string' ? e : [e?.loc?.slice(-1)[0], e?.msg].filter(Boolean).join(': ')))
      .filter(Boolean).join('; ');
  }
  return d ? JSON.stringify(d) : '';
}

const DOC_LABELS = {
  photo_id_proof: 'Photo ID Proof',
  passport_photo: 'Passport Photo',
  signature: 'Signature',
  marksheet_10: '10th Marksheet',
  certificate_10: '10th Certificate',
  marksheet_12: '12th Marksheet',
  certificate_12: '12th Certificate',
  board_verification_10: '10th Board Verification',
  board_verification_12: '12th Board Verification',
  passport: 'Passport',
  i20_admission_letter: 'I-20 Admission Letter',
  medical: 'Medical',
};
const ACCEPT = 'image/jpeg,image/jpg,image/png,image/heic,image/heif,.jpg,.jpeg,.png,.heic,.heif';

const authHeaders = () => ({ Authorization: `Bearer ${localStorage.getItem('token')}` });

export default function StudentDirectory() {
  const [students, setStudents] = useState([]);
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(null);
  const [showAdd, setShowAdd] = useState(false);

  const loadStudents = async (q = '') => {
    setLoading(true);
    try {
      const res = await fetch(`${API_URL}/api/students?search=${encodeURIComponent(q)}`, { headers: authHeaders() });
      if (res.ok) setStudents(await res.json());
      else showToast('Failed to load students', 'error');
    } catch { showToast('Failed to load students', 'error'); }
    setLoading(false);
  };

  useEffect(() => { loadStudents(); }, []);
  useEffect(() => {
    const t = setTimeout(() => loadStudents(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  if (selectedId) {
    return <StudentDetail studentId={selectedId} onBack={() => { setSelectedId(null); loadStudents(search); }} />;
  }

  return (
    <div className="glass-card p-4 animate-glass-in">
      <div className="flex flex-col sm:flex-row justify-between items-stretch sm:items-center gap-3 mb-4">
        <h2 className="text-lg font-semibold">Students</h2>
        <div className="flex flex-wrap gap-2">
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search name, mobile, computer no., course"
            aria-label="Search students"
            className="flex-1 min-w-[200px] sm:w-72 glass-input px-3 py-2"
          />
          <button onClick={() => setShowAdd(true)} className="px-4 py-2 min-h-[40px] bg-green-600 text-white rounded-lg font-semibold hover:bg-green-700 whitespace-nowrap">
            + Add Student
          </button>
        </div>
      </div>

      {loading ? (
        <div className="text-center text-glass-muted py-8">Loading…</div>
      ) : students.length === 0 ? (
        <div className="text-center text-glass-muted py-8">No students found.</div>
      ) : (
        <div className="glass-table overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left border-b text-glass-muted">
                <th className="px-3 py-2">Name</th>
                <th className="px-3 py-2">Mobile</th>
                <th className="px-3 py-2">Course</th>
                <th className="px-3 py-2">Admission</th>
                <th className="px-3 py-2">Documents</th>
              </tr>
            </thead>
            <tbody>
              {students.map((s) => {
                const complete = s.documents_complete === s.documents_total;
                return (
                  <tr key={s.id} onClick={() => setSelectedId(s.id)}
                    className="border-b hover:bg-blue-50 cursor-pointer">
                    <td className="px-3 py-2 font-medium text-glass-primary">{s.name}</td>
                    <td className="px-3 py-2">{displayPhone(s.mobile)}</td>
                    <td className="px-3 py-2">{s.course || '-'}</td>
                    <td className="px-3 py-2">{s.admission_date || '-'}</td>
                    <td className="px-3 py-2">
                      <span className={`px-2 py-1 rounded-full text-xs font-semibold ${complete ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}`}>
                        {s.documents_complete}/{s.documents_total}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {showAdd && (
        <AddStudent
          onClose={() => setShowAdd(false)}
          onCreated={() => { setShowAdd(false); loadStudents(search); }}
          onOpenExisting={(id) => { setShowAdd(false); setSelectedId(id); }}
        />
      )}
    </div>
  );
}

function AddStudent({ onClose, onCreated, onOpenExisting }) {
  const [form, setForm] = useState({
    first_name: '', middle_name: '', last_name: '', guardian_name: '', mobile: '',
    emergency_contact: '', address: '', course: '', computer_number: '', admission_date: '',
    date_of_birth: '', lead_id: '',
  });
  const [leads, setLeads] = useState([]);
  const [saving, setSaving] = useState(false);
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  useEffect(() => {
    fetch(`${API_URL}/api/students/prefill-leads`, { headers: authHeaders() })
      .then((r) => (r.ok ? r.json() : [])).then(setLeads).catch(() => {});
  }, []);

  const prefill = (leadId) => {
    const l = leads.find((x) => x.id === leadId);
    if (!l) { set('lead_id', ''); return; }
    const parts = (l.name || '').trim().split(/\s+/);
    setForm((f) => ({
      ...f,
      lead_id: l.id,
      first_name: parts[0] || '',
      last_name: parts.length > 1 ? parts.slice(1).join(' ') : '',
      guardian_name: l.guardian_name || '',
      mobile: displayPhone(l.phone) || '',
      address: l.address || '',
      course: l.course_interest || '',
    }));
  };

  const submit = async (e) => {
    e.preventDefault();
    if (!form.first_name || !form.mobile) {
      showToast('First name and mobile are required', 'error');
      return;
    }
    setSaving(true);
    try {
      // Optional fields go as null, never "" — Postgres rejects "" for date/numeric columns.
      const payload = Object.fromEntries(
        Object.entries(form).map(([k, v]) => [k, typeof v === 'string' && !v.trim() ? null : v])
      );
      const res = await fetch(`${API_URL}/api/students`, {
        method: 'POST',
        headers: { ...authHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      setSaving(false);
      if (!res.ok) { showToast(errorDetail(data) || `Failed to add student (${res.status})`, 'error'); return; }
      if (data.status === 'duplicate') {
        if (window.confirm(`A student with this mobile already exists${data.name ? ` (${data.name})` : ''}. Open the existing record?`)) {
          onOpenExisting(data.student_id);
        }
        return;
      }
      showToast('Student added', 'success');
      onCreated();
    } catch (err) { setSaving(false); showToast(`Failed to add student: ${err?.message || 'network error'}`, 'error'); }
  };

  const input = 'w-full glass-input';

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
      <div className="glass-strong max-w-lg w-full p-6 my-8 max-h-[90vh] overflow-y-auto">
        <div className="flex justify-between items-start mb-4">
          <h2 className="text-xl font-bold">Add Student</h2>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 text-2xl">×</button>
        </div>

        {leads.length > 0 && (
          <div className="mb-4">
            <label className="block text-sm font-semibold mb-1">Prefill from completed admission</label>
            <select value={form.lead_id} onChange={(e) => prefill(e.target.value)} className={input}>
              <option value="">-- None (enter manually) --</option>
              {leads.map((l) => <option key={l.id} value={l.id}>{l.name} — {displayPhone(l.phone)}</option>)}
            </select>
          </div>
        )}

        <form onSubmit={submit} className="space-y-3">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <input className={input} placeholder="First Name *" value={form.first_name} onChange={(e) => set('first_name', e.target.value)} required />
            <input className={input} placeholder="Middle Name" value={form.middle_name} onChange={(e) => set('middle_name', e.target.value)} />
            <input className={input} placeholder="Last Name" value={form.last_name} onChange={(e) => set('last_name', e.target.value)} />
          </div>
          <input className={input} placeholder="Guardian's Name" value={form.guardian_name} onChange={(e) => set('guardian_name', e.target.value)} />
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <input className={input} type="tel" placeholder="Mobile *" value={form.mobile} onChange={(e) => set('mobile', e.target.value)} required />
            <input className={input} type="tel" placeholder="Emergency Contact" value={form.emergency_contact} onChange={(e) => set('emergency_contact', e.target.value)} />
          </div>
          <input className={input} placeholder="Address" value={form.address} onChange={(e) => set('address', e.target.value)} />
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <select className={input} value={form.course} onChange={(e) => set('course', e.target.value)} required>
              <option value="">Select Course *</option>
              {COURSES.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
            <input className={input} placeholder="Computer Number (DGCA)" value={form.computer_number} onChange={(e) => set('computer_number', e.target.value)} />
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-glass-muted mb-1">Admission Date</label>
              <input className={input} type="date" value={form.admission_date} onChange={(e) => set('admission_date', e.target.value)} />
            </div>
            <div>
              {/* Optional — blank is mapped to null with the other fields in submit(). */}
              <label className="block text-xs text-glass-muted mb-1">Date of Birth</label>
              <input className={input} type="date" value={form.date_of_birth} onChange={(e) => set('date_of_birth', e.target.value)} />
            </div>
          </div>
          <button type="submit" disabled={saving} className="w-full bg-green-600 text-white py-3 rounded-lg font-semibold hover:bg-green-700 disabled:bg-gray-400">
            {saving ? 'Saving…' : 'Save Student'}
          </button>
        </form>
      </div>
    </div>,
    document.body
  );
}

function StudentDetail({ studentId, onBack }) {
  const [student, setStudent] = useState(null);
  const [busy, setBusy] = useState('');
  const [showDelete, setShowDelete] = useState(false);
  const [confirmText, setConfirmText] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [showPin, setShowPin] = useState(false);
  const [showEdit, setShowEdit] = useState(false);
  const department = (() => {
    try { return JSON.parse(localStorage.getItem('employee') || '{}').department; }
    catch { return ''; }
  })();
  // Setting a student PIN is Admin-only (enforced server-side); hide the button for others.
  const isAdmin = department === 'Admin';
  // Editing is Admin + Sales, mirroring _require_students_access on the server.
  const canEdit = department === 'Admin' || department === 'Sales';

  const deleteStudent = async () => {
    setDeleting(true);
    try {
      const res = await fetch(`${API_URL}/api/students/${studentId}`, {
        method: 'DELETE', headers: authHeaders(),
      });
      const data = await res.json().catch(() => ({}));
      setDeleting(false);
      if (!res.ok) { showToast(data.detail || 'Delete failed', 'error'); return; }
      showToast('Student deleted', 'success');
      onBack();
    } catch { setDeleting(false); showToast('Delete failed', 'error'); }
  };

  const load = async () => {
    const res = await fetch(`${API_URL}/api/students/${studentId}`, { headers: authHeaders() });
    if (res.ok) setStudent(await res.json());
    else showToast('Failed to load student', 'error');
  };
  useEffect(() => { load(); }, [studentId]);

  const upload = async (docType, file) => {
    if (!file) return;
    setBusy(docType);
    try {
      const fd = new FormData();
      fd.append('doc_type', docType);
      fd.append('file', file);
      const res = await fetch(`${API_URL}/api/students/${studentId}/documents`, {
        method: 'POST', headers: authHeaders(), body: fd,
      });
      const data = await res.json();
      if (!res.ok) showToast(data.detail || 'Upload failed', 'error');
      else { showToast('Uploaded', 'success'); await load(); }
    } catch { showToast('Upload failed', 'error'); }
    setBusy('');
  };

  const view = async (docId) => {
    const res = await fetch(`${API_URL}/api/students/${studentId}/documents/${docId}/url`, { headers: authHeaders() });
    if (res.ok) { const { url } = await res.json(); window.open(url, '_blank', 'noopener'); }
    else showToast('Could not open document', 'error');
  };

  const remove = async (docId, label) => {
    if (!window.confirm(`Delete "${label}"? This permanently removes the file.`)) return;
    const res = await fetch(`${API_URL}/api/students/${studentId}/documents/${docId}`, {
      method: 'DELETE', headers: authHeaders(),
    });
    if (res.ok) { showToast('Deleted', 'success'); await load(); }
    else showToast('Delete failed', 'error');
  };

  if (!student) return <div className="glass-card p-6 text-center text-glass-muted animate-glass-in">Loading…</div>;

  const uploadedCount = student.doc_types.filter((t) => student.documents[t]).length;
  const field = (label, val) => (
    <div>
      <label className="text-sm font-medium text-glass-muted">{label}</label>
      <div className="mt-1 text-glass-primary font-medium">{val || '-'}</div>
    </div>
  );

  return (
    <div className="glass-card p-4 sm:p-6 animate-glass-in">
      <div className="flex justify-between items-center mb-4">
        <button onClick={onBack} className="text-blue-600 hover:underline">← Back to Students</button>
        <div className="flex gap-2 flex-wrap justify-end">
          {canEdit && (
            <button onClick={() => setShowEdit(true)}
              className="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
              Edit
            </button>
          )}
          {isAdmin && (
            <button onClick={() => setShowPin(true)}
              className="px-3 py-1 text-sm bg-indigo-600 text-white rounded hover:bg-indigo-700">
              Set PIN
            </button>
          )}
          <button onClick={() => { setShowDelete(true); setConfirmText(''); }}
            className="px-3 py-1 text-sm bg-red-600 text-white rounded hover:bg-red-700">
            Delete Student
          </button>
        </div>
      </div>

      <h2 className="text-2xl font-bold text-glass-primary">
        {[student.first_name, student.middle_name, student.last_name].filter(Boolean).join(' ')}
      </h2>
      <p className="text-glass-secondary mb-4">{student.course || 'Student'}</p>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 mb-6">
        {field('Mobile', student.mobile)}
        {field('Guardian', student.guardian_name)}
        {field('Emergency Contact', student.emergency_contact)}
        {field('Computer Number (DGCA)', student.computer_number)}
        {field('Admission Date', student.admission_date)}
        {field('Date of Birth', student.date_of_birth ? formatDate(student.date_of_birth) : '—')}
        {field('Address', student.address)}
      </div>

      <div className="flex items-center justify-between mb-3">
        <h3 className="text-lg font-semibold">Documents</h3>
        <span className={`px-3 py-1 rounded-full text-sm font-semibold ${uploadedCount === student.doc_types.length ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}`}>
          {uploadedCount}/{student.doc_types.length} uploaded
        </span>
      </div>

      <div className="divide-y border rounded-lg">
        {student.doc_types.map((t) => {
          const doc = student.documents[t];
          return (
            <div key={t} className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 p-3">
              <div className="flex items-center gap-2">
                <span className={doc ? 'text-green-600' : 'text-gray-300'}>{doc ? '✓' : '○'}</span>
                <span className="font-medium text-gray-800">{DOC_LABELS[t]}</span>
                {doc && <span className="text-xs text-gray-400 truncate max-w-[160px]">{doc.original_filename}</span>}
              </div>
              <div className="flex gap-2 flex-wrap">
                {doc && (
                  <>
                    <button onClick={() => view(doc.id)} className="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">View</button>
                    <button onClick={() => remove(doc.id, DOC_LABELS[t])} className="px-3 py-1 text-sm bg-red-100 text-red-700 rounded hover:bg-red-200">Delete</button>
                  </>
                )}
                <label className={`px-3 py-1 text-sm rounded cursor-pointer ${doc ? 'bg-gray-200 text-gray-700 hover:bg-gray-300' : 'bg-green-600 text-white hover:bg-green-700'}`}>
                  {busy === t ? 'Uploading…' : doc ? 'Replace' : 'Upload'}
                  <input type="file" accept={ACCEPT} className="hidden" disabled={busy === t}
                    onChange={(e) => { upload(t, e.target.files[0]); e.target.value = ''; }} />
                </label>
              </div>
            </div>
          );
        })}
      </div>

      {showEdit && (
        <EditStudent
          student={student}
          onClose={() => setShowEdit(false)}
          onSaved={async () => { setShowEdit(false); await load(); }}
        />
      )}

      {showPin && (
        <SetPinModal
          studentId={studentId}
          studentName={[student.first_name, student.middle_name, student.last_name].filter(Boolean).join(' ')}
          onClose={() => setShowPin(false)}
        />
      )}

      {showDelete && createPortal(
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
          <div className="glass-strong max-w-md w-full p-6 my-8 max-h-[90vh] overflow-y-auto">
            <h3 className="text-lg font-bold text-red-700 mb-2">Delete Student</h3>
            <p className="text-sm text-gray-700 mb-4">
              This permanently deletes <span className="font-semibold">{[student.first_name, student.middle_name, student.last_name].filter(Boolean).join(' ')}</span>,
              all {uploadedCount} document(s), and every stored file. This cannot be undone.
            </p>
            <label className="block text-sm font-medium text-gray-700 mb-1">Type <span className="font-mono font-bold">DELETE</span> to confirm</label>
            <input
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
              className="w-full glass-input mb-4"
              autoFocus
            />
            <div className="flex gap-3">
              <button
                onClick={deleteStudent}
                disabled={confirmText !== 'DELETE' || deleting}
                className="flex-1 px-4 py-2 bg-red-600 text-white rounded font-semibold hover:bg-red-700 disabled:bg-gray-300 disabled:cursor-not-allowed"
              >
                {deleting ? 'Deleting…' : 'Delete Permanently'}
              </button>
              <button onClick={() => setShowDelete(false)} className="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300">
                Cancel
              </button>
            </div>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}

// Exactly the server's `allowed` set in update_student. id, lead_id, login_pin_hash,
// login_enabled, created_by and created_at are deliberately absent.
const EDITABLE_FIELDS = [
  'first_name', 'middle_name', 'last_name', 'guardian_name', 'mobile',
  'emergency_contact', 'address', 'course', 'admission_date', 'computer_number',
  'date_of_birth',
];

function EditStudent({ student, onClose, onSaved }) {
  // Inputs need '' rather than null; the original is kept so the PATCH can carry
  // only what actually changed.
  const initial = Object.fromEntries(EDITABLE_FIELDS.map((k) => [k, student[k] ?? '']));
  const [form, setForm] = useState(initial);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  // The guard is a ref, not the `saving` state: two clicks in the same tick both
  // read the pre-render state value and both get through. A ref flips synchronously.
  const inFlight = useRef(false);
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const submit = async (e) => {
    e.preventDefault();
    if (inFlight.current) return;     // a second click can't fire a second PATCH
    if (!form.first_name.trim()) { setError('First name is required'); return; }
    if (!form.mobile.trim()) { setError('Mobile is required'); return; }

    // Changed keys only. A cleared optional field goes as null, never "" —
    // Postgres rejects "" for date columns.
    const payload = {};
    for (const k of EDITABLE_FIELDS) {
      const now = form[k].trim();
      if (now === initial[k].trim()) continue;
      payload[k] = now === '' ? null : now;
    }
    if (Object.keys(payload).length === 0) { onClose(); return; }

    inFlight.current = true;
    setSaving(true);
    setError('');
    try {
      const res = await fetch(`${API_URL}/api/students/${student.id}`, {
        method: 'PATCH',
        headers: { ...authHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      inFlight.current = false;
      setSaving(false);
      // Failure keeps the modal open with the server's own message.
      if (!res.ok) { setError(errorDetail(data) || `Failed to save changes (${res.status})`); return; }
      showToast('Student updated', 'success');
      await onSaved();
    } catch (err) {
      inFlight.current = false;
      setSaving(false);
      setError(`Failed to save changes: ${err?.message || 'network error'}`);
    }
  };

  const input = 'w-full glass-input';
  // Older records can hold a course that is no longer in COURSES; keep it as an
  // option so opening this form can never silently blank it.
  const courseOptions = !form.course || COURSES.includes(form.course)
    ? COURSES
    : [form.course, ...COURSES];

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
      <div className="glass-strong max-w-lg w-full p-6 my-8 max-h-[90vh] overflow-y-auto">
        <div className="flex justify-between items-start mb-4">
          <h2 className="text-xl font-bold">Edit Student</h2>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 text-2xl leading-none">×</button>
        </div>

        {error && (
          <div className="mb-4 p-3 rounded-lg text-sm break-words"
            style={{ background: '#fef2f2', border: '1px solid #fca5a5', color: '#991b1b' }}>
            {error}
          </div>
        )}

        {/* Every field carries a visible label: unlike Add Student, this form opens
            pre-filled, so placeholders would never be shown. */}
        <form onSubmit={submit} className="space-y-3">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label className="block text-xs text-glass-muted mb-1">First Name *</label>
              <input className={input} value={form.first_name} onChange={(e) => set('first_name', e.target.value)} required />
            </div>
            <div>
              <label className="block text-xs text-glass-muted mb-1">Middle Name</label>
              <input className={input} value={form.middle_name} onChange={(e) => set('middle_name', e.target.value)} />
            </div>
            <div>
              <label className="block text-xs text-glass-muted mb-1">Last Name</label>
              <input className={input} value={form.last_name} onChange={(e) => set('last_name', e.target.value)} />
            </div>
          </div>
          <div>
            <label className="block text-xs text-glass-muted mb-1">Guardian's Name</label>
            <input className={input} value={form.guardian_name} onChange={(e) => set('guardian_name', e.target.value)} />
          </div>
          <div>
            <label className="block text-xs text-glass-muted mb-1">Mobile *</label>
            <input className={input} type="tel" value={form.mobile} onChange={(e) => set('mobile', e.target.value)} required />
            <p className="text-xs mt-1" style={{ color: '#b45309' }}>
              ⚠ Changing this changes the student's login number.
            </p>
          </div>
          <div>
            <label className="block text-xs text-glass-muted mb-1">Emergency Contact</label>
            <input className={input} type="tel" value={form.emergency_contact} onChange={(e) => set('emergency_contact', e.target.value)} />
          </div>
          <div>
            <label className="block text-xs text-glass-muted mb-1">Address</label>
            <input className={input} value={form.address} onChange={(e) => set('address', e.target.value)} />
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-glass-muted mb-1">Course</label>
              <select className={input} value={form.course} onChange={(e) => set('course', e.target.value)}>
                <option value="">Select Course</option>
                {courseOptions.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>
            <div>
              <label className="block text-xs text-glass-muted mb-1">Computer Number (DGCA)</label>
              <input className={input} value={form.computer_number} onChange={(e) => set('computer_number', e.target.value)} />
            </div>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-glass-muted mb-1">Admission Date</label>
              <input className={input} type="date" value={form.admission_date} onChange={(e) => set('admission_date', e.target.value)} />
            </div>
            <div>
              <label className="block text-xs text-glass-muted mb-1">Date of Birth</label>
              <input className={input} type="date" value={form.date_of_birth} onChange={(e) => set('date_of_birth', e.target.value)} />
            </div>
          </div>
          <div className="flex gap-3 pt-2">
            <button type="submit" disabled={saving}
              className="flex-1 px-4 py-2 bg-blue-600 text-white rounded font-semibold hover:bg-blue-700 disabled:bg-gray-300">
              {saving ? 'Saving...' : 'Save Changes'}
            </button>
            <button type="button" onClick={onClose} disabled={saving}
              className="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300 disabled:opacity-60">
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}

function SetPinModal({ studentId, studentName, onClose }) {
  const [pin, setPin] = useState('');
  const [resetPassword, setResetPassword] = useState(false);
  const [loginEnabled, setLoginEnabled] = useState(true);
  const [saving, setSaving] = useState(false);

  const save = async (e) => {
    e.preventDefault();
    if (pin && !/^\d{4}$/.test(pin)) {
      showToast('PIN must be exactly 4 digits', 'error');
      return;
    }
    // Send only what was provided: a PIN (if typed) and the login_enabled toggle.
    const body = { login_enabled: loginEnabled };
    if (pin) body.pin = pin;
    if (USE_SUPABASE && resetPassword) body.reset_password = true;
    setSaving(true);
    try {
      const res = await fetch(`${API_URL}/api/students/${studentId}/set-pin`, {
        method: 'POST',
        headers: { ...authHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json().catch(() => ({}));
      setSaving(false);
      if (!res.ok) { showToast(data.detail || 'Failed to update', 'error'); return; }
      showToast('Student login updated', 'success');
      onClose();
    } catch { setSaving(false); showToast('Failed to update', 'error'); }
  };

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
      <div className="glass-strong max-w-md w-full p-6 my-8 max-h-[90vh] overflow-y-auto">
        <h3 className="text-lg font-bold text-glass-primary mb-1">{USE_SUPABASE ? 'Student Login' : 'Set Student Login PIN'}</h3>
        <p className="text-sm text-glass-muted mb-4">{studentName}</p>
        <form onSubmit={save} className="space-y-4">
          {USE_SUPABASE ? (
            <label className="flex items-start gap-2 text-sm text-gray-700">
              <input type="checkbox" className="mt-1" checked={resetPassword} onChange={(e) => setResetPassword(e.target.checked)} />
              <span>Reset password to their mobile number<br />
                <span className="text-xs text-glass-muted">The student signs in with their mobile number and can change the password later.</span></span>
            </label>
          ) : (
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">New 4-digit PIN</label>
            <input
              type="text"
              inputMode="numeric"
              value={pin}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
              placeholder="Leave blank to keep the current PIN"
              maxLength={4}
              className="w-full glass-input tracking-widest"
              autoFocus
            />
            <p className="text-xs text-glass-muted mt-1">The student signs in with their mobile number + this PIN.</p>
          </div>
          )}
          <label className="flex items-center gap-2 text-sm text-gray-700">
            <input type="checkbox" checked={loginEnabled} onChange={(e) => setLoginEnabled(e.target.checked)} />
            Login enabled
          </label>
          <div className="flex gap-3 pt-2">
            <button type="submit" disabled={saving}
              className="flex-1 px-4 py-2 bg-indigo-600 text-white rounded font-semibold hover:bg-indigo-700 disabled:bg-gray-300">
              {saving ? 'Saving…' : 'Save'}
            </button>
            <button type="button" onClick={onClose} className="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300">
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}
