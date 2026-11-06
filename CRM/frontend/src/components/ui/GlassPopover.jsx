// Liquid Glass popover (iOS 26 / macOS Tahoe style): it grows out of the control that opened it ("morph"), floats on
// a translucent, refractive glass layer with a specular edge, and folds back into it when closed.
// Closes on Esc or a tap outside. Use morphFrom() for any floating panel that should open the same way.
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

const reduced = () => typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

// Animate `el` from the rectangle of `from` (the trigger) to its own place, like Apple's control-to-menu morph.
export function morphFrom(from, el, { reverse = false, duration = 420 } = {}) {
  if (!from || !el || reduced() || !el.animate) return null;
  const a = from.getBoundingClientRect();
  const b = el.getBoundingClientRect();
  if (!b.width || !b.height) return null;
  const sx = Math.max(0.05, a.width / b.width);
  const sy = Math.max(0.05, a.height / b.height);
  const dx = a.left + a.width / 2 - (b.left + b.width / 2);
  const dy = a.top + a.height / 2 - (b.top + b.height / 2);
  const start = { transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`, opacity: 0.4, filter: 'blur(2px)' };
  const end = { transform: 'none', opacity: 1, filter: 'blur(0)' };
  return el.animate(reverse ? [end, start] : [start, end], {
    duration: reverse ? 240 : duration, easing: reverse ? 'cubic-bezier(.4,0,.6,1)' : 'cubic-bezier(.28,1.22,.5,1)', fill: 'both',
  });
}

// macOS "genie": the panel pours out of the control - narrow where it meets the control, widening as it falls open -
// and is sucked back into it when it closes. Works for panels opening below or above the control.
export function genie(from, el, { reverse = false, duration = 540 } = {}) {
  if (!from || !el || reduced() || !el.animate) return null;
  const a = from.getBoundingClientRect();
  const b = el.getBoundingClientRect();
  if (!b.width || !b.height) return null;
  const pct = (x) => Math.max(0, Math.min(100, ((x - b.left) / b.width) * 100)).toFixed(2);
  const l = pct(a.left), r = pct(a.right);
  const up = b.bottom <= a.top + 2;                       // panel above its control
  const near = up ? 100 : 0, far = up ? 0 : 100;
  const poly = (tl, tr, br, bl) => `polygon(${tl}, ${tr}, ${br}, ${bl})`;
  const P = (x, y) => `${x}% ${y}%`;
  const mid = up ? 70 : 30;
  const frames = [
    { clipPath: poly(P(l, near), P(r, near), P(r, near), P(l, near)), transform: 'scaleY(0.12)', opacity: 0.35, offset: 0 },
    { clipPath: up ? poly(P(0, far), P(100, far), P(r, near), P(l, near)) : poly(P(l, near), P(r, near), P(100, mid + 30), P(0, mid + 30)),
      transform: 'scaleY(0.7)', opacity: 0.92, offset: 0.5 },
    { clipPath: up ? poly(P(0, far), P(100, far), P(100, near), P(0, near)) : poly(P(0, near), P(100, near), P(100, far), P(0, far)),
      transform: 'scaleY(1)', opacity: 1, offset: 1 },
  ];
  if (up) frames[0].clipPath = poly(P(l, near), P(r, near), P(r, near), P(l, near));
  const prevOrigin = el.style.transformOrigin;
  el.style.transformOrigin = `${(Number(l) + Number(r)) / 2}% ${up ? '100%' : '0%'}`;
  const anim = el.animate(reverse ? [...frames].reverse().map((f, i) => ({ ...f, offset: [0, 0.55, 1][i] })) : frames, {
    duration: reverse ? 300 : duration, easing: reverse ? 'cubic-bezier(.55,0,.8,.2)' : 'cubic-bezier(.33,.75,.25,1)',
    fill: reverse ? 'forwards' : 'none',
  });
  anim.addEventListener('finish', () => { if (!reverse) el.style.transformOrigin = prevOrigin; });
  return anim;
}

export default function GlassPopover({ anchor, open, onClose, children, width = 380, label, align = 'end' }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);
  const [closing, setClosing] = useState(false);

  const place = useCallback(() => {
    const r = anchor.current?.getBoundingClientRect();
    if (!r) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    if (vw < 640) {               // iPhone: a floating sheet near the bottom, above the tab bar and the home indicator
      setPos({ left: 8, width: vw - 16, up: true, bottom: 'calc(8px + env(safe-area-inset-bottom))', maxHeight: Math.round(vh * 0.8), sheet: true });
      return;
    }
    const w = Math.min(width, vw - 16);
    let left = align === 'end' ? r.right - w : r.left;
    left = Math.min(Math.max(8, left), vw - w - 8);
    const below = vh - r.bottom - 12;
    const up = below < 320 && r.top > below;
    setPos({ left, width: w, up, top: up ? undefined : r.bottom + 8, bottom: up ? vh - r.top + 8 : undefined,
      maxHeight: Math.max(220, (up ? r.top : below) - 8) });
  }, [anchor, width, align]);

  const close = useCallback(() => {
    if (closing) return;
    const anim = genie(anchor.current, ref.current, { reverse: true });
    if (!anim) { onClose(); return; }
    setClosing(true);
    anim.onfinish = () => { setClosing(false); onClose(); };
  }, [anchor, onClose, closing]);

  useLayoutEffect(() => { if (open) place(); else setPos(null); }, [open, place]);
  useLayoutEffect(() => { if (open && pos && ref.current && !ref.current.dataset.shown) { ref.current.dataset.shown = '1'; genie(anchor.current, ref.current); } }, [open, pos, anchor]);
  useEffect(() => {
    if (!open) return undefined;
    // a drop list opened from inside this panel lives in its own layer: using it must not close the panel
    const away = (e) => { if (!ref.current?.contains(e.target) && !anchor.current?.contains(e.target) && !e.target.closest?.('.apple-menu')) close(); };
    const key = (e) => { if (e.key === 'Escape' && !document.querySelector('.apple-menu')) { e.preventDefault(); e.stopPropagation(); close(); anchor.current?.focus({ preventScroll: true }); } };
    const re = () => place();
    document.addEventListener('mousedown', away, true);
    document.addEventListener('touchstart', away, true);
    window.addEventListener('keydown', key, true);
    window.addEventListener('resize', re);
    window.addEventListener('scroll', re, true);
    return () => {
      document.removeEventListener('mousedown', away, true);
      document.removeEventListener('touchstart', away, true);
      window.removeEventListener('keydown', key, true);
      window.removeEventListener('resize', re);
      window.removeEventListener('scroll', re, true);
    };
  }, [open, close, place, anchor]);

  if (!open || !pos) return null;
  return createPortal(
    <>
    {pos.sheet && <div className="fixed inset-0 fb-fade" style={{ zIndex: 255, background: 'rgba(0,0,0,0.18)' }} aria-hidden="true" />}
    <div ref={ref} role="dialog" aria-label={label} className="liquid-pop"
      style={{ left: pos.left, width: pos.width, top: pos.top, bottom: pos.bottom, maxHeight: pos.maxHeight,
        transformOrigin: pos.up ? 'bottom right' : 'top right', zIndex: pos.sheet ? 260 : undefined }}>
      {typeof children === 'function' ? children(close) : children}
    </div>
    </>, document.body);
}
