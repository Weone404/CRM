import { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';

// Confetti is CSS-only (no library, no canvas): a fixed set of small shapes that
// drift down once and settle. Static so it never re-randomises on a re-render.
// --dx is the horizontal drift, --spin the final rotation; both read by @keyframes
// bdConfettiFall in index.css, which is disabled under prefers-reduced-motion.
const CONFETTI = [
  { left: '6%',  delay: 0.0, dur: 5.4, dx: '18px',  spin: '210deg', color: '#5856D6', w: 7,  h: 12 },
  { left: '14%', delay: 0.9, dur: 6.2, dx: '-22px', spin: '-160deg', color: '#007AFF', w: 6,  h: 6, round: true },
  { left: '23%', delay: 0.3, dur: 5.8, dx: '26px',  spin: '140deg', color: '#FF9500', w: 8,  h: 11 },
  { left: '31%', delay: 1.6, dur: 6.6, dx: '-14px', spin: '190deg', color: '#5856D6', w: 5,  h: 9 },
  { left: '41%', delay: 0.6, dur: 5.2, dx: '20px',  spin: '-220deg', color: '#f472b6', w: 7,  h: 7, round: true },
  { left: '49%', delay: 2.1, dur: 6.0, dx: '-26px', spin: '150deg', color: '#007AFF', w: 6,  h: 12 },
  { left: '57%', delay: 0.2, dur: 6.4, dx: '16px',  spin: '-180deg', color: '#FF9500', w: 6,  h: 6, round: true },
  { left: '65%', delay: 1.2, dur: 5.6, dx: '-18px', spin: '200deg', color: '#5856D6', w: 8,  h: 11 },
  { left: '74%', delay: 0.5, dur: 6.8, dx: '24px',  spin: '-140deg', color: '#f472b6', w: 5,  h: 10 },
  { left: '82%', delay: 1.8, dur: 5.9, dx: '-20px', spin: '170deg', color: '#007AFF', w: 7,  h: 7, round: true },
  { left: '90%', delay: 0.8, dur: 6.3, dx: '14px',  spin: '-200deg', color: '#FF9500', w: 6,  h: 11 },
  { left: '96%', delay: 2.4, dur: 5.5, dx: '-24px', spin: '160deg', color: '#5856D6', w: 5,  h: 9 },
];

const firstName = (name) => (name || '').trim().split(/\s+/)[0] || 'there';

// Employees are identified by what they do, students by what they study.
const subtitleOf = (p) =>
  p.type === 'student' ? (p.course || 'Student') : (p.job_role || p.department || 'Team');

const initialOf = (name) => (name || '?').trim().charAt(0).toUpperCase();

// "Asha", "Asha & Ravi", "Asha, Ravi & Neel", then "Asha, Ravi & 3 others".
function greetingNames(people) {
  const names = people.map((p) => firstName(p.name));
  if (names.length === 1) return names[0];
  if (names.length <= 3) return `${names.slice(0, -1).join(', ')} & ${names[names.length - 1]}`;
  return `${names.slice(0, 2).join(', ')} & ${names.length - 2} others`;
}

/**
 * Birthday celebration overlay. Renders NOTHING (no wrapper, no portal) when
 * nobody has a birthday today — the caller can mount it unconditionally.
 *
 * Portaled to document.body on purpose: .glass-card / .glass-stat carry
 * `contain: layout paint`, which makes them a containing block for position:fixed
 * children and would clip this overlay if it rendered inside the page tree.
 *
 * No "Wish them" button: the only reusable send mechanism here is the wa.me link
 * pattern from leads, and that needs a phone number. /api/birthdays/today is open
 * to every authenticated user, so putting personal numbers in it would leak
 * contact details to people who cannot open the directory. Omitted rather than
 * half-built.
 */
export default function BirthdayPopup({ people, onClose }) {
  const cardRef = useRef(null);
  const list = Array.isArray(people) ? people : [];
  const hasBirthdays = list.length > 0;

  // onClose is an inline arrow from App, so its identity changes on every render
  // (the leads poll re-renders App every 60s). Keeping it in a ref lets the effect
  // below depend only on hasBirthdays — otherwise it would re-bind the listener
  // and re-steal focus on each of those renders.
  const onCloseRef = useRef(onClose);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);

  useEffect(() => {
    if (!hasBirthdays) return;
    const onKey = (e) => { if (e.key === 'Escape') onCloseRef.current(); };
    window.addEventListener('keydown', onKey);
    // Move focus to the dialog itself, not the × — a screen reader lands on the
    // greeting, and the first thing a sighted user sees isn't a focus ring.
    cardRef.current?.focus();
    return () => window.removeEventListener('keydown', onKey);
  }, [hasBirthdays]);

  if (!hasBirthdays) return null;

  const single = list.length === 1;

  return createPortal(
    <div
      className="fixed inset-0 glass-overlay flex items-center justify-center p-4 z-50 overflow-y-auto overflow-x-hidden"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-labelledby="birthday-greeting"
    >
      <div className="bd-confetti" aria-hidden="true">
        {CONFETTI.map((c, i) => (
          <i
            key={i}
            style={{
              left: c.left,
              width: `${c.w}px`,
              height: `${c.h}px`,
              background: c.color,
              borderRadius: c.round ? '50%' : '2px',
              animationDelay: `${c.delay}s`,
              animationDuration: `${c.dur}s`,
              '--dx': c.dx,
              '--spin': c.spin,
            }}
          />
        ))}
      </div>

      <div
        ref={cardRef}
        tabIndex={-1}
        className="glass-strong bd-card relative z-10 w-full max-w-sm p-6 sm:p-7 my-8"
        // Inline, because the app's global :focus-visible ring would otherwise
        // outline the whole card. The card is a focus target for screen readers,
        // not something you interact with; the × keeps its ring.
        style={{ outline: 'none' }}
        onClick={(e) => e.stopPropagation()}
      >
        <button
          onClick={onClose}
          aria-label="Dismiss"
          className="absolute top-3 right-3 w-8 h-8 rounded-full flex items-center justify-center text-glass-muted hover:text-glass-primary text-xl leading-none"
        >
          ×
        </button>

        <div className="text-[11px] font-semibold uppercase tracking-[0.14em] text-glass-muted mb-5">
          {single ? 'Birthday today' : `${list.length} birthdays today`}
        </div>

        {single ? (
          <div className="text-center">
            <div
              className="w-20 h-20 mx-auto rounded-full flex items-center justify-center text-3xl font-bold text-white"
              style={{ background: '#5856D6', boxShadow: '0 4px 12px rgba(99,102,241,0.30)' }}
            >
              {initialOf(list[0].name)}
            </div>
            <h2 className="mt-4 text-2xl font-bold text-glass-primary break-words">{list[0].name}</h2>
            <p className="mt-1 text-sm text-glass-secondary break-words">{subtitleOf(list[0])}</p>
            <p id="birthday-greeting" className="mt-5 text-base font-medium text-glass-primary break-words">
              Happy Birthday, {firstName(list[0].name)}!
            </p>
          </div>
        ) : (
          <>
            <h2 id="birthday-greeting" className="text-xl font-bold text-glass-primary break-words">
              Happy Birthday, {greetingNames(list)}!
            </h2>
            <ul className="mt-4 divide-y" style={{ borderColor: 'var(--border-subtle)' }}>
              {list.map((p) => (
                <li key={`${p.type}-${p.id}`} className="flex items-center gap-3 py-3">
                  <div
                    className="w-11 h-11 shrink-0 rounded-full flex items-center justify-center font-semibold text-white"
                    style={{ background: '#5856D6', boxShadow: '0 3px 10px rgba(99,102,241,0.25)' }}
                  >
                    {initialOf(p.name)}
                  </div>
                  <div className="min-w-0">
                    <div className="font-medium text-glass-primary truncate">{p.name}</div>
                    <div className="text-sm text-glass-secondary truncate">{subtitleOf(p)}</div>
                  </div>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    </div>,
    document.body
  );
}
