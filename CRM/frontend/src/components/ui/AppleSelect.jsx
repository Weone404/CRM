// Apple-style pop-up button: drop-in for <select>. Same props and children (<option>), same onChange(e) with
// e.target.value, so a <select> becomes <AppleSelect> by renaming the tag. The menu is a liquid-glass popover with a
// spring opening, a checkmark on the chosen item, macOS-style blue highlight, typeahead and full keyboard control.
// A hidden native <select> keeps form behaviour (required, name, form reset) intact.
import { Children, isValidElement, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { genie } from './GlassPopover';

function flatOptions(children) {
  const out = [];
  const walk = (nodes) => Children.forEach(nodes, (c) => {
    if (!isValidElement(c)) return;
    if (c.type === 'option') {
      const label = Children.toArray(c.props.children).join('');
      out.push({ value: String(c.props.value ?? label), label, disabled: !!c.props.disabled, hint: c.props['data-hint'] });
    } else if (c.props?.children) walk(c.props.children);
  });
  walk(children);
  return out;
}

const Chevrons = () => (
  <svg width="12" height="16" viewBox="0 0 12 16" aria-hidden="true" className="shrink-0 opacity-60">
    <path d="M3 6l3-3 3 3M3 10l3 3 3-3" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);
const Tick = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 6 9 17l-5-5" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" /></svg>
);

