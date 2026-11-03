import { useState, useEffect } from 'react';
import { displayPhone } from '../utils/formatters';
import { API_URL } from '../api';

export default function DispositionStats() {
  const [stats, setStats] = useState({
    interested: 0,
    not_interested: 0,
    not_reachable: 0,
    callback: 0
  });
  const [selectedDisposition, setSelectedDisposition] = useState(null);
  const [dispositionData, setDispositionData] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    loadStats();
  }, []);

  const loadStats = async () => {
    const token = localStorage.getItem('token');
    try {
      const res = await fetch(`${API_URL}/api/dispositions/stats`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (res.ok) {
        const data = await res.json();
        setStats(data);
      }
    } catch (err) {
      console.error('Failed to load disposition stats:', err);
    }
  };

  const loadDispositionData = async (disposition) => {
    setLoading(true);
    const token = localStorage.getItem('token');
    try {
      const res = await fetch(`${API_URL}/api/dispositions/${disposition}`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (res.ok) {
        const data = await res.json();
        setDispositionData(data);
        setSelectedDisposition(disposition);
      }
    } catch (err) {
      console.error('Failed to load disposition data:', err);
    } finally {
      setLoading(false);
    }
  };

  const formatDate = (dateStr) => {
    const date = new Date(dateStr);
    return date.toLocaleString('en-IN', {
      day: '2-digit',
      month: 'short',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      hour12: true
    });
  };

  return (
    <div className="mb-4 animate-glass-in">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
        <button
          onClick={() => loadDispositionData('interested')}
          className="glass-stat p-4 text-left transition cursor-pointer"
          style={{ backgroundColor: '#f0fdf4' }}
        >
          <div className="text-sm text-green-700 font-semibold">Interested</div>
          <div className="text-3xl font-bold text-green-900">{stats.interested}</div>
        </button>

        <button
          onClick={() => loadDispositionData('not-interested')}
          className="glass-stat p-4 text-left transition cursor-pointer"
          style={{ backgroundColor: '#f3f4f6' }}
        >
          <div className="text-sm text-gray-700 font-semibold">Not Interested</div>
          <div className="text-3xl font-bold text-glass-primary">{stats.not_interested}</div>
        </button>

        <button
          onClick={() => loadDispositionData('not-reachable')}
          className="glass-stat p-4 text-left transition cursor-pointer"
          style={{ backgroundColor: '#fefce8' }}
        >
          <div className="text-sm text-yellow-700 font-semibold">Not Reachable</div>
          <div className="text-3xl font-bold text-yellow-900">{stats.not_reachable}</div>
        </button>

        <button
          onClick={() => loadDispositionData('callback')}
          className="glass-stat p-4 text-left transition cursor-pointer"
          style={{ backgroundColor: '#faf5ff' }}
        >
          <div className="text-sm text-purple-700 font-semibold">Callback</div>
          <div className="text-3xl font-bold text-purple-900">{stats.callback}</div>
        </button>
      </div>

      {selectedDisposition && (
        <div className="glass-card p-4">
          <div className="flex justify-between items-center mb-4">
            <h3 className="text-lg font-bold capitalize">{selectedDisposition.replace('-', ' ')} Leads</h3>
            <button
              onClick={() => {
                setSelectedDisposition(null);
                setDispositionData([]);
              }}
              className="text-gray-400 hover:text-gray-600 text-xl"
            >
              ×
            </button>
          </div>

          {loading ? (
            <div className="text-center py-8 text-glass-muted">Loading...</div>
          ) : (
            <div className="space-y-3 max-h-96 overflow-y-auto">
              {dispositionData.map(item => (
                <div key={item.id} className="glass-card p-4 hover:shadow-md transition">
                  <div className="flex justify-between items-start mb-2">
                    <div className="flex-1">
                      <div className="font-semibold text-lg">{item.name}</div>
                      <div className="text-sm text-glass-secondary">{displayPhone(item.phone)}</div>
                      <div className="text-sm text-glass-muted">{item.course_interest}</div>
                    </div>
                    <div className="text-xs text-glass-muted">
                      📅 {formatDate(item.marked_at)}
                    </div>
                  </div>
                  
                  {item.note && (
                    <div className="mt-2 p-2 glass-subtle rounded text-sm text-gray-700 italic">
                      💬 {item.note}
                    </div>
                  )}
                  
                  {item.callback_reason && (
                    <div className="mt-2 text-sm text-purple-700">
                      🔄 Callback: {item.callback_reason}
                      {item.callback_date && ` (${formatDate(item.callback_date)})`}
                    </div>
                  )}
                </div>
              ))}

              {dispositionData.length === 0 && (
                <div className="text-center py-8 text-glass-muted">No leads found</div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
