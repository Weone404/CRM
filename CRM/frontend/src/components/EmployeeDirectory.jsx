import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { formatDate, formatPhone } from '../utils/formatters';
import LoadingSpinner from './LoadingSpinner';
import EmptyState from './EmptyState';
import AttendanceCalendar from './AttendanceCalendar';
import { showToast } from '../utils/toast';
import { API_URL } from '../api';
import { USE_SUPABASE } from '../backend/mode';

export default function EmployeeDirectory() {
  const [employees, setEmployees] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [selectedEmployee, setSelectedEmployee] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({});
  const [loginIdManual, setLoginIdManual] = useState(false);
  const [currentMonth, setCurrentMonth] = useState(new Date());

  useEffect(() => { loadEmployees(); }, []);
  const loadEmployees = async () => { setLoading(true); try { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/employees`, { headers: { 'Authorization': `Bearer ${token}` } }); setEmployees(await res.json()); } catch { showToast('Failed to load employees', 'error'); } setLoading(false); };
  const loadEmployeeDetail = async (id) => { try { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/employees/${id}`, { headers: { 'Authorization': `Bearer ${token}` } }); setSelectedEmployee(await res.json()); } catch { showToast('Failed to load employee details', 'error'); } };
  const handleSubmit = async (e) => { e.preventDefault(); try { const token = localStorage.getItem('token'); const url = formData.id ? `${API_URL}/api/employees/${formData.id}` : `${API_URL}/api/employees`; const res = await fetch(url, { method: formData.id ? 'PATCH' : 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(formData) }); if (!res.ok) { let detail = `Failed to save employee (${res.status})`; try { const body = await res.json(); if (body?.detail) detail = typeof body.detail === 'string' ? body.detail : JSON.stringify(body.detail); } catch {} showToast(detail, 'error'); return; } showToast(formData.id ? 'Employee updated' : 'Employee created', 'success'); setShowForm(false); setFormData({}); setLoginIdManual(false); loadEmployees(); } catch { showToast('Failed to save employee', 'error'); } };
  const markLeaveDay = async (date, type) => { try { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/employees/${selectedEmployee.id}/leave`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ leave_date: date, leave_type: type }) }); if (!res.ok) { const error = await res.json(); showToast(error.detail || 'Failed to mark leave', 'error'); return; } showToast(type === 'wfh' ? 'Work from home marked' : 'Leave marked', 'success'); loadEmployeeDetail(selectedEmployee.id); } catch { showToast('Failed to mark leave', 'error'); } };
  const resetPassword = async (emp) => { if (!window.confirm(`Reset ${emp.name}'s password to their mobile number?`)) return; try { const token = localStorage.getItem('token'); const res = await fetch(`${API_URL}/api/employees/${emp.id}/reset-password`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}` } }); const data = await res.json().catch(() => ({})); if (!res.ok) { showToast(data.detail || 'Failed to reset password', 'error'); return; } showToast('Password reset to their mobile number', 'success'); } catch { showToast('Failed to reset password', 'error'); } };
  const unmarkLeaveDay = async (date) => { try { const token = localStorage.getItem('token'); await fetch(`${API_URL}/api/employees/${selectedEmployee.id}/leave/${date}`, { method: 'DELETE', headers: { 'Authorization': `Bearer ${token}` } }); showToast('Day unmarked', 'success'); loadEmployeeDetail(selectedEmployee.id); } catch { showToast('Failed to unmark leave', 'error'); } };

  const filteredEmployees = employees.filter(emp => { if (statusFilter !== 'all' && emp.status !== statusFilter) return false; if (searchQuery) { const query = searchQuery.toLowerCase(); return emp.name.toLowerCase().includes(query) || (emp.employee_id && emp.employee_id.toLowerCase().includes(query)) || (emp.job_role && emp.job_role.toLowerCase().includes(query)); } return true; });
  const STATUS_COLORS = { active: 'bg-green-100 text-green-800', 'non-active': 'bg-gray-100 text-gray-800' };

  if (loading) return <LoadingSpinner size="lg" text="Loading employees..." />;

  return (
    <div className="max-w-7xl mx-auto">
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-6 gap-4"><h2 className="text-2xl font-bold text-glass-primary">Employee Directory</h2><button onClick={() => { setFormData({}); setLoginIdManual(false); setShowForm(true); }} className="glass-btn px-4 py-2">+ Add Employee</button></div>
      <div className="flex flex-col sm:flex-row gap-3 mb-6"><input type="text" placeholder="🔍 Search by name, ID, role..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} className="glass-input flex-1 px-4 py-2" /><select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} className="glass-input px-4 py-2"><option value="all">All Status</option><option value="active">Active</option><option value="non-active">Non-Active</option></select></div>
      <div className="text-sm text-glass-secondary mb-3">Showing {filteredEmployees.length} of {employees.length} employees</div>
      {filteredEmployees.length === 0 ? <EmptyState icon="👥" title="No employees found" description={searchQuery ? "Try adjusting your search or filters" : "Click 'Add Employee' to get started"} /> : (
        <div className="glass-table overflow-x-auto">
          <table className="w-full">
            <thead><tr><th>Employee ID</th><th>Name</th><th>Job Role</th><th>Date of Joining</th><th>Status</th><th className="text-right">Actions</th></tr></thead>
            <tbody className="divide-y" style={{ borderColor: 'rgba(60,60,67,0.22)' }}>
              {filteredEmployees.map(emp => (
                <tr key={emp.id}>
                  <td className="text-glass-primary">{emp.employee_id || '-'}</td>
                  <td><div className="flex items-center gap-3"><div className="w-10 h-10 rounded-full flex items-center justify-center font-semibold text-sm text-white" style={{ background: '#5856D6' }}>{emp.name.charAt(0).toUpperCase()}</div><div className="font-medium text-glass-primary">{emp.name}</div></div></td>
                  <td className="text-glass-primary">{emp.job_role || '-'}</td>
                  <td className="text-glass-primary">{emp.joining_date ? formatDate(emp.joining_date) : '-'}</td>
                  <td><span className={`glass-badge ${STATUS_COLORS[emp.status] || 'bg-gray-100 text-gray-800'}`}>{emp.status === 'active' ? 'Active' : 'Non-Active'}</span></td>
                  <td className="text-right"><button onClick={() => loadEmployeeDetail(emp.id)} className="text-indigo-600 hover:text-indigo-800 font-medium text-sm">View →</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selectedEmployee && createPortal(
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
          <div className="glass-strong max-w-4xl w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
            <div className="flex justify-between items-start mb-6"><div className="flex items-center gap-4"><div className="w-16 h-16 rounded-full flex items-center justify-center text-2xl font-bold text-white" style={{ background: '#5856D6', boxShadow: '0 4px 12px rgba(99,102,241,0.30)' }}>{selectedEmployee.name.charAt(0).toUpperCase()}</div><div><h2 className="text-2xl font-bold text-glass-primary">{selectedEmployee.name}</h2><p className="text-glass-secondary">{selectedEmployee.job_role || 'Employee'}</p></div></div><button onClick={() => setSelectedEmployee(null)} className="text-glass-muted hover:text-glass-primary text-2xl">×</button></div>
            <div className="space-y-6">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div><label className="text-sm font-medium text-glass-muted">Employee ID</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.employee_id || '-'}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Employee Name</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.name}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Date of Joining</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.joining_date ? formatDate(selectedEmployee.joining_date) : '-'}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Date of Birth</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.date_of_birth ? formatDate(selectedEmployee.date_of_birth) : '—'}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Status</label><div className="mt-1"><span className={`glass-badge ${STATUS_COLORS[selectedEmployee.status]}`}>{selectedEmployee.status === 'active' ? 'Active' : 'Non-Active'}</span></div></div>
                {selectedEmployee.status === 'non-active' && selectedEmployee.date_of_leaving && <div><label className="text-sm font-medium text-glass-muted">Date of Leaving</label><div className="mt-1 text-glass-primary font-medium">{formatDate(selectedEmployee.date_of_leaving)}</div></div>}
                <div><label className="text-sm font-medium text-glass-muted">Monthly Salary</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.monthly_salary ? `₹${parseFloat(selectedEmployee.monthly_salary).toLocaleString('en-IN')}` : '-'}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Paid Leave Quota (Monthly)</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.paid_leave_quota || 0} days/month{selectedEmployee.paid_leave_quota > 0 && <span className="ml-2 text-sm text-indigo-600">(This month: {selectedEmployee.paid_leave_used || 0} used, {selectedEmployee.paid_leave_remaining || 0} left)</span>}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Department</label><div className="mt-1"><span className={`glass-badge ${selectedEmployee.department === 'Admin' ? 'bg-purple-100 text-purple-800' : selectedEmployee.department === 'Sales' ? 'bg-blue-100 text-blue-800' : selectedEmployee.department === 'IT' ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'}`}>{selectedEmployee.department}</span></div></div>
                <div><label className="text-sm font-medium text-glass-muted">Contact Number</label><div className="mt-1 text-glass-primary font-medium">{formatPhone(selectedEmployee.phone)}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Email Address</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.email || '-'}</div></div>
                <div><label className="text-sm font-medium text-glass-muted">Job Role</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.job_role || '-'}</div></div>
                <div className="md:col-span-2"><label className="text-sm font-medium text-glass-muted">Address</label><div className="mt-1 text-glass-primary font-medium">{selectedEmployee.address || '-'}</div></div>
              </div>
              <div className="border-t pt-6" style={{ borderColor: 'rgba(60,60,67,0.22)' }}>
                {selectedEmployee.paid_leave_quota > 0 && <div className="mb-4 p-3 glass-subtle" style={{ background: 'rgba(0,122,255,0.08)' }}><div className="flex justify-between items-center"><span className="text-sm font-semibold text-blue-900">Paid Leave Status (This Month)</span><span className="text-lg font-bold text-blue-600">{selectedEmployee.paid_leave_remaining || 0} / {selectedEmployee.paid_leave_quota} remaining</span></div><p className="text-xs text-blue-700 mt-1">Used: {selectedEmployee.paid_leave_used || 0} days this month (resets monthly)</p></div>}
                <AttendanceCalendar employeeId={selectedEmployee.id} employeeName={selectedEmployee.name} month={currentMonth} setMonth={setCurrentMonth} leaveDays={selectedEmployee.leave_days} leaveCounts={selectedEmployee.leave_counts} paidLeaveQuota={selectedEmployee.paid_leave_quota || 0} paidLeaveRemaining={selectedEmployee.paid_leave_remaining || 0} onMarkLeave={markLeaveDay} onUnmarkLeave={unmarkLeaveDay} />
              </div>
            </div>
            <div className="mt-6 flex gap-3"><button onClick={() => { setFormData(selectedEmployee); setSelectedEmployee(null); setShowForm(true); }} className="glass-btn px-4 py-2">Edit Employee</button>{USE_SUPABASE && <button onClick={() => resetPassword(selectedEmployee)} className="px-4 py-2 rounded-lg font-medium" style={{ background: 'rgba(255,149,0,0.14)', color: '#C93400' }}>Reset Password</button>}<button onClick={() => setSelectedEmployee(null)} className="px-4 py-2 rounded-lg font-medium" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Close</button></div>
          </div>
        </div>,
        document.body
      )}

      {showForm && createPortal(
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto">
          <div className="glass-strong max-w-2xl w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
            <h2 className="text-xl font-bold mb-4 text-glass-primary">{formData.id ? 'Edit' : 'Add'} Employee</h2>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div><label className="block text-xs font-medium text-glass-muted mb-1">Employee ID</label><input type="text" placeholder="e.g. EMP001" value={formData.employee_id || ''} onChange={(e) => { const v = e.target.value; setFormData(prev => ({ ...prev, employee_id: v, login_id: (loginIdManual || prev.id) ? prev.login_id : v })); }} className="glass-input w-full px-3 py-2" /></div>
                <div><label className="block text-xs font-medium text-glass-muted mb-1">Login ID <span className="text-red-500">*</span></label><input type="text" placeholder="Login ID" value={formData.login_id || ''} onChange={(e) => { setLoginIdManual(true); setFormData({...formData, login_id: e.target.value}); }} className="glass-input w-full px-3 py-2" required /></div>
                <input type="text" placeholder="Full Name *" value={formData.name || ''} onChange={(e) => setFormData({...formData, name: e.target.value})} className="glass-input px-3 py-2" required />
                <input type="date" placeholder="Date of Joining" value={formData.joining_date || ''} onChange={(e) => setFormData({...formData, joining_date: e.target.value})} className="glass-input px-3 py-2" />
                {/* Optional. Cleared input sends null (never ""), which the API stores as NULL. */}
                <div><label className="block text-xs font-medium text-glass-muted mb-1">Date of Birth</label><input type="date" value={formData.date_of_birth || ''} onChange={(e) => setFormData({...formData, date_of_birth: e.target.value || null})} className="glass-input w-full px-3 py-2" /></div>
                <select value={formData.status || 'active'} onChange={(e) => setFormData({...formData, status: e.target.value})} className="glass-input px-3 py-2"><option value="active">Active</option><option value="non-active">Non-Active</option></select>
                {formData.status === 'non-active' && <input type="date" placeholder="Date of Leaving" value={formData.date_of_leaving || ''} onChange={(e) => setFormData({...formData, date_of_leaving: e.target.value})} className="glass-input px-3 py-2" />}
                <input type="number" placeholder="Monthly Salary" value={formData.monthly_salary || ''} onChange={(e) => setFormData({...formData, monthly_salary: e.target.value})} className="glass-input px-3 py-2" step="0.01" />
                <input type="number" placeholder="Paid Leave Quota (Monthly)" value={formData.paid_leave_quota || ''} onChange={(e) => setFormData({...formData, paid_leave_quota: e.target.value})} className="glass-input px-3 py-2" min="0" />
                <select value={formData.department || ''} onChange={(e) => setFormData({...formData, department: e.target.value})} className="glass-input px-3 py-2" required><option value="">Select Department *</option><option value="Admin">Admin</option><option value="IT">IT</option><option value="Sales">Sales</option><option value="Instructors">Instructors</option></select>
                <input type="tel" placeholder="Contact Number *" value={formData.phone || ''} onChange={(e) => setFormData({...formData, phone: e.target.value})} className="glass-input px-3 py-2" required />
                <input type="email" placeholder="Email Address" value={formData.email || ''} onChange={(e) => setFormData({...formData, email: e.target.value})} className="glass-input px-3 py-2" />
                <input type="text" placeholder="Job Role" value={formData.job_role || ''} onChange={(e) => setFormData({...formData, job_role: e.target.value})} className="glass-input px-3 py-2" />
                {USE_SUPABASE ? (<div className="text-xs text-glass-muted self-end pb-2">First password is their mobile number. They can change it in My Profile.</div>) : (<div><label className="block text-xs font-medium text-glass-muted mb-1">Login PIN (optional, 4 digits)</label><input type="text" inputMode="numeric" pattern="\d{4}" maxLength={4} placeholder="e.g. 1234" value={formData.login_pin || ''} onChange={(e) => setFormData({...formData, login_pin: e.target.value.replace(/\D/g, '').slice(0, 4)})} className="glass-input w-full px-3 py-2" /></div>)}
              </div>
              <textarea placeholder="Address" value={formData.address || ''} onChange={(e) => setFormData({...formData, address: e.target.value})} className="glass-input w-full px-3 py-2" rows={2} />
              <div className="flex gap-3 pt-4"><button type="submit" className="glass-btn px-6 py-2">{formData.id ? 'Update' : 'Create'} Employee</button><button type="button" onClick={() => { setShowForm(false); setFormData({}); setLoginIdManual(false); }} className="px-6 py-2 rounded-lg font-medium" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Cancel</button></div>
            </form>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