export default function AppleSelect({ value, defaultValue, onChange, children, className = '', style, disabled, id, name,
  required, placeholder, 'aria-label': ariaLabel, title, variant, display, menuWidth = 220, ...rest }) {
  const options = useMemo(() => flatOptions(children), [children]);
  const [inner, setInner] = useState(defaultValue ?? options[0]?.value ?? '');
  const current = value !== undefined && value !== null ? String(value) : String(inner);
  const sel = options.find((o) => o.value === current);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const [pos, setPos] = useState(null);
  const btn = useRef(null);
  const menu = useRef(null);
  const typed = useRef({ s: '', t: 0 });
  const uid = useId();

  const closing = useRef(false);
  const shut = useCallback(() => {          // genie back into the button, then unmount
    if (closing.current) return;
    const anim = genie(btn.current, menu.current, { reverse: true });
    if (!anim) { setOpen(false); return; }
    closing.current = true;
    anim.onfinish = () => { closing.current = false; setOpen(false); };
  }, []);

  const choose = useCallback((o) => {
    if (!o || o.disabled) return;
    shut();
    btn.current?.focus({ preventScroll: true });
    if (o.value === current) return;
    if (value === undefined) setInner(o.value);
    // let a form window know it was edited (modalProps' "Discard changes?" guard listens for input events)
    btn.current?.dispatchEvent(new Event('input', { bubbles: true }));
    onChange?.({ target: { value: o.value, name, id }, currentTarget: { value: o.value, name, id }, preventDefault() {}, stopPropagation() {} });
  }, [current, value, onChange, name, id, shut]);

  const place = useCallback(() => {
    const r = btn.current?.getBoundingClientRect();
    if (!r) return;
    if (r.bottom < 0 || r.top > window.innerHeight) { setOpen(false); return; }
    const width = Math.max(r.width, menuWidth);
    const left = Math.min(Math.max(8, r.left), window.innerWidth - width - 8);
    const below = window.innerHeight - r.bottom - 12;
    const above = r.top - 12;
    const want = Math.min(340, options.length * 44 + 12);
    const up = below < Math.min(want, 220) && above > below;
    setPos({ left, width, up, top: up ? undefined : r.bottom + 6, bottom: up ? window.innerHeight - r.top + 6 : undefined,
      maxHeight: Math.max(140, Math.min(340, up ? above : below)) });
  }, [options.length]);

  useLayoutEffect(() => { if (open) place(); else setPos(null); }, [open, place]);
  useLayoutEffect(() => {          // the menu grows out of the button (Liquid Glass morph)
    if (open && pos && menu.current && !menu.current.dataset.shown) { menu.current.dataset.shown = '1'; genie(btn.current, menu.current, { duration: 500 }); }
  }, [open, pos]);
  useEffect(() => {
    if (!open) return undefined;
    const i = options.findIndex((o) => o.value === current);
    setActive(i >= 0 ? i : options.findIndex((o) => !o.disabled));
    const away = (e) => { if (!menu.current?.contains(e.target) && !btn.current?.contains(e.target)) shut(); };
    const re = () => place();
    document.addEventListener('mousedown', away, true);
    document.addEventListener('touchstart', away, true);
    window.addEventListener('resize', re);
    window.addEventListener('scroll', re, true);
    return () => {
      document.removeEventListener('mousedown', away, true);
      document.removeEventListener('touchstart', away, true);
      window.removeEventListener('resize', re);
      window.removeEventListener('scroll', re, true);
    };
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {        // keep the highlighted item in view, smoothly
    if (!open || active < 0) return;
    menu.current?.querySelector(`[data-i="${active}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [active, open]);

  const move = (d) => {
    if (!options.length) return;
    let i = active;
    for (let k = 0; k < options.length; k++) {
      i = (i + d + options.length) % options.length;
      if (!options[i].disabled) break;
    }
    setActive(i);
  };
  const onKey = (e) => {
    if (disabled) return;
    if (!open) {
      if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(e.key)) { e.preventDefault(); setOpen(true); }
      return;
    }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); shut(); return; }
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); return; }
    if (e.key === 'Home') { e.preventDefault(); setActive(options.findIndex((o) => !o.disabled)); return; }
    if (e.key === 'End') { e.preventDefault(); setActive(options.length - 1 - [...options].reverse().findIndex((o) => !o.disabled)); return; }
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(options[active]); return; }
    if (e.key === 'Tab') { setOpen(false); return; }
    if (e.key.length === 1) {            // typeahead
      const now = Date.now();
      typed.current = { s: (now - typed.current.t < 700 ? typed.current.s : '') + e.key.toLowerCase(), t: now };
      const i = options.findIndex((o) => !o.disabled && o.label.toLowerCase().startsWith(typed.current.s));
      if (i >= 0) setActive(i);
    }
  };

  return (
    <>
      <button ref={btn} type="button" id={id} title={title} disabled={disabled} aria-label={ariaLabel}
        aria-haspopup="listbox" aria-expanded={open} aria-controls={open ? `${uid}-menu` : undefined}
        aria-activedescendant={open && active >= 0 ? `${uid}-o${active}` : undefined}
        onClick={() => (open ? shut() : setOpen(true))} onKeyDown={onKey}
        className={`${variant === 'capsule' ? 'glass-capsule' : 'apple-select'} ${className}`} style={style} data-open={open ? '' : undefined} {...rest}>
        <span className={`truncate ${variant === 'capsule' ? '' : 'flex-1'} text-left ${sel ? '' : 'opacity-50'}`}>{display ? display(sel) : (sel?.label ?? placeholder ?? '')}</span>
        <Chevrons />
      </button>
      <select tabIndex={-1} aria-hidden="true" className="sr-only" name={name} required={required} value={current}
        onChange={() => {}} disabled={disabled}>
        {options.map((o) => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
      </select>
      {open && pos && createPortal(
        <div ref={menu} id={`${uid}-menu`} role="listbox" aria-label={ariaLabel} className={`apple-menu ${pos.up ? 'apple-menu-up' : ''}`}
          style={{ left: pos.left, width: pos.width, top: pos.top, bottom: pos.bottom, maxHeight: pos.maxHeight }}
          onMouseDown={(e) => e.preventDefault()}>
          {options.map((o, i) => (
            <div key={`${o.value}-${i}`} id={`${uid}-o${i}`} data-i={i} role="option" aria-selected={o.value === current}
              aria-disabled={o.disabled || undefined} className="apple-menu-item" data-active={i === active ? '' : undefined}
              onMouseEnter={() => !o.disabled && setActive(i)} onClick={() => choose(o)}>
              <span className="apple-menu-tick">{o.value === current && <Tick />}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate">{o.label}</span>
                {o.hint && <span className="block text-[11px] opacity-70 truncate">{o.hint}</span>}
              </span>
            </div>
          ))}
        </div>, document.body)}
    </>
  );
}
