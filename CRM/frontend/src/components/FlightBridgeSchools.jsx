import { useCallback, useEffect, useState } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';
import { countryName } from '../utils/country';
import Icon from './icons';

// FlightBridge schools inside the CRM: Country > State > Area, eligibility sections, full details.
// Same data and API as the standalone FlightBridge app.

async function call(path, opts = {}) {
  const token = localStorage.getItem('token');
  const res = await apiFetch(`/api/flightbridge${path}`, { token, ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

const cname = (c) => countryName(c);
const SECTIONS = [
  ['eligible_verified', 'Eligible', 'bg-green-100 text-green-800', 'Approved by the official register or confirmed by a person.'],
  ['eligible_claimed', 'Check needed', 'bg-yellow-100 text-yellow-800', 'The website claims the approval, or the country has no register yet – confirm it on the regulator’s site.'],
  ['unqualified', 'Unqualified', 'bg-red-100 text-red-800', 'No approval found for this country’s standard, or not a pilot-training school.'],
  ['unknown', 'Not checked yet', 'bg-gray-100 text-gray-700', 'Website not read yet – automation will get to these.'],
];
const SEC = Object.fromEntries(SECTIONS.map(([k, l, c]) => [k, { label: l, cls: c }]));
const PHONE_SRC = { website: 'website', regulator: 'regulator register', google_places: 'Google', human: 'added by a person' };
const CHANNEL = { contact_form: 'Enquiry form', linkedin: 'LinkedIn', facebook: 'Facebook', instagram: 'Instagram', x: 'X', youtube: 'YouTube', whatsapp: 'WhatsApp' };

function Tree({ regions, sel, onSel }) {
  const [open, setOpen] = useState({});
  const t = (k) => setOpen((o) => ({ ...o, [k]: !o[k] }));
  const item = (active) => `w-full text-left px-2 py-1 rounded text-sm flex justify-between gap-2 ${active ? 'bg-blue-50 text-blue-700 font-semibold' : 'hover:bg-gray-50'}`;
  return (
    <div className="text-sm">
      <button className={item(!sel.country)} onClick={() => onSel({})}><span>All schools</span><span className="text-gray-400">{regions.reduce((a, c) => a + c.total, 0)}</span></button>
      {regions.map((c) => (
        <div key={c.country}>
          <div className="flex items-center">
            <button className="w-5 text-gray-400" onClick={() => t(c.country)} aria-label="expand">{open[c.country] ? '▾' : '▸'}</button>
            <button className={item(sel.country === c.country && !sel.region && !sel.area)} onClick={() => { onSel({ country: c.country }); setOpen((o) => ({ ...o, [c.country]: true })); }}>
              <span>{cname(c.country)}</span><span className="text-gray-400">{c.total || ''}</span></button>
          </div>
          {open[c.country] && c.regions.map((r) => {
            const rk = `${c.country}/${r.region}`;
            return (
              <div key={rk} className="ml-4">
                <div className="flex items-center">
                  <button className="w-5 text-gray-400" onClick={() => t(rk)} aria-label="expand">{open[rk] ? '▾' : '▸'}</button>
                  <button className={item(sel.country === c.country && sel.region === (r.region ?? '__none__') && !sel.area)} onClick={() => { onSel({ country: c.country, region: r.region ?? '__none__' }); setOpen((o) => ({ ...o, [rk]: true })); }}>
                    <span>{r.region || 'Region not stated'}</span><span className="text-gray-400">{r.total || ''}</span></button>
                </div>
                {open[rk] && (r.areas || []).map((a) => (
                  <div key={a.id} className="ml-9">
                    <button className={item(String(sel.area) === String(a.id))} onClick={() => onSel({ country: c.country, region: r.region, area: a.id, areaName: a.name, kind: a.kind })}>
                      <span>{a.name}{a.kind === 'demand_hub' ? ' · demand' : ''}</span><span className="text-gray-400">{a.total || ''}</span></button>
                  </div>
                ))}
                {open[rk] && r.unplaced > 0 && (
                  <div className="ml-9"><button className={item(sel.area === 0 && sel.region === r.region)} onClick={() => onSel({ country: c.country, region: r.region, area: 0, areaName: `Elsewhere in ${r.region}` })}>
                    <span className="text-gray-500">Elsewhere in {r.region}</span><span className="text-gray-400">{r.unplaced}</span></button></div>
                )}
              </div>
            );
          })}
        </div>
      ))}
    </div>
  );
}

// School card: opens as a centred window (a bottom sheet on phones) over the list. The verdict comes first (a green
// tick when the official register lists the school), then one-tap contacts, then the evidence; manual decisions are
// at the bottom. Closes with ✕, Esc, or a tap/click outside; ← / → step through the list.
const SIGNAL_LABEL = { has_cpl: 'CPL course', has_ppl: 'PPL course', aeroplane: 'Aeroplanes', helicopter: 'Helicopters', drone: 'Drones',
  accommodation: 'Accommodation', intl_students: 'International students', cricos_on_site: 'CRICOS on site', fleet_published: 'Fleet listed',
  part141: 'Part 141', sevp: 'SEVP / I-20', transport_canada: 'Transport Canada', dli: 'DLI', casa_part14x: 'CASA Part 141/142',
  caa_nz_part141: 'CAA NZ Part 141', nzqa: 'NZQA', ato: 'ATO', dto: 'DTO', airline_pathway: 'Airline pathway', simulator: 'Simulator' };
const VERDICT = {
  eligible_verified: { icon: 'checkCircle', tone: '#248A3D', bg: 'rgba(52,199,89,0.12)', border: 'rgba(52,199,89,0.35)', title: 'Eligible' },
  eligible_claimed: { icon: 'alert', tone: '#B25000', bg: 'rgba(255,149,0,0.12)', border: 'rgba(255,149,0,0.35)', title: 'Check needed' },
  unqualified: { icon: 'xCircle', tone: '#D70015', bg: 'rgba(255,59,48,0.10)', border: 'rgba(255,59,48,0.30)', title: 'Not qualified' },
  unknown: { icon: 'clock', tone: '#636366', bg: 'rgba(142,142,147,0.12)', border: 'rgba(142,142,147,0.30)', title: 'Not checked yet' },
};
const flag = (cc) => (cc && cc.length === 2 ? String.fromCodePoint(...[...cc.toUpperCase()].map((c) => 127397 + c.charCodeAt(0))) : '');

// The school's own logo (its site icon), larger from Google's favicon service, then DuckDuckGo's, else its initial.
const ICON_SOURCES = [(d) => `https://www.google.com/s2/favicons?domain=${encodeURIComponent(d)}&sz=128`,
  (d) => `https://icons.duckduckgo.com/ip3/${encodeURIComponent(d)}.ico`];
function SiteIcon({ domain, name, size = 44 }) {
  const [n, setN] = useState(0);
  useEffect(() => setN(0), [domain]);
  const letter = (name || '?').trim().charAt(0).toUpperCase();
  if (!domain || n >= ICON_SOURCES.length) {
    return <div className="rounded-2xl grid place-items-center font-bold text-white shrink-0" style={{ width: size, height: size, background: 'linear-gradient(135deg,#007AFF,#5856D6)', fontSize: size * 0.42 }} aria-hidden="true">{letter}</div>;
  }
  return <img src={ICON_SOURCES[n](domain)} alt="" width={size} height={size} loading="lazy" referrerPolicy="no-referrer" onError={() => setN((x) => x + 1)}
    className={`shrink-0 bg-white object-contain ${size >= 32 ? 'rounded-2xl' : 'rounded'}`}
    style={{ width: size, height: size, padding: size >= 32 ? 6 : 0, boxShadow: size >= 32 ? '0 0 0 1px rgba(0,0,0,0.08)' : 'none' }} />;
}

function copy(text, what) {
  navigator.clipboard?.writeText(text).then(() => showToast(`${what} copied`, 'success'), () => showToast('Could not copy', 'error'));
}

function Section({ title, children, right }) {
  return (
    <section className="rounded-2xl p-4" style={{ background: 'rgba(255,255,255,0.7)', boxShadow: '0 0 0 1px rgba(0,0,0,0.06)' }}>
      <div className="flex items-center justify-between gap-2 mb-2">
        <h3 className="text-[13px] font-semibold uppercase tracking-wide" style={{ color: 'rgba(60,60,67,0.6)' }}>{title}</h3>{right}
      </div>
      {children}
    </section>
  );
}

function Detail({ id, onChanged, onClose, onPrev, onNext, pos }) {
  const [s, setS] = useState(null);
  const [note, setNote] = useState('');
  const [ref, setRef] = useState('');
  const [src, setSrc] = useState('');
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => call(`/schools/${id}`).then(setS, (e) => showToast(e.message, 'error')), [id]);
  useEffect(() => { setS(null); setNote(''); setRef(''); setSrc(''); setAsking(false); load(); }, [load]);
  const act = async (body, ok) => {
    setBusy(true);
    try { await call(`/schools/${id}/eligibility`, { method: 'POST', body: JSON.stringify(body) }); showToast(ok, 'success'); setAsking(false); load(); onChanged(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const research = async () => {
    try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify({ kind: 'research_school', org_id: id }) }); showToast(r.message, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };

  const nav = (
    <div className="flex items-center gap-1">
      {pos && <span className="text-xs tabular-nums mr-1" style={{ color: 'rgba(60,60,67,0.6)' }}>{pos}</span>}
      <button type="button" className="fb-iconbtn" onClick={onPrev} disabled={!onPrev} aria-label="Previous school" title="Previous (←)"><Icon name="chevronLeft" size={18} /></button>
      <button type="button" className="fb-iconbtn" onClick={onNext} disabled={!onNext} aria-label="Next school" title="Next (→)"><Icon name="chevronRight" size={18} /></button>
      <button type="button" className="fb-iconbtn" onClick={onClose} aria-label="Close" title="Close (Esc)"><Icon name="close" size={18} /></button>
    </div>
  );
  if (!s) {
    return (
      <div className="p-5">
        <div className="flex justify-end">{nav}</div>
        <div className="animate-pulse space-y-3 mt-2">
          <div className="flex gap-3 items-center"><div className="w-14 h-14 rounded-2xl bg-gray-200" /><div className="flex-1 space-y-2"><div className="h-5 bg-gray-200 rounded w-2/3" /><div className="h-3 bg-gray-200 rounded w-1/3" /></div></div>
          <div className="h-20 bg-gray-200 rounded-2xl" /><div className="h-24 bg-gray-200 rounded-2xl" />
        </div>
      </div>
    );
  }
  const v = VERDICT[s.eligibility] || VERDICT.unknown;
  const place = [s.city, s.region, cname(s.country)].filter((x, i, a) => x && a.indexOf(x) === i).join(', ');
  const listed = (s.regulatory || []).filter((r) => r.status === 'listed_in_register' || r.status === 'verified_by_human');
  const reasons = (s.eligibility_reasons || []).filter((r) => r.code !== 'verified');
  const firstEmail = (s.contacts || [])[0]?.email;
  const firstPhone = (s.phones || [])[0];
  const form = (s.channels || []).find((c) => c.kind === 'contact_form');
  const signals = Object.entries(s.profile?.signals || {}).filter(([, val]) => val === true);
  const quick = [
    firstPhone && { icon: 'phone', label: 'Call', href: `tel:${firstPhone.phone}` },
    firstEmail && { icon: 'mail', label: 'Email', href: `mailto:${firstEmail}` },
    s.website_domain && { icon: 'globe', label: 'Website', href: `https://${s.website_domain}`, ext: true },
    form && { icon: 'form', label: 'Enquiry', href: form.url, ext: true },
  ].filter(Boolean);

  return (
    <div className="text-sm">
      {/* header */}
      <div className="sticky top-0 z-10 px-5 pt-4 pb-3" style={{ background: 'rgba(250,250,252,0.86)', backdropFilter: 'blur(20px) saturate(180%)', WebkitBackdropFilter: 'blur(20px) saturate(180%)' }}>
        <div className="sm:hidden mx-auto mb-3 h-1.5 w-10 rounded-full bg-gray-300" aria-hidden="true" />
        <div className="flex items-start gap-3">
          <SiteIcon domain={s.website_domain} name={s.name} size={52} />
          <div className="min-w-0 flex-1">
            <h2 id="fb-school-title" className="text-[19px] font-bold leading-snug" style={{ color: 'rgba(0,0,0,0.9)' }}>{s.name}</h2>
            <div className="flex items-center gap-1 mt-0.5" style={{ color: 'rgba(60,60,67,0.7)' }}>
              <span aria-hidden="true">{flag(s.country)}</span><span className="truncate">{place}</span>
            </div>
            {s.website_domain && (
              <a href={`https://${s.website_domain}`} target="_blank" rel="noreferrer noopener"
                className="inline-flex items-center gap-1.5 mt-1.5 px-2.5 py-1 rounded-full text-[13px] font-medium text-blue-600 hover:bg-blue-50"
                style={{ background: 'rgba(0,122,255,0.08)' }}>
                <SiteIcon domain={s.website_domain} name={s.name} size={16} /><span className="truncate max-w-[220px]">{s.website_domain}</span><Icon name="external" size={13} />
              </a>
            )}
          </div>
          <div className="hidden sm:block">{nav}</div>
        </div>
        <div className="sm:hidden flex justify-end mt-1">{nav}</div>
      </div>

      <div className="px-5 pb-5 space-y-3">
        {/* verdict first */}
        <div className="rounded-2xl p-4" style={{ background: v.bg, boxShadow: `0 0 0 1px ${v.border}` }}>
          <div className="flex items-center gap-2.5">
            <span style={{ color: v.tone }} className="shrink-0"><Icon name={v.icon} size={28} strokeWidth={2.2} title={v.title} /></span>
            <div className="min-w-0">
              <div className="text-[17px] font-bold" style={{ color: v.tone }}>{v.title}</div>
              {s.eligibility_rule && <div className="text-xs" style={{ color: 'rgba(60,60,67,0.7)' }}>Standard: {s.eligibility_rule.credential}</div>}
            </div>
          </div>
          {s.org_kind === 'ground_school' && <div className="text-xs mt-2">Aviation institute in a student-demand hub – not a flying school, so not assessed.</div>}
          {listed.length > 0 && (
            <ul className="mt-3 space-y-1.5">
              {listed.map((r) => (
                <li key={r.id} className="flex items-center gap-2 rounded-xl px-3 py-2 bg-white/80">
                  <span className="grid place-items-center w-5 h-5 rounded-full shrink-0" style={{ background: '#34C759' }}><Icon name="check" size={13} strokeWidth={3} className="text-white" /></span>
                  <span className="min-w-0 flex-1">
                    <span className="font-semibold">{r.status === 'verified_by_human' ? 'Confirmed by a person' : 'Listed in the official register'}</span>
                    <span style={{ color: 'rgba(60,60,67,0.7)' }}> · {r.authority_code.replace('_', ' ')}{r.approval_ref ? ` ${r.approval_ref}` : ''}</span>
                  </span>
                  {r.source_url && <a href={r.source_url} target="_blank" rel="noreferrer noopener" className="text-xs font-medium text-blue-600 inline-flex items-center gap-0.5 shrink-0">Source<Icon name="external" size={12} /></a>}
                </li>
              ))}
            </ul>
          )}
          {reasons.length > 0 && (
            <ul className="mt-2 space-y-1">
              {reasons.map((r, i) => (
                <li key={i} className="text-[13px] leading-snug" style={{ color: 'rgba(0,0,0,0.75)' }}>{r.text}
                  {r.excerpt && <div className="text-xs italic mt-0.5" style={{ color: 'rgba(60,60,67,0.6)' }}>“{r.excerpt}”</div>}
                  {r.source_url && <a className="text-xs text-blue-600 ml-1" href={r.source_url} target="_blank" rel="noreferrer noopener">Source</a>}
                </li>
              ))}
            </ul>
          )}
        </div>

        {/* one-tap contact */}
        {quick.length > 0 && (
          <div className={`grid gap-2 ${quick.length >= 4 ? 'grid-cols-4' : quick.length === 3 ? 'grid-cols-3' : 'grid-cols-2'}`}>
            {quick.map((q) => (
              <a key={q.label} href={q.href} {...(q.ext ? { target: '_blank', rel: 'noreferrer noopener' } : {})}
                className="flex flex-col items-center gap-1 rounded-2xl py-3 text-[12px] font-medium text-blue-600 hover:bg-blue-50 transition"
                style={{ background: 'rgba(255,255,255,0.7)', boxShadow: '0 0 0 1px rgba(0,0,0,0.06)' }}>
                <Icon name={q.icon} size={20} />{q.label}
              </a>
            ))}
          </div>
        )}

        <Section title="Contacts">
          <div className="space-y-1.5">
            {(s.phones || []).map((p) => (
              <div key={p.phone} className="flex items-center gap-2">
                <Icon name="phone" size={15} className="text-gray-400" />
                <a className="font-semibold" href={`tel:${p.phone}`}>{p.display}</a>
                <span className="text-xs" style={{ color: 'rgba(60,60,67,0.6)' }}>{PHONE_SRC[p.source] || p.source}</span>
                <button type="button" className="ml-auto fb-iconbtn" onClick={() => copy(p.phone, 'Number')} aria-label={`Copy ${p.display}`}><Icon name="copy" size={14} /></button>
              </div>
            ))}
            {(s.contacts || []).map((c) => (
              <div key={c.id} className="flex items-center gap-2">
                <Icon name="mail" size={15} className="text-gray-400" />
                <a className="font-semibold truncate" href={`mailto:${c.email}`}>{c.email}</a>
                <span className="text-xs whitespace-nowrap" style={{ color: 'rgba(60,60,67,0.6)' }}>{c.is_role_address ? 'shared inbox' : 'person'} · <a className="underline" href={c.source_url} target="_blank" rel="noreferrer noopener">found here</a></span>
                <button type="button" className="ml-auto fb-iconbtn" onClick={() => copy(c.email, 'Email')} aria-label={`Copy ${c.email}`}><Icon name="copy" size={14} /></button>
              </div>
            ))}
            {!(s.phones || []).length && !(s.contacts || []).length && <div style={{ color: 'rgba(60,60,67,0.6)' }}>No phone or email found yet.</div>}
          </div>
          {(s.channels || []).filter((c) => c.kind !== 'contact_form').length > 0 && (
            <div className="flex flex-wrap gap-1.5 mt-3">
              {s.channels.filter((c) => c.kind !== 'contact_form').map((c) => (
                <a key={c.url} className="glass-badge bg-blue-50 text-blue-700 inline-flex items-center gap-1" href={c.url} target="_blank" rel="noreferrer noopener">{CHANNEL[c.kind] || c.kind}<Icon name="external" size={11} /></a>
              ))}
            </div>
          )}
          <div className="text-[11px] mt-2" style={{ color: 'rgba(60,60,67,0.5)' }}>Emails come only from the school’s own website – never guessed.</div>
        </Section>

        {(s.profile?.summary || signals.length > 0) && (
          <Section title="On their website">
            {s.profile?.summary && <p className="mb-2 leading-relaxed">{s.profile.summary}</p>}
            <div className="flex flex-wrap gap-1.5">
              {signals.map(([k]) => (
                <span key={k} className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-[12px] font-medium" style={{ background: 'rgba(118,118,128,0.12)' }}>
                  <Icon name="check" size={12} strokeWidth={2.5} className="text-green-600" />{SIGNAL_LABEL[k] || k.replace(/_/g, ' ')}
                </span>
              ))}
            </div>
          </Section>
        )}

        {s.org_kind !== 'ground_school' && (
          <Section title="Your decision">
            {s.eligibility !== 'eligible_verified' && s.eligibility_rule && (
              <div className="flex flex-wrap gap-2 mb-2">
                <input className="glass-input px-3 py-2 text-sm flex-1 min-w-[160px]" placeholder="Approval no. (optional)" value={ref} onChange={(e) => setRef(e.target.value)} />
                <button className="glass-btn px-4 py-2 text-sm" disabled={busy} onClick={() => act({ decision: 'confirm', reference: ref || null }, 'Marked eligible')}>I checked – it’s approved</button>
              </div>
            )}
            {s.eligibility !== 'eligible_verified' && !s.eligibility_rule && (
              <div className="space-y-2 mb-2">
                <div className="text-xs" style={{ color: 'rgba(60,60,67,0.7)' }}>No approval register for {cname(s.country)} yet: check the school on its civil aviation authority’s site and paste that page.</div>
                <div className="flex flex-wrap gap-2">
                  <input className="glass-input px-3 py-2 text-sm flex-1 min-w-[180px]" placeholder="Link to the authority page" value={src} onChange={(e) => setSrc(e.target.value)} />
                  <input className="glass-input px-3 py-2 text-sm w-36" placeholder="Approval no." value={ref} onChange={(e) => setRef(e.target.value)} />
                  <button className="glass-btn px-4 py-2 text-sm" disabled={busy || !/^https?:\/\//i.test(src.trim())}
                    onClick={() => act({ decision: 'confirm', reference: ref || null, source_url: src.trim() }, 'Marked eligible')}>I checked – it’s approved</button>
                </div>
              </div>
            )}
            {s.eligibility_rule && (
              <div className="text-xs mb-2" style={{ color: 'rgba(60,60,67,0.7)' }}>Check on: {s.eligibility_rule.lookup.map(([l, h], i) => <span key={h}>{i ? ' · ' : ''}<a className="text-blue-600" href={h} target="_blank" rel="noreferrer noopener">{l}</a></span>)}</div>
            )}
            {asking && (
              <div className="flex flex-wrap gap-2 mb-2">
                <input autoFocus className="glass-input px-3 py-2 text-sm flex-1 min-w-[180px]" placeholder="Why is it not qualified?" value={note} onChange={(e) => setNote(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && note.trim()) act({ decision: 'unqualified', note }, 'Marked not qualified'); }} />
                <button className="px-4 py-2 text-sm rounded-xl text-white" style={{ background: '#FF3B30' }} disabled={busy || !note.trim()} onClick={() => act({ decision: 'unqualified', note }, 'Marked not qualified')}>Confirm</button>
                <button className="px-3 py-2 text-sm rounded-xl" onClick={() => setAsking(false)}>Cancel</button>
              </div>
            )}
            <div className="flex flex-wrap gap-2">
              {s.eligibility !== 'unqualified' && !asking && (
                <button className="px-3 py-2 text-[13px] rounded-xl border border-red-200 text-red-600 bg-white inline-flex items-center gap-1" onClick={() => setAsking(true)}><Icon name="ban" size={14} />Not qualified</button>
              )}
              <button className="px-3 py-2 text-[13px] rounded-xl border border-gray-200 bg-white inline-flex items-center gap-1" disabled={busy} onClick={() => act({ decision: 'recheck' }, 'Checked again')}><Icon name="refresh" size={14} />Check again</button>
              <button className="px-3 py-2 text-[13px] rounded-xl border border-gray-200 bg-white inline-flex items-center gap-1" onClick={research}><Icon name="globe" size={14} />Read website again</button>
            </div>
          </Section>
        )}
      </div>
    </div>
  );
}

// Centred window on desktop, bottom sheet on phones. Closes on ✕, Esc, or a click/tap on the dimmed background.
function SchoolWindow({ ids, openId, setOpenId, onChanged }) {
  const i = ids.indexOf(openId);
  const prev = i > 0 ? () => setOpenId(ids[i - 1]) : null;
  const next = i >= 0 && i < ids.length - 1 ? () => setOpenId(ids[i + 1]) : null;
  useEffect(() => {
    const k = (e) => {
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target?.tagName)) return;
      if (e.key === 'ArrowLeft' && prev) prev();
      if (e.key === 'ArrowRight' && next) next();
    };
    window.addEventListener('keydown', k);
    const old = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { window.removeEventListener('keydown', k); document.body.style.overflow = old; };
  }, [prev, next]);
  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center sm:p-6 fb-fade"
      style={{ background: 'rgba(0,0,0,0.32)', backdropFilter: 'blur(6px)', WebkitBackdropFilter: 'blur(6px)' }}
      onMouseDown={(e) => { if (e.target === e.currentTarget) setOpenId(null); }}>
      <div role="dialog" aria-modal="true" aria-labelledby="fb-school-title"
        className="w-full sm:max-w-2xl max-h-[92vh] sm:max-h-[88vh] overflow-y-auto overscroll-contain rounded-t-3xl sm:rounded-3xl fb-pop"
        style={{ background: 'rgba(246,246,248,0.97)', boxShadow: '0 30px 80px rgba(0,0,0,0.25), 0 0 0 1px rgba(255,255,255,0.6) inset' }}>
        <Detail id={openId} onChanged={onChanged} onClose={() => setOpenId(null)} onPrev={prev} onNext={next}
          pos={i >= 0 ? `${i + 1} of ${ids.length.toLocaleString()}` : null} />
      </div>
    </div>
  );
}

export default function FlightBridgeSchools() {
  const [regions, setRegions] = useState([]);
  const [sel, setSel] = useState({});
  const [list, setList] = useState(null);
  const [section, setSection] = useState(null);
  const [q, setQ] = useState('');
  const [openId, setOpenId] = useState(null);
  const loadTree = useCallback(() => call('/regions').then(setRegions, (e) => showToast(e.message, 'error')), []);
  // Counts come from the server for the whole filter; the list loads one section at a time (up to 1,000 rows),
  // and search runs on the server so it finds schools beyond the first 1,000.
  const [counts, setCounts] = useState(undefined);        // undefined = loading, null = not available
  const [qs, setQs] = useState('');
  useEffect(() => { const t = setTimeout(() => setQs(q.trim()), 300); return () => clearTimeout(t); }, [q]);
  const params = useCallback((extra = {}) => {
    const p = new URLSearchParams(extra);
    if (sel.country) p.set('country', sel.country);
    if (sel.region && sel.area === undefined) p.set('region', sel.region);
    if (sel.area !== undefined) { p.set('area_id', String(sel.area)); if (sel.area === 0) p.set('region', sel.region); }
    if (qs) p.set('q', qs);
    return p;
  }, [sel, qs]);
  const loadCounts = useCallback(() => call(`/school-counts?${params()}`).then(setCounts, () => setCounts(null)), [params]);
  const active = section || SECTIONS.find(([k]) => counts?.[k])?.[0] || 'eligible_verified';
  const countsReady = counts !== undefined;
  const loadList = useCallback(() => (countsReady ? call(`/schools?${params({ limit: '1000', eligibility: active })}`)
    .then(setList, (e) => showToast(e.message, 'error')) : Promise.resolve()), [params, active, countsReady]);
  useEffect(() => { loadTree(); }, [loadTree]);
  useEffect(() => { const k = (e) => e.key === 'Escape' && setOpenId(null); window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k); }, []);
  useEffect(() => { setSection(null); setCounts(undefined); loadCounts(); }, [loadCounts]);
  useEffect(() => { setList(null); loadList(); }, [loadList]);

  const rows = list || [];
  const shownTotal = counts?.[active] ?? rows.length;
  const title = sel.areaName || (sel.region === '__none__' ? 'Region not stated' : sel.region || (sel.country ? cname(sel.country) : 'All schools'));
  const searchArea = async () => {
    try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify({ kind: 'search_area', area_id: sel.area }) }); showToast(r.message, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };

  return (
    <div className="grid gap-4 md:grid-cols-[230px_1fr]">
      <div className="glass-card p-3 h-fit md:max-h-[75vh] overflow-y-auto"><Tree regions={regions} sel={sel} onSel={(s) => { setSel(s); setOpenId(null); }} /></div>
      <div className="space-y-3 min-w-0">
        <div className="flex flex-wrap justify-between items-center gap-2">
          <div>
            <div className="text-lg font-bold">{title}</div>
            <div className="text-xs text-gray-500">{sel.country ? [cname(sel.country), sel.region === '__none__' ? null : sel.region].filter(Boolean).join(' › ') : 'Every country'}{sel.kind === 'demand_hub' ? ' · student-demand hub' : ''}</div>
          </div>
          <div className="flex flex-wrap gap-2 w-full sm:w-auto">
            <input className="glass-input px-3 py-1.5 text-sm flex-1 sm:flex-none min-w-0" placeholder="Search name or website" aria-label="Search schools" value={q} onChange={(e) => setQ(e.target.value)} />
            {sel.area > 0 && <button className="glass-btn px-3 py-1.5 text-sm" onClick={searchArea}>Search this area now</button>}
          </div>
        </div>
        <div className="flex gap-2 overflow-x-auto whitespace-nowrap">
          {SECTIONS.map(([k, label]) => (
            <button key={k} onClick={() => setSection(k)} className={`glass-tab-btn ${active === k ? 'active' : ''}`}>{label} ({(counts?.[k] ?? 0).toLocaleString()})</button>
          ))}
        </div>
        <div className="text-xs text-gray-500">{SECTIONS.find(([k]) => k === active)?.[3]}</div>
        {list !== null && shownTotal > rows.length && (
          <div className="text-xs rounded-lg px-3 py-2" style={{ background: 'rgba(0,122,255,0.08)', color: 'rgba(0,0,0,0.6)' }}>
            Showing the first {rows.length.toLocaleString()} of {shownTotal.toLocaleString()}. Pick a country or state on the left, or search, to see the rest.
          </div>
        )}
        {list === null ? <div className="text-gray-500 text-sm">Loading…</div> : rows.length === 0 ? <div className="glass-card p-6 text-center text-gray-500 text-sm">Nothing here.</div> : (
          <div>
            <div className="glass-card overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-gray-500 text-left"><tr><th className="p-2">School</th><th className="p-2">Approval</th><th className="p-2 text-right">Contacts</th></tr></thead>
                <tbody>
                  {rows.map((s) => (
                    <tr key={s.id} className={`border-t border-gray-100 cursor-pointer ${openId === s.id ? 'bg-blue-50' : 'hover:bg-gray-50'}`} onClick={() => setOpenId(s.id)}>
                      <td className="p-2"><div className="font-semibold">{s.name}{s.org_kind === 'ground_school' && <span className="glass-badge bg-purple-100 text-purple-800 ml-1">institute</span>}</div><div className="text-xs text-gray-500">{[s.city, s.region].filter((x, i, a) => x && a.indexOf(x) === i).join(', ')}{s.website_domain ? ` · ${s.website_domain}` : ''}</div></td>
                      <td className="p-2 text-xs">{s.approval_ref ? `${(s.authority_code || '').replace('_', ' ')} ${s.approval_ref}` : <span className={`glass-badge ${SEC[s.eligibility]?.cls}`}>{SEC[s.eligibility]?.label}</span>}</td>
                      <td className="p-2 text-right text-xs whitespace-nowrap">{s.contacts} email · {s.phones || 0} phone{!Number(s.contacts) && (s.channels || []).includes('contact_form') ? ' · form' : ''}{(s.channels || []).includes('linkedin') ? ' · in' : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {openId && <SchoolWindow ids={rows.map((r) => r.id)} openId={openId} setOpenId={setOpenId}
              onChanged={() => { loadList(); loadCounts(); loadTree(); }} />}
          </div>
        )}
      </div>
    </div>
  );
}
