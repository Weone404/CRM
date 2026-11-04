import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { API_URL } from '../api';
import { USE_SUPABASE } from '../backend/mode';

export default function QuoteGenerator({ lead, onClose }) {
  const [courses, setCourses] = useState([]);
  const [selectedCourse, setSelectedCourse] = useState('');
  const [discount, setDiscount] = useState(0);
  const [installments, setInstallments] = useState(1);
  const [downPayment, setDownPayment] = useState(0);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    loadCourses();
  }, []);

  const loadCourses = async () => {
    const token = localStorage.getItem('token');
    const res = await fetch(`${API_URL}/api/courses`, {
      headers: { 'Authorization': `Bearer ${token}` }
    });
    const data = await res.json();
    setCourses(data);
  };

  const selectedCourseData = courses.find(c => c.id === selectedCourse);
  const baseFee = selectedCourseData?.base_fee || 0;
  const discountAmount = Math.round(baseFee * discount / 100);
  const discountedPrice = baseFee - discountAmount;
  const remainingAfterDown = discountedPrice - downPayment;
  const installmentAmount = installments > 1 ? Math.round(remainingAfterDown / (installments - 1)) : 0;

  const handleGenerate = async () => {
    if (!selectedCourse) {
      alert('Select a course first');
      return;
    }

    const token = localStorage.getItem('token');
    
    if (!USE_SUPABASE && discount > 0) {
      await fetch(`${API_URL}/api/courses/${selectedCourse}/discount`, {
        method: 'PATCH',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ discount_percent: discount })
      });
    }

    if (!USE_SUPABASE && installments !== selectedCourseData?.installment_count) {
      await fetch(`${API_URL}/api/courses/${selectedCourse}/installments`, {
        method: 'PATCH',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ installment_count: installments })
      });
    }

    setLoading(true);
    const res = await fetch(`${API_URL}/api/quotes/generate`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        lead_id: lead.id,
        course_id: selectedCourse,
        down_payment: downPayment,
        // Supabase: this quote's own discount and instalments (the course itself is not changed)
        ...(USE_SUPABASE ? { discount_percent: discount, installment_count: installments } : {})
      })
    });
    const data = await res.json();
    setLoading(false);

    if (res.ok) {
      alert(`Quote ${data.quote_id} generated! Check Outbox to review before sending.`);
      onClose();
    } else {
      alert(USE_SUPABASE && data?.detail ? `Could not generate the quote: ${data.detail}` : 'Failed to generate quote');
    }
  };

  return createPortal(
    <div className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto animate-glass-in">
      <div className="glass-strong max-w-lg w-full p-6 my-8 max-h-[90vh] overflow-y-auto">
        <div className="flex justify-between items-start mb-4">
          <div>
            <h2 className="text-xl font-bold">Generate Quote</h2>
            <p className="text-glass-secondary text-sm">{lead.name}</p>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600 text-2xl"
          >
            ×
          </button>
        </div>

        <div className="mb-4">
          <label className="block text-sm font-semibold mb-2">Select Course</label>
          <select
            value={selectedCourse}
            onChange={(e) => {
              setSelectedCourse(e.target.value);
              setDiscount(0);
              setInstallments(1);
              setDownPayment(0);
            }}
            className="w-full glass-input px-3 py-2"
          >
            <option value="">-- Choose Course --</option>
            {courses.map(c => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </div>

        {selectedCourse && (
          <>
            <div className="mb-4 p-4 glass-subtle rounded-lg" style={{ backgroundColor: '#eff6ff' }}>
              <div className="flex justify-between items-center mb-2">
                <span className="text-sm font-semibold text-gray-700">Total Course Fee</span>
                <span className="text-xl font-bold text-blue-900">₹{baseFee.toLocaleString()}</span>
              </div>
            </div>

            <div className="mb-4">
              <label className="block text-sm font-semibold mb-2">Discount %</label>
              <div className="flex items-center gap-3">
                <input
                  type="range"
                  value={discount}
                  onChange={(e) => setDiscount(parseFloat(e.target.value))}
                  min="0"
                  max="100"
                  step="0.5"
                  className="flex-1"
                />
                <input
                  type="number"
                  value={discount}
                  onChange={(e) => setDiscount(Math.max(0, Math.min(100, parseFloat(e.target.value) || 0)))}
                  className="w-20 glass-input px-2 py-1 text-center"
                  min="0"
                  max="100"
                  step="0.5"
                />
                <span className="text-sm font-semibold">%</span>
              </div>
              {discount > 0 && (
                <p className="text-xs text-green-600 mt-1">Discount: -₹{discountAmount.toLocaleString()}</p>
              )}
            </div>

            {discount > 0 && (
              <div className="mb-4 p-4 glass-subtle rounded-lg" style={{ backgroundColor: '#f0fdf4' }}>
                <div className="flex justify-between items-center">
                  <span className="text-sm font-semibold text-gray-700">Discounted Price</span>
                  <span className="text-xl font-bold text-green-900">₹{discountedPrice.toLocaleString()}</span>
                </div>
              </div>
            )}

            <div className="mb-4 p-4 glass-subtle rounded-lg" style={{ backgroundColor: '#faf5ff' }}>
              <div className="flex justify-between items-center">
                <span className="text-sm font-semibold text-gray-700">Final Amount</span>
                <span className="text-2xl font-bold text-purple-900">₹{discountedPrice.toLocaleString()}</span>
              </div>
            </div>

            <div className="mb-4">
              <label className="block text-sm font-semibold mb-2">Number of Installments</label>
              <select
                value={installments}
                onChange={(e) => {
                  const val = parseInt(e.target.value);
                  setInstallments(val);
                  if (val === 1) setDownPayment(0);
                }}
                className="w-full glass-input px-3 py-2"
              >
                <option value="1">1 (Full Payment)</option>
                <option value="2">2 Installments</option>
                <option value="3">3 Installments</option>
                <option value="4">4 Installments</option>
                <option value="6">6 Installments</option>
                <option value="12">12 Installments</option>
              </select>
            </div>

            {installments > 1 && (
              <>
                <div className="mb-4">
                  <label className="block text-sm font-semibold mb-2">First Down Payment Amount</label>
                  <div className="flex items-center gap-2">
                    <span className="text-lg">₹</span>
                    <input
                      type="number"
                      value={downPayment}
                      onChange={(e) => setDownPayment(Math.max(0, Math.min(discountedPrice, parseInt(e.target.value) || 0)))}
                      className="flex-1 glass-input px-3 py-2"
                      placeholder="0"
                      min="0"
                      max={discountedPrice}
                    />
                  </div>
                  <div className="flex justify-between text-xs text-glass-muted mt-1">
                    <button
                      type="button"
                      onClick={() => setDownPayment(Math.round(discountedPrice * 0.25))}
                      className="text-blue-600 hover:underline"
                    >
                      25%
                    </button>
                    <button
                      type="button"
                      onClick={() => setDownPayment(Math.round(discountedPrice * 0.50))}
                      className="text-blue-600 hover:underline"
                    >
                      50%
                    </button>
                    <button
                      type="button"
                      onClick={() => setDownPayment(Math.round(discountedPrice * 0.75))}
                      className="text-blue-600 hover:underline"
                    >
                      75%
                    </button>
                  </div>
                </div>

                <div className="mb-4 p-4 glass-subtle rounded-lg" style={{ backgroundColor: '#f3f4f6' }}>
                  <h3 className="text-sm font-semibold mb-2">Payment Breakdown</h3>
                  <div className="space-y-1 text-sm">
                    <div className="flex justify-between">
                      <span>Down Payment:</span>
                      <span className="font-semibold">₹{downPayment.toLocaleString()}</span>
                    </div>
                    {installmentAmount > 0 && (
                      <>
                        <div className="flex justify-between">
                          <span>Each Installment ({installments - 1}×):</span>
                          <span className="font-semibold">₹{installmentAmount.toLocaleString()}</span>
                        </div>
                        <div className="flex justify-between pt-1 border-t border-gray-300">
                          <span>Total:</span>
                          <span className="font-bold">₹{(downPayment + (installmentAmount * (installments - 1))).toLocaleString()}</span>
                        </div>
                      </>
                    )}
                  </div>
                </div>
              </>
            )}

            <button
              onClick={handleGenerate}
              disabled={loading}
              className="w-full glass-btn py-3 font-semibold disabled:bg-gray-400 disabled:cursor-not-allowed transition"
            >
              {loading ? 'Generating PDF...' : 'Generate Quote → Outbox'}
            </button>
          </>
        )}
      </div>
    </div>,
    document.body
  );
}
