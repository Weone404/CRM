import { useState } from 'react';
import { rpc, run, useLoad, Btn } from './adsKit';
import { showToast } from '../utils/toast';
import { confirmDialog, promptDialog } from './ui/dialogs';

// CRM > Meta Ads > Automate (migration 110): quick actions, the approval queue, rules (always with approval) and A/B tests.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF', grey: 'rgba(118,118,128,0.12)' };
const fmt = (v) => (v === null || v === undefined ? '–' : Math.round(Number(v)).toLocaleString('en-IN'));
const inr = (v) => (v === null || v === undefined ? '–' : `₹${Math.round(Number(v)).toLocaleString('en-IN')}`);
const iso = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const LEVELS = [['campaign', 'Campaigns'], ['adset', 'Ad sets'], ['ad', 'Ads']];
const KIND = { pause: 'Pause', activate: 'Switch on', budget: 'Change budget', duplicate: 'Duplicate (paused)' };
const ST = { pending: ['Waiting for approval', C.amber], approved: ['Approved, running soon', C.blue], executing: ['Running', C.blue], done: ['Done', C.green],
  failed: ['Failed', C.red], rejected: ['Rejected', '#6B7280'], cancelled: ['Cancelled', '#6B7280'], stale: ['Changed meanwhile', C.amber], expired: ['Expired', '#6B7280'] };
const METRIC = { spend: 'Spend (₹)', leads: 'Leads', cpl: 'Cost per lead (₹)', cpql: 'Cost per qualified lead (₹)', qualified: 'Qualified leads', ctr: 'CTR (%)', frequency: 'Frequency', cpm: 'CPM (₹)' };
const ACTION = { pause: 'Pause it', budget_up: 'Raise budget by', budget_down: 'Cut budget by', notify: 'Only warn me' };
const TMETRIC = { cost_per_lead: 'Cost per lead', cost_per_qualified: 'Cost per qualified lead', qualified_rate: 'Qualified rate', ctr: 'CTR' };
const describe = (a) => a.kind === 'budget' ? (a.params?.daily ? `Daily budget → ₹${fmt(a.params.daily)}` : `Daily budget ${a.params?.pct > 0 ? '+' : ''}${a.params?.pct}%`) : KIND[a.kind];

function Queue({ data, reload, edge }) {
  if (!data) return null;
  const items = data.items || [];
  const open = items.filter((a) => ['pending', 'approved', 'executing'].includes(a.status));
  const past = items.filter((a) => !['pending', 'approved', 'executing'].includes(a.status)).slice(0, 15);
  const decide = async (a, ok) => {
    const note = ok ? '' : await promptDialog('Why reject it?', { message: 'Optional note for the log.', confirmText: 'Reject' });
    if (note === null) return;
    if (await run(rpc('api_ads_meta_action_decide', { p_id: a.id, p_approve: ok, p_note: note || null }), ok ? 'Approved' : 'Rejected')) {
      if (ok) { const r = await edge({ jobs: ['meta_actions'] }).catch((e) => ({ error: e.message })); const res = r?.results?.meta_actions; showToast(res?.detail || r?.error || 'Sent', res?.status === 'error' || r?.error ? 'error' : 'success'); }
      reload();
    }
  };
  const row = (a) => (
    <div key={a.id} className="flex flex-wrap items-start gap-2 text-sm py-1.5 border-t border-black/5" data-testid={`action-${a.id}`}>
      <div className="flex-1 min-w-[14rem]"><b>{describe(a)}</b> · {a.object_name || a.object_id} <span className="text-xs text-glass-muted">({a.level === 'adset' ? 'ad set' : a.level})</span>
        <div className="text-xs text-glass-muted">{a.source === 'rule' ? `Rule: ${a.rule}. ` : a.source === 'test' ? 'From an A/B test. ' : ''}{a.reason}</div>
        {(a.guard || []).map((g) => <div key={g} className="text-xs" style={{ color: C.amber }}>{g}</div>)}
        {a.error && <div className="text-xs" style={{ color: C.red }}>{a.error}</div>}
        {a.after?.note && <div className="text-xs text-glass-muted">{a.after.note}</div>}
        {a.after?.copy_id && <div className="text-xs text-glass-muted">Copy id {a.after.copy_id}</div>}</div>
      <span className="text-xs font-semibold" style={{ color: ST[a.status]?.[1] }}>{ST[a.status]?.[0] || a.status}</span>
      {a.status === 'pending' && data.can_approve && <><Btn ghost onClick={() => decide(a, false)}>Reject</Btn>
        <Btn disabled={data.two_person && a.mine} onClick={() => decide(a, true)}>{data.two_person && a.mine ? 'Needs another approver' : 'Approve and run'}</Btn></>}
    </div>);
  return (
    <section className="glass-card p-4 space-y-2" data-testid="action-queue">
      <h3 className="font-bold">Changes waiting ({open.length})</h3>
      <p className="text-xs text-glass-muted">Nothing changes in Meta until an approver approves. The CRM reads the object first, makes the change, then reads it back.{data.paused ? ' The Meta emergency stop is on: approved changes wait.' : ''}</p>
      {open.length === 0 ? <div className="text-sm text-glass-muted">Nothing waiting.</div> : open.map(row)}
      {past.length > 0 && <details className="text-sm"><summary className="cursor-pointer text-xs font-semibold">History ({past.length})</summary>{past.map(row)}</details>}
    </section>);
}

