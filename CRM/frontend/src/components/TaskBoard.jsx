import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { formatDate } from '../utils/formatters';
import { showToast } from '../utils/toast';
import LoadingSpinner from './LoadingSpinner';
import { API_URL } from '../api';
import { modalProps } from './ui/overlay';
import { confirmDialog, promptDialog, choiceDialog, alertDialog } from './ui/dialogs';
import AppleSelect from './ui/AppleSelect';

export default function TaskBoard() {
  const [employees, setEmployees] = useState([]);
  const [tasks, setTasks] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAddTask, setShowAddTask] = useState(false);
  const [formData, setFormData] = useState({});
  const [currentEmployee, setCurrentEmployee] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [confirmDeleteId, setConfirmDeleteId] = useState(null);

  const department = currentEmployee?.department || '';
  const canViewAllEmployees = department === 'Admin';

  useEffect(() => { const empStr = localStorage.getItem('employee'); if (empStr) { const emp = JSON.parse(empStr); setCurrentEmployee(emp); } }, []);
  useEffect(() => { if (currentEmployee) loadData(); }, [currentEmployee]);

  const loadData = async () => {
    setLoading(true);
    try {
      const token = localStorage.getItem('token');
      const tasksRes = await fetch(`${API_URL}/api/tasks`, { headers: { 'Authorization': `Bearer ${token}` } });
      const tasksData = await tasksRes.json(); setTasks(tasksData);
      if (canViewAllEmployees) {
        try { const empRes = await fetch(`${API_URL}/api/employees`, { headers: { 'Authorization': `Bearer ${token}` } }); if (empRes.ok) setEmployees(await empRes.json()); } catch { if (currentEmployee) setEmployees([{ id: currentEmployee.id, name: currentEmployee.name, job_role: currentEmployee.job_role }]); }
      } else { if (currentEmployee) setEmployees([{ id: currentEmployee.id, name: currentEmployee.name, job_role: currentEmployee.job_role }]); }
    } catch { showToast('Failed to load task board', 'error'); }
    setLoading(false);
  };

  const handleAddTask = async (e) => {
    e.preventDefault(); if (submitting) return; setSubmitting(true);
    try {
      const token = localStorage.getItem('token');
      const res = await fetch(`${API_URL}/api/tasks`, { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(formData) });
      if (!res.ok) { const data = await res.json().catch(() => ({})); showToast(data.detail || 'Failed to add task', 'error'); return; }
      showToast('Task added', 'success'); setShowAddTask(false); setFormData({}); loadData();
    } catch { showToast('Failed to add task', 'error'); } finally { setSubmitting(false); }
  };

  const canDeleteTask = (task) => department === 'Admin' || task.created_by === currentEmployee?.id || task.assigned_to === currentEmployee?.id;

  const handleDeleteTask = async (taskId) => {
    setConfirmDeleteId(null); const token = localStorage.getItem('token'); const previousTasks = tasks;
    setTasks(tasks.filter(t => t.id !== taskId));
    try { const res = await fetch(`${API_URL}/api/tasks/${taskId}`, { method: 'DELETE', headers: { 'Authorization': `Bearer ${token}` } }); if (!res.ok) { const data = await res.json().catch(() => ({})); showToast(data.detail || 'Failed to delete task', 'error'); setTasks(previousTasks); return; } showToast('Task deleted', 'success'); } catch { showToast('Failed to delete task', 'error'); setTasks(previousTasks); }
  };

  const handleStatusChange = async (taskId, newStatus) => {
    try {
      const token = localStorage.getItem('token'); const payload = { status: newStatus };
      if (newStatus === 'aborted') { const reason = await promptDialog('Abort this task?', { message: 'Write the reason (required).', placeholder: 'Reason', required: true, confirmText: 'Abort task', multiline: true }); if (!reason) return; payload.abort_reason = reason; }
      await fetch(`${API_URL}/api/tasks/${taskId}`, { method: 'PATCH', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      showToast('Task updated', 'success'); loadData();
    } catch { showToast('Failed to update task', 'error'); }
  };

  const getEmployeeTasks = (employeeId) => tasks.filter(t => t.assigned_to === employeeId);
  const getPendingCount = (employeeId) => tasks.filter(t => t.assigned_to === employeeId && t.status === 'pending').length;

  const STATUS_COLORS = { pending: 'bg-amber-100 text-amber-800 border-amber-200', done: 'bg-green-100 text-green-800 border-green-200', aborted: 'bg-red-100 text-red-800 border-red-200' };
  const STATUS_LABELS = { pending: 'Pending', done: 'Completed', aborted: 'Aborted' };

  if (loading) return <LoadingSpinner size="lg" text="Loading task board..." />;

  return (
    <div className="max-w-7xl mx-auto">
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-6 gap-4">
        <div><h2 className="text-2xl font-bold text-glass-primary">{canViewAllEmployees ? 'Task Board' : 'My Tasks'}</h2><p className="text-sm text-glass-secondary mt-1">{canViewAllEmployees ? 'Manage tasks across your team' : 'Manage your assigned tasks'}</p></div>
        <button onClick={() => { setFormData(canViewAllEmployees ? {} : { assigned_to: currentEmployee.id }); setShowAddTask(true); }} className="glass-btn px-4 py-2">+ Add Task</button>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {employees.map(emp => {
          const employeeTasks = getEmployeeTasks(emp.id); const pendingCount = getPendingCount(emp.id);
          return (
            <div key={emp.id} className="glass-card overflow-hidden">
              <div className="p-6" style={{ background: 'linear-gradient(135deg, rgba(88,86,214,0.10), rgba(88,86,214,0.08))', borderBottom: '1px solid rgba(60,60,67,0.12)' }}>
                <div className="flex items-center gap-4">
                  <div className="w-14 h-14 rounded-full flex items-center justify-center text-xl font-bold text-white" style={{ background: '#5856D6', boxShadow: '0 4px 12px rgba(99,102,241,0.30)' }}>{emp.name.charAt(0).toUpperCase()}</div>
                  <div className="flex-1 min-w-0"><h3 className="font-semibold text-glass-primary text-lg truncate">{emp.name}</h3><p className="text-sm text-glass-secondary truncate">{emp.job_role || 'Employee'}</p></div>
                </div>
                <div className="mt-4 inline-flex items-center gap-2 px-3 py-1.5 glass-subtle">
                  <span className="text-sm font-medium text-glass-secondary">Pending Tasks:</span>
                  <span className={`text-lg font-bold ${pendingCount > 0 ? 'text-amber-600' : 'text-green-600'}`}>{pendingCount}</span>
                </div>
              </div>
              <div className="p-4">
                {employeeTasks.length === 0 ? (
                  <div className="text-center py-8 text-glass-muted"><div className="text-3xl mb-2">✓</div><p className="text-sm">No tasks assigned</p></div>
                ) : (
                  <div className="space-y-3">
                    {employeeTasks.map(task => (
                      <div key={task.id} className="glass-subtle p-3">
                        <div className="flex items-start justify-between gap-3 mb-2">
                          <h4 className="font-medium text-glass-primary text-sm flex-1">{task.title}</h4>
                          <div className="flex items-center gap-1">
                            <AppleSelect value={task.status} onChange={(e) => handleStatusChange(task.id, e.target.value)} className={`text-xs px-2 py-1 rounded-full border font-medium ${STATUS_COLORS[task.status] || 'glass-subtle text-glass-primary'}`}>{<option value="pending">Pending</option>}<option value="done">Completed</option><option value="aborted">Aborted</option></AppleSelect>
                            {canDeleteTask(task) && confirmDeleteId !== task.id && <button onClick={() => setConfirmDeleteId(task.id)} title="Delete task" className="p-1 text-glass-muted hover:text-red-600 transition">🗑️</button>}
                          </div>
                        </div>
                        {confirmDeleteId === task.id && (
                          <div className="flex items-center gap-2 mb-2 text-xs rounded-lg px-2 py-1.5" style={{ background: 'rgba(255,59,48,0.08)', border: '1px solid rgba(255,59,48,0.35)' }}>
                            <span className="text-red-700 font-medium flex-1">Delete this task?</span>
                            <button onClick={() => handleDeleteTask(task.id)} className="px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700 font-medium">Delete</button>
                            <button onClick={() => setConfirmDeleteId(null)} className="px-2 py-1 glass-subtle text-glass-secondary font-medium">Cancel</button>
                          </div>
                        )}
                        {task.description && <p className="text-xs text-glass-secondary mb-2 line-clamp-2">{task.description}</p>}
                        <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-glass-muted">
                          <span>Assigned: {formatDate(task.created_at)}</span>
                          {task.status === 'done' && task.finish_date && <span className="text-green-600 font-medium">✓ Finished: {formatDate(task.finish_date)}</span>}
                          {task.status === 'aborted' && task.abort_reason && <span className="text-red-600 font-medium" title={task.abort_reason}>✕ Aborted: {task.abort_reason.substring(0, 30)}{task.abort_reason.length > 30 ? '...' : ''}</span>}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>
      {employees.length === 0 && <div className="text-center py-16 text-glass-muted"><div className="text-5xl mb-4">👥</div><h3 className="text-lg font-medium text-glass-secondary mb-2">No employees found</h3><p className="text-sm">Add employees to start assigning tasks</p></div>}

      {showAddTask && createPortal(
        <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto" {...modalProps(() => { setShowAddTask(false); setFormData({}); }, { guard: true })}>
          <div className="glass-strong max-w-md w-full p-6 my-8 max-h-[90vh] overflow-y-auto animate-glass-in">
            <h2 className="text-xl font-bold mb-4 text-glass-primary">Add New Task</h2>
            <form onSubmit={handleAddTask} className="space-y-4">
              {canViewAllEmployees && <div><label className="block text-sm font-medium text-glass-secondary mb-1">Assign To *</label><AppleSelect value={formData.assigned_to || ''} onChange={(e) => setFormData({...formData, assigned_to: e.target.value})} className="glass-input w-full px-3 py-2" required><option value="">Select employee...</option>{employees.map(emp => <option key={emp.id} value={emp.id}>{emp.name}</option>)}</AppleSelect></div>}
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Task Title *</label><input type="text" value={formData.title || ''} onChange={(e) => setFormData({...formData, title: e.target.value})} className="glass-input w-full px-3 py-2" placeholder="e.g., Follow up with lead" required /></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Description</label><textarea value={formData.description || ''} onChange={(e) => setFormData({...formData, description: e.target.value})} className="glass-input w-full px-3 py-2" rows={3} placeholder="Task details..." /></div>
              <div><label className="block text-sm font-medium text-glass-secondary mb-1">Due Date</label><input type="date" value={formData.due_date || ''} onChange={(e) => setFormData({...formData, due_date: e.target.value})} className="glass-input w-full px-3 py-2" /></div>
              <div className="flex gap-3 pt-4"><button type="submit" disabled={submitting} className="glass-btn flex-1 px-4 py-2">{submitting ? 'Adding...' : 'Add Task'}</button><button type="button" disabled={submitting} onClick={() => { setShowAddTask(false); setFormData({}); }} className="px-4 py-2 rounded-lg font-medium" style={{ background: 'rgba(118,118,128,0.12)', color: 'rgba(0,0,0,0.6)' }}>Cancel</button></div>
            </form>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
