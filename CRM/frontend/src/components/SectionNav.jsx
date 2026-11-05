import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import Icon from './icons';

// Section picker for a page with many sections (FlightBridge AI).
// Sections are grouped (e.g. Find schools / Outreach / Results / Setup).
//   Phones: one large button shows where you are; tapping it opens a sheet with every section, grouped, with icons,
//           a one-line description and counts. One tap to go anywhere, nothing hidden in a scroll strip.
//   Tablet and desktop: the groups sit side by side as capsule rows that wrap, so every section is always visible.
// groups: [{ label, items: [{ id, label, hint, icon, count }] }]
export default function SectionNav({ groups, value, onChange }) {
  const [open, setOpen] = useState(false);
  const all = groups.flatMap((g) => g.items.map((it) => ({ ...it, group: g.label })));
  const cur = all.find((it) => it.id === value) || all[0];

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') setOpen(false); };
    window.addEventListener('keydown', onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { window.removeEventListener('keydown', onKey); document.body.style.overflow = prev; };
  }, [open]);

  const pick = (id) => { onChange(id); setOpen(false); };
  const Count = ({ n, active }) => (n > 0 ? (
    <span className="min-w-[1.4rem] h-[1.4rem] px-1.5 rounded-full text-[11px] font-bold inline-flex items-center justify-center"
      style={{ background: active ? 'rgba(255,255,255,0.9)' : '#FF3B30', color: active ? '#007AFF' : '#fff' }}>{n > 99 ? '99+' : n}</span>
  ) : null);

  return (
    <>
      {/* phones */}
      <button type="button" onClick={() => setOpen(true)} aria-haspopup="dialog" aria-expanded={open}
        className="sm:hidden glass-card w-full flex items-center gap-3 px-4 py-3 text-left min-h-[60px]">
        <span className="h-10 w-10 rounded-[12px] inline-flex items-center justify-center text-white shrink-0"
          style={{ background: 'linear-gradient(160deg, #3D9BFF, #007AFF)' }}><Icon name={cur.icon} size={20} /></span>
        <span className="min-w-0 flex-1">
          <span className="block text-[11px] font-semibold uppercase tracking-wider text-glass-secondary">{cur.group}</span>
          <span className="block text-base font-semibold text-glass-primary truncate">{cur.label}</span>
        </span>
        <span className="text-sm font-medium inline-flex items-center gap-1 shrink-0" style={{ color: '#007AFF' }}>All sections<Icon name="chevronDown" size={16} /></span>
      </button>

      {open && createPortal(
        <div className="fixed inset-0 z-50 glass-overlay flex items-end sm:hidden" onClick={() => setOpen(false)}>
          <div className="w-full glass-strong rounded-b-none max-h-[85vh] overflow-y-auto animate-glass-in" role="dialog" aria-label="Page sections"
            style={{ paddingBottom: 'calc(1rem + env(safe-area-inset-bottom))' }} onClick={(e) => e.stopPropagation()}>
            <div className="sticky top-0 z-10 flex items-center justify-between px-4 pt-3 pb-2" style={{ background: 'inherit' }}>
              <span className="mx-auto h-1.5 w-10 rounded-full absolute left-1/2 -translate-x-1/2 top-1.5" style={{ background: 'rgba(60,60,67,0.3)' }} aria-hidden="true" />
              <h3 className="text-lg font-bold text-glass-primary mt-2">Sections</h3>
              <button onClick={() => setOpen(false)} className="mt-2 h-9 w-9 rounded-full inline-flex items-center justify-center text-glass-secondary"
                style={{ background: 'rgba(118,118,128,0.12)' }} aria-label="Close"><Icon name="close" size={18} /></button>
            </div>
            <div className="px-4 space-y-4 pb-2">
              {groups.map((g) => (
                <div key={g.label}>
                  <div className="text-[12px] font-semibold uppercase tracking-wider text-glass-secondary px-1 mb-1.5">{g.label}</div>
                  <div className="rounded-2xl overflow-hidden" style={{ background: 'rgba(255,255,255,0.75)' }}>
                    {g.items.map((it, i) => {
                      const active = it.id === value;
                      return (
                        <button key={it.id} onClick={() => pick(it.id)} aria-current={active ? 'page' : undefined}
                          className="w-full flex items-center gap-3 px-3 py-2.5 text-left min-h-[56px]"
                          style={{ borderTop: i ? '1px solid rgba(60,60,67,0.12)' : 'none' }}>
                          <span className="h-8 w-8 rounded-[9px] inline-flex items-center justify-center shrink-0"
                            style={{ background: active ? '#007AFF' : 'rgba(0,122,255,0.12)', color: active ? '#fff' : '#007AFF' }}><Icon name={it.icon} size={17} /></span>
                          <span className="min-w-0 flex-1">
                            <span className={`block text-[15px] ${active ? 'font-semibold' : 'font-medium'} text-glass-primary`}>{it.label}</span>
                            {it.hint && <span className="block text-xs text-glass-secondary truncate">{it.hint}</span>}
                          </span>
                          <Count n={it.count} />
                          {active && <span style={{ color: '#007AFF' }}><Icon name="check" size={18} strokeWidth={2.5} /></span>}
                        </button>
                      );
                    })}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>,
        document.body,
      )}

      {/* tablet and desktop */}
      <nav className="hidden sm:flex flex-wrap gap-x-5 gap-y-3" aria-label="Page sections">
        {groups.map((g) => (
          <div key={g.label} className="min-w-0">
            <div className="text-[11px] font-semibold uppercase tracking-wider text-glass-secondary px-1 mb-1">{g.label}</div>
            <div className="inline-flex flex-wrap gap-1 p-1 rounded-full" style={{ background: 'rgba(118,118,128,0.12)' }} role="tablist">
              {g.items.map((it) => {
                const active = it.id === value;
                return (
                  <button key={it.id} role="tab" aria-selected={active} onClick={() => onChange(it.id)} title={it.hint}
                    className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm whitespace-nowrap transition ${active ? 'font-semibold' : 'font-medium text-glass-secondary hover:text-glass-primary'}`}
                    style={active ? { background: '#fff', color: '#007AFF', boxShadow: '0 3px 8px rgba(0,0,0,0.12), 0 3px 1px rgba(0,0,0,0.04)' } : undefined}>
                    <Icon name={it.icon} size={15} />{it.label}<Count n={it.count} active={false} />
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </nav>
    </>
  );
}
