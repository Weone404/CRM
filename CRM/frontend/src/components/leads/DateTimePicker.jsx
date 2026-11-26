// A friendly date (and optional time) picker: one-tap shortcuts, a month calendar, and common times as chips.
// value: { date: 'YYYY-MM-DD', time: 'HH:MM' | '' }
import { useMemo, useState } from 'react';
import { addDays, nextMonday, today, timeLabel, ymd } from '../../utils/leadPlan';

const WEEK = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const TIMES = ['10:00', '11:00', '12:00', '14:00', '16:00', '18:00'];
const MONTH = new Intl.DateTimeFormat('en-IN', { month: 'long', year: 'numeric' });

const Chev = ({ left }) => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d={left ? 'M15 6l-6 6 6 6' : 'M9 6l6 6-6 6'} />
  </svg>
);

export function Chip({ on, onClick, children, tone = '#007AFF', className = '', ...rest }) {
  return (
    <button type="button" onClick={onClick} aria-pressed={on}
      className={`lp-chip ${on ? 'lp-chip-on' : ''} ${className}`} style={on ? { background: tone, borderColor: tone } : undefined} {...rest}>
      {children}
    </button>
  );
}

export default function DateTimePicker({ value, onChange, shortcuts = true, allowPast = false, label = 'Date' }) {
  const t = today();
  const sel = value?.date || '';
  const [view, setView] = useState(() => { const d = new Date(`${sel || t}T12:00:00`); return { y: d.getFullYear(), m: d.getMonth() }; });
  const [customTime, setCustomTime] = useState(Boolean(value?.time && !TIMES.includes(value.time)));

  const cells = useMemo(() => {
    const first = new Date(view.y, view.m, 1);
    const lead = (first.getDay() + 6) % 7;                    // Monday first
    const days = new Date(view.y, view.m + 1, 0).getDate();
    const out = Array.from({ length: lead }, () => null);
    for (let d = 1; d <= days; d++) out.push(ymd(new Date(view.y, view.m, d)));
    return out;
  }, [view]);
  const move = (k) => setView((v) => { const d = new Date(v.y, v.m + k, 1); return { y: d.getFullYear(), m: d.getMonth() }; });
  const pick = (date) => { onChange({ date, time: value?.time || '' }); const d = new Date(`${date}T12:00:00`); setView({ y: d.getFullYear(), m: d.getMonth() }); };
  const setTime = (time) => onChange({ date: sel || t, time });

  const quick = [['Tomorrow', addDays(t, 1)], ['In 3 days', addDays(t, 3)], ['Next week', nextMonday()]];
  // the calendar stays folded until it is needed: shortcuts cover most calls
  const [cal, setCal] = useState(() => !shortcuts || Boolean(sel && !quick.some(([, d]) => d === sel)));
  const canPrev = allowPast || new Date(view.y, view.m, 1) > new Date(new Date().getFullYear(), new Date().getMonth(), 1);

  return (
    <div className="space-y-3">
      {shortcuts && (
        <div className="flex flex-wrap gap-2" role="group" aria-label="Quick dates">
          {quick.map(([l, d]) => <Chip key={l} on={sel === d && !cal} onClick={() => { setCal(false); pick(d); }}>{l}</Chip>)}
          <Chip on={cal} onClick={() => setCal(!cal)} aria-expanded={cal}>{cal ? 'Hide calendar' : 'Pick a date…'}</Chip>
        </div>
      )}
      {cal && <div className="lp-cal lp-reveal" role="group" aria-label={label}>
        <div className="flex items-center justify-between mb-1.5">
          <button type="button" className="lp-iconbtn" onClick={() => move(-1)} disabled={!canPrev} aria-label="Previous month"><Chev left /></button>
          <div className="text-[14px] font-semibold text-glass-primary">{MONTH.format(new Date(view.y, view.m, 1))}</div>
          <button type="button" className="lp-iconbtn" onClick={() => move(1)} aria-label="Next month"><Chev /></button>
        </div>
        <div className="grid grid-cols-7 text-center text-[11px] font-medium text-glass-muted mb-1">{WEEK.map((w) => <div key={w}>{w}</div>)}</div>
        <div className="grid grid-cols-7 gap-y-1">
          {cells.map((d, i) => {
            if (!d) return <div key={`e${i}`} />;
            const past = !allowPast && d < t;
            const on = d === sel;
            return (
              <button key={d} type="button" disabled={past} onClick={() => pick(d)} aria-pressed={on} aria-label={d}
                className={`lp-day ${on ? 'lp-day-on' : ''} ${d === t ? 'lp-day-today' : ''}`}>
                {Number(d.slice(8))}
              </button>
            );
          })}
        </div>
      </div>}
      {sel && <div className="lp-reveal">
        <div className="flex items-center justify-between mb-1.5">
          <span className="text-[12px] font-medium text-glass-secondary">Time <span className="text-glass-muted font-normal">(optional)</span></span>
          {value?.time && <button type="button" className="text-[12px] font-semibold" style={{ color: '#007AFF' }} onClick={() => { setCustomTime(false); setTime(''); }}>No time</button>}
        </div>
        <div className="flex flex-wrap gap-2">
          {TIMES.map((x) => <Chip key={x} on={value?.time === x && !customTime} onClick={() => { setCustomTime(false); setTime(x); }}>{timeLabel(x)}</Chip>)}
          <Chip on={customTime} onClick={() => setCustomTime(true)}>Other…</Chip>
        </div>
        {customTime && (
          <input type="time" className="glass-input mt-2 px-3 py-2 rounded-xl text-[15px]" value={value?.time || ''} aria-label="Exact time"
            onChange={(e) => setTime(e.target.value)} autoFocus />
        )}
      </div>}
    </div>
  );
}
