import { useCallback, useEffect, useMemo, useState } from 'react';
import { apiFetch } from '../api';
import { showToast } from '../utils/toast';

// FlightBridge areas, automation and team, inside the CRM.

async function call(path, opts = {}) {
  const token = localStorage.getItem('token');
  const res = await apiFetch(`/api/flightbridge${path}`, { token, ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}
const COUNTRY = { US: 'United States', CA: 'Canada', AU: 'Australia', NZ: 'New Zealand', GB: 'United Kingdom', IN: 'India' };
const cname = (c) => COUNTRY[c] || c;
const when = (d) => (d ? new Date(d).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');
const ago = (d) => {
  const m = Math.round((Date.now() - new Date(d)) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return when(d);
};
const run = async (body) => {
  try { const r = await call('/automation/run', { method: 'POST', body: JSON.stringify(body) }); showToast(r.message, 'success'); return true; }
  catch (e) { showToast(e.message, 'error'); return false; }
};

/* ---------------------------------------------------------------- Areas */
export function Areas({ isAdmin }) {
  const [list, setList] = useState(null);
  const load = useCallback(() => call('/areas').then(setList, (e) => showToast(e.message, 'error')), []);
  useEffect(() => { load(); }, [load]);
  const grouped = useMemo(() => {
    const g = {};
    (list || []).forEach((a) => { ((g[a.country] ||= {})[a.region] ||= []).push(a); });
    return g;
  }, [list]);
  const toggle = async (a) => {
    try { await call(`/areas/${a.id}`, { method: 'PATCH', body: JSON.stringify({ enabled: !a.enabled }) }); showToast(a.enabled ? 'Paused' : 'Resumed', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <div className="space-y-4">
      <p className="text-sm text-glass-muted">Each area is searched for schools on Google. <b>Flying-school hubs</b> are airfields where schools cluster; <b>student-demand hubs</b> (like Ramphal Chowk) are where students and aviation institutes are. Areas are searched again every 30 days.</p>
      {isAdmin && <AddArea onAdded={load} />}
      {list === null && <div className="text-sm text-glass-muted">Loading…</div>}
      {Object.entries(grouped).map(([country, regions]) => (
        <div key={country} className="glass-card p-4 overflow-x-auto">
          <h3 className="font-bold mb-2">{cname(country)}</h3>
          <table className="w-full text-sm">
            <thead className="text-xs text-glass-muted text-left"><tr><th className="p-1">Area</th><th className="p-1">Kind</th><th className="p-1 text-right">Schools</th><th className="p-1">Last searched</th><th /></tr></thead>
            <tbody>
              {Object.entries(regions).map(([region, areas]) => areas.map((a, i) => (
                <tr key={a.id} className={`border-t border-gray-100 ${a.enabled ? '' : 'opacity-50'}`}>
                  <td className="p-1">{i === 0 && <div className="text-xs text-glass-muted">{region}</div>}<b>{a.name}</b> <span className="text-xs text-glass-muted">{a.radius_km} km</span></td>
                  <td className="p-1 text-xs">{a.kind === 'demand_hub' ? 'Student demand' : 'Flying schools'}</td>
                  <td className="p-1 text-right">{a.schools}</td>
                  <td className="p-1 text-xs text-glass-muted">{a.last_searched_at ? `${when(a.last_searched_at)}${a.last_result?.new != null ? ` – ${a.last_result.new} new` : ''}` : 'not yet'}</td>
                  <td className="p-1 text-right whitespace-nowrap">
                    <button className="text-xs underline mr-2" onClick={() => run({ kind: 'search_area', area_id: a.id })}>Search now</button>
                    {isAdmin && <button className="text-xs underline" onClick={() => toggle(a)}>{a.enabled ? 'Pause' : 'Resume'}</button>}
                  </td>
                </tr>
              )))}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}

function AddArea({ onAdded }) {
  const [v, setV] = useState({ country: 'US', region: '', name: '', kind: 'training_hub', radius_km: 40 });
  const [busy, setBusy] = useState(false);
  const submit = async (e) => {
    e.preventDefault(); setBusy(true);
    try {
      await call('/areas', { method: 'POST', body: JSON.stringify({ ...v, radius_km: Number(v.radius_km), region: v.region.trim(), name: v.name.trim() }) });
      showToast(`Added ${v.name}. It's searched on the next cycle.`, 'success'); setV({ ...v, name: '' }); onAdded();
    } catch (x) { showToast(x.message, 'error'); } finally { setBusy(false); }
  };
  const f = 'glass-input px-2 py-1.5 text-sm w-full';
  return (
    <form className="glass-card p-4" onSubmit={submit}>
      <h3 className="font-bold mb-2">Add an area</h3>
      <div className="grid grid-cols-2 md:grid-cols-5 gap-2 text-xs">
        <label>Country<select className={f} value={v.country} onChange={(e) => setV({ ...v, country: e.target.value })}>{Object.keys(COUNTRY).map((c) => <option key={c} value={c}>{cname(c)}</option>)}</select></label>
        <label>State / province<input className={f} value={v.region} onChange={(e) => setV({ ...v, region: e.target.value })} placeholder="Florida" required /></label>
        <label>Area<input className={f} value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} placeholder="Lakeland" required /></label>
        <label>Kind<select className={f} value={v.kind} onChange={(e) => setV({ ...v, kind: e.target.value })}><option value="training_hub">Flying-school hub</option><option value="demand_hub">Student-demand hub</option></select></label>
        <label>Radius (km)<input className={f} type="number" min={2} max={50} value={v.radius_km} onChange={(e) => setV({ ...v, radius_km: e.target.value })} /></label>
      </div>
      <div className="flex items-center justify-between mt-2 gap-2">
        <span className="text-xs text-glass-muted">Google finds the location from the name.</span>
        <button className="glass-btn px-3 py-1.5 text-sm" disabled={busy || !v.region.trim() || !v.name.trim()}>{busy ? 'Finding it…' : 'Add area'}</button>
      </div>
    </form>
  );
}

/* ---------------------------------------------------------------- Automation */
const RUNNER = { 'crm-server': 'CRM server', 'github-actions': 'GitHub Actions', mac: 'Office Mac' };
const runnerLabel = (r) => RUNNER[(r || '').split('@')[0]] || (r?.startsWith('manual') ? 'Manual run' : r);
const KIND = { cycle: 'Full cycle', research_school: 'Read one school', find_websites: 'Find websites', research_batch: 'Read websites', search_area: 'Search area' };
const ACTION = {
  website_search: (p) => (p.status === 'found' ? `Found the website ${p.domain}` : 'No confirmed website'),
  research_stored: (p) => `Read ${p.pages} pages, ${p.contacts} public email${p.contacts === 1 ? '' : 's'}`,
  qualified: (p) => `Scored ${Math.round(p.score)}/100`,
  draft_created: () => 'Drafted a first email for approval',
  draft_skipped: (p) => (p.reason === 'no_approved_initial_template' ? 'Draft waiting – approve a first-email template' : `Draft skipped – ${p.reason}`),
  organisation_created: (p) => (p.source === 'google_places' ? `Found on Google in ${p.area}` : 'Added from the regulator register'),
  school_qualified: () => 'Marked good fit by a person',
  school_rejected: (p) => `Marked not a fit${p.reason ? ` – ${p.reason}` : ''}`,
  regulatory_verified_by_human: () => 'Approval confirmed by a person',
  approval_approved: () => 'Email approved',
  approval_edited_approved: () => 'Email edited and approved',
  template_approved: () => 'Template approved',
  kill_switch_set: (p) => (p.engaged ? 'Sending paused' : 'Kill switch released'),
  area_searched: (p) => `Searched: ${p.new || 0} new, ${p.matched || 0} already known`,
  eligibility_set: (p) => `Eligibility: ${{ eligible_verified: 'eligible', eligible_claimed: 'check needed', unqualified: 'unqualified', unknown: 'not checked' }[p.to] || p.to}`,
};
const GROUPABLE = ['organisation_created', 'website_search', 'research_stored', 'qualified', 'draft_created', 'eligibility_set', 'area_searched'];
const GROUP_LABEL = {
  organisation_created: (n) => `${n} new schools found`, website_search: (n) => `Searched ${n} websites`,
  research_stored: (n) => `Read ${n} school websites`, qualified: (n) => `Scored ${n} schools`,
  draft_created: (n) => `Drafted ${n} emails`, eligibility_set: (n) => `Checked eligibility of ${n} schools`, area_searched: (n) => `Searched ${n} areas`,
};
function groupActivity(items) {
  const out = [];
  for (const e of items) {
    const last = out[out.length - 1];
    if (last && last.action === e.action && e.actor_type === 'system' && last.actor_type === 'system' && GROUPABLE.includes(e.action)) last.group.push(e);
    else out.push({ ...e, group: [e] });
  }
  return out.slice(0, 16);
}
function summarise(st = {}) {
  const r = st.research || {};
  const b = [];
  const n = (v, one, many) => v && b.push(`${v} ${v === 1 ? one : many}`);
  n(r.discover?.new, 'new school', 'new schools');
  n(r.find_websites?.found, 'website found', 'websites found');
  n(r.research?.researched, 'site read', 'sites read');
  n(r.research?.emails_found, 'email', 'emails');
  n(r.eligibility?.eligible_verified, 'eligible', 'eligible');
  n(r.qualify?.qualified, 'good fit', 'good fit');
  n(r.draft?.drafts_created, 'draft', 'drafts');
  n(st.inbound?.stored, 'reply', 'replies');
  return b.length ? b.join(', ') : 'Nothing new to do';
}
function errorsOf(r) {
  const st = r.stats || {};
  const e = Object.entries({ ...st, ...(st.research || {}) }).filter(([k]) => k.endsWith('_error')).map(([, v]) => String(v));
  if (r.error) e.unshift(r.error);
  return [...new Set(e)];
}
function explain(err) {
  if (/has not been used|SERVICE_DISABLED/i.test(err)) return 'Enable "Places API (New)" in Google Cloud, then it continues on the next cycle.';
  if (/GOOGLE_PLACES_API_KEY is not set/.test(err)) return 'Add the Google Places key in Settings.';
  if (/API key not valid|API_KEY_INVALID/.test(err)) return 'Google says the Places key is not valid. Replace it in Settings.';
  return err;
}

export function Automation({ isAdmin }) {
  const [d, setD] = useState(null);
  const load = useCallback(() => call('/automation').then(setD, (e) => showToast(e.message, 'error')), []);
  useEffect(() => { load(); const t = setInterval(load, 20000); return () => clearInterval(t); }, [load]);
  const go = async (kind) => { if (await run({ kind })) load(); };
  if (!d) return <div className="text-sm text-glass-muted">Loading…</div>;
  const last = d.runs[0];
  const lastErr = last ? errorsOf(last) : [];
  const running = last && !last.finished_at && Date.now() - new Date(last.started_at) < 2 * 3600e3;
  const ap = d.autopilot || {};
  const stage = (n, title, text, key, kind) => (
    <div className={`glass-card p-3 ${ap[key] === false ? 'opacity-60' : ''}`}>
      <div className="flex justify-between items-start gap-2"><b className="text-sm">{title}</b>{n != null && <span className="glass-badge bg-blue-100 text-blue-800" title="Waiting at this step">{n}</span>}</div>
      <p className="text-xs text-glass-muted mt-1">{text}</p>
      {ap[key] === false && <p className="text-xs text-orange-700 mt-1">Paused</p>}
      {kind && <button className="text-xs underline mt-1" onClick={() => go(kind)}>Run now</button>}
    </div>
  );
  return (
    <div className="space-y-4">
      <div className="glass-card p-4 flex flex-wrap justify-between items-center gap-3">
        <div>
          <div className="font-bold flex items-center gap-2">
            <span className={`inline-block w-2.5 h-2.5 rounded-full ${running ? 'bg-blue-500 animate-pulse' : lastErr.length ? 'bg-orange-500' : last ? 'bg-green-500' : 'bg-gray-400'}`} />
            {running ? 'Working now…' : last ? `Last cycle ${ago(last.finished_at || last.started_at)}` : 'Waiting for the first cycle'}
          </div>
          <div className="text-xs text-glass-muted">Runs on the CRM server every 15 minutes. Nothing is ever sent from here.</div>
          {lastErr.map((e) => <div key={e} className="text-xs text-red-700 mt-1">{explain(e)}</div>)}
        </div>
        <button className="glass-btn px-3 py-2 text-sm" onClick={() => go('cycle')}>Run a cycle now</button>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
        {stage(null, '1 · Search areas', 'Google search inside each area for schools.', 'discover_areas')}
        {stage(d.backlog.need_website, '2 · Find website', 'Kept only if the site names the school.', 'find_websites', 'find_websites')}
        {stage(d.backlog.need_research, '3 · Read website', 'Public emails, phones and facts from the school’s own site.', 'research', 'research_batch')}
        {stage(null, '4 · Eligibility', 'Checked against the country’s own standard.', 'eligibility')}
        {stage(d.backlog.need_scoring, '5 · Score fit', 'Unclear cases go to a person.', 'qualify')}
        {stage(null, '6 · Draft email', 'Eligible schools only, from your approved template.', 'draft')}
      </div>

      {isAdmin && <Autopilot cfg={ap} onSaved={load} />}

      <div className="grid md:grid-cols-2 gap-4">
        <div className="glass-card p-4">
          <h3 className="font-bold mb-2">Recent cycles</h3>
          {d.runs.length === 0 ? <p className="text-sm text-glass-muted">None yet.</p> : (
            <ul className="space-y-2 text-sm">
              {d.runs.slice(0, 10).map((r) => {
                const errs = errorsOf(r);
                return (
                  <li key={r.id} className="flex gap-2">
                    <span className={`mt-1.5 inline-block w-2 h-2 rounded-full shrink-0 ${r.status === 'ok' || r.status === 'succeeded' ? 'bg-green-500' : r.finished_at ? 'bg-orange-500' : 'bg-blue-500'}`} />
                    <div>
                      <div className="font-semibold">{summarise(r.stats)}</div>
                      <div className="text-xs text-glass-muted">{when(r.started_at)} · {runnerLabel(r.runner)}{r.finished_at ? ` · ${Math.max(1, Math.round((new Date(r.finished_at) - new Date(r.started_at)) / 1000))} s` : ' · running'}</div>
                      {errs[0] && <div className="text-xs text-red-700">{explain(errs[0])}</div>}
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
        <div className="glass-card p-4">
          <h3 className="font-bold mb-2">What happened</h3>
          {d.activity.length === 0 ? <p className="text-sm text-glass-muted">Nothing yet.</p> : (
            <ul className="space-y-1.5 text-sm">
              {groupActivity(d.activity).map((e, i) => (
                <li key={i}>
                  <span className="text-xs text-glass-muted mr-2">{ago(e.at)}{e.actor_type === 'employee' ? ' · person' : ''}</span>
                  {e.group.length > 2 ? GROUP_LABEL[e.action](e.group.length)
                    : <>{e.org_name && <b>{e.org_name}: </b>}{(ACTION[e.action] || (() => e.action.replace(/_/g, ' ')))(e.payload || {})}</>}
                </li>
              ))}
            </ul>
          )}
          {d.jobs.length > 0 && (
            <>
              <h4 className="font-semibold text-sm mt-3 mb-1">Run-now requests</h4>
              <ul className="space-y-1 text-sm">
                {d.jobs.slice(0, 6).map((j) => (
                  <li key={j.id}><span className="text-xs text-glass-muted mr-2">{ago(j.requested_at)}{j.requested_by_name ? ` · ${j.requested_by_name}` : ''}</span>
                    {KIND[j.kind] || j.kind}{j.org_name ? ` – ${j.org_name}` : ''}: <b>{{ queued: 'waiting', running: 'running', done: 'done', failed: 'failed' }[j.status] || j.status}</b></li>
                ))}
              </ul>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Autopilot({ cfg, onSaved }) {
  const [v, setV] = useState({ discover_areas: true, find_websites: true, research: true, eligibility: true, qualify: true, draft: true, batch_size: 8, areas_per_cycle: 2, ...cfg });
  useEffect(() => { setV((x) => ({ ...x, ...cfg })); }, [cfg]);
  const save = async () => {
    try { await call('/automation/settings', { method: 'POST', body: JSON.stringify({ ...v, batch_size: Number(v.batch_size), areas_per_cycle: Number(v.areas_per_cycle) }) }); showToast('Saved – applies from the next cycle', 'success'); onSaved(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  const box = (k, label) => <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={!!v[k]} onChange={(e) => setV({ ...v, [k]: e.target.checked })} />{label}</label>;
  const num = (k, label, max) => <label className="flex items-center gap-1.5 text-sm">{label}<input type="number" min={1} max={max} className="glass-input px-2 py-1 w-16 text-sm" value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} /></label>;
  return (
    <div className="glass-card p-4">
      <h3 className="font-bold">Autopilot</h3>
      <p className="text-xs text-glass-muted mb-2">Steps that run by themselves each cycle. Sending is never automatic.</p>
      <div className="flex flex-wrap gap-x-5 gap-y-2 items-center">
        {box('discover_areas', 'Search areas')}{box('find_websites', 'Find websites')}{box('research', 'Read websites')}
        {box('eligibility', 'Eligibility')}{box('qualify', 'Score fit')}{box('draft', 'Draft emails')}
        {num('areas_per_cycle', 'Areas per cycle', 10)}{num('batch_size', 'Schools per step', 50)}
        <button className="glass-btn px-3 py-1.5 text-sm" onClick={save}>Save</button>
      </div>
    </div>
  );
}

/* ---------------------------------------------------------------- Team */
export function Team({ meId }) {
  const [rows, setRows] = useState(null);
  const load = useCallback(() => call('/team').then(setRows, (e) => showToast(e.message, 'error')), []);
  useEffect(() => { load(); }, [load]);
  const set = async (emp, role) => {
    try { await call(`/team/${emp.id}/role`, { method: 'POST', body: JSON.stringify({ role: role || null }) }); showToast(`${emp.name}: ${role ? (role === 'admin' ? 'admin' : 'research assistant') : 'no access'}`, 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  if (!rows) return <div className="text-sm text-glass-muted">Loading…</div>;
  return (
    <div className="glass-card p-4">
      <p className="text-sm text-glass-muted mb-3">Research assistants see FlightBridge AI in their CRM, check schools and record evidence. Only admins approve emails, templates and settings.</p>
      <table className="w-full text-sm">
        <tbody>
          {rows.map((e) => (
            <tr key={e.id} className="border-t border-gray-100">
              <td className="p-1.5"><b>{e.name}</b> <span className="text-xs text-glass-muted">{e.department}</span></td>
              <td className="p-1.5 text-right">
                {e.department === 'Admin' ? <span className="text-xs text-glass-muted">Admin (CRM)</span> : (
                  <select className="glass-input px-2 py-1 text-sm" value={e.fb_role || ''} disabled={e.id === meId} onChange={(x) => set(e, x.target.value)}>
                    <option value="">No access</option><option value="researcher">Research assistant</option><option value="admin">Admin</option>
                  </select>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