function Objects({ access, reload: reloadQueue, edge }) {
  const [level, setLevel] = useState('adset');
  const [list, reload] = useLoad(() => rpc('api_ads_meta_objects', { p_level: level, p_days: 7 }), [level]);
  const can = access?.can_approve || access?.is_admin;
  const ask = async (o, kind) => {
    let params = {};
    if (kind === 'budget') {
      const v = await promptDialog(`New daily budget for ${o.name || o.id} (₹)`, { message: 'Ad sets with campaign budgets keep their budget on the campaign.', required: true, confirmText: 'Ask' });
      if (v === null) return;
      params = { daily: Number(String(v).replace(/[^\d.]/g, '')) };
    } else if (!(await confirmDialog(`${KIND[kind]}: ${o.name || o.id}?`, { message: 'This asks for approval; nothing changes until it is approved.', confirmText: 'Ask' }))) return;
    try {
      const r = await rpc('api_ads_meta_action_request', { p_level: level, p_object_id: o.id, p_kind: kind, p_params: params, p_reason: 'Quick action' });
      if (r.self_approve && await confirmDialog('Approve and run it now?', { message: (r.guard || []).join(' ') || 'You can also leave it for another approver.', confirmText: 'Approve and run' })) {
        await rpc('api_ads_meta_action_decide', { p_id: r.id, p_approve: true, p_note: null });
        const e = await edge({ jobs: ['meta_actions'] }).catch((x) => ({ error: x.message }));
        showToast(e?.results?.meta_actions?.detail || e?.error || 'Sent', e?.error || e?.results?.meta_actions?.status === 'error' ? 'error' : 'success');
      } else showToast('Asked: waiting for approval', 'success');
    } catch (e) { showToast(e.message, 'error'); }
    reload(); reloadQueue();
  };
  return (
    <section className="glass-card p-4 space-y-2" data-testid="quick-actions">
      <div className="flex flex-wrap items-center gap-2"><h3 className="font-bold flex-1">Quick actions</h3>
        <div role="tablist" aria-label="Object level" className="flex rounded-xl overflow-hidden" style={{ background: C.grey }}>
          {LEVELS.map(([k, l]) => <button key={k} role="tab" aria-selected={level === k} onClick={() => setLevel(k)} className="px-3 py-1.5 text-sm font-semibold"
            style={level === k ? { background: C.blue, color: '#fff' } : {}}>{l}</button>)}</div></div>
      <p className="text-xs text-glass-muted">Last 7 days. A budget change of 20% or more is a big edit that can restart Meta's learning phase; small steps are safer.</p>
      {!list ? <div className="text-sm text-glass-muted">Loading…</div> : list.length === 0 ? <div className="text-sm text-glass-muted">Nothing synced from Meta yet.</div> : (
        <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="object-table">
          <thead><tr className="text-left text-xs text-glass-muted"><th className="p-2">Name</th><th className="p-2">Status</th><th className="p-2 text-right">Spend</th><th className="p-2 text-right">Leads</th>
            <th className="p-2 text-right">Cost per lead</th><th className="p-2 text-right">Qualified</th><th className="p-2 text-right">Cost per qualified</th><th className="p-2 text-right">Frequency</th>{can && <th className="p-2">Action</th>}</tr></thead>
          <tbody>{list.map((o) => (
            <tr key={o.id} className="border-t border-black/5">
              <td className="p-2 font-medium max-w-[16rem] truncate" title={o.name}>{o.name || o.id}</td><td className="p-2 text-xs">{(o.status || '').toLowerCase().replace(/_/g, ' ')}</td>
              <td className="p-2 text-right">{inr(o.spend)}</td><td className="p-2 text-right">{fmt(o.leads)}</td><td className="p-2 text-right">{inr(o.cpl)}</td>
              <td className="p-2 text-right">{fmt(o.qualified)}</td><td className="p-2 text-right">{inr(o.cpql)}</td><td className="p-2 text-right">{o.frequency ?? '–'}</td>
              {can && <td className="p-2 whitespace-nowrap">{o.open?.length ? <span className="text-xs" style={{ color: C.amber }}>waiting: {o.open.map((k) => KIND[k]).join(', ')}</span> : <div className="flex gap-1">
                {o.status === 'ACTIVE' ? <button className="text-xs font-semibold" style={{ color: C.red }} onClick={() => ask(o, 'pause')}>Pause</button>
                  : <button className="text-xs font-semibold" style={{ color: C.green }} onClick={() => ask(o, 'activate')}>Switch on</button>}
                {level !== 'ad' && <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={() => ask(o, 'budget')}>Budget</button>}
                <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={() => ask(o, 'duplicate')}>Duplicate</button></div>}</td>}
            </tr>))}</tbody></table></div>)}
    </section>);
}

