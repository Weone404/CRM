export const formatCurrency = (amount) => {
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    maximumFractionDigits: 0
  }).format(amount);
};

export const formatDate = (dateString) => {
  return new Date(dateString).toLocaleDateString('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric'
  });
};

export const formatDateTime = (dateString) => {
  return new Date(dateString).toLocaleString('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  });
};

export const formatRelativeTime = (dateString) => {
  const date = new Date(dateString);
  const now = new Date();
  const diffMs = now - date;
  const diffMins = Math.floor(diffMs / 60000);
  
  if (diffMins < 1) return 'Just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  
  const diffHours = Math.floor(diffMins / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 30) return `${diffDays}d ago`;
  
  return formatDate(dateString);
};

// Indian mobile numbers as plain 10 digits: "+91 98765 43210", "098765-43210", "919876543210" -> "9876543210".
// Anything that isn't a phone number (e.g. a login ID) is returned unchanged.
export const toMobile10 = (raw) => {
  const t = String(raw ?? '').trim();
  if (!/^[\s+().\-\d]+$/.test(t)) return t;
  let d = t.replace(/\D/g, '');
  if (d.length === 12 && d.startsWith('91')) d = d.slice(2);
  else if (d.length === 13 && d.startsWith('091')) d = d.slice(3);
  else if (d.length === 11 && d.startsWith('0')) d = d.slice(1);
  return d.length === 10 ? d : t;
};

// For display: no +91.
export const displayPhone = (phone) => (phone ? toMobile10(phone) : phone);

export const formatPhone = (phone) => {
  const d = displayPhone(phone || '');
  return /^\d{10}$/.test(d) ? `${d.slice(0, 5)} ${d.slice(5)}` : d;
};
