// Notices appear like the Dynamic Island: a dark capsule that springs open at the top centre and folds back in.
const TONES = {
  success: ['#34C759', '<path d="M20 6 9 17l-5-5"/>'],
  error: ['#FF453A', '<path d="M18 6 6 18M6 6l12 12"/>'],
  warning: ['#FF9F0A', '<path d="M12 8v5M12 17h.01"/>'],
  info: ['#0A84FF', '<path d="M12 11v6M12 7h.01"/>'],
};

export function showToast(message, type = 'info') {
  const container = getOrCreateContainer();
  const [color, path] = TONES[type] || TONES.info;
  const toast = document.createElement('div');
  toast.className = 'island-toast';
  toast.setAttribute('role', type === 'error' ? 'alert' : 'status');
  const icon = document.createElement('span');
  icon.className = 'island-icon';
  icon.style.background = color;
  icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">${path}</svg>`;
  const text = document.createElement('span');
  text.className = 'island-text';
  text.textContent = String(message ?? '');           // text only: messages can contain server text
  toast.append(icon, text);
  container.appendChild(toast);
  const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  if (!reduce && toast.animate) {
    toast.animate([{ transform: 'scale(0.35, 0.6)', opacity: 0, filter: 'blur(4px)' }, { transform: 'scale(1.04, 1)', opacity: 1, filter: 'blur(0)', offset: 0.7 },
      { transform: 'none', opacity: 1 }], { duration: 520, easing: 'cubic-bezier(.3,1.2,.4,1)' });
  }
  const life = Math.min(7000, 2600 + String(message ?? '').length * 30);
  setTimeout(() => {
    const done = () => toast.remove();
    if (reduce || !toast.animate) { done(); return; }
    toast.animate([{ transform: 'none', opacity: 1 }, { transform: 'scale(0.4, 0.6)', opacity: 0, filter: 'blur(4px)' }],
      { duration: 320, easing: 'cubic-bezier(.5,0,.75,0)', fill: 'forwards' }).onfinish = done;
  }, life);
}

function getOrCreateContainer() {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.setAttribute('aria-live', 'polite');
    document.body.appendChild(container);
  }
  return container;
}

export const toast = {
  success: (message) => showToast(message, 'success'),
  error: (message) => showToast(message, 'error'),
  info: (message) => showToast(message, 'info'),
  warning: (message) => showToast(message, 'warning')
};
