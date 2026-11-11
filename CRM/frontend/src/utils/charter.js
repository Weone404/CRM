// Helpers for charter leads (segment === 'charter'), which come from
// bookmycharter.in or are added by hand. Kept in one place so the list card,
// the detail view and the WhatsApp message all describe a trip the same way.

export const SEGMENTS = [
  { id: 'aviation', label: 'We One Aviation', icon: '🎓' },
  { id: 'charter', label: 'Book My Charter', icon: '🛩️' },
];

export const segmentOf = (lead) => lead.segment || 'aviation';

// "Delhi (DEL) — Indira Gandhi International" -> "Delhi (DEL)"
export const shortPlace = (place) => (place || '').split(' — ')[0].trim();

export const formatTripDate = (iso) => {
  if (!iso) return '';
  const d = new Date(`${iso}T00:00:00`);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
};

export const formatTime = (hhmm) => {
  if (!hhmm) return '';
  const [h, m] = hhmm.split(':').map(Number);
  const suffix = h >= 12 ? 'PM' : 'AM';
  return `${((h + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${suffix}`;
};

// Same rule as the backend's charter_reference(): what the customer was shown.
export const charterRef = (leadId) => `BMC-${String(leadId).replace(/-/g, '').slice(0, 8).toUpperCase()}`;

export const routeLine = (d = {}) => `${shortPlace(d.from) || '?'} → ${shortPlace(d.to) || '?'}`;

export const tripSummary = (d = {}) => {
  const parts = [routeLine(d)];
  if (d.departureDate) parts.push(formatTripDate(d.departureDate));
  if (d.passengers) parts.push(`${d.passengers} pax`);
  return parts.join(' · ');
};

const LABELS = {
  'one-way': 'One way', 'round-trip': 'Round trip', 'multi-city': 'Multi-city',
  'private-jet': 'Private jet', helicopter: 'Helicopter', turboprop: 'Turboprop',
  'executive-airliner': 'Regional aircraft', 'group-charter': 'Group aircraft',
  corporate: 'Corporate', leisure: 'Leisure', wedding: 'Wedding', medical: 'Medical',
  'film-and-aerial': 'Film / aerial', pilgrimage: 'Pilgrimage', event: 'Event', other: 'Other',
};
export const labelOf = (value) => LABELS[value] || value;

export const CLOSURE = {
  aviation: {
    positive: { value: 'admission_completed', label: 'Admission Completed', plural: 'Successful Admissions' },
    negative: { value: 'admission_aborted', label: 'Admission Aborted', plural: 'Failed Admissions' },
  },
  charter: {
    positive: { value: 'booking_confirmed', label: 'Booking Confirmed', plural: 'Bookings Confirmed' },
    negative: { value: 'booking_lost', label: 'Booking Lost', plural: 'Bookings Lost' },
  },
};

export const closureLabel = (outcome) => {
  for (const seg of Object.values(CLOSURE)) {
    if (seg.positive.value === outcome) return seg.positive.label;
    if (seg.negative.value === outcome) return seg.negative.label;
  }
  return 'Closed';
};
export const isPositiveClosure = (outcome) => outcome === 'admission_completed' || outcome === 'booking_confirmed';
