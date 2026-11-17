import { useState } from 'react';
import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';
import { showToast } from '../utils/toast';

// CRM > Meta Ads > Overview (migration 104): speed-to-lead alerts and the Meta lead archive.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF' };
const fmt = (v) => Math.round(Number(v) || 0).toLocaleString('en-IN');
const day = (t) => (t ? new Date(t).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '–');

export function SpeedAlerts({ access }) {
  const [a, reload] = useLoad(() => rpc('api_ads_lead_alerts'), [], { refreshMs: 60000 });
  const [cfg, setCfg] = useState(null);
  if (!a) return null;
  const s = cfg ?? a.settings;
  const set = (k) => (e) => setCfg({ ...s, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const waiting = a.waiting || [];
  return (
    <section className="glass-card p-4 space-y-3" data-testid="speed-alerts">
      <div className="flex items-start gap-2">
        <div className="flex-1"><h3 className="font-bold">Speed to lead</h3>
          <div className="text-xs text-glass-muted">Ad leads still waiting for a first call. {a.settings.on ? `Alerts after ${a.settings.minutes} min (owner), ${a.settings.escalate_minutes} min (Admin), ${a.settings.from}-${a.settings.to}.` : 'Alerts are off.'}
            {a.median_first_call_min_30d !== null && ` Median first call (30 days): ${fmt(a.median_first_call_min_30d)} min.`}</div></div>
        <span className="text-2xl font-bold" style={{ color: waiting.length ? C.red : C.green }}>{waiting.length}</span>
      </div>
      {waiting.length > 0 && <div className="space-y-1">{waiting.slice(0, 8).map((w) => (
        <div key={w.lead_id} className="flex items-center gap-2 text-sm">
          <span className="flex-1 truncate"><b>{w.name || 'New lead'}</b>{w.course ? ` · ${w.course}` : ''} <span className="text-glass-muted text-xs">({w.platform})</span></span>
          <span className="text-xs font-semibold" style={{ color: w.waited_min >= a.settings.escalate_minutes ? C.red : C.amber }}>{fmt(w.waited_min)} min</span>
        </div>))}</div>}
      {(!a.settings.phones || !a.settings.email_ready) && <div className="text-[11px] text-glass-muted">
        {!a.settings.phones && 'Nobody has phone notifications on yet (My Profile → phone app). '}{!a.settings.email_ready && 'CRM email is not set up, so no alert emails. '}Waiting leads always show here.</div>}
      {access.is_admin && <details className="text-sm"><summary className="cursor-pointer text-xs font-semibold">Alert settings</summary>
        <div className="flex flex-wrap items-end gap-2 mt-2">
          <label className="text-xs flex items-center gap-1.5"><input type="checkbox" aria-label="Alerts on" checked={!!s.on} onChange={set('on')} />On</label>
          <label className="text-xs">First alert after (min)<input aria-label="First alert minutes" className="glass-input px-2 py-1 text-sm w-20 block" value={s.minutes} onChange={set('minutes')} /></label>
          <label className="text-xs">Admin after (min)<input aria-label="Admin alert minutes" className="glass-input px-2 py-1 text-sm w-20 block" value={s.escalate_minutes} onChange={set('escalate_minutes')} /></label>
          <label className="text-xs">From<input aria-label="Alerts from" type="time" className="glass-input px-2 py-1 text-sm block" value={s.from} onChange={set('from')} /></label>
          <label className="text-xs">To<input aria-label="Alerts to" type="time" className="glass-input px-2 py-1 text-sm block" value={s.to} onChange={set('to')} /></label>
          <Btn ghost disabled={!cfg} onClick={() => run(rpc('api_ads_lead_alerts_save', { p_cfg: { ...s, minutes: Number(s.minutes), escalate_minutes: Number(s.escalate_minutes) } })
            .then(() => { setCfg(null); reload(); }), 'Saved')}>Save</Btn>
        </div></details>}
    </section>);
}

// Meta's CSV download: one row per lead, fixed columns then one column per form question.
const FIXED = ['id', 'created_time', 'ad_id', 'ad_name', 'adset_id', 'adset_name', 'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'lead_status'];
export function parseCsv(text) {
  const rows = []; let row = [], cell = '', q = false;
  const t = text.replace(/^﻿/, '');
  const tab = !t.split('\n', 1)[0].includes(',') && t.includes('\t');
  const sep = tab ? '\t' : ',';
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; continue; }
    if (c === '"') q = true;
    else if (c === sep) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && t[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((x) => x.trim()));
}
export function csvToLeads(text) {
  const rows = parseCsv(text);
  if (rows.length < 2) return [];
  const head = rows[0].map((h) => h.trim().toLowerCase());
  const find = (...names) => head.findIndex((h) => names.includes(h));
  const iName = find('full_name', 'full name', 'name'), iPhone = find('phone_number', 'phone number', 'phone'), iEmail = find('email');
  return rows.slice(1).map((r) => {
    const o = { answers: {} };
    head.forEach((h, i) => {
      const v = (r[i] ?? '').trim();
      if (!v) return;
      if (FIXED.includes(h)) o[h] = v;
      else if (i !== iName && i !== iPhone && i !== iEmail) o.answers[h.slice(0, 80)] = v.slice(0, 300);
    });
    if (iName >= 0) o.name = (r[iName] ?? '').trim();
    if (iPhone >= 0) o.phone = (r[iPhone] ?? '').trim();
    if (iEmail >= 0) o.email = (r[iEmail] ?? '').trim();
    return o;
  }).filter((o) => o.id);
}
const csvCell = (v) => { const s = typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

export function LeadArchive({ access }) {
  const [a, reload] = useLoad(() => rpc('api_ads_meta_archive'), []);
  const [busy, setBusy] = useState('');
  if (!a) return null;
  const importFile = async (file) => {
    setBusy('import');
    try {
      const leads = csvToLeads(await file.text());
      if (!leads.length) { showToast('No leads found: use the CSV from Meta (Leads Center or the form\'s Download).', 'error'); return; }
      const tot = { added: 0, updated: 0, skipped: 0, matched: 0 };
      for (let i = 0; i < leads.length; i += 1000) {
        const r = await rpc('api_ads_meta_leads_import', { p_rows: leads.slice(i, i + 1000) }, { timeout: 60000 });
        for (const k of Object.keys(tot)) tot[k] += Number(r?.[k]) || 0;
      }
      showToast(`${tot.added} added, ${tot.updated} updated, ${tot.matched} already in Leads${tot.skipped ? `, ${tot.skipped} skipped` : ''}`, 'success');
      reload();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(''); }
  };
  const download = async () => {
    setBusy('export');
    try {
      const rows = await rpc('api_ads_meta_archive_export', {}, { timeout: 60000 });
      const cols = ['id', 'created_time', 'source', 'campaign_name', 'campaign_id', 'adset_name', 'adset_id', 'ad_name', 'ad_id', 'form_name', 'form_id',
        'platform', 'is_organic', 'name', 'phone', 'email', 'in_leads', 'answers'];
      const csv = [cols.join(','), ...(rows || []).map((r) => cols.map((c) => csvCell(r[c])).join(','))].join('\n');
      const url = URL.createObjectURL(new Blob([`﻿${csv}`], { type: 'text/csv' }));
      const el = Object.assign(document.createElement('a'), { href: url, download: `meta-leads-${new Date().toISOString().slice(0, 10)}.csv` });
      el.click(); setTimeout(() => URL.revokeObjectURL(url), 5000);
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(''); }
  };
  return (
    <section className="glass-card p-4 space-y-2" data-testid="lead-archive">
      <div className="flex items-start gap-2"><div className="flex-1"><h3 className="font-bold">Meta lead archive</h3>
        <div className="text-xs text-glass-muted">Meta deletes form answers after 90 days. Every Meta lead the CRM receives is kept here for good, with its answers.</div></div>
        <span className="text-2xl font-bold">{fmt(a.total)}</span></div>
      <div className="text-xs">{fmt(a.from_crm)} received by the CRM · {fmt(a.imported)} imported · {fmt(a.in_leads)} in Leads{a.first ? ` · ${day(a.first)} – ${day(a.last)}` : ''}
        {a.forms ? ` · ${a.forms_swept} of ${a.forms} forms read back 89 days` : ''}</div>
      {access.is_admin && <div className="flex flex-wrap gap-2">
        <label className="px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center gap-1.5 cursor-pointer" style={{ background: 'rgba(118,118,128,0.12)', opacity: busy ? 0.5 : 1 }}>
          <Icon name="plus" size={14} />{busy === 'import' ? 'Importing…' : 'Import old Meta CSV'}
          <input type="file" accept=".csv,text/csv,.tsv,text/tab-separated-values" className="hidden" aria-label="Meta leads CSV" disabled={!!busy}
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) importFile(f); }} /></label>
        <Btn ghost disabled={!!busy || !a.total} onClick={download}><Icon name="external" size={14} />{busy === 'export' ? 'Preparing…' : 'Download all (CSV)'}</Btn>
      </div>}
    </section>);
}
