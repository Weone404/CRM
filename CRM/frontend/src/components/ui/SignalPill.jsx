import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { subscribe, getStatus, checkNow } from '../../utils/netStatus';

const TONE = {
  good: { fg: '#1E7B34', bg: 'rgba(30,123,52,0.10)' },
  warn: { fg: '#8A5300', bg: 'rgba(178,106,0,0.12)' },
  bad: { fg: '#A42219', bg: 'rgba(192,39,29,0.10)' },
};

function Bars({ level, color }) {
  return (
    <svg width="16" height="14" viewBox="0 0 16 14" aria-hidden="true" style={{ flexShrink: 0 }}>
      {[0, 1, 2].map((i) => (
        <rect key={i} x={i * 5.5} y={10 - i * 4} width="4" height={4 + i * 4} rx="1"
          fill={i < level ? color : 'rgba(60,60,67,0.22)'} />
      ))}
    </svg>
  );
}

const ago = (t) => {
  if (!t) return 'not yet';
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 10) return 'just now';
  if (s < 60) return `${s} s ago`;
  const m = Math.round(s / 60);
  return m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`;
};

// The signal indicator in the top bar: internet and CRM-server health at a glance; tap for details.
export default function SignalPill() {
  const st = useSyncExternalStore(subscribe, getStatus);
  const [open, setOpen] = useState(false);
  const [checking, setChecking] = useState(false);
  const [, tick] = useState(0);
  const box = useRef(null);
  const tone = TONE[st.tone] || TONE.good;

  useEffect(() => {
    if (!open) return undefined;
    const t = setInterval(() => tick((n) => n + 1), 5000);
    const away = (e) => { if (box.current && !box.current.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', away);
    document.addEventListener('keydown', esc);
    return () => { clearInterval(t); document.removeEventListener('mousedown', away); document.removeEventListener('keydown', esc); };
  }, [open]);

  const internet = !st.online || st.internet === 'down'
    ? 'Offline'
    : `Online${st.effectiveType ? ` · ${st.effectiveType.toUpperCase()}` : ''}${st.downlink ? ` · about ${st.downlink} Mbps` : ''}`;
  const server = st.label === 'CRM not responding' ? 'Not responding' : st.ms != null ? `${st.ms < 1000 ? `${st.ms} ms` : `${(st.ms / 1000).toFixed(1)} s`}` : 'Checking…';

  return (
    <div ref={box} className="relative">
      <button type="button" onClick={() => setOpen((v) => !v)} aria-expanded={open} aria-haspopup="dialog"
        aria-label={`Connection: ${st.label}`} title={st.detail}
        className="inline-flex items-center gap-1.5 rounded-full px-2.5 min-h-[32px] text-[13px] font-medium"
        style={{ color: tone.fg, background: tone.bg }}>
        <Bars level={st.level} color={tone.fg} />
        <span className={st.tone === 'good' ? 'hidden sm:inline' : ''}>{st.label}</span>
      </button>
      {open && (
        <div role="dialog" aria-label="Connection details"
          className="absolute right-0 mt-2 w-[290px] max-w-[90vw] glass-strong p-4 z-50 text-sm animate-glass-in">
          <p className="m-0 mb-3 text-glass-primary">{st.detail}</p>
          <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5">
            <dt className="text-glass-secondary">Your internet</dt><dd className="m-0 text-right text-glass-primary">{internet}</dd>
            <dt className="text-glass-secondary">CRM server</dt><dd className="m-0 text-right text-glass-primary">{server}</dd>
            <dt className="text-glass-secondary">Last refresh</dt><dd className="m-0 text-right text-glass-primary">{ago(st.lastSyncAt || st.lastOkAt)}</dd>
            {st.inFlight > 0 && (<><dt className="text-glass-secondary">Loading now</dt><dd className="m-0 text-right text-glass-primary">{st.inFlight}</dd></>)}
          </dl>
          <button type="button" disabled={checking}
            onClick={async () => { setChecking(true); try { await checkNow(); } finally { setChecking(false); } }}
            className="glass-btn-ghost w-full mt-3 min-h-[38px] text-sm">{checking ? 'Checking…' : 'Check again'}</button>
        </div>
      )}
    </div>
  );
}
