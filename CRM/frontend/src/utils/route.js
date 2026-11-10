// App-wide links. Every place in the CRM has an address: #/<tab>/<section>?key=value
//   #/partnerships/pipeline?stage=sent      FlightBridge AI > Pipeline > Sent
//   #/leads?filter=pending                  Leads > Pending
// So any number or card can link straight to the list behind it, the browser's Back/Forward buttons work,
// a refresh keeps you where you were, and a copied link opens the same view for a colleague.
import { useEffect, useState } from 'react';

export function parseHash(h = typeof window !== 'undefined' ? window.location.hash : '') {
  const [path, qs = ''] = String(h || '').replace(/^#\/?/, '').split('?');
  const [tab = '', section = ''] = path.split('/').map((s) => { try { return decodeURIComponent(s); } catch { return s; } });
  return { tab, section, params: Object.fromEntries(new URLSearchParams(qs)) };
}

const clean = (params) => Object.entries(params || {}).filter(([, v]) => v !== undefined && v !== null && v !== '');

export function href(tab, section, params) {
  let h = `#/${encodeURIComponent(tab || '')}`;
  if (section) h += `/${encodeURIComponent(section)}`;
  const qs = new URLSearchParams(clean(params)).toString();
  return qs ? `${h}?${qs}` : h;
}

const fire = () => window.dispatchEvent(new HashChangeEvent('hashchange'));

// Go somewhere. A new history entry (so Back returns), and the page scrolls to the top.
// replace: change the address in place (filters, search text) without adding a Back step.
export function navigate(tab, section, params, { replace = false, scroll = !replace } = {}) {
  const h = href(tab, section, params);
  if (window.location.hash !== h) {
    if (replace) { window.history.replaceState(window.history.state, '', h); fire(); }
    else window.location.hash = h;
  }
  if (scroll) window.scrollTo({ top: 0, behavior: 'smooth' });
}

// Change only some filters of the current place, in place.
export function setParams(patch) {
  const r = parseHash();
  navigate(r.tab, r.section, { ...r.params, ...patch }, { replace: true });
}

export function useRoute() {
  const [r, setR] = useState(() => parseHash());
  useEffect(() => {
    const on = () => setR(parseHash());
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return r;
}