const BLANK_RULE = { name: '', enabled: false, level: 'adset', name_contains: '', metric: 'cpql', window_days: 7, op: 'gt', value: '', min_spend: 1000, min_leads: 5, action: 'pause', pct: 15, cooldown_days: 3 };
function Rules({ access, reloadQueue }) {
  const [list, reload] = useLoad(() => rpc('api_ads_meta_rules'), []);
  const [edit, setEdit] = useState(null);
  if (!list) return null;
  const admin = access?.is_admin;
  const save = (r) => run(rpc('api_ads_meta_rule_save', { p: { ...r, value: String(r.value), pct: r.pct == null || r.pct === '' ? null : String(r.pct), window_days: String(r.window_days),
    min_spend: String(r.min_spend), min_leads: String(r.min_leads), cooldown_days: String(r.cooldown_days) } }).then(() => { setEdit(null); reload(); }), 'Saved');
  const runNow = async (id) => { if (await run(rpc('api_ads_meta_rules_run', { p_rule: id ?? null }).then((r) => { showToast(`Checked ${r.checked}: ${r.requests} request(s), ${r.warnings} warning(s)`, 'success'); return r; }))) { reload(); reloadQueue(); } };
  const sentence = (r) => `${r.level === 'adset' ? 'Ad sets' : r.level === 'ad' ? 'Ads' : 'Campaigns'}${r.name_contains ? ` named "…${r.name_contains}…"` : ''}: if ${METRIC[r.metric]} is ${r.op === 'gt' ? 'above' : 'below'} ${r.value} over ${r.window_days} days (after ₹${fmt(r.min_spend)} spend${r.min_leads ? ` and ${r.min_leads} leads` : ''}) → ${ACTION[r.action]}${r.pct ? ` ${r.pct}%` : ''}; wait ${r.cooldown_days} days before asking again.`;
  const set = (k) => (e) => setEdit({ ...edit, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <section className="glass-card p-4 space-y-2" data-testid="rules">
      <div className="flex flex-wrap items-start gap-2"><div className="flex-1 min-w-[14rem]"><h3 className="font-bold">Rules</h3>
        <p className="text-xs text-glass-muted">Checked every morning at 09:10. They can use CRM quality (qualified leads), which Meta's own rules cannot see. A rule only asks: every change still needs approval.</p></div>
        {(access?.can_approve || admin) && <Btn ghost onClick={() => runNow(null)}>Run all now</Btn>}{admin && <Btn ghost onClick={() => setEdit({ ...BLANK_RULE })}>Add rule</Btn>}</div>
      {list.map((r) => (
        <div key={r.id} className="flex flex-wrap items-start gap-2 text-sm py-1.5 border-t border-black/5" style={{ opacity: r.enabled ? 1 : 0.6 }} data-testid={`rule-${r.id}`}>
          {admin && <input type="checkbox" aria-label={`Rule ${r.name} on`} checked={r.enabled} onChange={(e) => save({ ...r, enabled: e.target.checked })} />}
          <div className="flex-1 min-w-[14rem]"><b>{r.name}</b><div className="text-xs text-glass-muted">{sentence(r)}</div>
            {r.last_run_at && <div className="text-[11px] text-glass-muted">Last run {new Date(r.last_run_at).toLocaleString('en-IN')}: {r.last_hits ?? 0} hit(s)</div>}</div>
          {admin && <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={() => setEdit({ ...r })}>Edit</button>}
        </div>))}
      {edit && <div className="rounded-xl p-3 space-y-2 border border-black/10" data-testid="rule-edit">
        <label className="text-xs block">Name<input aria-label="Rule name" className="glass-input px-2 py-1 text-sm w-full block" value={edit.name} onChange={set('name')} /></label>
        <div className="flex flex-wrap items-end gap-2 text-xs">
          <label>Level<select aria-label="Rule level" className="glass-input px-2 py-1 text-sm block" value={edit.level} onChange={set('level')}>{LEVELS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <label>Name contains<input aria-label="Rule name contains" className="glass-input px-2 py-1 text-sm w-32 block" value={edit.name_contains || ''} onChange={set('name_contains')} /></label>
          <label>If<select aria-label="Rule metric" className="glass-input px-2 py-1 text-sm block" value={edit.metric} onChange={set('metric')}>{Object.entries(METRIC).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <label>is<select aria-label="Rule op" className="glass-input px-2 py-1 text-sm block" value={edit.op} onChange={set('op')}><option value="gt">above</option><option value="lt">below</option></select></label>
          <label>Limit<input aria-label="Rule value" className="glass-input px-2 py-1 text-sm w-24 block" value={edit.value} onChange={set('value')} /></label>
          <label>Days<input aria-label="Rule days" type="number" className="glass-input px-2 py-1 text-sm w-16 block" value={edit.window_days} onChange={set('window_days')} /></label>
          <label>Min spend ₹<input aria-label="Rule min spend" type="number" className="glass-input px-2 py-1 text-sm w-24 block" value={edit.min_spend} onChange={set('min_spend')} /></label>
          <label>Min leads<input aria-label="Rule min leads" type="number" className="glass-input px-2 py-1 text-sm w-16 block" value={edit.min_leads} onChange={set('min_leads')} /></label>
          <label>Then<select aria-label="Rule action" className="glass-input px-2 py-1 text-sm block" value={edit.action} onChange={set('action')}>{Object.entries(ACTION).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          {edit.action.startsWith('budget') && <label>%<input aria-label="Rule pct" type="number" className="glass-input px-2 py-1 text-sm w-16 block" value={edit.pct ?? ''} onChange={set('pct')} /></label>}
          <label>Cool-down days<input aria-label="Rule cooldown" type="number" className="glass-input px-2 py-1 text-sm w-16 block" value={edit.cooldown_days} onChange={set('cooldown_days')} /></label>
          <label className="flex items-center gap-1"><input type="checkbox" aria-label="Rule enabled" checked={!!edit.enabled} onChange={set('enabled')} />On</label>
        </div>
        <div className="text-xs text-glass-muted">{edit.value !== '' ? sentence(edit) : ''}</div>
        <div className="flex gap-2">{edit.id && <Btn ghost onClick={() => run(rpc('api_ads_meta_rule_save', { p: { id: edit.id, delete: 'true' } }).then(() => { setEdit(null); reload(); }), 'Deleted')}>Delete</Btn>}
          {edit.id && <Btn ghost onClick={() => runNow(edit.id)}>Test this rule now</Btn>}
          <div className="flex-1" /><Btn ghost onClick={() => setEdit(null)}>Cancel</Btn><Btn onClick={() => save(edit)}>Save rule</Btn></div>
      </div>}
    </section>);
}

function Tests({ access }) {
  const [list, reload] = useLoad(() => rpc('api_ads_meta_tests'), []);
  const [form, setForm] = useState(null);
  const [objs] = useLoad(() => (form ? rpc('api_ads_meta_objects', { p_level: form.level, p_days: 30 }) : Promise.resolve(null)), [form?.level, !!form]);
  if (!list) return null;
  const admin = access?.is_admin;
  const start = () => setForm({ name: '', hypothesis: '', variable: 'creative', level: 'adset', metric: 'cost_per_qualified', start_date: iso(new Date()),
    end_date: iso(new Date(Date.now() + 14 * 86400000)), min_results: 30, meta_split: false, cells: [{ name: 'A (control)', ids: [] }, { name: 'B', ids: [] }] });
  const setCell = (i, k, v) => setForm({ ...form, cells: form.cells.map((c, j) => (j === i ? { ...c, [k]: v } : c)) });
  const create = () => run(rpc('api_ads_meta_test_save', { p: { ...form, min_results: String(form.min_results) } }).then(() => { setForm(null); reload(); }), 'Test started');
  return (
    <section className="glass-card p-4 space-y-3" data-testid="ab-tests">
      <div className="flex flex-wrap items-start gap-2"><div className="flex-1 min-w-[14rem]"><h3 className="font-bold">A/B tests</h3>
        <p className="text-xs text-glass-muted">Change one thing at a time. Cost tests check each cell's share of leads against its share of spend; rate tests use a two-proportion test. A winner needs 95% confidence and enough results in every cell. "Meta split test" also makes it a real Meta A/B test, where Meta keeps the audiences apart.</p></div>
        {admin && !form && <Btn ghost onClick={start}>New test</Btn>}</div>
      {form && <div className="rounded-xl p-3 space-y-2 border border-black/10" data-testid="test-form">
        <div className="flex flex-wrap gap-2 text-xs">
          <label className="flex-1 min-w-[12rem]">Name<input aria-label="Test name" className="glass-input px-2 py-1 text-sm w-full block" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></label>
          <label>Testing<select aria-label="Test variable" className="glass-input px-2 py-1 text-sm block" value={form.variable} onChange={(e) => setForm({ ...form, variable: e.target.value })}>
            {['creative', 'audience', 'placement', 'form', 'offer', 'other'].map((v) => <option key={v} value={v}>{v}</option>)}</select></label>
          <label>Compare<select aria-label="Test level" className="glass-input px-2 py-1 text-sm block" value={form.level} onChange={(e) => setForm({ ...form, level: e.target.value, cells: form.cells.map((c) => ({ ...c, ids: [] })) })}>
            {LEVELS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <label>Judge by<select aria-label="Test metric" className="glass-input px-2 py-1 text-sm block" value={form.metric} onChange={(e) => setForm({ ...form, metric: e.target.value })}>
            {Object.entries(TMETRIC).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <label>From<input aria-label="Test start" type="date" className="glass-input px-2 py-1 text-sm block" value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} /></label>
          <label>To<input aria-label="Test end" type="date" className="glass-input px-2 py-1 text-sm block" value={form.end_date} onChange={(e) => setForm({ ...form, end_date: e.target.value })} /></label>
          <label>Min results per cell<input aria-label="Test min results" type="number" className="glass-input px-2 py-1 text-sm w-20 block" value={form.min_results} onChange={(e) => setForm({ ...form, min_results: e.target.value })} /></label>
        </div>
        <label className="text-xs block">What do you expect, and why?<input aria-label="Test hypothesis" className="glass-input px-2 py-1 text-sm w-full block" value={form.hypothesis} onChange={(e) => setForm({ ...form, hypothesis: e.target.value })} /></label>
        <div className="grid md:grid-cols-2 gap-2">{form.cells.map((c, i) => (
          <div key={i} className="rounded-lg p-2 space-y-1" style={{ background: C.grey }}>
            <input aria-label={`Cell ${i + 1} name`} className="glass-input px-2 py-1 text-sm w-full" value={c.name} onChange={(e) => setCell(i, 'name', e.target.value)} />
            <select aria-label={`Cell ${i + 1} objects`} multiple className="glass-input px-2 py-1 text-xs w-full h-24" value={c.ids}
              onChange={(e) => setCell(i, 'ids', [...e.target.selectedOptions].map((o) => o.value))}>
              {(objs || []).map((o) => <option key={o.id} value={o.id} disabled={form.cells.some((x, j) => j !== i && x.ids.includes(o.id))}>{o.name || o.id}</option>)}</select>
          </div>))}</div>
        <div className="flex flex-wrap items-center gap-2 text-xs">
          {form.cells.length < 5 && <button className="font-semibold" style={{ color: C.blue }} onClick={() => setForm({ ...form, cells: [...form.cells, { name: String.fromCharCode(65 + form.cells.length), ids: [] }] })}>+ Cell</button>}
          <label className="flex items-center gap-1"><input type="checkbox" aria-label="Meta split test" checked={form.meta_split} disabled={form.level === 'ad'} onChange={(e) => setForm({ ...form, meta_split: e.target.checked })} />Also create as a Meta split test</label>
          <div className="flex-1" /><Btn ghost onClick={() => setForm(null)}>Cancel</Btn><Btn onClick={create}>Start test</Btn></div>
      </div>}
      {list.length === 0 && !form && <div className="text-sm text-glass-muted">No tests yet.</div>}
      {list.map((t) => (
        <div key={t.id} className="rounded-xl p-3 space-y-1 text-sm" style={{ background: C.grey }} data-testid={`test-${t.id}`}>
          <div className="flex flex-wrap items-baseline gap-2"><b className="flex-1">{t.name}</b><span className="text-xs text-glass-muted">{t.variable} · {TMETRIC[t.metric]} · {t.start_date} → {t.end_date} · {t.status}</span>
            {admin && t.status === 'running' && <button className="text-xs font-semibold" style={{ color: C.blue }} onClick={async () => {
              const d = await promptDialog('Finish the test: what did you decide?', { message: 'Written to the test for the record.', confirmText: 'Finish' });
              if (d !== null) await run(rpc('api_ads_meta_test_save', { p: { id: t.id, status: 'finished', decision: d } }).then(reload), 'Finished');
            }}>Finish</button>}</div>
          {t.hypothesis && <div className="text-xs text-glass-muted">{t.hypothesis}</div>}
          <div className="overflow-x-auto"><table className="w-full text-xs"><thead><tr className="text-left text-glass-muted"><th className="p-1">Cell</th><th className="p-1 text-right">Spend</th><th className="p-1 text-right">Leads</th>
            <th className="p-1 text-right">Qualified</th><th className="p-1 text-right">{TMETRIC[t.metric]}</th><th className="p-1 text-right">Confidence vs control</th></tr></thead>
            <tbody>{t.result.cells.map((c, i) => (
              <tr key={i} className="border-t border-black/5" style={t.result.leader === i ? { fontWeight: 700 } : undefined}><td className="p-1">{c.name}</td><td className="p-1 text-right">{inr(c.spend)}</td><td className="p-1 text-right">{fmt(c.leads)}</td>
                <td className="p-1 text-right">{fmt(c.qualified)}</td><td className="p-1 text-right">{c.value === null ? '–' : t.metric.startsWith('cost') ? inr(c.value) : `${c.value}%`}</td>
                <td className="p-1 text-right">{i === 0 ? 'control' : c.confidence === null || c.confidence === undefined ? '–' : `${c.confidence}%`}</td></tr>))}</tbody></table></div>
          <div className="text-xs font-semibold" style={{ color: t.result.enough ? C.green : C.amber }}>{t.result.verdict}</div>
          {t.meta_split && <div className="text-[11px] text-glass-muted">Meta split test: {t.meta_study_id ? `created (${t.meta_study_id})` : t.meta_detail || 'being created'}</div>}
          {t.decision && <div className="text-xs">Decision: {t.decision}</div>}
        </div>))}
    </section>);
}

export default function AdsMetaAutomate({ access, edge }) {
  const [q, reloadQueue] = useLoad(() => rpc('api_ads_meta_actions', { p_days: 14 }), [], { refreshMs: 60000 });
  return (
    <div className="space-y-3" data-testid="meta-automate">
      <Queue data={q} reload={reloadQueue} edge={edge} />
      <Objects access={access} reload={reloadQueue} edge={edge} />
      <Rules access={access} reloadQueue={reloadQueue} />
      <Tests access={access} />
    </div>);
}
