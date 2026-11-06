// iOS-style controls: Segmented (sliding thumb), Stepper (− value +), Switch (spring thumb).
import { useEffect, useRef, useState } from 'react';

export function Segmented({ options, value, onChange, disabled, label }) {
  const i = Math.max(0, options.findIndex((o) => (o.value ?? o) === value));
  const onKey = (e) => {
    const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
    if (!d) return;
    e.preventDefault();
    const n = Math.min(options.length - 1, Math.max(0, i + d));
    onChange(options[n].value ?? options[n]);
  };
  return (
    <div className="apple-seg" role="radiogroup" aria-label={label} onKeyDown={onKey}>
      <span className="apple-seg-thumb" aria-hidden="true"
        style={{ width: `calc((100% - 4px) / ${options.length})`, transform: `translateX(${i * 100}%)` }} />
      {options.map((o, k) => {
        const v = o.value ?? o;
        return (
          <button key={String(v)} type="button" role="radio" aria-checked={k === i} tabIndex={k === i ? 0 : -1}
            disabled={disabled} onClick={() => onChange(v)}>{o.label ?? String(v)}</button>
        );
      })}
    </div>
  );
}

export function Stepper({ value, min, max, onChange, disabled, label, step = 1 }) {
  const [bump, setBump] = useState(0);
  const prev = useRef(value);
  useEffect(() => { if (prev.current !== value) { setBump((b) => b + 1); prev.current = value; } }, [value]);
  return (
    <div className="apple-stepper" role="group" aria-label={label}>
      <button type="button" aria-label={`${label}: fewer`} disabled={disabled || value <= min} onClick={() => onChange(Math.max(min, value - step))}>−</button>
      <span key={bump} className={bump ? 'bump' : ''} aria-live="polite">{value}</span>
      <button type="button" aria-label={`${label}: more`} disabled={disabled || value >= max} onClick={() => onChange(Math.min(max, value + step))}>+</button>
    </div>
  );
}

export function Switch({ on, disabled, onChange, label, size = 'lg' }) {
  const w = size === 'lg' ? 64 : 51;
  const h = size === 'lg' ? 36 : 31;
  const t = h - 6;
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} onClick={() => onChange(!on)}
      className="relative inline-flex items-center rounded-full shrink-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style={{ width: w, height: h, background: on ? '#34C759' : 'rgba(120,120,128,0.32)', opacity: disabled ? 0.5 : 1,
        outlineColor: '#007AFF', transition: 'background .25s cubic-bezier(.25,.8,.25,1)' }}>
      <span className="absolute rounded-full bg-white apple-switch-thumb"
        style={{ width: t, height: t, left: 3, top: 3, transform: on ? `translateX(${w - t - 6}px)` : 'none',
          boxShadow: '0 3px 8px rgba(0,0,0,0.15), 0 1px 1px rgba(0,0,0,0.16)' }} />
    </button>
  );
}
