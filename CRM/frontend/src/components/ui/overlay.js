// One behaviour for every pop-up in the CRM.
//   <div className="fixed inset-0 glass-overlay …" {...modalProps(onClose)}> <div className="glass-strong …">…</div> </div>
// * a click or tap on the dimmed background (outside the window) closes it
// * Esc closes the top-most window (installModalKeys, once, in main.jsx)
// * the page behind does not scroll while a window is open, and focus moves into the window
// * on phones the window becomes a bottom sheet (CSS: .glass-overlay[data-modal] in index.css)
// guard: a form window asks "Discard changes?" before closing from outside/Esc once something was typed in it.
export function modalProps(onClose, { guard = false } = {}) {
  const attempt = async (el) => {
    if (!onClose) return;
    if (guard && el.dataset.dirty === '1') {
      const { confirmDialog } = await import('./dialogs');
      if (!(await confirmDialog('Discard your changes?', { message: 'What you typed in this window will be lost.', confirmText: 'Discard', cancelText: 'Keep editing', danger: true }))) return;
    }
    onClose();
  };
  return {
    'data-modal': '',
    onInput: guard ? (e) => { e.currentTarget.dataset.dirty = '1'; } : undefined,
    onMouseDown: (e) => { if (e.target === e.currentTarget) e.currentTarget.dataset.downOutside = '1'; },
    onClick: (e) => {
      const el = e.currentTarget;
      const outside = e.target === el && el.dataset.downOutside === '1';
      delete el.dataset.downOutside;
      if (outside) attempt(el);
    },
    onKeyDown: (e) => { if (e.key === 'Escape') { e.stopPropagation(); attempt(e.currentTarget); } },
  };
}

let installed = false;
export function installModalKeys() {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  const top = () => { const all = document.querySelectorAll('[data-modal]'); return all[all.length - 1] || null; };
  // Esc when focus is outside any window (e.g. on the page): send it to the top-most window
  window.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || e.defaultPrevented) return;
    const m = top();
    if (m && !m.contains(document.activeElement)) {
      m.dataset.downOutside = '1';
      m.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    }
  });
  let locked = false, saved = '';
  const sync = () => {
    const m = top();
    if (m && !locked) { saved = document.body.style.overflow; document.body.style.overflow = 'hidden'; locked = true; }
    if (!m && locked) { document.body.style.overflow = saved; locked = false; }
    if (m && !m.contains(document.activeElement)) {
      // the window itself takes focus (so Esc and Tab work) without popping up the phone keyboard; [autofocus] wins
      const f = m.querySelector('[autofocus]');
      const win = [...m.children].find((c) => c.getAttribute('aria-hidden') !== 'true');
      if (win && !win.hasAttribute('tabindex')) win.setAttribute('tabindex', '-1');
      (f || win)?.focus({ preventScroll: true });
    }
  };
  new MutationObserver(sync).observe(document.body, { childList: true, subtree: true });
}
