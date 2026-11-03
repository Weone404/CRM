import { useCallback, useEffect, useMemo, useState } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';

// FlightBridge schools inside the CRM: Country > State > Area, eligibility sections, full details.
// Same data and API as the standalone FlightBridge app.

async function call(path, opts = {}) {
  const token = localStorage.getItem('token');
  const res = await apiFetch(`/api/flightbridge${path}`, { token, ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

const COUNTRY = { US: 'United States', CA: 'Canada', AU: 'Australia', NZ: 'New Zealand', GB: 'United Kingdom', IN: 'India', ES: 'Spain', IE: 'Ireland' };
const cname = (c) => COUNTRY[c] || c;
const SECTIONS = [
  ['eligible_verified', 'Eligible', 'bg-green-100 text-green-800', 'Approved by the official register or confirmed by a person.'],
  ['eligible_claimed', 'Check needed', 'bg-yellow-100 text-yellow-800', 'The website claims the approval – confirm it on the regulator’s site.'],
  ['unqualified', 'Unqualified', 'bg-red-100 text-red-800', 'No approval found for this country’s standard, or not a pilot-training school.'],
  ['unknown', 'Not checked yet', 'bg-gray-100 text-gray-700', 'Website not read yet – automation will get to these.'],
];
const SEC = Object.fromEntries(SECTIONS.map(([k, l, c]) => [k, { label: l, cls: c }]));
const PHONE_SRC = { website: 'website', regulator: 'regulator register', google_places: 'Google', human: 'added by a person' };

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

function Detail({ id, onChanged, onClose }) {
  const [s, setS] = useState(null);
  const [note, setNote] = useState('');
  const [ref, setRef] = useState('');
  const load = useCallback(() => call(`/schools/${id}`).then(setS, (e) => showToast(e.message, 'error')), [id]);
  useEffect(() => { setS(null); load(); }, [load]);
  const act = async (body, ok) => {
    try { await call(`/schools/${id}/eligibility`, { method: 'POST', body: JSON.stringify(body) }); showToast(ok, 'success'); load(); onChanged(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const research = async () => {
    try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify({ kind: 'research_school', org_id: id }) }); showToast(r.message, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };
  if (!s) return <div className="glass-card p-4 text-sm text-gray-500">Loading…</div>;
  const sec = SEC[s.eligibility] || SEC.unknown;
  return (
    <div className="glass-card p-4 space-y-3 text-sm">
      <div className="flex justify-between gap-2">
        <div>
          <div className="text-lg font-bold">{s.name}</div>
          <div className="text-gray-500">{[s.city, s.region, cname(s.country)].filter((x, i, a) => x && a.indexOf(x) === i).join(', ')}{s.area ? ` · area: ${s.area.name}` : ''}</div>
          {s.website_domain && <a className="text-blue-600 underline" href={`https://${s.website_domain}`} target="_blank" rel="noreferrer noopener">{s.website_domain}</a>}
        </div>
        <button className="text-gray-500 underline h-fit" onClick={onClose}>Close</button>
      </div>

      <div>
        <div className="font-semibold mb-1">Eligibility <span className={`glass-badge ml-1 ${sec.cls}`}>{sec.label}</span></div>
        {s.org_kind === 'ground_school' && <div className="text-xs text-gray-600 mb-1">Aviation institute in a student-demand hub – not a flying school, so not assessed.</div>}
        {s.eligibility_rule && s.org_kind !== 'ground_school' && <div className="text-xs text-gray-500 mb-1">Standard: {s.eligibility_rule.credential}</div>}
        <ul className="space-y-1">{(s.eligibility_reasons || []).map((r, i) => (
          <li key={i} className="border-l-2 border-gray-300 pl-2">{r.text}
            {r.excerpt && <div className="text-xs text-gray-500">“{r.excerpt}”</div>}
            {r.source_url && <a className="text-xs text-blue-600 underline" href={r.source_url} target="_blank" rel="noreferrer noopener">Source</a>}</li>))}</ul>
        {s.eligibility_rule && <div className="text-xs mt-1">Check on: {s.eligibility_rule.lookup.map(([l, h], i) => <span key={h}>{i ? ' · ' : ''}<a className="text-blue-600 underline" href={h} target="_blank" rel="noreferrer noopener">{l}</a></span>)}</div>}
        <div className="flex flex-wrap gap-2 mt-2">
          {s.eligibility !== 'eligible_verified' && s.eligibility_rule && (
            <>
              <input className="glass-input px-2 py-1 text-xs" placeholder="Approval no. (optional)" value={ref} onChange={(e) => setRef(e.target.value)} />
              <button className="glass-btn px-3 py-1 text-xs" onClick={() => act({ decision: 'confirm', reference: ref || null }, 'Marked eligible')}>I checked – it’s approved</button>
            </>
          )}
          {s.eligibility !== 'unqualified' && (
            <>
              <input className="glass-input px-2 py-1 text-xs" placeholder="Why unqualified?" value={note} onChange={(e) => setNote(e.target.value)} />
              <button className="px-3 py-1 text-xs rounded-lg border border-red-200 text-red-600 bg-white" disabled={!note.trim()} onClick={() => act({ decision: 'unqualified', note }, 'Marked unqualified')}>Mark unqualified</button>
            </>
          )}
          <button className="px-3 py-1 text-xs rounded-lg border border-gray-300 bg-white" onClick={() => act({ decision: 'recheck' }, 'Re-checked')}>Re-check</button>
          <button className="px-3 py-1 text-xs rounded-lg border border-gray-300 bg-white" onClick={research}>Read website again</button>
        </div>
      </div>

      <div>
        <div className="font-semibold mb-1">Contacts</div>
        {(s.phones || []).map((p) => <div key={p.phone}><a className="font-semibold" href={`tel:${p.phone}`}>{p.display}</a> <span className="text-xs text-gray-500">from {PHONE_SRC[p.source] || p.source}</span></div>)}
        {(s.contacts || []).map((c) => <div key={c.id}><a className="font-semibold" href={`mailto:${c.email}`}>{c.email}</a> <span className="text-xs text-gray-500">{c.is_role_address ? 'shared inbox' : 'named person'} · <a className="underline" href={c.source_url} target="_blank" rel="noreferrer noopener">found here</a></span></div>)}
        {!(s.phones || []).length && !(s.contacts || []).length && <div className="text-gray-500">No contact details found yet.</div>}
        <div className="text-xs text-gray-500 mt-1">Emails come only from the school’s own website – never guessed.</div>
      </div>

      {s.profile && (
        <div>
          <div className="font-semibold mb-1">What their website says</div>
          {s.profile.summary && <p>{s.profile.summary}</p>}
          <div className="flex flex-wrap gap-1 mt-1">{Object.entries(s.profile.signals || {}).filter(([, v]) => v).map(([k]) => <span key={k} className="glass-badge bg-gray-100 text-gray-700">{k.replace(/_/g, ' ')}</span>)}</div>
        </div>
      )}

      {(s.regulatory || []).length > 0 && (
        <div>
          <div className="font-semibold mb-1">Regulator entry</div>
          {s.regulatory.map((r) => <div key={r.id}><b>{r.authority_code.replace('_', ' ')}</b> {r.approval_ref || ''} · {r.status === 'verified_by_human' ? 'confirmed by a person' : 'listed in the official register'} · <a className="text-blue-600 underline" href={r.source_url} target="_blank" rel="noreferrer noopener">source</a></div>)}
        </div>
      )}
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
  const loadList = useCallback(() => {
    const p = new URLSearchParams({ limit: '1000' });
    if (sel.country) p.set('country', sel.country);
    if (sel.region && sel.area === undefined) p.set('region', sel.region);
    if (sel.area !== undefined) { p.set('area_id', String(sel.area)); if (sel.area === 0) p.set('region', sel.region); }
    return call(`/schools?${p}`).then(setList, (e) => showToast(e.message, 'error'));
  }, [sel]);
  useEffect(() => { loadTree(); }, [loadTree]);
  useEffect(() => { setList(null); setSection(null); loadList(); }, [loadList]);

  const counts = useMemo(() => { const c = {}; (list || []).forEach((s) => { c[s.eligibility || 'unknown'] = (c[s.eligibility || 'unknown'] || 0) + 1; }); return c; }, [list]);
  const active = section || SECTIONS.find(([k]) => counts[k])?.[0] || 'eligible_verified';
  const rows = (list || []).filter((s) => (s.eligibility || 'unknown') === active && (!q || `${s.name} ${s.website_domain || ''}`.toLowerCase().includes(q.toLowerCase())));
  const title = sel.areaName || (sel.region === '__none__' ? 'Region not stated' : sel.region || (sel.country ? cname(sel.country) : 'All schools'));
  const searchArea = async () => {
    try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify({ kind: 'search_area', area_id: sel.area }) }); showToast(r.message, 'success'); }
    catch (e) { showToast(e.message, 'error'); }
  };

  return (
    <div className="grid gap-4" style={{ gridTemplateColumns: 'minmax(200px, 260px) 1fr' }}>
      <div className="glass-card p-3 h-fit max-h-[75vh] overflow-y-auto"><Tree regions={regions} sel={sel} onSel={(s) => { setSel(s); setOpenId(null); }} /></div>
      <div className="space-y-3 min-w-0">
        <div className="flex flex-wrap justify-between items-center gap-2">
          <div>
            <div className="text-lg font-bold">{title}</div>
            <div className="text-xs text-gray-500">{sel.country ? [cname(sel.country), sel.region === '__none__' ? null : sel.region].filter(Boolean).join(' › ') : 'Every country'}{sel.kind === 'demand_hub' ? ' · student-demand hub' : ''}</div>
          </div>
          <div className="flex gap-2">
            <input className="glass-input px-3 py-1.5 text-sm" placeholder="Search name or website" value={q} onChange={(e) => setQ(e.target.value)} />
            {sel.area > 0 && <button className="glass-btn px-3 py-1.5 text-sm" onClick={searchArea}>Search this area now</button>}
          </div>
        </div>
        <div className="flex gap-2 overflow-x-auto whitespace-nowrap">
          {SECTIONS.map(([k, label]) => (
            <button key={k} onClick={() => setSection(k)} className={`glass-tab-btn ${active === k ? 'active' : ''}`}>{label} ({counts[k] || 0})</button>
          ))}
        </div>
        <div className="text-xs text-gray-500">{SECTIONS.find(([k]) => k === active)?.[3]}</div>
        {list === null ? <div className="text-gray-500 text-sm">Loading…</div> : rows.length === 0 ? <div className="glass-card p-6 text-center text-gray-500 text-sm">Nothing here.</div> : (
          <div className="grid gap-3" style={{ gridTemplateColumns: openId ? '1fr 1fr' : '1fr' }}>
            <div className="glass-card overflow-hidden">
              <table className="w-full text-sm">
                <thead className="text-xs text-gray-500 text-left"><tr><th className="p-2">School</th><th className="p-2">Approval</th><th className="p-2 text-right">Contacts</th></tr></thead>
                <tbody>
                  {rows.map((s) => (
                    <tr key={s.id} className={`border-t border-gray-100 cursor-pointer ${openId === s.id ? 'bg-blue-50' : 'hover:bg-gray-50'}`} onClick={() => setOpenId(s.id)}>
                      <td className="p-2"><div className="font-semibold">{s.name}{s.org_kind === 'ground_school' && <span className="glass-badge bg-purple-100 text-purple-800 ml-1">institute</span>}</div><div className="text-xs text-gray-500">{[s.city, s.region].filter((x, i, a) => x && a.indexOf(x) === i).join(', ')}{s.website_domain ? ` · ${s.website_domain}` : ''}</div></td>
                      <td className="p-2 text-xs">{s.approval_ref ? `${(s.authority_code || '').replace('_', ' ')} ${s.approval_ref}` : <span className={`glass-badge ${SEC[s.eligibility]?.cls}`}>{SEC[s.eligibility]?.label}</span>}</td>
                      <td className="p-2 text-right text-xs whitespace-nowrap">{s.contacts} email · {s.phones || 0} phone</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {openId && <Detail id={openId} onChanged={() => { loadList(); loadTree(); }} onClose={() => setOpenId(null)} />}
          </div>
        )}
      </div>
    </div>
  );
}
