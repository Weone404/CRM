import { useLayoutEffect, useRef, useState } from 'react';
import Icon from '../icons';

// A row of tabs that shows every tab that fits the width and puts only the rest behind a "⋯" button.
// Widths are measured from an invisible copy of the row, so labels, icons and badges of any length fit exactly.
// items: [{ id, label }]; renderItem(item, active) returns the inside of a tab button.
export default function OverflowNav({ items, activeId, onSelect, renderItem, itemClass, dotsClass, ariaLabel, className = '' }) {
  const wrap = useRef(null);
  const meas = useRef(null);
  const [count, setCount] = useState(items.length);
  const [open, setOpen] = useState(false);
  const key = items.map((i) => `${i.id}:${i.label}:${i.badge || ''}`).join('|');

  useLayoutEffect(() => {
    const el = wrap.current, m = meas.current;
    if (!el || !m) return undefined;
    const outer = (n) => { const cs = getComputedStyle(n); return n.getBoundingClientRect().width + parseFloat(cs.marginLeft) + parseFloat(cs.marginRight); };
    const fit = () => {
      const kids = [...m.children];
      const dots = outer(kids[kids.length - 1]);
      const widths = kids.slice(0, -1).map(outer);
      const avail = el.clientWidth - 2;
      const total = widths.reduce((a, b) => a + b, 0);
      if (total <= avail) { setCount(widths.length); return; }
      let used = dots, k = 0;
      while (k < widths.length && used + widths[k] <= avail) { used += widths[k]; k++; }
      setCount(k);
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    document.fonts?.ready?.then(fit).catch(() => {});
    return () => ro.disconnect();
  }, [key]);

  const shown = items.slice(0, count);
  const rest = items.slice(count);
  const restActive = rest.some((i) => i.id === activeId);
  const pick = (id) => { setOpen(false); onSelect(id); };
  const Dots = ({ active, ...p }) => (
    <button type="button" aria-label="More" title="More" className={dotsClass(active)} {...p}><Icon name="more" size={18} strokeWidth={2.4} /></button>
  );
  return (
    <div ref={wrap} className={`relative min-w-0 ${className}`}>
      {/* invisible copy, only for measuring */}
      <div ref={meas} aria-hidden="true" className="absolute left-0 top-0 flex whitespace-nowrap invisible pointer-events-none" style={{ width: 'max-content' }}>
        {items.map((i) => <span key={i.id} className={itemClass(true)}>{renderItem(i, true)}</span>)}
        <span className={dotsClass(false)}><Icon name="more" size={18} strokeWidth={2.4} /></span>
      </div>
      <div role="tablist" aria-label={ariaLabel} className="flex items-center whitespace-nowrap">
        {shown.map((i) => (
          <button key={i.id} type="button" role="tab" aria-selected={activeId === i.id} aria-label={i.badge ? `${i.label} ${i.badge}` : i.label} onClick={() => pick(i.id)} className={itemClass(activeId === i.id)}>
            {renderItem(i, activeId === i.id)}
          </button>
        ))}
        {rest.length > 0 && (
          <div className="relative">
            <Dots active={restActive || open} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((v) => !v)} />
            {open && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} aria-hidden="true" />
                <div role="menu" aria-label="More" className="absolute right-0 top-full mt-1.5 z-50 min-w-[220px] more-menu p-1.5 animate-glass-in"
                  onKeyDown={(e) => { if (e.key === 'Escape') setOpen(false); }}>
                  {rest.map((i) => (
                    <button key={i.id} type="button" role="menuitem" aria-label={i.badge ? `${i.label} ${i.badge}` : i.label} onClick={() => pick(i.id)}
                      className={`menu-item w-full flex items-center gap-3 px-3 min-h-[42px] rounded-xl text-sm text-left ${activeId === i.id ? 'is-active' : ''}`}>
                      {renderItem(i, activeId === i.id)}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
